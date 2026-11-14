# litellm-deb

Debian packages of the latest [LiteLLM](https://github.com/BerriAI/litellm) release from PyPI, for
**Ubuntu 24.04 (noble)** on **arm64** (primary target: NVIDIA DGX Spark with a local vLLM at
`http://127.0.0.1:30000/v1`) and **amd64**.

The package vendors the upstream wheel, installs it with pipx (including the `proxy` extra) into a
system venv under `/opt/litellm`, and runs the LiteLLM proxy as the `litellm` systemd service.
A weekly GitHub Actions workflow builds both debs, publishes a GitHub Release, and deploys a
GPG-signed apt repository to GitHub Pages.

## Install (client)

Replace `<GITHUB_USER>` with the account that hosts this repository.

```sh
curl -fsSL https://<GITHUB_USER>.github.io/litellm-deb/litellm-archive-keyring.gpg \
  | sudo install -D -m 0644 /dev/stdin /etc/apt/keyrings/litellm-deb.gpg
echo "deb [signed-by=/etc/apt/keyrings/litellm-deb.gpg] https://<GITHUB_USER>.github.io/litellm-deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/litellm-deb.list
sudo apt update
sudo apt install litellm
```

The postinst runs `pipx install`, which downloads LiteLLM's Python dependencies from PyPI, so the
machine needs internet access during installation.

## First-time setup (repository owner)

1. Enable Pages: Settings → Pages → Source: **GitHub Actions**.
2. Create a signing key (ed25519, no expiry):
   ```sh
   gpg --full-generate-key
   gpg --armor --export-secret-keys <fpr>
   ```
   Add the output as the repository secret `APT_GPG_PRIVATE_KEY`; if the key has a passphrase,
   add it as `APT_GPG_PASSPHRASE`. The key is required: without it the build fails instead of
   publishing an unsigned repository, so clients always pin the archive with `signed-by`.
3. Run the workflow once by hand (Actions → litellm-deb → Run workflow).

## How the weekly build works

- Runs Mondays at 06:00 UTC (and on demand).
- Reads the latest version from PyPI; if release `v<version>` already exists, it logs
  "no new litellm, skipping" and stops.
- Otherwise it downloads the `cp310-abi3-manylinux_2_28` wheels for aarch64 and x86_64, checks
  them, builds `litellm_<version>-1_arm64.deb` and `..._amd64.deb`, and creates the GitHub
  Release `v<version>` with both debs.
- Afterwards the reusable `publish-apt-repo` workflow downloads the debs from that release,
  rebuilds the GPG-signed apt repository, and deploys it to GitHub Pages. It can also be
  dispatched by hand (Actions → publish-apt-repo → Run workflow) to republish an existing
  version — e.g. after a failed deploy — so the publish logic lives in exactly one place.
- GitHub Releases keep every version. The apt repository holds only the latest one, so
  downgrading through apt is not possible; download an older deb from Releases instead.

Local build: `build/build-deb.sh <version> <arch> <wheel> <out-dir>` and
`build/build-apt-repo.sh <site-dir> <version> <deb>...` (needs `dpkg-dev` and `apt-utils`).

## Configuration

- Models: `/etc/litellm/config.yaml` (defaults to the DGX Spark vLLM at `127.0.0.1:30000`).
- Secrets and environment: `/etc/litellm/litellm.env`, e.g. `LITELLM_MASTER_KEY=...`.
- Both files are conffiles: upgrades keep your edits.
- The service listens on `127.0.0.1:4000`.

```sh
sudo systemctl restart litellm
sudo systemctl status litellm
journalctl -u litellm -f
```

## Uninstall

```sh
sudo apt purge litellm
```

`remove` deletes `/opt/litellm` and the `litellm` user; `purge` also removes `/etc/litellm`.

## Caveats

- Upstream publishes per-architecture `cp310-abi3-manylinux_2_28` wheels; the build fails loudly
  if either is missing for a release.
- `pipx` comes from noble's `universe` component; keep universe enabled.
- The Pages apt repository is public by design and contains no secrets (only the debs, indexes,
  signatures and the public key).
