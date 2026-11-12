#!/bin/bash
# Build the litellm .deb for one architecture from a vendored PyPI wheel.
# Usage: build-deb.sh <version> <arch> <wheel-path> <out-dir>
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <version> <arch> <wheel-path> <out-dir>" >&2
    exit 2
fi

VERSION=$1
ARCH=$2
WHEEL=$3
OUT_DIR=$4
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$WHEEL" ] || { echo "wheel not found: $WHEEL" >&2; exit 1; }
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT=$STAGE/litellm_${VERSION}-1_${ARCH}

install -d -m 0755 "$ROOT/DEBIAN" "$ROOT/usr/share/litellm" \
    "$ROOT/lib/systemd/system" "$ROOT/etc/litellm"

sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{ARCH}}/${ARCH}/g" \
    "$HERE/control.template" > "$ROOT/DEBIAN/control"
chmod 0644 "$ROOT/DEBIAN/control"

for script in postinst prerm postrm; do
    install -m 0755 "$HERE/$script" "$ROOT/DEBIAN/$script"
done

printf '%s\n' /etc/litellm/config.yaml /etc/litellm/litellm.env > "$ROOT/DEBIAN/conffiles"
chmod 0644 "$ROOT/DEBIAN/conffiles"

install -m 0644 "$WHEEL" "$ROOT/usr/share/litellm/$(basename "$WHEEL")"
install -m 0644 "$HERE/litellm.service" "$ROOT/lib/systemd/system/litellm.service"
install -m 0644 "$HERE/config.yaml" "$ROOT/etc/litellm/config.yaml"
install -m 0644 "$HERE/litellm.env" "$ROOT/etc/litellm/litellm.env"

DEB=$OUT_DIR/litellm_${VERSION}-1_${ARCH}.deb
dpkg-deb --build --root-owner-group "$ROOT" "$DEB"
echo "built $DEB"
