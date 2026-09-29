#!/usr/bin/env bash
# Wait for after_r1.sh, then fine-tune Laya (RLCD), dump val/test/merge, calibrate on VALIDATION, test report, latency.
cd ~/hack/claude-s1
P=logs/pipeline.progress
say(){ echo "$(date +%H:%M:%S) $*" | tee -a $P; }
while pgrep -f "code/after_r1.sh" >/dev/null; do sleep 10; done
free -g | head -2 >> $P
MIN=${LAYA_MIN:-55}
say "laya ft start (max $MIN min)"
cd code
LP=../laya-venv/bin/python
$LP laya_s1.py --base ../models/laya/multilingual --data ../data --out ../runs/laya_ft --epochs ${LAYA_EPOCHS:-3} --max-minutes $MIN --mem-gb ${LAYA_MEM:-5.0} > ../logs/laya_ft.log 2>&1 && say "laya ft trained+dumped" || say "laya ft FAILED"
$LP laya_calibrate.py --run ../runs/laya_ft --write-model --label "Laya fine-tuned" > ../logs/cal_laya_ft.log 2>&1 && say "laya ft calibrated"
$LP laya_calibrate.py --run ../runs/laya_ft --report-test --label "Laya fine-tuned" > ../logs/cal_laya_ft_test.log 2>&1 && say "laya ft test report"
$LP laya_latency.py --run ../runs/laya_ft --data ../data --n 300 > ../logs/lat_laya_ft.log 2>&1 && say "laya ft latency"
say "laya pipeline done"
