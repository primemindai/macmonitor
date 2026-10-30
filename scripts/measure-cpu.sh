#!/bin/bash
# Measures MacMonitor's CPU cost (spec section 4): 100% = one core, averaged over a window.
# Usage: scripts/measure-cpu.sh <label> [seconds]
# Prints two numbers:
#  1. ps %CPU sampled once a second and averaged (the spec's method; ps itself is a decaying average).
#  2. Exact CPU seconds used over the window, from the app's own getrusage log, split into the app and the
#     child processes it ran (ps every 5 s, top every 15 s). Needs, before the app starts:
#       defaults write com.macmonitor.app cpuLogPath <file>
set -euo pipefail
LABEL="${1:-run}"
SECS="${2:-60}"
APPBIN="$HOME/Applications/MacMonitor.app/Contents/MacOS/MacMonitor"
PID=$(pgrep -f "$APPBIN" | head -1 || true)
[[ -z "$PID" ]] && { echo "MacMonitor is not running from ~/Applications"; exit 1; }
LOG=$(defaults read com.macmonitor.app cpuLogPath 2>/dev/null || true)

last_log() { [[ -n "$LOG" && -f "$LOG" ]] && tail -1 "$LOG" || echo ""; }
START_LOG=$(last_log)
T0=$(date +%s)
SUM=0; N=0
for _ in $(seq 1 "$SECS"); do
  V=$(ps -o %cpu= -p "$PID" | tr -d ' ')
  SUM=$(echo "$SUM + ${V:-0}" | bc -l); N=$((N + 1))
  sleep 1
done
sleep 5   # let the app write one more log line after the window
END_LOG=$(last_log)
AVG=$(echo "scale=2; $SUM / $N" | bc -l)
echo "[$LABEL] $(date '+%Y-%m-%d %H:%M:%S') pid $PID, $N one-second ps samples"
echo "  ps %CPU average (app only): $AVG%"
if [[ -n "$START_LOG" && -n "$END_LOG" ]]; then
  read -r t0 o0 c0 <<<"$START_LOG"; read -r t1 o1 c1 <<<"$END_LOG"
  awk -v t0="$t0" -v t1="$t1" -v o0="$o0" -v o1="$o1" -v c0="$c0" -v c1="$c1" 'BEGIN {
    dt = t1 - t0; own = (o1 - o0) / dt * 100; kids = (c1 - c0) / dt * 100;
    printf "  getrusage over %.0f s: app %.2f%%, child processes (ps, top) %.2f%%, total %.2f%% of one core\n", dt, own, kids, own + kids }'
else
  echo "  (no cpuLogPath log; child processes not counted)"
fi
