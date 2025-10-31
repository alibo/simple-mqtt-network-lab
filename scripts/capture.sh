#!/usr/bin/env bash
set -euo pipefail

# Simple tcpdump helper using the persistent netshoot container that shares
# toxiproxy's network namespace (service name: network-troubleshooting).
#
# Common tasks:
#   - Timed capture on MQTT proxy port 18830
#   - Generic filter capture
#   - Live interactive sniffing
#   - Listing and copying .pcap files from the helper container
#
# Requirements:
#   docker compose up -d network-troubleshooting

EXEC_CONTAINER=${EXEC_CONTAINER:-network-troubleshooting}
IFACE=${IFACE:-eth0}
PORT=${PORT:-18830}

usage() {
  cat <<EOF
Usage: bash scripts/capture.sh <command> [args]

Commands:
  status                          Show helper status, interface, and saved pcaps
  port [seconds] [outfile.pcap]   Capture TCP ${PORT} for N seconds (default 30) to /tmp/<file>
  filter "<expr>" [seconds] [outfile.pcap]
                                  Capture with tcpdump filter for N seconds (default 30)
  live ["<expr>"]                 Live interactive capture (Ctrl+C to stop). Default filter: both
  live-wireshark ["<expr>"]       Stream live capture into Wireshark via named pipe (default filter: both)
  presets                         List preset filter aliases
  preset <name> [sec] [outfile]   Capture using a preset alias (cp|pg|both)
  live-preset <name>              Live capture using a preset alias
  live-wireshark-preset <name>    Live Wireshark using a preset alias
  list                            List /tmp/*.pcap in helper
  copy <file.pcap> [dest_dir]     Copy pcap from helper to host (default ./)
  clear                           Remove saved pcaps from helper (/tmp/*.pcap)

Env:
  EXEC_CONTAINER=${EXEC_CONTAINER}  IFACE=${IFACE}  PORT=${PORT}
Examples:
  bash scripts/capture.sh port 60 mqtt-proxy.pcap
  bash scripts/capture.sh filter "host emqx1 or host mqtt-gateway" 30 gw-emqx.pcap
  bash scripts/capture.sh live "port 18830"
  bash scripts/capture.sh copy mqtt-proxy.pcap ./captures
EOF
}

ensure_exec_running() {
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$EXEC_CONTAINER" 2>/dev/null || true)
  if [[ "$running" != "true" ]]; then
    echo "helper container '$EXEC_CONTAINER' not running. Start with: docker compose up -d network-troubleshooting" >&2
    exit 1
  fi
}

ts() { date +%Y%m%d-%H%M%S; }

# Preset filters relative to toxiproxy vantage point
#  - cp   (client↔proxy):           port ${PORT}
#  - pg   (proxy↔gateway):          host mqtt-gateway and port 1883
#  - both (client↔proxy + ↔gateway): port ${PORT} or (host mqtt-gateway and port 1883)
preset_expr() {
  local name=$(echo "$1" | tr 'A-Z' 'a-z')
  case "$name" in
    cp|client-proxy|client|proxy-port|proxy) echo "port ${PORT}" ;;
    pg|proxy-gateway|gateway) echo "host mqtt-gateway and port 1883" ;;
    both|e2e|end-to-end|all) echo "port ${PORT} or (host mqtt-gateway and port 1883)" ;;
    *) return 1 ;;
  esac
}

presets_cmd() {
  cat <<EOF
[presets]
  cp   | client-proxy     : port ${PORT}
  pg   | proxy-gateway    : host mqtt-gateway and port 1883
  both | e2e | end-to-end : port ${PORT} or (host mqtt-gateway and port 1883)

Note: Capturing from toxiproxy's netns cannot see gateway↔EMQX traffic.
EOF
}

status_cmd() {
  ensure_exec_running
  echo "[capture] helper: $EXEC_CONTAINER (iface=$IFACE, port=$PORT)"
  docker exec "$EXEC_CONTAINER" sh -lc "ip -o addr show dev $IFACE || true"
  list_cmd || true
}

list_cmd() {
  ensure_exec_running
  echo "[capture] pcaps in /tmp:"
  docker exec "$EXEC_CONTAINER" sh -lc 'ls -l /tmp/*.pcap 2>/dev/null || echo "(none)"'
}

clear_cmd() {
  ensure_exec_running
  echo "[capture] clearing /tmp/*.pcap"
  docker exec "$EXEC_CONTAINER" sh -lc 'rm -f /tmp/*.pcap 2>/dev/null || true; ls -l /tmp/*.pcap 2>/dev/null || echo "(none)"'
}

capture_with_filter() {
  local expr=$1; shift
  local secs=${1:-30}; shift || true
  local outfile=${1:-"capture-$(ts).pcap"}
  ensure_exec_running
  echo "[capture] ${secs}s on $EXEC_CONTAINER:$IFACE filter=[$expr] → /tmp/${outfile}"
  # Prefer coreutils timeout; fallback to tcpdump -G loop if timeout missing
  docker exec -e SECS="$secs" -e FILE="$outfile" -e IFACE="$IFACE" -e EXPR="$expr" "$EXEC_CONTAINER" sh -lc '
set -e
PATH="$PATH:/sbin:/usr/sbin"
if command -v timeout >/dev/null 2>&1; then
  timeout "$SECS" tcpdump -i "$IFACE" -n -U -w "/tmp/$FILE" $EXPR
else
  # Fallback: background tcpdump and kill after SECS
  tcpdump -i "$IFACE" -n -U -w "/tmp/$FILE" $EXPR &
  pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT INT TERM
  sleep "$SECS"
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
fi
'
  echo "[capture] saved /tmp/${outfile} (copy with: bash scripts/capture.sh copy ${outfile})"
}

port_cmd() {
  local secs=${1:-30}
  local outfile=${2:-"mqtt-proxy-$(ts).pcap"}
  capture_with_filter "port ${PORT}" "$secs" "$outfile"
}

filter_cmd() {
  local expr=${1:?tcpdump filter expression required}
  local secs=${2:-30}
  local outfile=${3:-"capture-$(ts).pcap"}
  capture_with_filter "$expr" "$secs" "$outfile"
}

live_cmd() {
  local default_expr
  default_expr=$(preset_expr both)
  local expr=${1:-"$default_expr"}
  ensure_exec_running
  echo "[capture] live on $IFACE filter=[$expr]. Ctrl+C to stop."
  docker exec -it -e EXPR="$expr" "$EXEC_CONTAINER" sh -lc 'tcpdump -i "$IFACE" -n -vv $EXPR'
}

copy_cmd() {
  local file=${1:?pcap filename in /tmp required}
  local dest=${2:-.}
  mkdir -p "$dest"
  echo "[capture] copying /tmp/${file} → ${dest}/"
  docker cp "$EXEC_CONTAINER:/tmp/$file" "$dest/"
  echo "[capture] copied to ${dest}/$file"
}

live_wireshark_cmd() {
  local default_expr
  default_expr=$(preset_expr both)
  local expr=${1:-"$default_expr"}
  ensure_exec_running
  local fifo=${FIFO:-/tmp/mqtt.pipe}
  # Create named pipe if needed
  if [[ -e "$fifo" && ! -p "$fifo" ]]; then
    rm -f "$fifo"
  fi
  if [[ ! -p "$fifo" ]]; then
    mkfifo "$fifo"
  fi
  echo "[capture] starting tcpdump producer (expr=[$expr]) → $fifo"
  docker exec -e EXPR="$expr" -e IFACE="$IFACE" "$EXEC_CONTAINER" sh -lc 'tcpdump -i "$IFACE" -U -s 0 -w - $EXPR' > "$fifo" &
  local prod_pid=$!
  trap "kill $prod_pid 2>/dev/null || true; rm -f \"$fifo\"" INT TERM EXIT
  echo "[capture] launching Wireshark. Close Wireshark to stop."
  if command -v wireshark >/dev/null 2>&1; then
    wireshark -k -i "$fifo" -d tcp.port==${PORT},mqtt -d tcp.port==1883,mqtt || true
  elif [[ "$(uname -s)" == "Darwin" && -x "/Applications/Wireshark.app/Contents/MacOS/Wireshark" ]]; then
    "/Applications/Wireshark.app/Contents/MacOS/Wireshark" -k -i "$fifo" -d tcp.port==${PORT},mqtt -d tcp.port==1883,mqtt || open -a Wireshark --args -k -i "$fifo" -d tcp.port==${PORT},mqtt -d tcp.port==1883,mqtt || true
  else
    if [[ "$(uname -s)" == "Darwin" ]]; then
      open -a Wireshark --args -k -i "$fifo" -d tcp.port==${PORT},mqtt -d tcp.port==1883,mqtt || true
    else
      echo "[capture] wireshark not found in PATH. Please install Wireshark or adjust PATH." >&2
    fi
  fi
  echo "[capture] waiting for tcpdump producer to exit…"
  wait $prod_pid 2>/dev/null || true
  rm -f "$fifo"
  trap - INT TERM EXIT
}

preset_cmd() {
  local name=${1:?preset name required}
  local expr
  if ! expr=$(preset_expr "$name"); then
    echo "unknown preset: $name" >&2; presets_cmd; exit 1
  fi
  local secs=${2:-30}
  local outfile=${3:-"capture-${name}-$(ts).pcap"}
  filter_cmd "$expr" "$secs" "$outfile"
}

live_preset_cmd() {
  local name=${1:?preset name required}
  local expr
  if ! expr=$(preset_expr "$name"); then
    echo "unknown preset: $name" >&2; presets_cmd; exit 1
  fi
  live_cmd "$expr"
}

live_wireshark_preset_cmd() {
  local name=${1:?preset name required}
  local expr
  if ! expr=$(preset_expr "$name"); then
    echo "unknown preset: $name" >&2; presets_cmd; exit 1
  fi
  live_wireshark_cmd "$expr"
}

cmd=${1:-}
case "$cmd" in
  status) status_cmd ;;
  list) list_cmd ;;
  clear) clear_cmd ;;
  port) shift; port_cmd "${1:-30}" "${2:-}" ;;
  filter) shift; filter_cmd "${1:-}" "${2:-30}" "${3:-}" ;;
  live) shift; live_cmd "${1:-}" ;;
  live-wireshark) shift; live_wireshark_cmd "${1:-}" ;;
  presets) presets_cmd ;;
  preset) shift; preset_cmd "${1:-}" "${2:-30}" "${3:-}" ;;
  live-preset) shift; live_preset_cmd "${1:-}" ;;
  live-wireshark-preset) shift; live_wireshark_preset_cmd "${1:-}" ;;
  copy) shift; copy_cmd "${1:-}" "${2:-.}" ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac
