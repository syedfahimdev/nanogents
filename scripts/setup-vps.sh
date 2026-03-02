#!/usr/bin/env bash
# First-time VPS setup. Run this once on a fresh server.
# Usage: ssh root@your-vps 'bash -s' < scripts/setup-vps.sh

set -euo pipefail

echo "==> Updating system..."
apt-get update && apt-get upgrade -y

echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

echo "==> Installing Docker Compose plugin..."
if ! docker compose version &>/dev/null; then
    apt-get install -y docker-compose-plugin
fi

echo "==> Installing git..."
apt-get install -y git

echo "==> Creating project directory..."
mkdir -p /opt/nanogents

echo "==> Setting up nanobot config directory..."
mkdir -p /root/.nanobot/workspace

echo ""
echo "==> VPS is ready!"
echo ""
echo "Next steps:"
echo "  1. Clone your repo:  git clone https://github.com/syedfahimdev/nanogents.git /opt/nanogents"
echo "  2. Configure:        nano /root/.nanobot/config.json"
echo "  3. Deploy:           cd /opt/nanogents && docker compose -f docker-compose.prod.yml up -d"
echo ""
echo "Or from your local machine:"
echo "  ./scripts/deploy.sh your-vps-ip"
