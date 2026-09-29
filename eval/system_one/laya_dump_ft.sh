#!/usr/bin/env bash
# Dump the saved fine-tuned Laya checkpoint (val, test, merge val) under the node-memory watchdog.
cd ~/hack/claude-s1/code
../laya-venv/bin/python laya_s1.py --base ../runs/laya_ft/model --data ../data --out ../runs/laya_ft --zero-shot --mem-gb 2.6 > ../logs/laya_ft_dump.log 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "$a" -lt 900 ]; then echo "$(date +%H:%M:%S) watchdog: MemAvailable ${a} MB, stopping $PID" >> ../logs/laya_ft_dump.log; kill $PID; fi
  sleep 2
done
echo "$(date +%H:%M:%S) dump exited" >> ../logs/laya_ft_dump.log
