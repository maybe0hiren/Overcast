#!/usr/bin/env bash
# =============================================================================
# Overcast Linux Client - Build & Release Packaging Script
# Builds the Flutter Linux release bundle and packages it with setup.sh into:
#   dist/linux/Overcast-Linux.zip
#   dist/linux/Overcast-Linux.tar.gz
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
DIST_DIR="$ROOT_DIR/dist/linux"
STAGE_DIR="$DIST_DIR/Overcast-Linux"

find_flutter() {
    if command -v flutter >/dev/null 2>&1; then
        command -v flutter
        return 0
    fi
    for candidate in \
        "/home/Hiren/develop/flutter/bin/flutter" \
        "$HOME/develop/flutter/bin/flutter" \
        "$HOME/flutter/bin/flutter" \
        "/opt/flutter/bin/flutter"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    if [[ -f "$FRONTEND_DIR/android/local.properties" ]]; then
        local sdk_path
        sdk_path="$(grep '^flutter.sdk=' "$FRONTEND_DIR/android/local.properties" | cut -d'=' -f2- || true)"
        if [[ -n "$sdk_path" && -x "$sdk_path/bin/flutter" ]]; then
            echo "$sdk_path/bin/flutter"
            return 0
        fi
    fi
    return 1
}

FLUTTER_BIN="$(find_flutter || true)"
if [[ -z "$FLUTTER_BIN" ]]; then
    echo "[ERROR] Flutter SDK not found. Install Flutter or add it to PATH." >&2
    exit 1
fi

echo "Using Flutter: $FLUTTER_BIN"
cd "$FRONTEND_DIR"

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" analyze
"$FLUTTER_BIN" test
"$FLUTTER_BIN" build linux --release

BUNDLE_SRC="$FRONTEND_DIR/build/linux/x64/release/bundle"
if [[ ! -d "$BUNDLE_SRC" ]]; then
    echo "[ERROR] Linux release bundle not found at $BUNDLE_SRC" >&2
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bundle"

cp -a "$BUNDLE_SRC/." "$STAGE_DIR/bundle/"
cp "$SCRIPT_DIR/setup.sh" "$STAGE_DIR/setup.sh"
chmod +x "$STAGE_DIR/setup.sh"

cat > "$STAGE_DIR/README.txt" <<'EOF'
OVERCAST LINUX CLIENT
=====================

Installation (No Flutter or development tools required):

1. Open a terminal in this extracted folder.
2. Run:

   ./setup.sh

3. Launch Overcast from your desktop application launcher or run:

   ~/.local/bin/overcast
EOF

cd "$DIST_DIR"
rm -f Overcast-Linux.tar.gz Overcast-Linux.zip
tar -czf Overcast-Linux.tar.gz Overcast-Linux
if command -v zip >/dev/null 2>&1; then
    zip -rq Overcast-Linux.zip Overcast-Linux
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import shutil; shutil.make_archive('Overcast-Linux', 'zip', '.', 'Overcast-Linux')"
fi

echo
echo "Linux client package created:"
ls -lh "$DIST_DIR"/Overcast-Linux.*
