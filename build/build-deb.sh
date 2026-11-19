#!/bin/bash
# Build the litellm .deb for one architecture from a ready venv.
# The venv (see make-venv.sh) contains litellm[proxy,extra_proxy,saml,healthcheck] and every dependency,
# so installing the deb is fully offline; dpkg tracks all of its files.
# Usage: build-deb.sh <version> <arch> <venv-dir> <out-dir>
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <version> <arch> <venv-dir> <out-dir>" >&2
    exit 2
fi

VERSION=$1
ARCH=$2
VENV=$3
OUT_DIR=$4
HERE=$(cd "$(dirname "$0")" && pwd)

[ -x "$VENV/bin/litellm" ] || { echo "venv not found or incomplete: $VENV" >&2; exit 1; }
# The venv must carry the generated Prisma client (build/generate-prisma.sh);
# without it a proxy with DATABASE_URL set dies at startup.
"$VENV/bin/python" -c 'import prisma.client' 2>/dev/null \
    || { echo "prisma client not generated in $VENV (run build/generate-prisma.sh first)" >&2; exit 1; }
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT=$STAGE/litellm_${VERSION}-1_${ARCH}

install -d -m 0755 "$ROOT/DEBIAN" "$ROOT/opt/litellm" "$ROOT/usr/bin" \
    "$ROOT/lib/systemd/system" "$ROOT/etc/litellm"

sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{ARCH}}/${ARCH}/g" \
    "$HERE/control.template" > "$ROOT/DEBIAN/control"
chmod 0644 "$ROOT/DEBIAN/control"

for script in postinst prerm postrm; do
    install -m 0755 "$HERE/$script" "$ROOT/DEBIAN/$script"
done

printf '%s\n' /etc/litellm/config.yaml /etc/litellm/litellm.env > "$ROOT/DEBIAN/conffiles"
chmod 0644 "$ROOT/DEBIAN/conffiles"

# The venv lands in /opt/litellm/venv; every file in it is tracked in
# /var/lib/dpkg/info/litellm.list by dpkg. /usr/bin/litellm is the launcher.
cp -a "$VENV" "$ROOT/opt/litellm/venv"
ln -s /opt/litellm/venv/bin/litellm "$ROOT/usr/bin/litellm"

# The Prisma engine binaries (query-engine + the Node-based prisma CLI, used
# for the startup migration diff) were generated into the final install
# location by generate-prisma.sh, because the generated client embeds those
# paths as absolute — ship the directory to exactly the same path.
PRISMA_BINARY_CACHE_DIR=${PRISMA_BINARY_CACHE_DIR:-/opt/litellm/prisma/binaries}
[ -d "$PRISMA_BINARY_CACHE_DIR" ] \
    || { echo "prisma binaries not found: $PRISMA_BINARY_CACHE_DIR (run build/generate-prisma.sh first)" >&2; exit 1; }
install -d "$ROOT/opt/litellm/prisma"
cp -a "$PRISMA_BINARY_CACHE_DIR" "$ROOT/opt/litellm/prisma/binaries"

install -m 0644 "$HERE/litellm.service" "$ROOT/lib/systemd/system/litellm.service"
install -m 0644 "$HERE/config.yaml" "$ROOT/etc/litellm/config.yaml"
install -m 0644 "$HERE/litellm.env" "$ROOT/etc/litellm/litellm.env"

# Normalize modes (the venv was built under an arbitrary umask) so the
# package is identical regardless of the builder.
chmod -R go-w "$ROOT"

# Entry-point scripts (litellm, uvicorn, ...) carry the build venv path in
# their shebangs; repoint them at the install location or they would be
# broken on the target system.
for s in "$ROOT"/opt/litellm/venv/bin/*; do
    [ -f "$s" ] && [ ! -L "$s" ] || continue
    if head -c 2 "$s" | grep -q '^#!'; then
        sed -i "1s|^#!.*bin/python[0-9.]*|#!/opt/litellm/venv/bin/python3|" "$s"
    fi
done

# md5sums: lets dpkg -V litellm verify every installed file.
(
    cd "$ROOT"
    find . -type f ! -path './DEBIAN/*' -print0 \
        | xargs -0 md5sum > DEBIAN/md5sums
)
chmod 0644 "$ROOT/DEBIAN/md5sums"

DEB=$OUT_DIR/litellm_${VERSION}-1_${ARCH}.deb
dpkg-deb --build --root-owner-group "$ROOT" "$DEB"
echo "built $DEB"
