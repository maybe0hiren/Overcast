#!/usr/bin/env bash
# =============================================================================
# Overcast Full Release Builder
# Builds and packages Backend, Linux Client, and Android APK into dist/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================"
echo "       OVERCAST RELEASE BUILDER"
echo "======================================"

echo
echo "[1/3] Packaging Docker Backend..."
"$ROOT_DIR/deployment/backend/package_backend.sh"

echo
echo "[2/3] Building & Packaging Linux Client..."
"$ROOT_DIR/deployment/linux/package_linux.sh"

echo
echo "[3/3] Building Android Release APK..."
"$ROOT_DIR/deployment/android/build.sh"

echo
echo "======================================"
echo "          BUILD COMPLETE"
echo "======================================"
ls -lh "$ROOT_DIR/dist/backend" "$ROOT_DIR/dist/linux" "$ROOT_DIR/dist/android"
