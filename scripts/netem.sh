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
  shape <ms> <jitter> <loss_pct> [corr]
                         Set delay+jitter+loss together in one netem rule

Env:
  TARGET=${TARGET}  IFACE=${IFACE}  RUN_IMAGE=${RUN_IMAGE}  EXEC_CONTAINER=${EXEC_CONTAINER}
Behavior:
  If a container named "${EXEC_CONTAINER}" is running, commands exec into it
  (it must share network with TARGET). Otherwise a short-lived helper runs
  with --network container:
Examples:
  TARGET=toxiproxy bash scripts/netem.sh delay 100 20
  TARGET=toxiproxy bash scripts/netem.sh loss 10 25
  TARGET=toxiproxy bash scripts/netem.sh shape 80 10 1 0
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

set_delay() {
  local d_ms=${1:?delay ms required}
  local j_ms=${2:-0}
  ensure_target_running
  if ! [[ $d_ms =~ ^[0-9]+$ && $j_ms =~ ^[0-9]+$ ]]; then
    echo "invalid delay/jitter: delay=$d_ms jitter=$j_ms" >&2; exit 1
  fi
  echo "[netem] delay ${d_ms}ms jitter ${j_ms}ms on ${TARGET}:${IFACE} (replaces existing)"
  if (( j_ms > 0 )); then
    run_tc "tc qdisc replace dev ${IFACE} root netem delay ${d_ms}ms ${j_ms}ms"
  else
    run_tc "tc qdisc replace dev ${IFACE} root netem delay ${d_ms}ms"
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
    run_tc "tc qdisc replace dev ${IFACE} root netem loss ${pct}% ${corr}%"
  else
    run_tc "tc qdisc replace dev ${IFACE} root netem loss ${pct}%"
  fi
}

shape_both() {
  local d_ms=${1:?delay ms}
  local j_ms=${2:?jitter ms}
  local pct=${3:?loss percent}
  local corr=${4:-0}
  ensure_target_running
  if ! [[ $d_ms =~ ^[0-9]+$ && $j_ms =~ ^[0-9]+$ ]]; then
    echo "invalid delay/jitter: delay=$d_ms jitter=$j_ms" >&2; exit 1
  fi
  if ! [[ $pct =~ ^[0-9]+(\.[0-9]+)?$ && $corr =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "invalid loss/correlation: loss=$pct corr=$corr" >&2; exit 1
  fi
  echo "[netem] shape delay=${d_ms}ms jitter=${j_ms}ms loss=${pct}% corr=${corr}% on ${TARGET}:${IFACE}"
  if (( $(awk -v c="$corr" 'BEGIN{print (c>0)}') )); then
    run_tc "tc qdisc replace dev ${IFACE} root netem delay ${d_ms}ms ${j_ms}ms loss ${pct}% ${corr}%"
  else
    run_tc "tc qdisc replace dev ${IFACE} root netem delay ${d_ms}ms ${j_ms}ms loss ${pct}%"
  fi
}

cmd=${1:-}
case "$cmd" in
  status) status ;;
  clear) clear_qdisc ;;
  delay) shift; set_delay "${1:-}" "${2:-0}" ;;
  loss) shift; set_loss "${1:-}" "${2:-0}" ;;
  shape) shift; shape_both "${1:-}" "${2:-0}" "${3:-0}" "${4:-0}" ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac
