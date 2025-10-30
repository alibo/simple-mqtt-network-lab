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
  packetloss <pct> [dir] Add slicer toxic(s) with given percentage (0-100). dir: up|down|both (default both)
  unpacketloss           Remove packetloss toxics if present
  bandwidth <rate> [dir] Limit bandwidth using bandwidth toxic. rate supports suffix: bps, kbps, mbps. 0 = full down
  unbandwidth            Remove bandwidth toxics if present

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
  api DELETE "/proxies/$PROXY/toxics/packetloss_down" || true
  api DELETE "/proxies/$PROXY/toxics/packetloss_up" || true
  api DELETE "/proxies/$PROXY/toxics/bandwidth_down" || true
  api DELETE "/proxies/$PROXY/toxics/bandwidth_up" || true
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

# Packet loss simulation
# Note: Toxiproxy doesn't drop individual TCP packets. We approximate loss by
# applying a slicer toxic with a given toxicity (probability per-connection).
# This degrades the stream and can cause MQTT-level retransmits or disconnects.
packetloss() {
  local pct_raw=${1:?percent (0-100 or e.g. 25%) required}
  local dir=${2:-both}
  local pct="${pct_raw%\%}"  # strip a trailing '%'
  if ! [[ $pct =~ ^[0-9]+$ ]]; then
    echo "invalid percent: $pct_raw" >&2; exit 1
  fi
  if (( pct < 0 || pct > 100 )); then
    echo "percent must be between 0 and 100" >&2; exit 1
  fi
  if (( pct == 0 )); then
    echo "[toxiproxy] clearing packetloss toxics (0%) on $PROXY"
    unpacketloss
    return 0
  fi
  local tox
  tox=$(awk -v p="$pct" 'BEGIN{printf "%.3f", p/100.0}')
  echo "[toxiproxy] setting packetloss (${pct}%) on $PROXY (dir=$dir)"
  # remove existing
  api DELETE "/proxies/$PROXY/toxics/packetloss_down" || true
  api DELETE "/proxies/$PROXY/toxics/packetloss_up" || true
  # attributes for slicer: small segments to increase fragmentation
  local attrs_down
  attrs_down='{"name":"packetloss_down","type":"slicer","stream":"downstream","toxicity":'"$tox"',"attributes":{"average_size":512,"size_variation":512,"delay":0}}'
  local attrs_up
  attrs_up='{\"name\":\"packetloss_up\",\"type\":\"slicer\",\"stream\":\"upstream\",\"toxicity\":'"$tox"',\"attributes\":{\"average_size\":512,\"size_variation\":512,\"delay\":0}}'
  case "$dir" in
    down|downstream)
      api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d "$attrs_down" || true ;;
    up|upstream)
      # Use a separate quoting to avoid escaping
      api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d '{"name":"packetloss_up","type":"slicer","stream":"upstream","toxicity":'"$tox"',"attributes":{"average_size":512,"size_variation":512,"delay":0}}' || true ;;
    both|*)
      api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d "$attrs_down" || true
      api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d '{"name":"packetloss_up","type":"slicer","stream":"upstream","toxicity":'"$tox"',"attributes":{"average_size":512,"size_variation":512,"delay":0}}' || true ;;
  esac
}

unpacketloss() {
  api DELETE "/proxies/$PROXY/toxics/packetloss_down" || true
  api DELETE "/proxies/$PROXY/toxics/packetloss_up" || true
}

# Bandwidth limiting
# rate supports suffix: bps (bits/s), kbps, mbps. Without suffix = bytes/s.
# If rate=0, we blackhole via limit_data (bytes=0).
parse_rate_to_bytes() {
  local in=$1
  local num unit
  if [[ $in =~ ^([0-9]+)([a-zA-Z]+)$ ]]; then
    num=${BASH_REMATCH[1]}
    unit=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-Z' 'a-z') # lower
  elif [[ $in =~ ^[0-9]+$ ]]; then
    echo "$in"; return 0
  else
    echo ""; return 1
  fi
  case $unit in
    bps)   awk -v n="$num" 'BEGIN{printf "%d", n/8}' ;;
    kbps)  awk -v n="$num" 'BEGIN{printf "%d", (n*1000)/8}' ;;
    mbps)  awk -v n="$num" 'BEGIN{printf "%d", (n*1000000)/8}' ;;
    Bps|BPS) echo "$num" ;;
    *) echo ""; return 1 ;;
  esac
}

bandwidth() {
  local rate_raw=${1:?rate required (e.g., 256kbps, 1mbps, 65536) }
  local dir=${2:-both}
  local rate_bytes
  if [[ "$rate_raw" == "0" ]]; then
    rate_bytes=0
  else
    rate_bytes=$(parse_rate_to_bytes "$rate_raw") || { echo "invalid rate: $rate_raw" >&2; exit 1; }
  fi
  echo "[toxiproxy] setting bandwidth (${rate_raw} ~= ${rate_bytes} B/s) on $PROXY (dir=$dir)"
  # remove existing
  api DELETE "/proxies/$PROXY/toxics/bandwidth_down" || true
  api DELETE "/proxies/$PROXY/toxics/bandwidth_up" || true
  case "$dir" in
    down|downstream)
      if [[ "$rate_bytes" == "0" ]]; then
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_down","type":"limit_data","stream":"downstream","attributes":{"bytes":0}}' || true
      else
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_down","type":"bandwidth","stream":"downstream","attributes":{"rate":'"$rate_bytes"'}}' || true
      fi ;;
    up|upstream)
      if [[ "$rate_bytes" == "0" ]]; then
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_up","type":"limit_data","stream":"upstream","attributes":{"bytes":0}}' || true
      else
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_up","type":"bandwidth","stream":"upstream","attributes":{"rate":'"$rate_bytes"'}}' || true
      fi ;;
    both|*)
      if [[ "$rate_bytes" == "0" ]]; then
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_down","type":"limit_data","stream":"downstream","attributes":{"bytes":0}}' || true
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_up","type":"limit_data","stream":"upstream","attributes":{"bytes":0}}' || true
      else
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_down","type":"bandwidth","stream":"downstream","attributes":{"rate":'"$rate_bytes"'}}' || true
        api POST "/proxies/$PROXY/toxics" -H 'Content-Type: application/json' \
          -d '{"name":"bandwidth_up","type":"bandwidth","stream":"upstream","attributes":{"rate":'"$rate_bytes"'}}' || true
      fi ;;
  esac
}

unbandwidth() {
  api DELETE "/proxies/$PROXY/toxics/bandwidth_down" || true
  api DELETE "/proxies/$PROXY/toxics/bandwidth_up" || true
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
  packetloss) shift; packetloss "${1:-}" "${2:-both}" ;;
  unpacketloss) unpacketloss ;;
  bandwidth) shift; bandwidth "${1:-}" "${2:-both}" ;;
  unbandwidth) unbandwidth ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac
