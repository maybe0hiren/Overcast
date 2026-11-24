#!/usr/bin/env bash
# =============================================================================
# Overcast Linux Desktop Client - One-Command User-Level Installer
#
# Installs the pre-built Overcast Linux application bundle into:
#   ~/.local/share/Overcast
# Creates:
#   ~/.local/bin/overcast (CLI launcher)
#   ~/.local/share/applications/overcast.desktop (Desktop menu entry)
#   ~/.local/share/icons/hicolor/scalable/apps/overcast.svg (Application icon)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[OVERCAST-LINUX]${NC} $*"; }
ok()   { echo -e "${GREEN}[      OK      ]${NC} $*"; }
warn() { echo -e "${YELLOW}[     WARN     ]${NC} $*"; }
err()  { echo -e "${RED}[    ERROR     ]${NC} $*" >&2; }

# Locate the Flutter Linux release bundle
BUNDLE_DIR=""
for candidate in \
    "$SCRIPT_DIR/bundle" \
    "$SCRIPT_DIR/Overcast" \
    "$SCRIPT_DIR" \
    "$SCRIPT_DIR/../../frontend/build/linux/x64/release/bundle"; do
    if [[ -d "$candidate/lib" && -d "$candidate/data" ]]; then
        BUNDLE_DIR="$(cd "$candidate" && pwd)"
        break
    fi
done

if [[ -z "$BUNDLE_DIR" ]]; then
    err "Could not find the Overcast Linux release bundle (lib/ and data/ directories)."
    err "Make sure you extracted the entire Overcast-Linux package before running ./setup.sh."
    exit 1
fi

# Detect binary name inside bundle (overcast or frontend)
BIN_NAME=""
for bin_candidate in "overcast" "frontend"; do
    if [[ -f "$BUNDLE_DIR/$bin_candidate" ]]; then
        BIN_NAME="$bin_candidate"
        break
    fi
done

if [[ -z "$BIN_NAME" ]]; then
    err "Could not find the Overcast executable inside $BUNDLE_DIR"
    exit 1
fi

check_runtime_dependencies() {
    info "Checking required Linux GTK3 and media runtime libraries..."
    local missing=()
    if command -v ldconfig >/dev/null 2>&1; then
        if ! ldconfig -p 2>/dev/null | grep -q "libgtk-3.so"; then
            missing+=("libgtk-3-0")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing system libraries: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
            info "Installing missing runtime dependencies via apt-get..."
            sudo apt-get update -y && sudo apt-get install -y "${missing[@]}" xdg-utils || true
        else
            warn "Please install GTK3 runtime libraries using your distribution's package manager."
        fi
    else
        ok "GTK3 runtime libraries are present."
    fi
}

install_application() {
    local install_dir="$HOME/.local/share/Overcast"
    local bin_dir="$HOME/.local/bin"
    local apps_dir="$HOME/.local/share/applications"
    local icon_dir="$HOME/.local/share/icons/hicolor/scalable/apps"

    info "Installing Overcast Linux Client to $install_dir..."

    # Stop any running instance safely before upgrading files
    pkill -f "$install_dir/$BIN_NAME" 2>/dev/null || true

    mkdir -p "$install_dir" "$bin_dir" "$apps_dir" "$icon_dir"

    # Copy all runtime files (executable, lib/*.so, data/flutter_assets)
    cp -a "$BUNDLE_DIR/." "$install_dir/"
    chmod +x "$install_dir/$BIN_NAME"

    # Create or copy SVG application icon
    cat > "$icon_dir/overcast.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#7AA2F7"/>
      <stop offset="100%" stop-color="#9B8AFB"/>
    </linearGradient>
  </defs>
  <rect width="128" height="128" rx="28" fill="#070B16"/>
  <rect x="8" y="8" width="112" height="112" rx="24" fill="url(#g)" fill-opacity="0.18" stroke="#7AA2F7" stroke-width="3"/>
  <path d="M42 84h46a18 18 0 0 0 2-35.9A25 25 0 0 0 42.3 43 20 20 0 0 0 42 84z" fill="url(#g)"/>
</svg>
SVG
    cp "$icon_dir/overcast.svg" "$install_dir/overcast.svg"

    # Create launcher wrapper script in ~/.local/bin/overcast
    cat > "$bin_dir/overcast" <<EOF
#!/usr/bin/env bash
cd "$install_dir"
exec "$install_dir/$BIN_NAME" "\$@"
EOF
    chmod +x "$bin_dir/overcast"

    # Create XDG Desktop Entry
    cat > "$apps_dir/overcast.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Overcast
Comment=Self-Hosted LAN Cloud Storage Client
Exec=$install_dir/$BIN_NAME
Path=$install_dir
Icon=$install_dir/overcast.svg
Terminal=false
Categories=Utility;Network;FileTools;
StartupNotify=true
StartupWMClass=$BIN_NAME
EOF
    chmod +x "$apps_dir/overcast.desktop"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    fi

    ok "Overcast installed to: $install_dir"
    ok "Launcher command created: $bin_dir/overcast"
    ok "Desktop entry created: $apps_dir/overcast.desktop"
    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}            OVERCAST LINUX CLIENT INSTALLATION COMPLETE               ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo "  Launch from terminal:  $bin_dir/overcast"
    echo "  Or launch 'Overcast' directly from your desktop application menu."
    echo -e "${GREEN}======================================================================${NC}"
}

check_runtime_dependencies
install_application

