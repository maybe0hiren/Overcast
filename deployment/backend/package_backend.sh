#!/usr/bin/env bash
# =============================================================================
# Overcast Backend Packager
# Packages the self-contained Docker backend directory into:
#   dist/backend/Overcast-Backend.zip
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_SRC="$ROOT_DIR/backend"
DIST_DIR="$ROOT_DIR/dist/backend"
STAGE_DIR="$DIST_DIR/Overcast-Backend"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/database" "$STAGE_DIR/functions"

cp "$BACKEND_SRC/main.py" "$STAGE_DIR/"
cp "$BACKEND_SRC/run.py" "$STAGE_DIR/"
cp "$BACKEND_SRC/requirements.txt" "$STAGE_DIR/"
cp "$BACKEND_SRC/Dockerfile" "$STAGE_DIR/"
cp "$BACKEND_SRC/docker-compose.yml" "$STAGE_DIR/"
cp "$BACKEND_SRC/.env.example" "$STAGE_DIR/"
cp "$BACKEND_SRC/.dockerignore" "$STAGE_DIR/"
cp "$BACKEND_SRC/setup.sh" "$STAGE_DIR/"
if [[ -f "$BACKEND_SRC/README.md" ]]; then
    cp "$BACKEND_SRC/README.md" "$STAGE_DIR/"
fi

cp "$BACKEND_SRC/database/"*.py "$STAGE_DIR/database/"
cp "$BACKEND_SRC/functions/"*.py "$STAGE_DIR/functions/"
chmod +x "$STAGE_DIR/setup.sh"

cd "$DIST_DIR"
rm -f Overcast-Backend.zip Overcast-Backend.tar.gz
if command -v zip >/dev/null 2>&1; then
    zip -rq Overcast-Backend.zip Overcast-Backend
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import shutil; shutil.make_archive('Overcast-Backend', 'zip', '.', 'Overcast-Backend')"
fi
tar -czf Overcast-Backend.tar.gz Overcast-Backend

echo "Created self-contained backend deployment archives:"
ls -lh "$DIST_DIR"/Overcast-Backend.*

