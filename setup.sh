#!/usr/bin/env bash
# setup.sh — Fresh VPS setup for a standalone OpenClaw deployment.
# Installs: Docker, Tailscale (optional), UFW.
#
# Usage: sudo bash setup.sh
#
# Safe to re-run — skips already-installed tools.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root or with sudo"
    exit 1
fi

echo "=== Fresh OpenClaw — VPS Setup ==="
echo ""

# ── 1. System update ─────────────────────────────────────────────────────────
echo "[1/4] System update..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget git jq ufw
echo "  done"

# ── 2. Docker ────────────────────────────────────────────────────────────────
echo "[2/4] Docker..."
if command -v docker &>/dev/null; then
    echo "  already installed ($(docker --version | cut -d' ' -f3 | tr -d ',')) — skipping"
else
    curl -fsSL https://get.docker.com | sh
    echo "  installed"
fi

if ! docker compose version &>/dev/null; then
    echo "  WARNING: docker compose plugin not found"
fi
echo "  done"

# ── 3. Tailscale (optional) ───────────────────────────────────────────────────
echo "[3/4] Tailscale..."
if command -v tailscale &>/dev/null; then
    echo "  already installed — skipping"
else
    read -rp "  Install Tailscale? [y/N]: " INSTALL_TS
    if [[ "${INSTALL_TS,,}" == "y" ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        echo "  installed — run 'tailscale up' to connect"
    else
        echo "  skipped"
    fi
fi
echo "  done"

# ── 4. UFW firewall ──────────────────────────────────────────────────────────
echo "[4/4] UFW firewall..."
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1

if ! ufw status | grep -q 'Status: active'; then
    ufw --force enable >/dev/null 2>&1
fi

echo "  open: SSH only"
echo ""
echo "  NOTE: Docker port publishing bypasses UFW."
echo "  All ports in docker-compose.yml are bound to 127.0.0.1 — do not change this."
echo "  done"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Copy this directory to the server"
echo "  2. Run: bash deploy.sh"
echo ""
