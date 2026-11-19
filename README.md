# litellm-deb

Weekly Debian packages for [LiteLLM](https://github.com/BerriAI/litellm):
the latest release from PyPI, repackaged for Debian 13 (trixie), with a
self-hosted apt repository as the distribution channel.

**Why**: LiteLLM is an actively developed Python project. On Debian 13 it can
also be installed with pip, but that pulls in Python 3.13 build dependencies
(`python3-dev`, `python3-setuptools`, …) — heavy and easy to get wrong — and
there is no official or third-party .deb for LiteLLM. This repo produces one,
weekly, from the canonical PyPI release.

- **Target**: Debian 13 (trixie), amd64 **and** arm64 (e.g. an NVIDIA DGX
  Spark as a plain Debian machine)
- **Source**: `litellm[proxy]` from PyPI, pinned to the latest release at build time
- **Install**: one `apt install` — fully offline, no pip, no pipx
- **Upgrade**: `apt upgrade` — the same path as any other package
- **Repo**: `https://deduktiva.github.io/litellm-deb/` (GitHub Pages, GPG-signed)
- **Release**: GitHub release per litellm version (both .debs)

## What the package does

The deb contains a **complete Python venv** under `/opt/litellm/venv` with
`litellm[proxy]` and every one of its dependencies (117 wheels for
1.109.1). Because the venv is part of the package, `dpkg -i` / `apt install`
needs **no network access** — no PyPI, no pip, no pipx — and dpkg tracks
**every** installed file (visible in `/var/lib/dpkg/info/litellm.list`), so
`dpkg -V litellm` works and an upgrade replaces the whole tree cleanly.

- `/usr/bin/litellm` — launcher (symlink into the venv)
- `/opt/litellm/venv/` — the venv (installed by dpkg, no pip inside), with
  the generated Prisma client baked in
- `/opt/litellm/prisma/binaries/` — Prisma query-engine binaries + the Node
  prisma CLI (built-in by `prisma generate` at build time; used for the
  startup migration diff, hence the `nodejs` dependency)
- `/etc/litellm/config.yaml` — proxy config, pointing at vLLM
  (`http://127.0.0.1:30000/v1`, model `qwen`)
- `/etc/litellm/litellm.env` — environment, e.g. `LITELLM_MASTER_KEY`
- `litellm.service` — systemd unit, runs the proxy on `127.0.0.1:4000`
  as user `litellm` (created by the package)
- conffiles are kept on removal; the config survives upgrades

The venv's interpreter is a symlink to the distro's `/usr/bin/python3.13`,
so the package depends on `python3.13` (trixie's current Python). It is
**not** forward-compatible with a Debian that ships 3.14+; rebuild for that.

## Install

```sh
sudo apt-get update
sudo apt-get install -y curl gpg
curl -fsSL https://deduktiva.github.io/litellm-deb/pubkey.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/litellm-deb.gpg
echo "deb [signed-by=/etc/apt/keyrings/litellm-deb.gpg] https://deduktiva.github.io/litellm-deb/ trixie main" \
  | sudo tee /etc/apt/sources.list.d/litellm-deb.list
sudo apt-get update
sudo apt-get install -y litellm
```

`Depends: python3, python3.13, systemd` resolve from the trixie main repository.

The service starts immediately (port 4000). Point `api_base` at your vLLM
in `/etc/litellm/config.yaml`, then `sudo systemctl restart litellm`.

## Usage

```sh
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "qwen", "messages": [{"role": "user", "content": "Say hi"}]}'
```

Manage it like any service:

```sh
systemctl status litellm
journalctl -u litellm -f
```

## Upgrade

```sh
sudo apt-get update
sudo apt-get install -y --only-upgrade litellm
```

The venv is replaced in place and the service restarted by the package.
There is nothing to clean up by hand — no pipx venv, no leftover files.
If a dependency ever needs a rebuild against a newer glibc, the build fails
loudly (see below) instead of shipping a wheel that cannot run on trixie.

## Build pipeline

```
GitHub Actions (weekly 18:42 Europe/Vienna + manual dispatch)
  1. resolve latest litellm on PyPI (must have manylinux_2_28 wheels for
     x86_64 and aarch64; else abort with a clear message)
  2. skip if that version is already released
  3. download the full litellm[proxy] wheel closure per architecture —
     cross-platform pip download, the only PyPI access in the pipeline
  4. in a debian:trixie container (arm64 under qemu):
     create the venv with python3.13, install the closure offline
     (--no-index --find-links), smoke-test the entry point, strip pip,
     bake the Prisma client in (`prisma generate`, the only other network
     access — the wheels ship the schema but not the generated client),
     assemble the .deb (dpkg-deb)
  5. verify: metadata, key paths, no pip/pipx in the deb, and an
     end-to-end dpkg -i + litellm --version + Prisma round-trip against a
     real PostgreSQL in a fresh trixie container
  6. GitHub release v<version> with both .debs
  7. rebuild dists/ + pool/ from the release, sign with the repo key,
     deploy to GitHub Pages
```

`build/` holds the pieces:

| file | role |
|---|---|
| `download-wheels.sh` | `pip download` of the full closure for one arch (offline afterwards) |
| `make-venv.sh` | venv creation + offline `pip install --no-index` + entry-point smoke test |
| `generate-prisma.sh` | `prisma generate`: bakes the generated Prisma client into the venv and the query-engine + Node CLI binaries into `/opt/litellm/prisma/binaries` (needs nodejs+npm, network) |
| `build-deb.sh` | assembles the .deb from the venv (layout, control, conffiles) |
| `control.template` | package metadata |
| `postinst` / `prerm` / `postrm` | user, service enable/start/stop, cleanup |
| `litellm.service` | systemd unit |
| `config.yaml`, `litellm.env` | default conffiles |
| `signing.key` | GPG key **private part**, used to sign the apt repo |
| `build-apt-repo.sh` | builds `dists/` + `pool/` from the release artifacts |
| `expected-release-files.txt` | canonical file list for the repo |

The manylinux tag list in `download-wheels.sh` is deliberate: pip's
`--platform` matches exact PEP 600 tags and does not expand downward, so the
script lists every generation trixie's glibc 2.41 can run
(`manylinux2014`, `manylinux_2_24` … `manylinux_2_41`). A dependency tagged
above 2_41 cannot run on trixie and will fail the build instead of
quietly downloading an unusable wheel.

## Test locally

```sh
# build one architecture (needs Debian 13 for make-venv.sh, nodejs+npm for
# generate-prisma.sh):
build/download-wheels.sh 1.109.1 amd64 build/wheels-amd64
build/make-venv.sh 1.109.1 build/wheels-amd64 build/venv-amd64
build/generate-prisma.sh build/venv-amd64
build/build-deb.sh 1.109.1 amd64 build/venv-amd64 dist
dpkg -i dist/litellm_1.109.1-1_amd64.deb && litellm --version && dpkg -V litellm

# build the apt repo from an existing release:
build/build-apt-repo.sh 1.109.1 /path/to/release-assets
cd site && python3 -m http.server 8000   # inspect
```

The devcontainer for this (Debian 13 + dpkg-dev + apt-utils + gnupg2 +
python3-venv + nodejs/npm) is defined in `Dockerfile.dev` /
`.owncore/devenv.yml`.

## Repository

```
sources.list:
deb [signed-by=/etc/apt/keyrings/litellm-deb.gpg] https://deduktiva.github.io/litellm-deb/ trixie main
```

- amd64 + arm64, `Codename: trixie`
- signed with `build/signing.key` (fingerprint in `pubkey.gpg`)
- `Release`, `Release.gpg`, `InRelease`, per-package `.deb` + `.releases`
  under `pool/main/l/`
- `index.html` lists the current version, fingerprint and install steps

## Security notes

- `build/signing.key` **contains the private key**. It is committed to this
  repository so the CI can sign. Anyone with write access to the repo can
  therefore sign the apt repository. For a public distribution this should
  move to a GitHub Actions secret (key in CI only) — accepted risk while
  the repo is private/low-traffic.
- The apt repo is served over HTTPS only (GitHub Pages); the GPG signature
  is the trust anchor, `pubkey.gpg` the public trust.

## Do not

- Do not change the `trixie` codename without also bumping the Python
  version in `Depends:` and the `--python-version` in `download-wheels.sh`.
- Do not add build-time pip installs to `postinst` (that reintroduces the
  PyPI dependency and untracked files); ship everything in the venv.
- Do not commit `*.deb`, `build/wheels*`, `build/venv*`, or `site/`.
