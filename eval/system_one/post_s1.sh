#!/usr/bin/env bash
# After the Laya fine-tune: calibrate it, measure Laya latency (in-process, GB10), serve the reranker
# on 127.0.0.1:8021 and measure its latency over HTTP, then rebuild the report.  One GPU job at a time.
cd ~/hack/claude-s1/code
LP=../laya-venv/bin/python; VP=~/hack/claude-files/vllm-venv/bin/python; TP=../tools/bin/python
say(){ echo "$(date +%H:%M:%S) $*"; }
while pgrep -f "laya_s1.py --base" >/dev/null; do sleep 10; done
say "laya ft finished"
$LP laya_calibrate.py --run ../runs/laya_ft --write-model --label "Laya fine-tuned" > ../logs/cal_laya_ft.log 2>&1 && say "laya ft calibrated"
$LP laya_latency.py --run ../runs/laya_ft --data ../data --n 300 > ../logs/lat_laya_ft.log 2>&1 && say "laya ft latency: $(tail -1 ../logs/lat_laya_ft.log)"
$LP laya_latency.py --run ../runs/laya_zs --data ../data --n 300 --model ../models/laya/multilingual > ../logs/lat_laya_zs.log 2>&1 && say "laya zs latency: $(tail -1 ../logs/lat_laya_zs.log)"
setsid nohup $VP serve_rr.py --run ../runs/r1 --port 8021 --mem-gb 2.5 > ../logs/serve_rr.log 2>&1 < /dev/null &
for i in $(seq 1 60); do curl -s -m 2 127.0.0.1:8021/health >/dev/null && break; sleep 3; done
curl -s -m 2 127.0.0.1:8021/health && say "serve_rr up" || say "serve_rr FAILED"
$VP rr_latency.py --run ../runs/r1 --data ../data --n 300 > ../logs/lat_r1.log 2>&1 && say "r1 latency: $(tail -1 ../logs/lat_r1.log)"
$TP report_s1.py --runs ../runs --data ../data --out ../runs/report > ../logs/report.log 2>&1 && say "report done"
say "post done"
