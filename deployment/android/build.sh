#!/usr/bin/env bash
# =============================================================================
# Overcast Android Client - One-Command APK Build Script (build.sh)
#
# Checks for Flutter SDK, Android SDK, and required build components,
# resolves dependencies, runs analyzer, builds the release APK, and outputs:
#   dist/android/Overcast-Android.apk
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/pubspec.yaml" ]]; then
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -d "$SCRIPT_DIR/frontend" ]]; then
    ROOT_DIR="$SCRIPT_DIR"
else
    ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

FRONTEND_DIR="$ROOT_DIR/frontend"
DIST_DIR="$ROOT_DIR/dist/android"
LEGACY_OUT_DIR="$HOME/Documents/Cache/temp/Overcast"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[OVERCAST-ANDROID]${NC} $*"; }
ok()   { echo -e "${GREEN}[       OK       ]${NC} $*"; }
warn() { echo -e "${YELLOW}[      WARN      ]${NC} $*"; }
err()  { echo -e "${RED}[     ERROR      ]${NC} $*" >&2; }

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

find_android_sdk() {
    if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]]; then
        echo "$ANDROID_HOME"
        return 0
    fi
    if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}" ]]; then
        echo "$ANDROID_SDK_ROOT"
        return 0
    fi
    if [[ -f "$FRONTEND_DIR/android/local.properties" ]]; then
        local sdk_dir
        sdk_dir="$(grep '^sdk.dir=' "$FRONTEND_DIR/android/local.properties" | cut -d'=' -f2- || true)"
        if [[ -n "$sdk_dir" && -d "$sdk_dir" ]]; then
            echo "$sdk_dir"
            return 0
        fi
    fi
    for candidate in \
        "/opt/android-sdk" \
        "$HOME/Android/Sdk" \
        "$HOME/Library/Android/sdk"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

info "Checking Flutter SDK..."
FLUTTER_BIN="$(find_flutter || true)"
if [[ -z "$FLUTTER_BIN" ]]; then
    err "Flutter SDK not found. Please install Flutter or set flutter.sdk in frontend/android/local.properties."
    exit 1
fi
export PATH="$(dirname "$FLUTTER_BIN"):$PATH"
ok "Found Flutter: $FLUTTER_BIN"

info "Checking Android SDK..."
ANDROID_SDK="$(find_android_sdk || true)"
if [[ -z "$ANDROID_SDK" ]]; then
    err "Android SDK not found. Please set ANDROID_HOME or sdk.dir in frontend/android/local.properties."
    exit 1
fi
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
ok "Found Android SDK: $ANDROID_SDK"

for component in "platform-tools" "build-tools" "platforms"; do
    if [[ ! -d "$ANDROID_SDK/$component" ]]; then
        err "Missing required Android SDK component directory: $ANDROID_SDK/$component"
        exit 1
    fi
done
ok "Verified Android SDK components (platform-tools, build-tools, platforms)."

cd "$FRONTEND_DIR"

info "Resolving Flutter packages..."
"$FLUTTER_BIN" pub get

info "Running Flutter analyzer..."
"$FLUTTER_BIN" analyze

info "Building release APK..."
"$FLUTTER_BIN" build apk --release

APK_SRC="$FRONTEND_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK_SRC" ]]; then
    err "Expected APK output not found at $APK_SRC"
    exit 1
fi

mkdir -p "$DIST_DIR"
cp "$APK_SRC" "$DIST_DIR/Overcast-Android.apk"

# Also copy to legacy output folder if writable
if mkdir -p "$LEGACY_OUT_DIR" 2>/dev/null; then
    cp "$APK_SRC" "$LEGACY_OUT_DIR/Overcast-Android.apk" 2>/dev/null || true
fi

APK_SIZE="$(du -h "$DIST_DIR/Overcast-Android.apk" | awk '{print $1}')"
APK_SHA="$(sha256sum "$DIST_DIR/Overcast-Android.apk" | awk '{print $1}')"

echo
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}                OVERCAST ANDROID APK BUILD COMPLETE                   ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo "  APK Output Path:  $DIST_DIR/Overcast-Android.apk"
echo "  APK Size:         $APK_SIZE"
echo "  SHA-256:          $APK_SHA"
echo -e "${GREEN}======================================================================${NC}"

