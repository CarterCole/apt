#!/usr/bin/env bash
# Build the apt repository into a directory of static files.
#
#   ./build.sh [out dir] [local .deb ...]          (out dir default: site)
#
# Each file in projects/ names a GitHub repository whose releases carry .deb
# files. The .debs from the newest $KEEP releases of each (default 3) go into
# the pool, so `apt install <name>=<version>` can go back a release or two.
# Local .debs named after the out dir go in too, to try a package before its
# release; the workflow never passes any.
# Then it writes the indexes, signs them with the key in key.asc (its secret
# half has to be in gpg's keyring), and writes the setup file and front page.
#
# Needs bash, curl, jq, gpg, dpkg-deb and apt-ftparchive (apt-utils). GH_TOKEN,
# when set, lifts GitHub's rate limit on the release listings.
set -euo pipefail
cd "$(dirname "$0")"

out=${1:-site}
shift || true
keep=${KEEP:-3}
url=https://apt.cartercole.net
suite=stable
component=main

fpr=$(gpg --show-keys --with-colons key.asc | awk -F: '$1 == "fpr" { print $10; exit }')
if ! gpg --list-secret-keys "$fpr" >/dev/null 2>&1; then
	echo "the secret half of key.asc ($fpr) is not in gpg's keyring" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$out/pool/$component"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

auth=()
if [ -n "${GH_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GH_TOKEN"); fi

# Put a .deb in the pool, named from the package's own control fields.
add() {
	local pkg ver arch dir
	pkg=$(dpkg-deb -f "$1" Package)
	ver=$(dpkg-deb -f "$1" Version)
	arch=$(dpkg-deb -f "$1" Architecture)
	dir=$out/pool/$component/${pkg:0:1}/$pkg
	mkdir -p "$dir"
	cp "$1" "$dir/${pkg}_${ver#*:}_$arch.deb"
	echo "$2: ${pkg}_${ver#*:}_$arch.deb"
}

for deb in "$@"; do add "$deb" local; done

# Download the .debs. A release asset's digest, where GitHub gives one, is
# checked.
for project in projects/*; do
	read -r repo _ <"$project"
	curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/$repo/releases?per_page=30" |
		jq -r --argjson keep "$keep" '
			[ .[] | select((.draft or .prerelease) | not)
			      | select(any(.assets[]; .name | endswith(".deb"))) ][:$keep][]
			| .assets[] | select(.name | endswith(".deb"))
			| "\(.browser_download_url) \(.digest // "-")"' >"$tmp/assets"
	if [ ! -s "$tmp/assets" ]; then
		echo "warning: no release of $repo has a .deb" >&2
	fi
	while read -r asset digest; do
		deb=$tmp/download.deb
		curl -fsSL -o "$deb" "$asset"
		if [ "$digest" != - ] && ! echo "${digest#sha256:}  $deb" | sha256sum -c --status -; then
			echo "$asset does not match its digest $digest" >&2
			exit 1
		fi
		add "$deb" "$repo"
	done <"$tmp/assets"
done

archs=$(find "$out/pool" -name '*.deb' -exec dpkg-deb -f {} Architecture \; | grep -vx all | sort -u | xargs)
if [ -z "$archs" ]; then
	echo "no packages for any architecture: refusing to publish an empty repository" >&2
	exit 1
fi

# The indexes. By-hash paths (Acquire-By-Hash) mean a client that gets a new
# InRelease never pairs it with a Packages file a CDN cached from before.
(
	cd "$out"
	for arch in $archs; do
		dir=dists/$suite/$component/binary-$arch
		mkdir -p "$dir"
		apt-ftparchive --arch "$arch" packages "pool/$component" >"$dir/Packages"
		gzip -9nk "$dir/Packages"
		xz -k "$dir/Packages"
	done
	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=apt.cartercole.net \
		-o APT::FTPArchive::Release::Label="Carter Cole" \
		-o APT::FTPArchive::Release::Suite="$suite" \
		-o APT::FTPArchive::Release::Codename="$suite" \
		-o APT::FTPArchive::Release::Architectures="$archs" \
		-o APT::FTPArchive::Release::Components="$component" \
		-o APT::FTPArchive::Release::Description="Packages from github.com/CarterCole" \
		-o APT::FTPArchive::DoByHash=true \
		release "dists/$suite" >"$tmp/Release"
	mv "$tmp/Release" "dists/$suite/Release"
	gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 \
		--clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"
	gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 \
		--armor --detach-sign -o "dists/$suite/Release.gpg" "dists/$suite/Release"
)

# Check the signature the way apt will, against key.asc alone.
gpg --dearmor <key.asc >"$tmp/key.gpg"
gpgv --quiet --keyring "$tmp/key.gpg" "$out/dists/$suite/InRelease"

# The setup file: the repository with its key inline (apt 2.3 or newer, which
# every release the packages support has). Blank lines in an inline key are ".".
cp key.asc "$out/key.asc"
{
	echo "Types: deb"
	echo "URIs: $url"
	echo "Suites: $suite"
	echo "Components: $component"
	echo "Signed-By:"
	sed -e 's/^$/./' -e 's/^/ /' key.asc
} >"$out/cartercole.sources"

# The front page lists the newest version of each package.
find "$out/pool" -name '*.deb' -exec dpkg-deb -W \
	--showformat='${Package}\t${Version}\t${Architecture}\t${binary:Summary}\t${Homepage}\n' {} \; |
	sort -t "$(printf '\t')" -k1,1 -k2,2V -k3,3 |
	awk -F '\t' '
		function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
		function flush() {
			if (pkg == "") return
			name = home == "" ? esc(pkg) : sprintf("<a href=\"%s\">%s</a>", esc(home), esc(pkg))
			printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", name, esc(ver), archs, esc(desc)
		}
		$1 != pkg { flush(); pkg = $1; ver = "" }
		$2 != ver { ver = $2; archs = "" }
		{ archs = archs (archs == "" ? "" : ", ") $3; desc = $4; home = $5 }
		END { flush() }' >"$tmp/rows"
awk -v rows="$tmp/rows" -v fpr="$fpr" '
	/<!-- packages -->/ { while ((getline line < rows) > 0) print line; next }
	{ gsub(/\{\{fingerprint\}\}/, fpr); print }' index.html >"$out/index.html"

echo "built $out: $(find "$out/pool" -name '*.deb' | wc -l | xargs) packages for $archs, signed by $fpr"
