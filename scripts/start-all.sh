#!/usr/bin/env bash
# Start the doorbell PBX: the Asterisk container.
# The SIP clients are the TUI's baresip endpoints (see tui/README.md).
set -e
cd "$(dirname "$0")/.."

# Idempotent restart
docker compose -f docker/docker-compose.yml down 2>/dev/null || true
sleep 1

echo "=== Starting Asterisk container ==="
docker compose -f docker/docker-compose.yml up -d
sleep 3

echo ""
echo "=== PBX is running ==="
echo "  Asterisk:   doorbell-device container"
echo ""
echo "Next, start the TUI in another terminal:"
echo "  cd tui && cargo run --release"
echo ""
echo "To stop the PBX: ./scripts/stop-all.sh"
