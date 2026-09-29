#!/usr/bin/env bash
# Laya RLCD fine-tune, memory-safe variant: top encoder layers + head trainable, frozen weights bf16,
# and a watchdog that stops the job if the node's MemAvailable drops under 1.2 GB (shared services first).
cd ~/hack/claude-s1/code
LP=../laya-venv/bin/python
$LP laya_s1.py --base ../models/laya/multilingual --data ../data --out ../runs/laya_ft --epochs ${LAYA_EPOCHS:-1.0} \
  --max-minutes ${LAYA_MIN:-22} --mem-gb ${LAYA_MEM:-2.6} --train-top ${LAYA_TOP:-6} ${LAYA_EXTRA:-} > ../logs/laya_ft.log 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "$a" -lt 1200 ]; then echo "$(date +%H:%M:%S) watchdog: MemAvailable ${a} MB, stopping $PID" >> ../logs/laya_ft.log; kill $PID; fi
  sleep 3
done
echo "$(date +%H:%M:%S) laya ft exited" >> ../logs/laya_ft.log
