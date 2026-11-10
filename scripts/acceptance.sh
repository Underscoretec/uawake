#!/bin/zsh
# 0.1 acceptance checks that need a real app and pmset (docs/ACCEPTANCE-0.1.md).
# Usage: acceptance.sh <path to uawake.app>. Run with no other uawake instance open:
# URLs go to whichever instance LaunchServices picks.
set -u
trap '"${0:A:h}/clean-apps.sh" --tmp' EXIT  # copies under build.noindex/tmp are throwaway
app=${1:?path to uawake.app}
assertions() { pmset -g assertions | grep 'uawake:' | grep -v 'Countdown accuracy' | sed 's/^ *//' }
stamp() { python3 -c 'import time; print(f"{time.time():.3f}")' }
wait_until_gone() {  # Polls every 50 ms; prints elapsed seconds since $1.
  local start=$1
  for i in {1..100}; do assertions | grep -q . || { echo $(( $(stamp) - start )); return; }; sleep 0.05; done
  echo "timeout"
}

# LaunchServices picks the handler for uawake:// itself; let it start, then read the
# handling pid from pmset where it matters (kill -9).
open "$app"; sleep 3
open "uawake://deactivate"; sleep 2

echo "\n## 1. Assertions carry the session's reason"
for url in "uawake://activate" "uawake://activate?duration=90m" "uawake://activate?until=23:59" \
           "uawake://activate?display=1&reason=Render"; do
  open "$url"; sleep 1; echo "\$ open '$url'"; assertions
  open "uawake://deactivate"; sleep 1
done

echo "\n## 2. Stopping removes assertions within 1 second"
for run in 1 2 3; do
  open "uawake://activate?reason=Stop%20timing"; sleep 1
  t=$(stamp); open "uawake://deactivate"; echo "run $run: gone after $(wait_until_gone $t) s (includes URL dispatch)"
done

echo "\n## 7. URL table and invalid URLs"
open "uawake://toggle"; sleep 1; echo "toggle (off→on):"; assertions
open "uawake://toggle"; sleep 1; echo "toggle (on→off):"; assertions; echo "(none expected above)"
open "uawake://activate?duration=1h"; sleep 1
for bad in "uawake://activate?duration=0" "uawake://activate?duration=30m1h" "uawake://sleep" \
           "uawake://activate?until=25:00" "uawake://deactivate?x=1"; do
  open "$bad"; sleep 0.5
done
echo "after 5 invalid URLs, the 1 h session is unchanged:"; assertions
open "uawake://deactivate"; sleep 1

echo "\n## 4. Two overlapping sessions keep the Mac awake until the later one ends"
open "uawake://activate?duration=30s&reason=Short"; open "uawake://activate?duration=60s&reason=Long"; sleep 1
echo "t=1s:"; assertions; sleep 34
echo "t=35s:"; assertions; sleep 30
echo "t=65s:"; assertions; echo "(none expected above)"

echo "\n## 3. kill -9 leaves no assertions"
open "uawake://activate?reason=Kill%20test"; sleep 1; echo "before:"; assertions
pid=$(pmset -g assertions | grep 'uawake: Kill test' | sed -E 's/.*pid ([0-9]+).*/\1/' | head -1)
echo "handler: $(ps -o args= -p $pid)"
kill -9 $pid; sleep 1; echo "after kill -9 $pid:"; assertions; echo "(none expected above)"
