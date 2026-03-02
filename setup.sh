#!/usr/bin/env bash
# ============================================================================
#  nanogents - One-Click Interactive Setup
#  Run: bash setup.sh
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
print_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()   { echo -e "  ${RED}✘${NC} $1"; }
print_info()  { echo -e "  ${CYAN}→${NC} $1"; }

TOTAL_STEPS=4

# ── Detect OS ──────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif command -v sw_vers &>/dev/null; then
        OS="macos"
    else
        OS="unknown"
    fi
    echo "$OS"
}

# ── Step 1: System Dependencies ────────────────────────────────────────────
install_system_deps() {
    print_step 1 "Checking system dependencies"

    local MISSING=()

    # Check Python
    if command -v python3 &>/dev/null; then
        PY_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+')
        if python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" 2>/dev/null; then
            print_ok "Python $PY_VERSION"
        else
            print_err "Python $PY_VERSION (need >= 3.11)"
            MISSING+=("python3.11+")
        fi
    else
        print_err "Python 3 not found"
        MISSING+=("python3")
    fi

    # Check pip
    if python3 -m pip --version &>/dev/null; then
        print_ok "pip"
    else
        print_warn "pip not found"
        MISSING+=("pip")
    fi

    # Check git
    if command -v git &>/dev/null; then
        print_ok "git $(git --version | grep -oP '\d+\.\d+\.\d+')"
    else
        print_err "git not found"
        MISSING+=("git")
    fi

    # Check Node.js (optional, for WhatsApp)
    if command -v node &>/dev/null; then
        print_ok "Node.js $(node --version) (for WhatsApp bridge)"
    else
        print_warn "Node.js not found (optional, needed for WhatsApp)"
    fi

    # Check Docker (optional, for deployment)
    if command -v docker &>/dev/null; then
        print_ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    else
        print_warn "Docker not found (optional, needed for VPS deployment)"
    fi

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo ""
        print_warn "Missing required dependencies: ${MISSING[*]}"
        echo ""
        read -p "  Install missing dependencies automatically? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            print_err "Cannot continue without: ${MISSING[*]}"
            exit 1
        fi

        OS=$(detect_os)
        case "$OS" in
            ubuntu|debian|pop)
                sudo apt-get update -qq
                sudo apt-get install -y -qq python3 python3-pip python3-venv git curl
                ;;
            fedora|rhel|centos)
                sudo dnf install -y python3 python3-pip git curl
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
                print_err "Unsupported OS. Please install manually: python3.11+ pip git"
                exit 1
                ;;
        esac
        print_ok "System dependencies installed"
    fi
}

# ── Step 2: Install nanogents ──────────────────────────────────────────────
install_nanogents() {
    print_step 2 "Installing nanogents"

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    if python3 -c "import nanobot" &>/dev/null; then
        print_ok "nanogents already installed"
        read -p "  Reinstall / update? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    print_info "Installing in editable mode from source..."
    python3 -m pip install -e "$SCRIPT_DIR" --quiet 2>&1 | tail -3
    print_ok "nanogents installed successfully"

    # Verify
    if command -v nanobot &>/dev/null; then
        print_ok "nanobot command available: $(which nanobot)"
    else
        print_warn "'nanobot' not in PATH. You may need to add ~/.local/bin to your PATH"
        print_info "Run: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

# ── Step 3: Initialize workspace ──────────────────────────────────────────
init_workspace() {
    print_step 3 "Initializing workspace"

    NANOBOT_HOME="$HOME/.nanobot"
    WORKSPACE="$NANOBOT_HOME/workspace"

    mkdir -p "$WORKSPACE"
    print_ok "Config directory: $NANOBOT_HOME"
    print_ok "Workspace: $WORKSPACE"

    # Sync templates if available
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TEMPLATE_SRC="$SCRIPT_DIR/nanobot/templates"
    if [ -d "$TEMPLATE_SRC" ]; then
        for f in "$TEMPLATE_SRC"/*.md; do
            [ -f "$f" ] || continue
            BASENAME=$(basename "$f")
            if [ ! -f "$WORKSPACE/$BASENAME" ]; then
                cp "$f" "$WORKSPACE/$BASENAME"
            fi
        done
        print_ok "Templates synced to workspace"
    fi
}

# ── Step 4: Run interactive wizard ─────────────────────────────────────────
run_wizard() {
    print_step 4 "Interactive configuration"

    echo ""
    print_info "Launching setup wizard..."
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    python3 "$SCRIPT_DIR/scripts/wizard.py"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    print_banner
    install_system_deps
    install_nanogents
    init_workspace
    run_wizard

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │                                             │"
    echo "  │        ✅  Setup complete!                  │"
    echo "  │                                             │"
    echo "  │   Quick start:                              │"
    echo "  │     nanobot agent          # chat mode      │"
    echo "  │     nanobot gateway        # start gateway  │"
    echo "  │     nanobot status         # check status   │"
    echo "  │                                             │"
    echo "  │   Config: ~/.nanobot/config.json            │"
    echo "  │                                             │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"
}

main "$@"
