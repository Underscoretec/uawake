#!/bin/zsh
# uawake overnight test: logs every 30 s; a gap > 60 s means the Mac slept.
# Usage: scripts/overnight-test.sh   (stop with: pkill -f overnight-test.sh)
cd "$(dirname "$0")/.."
LOG=build.noindex/overnight/overnight-$(date +%Y%m%d-%H%M).log
mkdir -p "$(dirname "$LOG")"
START=$(date +%s); i=0
{ echo "=== start $(date '+%F %T') ==="; pmset -g batt | head -1; } >> "$LOG"
echo "Logging to $LOG"
while true; do
  i=$((i+1)); NOW=$(date +%s)
  echo "$(date '+%F %T') #$i elapsed=$(( (NOW-START)/60 ))m" >> "$LOG"
  if (( i % 10 == 1 )); then
    pmset -g assertions | grep uawake | sed 's/^/   /' >> "$LOG"
  fi
  sleep 30
done
