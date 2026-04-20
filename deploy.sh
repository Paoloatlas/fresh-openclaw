#!/usr/bin/env bash
# deploy.sh — Fresh OpenClaw deployment.
# Assumes setup.sh has already been run on this VPS.
#
# Usage: bash deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENTS_BASE="$HOME/oc-deployments"

echo "==================================="
echo "  Fresh OpenClaw — Deploy"
echo "==================================="
echo ""

# ── Client name ───────────────────────────────────────────────────────────────
read -rp "  Client name (e.g. sarah, acme-corp): " CLIENT_NAME
CLIENT_NAME=$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

if [ -z "$CLIENT_NAME" ]; then
    echo "ERROR: Client name is required."
    exit 1
fi

DEPLOY_DIR="$DEPLOYMENTS_BASE/$CLIENT_NAME"

if [ -d "$DEPLOY_DIR" ]; then
    echo "  WARNING: $DEPLOY_DIR already exists."
    read -rp "  Overwrite? [y/N]: " CONFIRM
    if [[ ! "${CONFIRM,,}" == "y" ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

mkdir -p "$DEPLOY_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/.env.example" "$DEPLOY_DIR/.env.example"
cp "$SCRIPT_DIR/openclaw.json" "$DEPLOY_DIR/openclaw.json"
mkdir -p "$DEPLOY_DIR/openclaw-home/.openclaw/workspace"

echo "  deploying to $DEPLOY_DIR"
echo ""

CONFIG_DIR="$DEPLOY_DIR/openclaw-home/.openclaw"
WORKSPACE_DIR="$CONFIG_DIR/workspace"

# ── Preflight ─────────────────────────────────────────────────────────────────
for cmd in docker jq openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed. Run setup.sh first."
        exit 1
    fi
done

if ! docker compose version &>/dev/null; then
    echo "ERROR: Docker Compose v2 is required. Run setup.sh first."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env.example" ]; then
    echo "ERROR: .env.example not found. Are you running from the fresh-openclaw directory?"
    exit 1
fi

# ── Phase 1: Generate token + write .env ─────────────────────────────────────
echo "[1/6] Generating config..."

if [ -f "$DEPLOY_DIR/.env" ]; then
    echo "  .env already exists — skipping token generation"
    source "$DEPLOY_DIR/.env"
else
    GATEWAY_TOKEN=$(openssl rand -hex 24)
    sed "s/replace-with-your-token/$GATEWAY_TOKEN/" "$SCRIPT_DIR/.env.example" > "$DEPLOY_DIR/.env"
    echo "  generated gateway token"
fi

source "$DEPLOY_DIR/.env"

if [ -z "${GATEWAY_TOKEN:-}" ]; then
    echo "ERROR: GATEWAY_TOKEN is not set in .env"
    exit 1
fi

if [ -z "${QMD_PATH:-}" ]; then
    echo "ERROR: QMD_PATH is not set in .env"
    echo "  Install QMD first:"
    echo "    docker run --rm -u root \\"
    echo "      -v \$HOME/.local/lib/qmd-node24:/opt/qmd \\"
    echo "      ghcr.io/openclaw/openclaw:latest \\"
    echo "      sh -c \"cd /opt/qmd && npm init -y && npm install @tobilu/qmd\""
    exit 1
fi

if [ ! -d "$QMD_PATH" ]; then
    echo "ERROR: QMD not found at $QMD_PATH"
    echo "  Check QMD_PATH in .env or install QMD first."
    exit 1
fi

# Patch token into openclaw.json
mkdir -p "$CONFIG_DIR"
jq --arg token "$GATEWAY_TOKEN" \
    '.gateway.auth.token = $token' \
    "$DEPLOY_DIR/openclaw.json" > "$CONFIG_DIR/openclaw.json"

echo "  patched token into openclaw.json"
echo "  done"

# ── Phase 2: Pull image ───────────────────────────────────────────────────────
echo "[2/6] Pulling OpenClaw image..."
cd "$DEPLOY_DIR"
docker compose pull
echo "  done"

# ── Phase 3: openclaw setup ───────────────────────────────────────────────────
echo "[3/6] Running openclaw setup..."

# Setup initializes internal state but overwrites openclaw.json — we restore ours after.
docker compose run --rm openclaw-cli setup

# Restore our openclaw.json (setup overwrites it)
jq --arg token "$GATEWAY_TOKEN" \
    '.gateway.auth.token = $token' \
    "$DEPLOY_DIR/openclaw.json" > "$CONFIG_DIR/openclaw.json"

echo "  restored openclaw.json with our config"
echo "  done"

# ── Phase 4: Configure model ──────────────────────────────────────────────────
echo "[4/6] Model configuration..."
echo "  This will ask for your AI provider and API key."
echo ""
docker compose run --rm openclaw-cli configure
echo "  done"

# ── Phase 5: Start gateway ────────────────────────────────────────────────────
echo "[5/6] Starting gateway..."
docker compose up -d

echo "  waiting for gateway to be healthy..."
RETRIES=0
MAX_RETRIES=12
until docker compose exec openclaw-gateway \
    node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
    2>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        echo ""
        echo "ERROR: Gateway did not become healthy after 60s."
        echo "  Check logs: docker compose logs openclaw-gateway"
        exit 1
    fi
    sleep 5
done

echo "  gateway is healthy"
echo "  done"

# ── Phase 6: Channel setup ────────────────────────────────────────────────────
echo "[6/6] Channel setup..."
echo ""
echo "  Which channel do you want to connect?"
echo "  1) Slack"
echo "  2) Telegram"
echo "  3) Discord"
echo "  4) Skip for now"
echo ""
read -rp "  Choice [1-4]: " CHANNEL_CHOICE

case "$CHANNEL_CHOICE" in
    1) CHANNEL="slack" ;;
    2) CHANNEL="telegram" ;;
    3) CHANNEL="discord" ;;
    4)
        echo "  Skipping — run this later:"
        echo "    docker compose run --rm openclaw-cli channels add --channel <type>"
        echo "    docker compose restart openclaw-gateway"
        ;;
    *)
        echo "  Invalid choice — skipping channel setup."
        CHANNEL_CHOICE=4
        ;;
esac

if [ "${CHANNEL_CHOICE}" != "4" ]; then
    docker compose run --rm openclaw-cli channels add --channel "$CHANNEL"
    docker compose restart openclaw-gateway
    echo "  channel connected and gateway restarted"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==================================="
echo "  OpenClaw is running"
echo "==================================="
echo ""
echo "  Gateway:  http://localhost:${GATEWAY_PORT:-18789}"
echo "  Location: $DEPLOY_DIR"
echo "  Logs:     cd $DEPLOY_DIR && docker compose logs -f"
echo "  TUI:      cd $DEPLOY_DIR && docker compose run --rm openclaw-cli tui --token $GATEWAY_TOKEN"
echo ""
echo "  Access the control UI via Tailscale:"
echo "  http://<tailscale-ip>:${GATEWAY_PORT:-18789}"
echo ""
