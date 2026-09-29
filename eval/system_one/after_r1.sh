#!/usr/bin/env bash
# Chain: wait for reranker run r1 -> serve it (vLLM :8021) -> score val/test/merge -> calibrate -> latency -> stop.
# Then Laya zero-shot dump on VALIDATION.  Progress in logs/pipeline.progress
cd ~/hack/claude-s1
P=logs/pipeline.progress
say(){ echo "$(date +%H:%M:%S) $*" | tee -a $P; }
while pgrep -f "code/train_s1.py" >/dev/null; do sleep 15; done
say "r1 exited"; ls runs/r1/model >/dev/null 2>&1 || say "r1 model missing"
VP=~/hack/claude-files/vllm-venv/bin/python
free -g | head -2 >> $P
setsid nohup bash code/serve_s1.sh runs/r1/model > logs/serve_r1.log 2>&1 &
for i in $(seq 1 90); do curl -s -m 2 127.0.0.1:8021/health >/dev/null && break; sleep 5; done
curl -s -m 2 127.0.0.1:8021/health >/dev/null && say "vllm up" || say "vllm FAILED"
cd code
$VP score_vllm.py --run ../runs/r1 --data ../data >> ../logs/score_r1.log 2>&1 && say "scored"
$VP calibrate_s1.py --run ../runs/r1 --data ../data > ../logs/cal_r1.log 2>&1 && say "calibrated"
$VP calibrate_s1.py --run ../runs/r1 --data ../data --report-test > ../logs/cal_r1_test.log 2>&1 && say "test report"
$VP s1_client.py --run ../runs/r1 --data ../data --split val --n 300 > ../logs/lat_r1.log 2>&1 && say "latency"
cd ..
pkill -f "served-model-name s1-reranker"; sleep 15
say "vllm stopped"; free -g | head -2 >> $P
cd code
../laya-venv/bin/python laya_s1.py --base ../models/laya/multilingual --data ../data --out ../runs/laya_zs --zero-shot --splits val > ../logs/laya_zs.log 2>&1 && say "laya zs dumped"
../laya-venv/bin/python laya_calibrate.py --run ../runs/laya_zs --label "Laya zero-shot" > ../logs/cal_laya_zs.log 2>&1 && say "laya zs calibrated"
say "pipeline done"
