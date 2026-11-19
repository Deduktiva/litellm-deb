#!/bin/bash
# Bake the Prisma client into the venv. Build-time codegen the wheels do not
# ship: the litellm wheel carries only the schema (litellm/proxy/schema.prisma)
# and the bare prisma package; the generated client (prisma/client.py,
# models.py, types.py, ...) and the native query-engine binaries appear only
# after running `prisma generate` — the same build step LiteLLM's Docker image
# performs in its builder stage. Without it, a proxy with DATABASE_URL set
# dies at startup with "The Client hasn't been generated yet".
#
# The generated client records the engine binary locations as absolute paths,
# so generate with PRISMA_BINARY_CACHE_DIR set to the final install location.
# build-deb.sh ships that directory to the same path in the deb, so nothing
# has to be relinked at install time and the runtime stays fully offline.
#
# Needs network (Prisma CLI + engine download — a build-time step like
# download-wheels.sh), plus nodejs and npm (the prisma CLI is a Node CLI and
# the generator invokes the venv's prisma-client-py console script).
# Usage: generate-prisma.sh <venv-dir>
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <venv-dir>" >&2
    exit 2
fi
VENV=$1
# Final install location of the engine binaries (shipped in the deb, see
# build-deb.sh). Override only for special builds.
PRISMA_BINARY_CACHE_DIR=${PRISMA_BINARY_CACHE_DIR:-/opt/litellm/prisma/binaries}

[ -x "$VENV/bin/prisma" ] || { echo "venv not found or missing the prisma CLI: $VENV" >&2; exit 1; }
for t in node npm; do
    command -v "$t" >/dev/null || { echo "generate-prisma.sh needs $t on PATH" >&2; exit 1; }
done

SCHEMA=$("$VENV/bin/python" -c 'import litellm, os; print(os.path.join(os.path.dirname(litellm.__file__), "proxy", "schema.prisma"))')
[ -f "$SCHEMA" ] || { echo "litellm schema not found: $SCHEMA" >&2; exit 1; }

# The JS generator calls the prisma-client-py console script, so the venv's
# bin directory must be on PATH.
export PATH="$VENV/bin:$PATH"
export PRISMA_BINARY_CACHE_DIR

# Start clean so a rerun never mixes binaries of different prisma versions.
rm -rf "$PRISMA_BINARY_CACHE_DIR"
mkdir -p "$(dirname "$PRISMA_BINARY_CACHE_DIR")"
"$VENV/bin/prisma" generate --schema "$SCHEMA"

# The client must have been generated into the venv's prisma package, and
# every recorded engine path must live inside $PRISMA_BINARY_CACHE_DIR.
"$VENV/bin/python" - <<'PY'
import os
from pathlib import Path
from prisma import client as c
sp = Path(c.__file__).parent
assert (sp / "client.py").is_file(), "prisma client was not generated into the venv package"
assert (sp / "schema.prisma").is_file(), "packaged schema missing from the prisma package"
root = os.path.realpath(os.environ["PRISMA_BINARY_CACHE_DIR"])
for target, path in c.BINARY_PATHS.query_engine.items():
    assert os.path.realpath(path).startswith(root + os.sep), (target, path)
    assert os.path.isfile(path), (target, path)
print(f"prisma client baked: {len(c.BINARY_PATHS.query_engine)} engine target(s)")
PY

echo "prisma client ready: $VENV, binaries in $PRISMA_BINARY_CACHE_DIR"
