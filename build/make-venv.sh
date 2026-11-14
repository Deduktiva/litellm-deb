#!/bin/bash
# Create the packaged venv from the downloaded wheels. Runs on Debian 13
# (its python3 is 3.13, the target interpreter) and needs no network:
# --no-index installs exclusively from the wheels dir.
# Usage: make-venv.sh <version> <wheels-dir> <venv-dir>
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <version> <wheels-dir> <venv-dir>" >&2
    exit 2
fi
VERSION=$1
WHEELS=$2
VENV=$3

[ -d "$WHEELS" ] || { echo "wheels dir not found: $WHEELS" >&2; exit 1; }

# The venv must be created with the target's interpreter (trixie's python3,
# 3.13). In CI/dev container that is the system python3; override with
# PYTHON3 to test elsewhere.
PYTHON3=${PYTHON3:-python3}
[ "$("$PYTHON3" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')" = "3.13" ] || {
    echo "make-venv.sh needs the Debian 13 python3 (3.13); found $("$PYTHON3" --version 2>&1)" >&2
    exit 1
}

rm -rf "$VENV"
"$PYTHON3" -m venv "$VENV"

# The venv's own pip performs this offline install only; it is uninstalled
# again below so the deb ships no package manager.
"$VENV/bin/pip" install --no-index --find-links "$WHEELS" "litellm[proxy]==${VERSION}"

# Smoke test: the entry point must run against this venv.
"$VENV/bin/litellm" --version

# Strip pip and setuptools from the venv, then the pyc caches.
"$VENV/bin/python" -m pip uninstall -y pip setuptools
find "$VENV" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$VENV" -name '*.pyc' -delete

echo "venv ready: $VENV"
