#!/usr/bin/env bash
set -euo pipefail

# Collect latency samples from java-client and go-backend logs within a time window
# and generate per-topic CSVs + a self-contained HTML report with inline JS charts.
#
# Usage examples:
#   bash scripts/latency-report.sh --pre 5 --post 10 -- bash scripts/netem.sh shape 120 20 2 10 1mbps
#   bash scripts/latency-report.sh --pre 10 --post 30 
#   OUT=./captures/run1 bash scripts/latency-report.sh --pre 5 --post 20 -- bash scripts/mqtt-proxy.sh latency 120 40 both
#
# Notes:
# - Requires the app containers to be running: 'java-client' and 'go-backend'.
# - The apps must log 'latency_ms=' on recv lines (already implemented).

PRE=5
POST=10
OUT=${OUT:-}
:

if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" || "$1" == "help" ) ]]; then
  cat <<EOF
Usage: bash scripts/latency-report.sh [--pre N] [--post N] [--] [command ...]
Options:
  --pre N       Seconds before the command to include (default 5)
  --post N      Seconds after the command to include (default 10)
  --            Separator; anything after is executed as the impairment command

Env:
  OUT           Output directory (default: ./captures/latency-<ts>)
EOF
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) PRE=${2:?}; shift 2 ;;
    --post) POST=${2:?}; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

CMD=("$@")

ts_now() { date +%s; }

ensure_running() {
  local name=$1
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" != "true" ]]; then
    echo "container '$name' not running" >&2; exit 1
  fi
}

ensure_running java-client
ensure_running go-backend

T0=$(ts_now)
if (( PRE < 0 )); then PRE=0; fi
SINCE=$(( T0 - PRE ))

if [[ ${#CMD[@]} -gt 0 ]]; then
  echo "[latency] executing impairment command: ${CMD[*]}"
  # shellcheck disable=SC2068
  ${CMD[@]}
fi

echo "[latency] waiting post window: ${POST}s"
sleep "$POST"

UNTIL=$(ts_now)

OUT=${OUT:-"./captures/latency-${T0}"}
mkdir -p "$OUT"

echo "[latency] collecting logs: since=${SINCE} until=${UNTIL} → $OUT"
docker logs --since "$SINCE" --until "$UNTIL" java-client > "$OUT/java.log" 2>&1 || true
docker logs --since "$SINCE" --until "$UNTIL" go-backend   > "$OUT/go.log"   2>&1 || true

echo "[latency] parsing logs to CSVs"
META="since=${SINCE} until=${UNTIL} pre=${PRE}s post=${POST}s cmd=${CMD[*]:-none}"
# First pass: generate CSVs and summaries (no HTML yet)
python3 "$(dirname "$0")/latency_parse.py" --java "$OUT/java.log" --go "$OUT/go.log" --outdir "$OUT" --title "MQTT Latency Report" --meta "$META" || {
  echo "[latency] parsing failed; ensure python3 is available" >&2; exit 1; }


if command -v gnuplot >/dev/null 2>&1; then
  echo "[latency] rendering charts via gnuplot"
  # Common style (dark background to match HTML)
  GNUPLOT_STYLE="set term pngcairo size 1280,720 background rgb '#0b0f14';\
set border lw 1.5 lc rgb '#3a4758'; set grid back lc rgb '#223042' lw 1;\
set tics textcolor rgb '#e6eef7'; set xlabel textcolor rgb '#e6eef7'; set ylabel textcolor rgb '#e6eef7'; set key textcolor rgb '#e6eef7';\
set title textcolor rgb '#e6eef7' font ',14'; set xlabel font ',12'; set ylabel font ',12'; set xtics font ',11'; set ytics font ',11';\
set mxtics; set mytics;"
  # Latency line charts
  gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xlabel 'seq'; set ylabel 'latency (ms)'; set title '/driver/offer latency vs seq'; set output '$OUT/latency_offer.png'; plot '$OUT/latency_offer.csv' using 1:(\$2>=0?\$2:1/0) with lines lw 2 lc rgb '#5eb1ff' title 'offer'" || true
  gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xlabel 'seq'; set ylabel 'latency (ms)'; set title '/driver/ride latency vs seq'; set output '$OUT/latency_ride.png'; plot '$OUT/latency_ride.csv' using 1:(\$2>=0?\$2:1/0) with lines lw 2 lc rgb '#2ecc71' title 'ride'" || true
  gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xlabel 'seq'; set ylabel 'latency (ms)'; set title '/driver/location latency vs seq'; set output '$OUT/latency_location.png'; plot '$OUT/latency_location.csv' using 1:(\$2>=0?\$2:1/0) with lines lw 2 lc rgb '#f39c12' title 'location'" || true
  for t in offer ride location; do
    if [[ -f "$OUT/rate_${t}.csv" ]]; then
      gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xdata time; set timefmt '%s'; set format x '%H:%M:%S'; set xlabel 'time (hh:mm:ss)'; set ylabel 'msgs/sec'; set title '/driver/${t} pub vs recv per second'; set output '$OUT/rate_${t}.png'; plot '$OUT/rate_${t}.csv' using 1:2 with lines lw 2 lc rgb '#5eb1ff' title 'published', '$OUT/rate_${t}.csv' using 1:3 with lines lw 2 lc rgb '#2ecc71' title 'received'" || true
    fi
  done
  for t in offer ride location; do
    if [[ -f "$OUT/rate_${t}.csv" ]]; then
      gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xdata time; set timefmt '%s'; set format x '%H:%M:%S'; set yrange [0:1]; set xlabel 'time (hh:mm:ss)'; set ylabel 'delivered ratio'; set title '/driver/${t} delivered ratio (delivered/published by pub-second)'; set output '$OUT/rate_${t}_ratio.png'; plot '$OUT/rate_${t}.csv' using 1:4 with lines lw 2 lc rgb '#f39c12' title 'delivered_ratio'" || true
    fi
  done
  for t in offer ride location; do
    if [[ -f "$OUT/latency_${t}_missing.csv" && -f "$OUT/latency_${t}.csv" ]]; then
      gnuplot -e "$GNUPLOT_STYLE; set datafile separator ','; set xlabel 'seq'; set ylabel 'latency (ms)'; set title '/driver/${t} latency vs seq (missing marked)'; set output '$OUT/latency_${t}_with_missing.png'; plot '$OUT/latency_${t}.csv' using 1:(\$2>=0?\$2:1/0) with lines lw 2 lc rgb '#5eb1ff' title 'delivered', '$OUT/latency_${t}_missing.csv' using 1:(0) with points pt 7 ps 1.2 lc rgb '#e74c3c' title 'missing'" || true
    fi
  done
else
  echo "[latency] gnuplot not found; skipping PNG chart rendering."
fi

# Second pass: generate HTML after PNGs exist so images render in the page
python3 "$(dirname "$0")/latency_parse.py" --java "$OUT/java.log" --go "$OUT/go.log" --outdir "$OUT" --html --title "MQTT Latency Report" --meta "$META" || true





echo "[latency] done → $OUT"
