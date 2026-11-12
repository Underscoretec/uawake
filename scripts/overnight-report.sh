#!/bin/zsh
# Summarise the latest overnight log: gaps (sleep), uawake assertions, display events.
cd "$(dirname "$0")/.."
LOG=$(ls -t build.noindex/overnight/overnight-*.log | head -1)
echo "Log: $LOG"
head -2 "$LOG"; tail -1 "$LOG"
echo "--- gaps over 60 s (Mac slept) ---"
awk '/elapsed/{split($2,t,":"); s=t[1]*3600+t[2]*60+t[3]; if(p && s-p>60) print "GAP", s-p, "s before", $0; p=s}' "$LOG"
echo "--- last uawake assertions ---"
grep "uawake" "$LOG" | tail -3
echo "--- macOS sleep/display events ---"
pmset -g log | grep -E "Display is turned|Entering Sleep|Wake from" | tail -20
