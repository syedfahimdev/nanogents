#!/usr/bin/env bash
# ============================================================================
#  nanogents - One-Click Interactive Setup
#  Run: bash setup.sh
#
#  Safe to re-run — tracks completed steps and resumes where it left off.
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$HOME/.nanobot/.setup_state"
TOTAL_STEPS=5

# ── State tracking ─────────────────────────────────────────────────────────
# Each step writes its name to the state file on completion.
# Re-running the script skips already-completed steps.

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

# ── Step 1: System Dependencies ────────────────────────────────────────────
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

    # Python 3.11+
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

    # pip
    if python3 -m pip --version &>/dev/null 2>&1; then
        print_ok "pip"
    else
        print_warn "pip not found"
        MISSING+=("pip")
    fi

    # python3-venv (needed on Debian/Ubuntu for PEP 668)
    if python3 -c "import venv" &>/dev/null 2>&1; then
        print_ok "python3-venv"
    else
        print_warn "python3-venv not found"
        MISSING+=("python3-venv")
    fi

    # git
    if command -v git &>/dev/null; then
        print_ok "git $(git --version | grep -oP '\d+\.\d+\.\d+')"
    else
        print_err "git not found"
        MISSING+=("git")
    fi

    # ── Optional ──

    # Node.js (for WhatsApp bridge)
    if command -v node &>/dev/null; then
        print_ok "Node.js $(node --version)"
    else
        print_warn "Node.js not found (needed for WhatsApp bridge)"
        OPTIONAL_MISSING+=("nodejs")
    fi

    # Docker
    if command -v docker &>/dev/null; then
        print_ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    else
        print_warn "Docker not found (needed for VPS deployment)"
        OPTIONAL_MISSING+=("docker")
    fi

    # ── Install missing required deps ──

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

    # ── Install missing optional deps ──

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
                    if confirm "Install Docker? (needed for VPS deployment)" "N"; then
                        print_info "Installing Docker via official script..."
                        curl -fsSL https://get.docker.com | sudo sh
                        sudo systemctl enable --now docker 2>/dev/null || true
                        if command -v docker &>/dev/null; then
                            print_ok "Docker installed"
                        fi
                    else
                        print_info "Skipped Docker (you can install later for VPS deployment)"
                    fi
                    ;;
            esac
        done
    fi

    mark_done "$STEP_ID"
    print_ok "System dependencies ready"
}

# ── Step 2: Python Virtual Environment ─────────────────────────────────────
step_venv() {
    local STEP_ID="venv"
    local VENV_DIR="$SCRIPT_DIR/.venv"

    if is_done "$STEP_ID"; then
        print_step 2 "Python environment"
        print_skip "Virtual environment already set up"
        # Still activate it for subsequent steps
        activate_venv
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

    # Upgrade pip inside venv
    print_info "Upgrading pip..."
    pip install --upgrade pip --quiet 2>&1 | tail -1 || true
    print_ok "pip up to date"

    mark_done "$STEP_ID"
}

activate_venv() {
    local VENV_DIR="$SCRIPT_DIR/.venv"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    print_ok "Using Python: $(which python3)"
}

# ── Step 3: Install nanogents ──────────────────────────────────────────────
step_install() {
    local STEP_ID="install"

    if is_done "$STEP_ID"; then
        print_step 3 "Installing nanogents"
        print_skip "nanogents already installed"
        if confirm "Reinstall / update?" "N"; then
            # Fall through to install
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
    if command -v node &>/dev/null && [ -f "$SCRIPT_DIR/bridge/package.json" ]; then
        print_info "Building WhatsApp bridge..."
        (cd "$SCRIPT_DIR/bridge" && npm install --silent 2>&1 | tail -2 && npm run build --silent 2>&1 | tail -2) || {
            print_warn "WhatsApp bridge build failed (non-critical, you can fix later)"
        }
        print_ok "WhatsApp bridge built"
    fi

    # Verify nanobot command
    if command -v nanobot &>/dev/null; then
        print_ok "nanobot command: $(which nanobot)"
    else
        print_warn "'nanobot' not found in PATH"
        print_info "Activate the venv first: source .venv/bin/activate"
    fi

    mark_done "$STEP_ID"
}

# ── Step 4: Initialize workspace ──────────────────────────────────────────
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

    mkdir -p "$WORKSPACE"
    print_ok "Config directory: $NANOBOT_HOME"
    print_ok "Workspace: $WORKSPACE"

    # Sync templates
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

    mark_done "$STEP_ID"
}

# ── Step 5: Run interactive wizard ─────────────────────────────────────────
step_wizard() {
    local STEP_ID="wizard"

    if is_done "$STEP_ID"; then
        print_step 5 "Configuration"
        print_skip "Configuration wizard already completed"
        if confirm "Run wizard again? (existing config will be preserved)" "N"; then
            # Fall through
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

# ── Summary ────────────────────────────────────────────────────────────────
print_summary() {
    local VENV_DIR="$SCRIPT_DIR/.venv"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │                                             │"
    echo "  │        ✅  Setup complete!                  │"
    echo "  │                                             │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo -e "  ${BOLD}Before each session, activate the venv:${NC}"
    echo ""
    echo -e "    ${CYAN}source ${VENV_DIR}/bin/activate${NC}"
    echo ""
    echo -e "  ${BOLD}Then run:${NC}"
    echo ""
    echo -e "    ${CYAN}nanobot agent${NC}          # interactive chat"
    echo -e "    ${CYAN}nanobot gateway${NC}        # start gateway (Telegram, Discord, etc.)"
    echo -e "    ${CYAN}nanobot status${NC}         # check status"
    echo ""
    echo -e "  ${BOLD}Config:${NC}    ~/.nanobot/config.json"
    echo -e "  ${BOLD}Workspace:${NC} ~/.nanobot/workspace/"
    echo ""
    echo -e "  ${DIM}Re-run this script anytime — it picks up where it left off.${NC}"
    echo -e "  ${DIM}To start fresh: bash setup.sh --reset${NC}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
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
    step_system_deps
    step_venv
    step_install
    step_workspace
    step_wizard
    print_summary
}

main "$@"
