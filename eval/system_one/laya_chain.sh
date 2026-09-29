#!/usr/bin/env bash
# Laya zero-shot dump (val, test, merge val), then RLCD fine-tune under a time guard and its dump.
# One GPU job at a time; progress in logs/pipeline.progress.
cd ~/hack/claude-s1
P=logs/pipeline.progress
say(){ echo "$(date +%H:%M:%S) $*" | tee -a $P; }
while pgrep -f "code/train_s1.py" >/dev/null; do sleep 10; done
cd code
LP=../laya-venv/bin/python
say "laya zs start"; free -g | head -2 >> ../$P
$LP laya_s1.py --base ../models/laya/multilingual --data ../data --out ../runs/laya_zs --zero-shot --mem-gb ${LAYA_MEM:-4.0} \
  > ../logs/laya_zs.log 2>&1 && say "laya zs dumped" || say "laya zs FAILED"
say "laya ft start (max ${LAYA_MIN:-32} min)"; free -g | head -2 >> ../$P
$LP laya_s1.py --base ../models/laya/multilingual --data ../data --out ../runs/laya_ft --epochs ${LAYA_EPOCHS:-1.5} \
  --max-minutes ${LAYA_MIN:-32} --mem-gb ${LAYA_MEM:-4.5} > ../logs/laya_ft.log 2>&1 && say "laya ft trained+dumped" || say "laya ft FAILED"
say "laya chain done"
