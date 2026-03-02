#!/usr/bin/env bash
# ============================================================================
#  nanogents - One-Click Interactive Setup & Deploy
#
#  Usage:
#    bash setup.sh            # full setup (install + configure + launch)
#    bash setup.sh --reset    # clear state and start fresh
#
#  After setup, manage with:
#    bash scripts/start.sh --status | --stop | --logs
#
#  Safe to re-run — tracks completed steps and resumes where it left off.
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$HOME/.nanobot/.setup_state"
VENV_DIR="$SCRIPT_DIR/.venv"
LOG_DIR="$HOME/.nanobot/logs"
BRIDGE_DIR="$SCRIPT_DIR/bridge"
BRIDGE_PID_FILE="$HOME/.nanobot/.bridge.pid"
GATEWAY_PID_FILE="$HOME/.nanobot/.gateway.pid"
TOTAL_STEPS=7

# ── State tracking ─────────────────────────────────────────────────────────

mark_done() {
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$1" >> "$STATE_FILE"
}

is_done() {
    [ -f "$STATE_FILE" ] && grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

reset_state() {
    rm -f "$STATE_FILE"
}

# ── UI helpers ─────────────────────────────────────────────────────────────

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │                                             │"
    echo "  │           🤖  nanogents  setup              │"
    echo "  │       Your Personal AI Assistant            │"
    echo "  │                                             │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"
}

print_step() {
    echo ""
    echo -e "${BLUE}${BOLD}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"
    echo -e "${BLUE}$(printf '%.0s─' {1..50})${NC}"
}

print_ok()    { echo -e "  ${GREEN}✔${NC} $1"; }
print_skip()  { echo -e "  ${DIM}✔ $1 (already done)${NC}"; }
print_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()   { echo -e "  ${RED}✘${NC} $1"; }
print_info()  { echo -e "  ${CYAN}→${NC} $1"; }

confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint
    if [ "$default" = "Y" ]; then hint="Y/n"; else hint="y/N"; fi

    read -rp "  $prompt [$hint]: " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "$ID"
    elif command -v sw_vers &>/dev/null; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# ── Process helpers ────────────────────────────────────────────────────────

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

stop_pid() {
    local pidfile="$1"
    local label="$2"
    if is_running "$pidfile"; then
        local pid
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$pidfile"
        print_ok "$label stopped (PID $pid)"
    fi
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

activate_venv() {
    if [ -f "$VENV_DIR/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
    fi
}

# ============================================================================
#  STEP 1: System Dependencies
# ============================================================================
step_system_deps() {
    local STEP_ID="system_deps"

    if is_done "$STEP_ID"; then
        print_step 1 "System dependencies"
        print_skip "System dependencies already installed"
        if ! confirm "Re-check anyway?" "N"; then
            return
        fi
    else
        print_step 1 "Checking system dependencies"
    fi

    local MISSING=()
    local OPTIONAL_MISSING=()

    # ── Required ──

    if command -v python3 &>/dev/null; then
        local py_ver
        py_ver=$(python3 --version 2>&1 | grep -oP '\d+\.\d+')
        if python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" 2>/dev/null; then
            print_ok "Python $py_ver"
        else
            print_err "Python $py_ver found but need >= 3.11"
            MISSING+=("python3")
        fi
    else
        print_err "Python 3 not found"
        MISSING+=("python3")
    fi

    if python3 -m pip --version &>/dev/null 2>&1; then
        print_ok "pip"
    else
        print_warn "pip not found"
        MISSING+=("pip")
    fi

    if python3 -c "import venv" &>/dev/null 2>&1; then
        print_ok "python3-venv"
    else
        print_warn "python3-venv not found"
        MISSING+=("python3-venv")
    fi

    if command -v git &>/dev/null; then
        print_ok "git $(git --version | grep -oP '\d+\.\d+\.\d+')"
    else
        print_err "git not found"
        MISSING+=("git")
    fi

    # ── Optional ──

    if command -v node &>/dev/null; then
        print_ok "Node.js $(node --version)"
    else
        print_warn "Node.js not found (needed for WhatsApp bridge)"
        OPTIONAL_MISSING+=("nodejs")
    fi

    if command -v docker &>/dev/null; then
        print_ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    else
        print_warn "Docker not found (needed for container deployment)"
        OPTIONAL_MISSING+=("docker")
    fi

    # ── Install missing required ──

    local OS
    OS=$(detect_os)

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo ""
        print_warn "Missing required: ${MISSING[*]}"
        echo ""
        if confirm "Install missing required dependencies?" "Y"; then
            case "$OS" in
                ubuntu|debian|pop)
                    sudo apt-get update -qq
                    sudo apt-get install -y -qq python3 python3-pip python3-venv git curl
                    ;;
                fedora|rhel|centos)
                    sudo dnf install -y python3 python3-pip python3-libs git curl
                    ;;
                arch|manjaro)
                    sudo pacman -Sy --noconfirm python python-pip git curl
                    ;;
                macos)
                    if command -v brew &>/dev/null; then
                        brew install python@3.12 git
                    else
                        print_err "Install Homebrew first: https://brew.sh"
                        exit 1
                    fi
                    ;;
                *)
                    print_err "Unsupported OS ($OS). Please install manually: python3.11+ pip git"
                    exit 1
                    ;;
            esac
            print_ok "Required dependencies installed"
        else
            print_err "Cannot continue without: ${MISSING[*]}"
            exit 1
        fi
    fi

    # ── Install missing optional ──

    if [ ${#OPTIONAL_MISSING[@]} -gt 0 ]; then
        echo ""
        for dep in "${OPTIONAL_MISSING[@]}"; do
            case "$dep" in
                nodejs)
                    if confirm "Install Node.js 20? (needed for WhatsApp bridge)" "Y"; then
                        case "$OS" in
                            ubuntu|debian|pop)
                                print_info "Adding NodeSource repo and installing Node.js 20..."
                                sudo mkdir -p /etc/apt/keyrings
                                curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
                                echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
                                sudo apt-get update -qq
                                sudo apt-get install -y -qq nodejs
                                ;;
                            fedora|rhel|centos)
                                curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
                                sudo dnf install -y nodejs
                                ;;
                            arch|manjaro)
                                sudo pacman -Sy --noconfirm nodejs npm
                                ;;
                            macos)
                                brew install node@20
                                ;;
                            *)
                                print_warn "Please install Node.js 20 manually: https://nodejs.org"
                                ;;
                        esac
                        if command -v node &>/dev/null; then
                            print_ok "Node.js $(node --version) installed"
                        fi
                    else
                        print_info "Skipped Node.js (WhatsApp won't work without it)"
                    fi
                    ;;
                docker)
                    if confirm "Install Docker? (needed for container deployment)" "N"; then
                        print_info "Installing Docker via official script..."
                        curl -fsSL https://get.docker.com | sudo sh
                        sudo systemctl enable --now docker 2>/dev/null || true
                        if command -v docker &>/dev/null; then
                            print_ok "Docker installed"
                        fi
                    else
                        print_info "Skipped Docker"
                    fi
                    ;;
            esac
        done
    fi

    mark_done "$STEP_ID"
    print_ok "System dependencies ready"
}

# ============================================================================
#  STEP 2: Python Virtual Environment
# ============================================================================
step_venv() {
    local STEP_ID="venv"

    if is_done "$STEP_ID"; then
        print_step 2 "Python environment"
        print_skip "Virtual environment already set up"
        activate_venv
        print_ok "Using Python: $(which python3)"
        if ! confirm "Re-create venv?" "N"; then
            return
        fi
    else
        print_step 2 "Setting up Python environment"
    fi

    if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ]; then
        print_ok "Virtual environment exists at .venv/"
        activate_venv
    else
        print_info "Creating virtual environment at .venv/ ..."
        python3 -m venv "$VENV_DIR"
        activate_venv
        print_ok "Virtual environment created"
    fi

    print_ok "Using Python: $(which python3)"

    # Upgrade pip inside venv
    print_info "Upgrading pip..."
    pip install --upgrade pip --quiet 2>&1 | tail -1 || true
    print_ok "pip up to date"

    mark_done "$STEP_ID"
}

# ============================================================================
#  STEP 3: Install nanogents
# ============================================================================
step_install() {
    local STEP_ID="install"

    if is_done "$STEP_ID"; then
        print_step 3 "Installing nanogents"
        print_skip "nanogents already installed"
        if confirm "Reinstall / update?" "N"; then
            :
        else
            return
        fi
    else
        print_step 3 "Installing nanogents"
    fi

    print_info "Installing nanogents in editable mode (this may take a minute)..."
    if pip install -e "$SCRIPT_DIR" 2>&1 | tail -5; then
        print_ok "nanogents installed successfully"
    else
        print_err "Installation failed. Check the output above."
        print_info "Common fix: make sure python3-venv is installed and try again."
        exit 1
    fi

    # Build WhatsApp bridge if Node.js is available
    if command -v node &>/dev/null && [ -f "$BRIDGE_DIR/package.json" ]; then
        print_info "Building WhatsApp bridge..."
        (cd "$BRIDGE_DIR" && npm install --silent 2>&1 | tail -2 && npm run build --silent 2>&1 | tail -2) || {
            print_warn "WhatsApp bridge build failed (non-critical, you can fix later)"
        }
        print_ok "WhatsApp bridge built"
    fi

    # Verify nanobot command
    if command -v nanobot &>/dev/null; then
        print_ok "nanobot command: $(which nanobot)"
    else
        print_warn "'nanobot' not found in PATH"
    fi

    # Add venv auto-activation to shell profile
    local VENV_ACTIVATE="$VENV_DIR/bin/activate"
    local SHELL_RC=""

    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        SHELL_RC="$HOME/.zshrc"
    else
        SHELL_RC="$HOME/.bashrc"
    fi

    local ACTIVATE_LINE="# nanogents venv auto-activate"
    if [ -f "$SHELL_RC" ] && grep -qF "$ACTIVATE_LINE" "$SHELL_RC" 2>/dev/null; then
        print_ok "Shell auto-activate already in $SHELL_RC"
    else
        if confirm "Add nanobot to your PATH permanently? (auto-activate venv in $SHELL_RC)" "Y"; then
            {
                echo ""
                echo "$ACTIVATE_LINE"
                echo "[ -f \"$VENV_ACTIVATE\" ] && source \"$VENV_ACTIVATE\""
            } >> "$SHELL_RC"
            print_ok "Added to $SHELL_RC — nanobot will work in every new terminal"
        fi
    fi

    mark_done "$STEP_ID"
}

# ============================================================================
#  STEP 4: Initialize workspace
# ============================================================================
step_workspace() {
    local STEP_ID="workspace"

    if is_done "$STEP_ID"; then
        print_step 4 "Workspace"
        print_skip "Workspace already initialized"
        return
    fi

    print_step 4 "Initializing workspace"

    local NANOBOT_HOME="$HOME/.nanobot"
    local WORKSPACE="$NANOBOT_HOME/workspace"

    mkdir -p "$WORKSPACE" "$LOG_DIR"
    print_ok "Config directory: $NANOBOT_HOME"
    print_ok "Workspace: $WORKSPACE"
    print_ok "Logs: $LOG_DIR"

    # Restore customizations from repo if available
    local CUSTOM_DIR="$SCRIPT_DIR/custom"
    if [ -d "$CUSTOM_DIR/workspace" ] && [ "$(ls -A "$CUSTOM_DIR/workspace" 2>/dev/null)" ]; then
        print_info "Found saved customizations in repo — restoring..."
        bash "$SCRIPT_DIR/scripts/sync-custom.sh" pull
        print_ok "Customizations restored from repo"
    else
        # First-time setup — sync default templates
        local TEMPLATE_SRC="$SCRIPT_DIR/nanobot/templates"
        if [ -d "$TEMPLATE_SRC" ]; then
            local count=0
            for f in "$TEMPLATE_SRC"/*.md; do
                [ -f "$f" ] || continue
                local bname
                bname=$(basename "$f")
                if [ ! -f "$WORKSPACE/$bname" ]; then
                    cp "$f" "$WORKSPACE/$bname"
                    count=$((count + 1))
                fi
            done
            print_ok "Templates synced ($count new files)"
        fi
    fi

    mark_done "$STEP_ID"
}

# ============================================================================
#  STEP 5: Interactive configuration wizard
# ============================================================================
step_wizard() {
    local STEP_ID="wizard"

    if is_done "$STEP_ID"; then
        print_step 5 "Configuration"
        print_skip "Configuration wizard already completed"
        if confirm "Run wizard again? (existing config will be preserved)" "N"; then
            :
        else
            return
        fi
    else
        print_step 5 "Interactive configuration"
    fi

    echo ""
    print_info "Launching setup wizard..."
    echo ""

    python3 "$SCRIPT_DIR/scripts/wizard.py"

    mark_done "$STEP_ID"
}

# ============================================================================
#  STEP 6: n8n Workflow Automation (optional)
# ============================================================================
step_n8n() {
    local STEP_ID="n8n"

    if is_done "$STEP_ID"; then
        print_step 6 "n8n Automation"
        print_skip "n8n already configured"
        return
    fi

    print_step 6 "n8n Workflow Automation (optional)"

    echo ""
    print_info "n8n lets you create visual workflows that your agent can call as tools."
    print_info "Examples: send emails, update CRM, post to social media, scrape data, etc."
    echo ""

    if confirm "Set up n8n workflow automation?" "N"; then
        if ! command -v docker &>/dev/null; then
            print_err "Docker required for n8n. Skipping."
            mark_done "$STEP_ID"
            return
        fi

        bash "$SCRIPT_DIR/scripts/setup-n8n.sh"
    else
        print_info "Skipped. Set up later: bash scripts/setup-n8n.sh"
    fi

    mark_done "$STEP_ID"
}

# ============================================================================
#  STEP 7: Launch services
# ============================================================================
step_launch() {
    local STEP_ID="launch"

    print_step 7 "Launch services"

    mkdir -p "$LOG_DIR"

    echo ""
    if confirm "Install systemd services? (auto-start on boot, recommended for VPS)" "Y"; then
        install_systemd_services
    else
        if confirm "Start nanogents now in background?" "Y"; then
            start_background
        else
            print_info "You can start later with: bash scripts/start.sh"
        fi
    fi

    mark_done "$STEP_ID"
}

install_systemd_services() {
    print_info "Creating systemd services..."

    # ── WhatsApp bridge service ──
    if whatsapp_enabled && [ -f "$BRIDGE_DIR/dist/index.js" ]; then
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
        print_ok "Created nanogents-bridge.service"
    fi

    # ── Gateway service ──
    local AFTER="network.target"
    local REQUIRES=""
    if whatsapp_enabled && [ -f /etc/systemd/system/nanogents-bridge.service ]; then
        AFTER="network.target nanogents-bridge.service"
        REQUIRES="Requires=nanogents-bridge.service"
    fi

    cat > /etc/systemd/system/nanogents.service <<UNIT
[Unit]
Description=nanogents Gateway
After=$AFTER
$REQUIRES

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_DIR/bin/nanobot gateway
Restart=always
RestartSec=10
Environment=PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

[Install]
WantedBy=multi-user.target
UNIT
    print_ok "Created nanogents.service"

    # Reload and enable
    systemctl daemon-reload

    if whatsapp_enabled && [ -f /etc/systemd/system/nanogents-bridge.service ]; then
        systemctl enable nanogents-bridge nanogents 2>/dev/null
        systemctl restart nanogents-bridge nanogents
        sleep 3

        if systemctl is-active --quiet nanogents; then
            print_ok "Gateway running"
        else
            print_err "Gateway failed to start"
            print_info "Check: journalctl -u nanogents -e"
        fi

        if systemctl is-active --quiet nanogents-bridge; then
            print_ok "WhatsApp bridge running"
        else
            print_err "WhatsApp bridge failed to start"
            print_info "Check: journalctl -u nanogents-bridge -e"
        fi
    else
        systemctl enable nanogents 2>/dev/null
        systemctl restart nanogents
        sleep 3

        if systemctl is-active --quiet nanogents; then
            print_ok "Gateway running"
        else
            print_err "Gateway failed to start"
            print_info "Check: journalctl -u nanogents -e"
        fi
    fi

    print_ok "Services enabled — will auto-start on boot"
}

start_background() {
    # ── WhatsApp bridge ──
    if whatsapp_enabled && [ -f "$BRIDGE_DIR/dist/index.js" ]; then
        if is_running "$BRIDGE_PID_FILE"; then
            print_ok "WhatsApp bridge already running (PID $(cat "$BRIDGE_PID_FILE"))"
        else
            print_info "Starting WhatsApp bridge..."
            (cd "$BRIDGE_DIR" && nohup node dist/index.js >> "$LOG_DIR/bridge.log" 2>&1 &
            echo $! > "$BRIDGE_PID_FILE")

            sleep 3
            if is_running "$BRIDGE_PID_FILE"; then
                print_ok "WhatsApp bridge started (PID $(cat "$BRIDGE_PID_FILE"))"
            else
                print_err "WhatsApp bridge failed. Check: $LOG_DIR/bridge.log"
            fi
        fi
    fi

    # ── Gateway ──
    if is_running "$GATEWAY_PID_FILE"; then
        print_ok "Gateway already running (PID $(cat "$GATEWAY_PID_FILE"))"
    else
        print_info "Starting gateway..."
        activate_venv
        nohup nanobot gateway >> "$LOG_DIR/gateway.log" 2>&1 &
        echo $! > "$GATEWAY_PID_FILE"

        sleep 3
        if is_running "$GATEWAY_PID_FILE"; then
            print_ok "Gateway started (PID $(cat "$GATEWAY_PID_FILE"))"
        else
            print_err "Gateway failed. Check: $LOG_DIR/gateway.log"
        fi
    fi
}

# ============================================================================
#  Summary
# ============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │                                             │"
    echo "  │        ✅  Setup complete!                  │"
    echo "  │                                             │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"

    # Show service status
    if systemctl is-active --quiet nanogents 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} Gateway is ${GREEN}running${NC}"
    elif is_running "$GATEWAY_PID_FILE"; then
        echo -e "  ${GREEN}●${NC} Gateway is ${GREEN}running${NC} (PID $(cat "$GATEWAY_PID_FILE"))"
    else
        echo -e "  ${RED}●${NC} Gateway is ${RED}not running${NC}"
    fi

    if whatsapp_enabled; then
        if systemctl is-active --quiet nanogents-bridge 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} WhatsApp bridge is ${GREEN}running${NC}"
        elif is_running "$BRIDGE_PID_FILE"; then
            echo -e "  ${GREEN}●${NC} WhatsApp bridge is ${GREEN}running${NC} (PID $(cat "$BRIDGE_PID_FILE"))"
        else
            echo -e "  ${RED}●${NC} WhatsApp bridge is ${RED}not running${NC}"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo ""
    echo -e "    ${CYAN}nanobot agent${NC}                    # interactive chat (CLI)"
    echo -e "    ${CYAN}nanobot status${NC}                   # check nanobot status"
    echo ""

    # Show appropriate management commands
    if systemctl is-enabled --quiet nanogents 2>/dev/null; then
        echo -e "  ${BOLD}Manage services:${NC}"
        echo ""
        echo -e "    ${CYAN}systemctl status nanogents${NC}       # gateway status"
        echo -e "    ${CYAN}systemctl restart nanogents${NC}      # restart gateway"
        echo -e "    ${CYAN}journalctl -u nanogents -f${NC}       # follow gateway logs"
        if whatsapp_enabled; then
            echo -e "    ${CYAN}journalctl -u nanogents-bridge -f${NC}  # WhatsApp bridge logs"
        fi
    else
        echo -e "  ${BOLD}Manage processes:${NC}"
        echo ""
        echo -e "    ${CYAN}bash scripts/start.sh${NC}            # start everything"
        echo -e "    ${CYAN}bash scripts/start.sh --stop${NC}     # stop everything"
        echo -e "    ${CYAN}bash scripts/start.sh --status${NC}   # check status"
        echo -e "    ${CYAN}bash scripts/start.sh --logs${NC}     # tail logs"
    fi

    echo ""
    # n8n status
    if docker inspect n8n --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
        local n8n_domain
        n8n_domain=$(grep '^N8N_DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}●${NC} n8n is ${GREEN}running${NC} at ${CYAN}https://${n8n_domain}${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Config:${NC}    ~/.nanobot/config.json"
    echo -e "  ${BOLD}Workspace:${NC} ~/.nanobot/workspace/"
    echo -e "  ${BOLD}Logs:${NC}      $LOG_DIR/"
    echo ""
    echo -e "  ${DIM}Re-run this script anytime — it picks up where it left off.${NC}"
    echo -e "  ${DIM}To start fresh: bash setup.sh --reset${NC}"
    echo ""
}

# ============================================================================
#  Main
# ============================================================================
main() {
    # Handle --reset flag
    if [ "${1:-}" = "--reset" ]; then
        reset_state
        echo -e "  ${GREEN}✔${NC} Setup state cleared. Starting fresh."
    fi

    # Show resume info if state exists
    if [ -f "$STATE_FILE" ]; then
        local done_count
        done_count=$(wc -l < "$STATE_FILE" | tr -d ' ')
        echo ""
        echo -e "  ${CYAN}→${NC} Resuming setup (${done_count}/${TOTAL_STEPS} steps completed previously)"
        echo -e "  ${DIM}  Use --reset to start over${NC}"
    fi

    print_banner

    step_system_deps      # 1. System deps (Python, Node.js, Docker)
    step_venv             # 2. Virtual environment
    step_install          # 3. Install nanogents + build bridge + PATH
    step_workspace        # 4. Create workspace + sync templates
    step_wizard           # 5. Interactive config (provider, model, channels, WhatsApp QR)
    step_n8n              # 6. n8n workflow automation (optional)
    step_launch           # 7. Start services (systemd or background)

    print_summary
}

main "$@"
