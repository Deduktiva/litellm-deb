#!/bin/bash
# Build a flat-ish apt repository (dists/stable/main) for GitHub Pages.
# Usage: build-apt-repo.sh <site-dir> <version> <deb> [<deb> ...]
# Env (optional): APT_GPG_PRIVATE_KEY (ASCII-armored secret key),
#                 APT_GPG_PASSPHRASE (its passphrase, if any).
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <site-dir> <version> <deb> [<deb> ...]" >&2
    exit 2
fi

SITE=$1
VERSION=$2
shift 2
DEBS=("$@")

mkdir -p "$SITE"
SITE=$(cd "$SITE" && pwd)
POOL=$SITE/pool/main/litellm
DIST=$SITE/dists/stable
mkdir -p "$POOL"

for deb in "${DEBS[@]}"; do
    [ -f "$deb" ] || { echo "deb not found: $deb" >&2; exit 1; }
    cp "$deb" "$POOL/"
done

# Architectures from the debs themselves
ARCHS=()
for deb in "${DEBS[@]}"; do
    a=$(dpkg-deb -f "$deb" Architecture)
    case " ${ARCHS[*]-} " in *" $a "*) ;; *) ARCHS+=("$a") ;; esac
done

for a in "${ARCHS[@]}"; do
    BIN=$DIST/main/binary-$a
    mkdir -p "$BIN"
    # Filename paths are relative to the repository root; --arch keeps each
    # Packages file to its own architecture
    (cd "$SITE" && dpkg-scanpackages --multiversion --arch "$a" pool/main/litellm /dev/null) \
        > "$BIN/Packages"
    gzip -9 -k -f "$BIN/Packages"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=zeha \
    -o APT::FTPArchive::Release::Label=litellm-deb \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Architectures=${ARCHS[*]}" \
    -o "APT::FTPArchive::Release::Description=litellm ${VERSION} packaged from PyPI" \
    release "$DIST" > "$SITE/Release.tmp"
mv "$SITE/Release.tmp" "$DIST/Release"

touch "$SITE/.nojekyll"
cat > "$SITE/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>litellm-deb apt repository</title></head>
<body>
<h1>litellm-deb</h1>
<p>LiteLLM ${VERSION} from PyPI, packaged for Ubuntu 24.04 (noble), architectures: ${ARCHS[*]}.</p>
<pre>
# &lt;this-url&gt; is the address of this page, e.g. https://USER.github.io/litellm-deb
curl -fsSL &lt;this-url&gt;/litellm-archive-keyring.gpg | sudo install -D -m 0644 /dev/stdin /etc/apt/keyrings/litellm-deb.gpg
echo "deb [signed-by=/etc/apt/keyrings/litellm-deb.gpg] &lt;this-url&gt;/ stable main" | sudo tee /etc/apt/sources.list.d/litellm-deb.list
sudo apt update &amp;&amp; sudo apt install litellm
</pre>
</body></html>
HTML

if [ -n "${APT_GPG_PRIVATE_KEY:-}" ]; then
    GNUPGHOME=$(mktemp -d)
    export GNUPGHOME
    chmod 700 "$GNUPGHOME"
    cleanup_gpg() {
        gpgconf --kill all >/dev/null 2>&1 || true
        find "$GNUPGHOME" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$GNUPGHOME"
    }
    trap cleanup_gpg EXIT
    gpg-agent --homedir "$GNUPGHOME" --allow-loopback-pinentry --daemon \
        >"$GNUPGHOME/agent.log" 2>&1 </dev/null || true

    printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import
    FPR=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "$FPR" ] || { echo "no secret key imported" >&2; exit 1; }

    GPG_SIGN=(gpg --batch --yes --pinentry-mode loopback --local-user "$FPR")
    if [ -n "${APT_GPG_PASSPHRASE:-}" ]; then
        GPG_SIGN+=(--passphrase-fd 0)
        sign() { printf '%s' "$APT_GPG_PASSPHRASE" | "${GPG_SIGN[@]}" "$@"; }
    else
        sign() { "${GPG_SIGN[@]}" "$@" </dev/null; }
    fi
    sign --clearsign -o "$DIST/InRelease" "$DIST/Release"
    sign --detach-sign --armor -o "$DIST/Release.gpg" "$DIST/Release"

    gpg --batch --armor --export "$FPR" > "$SITE/litellm-archive-keyring.asc"
    # apt accepts armored keys in signed-by files when named .asc; also ship a
    # binary keyring under .gpg for the documented install path
    gpg --batch --export "$FPR" > "$SITE/litellm-archive-keyring.gpg"
    echo "signed repository with key $FPR"
else
    cat >&2 <<'WARN'
################################################################
# WARNING: APT_GPG_PRIVATE_KEY is not set.                     #
# The repository is UNSIGNED. Clients must use [trusted=yes].  #
################################################################
WARN
fi

echo "apt repository ready in $SITE (archs: ${ARCHS[*]})"
