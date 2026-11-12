#!/usr/bin/env bash
# Install every package of a built repository on fresh Debian and Ubuntu
# containers, the way a user would: the setup file, apt update, apt install.
#
#   ./test.sh [site dir] [image ...]
#
# The default images are the oldest and newest releases the packages support.
# Each installed binary in /usr/bin has to answer --version, and then every
# package has to purge cleanly, which runs its removal scripts. apt update has
# to finish without a warning or an error, so a bad signature or index fails
# here rather than on someone's machine. Images run at Docker's default
# platform; set DOCKER_DEFAULT_PLATFORM=linux/arm64, linux/amd64 or
# linux/arm/v7 (armhf) to try another.
set -euo pipefail
cd "$(dirname "$0")"

site=$(cd "${1:-site}" && pwd)
shift || true
images=("$@")
if [ ${#images[@]} -eq 0 ]; then images=(debian:12 debian:13 ubuntu:22.04 ubuntu:24.04); fi

port=8765
python3 -m http.server --bind 0.0.0.0 --directory "$site" "$port" >/dev/null 2>&1 &
server=$!
trap 'kill "$server"' EXIT
sleep 1

# "<arch> <package> ...", a line per architecture. Not every project builds for
# every architecture (kith has no armhf), so each container installs what its
# own architecture has.
by_arch=$(for f in "$site"/dists/stable/main/binary-*/Packages; do
	arch=${f%/Packages}
	echo "${arch##*binary-} $(sed -n 's/^Package: //p' "$f" | sort -u | xargs)"
done)
sources=$(sed "s|^URIs: .*|URIs: http://host.docker.internal:$port|" "$site/cartercole.sources")

for image in "${images[@]}"; do
	echo "--- $image"
	docker run --rm --add-host=host.docker.internal:host-gateway \
		-e SOURCES="$sources" -e BY_ARCH="$by_arch" "$image" sh -euc '
		arch=$(dpkg --print-architecture)
		PACKAGES=$(printf "%s\n" "$BY_ARCH" | sed -n "s/^$arch //p")
		if [ -z "$PACKAGES" ]; then echo "no packages for $arch"; exit 1; fi
		echo "$arch: $PACKAGES"
		printf "%s\n" "$SOURCES" > /etc/apt/sources.list.d/cartercole.sources
		apt-get update > /tmp/update.log 2>&1 || { cat /tmp/update.log; exit 1; }
		if grep -E "^(W|E):" /tmp/update.log; then exit 1; fi
		apt-get install -y -qq --no-install-recommends $PACKAGES > /tmp/install.log 2>&1 ||
			{ cat /tmp/install.log; exit 1; }
		for p in $PACKAGES; do
			for bin in $(dpkg -L "$p" | grep "^/usr/bin/."); do
				v=$("$bin" --version 2>&1) || { echo "$bin --version failed: $v"; exit 1; }
				echo "$p: $(printf "%s\n" "$v" | head -n 1)"
			done
		done
		apt-get purge -y -qq $PACKAGES > /tmp/purge.log 2>&1 || { cat /tmp/purge.log; exit 1; }'
done
