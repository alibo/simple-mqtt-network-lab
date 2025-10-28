#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[smoke] starting services..."
docker compose up -d --build

echo "[smoke] waiting for emqx dashboard..."
until curl -sf http://localhost:18083 >/dev/null; do sleep 1; done

echo "[smoke] checking toxiproxy..."
curl -sf http://localhost:8474/version

echo "[smoke] tailing logs (30s)..."
timeout 30s docker compose logs -f go-backend java-client | sed -e 's/^/[log] /'

echo "[smoke] OK"

