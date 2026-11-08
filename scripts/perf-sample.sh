#!/bin/zsh
# Samples a process's CPU and memory: perf-sample.sh <pid> <seconds> <label>
# Prints one line per 10 s sample, then the average CPU from the CPU-time delta.
pid=$1; duration=$2; label=$3
# ps prints CPU time as M:SS.cc or H:MM:SS.cc.
cputime() {
  ps -o time= -p $pid | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }'
}
start=$(cputime); t0=$(date +%s)
echo "# $label pid=$pid start=$(date '+%Y-%m-%d %H:%M:%S')"
while (( $(date +%s) - t0 < duration )); do
  echo "$(date +%H:%M:%S) $(ps -o %cpu=,rss= -p $pid) $(footprint -p $pid 2>/dev/null | awk '/phys_footprint:/ {print $2 $3}')"
  sleep 10
done
end=$(cputime); elapsed=$(( $(date +%s) - t0 ))
echo "# $label cpu_seconds=$(( end - start )) elapsed=$elapsed avg_cpu_percent=$(echo "scale=4; ($end - $start) * 100 / $elapsed" | bc)"
