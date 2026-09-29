#!/bin/zsh
# Stops the given heavy evaluation or training jobs before the Mac runs out of
# memory. Usage: memory_guard.sh <pid> [<pid> ...]
# Kills the jobs when available memory (free + inactive + purgeable +
# speculative pages) drops below MIN_AVAILABLE_GB (default 10) or swap use
# exceeds MAX_SWAP_GB (default 2). Exits once all jobs have ended.
min_gb=${MIN_AVAILABLE_GB:-10}
max_swap_gb=${MAX_SWAP_GB:-2}
page=$(sysctl -n hw.pagesize)
while true; do
  alive=()
  for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
  (( ${#alive} == 0 )) && exit 0
  pages=$(vm_stat | awk '/Pages (free|inactive|purgeable|speculative)/ {gsub("\\.", "", $NF); sum += $NF} END {print sum}')
  available_gb=$(( pages * page / 1073741824 ))
  swap_mb=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/' | cut -d. -f1)
  if (( available_gb < min_gb || swap_mb > max_swap_gb * 1024 )); then
    echo "$(date '+%H:%M:%S') memory guard: available ${available_gb} GB, swap ${swap_mb} MB; stopping ${alive[*]}"
    kill -TERM "${alive[@]}" 2>/dev/null
    sleep 5
    kill -KILL "${alive[@]}" 2>/dev/null
    exit 1
  fi
  sleep 3
done
