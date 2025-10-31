#!/usr/bin/env bash
set -euo pipefail

# NetEm helper to simulate real packet loss and latency/jitter
# Applies Linux tc netem in the network namespace of a running container
# without requiring that container to have NET_ADMIN.
#
# By default targets the 'toxiproxy' container so all MQTT traffic through the
# proxy is affected. You can override via TARGET env var.
#
# Requirements:
# - Docker available on host
# - Ability to pull/run an image with tc (we use alpine + iproute2 by default)
#
# Usage examples:
#   bash scripts/netem.sh status
#   bash scripts/netem.sh clear
#   bash scripts/netem.sh delay 150           # 150ms, jitter=0
#   bash scripts/netem.sh delay 150 50        # 150ms ±50ms
#   bash scripts/netem.sh loss 5              # 5% loss
#   bash scripts/netem.sh loss 5 25           # 5% loss, 25% correlation
#   bash scripts/netem.sh shape 120 20 2 10   # 120ms ±20ms, 2% loss, 10% corr
#   bash scripts/netem.sh rate 1mbps          # Limit egress to ~1 Mbit/s (see units)
#   bash scripts/netem.sh shape 120 20 2 10 512kbps  # Combine with bandwidth limit (optional 5th arg)
#
# Env vars:
#   TARGET     container name (default: toxiproxy)
#   IFACE      interface in target ns (default: eth0)
#   RUN_IMAGE  image to run tc from (default: alpine:3.19)

TARGET=${TARGET:-toxiproxy}
IFACE=${IFACE:-eth0}
RUN_IMAGE=${RUN_IMAGE:-alpine:3.19}
EXEC_CONTAINER=${EXEC_CONTAINER:-network-troubleshooting}

usage() {
  cat <<EOF
Usage: bash scripts/netem.sh <command> [args]

Commands:
  status                 Show current qdisc on target interface
  clear                  Remove netem from root qdisc
  delay <ms> [jitter]    Add/replace delay (ms). jitter defaults to 0
  loss <pct> [corr]      Add/replace packet loss percent. corr (0-100) optional
  shape <ms> <jitter> <loss_pct> [corr] [rate]
                         Set delay+jitter+loss together; optional rate adds TBF under netem
  rate <rate>            Limit egress bandwidth via TBF (units: kbit/mbit or kbps/mbps)
  bandwidth <rate>       Alias for 'rate'

Env:
  TARGET=${TARGET}  IFACE=${IFACE}  RUN_IMAGE=${RUN_IMAGE}  EXEC_CONTAINER=${EXEC_CONTAINER}
  TBF_BURST=${TBF_BURST:-32kbit}  TBF_LATENCY=${TBF_LATENCY:-400ms}  # for 'rate' (TBF child)
Behavior:
  If a container named "${EXEC_CONTAINER}" is running, commands exec into it
  (it must share network with TARGET). Otherwise a short-lived helper runs
  with --network container:
Examples:
  TARGET=toxiproxy bash scripts/netem.sh delay 100 20
  TARGET=toxiproxy bash scripts/netem.sh loss 10 25
  TARGET=toxiproxy bash scripts/netem.sh shape 80 10 1 0
  TARGET=toxiproxy bash scripts/netem.sh rate 512kbps
  TARGET=toxiproxy bash scripts/netem.sh shape 120 20 2 10 1mbps
EOF
}

ensure_target_running() {
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$TARGET" 2>/dev/null || true)
  if [[ "$running" != "true" ]]; then
    echo "target container '$TARGET' not running (or not found)" >&2
    exit 1
  fi
}

# Run a tc command inside the TARGET's network namespace.
# Preferred: exec into a long-running helper container sharing the same netns.
# Fallback: run a short-lived helper container joined to TARGET's netns.
run_tc() {
  local cmd=$1
  if [[ "$(docker inspect -f '{{.State.Running}}' "$EXEC_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
    docker exec -e CMD_STR="$cmd" "$EXEC_CONTAINER" sh -lc '
set -e

# Ensure tc is in PATH for various distros
PATH="$PATH:/sbin:/usr/sbin"

# Install tc if needed (Alpine-based helper)
if ! command -v tc >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache iproute2 >/dev/null
  fi
fi

# Execute requested tc commands
sh -c "$CMD_STR"
'
  else
    docker run --rm --cap-add=NET_ADMIN --network "container:${TARGET}" -e CMD_STR="$cmd" "$RUN_IMAGE" \
      sh -c '
set -e

# Install tc if needed (Alpine)
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache iproute2 >/dev/null
fi

# Ensure tc is in PATH for various distros
PATH="$PATH:/sbin:/usr/sbin"

# Execute requested tc commands
sh -c "$CMD_STR"
'
  fi
}

status() {
  ensure_target_running
  echo "[netem] status on ${TARGET}:${IFACE}"
  run_tc "tc qdisc show dev ${IFACE}; echo; tc -s qdisc show dev ${IFACE} || true"
}

clear_qdisc() {
  ensure_target_running
  echo "[netem] clearing qdisc on ${TARGET}:${IFACE}"
  run_tc "tc qdisc del dev ${IFACE} root || true; tc qdisc show dev ${IFACE}"
}

# Normalize a user-provided rate into a tc-compatible unit string
# Accepts: kbps/mbps (preferred) or kbit/mbit/gbit
# Returns a string like: 256kbit, 1mbit, 2gbit
normalize_tc_rate() {
  local in=$1
  local lc num unit
  lc=$(printf '%s' "$in" | tr 'A-Z' 'a-z')
  if [[ $lc =~ ^([0-9]+)(kbit|mbit|gbit)$ ]]; then
    printf '%s' "$lc"
    return 0
  fi
  if [[ $lc =~ ^([0-9]+)(kbps|mbps|gbps)$ ]]; then
    num=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
    case "$unit" in
      kbps) printf '%skbit' "$num" ;;
      mbps) printf '%smbit' "$num" ;;
      gbps) printf '%sgbit' "$num" ;;
    esac
    return 0
  fi
  echo ""; return 1
}

# Ensure a root netem qdisc exists with a stable handle so we can attach children.
ensure_root_netem_handle() {
  # We always replace the root with a handle to provide a stable parent (id 1:)
  # If there are existing netem params, the caller should set them explicitly after this call.
  run_tc "tc qdisc add dev ${IFACE} root handle 1: netem || true"
}

# Add/replace a TBF child under the netem root to enforce rate limiting.
# Uses defaults that are safe for typical lab conditions; override via env if desired.
set_rate() {
  local rate_raw=${1:?rate required (e.g., 256kbps, 1mbps, 512kbit)}
  ensure_target_running
  local rate
  rate=$(normalize_tc_rate "$rate_raw") || { echo "invalid rate: $rate_raw (use kbit/mbit or kbps/mbps)" >&2; exit 1; }
  local burst latency
  burst=${TBF_BURST:-32kbit}
  latency=${TBF_LATENCY:-400ms}
  echo "[netem] rate limit ${rate} (burst ${burst}, latency ${latency}) on ${TARGET}:${IFACE}"
  ensure_root_netem_handle
  run_tc "tc qdisc replace dev ${IFACE} parent 1: handle 10: tbf rate ${rate} burst ${burst} latency ${latency}"
}

set_delay() {
  local d_ms=${1:?delay ms required}
  local j_ms=${2:-0}
  ensure_target_running
  if ! [[ $d_ms =~ ^[0-9]+$ && $j_ms =~ ^[0-9]+$ ]]; then
    echo "invalid delay/jitter: delay=$d_ms jitter=$j_ms" >&2; exit 1
  fi
  echo "[netem] delay ${d_ms}ms jitter ${j_ms}ms on ${TARGET}:${IFACE} (replaces existing)"
  if (( j_ms > 0 )); then
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem delay ${d_ms}ms ${j_ms}ms"
  else
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem delay ${d_ms}ms"
  fi
}

set_loss() {
  local pct=${1:?loss percent required}
  local corr=${2:-0}
  ensure_target_running
  if ! [[ $pct =~ ^[0-9]+(\.[0-9]+)?$ && $corr =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "invalid loss/correlation: loss=$pct corr=$corr" >&2; exit 1
  fi
  echo "[netem] loss ${pct}% corr ${corr}% on ${TARGET}:${IFACE} (replaces existing)"
  if (( $(awk -v c="$corr" 'BEGIN{print (c>0)}') )); then
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem loss ${pct}% ${corr}%"
  else
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem loss ${pct}%"
  fi
}

shape_both() {
  local d_ms=${1:?delay ms}
  local j_ms=${2:?jitter ms}
  local pct=${3:?loss percent}
  local corr=${4:-0}
  local rate_opt=${5:-}
  ensure_target_running
  if ! [[ $d_ms =~ ^[0-9]+$ && $j_ms =~ ^[0-9]+$ ]]; then
    echo "invalid delay/jitter: delay=$d_ms jitter=$j_ms" >&2; exit 1
  fi
  if ! [[ $pct =~ ^[0-9]+(\.[0-9]+)?$ && $corr =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "invalid loss/correlation: loss=$pct corr=$corr" >&2; exit 1
  fi
  echo "[netem] shape delay=${d_ms}ms jitter=${j_ms}ms loss=${pct}% corr=${corr}% on ${TARGET}:${IFACE}"
  if (( $(awk -v c="$corr" 'BEGIN{print (c>0)}') )); then
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem delay ${d_ms}ms ${j_ms}ms loss ${pct}% ${corr}%"
  else
    run_tc "tc qdisc replace dev ${IFACE} root handle 1: netem delay ${d_ms}ms ${j_ms}ms loss ${pct}%"
  fi
  # Optional bandwidth limit
  if [[ -n "$rate_opt" && "$rate_opt" != "0" && "$rate_opt" != "none" ]]; then
    set_rate "$rate_opt"
  fi
}

cmd=${1:-}
case "$cmd" in
  status) status ;;
  clear) clear_qdisc ;;
  delay) shift; set_delay "${1:-}" "${2:-0}" ;;
  loss) shift; set_loss "${1:-}" "${2:-0}" ;;
  shape) shift; shape_both "${1:-}" "${2:-0}" "${3:-0}" "${4:-0}" "${5:-}" ;;
  rate|bandwidth) shift; set_rate "${1:-}" ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac
