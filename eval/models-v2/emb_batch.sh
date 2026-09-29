#!/bin/bash
# spark-D: embedding probes after the Mistral batch (or at 18:05 CST at the latest, then sharing the GPU at low memory).
set -u
C=~/hack/claude-models; V=$C/v2; P=$V/progress.log; PORT=8140
log(){ echo "$(date '+%F %T %Z') $*" >> $P; }
export VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 HF_HUB_OFFLINE=1 CUDA_HOME=/usr/local/cuda-13.0 PATH=$HOME/hack/vllm-venv/bin:/usr/local/cuda-13.0/bin:$PATH TORCH_CUDA_ARCH_LIST=12.1
until { [ -f $V/w/nemotron3-embed-8b/.READY ] && [ -f $V/w/qwen3-vl-emb-8b/.READY ]; } || [ $(date +%H%M) -ge 1800 ]; do sleep 30; done; until [ -z "$(pgrep -f "vllm serve $V/w/")" ] || [ $(date +%H%M) -ge 1805 ]; do sleep 30; done
GMU=0.3; [ -n "$(pgrep -f "vllm serve $V/w/")" ] && GMU=0.12
for m in nemotron3-embed-8b qwen3-vl-emb-8b; do
  W=$V/w/$m; O=$V/out/emb; mkdir -p $O
  [ -f $W/.READY ] || { log "SKIP emb $m not downloaded"; continue; }
  [ $(date +%H%M) -ge 1835 ] && { log "SKIP emb $m late"; continue; }
  log "SERVE emb $m gmu=$GMU"
  (exec setsid vllm serve $W --served-model-name $m --runner pooling --host 127.0.0.1 --port $PORT --trust-remote-code \
     --gpu-memory-utilization $GMU --max-model-len 8192 --max-num-seqs 16 --enforce-eager > $O/$m.serve.log 2>&1 < /dev/null) &
  SP=$!; ok=0
  for i in $(seq 1 90); do kill -0 $SP 2>/dev/null || break; curl -sf -m 3 127.0.0.1:$PORT/v1/models >/dev/null && { ok=1; break; }; sleep 10; done
  if [ $ok = 1 ]; then
    cd $V/repo && python3 $V/emb_eval.py http://127.0.0.1:$PORT $m $O/$m.json eval/scenarios/dev-week-v1/scenario.json eval/scenarios/holdout-week-v2/scenario.json > $O/$m.out 2>&1
    log "DONE emb $m rc=$?"
  else
    grep -E "Error|error|Traceback|not supported" $O/$m.serve.log | tail -12 > $O/$m.failstart.txt; log "FAILSTART emb $m"
  fi
  kill $SP 2>/dev/null; sleep 5; pkill -f "vllm serve $W"; sleep 10; pkill -9 -f "vllm serve $W"; sleep 5
done
log "EMB ALLDONE"
