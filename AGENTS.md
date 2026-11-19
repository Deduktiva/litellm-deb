# litellm-deb — agent instructions

## Purpose

Builds Debian packages of the latest LiteLLM from PyPI for Debian 13 (trixie) on amd64 (primary
target: a Debian 13 VM running the proxy against the DGX Spark's vLLM over the network) and
arm64, and publishes them weekly as GitHub Releases and a signed apt repository on GitHub Pages.

## Build, test, run

- Syntax: `bash -n build/*.sh` and `sh -n build/postinst build/prerm build/postrm`.
- One deb: `build/download-wheels.sh <version> <arch> build/wheels-<arch>` (needs
  `python3-pip`), then `build/make-venv.sh <version> <wheels-dir> <venv-dir>`
  (needs Debian 13's `python3-venv` — the interpreter must be the target's
  3.13), then `build/build-deb.sh <version> <arch> <venv-dir> dist`.
- Current build (2026-11-14): the deb ships a **complete venv** at
  `/opt/litellm/venv` (litellm[proxy,extra_proxy,saml,healthcheck] + all deps; pip removed again after the
  offline install). `Depends:` is `python3, python3.13, systemd`; `ExecStart` runs the
  venv entry point directly. No pipx, no PyPI access at install time, all
  venv files dpkg-tracked (`/var/lib/dpkg/info/litellm.list`, `dpkg -V`
  works). CI assembles each deb inside a `debian:trixie` container on a
  native runner of that architecture (arm64 on `ubuntu-24.04-arm`, amd64 on
  `ubuntu-24.04`) and smoke-tests it with a real `dpkg -i` in a fresh trixie
  container. GitHub runners have no qemu/binfmt: a cross-arch container dies
  with "exec format error", so never run an arm64 container on an amd64
  runner (or vice versa).
- The manylinux tag list in `download-wheels.sh` is deliberate and capped at
  `manylinux_2_41` (trixie's glibc 2.41): pip's `--platform` does not expand
  tags downward, and a dep tagged above 2_41 must fail the build instead of
  shipping an unusable wheel. The venv is not forward-compatible with a
  Debian that ships python 3.14+ — rebuild then.
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
- The venv is built with the `proxy`, `extra_proxy`, `saml` and `healthcheck` extras: the bare litellm CLI exits with
  "Missing dependency ... websockets".
- pip's `--platform` matches the exact PEP 600 tag (no downward expansion):
  `download-wheels.sh` passes one flag per manylinux generation
  (`manylinux2014` + `manylinux_2_24` … `manylinux_2_41`).
- Packages files must use `Filename: pool/main/litellm/...` relative to the repo root
  (`dpkg-scanpackages --arch <a> pool/main/litellm` run from the site dir).
- An arm64 venv cannot be created on an amd64 host (no qemu binfmt here);
  test the venv path with the amd64 wheels, the arm64 side in CI/dev container.

## Do not

- Commit wheels, debs, `build/wheels*`, `build/venv*`, `site/`, or any GPG key material.
- Do not change the `trixie` codename without also bumping the Python version in
  `Depends:` and `download-wheels.sh`.
- Do not add build-time network access or pip/pipx installs to `postinst`;
  everything must run from the venv shipped in the deb.
