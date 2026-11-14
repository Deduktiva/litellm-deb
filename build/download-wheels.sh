#!/bin/bash
# Download the full litellm[proxy] wheel closure for one target architecture
# from PyPI. Network access is needed here (and only here); everything after
# this step is offline.
# Target: Debian 13 (trixie, glibc 2.41), CPython 3.13.
# Usage: download-wheels.sh <version> <arch> <dest-dir>
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <version> <arch> <dest-dir>" >&2
    exit 2
fi
VERSION=$1
ARCH=$2
DEST=$3

case $ARCH in
    amd64) A=x86_64 ;;
    arm64) A=aarch64 ;;
    *) echo "arch must be amd64 or arm64" >&2; exit 2 ;;
esac
# Cross-platform pip download. PYTHON selects the interpreter running pip
# (default: the system python3, which has pip on the CI runner and in the
# dev container); its version does not matter, only --python-version does.
PYTHON=${PYTHON:-python3}
mkdir -p "$DEST"

# pip's --platform matches the exact PEP 600 tag and does NOT expand
# manylinux_2_N downward, so list every generation trixie's glibc 2.41 can
# run: the legacy alias (which expands to manylinux2010/manylinux1) plus
# manylinux_2_24 .. manylinux_2_41. Anything tagged above 2_41 would not run
# on trixie, so it is deliberately not listed and the build fails loudly if
# a dependency ever requires it.
PLATS=(manylinux2014_${A})
for n in $(seq 24 41); do
    PLATS+=(manylinux_2_${n}_${A})
done
ARGS=()
for p in "${PLATS[@]}"; do
    ARGS+=(--platform "$p")
done

"$PYTHON" -m pip download "litellm[proxy]==${VERSION}" \
    --dest "$DEST" \
    --only-binary=:all: \
    --python-version 313 \
    "${ARGS[@]}"

echo "downloaded $(ls "$DEST" | wc -l) wheels to $DEST"
