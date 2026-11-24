#!/usr/bin/env bash
# =============================================================================
# Overcast Windows Package Creator (from Linux)
# Creates dist/windows/Overcast-Windows.zip containing the Windows setup.ps1,
# package_windows.ps1, and clean frontend source ready to transfer to Windows.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
DIST_DIR="$ROOT_DIR/dist/windows"
STAGE_DIR="$DIST_DIR/Overcast-Windows"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/frontend" "$STAGE_DIR/deployment/windows"

# Copy frontend source excluding heavy Linux/Android build artifacts
tar -C "$FRONTEND_DIR" \
    --exclude='./build' \
    --exclude='./.dart_tool' \
    --exclude='./linux/flutter/ephemeral' \
    --exclude='./android/.gradle' \
    -cf - . | tar -C "$STAGE_DIR/frontend" -xf -

cp "$SCRIPT_DIR/setup.ps1" "$STAGE_DIR/setup.ps1"
cp "$SCRIPT_DIR/package_windows.ps1" "$STAGE_DIR/package_windows.ps1"
cp "$SCRIPT_DIR/setup.ps1" "$STAGE_DIR/deployment/windows/setup.ps1"
cp "$SCRIPT_DIR/package_windows.ps1" "$STAGE_DIR/deployment/windows/package_windows.ps1"

cat > "$STAGE_DIR/README.txt" <<'EOF'
OVERCAST WINDOWS CLIENT
=======================

1. Extract Overcast-Windows.zip on your Windows laptop.
2. Open PowerShell inside the extracted Overcast-Windows folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\setup.ps1

   - If pre-built Release\ binaries are present, setup.ps1 installs them immediately.
   - If transferred directly from Linux, setup.ps1 automatically runs
     `flutter build windows --release` and installs Overcast to:
     %LOCALAPPDATA%\Programs\Overcast\Overcast.exe
     with Start Menu and Desktop shortcuts.
EOF

cd "$DIST_DIR"
rm -f Overcast-Windows.zip
if command -v zip >/dev/null 2>&1; then
    zip -rq Overcast-Windows.zip Overcast-Windows
else
    python3 -c "import shutil; shutil.make_archive('Overcast-Windows', 'zip', '.', 'Overcast-Windows')"
fi

echo "Created Windows transfer archive:"
ls -lh "$DIST_DIR/Overcast-Windows.zip"
