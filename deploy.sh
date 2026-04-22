#!/usr/bin/env bash
# deploy.sh — Fresh OpenClaw deployment.
# Assumes setup.sh has already been run on this VPS.
#
# Usage:
#   bash deploy.sh            — deploy a new client
#   bash deploy.sh destroy    — stop and remove a client

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENTS_BASE="$HOME/oc-deployments"

fix_perms() {
    docker run --rm -u root \
        -v "$CONFIG_DIR:/data" \
        ghcr.io/openclaw/openclaw:latest \
        chmod -R a+rwX /data
}

# ── Destroy mode ──────────────────────────────────────────────────────────────
if [ "${1:-}" == "destroy" ]; then
    read -rp "  Client name to destroy: " CLIENT_NAME
    CLIENT_NAME=$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    DEPLOY_DIR="$DEPLOYMENTS_BASE/$CLIENT_NAME"

    if [ ! -d "$DEPLOY_DIR" ]; then
        echo "ERROR: $DEPLOY_DIR not found."
        exit 1
    fi

    read -rp "  Destroy $DEPLOY_DIR? This is permanent. [y/N]: " CONFIRM
    if [[ ! "${CONFIRM,,}" == "y" ]]; then
        echo "  Aborted."
        exit 0
    fi

    CONFIG_DIR="$DEPLOY_DIR/openclaw-home/.openclaw"
    cd "$DEPLOY_DIR"
    docker compose down 2>/dev/null || true
    fix_perms
    rm -rf "$DEPLOY_DIR"
    echo "  $CLIENT_NAME destroyed."
    exit 0
fi

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

QMD_PATH=$(grep '^QMD_PATH=' "$SCRIPT_DIR/.env.example" | cut -d= -f2)
if [ -z "$QMD_PATH" ] || [ ! -d "$QMD_PATH" ]; then
    echo "ERROR: QMD not found at $QMD_PATH"
    echo "  Install QMD first:"
    echo "    docker run --rm -u root \\"
    echo "      -v \$HOME/.local/lib/qmd-node24:/opt/qmd \\"
    echo "      ghcr.io/openclaw/openclaw:latest \\"
    echo "      sh -c \"cd /opt/qmd && npm init -y && npm install @tobilu/qmd\""
    exit 1
fi

# ── Phase 1: Generate token + write .env ─────────────────────────────────────
echo "[1/6] Generating config..."

# Auto-assign port: scan existing deployments for highest port, add 10
GATEWAY_PORT=18789
MAX_PORT=0
for envfile in "$DEPLOYMENTS_BASE"/*/.env; do
    [ -f "$envfile" ] || continue
    PORT=$(grep -o 'GATEWAY_PORT=[0-9]*' "$envfile" 2>/dev/null | grep -o '[0-9]*' || true)
    if [ -n "$PORT" ] && [ "$PORT" -gt "$MAX_PORT" ]; then
        MAX_PORT=$PORT
    fi
done
if [ "$MAX_PORT" -gt 0 ]; then
    GATEWAY_PORT=$((MAX_PORT + 10))
fi
BRIDGE_PORT=$((GATEWAY_PORT + 1))

mkdir -p "$DEPLOY_DIR/openclaw-home/.openclaw/workspace"
chmod -R a+rwX "$DEPLOY_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/openclaw-home/.openclaw/openclaw.json" "$DEPLOY_DIR/openclaw.json"

GATEWAY_TOKEN=$(openssl rand -hex 24)
sed \
    -e "s/replace-with-your-token/$GATEWAY_TOKEN/" \
    -e "s/^GATEWAY_PORT=.*/GATEWAY_PORT=$GATEWAY_PORT/" \
    -e "s/^BRIDGE_PORT=.*/BRIDGE_PORT=$BRIDGE_PORT/" \
    "$SCRIPT_DIR/.env.example" > "$DEPLOY_DIR/.env"

echo "  gateway port: $GATEWAY_PORT"
echo "  done"

# ── Phase 2: Pull image ───────────────────────────────────────────────────────
echo "[2/6] Pulling OpenClaw image..."
cd "$DEPLOY_DIR"
docker compose pull
echo "  done"

# ── Phase 3: openclaw setup ───────────────────────────────────────────────────
echo "[3/6] Running openclaw setup..."

# Setup initializes internal state and generates openclaw.json
docker compose run --rm openclaw-cli setup

fix_perms

# Merge our settings into the setup-generated openclaw.json.
# * does a deep merge — setup's device pairing + token state is preserved.
# We exclude gateway.auth from our file so setup's generated token wins.
SETUP_JSON=$(cat "$CONFIG_DIR/openclaw.json")
OUR_JSON=$(jq 'del(.gateway.auth)' "$DEPLOY_DIR/openclaw.json")
echo "$SETUP_JSON" > /tmp/setup.json
echo "$OUR_JSON" > /tmp/ours.json
jq -s '.[0] * .[1]' /tmp/setup.json /tmp/ours.json > "$CONFIG_DIR/openclaw.json"
rm /tmp/setup.json /tmp/ours.json

# Sync .env token to match what setup generated
GATEWAY_TOKEN=$(jq -r '.gateway.auth.token' "$CONFIG_DIR/openclaw.json")
sed -i "s/^GATEWAY_TOKEN=.*/GATEWAY_TOKEN=$GATEWAY_TOKEN/" "$DEPLOY_DIR/.env"

echo "  merged config into setup-generated openclaw.json"
echo "  done"

# ── Phase 4: Configure model + channel (optional) ────────────────────────────
echo ""
read -rp "  Configure model and channel now? [y/N]: " CONFIGURE_NOW

if [[ "${CONFIGURE_NOW,,}" == "y" ]]; then
    echo "[4/5] Model configuration..."
    echo "  This will ask for your AI provider and API key."
    echo ""
    docker compose run --rm openclaw-cli configure
    fix_perms
    echo "  done"

    echo "[5/5] Channel setup..."
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
        *) CHANNEL_CHOICE=4 ;;
    esac

    if [ "${CHANNEL_CHOICE}" != "4" ]; then
        docker compose run --rm openclaw-cli channels add --channel "$CHANNEL"
        fix_perms
        docker compose restart openclaw-gateway
        echo "  channel connected and gateway restarted"
    fi
fi

# ── Start gateway ─────────────────────────────────────────────────────────────
echo "[4/4] Starting gateway..."
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

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==================================="
echo "  OpenClaw is running"
echo "==================================="
echo ""
echo "  Location: $DEPLOY_DIR"
echo "  Logs:     cd $DEPLOY_DIR && docker compose logs -f"
echo ""
echo "  When ready:"
echo "  cd $DEPLOY_DIR"
echo "  docker compose run --rm openclaw-cli configure"
echo "  docker compose run --rm openclaw-cli channels add --channel slack"
echo "  docker compose restart openclaw-gateway"
echo ""
