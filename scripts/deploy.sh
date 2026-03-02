#!/usr/bin/env bash
# Deploy nanogents to your VPS.
# Usage: ./scripts/deploy.sh [host] [user] [path]
#
# Defaults can be set via .env or environment variables:
#   DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

HOST="${1:-${DEPLOY_HOST:-}}"
USER="${2:-${DEPLOY_USER:-root}}"
REMOTE_PATH="${3:-${DEPLOY_PATH:-/opt/nanogents}}"

if [ -z "$HOST" ]; then
    echo "Usage: $0 <host> [user] [path]"
    echo "   or: set DEPLOY_HOST in .env"
    exit 1
fi

REMOTE="$USER@$HOST"

echo "==> Deploying to $REMOTE:$REMOTE_PATH"

# Ensure remote directory exists
ssh "$REMOTE" "mkdir -p $REMOTE_PATH"

# Sync project files (exclude dev files and .git)
rsync -avz --delete \
    --exclude '.git' \
    --exclude '.env' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.venv' \
    --exclude 'venv' \
    --exclude 'node_modules' \
    --exclude '.pytest_cache' \
    --exclude '*.egg-info' \
    --exclude 'dist' \
    --exclude 'build' \
    "$PROJECT_DIR/" "$REMOTE:$REMOTE_PATH/"

echo "==> Building and restarting on VPS..."
ssh "$REMOTE" "cd $REMOTE_PATH && docker compose -f docker-compose.prod.yml build && docker compose -f docker-compose.prod.yml up -d"

echo ""
echo "==> Deployed! Check status:"
echo "    ssh $REMOTE 'cd $REMOTE_PATH && docker compose -f docker-compose.prod.yml logs -f'"
