#!/usr/bin/env bash
# ============================================================================
#  nanogents - Start everything with one command
#
#  Usage:
#    bash scripts/start.sh           # start bridge (if WhatsApp) + gateway
#    bash scripts/start.sh --login   # first-time WhatsApp QR scan
#    bash scripts/start.sh --stop    # stop everything
#    bash scripts/start.sh --status  # check what's running
#    bash scripts/start.sh --logs    # tail all logs
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/.venv"
LOG_DIR="$HOME/.nanobot/logs"
BRIDGE_PID_FILE="$HOME/.nanobot/.bridge.pid"
GATEWAY_PID_FILE="$HOME/.nanobot/.gateway.pid"
BRIDGE_DIR="$PROJECT_DIR/bridge"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# ── Activate venv ──────────────────────────────────────────────────────────
activate_venv() {
    if [ -f "$VENV_DIR/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
    elif ! command -v nanobot &>/dev/null; then
        err "nanobot not found. Run 'bash setup.sh' first."
        exit 1
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────
is_running() {
    local pidfile="$1"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pidfile"
    fi
    return 1
}

whatsapp_enabled() {
    local config="$HOME/.nanobot/config.json"
    [ -f "$config" ] && python3 -c "
import json, sys
c = json.load(open('$config'))
wa = c.get('channels', {}).get('whatsapp', {})
sys.exit(0 if wa.get('enabled') else 1)
" 2>/dev/null
}

has_whatsapp_session() {
    [ -d "$HOME/.nanobot/whatsapp-auth" ] && [ "$(ls -A "$HOME/.nanobot/whatsapp-auth" 2>/dev/null)" ]
}

# ── Stop ───────────────────────────────────────────────────────────────────
stop_all() {
    echo ""
    echo -e "  ${BOLD}Stopping nanogents...${NC}"

    if is_running "$GATEWAY_PID_FILE"; then
        local pid
        pid=$(cat "$GATEWAY_PID_FILE")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$GATEWAY_PID_FILE"
        ok "Gateway stopped (PID $pid)"
    else
        info "Gateway not running"
    fi

    if is_running "$BRIDGE_PID_FILE"; then
        local pid
        pid=$(cat "$BRIDGE_PID_FILE")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$BRIDGE_PID_FILE"
        ok "WhatsApp bridge stopped (PID $pid)"
    else
        info "WhatsApp bridge not running"
    fi

    echo ""
}

# ── Status ─────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "  ${BOLD}nanogents status${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..40})${NC}"

    if is_running "$GATEWAY_PID_FILE"; then
        ok "Gateway running (PID $(cat "$GATEWAY_PID_FILE"))"
    else
        err "Gateway not running"
    fi

    if whatsapp_enabled; then
        if is_running "$BRIDGE_PID_FILE"; then
            ok "WhatsApp bridge running (PID $(cat "$BRIDGE_PID_FILE"))"
        else
            err "WhatsApp bridge not running"
        fi

        if has_whatsapp_session; then
            ok "WhatsApp session: linked"
        else
            warn "WhatsApp session: not linked (run with --login)"
        fi
    else
        info "WhatsApp: not enabled"
    fi

    echo ""
    echo -e "  ${BOLD}Logs:${NC} $LOG_DIR/"
    echo ""
}

# ── Logs ───────────────────────────────────────────────────────────────────
show_logs() {
    echo ""
    info "Tailing logs... (Ctrl+C to stop)"
    echo ""
    tail -f "$LOG_DIR"/*.log 2>/dev/null || {
        err "No log files found in $LOG_DIR/"
    }
}

# ── WhatsApp Login (foreground, shows QR) ──────────────────────────────────
whatsapp_login() {
    echo ""
    echo -e "  ${BOLD}WhatsApp Login${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..40})${NC}"
    echo ""
    info "Starting WhatsApp bridge in foreground..."
    info "A QR code will appear — scan it with your phone:"
    info "  WhatsApp → Settings → Linked Devices → Link a Device"
    echo ""
    warn "IMPORTANT: After scanning, press Ctrl+C to stop."
    warn "Then run 'bash scripts/start.sh' to start normally."
    echo ""

    # Stop existing bridge (PID file or any process on port 3001)
    if is_running "$BRIDGE_PID_FILE"; then
        kill "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null || true
        rm -f "$BRIDGE_PID_FILE"
        sleep 1
    fi
    # Kill anything still holding port 3001
    local stale_pid
    stale_pid=$(lsof -ti:3001 2>/dev/null || true)
    if [ -n "$stale_pid" ]; then
        info "Killing old process on port 3001 (PID $stale_pid)..."
        kill "$stale_pid" 2>/dev/null || true
        sleep 1
    fi

    # Clear stale session so bridge generates a fresh QR code
    local AUTH_DIR="$HOME/.nanobot/whatsapp-auth"
    if [ -d "$AUTH_DIR" ]; then
        info "Clearing old WhatsApp session..."
        rm -rf "$AUTH_DIR"
        ok "Old session cleared — fresh QR will appear"
    fi

    # Run bridge in foreground so user can see QR code
    cd "$BRIDGE_DIR"
    node dist/index.js
}

# ── Start ──────────────────────────────────────────────────────────────────
start_all() {
    echo ""
    echo -e "  ${BOLD}Starting nanogents...${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..40})${NC}"

    mkdir -p "$LOG_DIR"

    # ── WhatsApp bridge ──
    if whatsapp_enabled; then
        if ! has_whatsapp_session; then
            echo ""
            warn "WhatsApp not linked yet!"
            info "Run first:  bash scripts/start.sh --login"
            info "Scan the QR code, then run this command again."
            echo ""
            exit 1
        fi

        if is_running "$BRIDGE_PID_FILE"; then
            ok "WhatsApp bridge already running (PID $(cat "$BRIDGE_PID_FILE"))"
        else
            info "Starting WhatsApp bridge..."
            cd "$BRIDGE_DIR"
            nohup node dist/index.js >> "$LOG_DIR/bridge.log" 2>&1 &
            local bridge_pid=$!
            echo "$bridge_pid" > "$BRIDGE_PID_FILE"
            cd "$PROJECT_DIR"

            # Wait for bridge to be ready
            sleep 3
            if kill -0 "$bridge_pid" 2>/dev/null; then
                ok "WhatsApp bridge started (PID $bridge_pid)"
            else
                err "WhatsApp bridge failed to start. Check: $LOG_DIR/bridge.log"
                rm -f "$BRIDGE_PID_FILE"
                exit 1
            fi
        fi
    fi

    # ── Gateway ──
    if is_running "$GATEWAY_PID_FILE"; then
        ok "Gateway already running (PID $(cat "$GATEWAY_PID_FILE"))"
    else
        info "Starting gateway..."
        activate_venv
        nohup nanobot gateway >> "$LOG_DIR/gateway.log" 2>&1 &
        local gw_pid=$!
        echo "$gw_pid" > "$GATEWAY_PID_FILE"

        sleep 2
        if kill -0 "$gw_pid" 2>/dev/null; then
            ok "Gateway started (PID $gw_pid)"
        else
            err "Gateway failed to start. Check: $LOG_DIR/gateway.log"
            rm -f "$GATEWAY_PID_FILE"
            exit 1
        fi
    fi

    echo ""
    ok "nanogents is running!"
    echo ""
    echo -e "  ${BOLD}Logs:${NC}"
    echo -e "    ${CYAN}tail -f $LOG_DIR/gateway.log${NC}"
    if whatsapp_enabled; then
        echo -e "    ${CYAN}tail -f $LOG_DIR/bridge.log${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Stop:${NC}   bash scripts/start.sh --stop"
    echo -e "  ${BOLD}Status:${NC} bash scripts/start.sh --status"
    echo ""
}

# ── Systemd install (optional, for auto-start on boot) ─────────────────────
install_services() {
    echo ""
    echo -e "  ${BOLD}Installing systemd services...${NC}"

    # WhatsApp bridge service
    if whatsapp_enabled; then
        cat > /etc/systemd/system/nanogents-bridge.service <<UNIT
[Unit]
Description=nanogents WhatsApp Bridge
After=network.target

[Service]
Type=simple
WorkingDirectory=$BRIDGE_DIR
ExecStart=$(command -v node) dist/index.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
UNIT
        ok "Created nanogents-bridge.service"
    fi

    # Gateway service
    cat > /etc/systemd/system/nanogents.service <<UNIT
[Unit]
Description=nanogents Gateway
After=network.target$(whatsapp_enabled && echo " nanogents-bridge.service" || true)
$(whatsapp_enabled && echo "Requires=nanogents-bridge.service" || true)

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/nanobot gateway
Restart=always
RestartSec=10
Environment=PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

[Install]
WantedBy=multi-user.target
UNIT
    ok "Created nanogents.service"

    systemctl daemon-reload

    if whatsapp_enabled; then
        systemctl enable nanogents-bridge nanogents
        ok "Services enabled (will start on boot)"
        echo ""
        info "Start now:  systemctl start nanogents"
        info "View logs:  journalctl -u nanogents -u nanogents-bridge -f"
    else
        systemctl enable nanogents
        ok "Service enabled (will start on boot)"
        echo ""
        info "Start now:  systemctl start nanogents"
        info "View logs:  journalctl -u nanogents -f"
    fi
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --login)
            activate_venv
            whatsapp_login
            ;;
        --stop)
            stop_all
            ;;
        --status)
            show_status
            ;;
        --logs)
            show_logs
            ;;
        --install-service)
            install_services
            ;;
        --help|-h)
            echo ""
            echo -e "  ${BOLD}Usage:${NC} bash scripts/start.sh [option]"
            echo ""
            echo "  Options:"
            echo "    (none)             Start bridge + gateway in background"
            echo "    --login            WhatsApp QR code scan (first time)"
            echo "    --stop             Stop everything"
            echo "    --status           Show what's running"
            echo "    --logs             Tail all log files"
            echo "    --install-service  Install systemd services (auto-start on boot)"
            echo ""
            ;;
        *)
            start_all
            ;;
    esac
}

main "$@"
