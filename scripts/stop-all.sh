#!/usr/bin/env bash
# Stop the doorbell PBX.
cd "$(dirname "$0")/.."
docker compose -f docker/docker-compose.yml down 2>/dev/null || true
echo "Everything stopped."
