#!/bin/bash
# spark-G: after the neutral-prompt batch, run each OCR specialist once more with its own card prompt (test split, conc 1).
set -u
C=~/hack/claude-models; V=$C/v2; P=$V/progress.log; PORT=8131
log(){ echo "$(date '+%F %T %Z') $*" >> $P; }
export VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 HF_HUB_OFFLINE=1 CUDA_HOME=/usr/local/cuda-13.0 PATH=$HOME/hack/vllm-venv/bin:/usr/local/cuda-13.0/bin:$PATH TORCH_CUDA_ARCH_LIST=12.1
until grep -q "BATCH ALLDONE" $P; do sleep 30; done
for spec in "paddleocr-vl-1.6|OCR:|16384" "glm-ocr|Text Recognition:|16384" "deepseek-ocr-2|Free OCR.|8192"; do
  IFS='|' read m prompt ml <<< "$spec"
  [ $(date +%H%M) -ge 1825 ] && { log "SKIP native $m late"; continue; }
  O=$V/out/$m; [ -f $V/w/$m/.READY ] || continue
  log "SERVE native $m"
  (exec setsid vllm serve $V/w/$m --served-model-name $m --host 127.0.0.1 --port $PORT --trust-remote-code \
     --gpu-memory-utilization 0.3 --max-model-len $ml --max-num-seqs 4 > $O/native.serve.log 2>&1 < /dev/null) &
  SP=$!; ok=0
  for i in $(seq 1 120); do kill -0 $SP 2>/dev/null || break; curl -sf -m 3 127.0.0.1:$PORT/v1/models >/dev/null && { ok=1; break; }; sleep 10; done
  if [ $ok = 1 ]; then
    log "START native $m"
    timeout 2400 python3 $V/ocr_native.py $V/mm http://127.0.0.1:$PORT $m "$prompt" $O/$m.native.jsonl > $O/logs.native.txt 2>&1
    log "END native $m rc=$?"
  else log "FAILSTART native $m"; fi
  kill $SP 2>/dev/null; sleep 5; pkill -f "vllm serve $V/w/$m"; sleep 10; pkill -9 -f "vllm serve $V/w/$m"; sleep 5
done
log "NATIVE ALLDONE"
