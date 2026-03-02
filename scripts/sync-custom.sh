#!/usr/bin/env bash
# ============================================================================
#  nanogents - Sync customizations between repo and ~/.nanobot/
#
#  Usage:
#    bash scripts/sync-custom.sh push    # ~/.nanobot/ → repo (backup)
#    bash scripts/sync-custom.sh pull    # repo → ~/.nanobot/ (restore)
#    bash scripts/sync-custom.sh status  # show what differs
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CUSTOM_DIR="$PROJECT_DIR/custom"
NANOBOT_HOME="$HOME/.nanobot"

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

# What we sync (relative to ~/.nanobot/)
SYNC_DIRS=(
    "workspace"       # SOUL.md, USER.md, AGENTS.md, TOOLS.md, HEARTBEAT.md
)

SYNC_FILES=(
    "config.json"     # provider/channel/tool config (secrets stripped)
)

# Files/patterns to exclude (secrets, logs, temp data)
EXCLUDE_PATTERNS=(
    "*.log"
    "whatsapp-auth/"
    ".setup_state"
    ".bridge.pid"
    ".gateway.pid"
    "logs/"
    "memory/HISTORY.md"   # Full conversation logs — too sensitive for git
)

# ── Strip secrets from config before backing up ─────────────────────────────
strip_secrets() {
    local src="$1"
    local dst="$2"
    python3 -c "
import json, re, sys

with open('$src') as f:
    config = json.load(f)

def redact(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            key_lower = k.lower()
            if any(s in key_lower for s in ['key', 'token', 'secret', 'password']):
                if isinstance(v, str) and v and v not in ('', 'no-key'):
                    obj[k] = '*** SET VIA WIZARD ***'
            else:
                redact(v, f'{path}.{k}')
    elif isinstance(obj, list):
        for item in obj:
            redact(item, path)

redact(config)

with open('$dst', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" 2>/dev/null
}

# ── Scrub secrets from MEMORY.md before backing up ───────────────────────────
scrub_memory() {
    local src="$1"
    local dst="$2"

    if [ ! -f "$src" ]; then
        return
    fi

    python3 -c "
import re, sys

with open('$src') as f:
    text = f.read()

# Redact common secret patterns
patterns = [
    # API keys: sk-xxx, ghp_xxx, bot12345:xxx, etc.
    (r'(sk-[a-zA-Z0-9_-]{10,})', '***REDACTED_KEY***'),
    (r'(ghp_[a-zA-Z0-9]{30,})', '***REDACTED_KEY***'),
    (r'(bot[0-9]+:[a-zA-Z0-9_-]{30,})', '***REDACTED_TOKEN***'),
    (r'(xoxb-[a-zA-Z0-9-]+)', '***REDACTED_TOKEN***'),
    # IP addresses (keep localhost/private ranges, redact public)
    (r'\b(?!127\.0\.0\.1|10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b', '***REDACTED_IP***'),
    # Passwords in common formats
    (r'(password|passwd|pwd)\s*[:=]\s*\S+', r'\1: ***REDACTED***'),
    # Bearer tokens
    (r'(Bearer\s+)[a-zA-Z0-9._-]{20,}', r'\1***REDACTED***'),
    # Generic long hex strings (likely keys/hashes)
    (r'\b[a-f0-9]{40,}\b', '***REDACTED_HASH***'),
]

for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)

with open('$dst', 'w') as f:
    f.write(text)
" 2>/dev/null
}

# ── Build rsync exclude args ────────────────────────────────────────────────
build_excludes() {
    local args=()
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args+=(--exclude "$pattern")
    done
    echo "${args[@]}"
}

# ── Push: ~/.nanobot/ → repo/custom/ ────────────────────────────────────────
do_push() {
    echo ""
    echo -e "  ${BOLD}Backing up customizations → repo${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"

    local count=0

    # Sync workspace directory (excludes HISTORY.md, scrubs MEMORY.md)
    for dir in "${SYNC_DIRS[@]}"; do
        local src="$NANOBOT_HOME/$dir"
        local dst="$CUSTOM_DIR/$dir"
        if [ -d "$src" ]; then
            mkdir -p "$dst"
            rsync -a --delete $(build_excludes) "$src/" "$dst/"
            ok "Synced $dir/"
            count=$((count + 1))

            # Scrub secrets from MEMORY.md if it was synced
            local memory_file="$dst/memory/MEMORY.md"
            if [ -f "$memory_file" ]; then
                scrub_memory "$memory_file" "$memory_file"
                ok "Scrubbed secrets from MEMORY.md"
            fi
        else
            info "Skipped $dir/ (not found)"
        fi
    done

    # Sync config (with secrets stripped)
    for file in "${SYNC_FILES[@]}"; do
        local src="$NANOBOT_HOME/$file"
        local dst="$CUSTOM_DIR/$file"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            if [ "$file" = "config.json" ]; then
                strip_secrets "$src" "$dst"
                ok "Synced $file (secrets redacted)"
            else
                cp "$src" "$dst"
                ok "Synced $file"
            fi
            count=$((count + 1))
        else
            info "Skipped $file (not found)"
        fi
    done

    echo ""
    if [ "$count" -gt 0 ]; then
        ok "Backed up $count item(s) to custom/"
        echo ""
        info "Now commit and push:"
        echo -e "    ${DIM}git add custom/ && git commit -m 'Update customizations' && git push${NC}"
    else
        warn "Nothing to back up. Set up your workspace first."
    fi
    echo ""
}

# ── Pull: repo/custom/ → ~/.nanobot/ ────────────────────────────────────────
do_pull() {
    echo ""
    echo -e "  ${BOLD}Restoring customizations → ~/.nanobot/${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"

    local count=0

    # Restore workspace directory
    for dir in "${SYNC_DIRS[@]}"; do
        local src="$CUSTOM_DIR/$dir"
        local dst="$NANOBOT_HOME/$dir"
        if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
            mkdir -p "$dst"
            rsync -a $(build_excludes) "$src/" "$dst/"
            ok "Restored $dir/"
            count=$((count + 1))
        else
            info "Skipped $dir/ (not in repo)"
        fi
    done

    # Restore config — merge with existing (don't overwrite secrets)
    for file in "${SYNC_FILES[@]}"; do
        local src="$CUSTOM_DIR/$file"
        local dst="$NANOBOT_HOME/$file"
        if [ -f "$src" ]; then
            if [ "$file" = "config.json" ]; then
                if [ -f "$dst" ]; then
                    # Merge: keep existing secrets, apply structure from repo
                    python3 -c "
import json

with open('$src') as f:
    repo = json.load(f)
with open('$dst') as f:
    local = json.load(f)

def deep_merge(base, overlay):
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        elif isinstance(v, str) and '***' in v:
            pass  # Keep local secret
        else:
            base[k] = v

deep_merge(local, repo)

with open('$dst', 'w') as f:
    json.dump(local, f, indent=2)
    f.write('\n')
" 2>/dev/null
                    ok "Merged $file (kept existing secrets)"
                else
                    cp "$src" "$dst"
                    warn "Restored $file (secrets are placeholders — run wizard to set them)"
                fi
            else
                cp "$src" "$dst"
                ok "Restored $file"
            fi
            count=$((count + 1))
        fi
    done

    echo ""
    if [ "$count" -gt 0 ]; then
        ok "Restored $count item(s) to ~/.nanobot/"
        if grep -q 'SET VIA WIZARD' "$NANOBOT_HOME/config.json" 2>/dev/null; then
            echo ""
            warn "Config has placeholder secrets. Run the wizard to set API keys:"
            echo -e "    ${DIM}python3 scripts/wizard.py${NC}"
        fi
    else
        warn "Nothing to restore. Push your customizations first."
    fi
    echo ""
}

# ── Status: show what differs ────────────────────────────────────────────────
do_status() {
    echo ""
    echo -e "  ${BOLD}Customization sync status${NC}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..45})${NC}"

    local has_diff=false

    for dir in "${SYNC_DIRS[@]}"; do
        local src="$NANOBOT_HOME/$dir"
        local dst="$CUSTOM_DIR/$dir"
        if [ -d "$src" ] && [ -d "$dst" ]; then
            local diff_output
            diff_output=$(diff -rq "$src" "$dst" 2>/dev/null | grep -v '__pycache__' || true)
            if [ -n "$diff_output" ]; then
                warn "$dir/ has changes"
                echo "$diff_output" | head -5 | sed 's/^/      /'
                has_diff=true
            else
                ok "$dir/ in sync"
            fi
        elif [ -d "$src" ] && [ ! -d "$dst" ]; then
            warn "$dir/ exists locally but not in repo (run push)"
            has_diff=true
        elif [ ! -d "$src" ] && [ -d "$dst" ]; then
            warn "$dir/ exists in repo but not locally (run pull)"
            has_diff=true
        else
            info "$dir/ not set up yet"
        fi
    done

    for file in "${SYNC_FILES[@]}"; do
        local src="$NANOBOT_HOME/$file"
        local dst="$CUSTOM_DIR/$file"
        if [ -f "$src" ] && [ -f "$dst" ]; then
            # Compare structure only (ignore secret values)
            local keys_src keys_dst
            keys_src=$(python3 -c "
import json
def keys(o,p=''):
    if isinstance(o,dict):
        for k,v in sorted(o.items()):
            print(f'{p}.{k}')
            keys(v,f'{p}.{k}')
keys(json.load(open('$src')))
" 2>/dev/null || echo "?")
            keys_dst=$(python3 -c "
import json
def keys(o,p=''):
    if isinstance(o,dict):
        for k,v in sorted(o.items()):
            print(f'{p}.{k}')
            keys(v,f'{p}.{k}')
keys(json.load(open('$dst')))
" 2>/dev/null || echo "?")
            if [ "$keys_src" = "$keys_dst" ]; then
                ok "$file structure in sync"
            else
                warn "$file structure differs (run push to update)"
                has_diff=true
            fi
        elif [ -f "$src" ] && [ ! -f "$dst" ]; then
            warn "$file exists locally but not in repo (run push)"
            has_diff=true
        fi
    done

    echo ""
    if $has_diff; then
        info "Run 'bash scripts/sync-custom.sh push' to back up changes"
    else
        ok "Everything in sync"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        push|backup)
            do_push
            ;;
        pull|restore)
            do_pull
            ;;
        status|diff)
            do_status
            ;;
        *)
            echo ""
            echo -e "  ${BOLD}Usage:${NC} bash scripts/sync-custom.sh <command>"
            echo ""
            echo "  Commands:"
            echo "    push     Back up ~/.nanobot/ customizations → repo"
            echo "    pull     Restore repo customizations → ~/.nanobot/"
            echo "    status   Show what differs between local and repo"
            echo ""
            echo "  Syncs: workspace/ (SOUL.md, skills, etc.) and config.json (secrets stripped)"
            echo ""
            ;;
    esac
}

main "$@"
