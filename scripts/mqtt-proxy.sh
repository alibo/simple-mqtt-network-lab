#!/usr/bin/env bash
set -euo pipefail

# Simple helper to control the toxiproxy MQTT proxy via HTTP API
# Defaults:
#   TOXIPROXY_URL=http://localhost:8474
# Proxy name:
#   PROXY=mqtt

TOXIPROXY_URL=${TOXIPROXY_URL:-http://localhost:8474}
PROXY=${PROXY:-mqtt}

usage() {
  cat <<EOF
Usage: bash scripts/mqtt-proxy.sh <command> [args]

Commands:
  status                 Show all proxies (raw JSON)
  down                   Add downstream reset_peer toxic (hard drop)
  up                     Remove 'down' and 'timeout' toxics if present
  timeout <ms>           Add downstream timeout toxic of <ms> milliseconds
  untimeout              Remove 'timeout' toxic if present
  halfdown               Blackhole downstream (server->client) using limit_data (sim half‑open client)
  halfup                 Blackhole upstream (client->server) using limit_data (sim half‑open server)
  blackhole [ms]         Block both directions with timeout toxics (no FIN/RST). Default ~1yr

Env vars:
  TOXIPROXY_URL          Default: http://localhost:8474
  PROXY                  Default: mqtt
EOF
}

api() {
  local method=$1; shift
  local path=$1; shift
  curl -sS -X "$method" "$TOXIPROXY_URL$path" "$@"
}

status() { api GET /proxies; }

down() {
  echo "[toxiproxy] adding reset_peer toxic 'down' on $PROXY"
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"down","type":"reset_peer","stream":"downstream","toxicity":1.0}' || true
}

up() {
  echo "[toxiproxy] removing toxics 'down' and 'timeout' on $PROXY (if present)"
  api DELETE "/proxies/$PROXY/toxics/down" || true
  api DELETE "/proxies/$PROXY/toxics/timeout" || true
  api DELETE "/proxies/$PROXY/toxics/halfdown" || true
  api DELETE "/proxies/$PROXY/toxics/halfup" || true
  api DELETE "/proxies/$PROXY/toxics/timeout_down" || true
  api DELETE "/proxies/$PROXY/toxics/timeout_up" || true
}

timeout_toxic() {
  local ms=${1:?milliseconds required}
  echo "[toxiproxy] adding timeout toxic ($ms ms) 'timeout' on $PROXY"
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"timeout","type":"timeout","stream":"downstream","attributes":{"timeout":'"$ms"'}}' || true
}

untimeout() { api DELETE "/proxies/$PROXY/toxics/timeout" || true; }

# Half-open style blackholes using limit_data toxic. This does not send RST/FIN.
# bytes=0 means no bytes are allowed through that stream; reads block.
#
# halfdown  → block server→client (client can't receive; server still sees client traffic)
# halfup    → block client→server (server can't receive; client still sees nothing back)
halfdown() {
  echo "[toxiproxy] adding limit_data toxic 'halfdown' (bytes=0, downstream) on $PROXY"
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"halfdown","type":"limit_data","stream":"downstream","attributes":{"bytes":0}}' || true
}

halfup() {
  echo "[toxiproxy] adding limit_data toxic 'halfup' (bytes=0, upstream) on $PROXY"
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"halfup","type":"limit_data","stream":"upstream","attributes":{"bytes":0}}' || true
}

# Full blackhole: block both directions indefinitely without sending FIN/RST
# Uses timeout toxics with a very large duration (default ~1 year)
blackhole() {
  local ms=${1:-31536000000}
  echo "[toxiproxy] adding timeout toxics 'timeout_down' (downstream) and 'timeout_up' (upstream) on $PROXY for ${ms}ms"
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"timeout_down","type":"timeout","stream":"downstream","attributes":{"timeout":'"$ms"'}}' || true
  api POST "/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"timeout_up","type":"timeout","stream":"upstream","attributes":{"timeout":'"$ms"'}}' || true
}

cmd=${1:-}
case "$cmd" in
  status) status ;;
  down) down ;;
  up) up ;;
  timeout) shift; timeout_toxic "${1:-}" ;;
  untimeout) untimeout ;;
  halfdown) halfdown ;;
  halfup) halfup ;;
  blackhole) shift; blackhole "${1:-}" ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac
