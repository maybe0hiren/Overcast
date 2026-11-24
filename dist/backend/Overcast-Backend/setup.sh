#!/usr/bin/env bash
# =============================================================================
# Overcast Backend - One-Command Docker Deployment & Management Script
# Target OS: Debian / Ubuntu Linux (and general Linux with Docker)
#
# Usage:
#   ./setup.sh            # Full initial setup or idempotent upgrade
#   ./setup.sh start      # Start the Overcast backend container
#   ./setup.sh stop       # Stop the Overcast backend container
#   ./setup.sh restart    # Restart the Overcast backend container
#   ./setup.sh logs       # Follow backend container logs
#   ./setup.sh status     # Show container status, health, and LAN address
#   ./setup.sh update     # Rebuild container image and restart (preserves data)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support running either directly inside backend/ or from a parent wrapper directory
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    BACKEND_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/backend/docker-compose.yml" ]]; then
    BACKEND_DIR="$SCRIPT_DIR/backend"
else
    echo "[ERROR] Could not locate docker-compose.yml in $SCRIPT_DIR"
    exit 1
fi

cd "$BACKEND_DIR"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${BLUE}[OVERCAST]${NC} $*"; }
ok()    { echo -e "${GREEN}[   OK   ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[  WARN  ]${NC} $*"; }
err()   { echo -e "${RED}[ ERROR  ]${NC} $*" >&2; }

run_privileged() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        err "Root privileges are required to run: $*"
        exit 1
    fi
}

detect_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
    fi
    if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    echo "${ip:-127.0.0.1}"
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            docker compose "$@"
        else
            run_privileged docker compose "$@"
        fi
    elif command -v docker-compose >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            docker-compose "$@"
        else
            run_privileged docker-compose "$@"
        fi
    else
        err "Docker Compose is not installed."
        exit 1
    fi
}

ensure_dependencies_and_docker() {
    info "Checking environment and system packages..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        info "Detected OS: ${PRETTY_NAME:-Linux}"
    fi

    local missing_pkgs=()
    for cmd_pkg in "curl:curl" "ip:iproute2" "sqlite3:sqlite3"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]] && command -v apt-get >/dev/null 2>&1; then
        info "Installing required system utilities: ${missing_pkgs[*]}..."
        run_privileged apt-get update -y
        run_privileged apt-get install -y --no-install-recommends \
            ca-certificates curl gnupg lsb-release "${missing_pkgs[@]}"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        info "Docker not found. Installing Docker Engine..."
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update -y
            run_privileged apt-get install -y ca-certificates curl gnupg
            if ! run_privileged apt-get install -y docker.io docker-compose-plugin 2>/dev/null; then
                if ! run_privileged apt-get install -y docker.io docker-compose-v2 2>/dev/null; then
                    info "Installing Docker via official convenience script..."
                    curl -fsSL https://get.docker.com | run_privileged sh
                fi
            fi
        else
            err "Automatic Docker installation requires apt-get (Debian/Ubuntu). Please install Docker manually."
            exit 1
        fi
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        info "Installing Docker Compose plugin..."
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update -y
            run_privileged apt-get install -y docker-compose-plugin || \
                run_privileged apt-get install -y docker-compose-v2 || \
                run_privileged apt-get install -y docker-compose
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        info "Ensuring Docker service is running and enabled on boot..."
        run_privileged systemctl enable --now docker || true
    fi

    ok "Docker and Docker Compose are ready."
}

prepare_persistent_data() {
    info "Preparing persistent data directories..."

    if [[ ! -f "$BACKEND_DIR/.env" ]]; then
        cp "$BACKEND_DIR/.env.example" "$BACKEND_DIR/.env"
        ok "Created .env from .env.example"
    else
        ok "Preserving existing .env configuration"
    fi

    # Load OVERCAST_DATA_DIR from .env
    local data_dir
    data_dir="$(grep -E '^OVERCAST_DATA_DIR=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)"
    data_dir="${data_dir:-./data}"
    if [[ "$data_dir" != /* ]]; then
        data_dir="$BACKEND_DIR/$data_dir"
    fi

    mkdir -p "$data_dir/storage" "$data_dir/database" "$data_dir/preview" "$data_dir/temp"

    # Safely migrate existing non-Docker data if present and target is empty
    local legacy_candidates=(
        "$BACKEND_DIR"
        "/opt/overcast/backend"
        "/opt/overcast"
    )

    for legacy in "${legacy_candidates[@]}"; do
        if [[ -f "$legacy/database/database.db" && ! -f "$data_dir/database/database.db" ]]; then
            info "Migrating existing SQLite database from $legacy/database/database.db..."
            cp -a "$legacy/database/database.db"* "$data_dir/database/" 2>/dev/null || true
            ok "Database migrated safely."
        fi

        if [[ -d "$legacy/storage" ]] && [[ -n "$(ls -A "$legacy/storage" 2>/dev/null || true)" ]] && [[ -z "$(ls -A "$data_dir/storage" 2>/dev/null || true)" ]]; then
            info "Migrating existing user files from $legacy/storage..."
            cp -a "$legacy/storage/." "$data_dir/storage/"
            ok "Stored files migrated safely."
        fi
    done

    ok "Persistent storage verified at: $data_dir"
}

configure_ports_and_services() {
    # If legacy systemd overcast-backend service is running on host port 8000, stop & disable it
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet overcast-backend 2>/dev/null; then
            info "Stopping legacy host systemd service (overcast-backend) before starting Docker container..."
            run_privileged systemctl stop overcast-backend || true
            run_privileged systemctl disable overcast-backend || true
        fi
    fi

    # Check if host port 80 is occupied by nginx or another web server (not overcast-backend)
    local desired_port
    desired_port="$(grep -E '^OVERCAST_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "80")"
    desired_port="${desired_port:-80}"

    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn 2>/dev/null | grep -qE ":${desired_port}\b" && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^overcast-backend$'; then
            if [[ "$desired_port" == "80" ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
                warn "Nginx is currently occupying port 80. Adjusting OVERCAST_PORT to 8080 (while keeping port 8000 active)..."
                sed -i 's/^OVERCAST_PORT=.*/OVERCAST_PORT=8080/' "$BACKEND_DIR/.env"
            fi
        fi
    fi

    local active_port
    active_port="$(grep -E '^OVERCAST_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "80")"
    local alt_port
    alt_port="$(grep -E '^OVERCAST_ALT_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "8000")"

    # Configure UFW firewall if active
    if command -v ufw >/dev/null 2>&1; then
        if run_privileged ufw status 2>/dev/null | grep -q "Status: active"; then
            info "UFW firewall is active. Allowing Overcast LAN ports ($active_port, $alt_port)..."
            run_privileged ufw allow "${active_port}/tcp" >/dev/null 2>&1 || true
            run_privileged ufw allow "${alt_port}/tcp" >/dev/null 2>&1 || true
            ok "Firewall rules updated."
        fi
    fi
}

verify_health() {
    local alt_port
    alt_port="$(grep -E '^OVERCAST_ALT_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "8000")"
    alt_port="${alt_port:-8000}"

    info "Waiting for Overcast backend to pass health checks..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -fsS "http://127.0.0.1:${alt_port}/api/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            ok "Overcast backend is healthy!"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done

    err "Backend health check did not succeed within ${max_attempts}s. Recent container logs:"
    compose_cmd logs --tail=50
    return 1
}

print_connection_summary() {
    local lan_ip
    lan_ip="$(detect_lan_ip)"
    local primary_port
    primary_port="$(grep -E '^OVERCAST_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "80")"
    local alt_port
    alt_port="$(grep -E '^OVERCAST_ALT_PORT=' "$BACKEND_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]' || echo "8000")"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}                 OVERCAST BACKEND IS UP AND RUNNING                   ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo
    if [[ "$primary_port" == "80" ]]; then
        echo -e "  Primary LAN URL:      ${BLUE}http://${lan_ip}${NC}"
    else
        echo -e "  Primary LAN URL:      ${BLUE}http://${lan_ip}:${primary_port}${NC}"
    fi
    echo -e "  Direct API Port URL:  ${BLUE}http://${lan_ip}:${alt_port}${NC}"
    echo -e "  Health Check URL:     ${BLUE}http://${lan_ip}:${alt_port}/api/health${NC}"
    echo -e "  Persistent Data Dir:  ${BACKEND_DIR}/data"
    echo -e "  Auto-Start on Reboot: Enabled (Docker restart: unless-stopped)"
    echo
    echo "  Runtime Management Commands:"
    echo "    ./setup.sh status   - Check container and health status"
    echo "    ./setup.sh logs     - View live backend logs"
    echo "    ./setup.sh restart  - Restart backend container"
    echo "    ./setup.sh stop     - Stop backend container"
    echo "    ./setup.sh start    - Start backend container"
    echo "    ./setup.sh update   - Rebuild image and restart (preserves data)"
    echo -e "${GREEN}======================================================================${NC}"
}

cmd_install() {
    ensure_dependencies_and_docker
    prepare_persistent_data
    configure_ports_and_services

    info "Building and starting Overcast Docker container..."
    compose_cmd up -d --build --remove-orphans

    verify_health
    print_connection_summary
}

cmd_start() {
    info "Starting Overcast backend..."
    compose_cmd up -d
    verify_health
    print_connection_summary
}

cmd_stop() {
    info "Stopping Overcast backend (persistent data is preserved)..."
    compose_cmd stop
    ok "Overcast backend stopped."
}

cmd_restart() {
    info "Restarting Overcast backend..."
    compose_cmd restart
    verify_health
    ok "Overcast backend restarted."
}

cmd_logs() {
    compose_cmd logs -f --tail=100
}

cmd_status() {
    compose_cmd ps
    echo
    local alt_port
    alt_port="$(grep -E '^OVERCAST_ALT_PORT=' "$BACKEND_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' || echo "8000")"
    alt_port="${alt_port:-8000}"
    info "Health endpoint response (http://127.0.0.1:${alt_port}/api/health):"
    curl -sS "http://127.0.0.1:${alt_port}/api/health" || err "Backend is not responding"
    echo
    print_connection_summary
}

cmd_update() {
    prepare_persistent_data
    info "Rebuilding Overcast backend image and recreating container (preserving volumes)..."
    compose_cmd up -d --build --remove-orphans
    verify_health
    print_connection_summary
}

ACTION="${1:-install}"
case "$ACTION" in
    install|setup)
        cmd_install
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    logs)
        cmd_logs
        ;;
    status|health)
        cmd_status
        ;;
    update|upgrade)
        cmd_update
        ;;
    *)
        echo "Usage: $0 {install|start|stop|restart|logs|status|update}"
        exit 1
        ;;
esac

