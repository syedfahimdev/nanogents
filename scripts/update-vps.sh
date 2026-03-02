#!/usr/bin/env bash
# Quick update: sync upstream, push, and redeploy.
# Usage: ./scripts/update-vps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Step 1: Sync with upstream..."
"$SCRIPT_DIR/sync-upstream.sh"

echo ""
echo "==> Step 2: Deploy to VPS..."
"$SCRIPT_DIR/deploy.sh"

echo ""
echo "==> All done! Upstream synced and VPS updated."
