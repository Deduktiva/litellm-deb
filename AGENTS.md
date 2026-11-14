# litellm-deb — agent instructions

## Purpose

Builds Debian packages of the latest LiteLLM from PyPI for Debian 13 (trixie) on amd64 (primary
target: a Debian 13 VM running the proxy against the DGX Spark's vLLM over the network) and
arm64, and publishes them weekly as GitHub Releases and a signed apt repository on GitHub Pages.

## Build, test, run

- Syntax: `bash -n build/*.sh` and `sh -n build/postinst build/prerm build/postrm`.
- One deb: `build/build-deb.sh <version> <arch> <wheel> dist` (needs `dpkg-deb`).
- Repo: `APT_GPG_PRIVATE_KEY=... build/build-apt-repo.sh site <version> dist/*.deb`
  (needs `dpkg-scanpackages`, `apt-ftparchive`, `gpg`). The key is mandatory: the script
  hard-fails without `APT_GPG_PRIVATE_KEY` (ASCII-armored secret key; optional
  `APT_GPG_PASSPHRASE`) and never builds an unsigned repo.
- Workflow: `.github/workflows/litellm-deb.yml` calls the reusable
  `.github/workflows/publish-apt-repo.yml` after the release; validate YAML with PyYAML `safe_load`.
- Test runs happen in the dev container (`.owncore/devenv.yml` + `Dockerfile.dev` — base image is
  Debian 13 like the target, plus `dpkg-dev`, `apt-utils`, `gnupg2`; no dev server): bring it up,
  then run the commands below through `devenv_exec` rather than host tooling.
- Validate a built repo with apt as non-root: `apt-get update`/`apt-cache policy` with
  `-o Dir::State=... -o Dir::Cache=... -o Dir::Etc=...` pointing at scratch dirs, source in
  `<Dir::Etc>/sources.list.d/*.list` (`deb [signed-by=<keyring>] file:<site> stable main`).

## Conventions

- Maintainer scripts are POSIX sh with `set -e` (dpkg runs them with /bin/sh); build scripts are
  bash with `set -euo pipefail`.
- The deb installs the wheel with the `[proxy]` extra: the bare wheel's `litellm` CLI exits with
  "Missing dependency ... websockets".
- Trixie has no `python3-pipx` package; the dependency is `pipx` (trixie `main`, so no extra
  component is needed on clients).
- Packages files must use `Filename: pool/main/litellm/...` relative to the repo root
  (`dpkg-scanpackages --arch <a> pool/main/litellm` run from the site dir).
- An arm64 wheel cannot be pip-installed on an amd64 host; test the pipx path with the host's wheel.

## Do not

- Commit wheels, debs, `site/`, or any GPG key material.
