# apt.cartercole.net

An apt repository for the tools in [github.com/CarterCole](https://github.com/CarterCole).
It works for apt the way [homebrew-tap](https://github.com/CarterCole/homebrew-tap) works
for Homebrew: add it once, then `apt install` and `apt upgrade` as usual.

On Debian 12+ or Ubuntu 22.04+:

```bash
sudo curl -fsSLo /etc/apt/sources.list.d/cartercole.sources https://apt.cartercole.net/cartercole.sources
sudo apt update && sudo apt install kith bond
```

`cartercole.sources` names the repository and carries its signing key inline, so that one
file is the whole setup, whichever packages you install. To remove the repository, delete
it.

| Package | From | Architectures |
|---------|------|---------------|
| `bond` | [CarterCole/bond](https://github.com/CarterCole/bond) | amd64, arm64, armhf |
| `kith` | [CarterCole/kith](https://github.com/CarterCole/kith) | amd64, arm64 |

## How it works

Nothing in this repository holds a package. Each file in `projects/` names a GitHub
repository whose releases carry `.deb` files, and the latest release that triggered a
build:

```
CarterCole/kith v0.2.0
```

On every push to `main`, [`publish.yml`](.github/workflows/publish.yml):

1. runs [`build.sh`](build.sh), which downloads the `.deb` files from the newest three
   releases of each project (checking GitHub's digest of each asset), writes the
   `Packages` and `Release` indexes with `apt-ftparchive`, and signs `Release` as
   `InRelease` and `Release.gpg`;
2. runs [`test.sh`](test.sh), which adds the repository on fresh Debian 12 and 13 and
   Ubuntu 22.04 and 24.04 containers (amd64, the runner's architecture), installs every
   package, runs each binary's `--version` and purges the packages again. `apt update`
   has to finish without a warning;
3. deploys the result to GitHub Pages, at apt.cartercole.net.

The site is rebuilt from the releases each time, so it keeps no state of its own. Keeping
three releases lets someone go back with `apt install kith=0.2.0-1`.

## Adding a project

1. Have the project's release attach a `.deb` per architecture (`amd64`, `arm64`,
   `armhf` if it builds one).
   - A Rust binary: add `[package.metadata.deb]` to its `Cargo.toml` and run
     `cargo deb --target <target> --no-build` after the release build, on a runner of that
     architecture so cargo-deb can work out `Depends` from the binary. Kith's
     [`release.yml`](https://github.com/CarterCole/kith/blob/main/.github/workflows/release.yml)
     does this.
   - A static binary (Go with `CGO_ENABLED=0`): package the release's binaries with
     [nfpm](https://nfpm.goreleaser.com). Bond's
     [`deploy/debian/nfpm.yaml`](https://github.com/CarterCole/bond/blob/main/deploy/debian/nfpm.yaml)
     and its `make release` do this.
2. Add `projects/<name>` here with the repository and its latest release tag.
3. Give the project's release a way to push here: make an SSH key, add its public half as
   a deploy key with write access on this repository, and store the private half as a
   secret on the project (`APT_REPO_DEPLOY_KEY`). Each project needs its own key, since
   GitHub accepts a key on one repository only. The release's last step clones this
   repository, writes `projects/<name>`, commits and pushes; the push starts the build.

## The signing key

`key.asc` is the public key, fingerprint
`F9C9 CB24 B25F 9B6A 1EB1 ABD0 CE79 24F6 0969 F61A` (Ed25519, no expiry). The secret half
lives only in this repository's `APT_SIGNING_KEY` Actions secret. If it is lost, make a new
key, replace `key.asc` and the secret, and anyone who added the repository fetches
`cartercole.sources` again.

## Building it locally

`build.sh` needs bash, curl, jq, gpg, dpkg-deb and apt-ftparchive, so on a Mac run it in a
container, with the secret key imported first. `test.sh` runs on the host and needs Docker.

```bash
./build.sh site && ./test.sh site
```
