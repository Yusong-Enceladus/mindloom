#!/bin/bash
# Sequential ModelScope download queue: dlq.sh REPO:DIR ... ; progress in ~/hack/claude-models/v2/dl.progress
C=~/hack/claude-models; mkdir -p $C/v2/logs
for spec in "$@"; do
  repo=${spec%%:*}; d=$C/v2/w/${spec##*:}
  echo "$(date +%T) START $repo" >> $C/v2/dl.progress
  python3 $C/v2/msdl.py $repo $d 4 4 > $C/v2/logs/dl-${spec##*:}.log 2>&1
  n=$(grep -c FAILED $C/v2/logs/dl-${spec##*:}.log)
  echo "$(date +%T) END $repo failed=$n $(du -sh $d | cut -f1)" >> $C/v2/dl.progress
  [ $n = 0 ] && touch $d/.READY
done
echo "$(date +%T) DLQ-ALLDONE" >> $C/v2/dl.progress
