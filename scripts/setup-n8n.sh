#!/usr/bin/env bash
# ============================================================================
#  nanogents - n8n Setup Script
#
#  Sets up n8n with:
#    - Docker Compose (Postgres + n8n)
#    - Reverse proxy with SSL: Caddy (recommended) or Nginx
#    - Connects to nanobot as MCP server
#
#  Usage:
#    bash scripts/setup-n8n.sh                 # interactive setup
#    bash scripts/setup-n8n.sh --stop          # stop n8n
#    bash scripts/setup-n8n.sh --status        # check status
#    bash scripts/setup-n8n.sh --uninstall     # remove everything
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

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

# ── Check prerequisites ──────────────────────────────────────────────────────
check_prereqs() {
    local missing=false

    if ! command -v docker &>/dev/null; then
        err "Docker not found. Install it first: curl -fsSL https://get.docker.com | sh"
        missing=true
    fi

    if ! docker compose version &>/dev/null; then
        err "Docker Compose not found."
        missing=true
    fi

    if $missing; then
        exit 1
    fi
}

# ── Load or create .env ──────────────────────────────────────────────────────
setup_env() {
    echo ""
    echo -e "  ${BOLD}n8n Configuration${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""

    # Load existing .env
    if [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi

    # Domain
    local current_domain="${N8N_DOMAIN:-}"
    read -rp "  $(echo -e "${CYAN}?${NC}") n8n domain (e.g. n8n.mysite.com) [$current_domain]: " input_domain
    N8N_DOMAIN="${input_domain:-$current_domain}"

    if [ -z "$N8N_DOMAIN" ]; then
        err "Domain is required. Example: n8n.mysite.com"
        exit 1
    fi

    N8N_URL="https://$N8N_DOMAIN"

    # Encryption key
    if [ -z "${N8N_ENCRYPTION_KEY:-}" ]; then
        N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
        ok "Generated encryption key"
    else
        ok "Encryption key already set"
    fi

    # Database password
    if [ -z "${N8N_DB_PASSWORD:-}" ] || [ "${N8N_DB_PASSWORD}" = "changeme" ]; then
        N8N_DB_PASSWORD=$(openssl rand -hex 16)
        ok "Generated database password"
    else
        ok "Database password already set"
    fi

    # Write to .env (append/update n8n vars)
    _update_env "N8N_DOMAIN" "$N8N_DOMAIN"
    _update_env "N8N_URL" "$N8N_URL"
    _update_env "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY"
    _update_env "N8N_DB_USER" "${N8N_DB_USER:-n8n}"
    _update_env "N8N_DB_PASSWORD" "$N8N_DB_PASSWORD"
    _update_env "N8N_DB_NAME" "${N8N_DB_NAME:-n8n}"

    ok "Saved to $ENV_FILE"
    echo ""
}

_update_env() {
    local key="$1" val="$2"
    touch "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

# ── Choose reverse proxy ─────────────────────────────────────────────────────
choose_proxy() {
    echo -e "  ${BOLD}Reverse Proxy${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""
    echo -e "  ${CYAN}?${NC} Which reverse proxy to use for SSL?"
    echo ""
    echo -e "    ${GREEN}●${NC} 1) ${BOLD}Caddy (recommended)${NC}  ${DIM}Auto SSL, zero config, simple${NC}"
    echo -e "    ${DIM}○${NC} 2) Nginx + Certbot     ${DIM}Traditional, more control${NC}"
    echo -e "    ${DIM}○${NC} 3) Skip                ${DIM}I'll handle SSL myself${NC}"
    echo ""

    local choice
    read -rp "    Enter number [1]: " choice
    choice="${choice:-1}"

    PROXY_CHOICE="${choice}"
    _update_env "N8N_PROXY" "${choice}"
}

# ── Caddy setup ──────────────────────────────────────────────────────────────
setup_caddy() {
    echo ""
    echo -e "  ${BOLD}Setting up Caddy${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""

    # Install Caddy if needed
    if ! command -v caddy &>/dev/null; then
        info "Installing Caddy..."
        apt-get update -qq
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt-get update -qq && apt-get install -y -qq caddy >/dev/null 2>&1
        ok "Caddy installed"
    else
        ok "Caddy already installed"
    fi

    # Create Caddyfile
    local CADDYFILE="/etc/caddy/Caddyfile"

    # Preserve existing entries, add/replace n8n block
    if [ -f "$CADDYFILE" ]; then
        # Remove existing n8n block if present
        sed -i "/^${N8N_DOMAIN//./\\.} {/,/^}/d" "$CADDYFILE" 2>/dev/null || true
    fi

    cat >> "$CADDYFILE" <<CADDY

${N8N_DOMAIN} {
    reverse_proxy 127.0.0.1:5678 {
        header_up X-Forwarded-Proto {scheme}
    }
    request_body {
        max_size 100MB
    }
}
CADDY

    # Validate config
    if caddy validate --config "$CADDYFILE" 2>/dev/null; then
        ok "Caddyfile valid"
    else
        err "Caddyfile error. Check: caddy validate --config $CADDYFILE"
        exit 1
    fi

    systemctl enable caddy 2>/dev/null || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy

    ok "Caddy configured for ${N8N_DOMAIN}"
    ok "SSL auto-provisioned (Let's Encrypt, auto-renew)"
    echo ""
}

# ── Nginx setup ──────────────────────────────────────────────────────────────
setup_nginx() {
    echo ""
    echo -e "  ${BOLD}Setting up Nginx + SSL${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""

    # Install nginx + certbot if needed
    if ! command -v nginx &>/dev/null; then
        info "Installing Nginx..."
        apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1
        ok "Nginx installed"
    else
        ok "Nginx already installed"
    fi

    if ! command -v certbot &>/dev/null; then
        info "Installing Certbot..."
        apt-get install -y -qq certbot python3-certbot-nginx >/dev/null 2>&1
        ok "Certbot installed"
    else
        ok "Certbot already installed"
    fi

    # Create Nginx config
    local NGINX_CONF="/etc/nginx/sites-available/n8n"
    cat > "$NGINX_CONF" <<NGINX
server {
    listen 80;
    server_name ${N8N_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        client_max_body_size 100M;
    }
}
NGINX

    # Enable site
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/n8n
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    if nginx -t 2>/dev/null; then
        ok "Nginx config valid"
    else
        err "Nginx config error. Check: nginx -t"
        exit 1
    fi

    systemctl reload nginx
    ok "Nginx configured for ${N8N_DOMAIN}"

    # SSL certificate
    echo ""
    info "Getting SSL certificate from Let's Encrypt..."
    echo ""

    local email=""
    read -rp "  $(echo -e "${CYAN}?${NC}") Email for SSL notifications (optional): " email

    local certbot_args=(
        --nginx
        -d "$N8N_DOMAIN"
        --non-interactive
        --agree-tos
        --redirect
    )

    if [ -n "$email" ]; then
        certbot_args+=(--email "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    if certbot "${certbot_args[@]}" 2>/dev/null; then
        ok "SSL certificate installed"
        ok "Auto-renewal enabled (certbot timer)"
    else
        warn "SSL failed — n8n will work on HTTP only"
        warn "Make sure DNS for ${N8N_DOMAIN} points to this server"
        warn "Then retry: certbot --nginx -d ${N8N_DOMAIN}"
    fi

    echo ""
}

# ── Start n8n ─────────────────────────────────────────────────────────────────
start_n8n() {
    echo -e "  ${BOLD}Starting n8n${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""

    cd "$PROJECT_DIR"

    docker compose -f docker-compose.prod.yml --profile n8n up -d

    # Wait for n8n to be healthy
    info "Waiting for n8n to start..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
        ok "n8n is running"
    else
        warn "n8n not responding yet — it may still be starting"
        info "Check: docker compose -f docker-compose.prod.yml logs n8n"
    fi

    echo ""
}

# ── Connect to nanobot ────────────────────────────────────────────────────────
connect_nanobot() {
    echo -e "  ${BOLD}Connect n8n to nanobot${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"
    echo ""

    info "To use n8n workflows as tools in nanobot:"
    echo ""
    echo -e "  1. Open ${CYAN}https://${N8N_DOMAIN}${NC} and create your account"
    echo ""
    echo -e "  2. Create a workflow with an ${BOLD}MCP Server Trigger${NC} node"
    echo ""
    echo -e "  3. Add to ${BOLD}~/.nanobot/config.json${NC}:"
    echo ""
    echo -e "     ${DIM}\"tools\": {"
    echo -e "       \"mcpServers\": {"
    echo -e "         \"n8n\": {"
    echo -e "           \"url\": \"https://${N8N_DOMAIN}/mcp\","
    echo -e "           \"headers\": {"
    echo -e "             \"Authorization\": \"Bearer <your-n8n-api-key>\""
    echo -e "           }"
    echo -e "         }"
    echo -e "       }"
    echo -e "     }${NC}"
    echo ""
    echo -e "  4. Restart nanobot: ${CYAN}bash scripts/start.sh --stop && bash scripts/start.sh${NC}"
    echo ""
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "  ${BOLD}n8n status${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"

    cd "$PROJECT_DIR"

    if docker compose -f docker-compose.prod.yml ps --format '{{.Name}}' 2>/dev/null | grep -q n8n; then
        local n8n_state
        n8n_state=$(docker inspect --format '{{.State.Status}}' n8n 2>/dev/null || echo "not found")
        local pg_state
        pg_state=$(docker inspect --format '{{.State.Status}}' n8n-postgres 2>/dev/null || echo "not found")

        if [ "$n8n_state" = "running" ]; then
            ok "n8n: running"
        else
            err "n8n: $n8n_state"
        fi

        if [ "$pg_state" = "running" ]; then
            ok "PostgreSQL: running"
        else
            err "PostgreSQL: $pg_state"
        fi
    else
        err "n8n containers not found"
        info "Start with: bash scripts/setup-n8n.sh"
    fi

    # Check reverse proxy
    if systemctl is-active --quiet caddy 2>/dev/null; then
        ok "Caddy: running (auto-SSL)"
    elif [ -f /etc/nginx/sites-enabled/n8n ] && systemctl is-active --quiet nginx 2>/dev/null; then
        ok "Nginx: running"
        # Check SSL cert
        if [ -n "${N8N_DOMAIN:-}" ] && [ -d "/etc/letsencrypt/live/${N8N_DOMAIN}" ]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${N8N_DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2)
            ok "SSL: valid until $expiry"
        fi
    else
        info "Reverse proxy: not detected"
    fi

    echo ""
    if [ -n "${N8N_DOMAIN:-}" ]; then
        echo -e "  ${BOLD}URL:${NC}  https://${N8N_DOMAIN}"
    fi
    echo -e "  ${BOLD}Logs:${NC} docker compose -f docker-compose.prod.yml logs -f n8n"
    echo ""
}

# ── Stop ──────────────────────────────────────────────────────────────────────
stop_n8n() {
    echo ""
    echo -e "  ${BOLD}Stopping n8n...${NC}"
    cd "$PROJECT_DIR"
    docker compose -f docker-compose.prod.yml --profile n8n stop n8n n8n-postgres
    ok "n8n stopped (data preserved)"
    echo ""
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall_n8n() {
    echo ""
    warn "This will remove n8n containers, database, and proxy config."
    read -rp "  $(echo -e "${CYAN}?${NC}") Are you sure? [y/N]: " confirm
    if [ "${confirm,,}" != "y" ]; then
        info "Cancelled"
        return
    fi

    cd "$PROJECT_DIR"

    # Stop and remove containers + volumes
    docker compose -f docker-compose.prod.yml --profile n8n down -v --remove-orphans 2>/dev/null || true
    ok "Containers and volumes removed"

    # Remove Caddy config
    if [ -f /etc/caddy/Caddyfile ] && [ -n "${N8N_DOMAIN:-}" ]; then
        sed -i "/^${N8N_DOMAIN//./\\.} {/,/^}/d" /etc/caddy/Caddyfile 2>/dev/null || true
        systemctl reload caddy 2>/dev/null || true
        ok "Caddy config removed"
    fi

    # Remove Nginx config
    rm -f /etc/nginx/sites-enabled/n8n /etc/nginx/sites-available/n8n 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true
    ok "Nginx config removed"

    # Remove SSL cert (certbot)
    if [ -n "${N8N_DOMAIN:-}" ]; then
        certbot delete --cert-name "$N8N_DOMAIN" --non-interactive 2>/dev/null || true
    fi

    # Clean .env
    for key in N8N_DOMAIN N8N_URL N8N_ENCRYPTION_KEY N8N_DB_USER N8N_DB_PASSWORD N8N_DB_NAME N8N_PROXY; do
        sed -i "/^${key}=/d" "$ENV_FILE" 2>/dev/null || true
    done

    ok "n8n fully removed"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --stop)
            [ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
            stop_n8n
            ;;
        --status)
            [ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
            show_status
            ;;
        --uninstall)
            [ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
            uninstall_n8n
            ;;
        --help|-h)
            echo ""
            echo -e "  ${BOLD}Usage:${NC} bash scripts/setup-n8n.sh [option]"
            echo ""
            echo "  Options:"
            echo "    (none)        Interactive setup (Docker + reverse proxy + SSL)"
            echo "    --status      Show n8n status"
            echo "    --stop        Stop n8n (data preserved)"
            echo "    --uninstall   Remove n8n completely"
            echo ""
            ;;
        *)
            check_prereqs
            setup_env
            choose_proxy

            case "$PROXY_CHOICE" in
                1) setup_caddy ;;
                2) setup_nginx ;;
                3) info "Skipping proxy setup — configure SSL yourself" ; echo "" ;;
                *) setup_caddy ;;
            esac

            start_n8n
            connect_nanobot

            echo -e "  ${GREEN}${BOLD}n8n setup complete!${NC}"
            echo ""
            echo -e "  ${BOLD}Open:${NC} https://${N8N_DOMAIN}"
            echo -e "  ${BOLD}Stop:${NC} bash scripts/setup-n8n.sh --stop"
            echo ""
            ;;
    esac
}

main "$@"
