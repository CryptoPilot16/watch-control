#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

echo "Stopping existing services..."
pkill -f "approve_webhook.py" 2>/dev/null || true
pkill -f "codex_watch.sh" 2>/dev/null || true
sleep 1

echo "Starting approve_webhook.py..."
nohup python3 "$SCRIPT_DIR/approve_webhook.py" >> /tmp/watchcontrol_webhook.log 2>&1 &
WEBHOOK_PID=$!

echo "Starting codex_watch.sh..."
nohup bash "$SCRIPT_DIR/codex_watch.sh" >> /tmp/watchcontrol_watch.log 2>&1 &
WATCH_PID=$!

echo "✓ Webhook started (pid $WEBHOOK_PID) — listening on :${APPROVE_PORT:-8787}"
echo "✓ Watcher started (pid $WATCH_PID)"
echo ""
echo "Logs:"
echo "  tail -f /tmp/watchcontrol_webhook.log"
echo "  tail -f /tmp/watchcontrol_watch.log"
