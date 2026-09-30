#!/bin/bash
# v5org.sh SLUG : optionally serve SLUG with vLLM 0.30.0 on 127.0.0.1:$PORT, then run the organizer eval
# (eval/run_eval.py --condition skills, code 2e532bc) on synthetic scenarios listed in RUNS. Synthetic data only.
set -u
SLUG=$1
V2=$HOME/hack/claude-models/v2; V5=$HOME/hack/claude-models/v5
PY=$HOME/hack/vllm-venv/bin/python
PORT=${PORT:-8140}; URL=${URL:-http://127.0.0.1:$PORT}
EMB=${EMB:-http://127.0.0.1:8012/v1}
VIS=${VIS:-}
SERVE=${SERVE:-1}
DEV_BY=${DEV_BY:-0}; HARD=${HARD:-0}
RUNS=${RUNS:-"h2:holdout-week-v2:r1 dev:dev-week-v1:r1"}
WRAP=${WRAP:-eval/run_eval.py}
O=$V5/out/$SLUG; mkdir -p $O
P=$V5/progress.log
log(){ echo "$(date '+%F %T %Z') $SLUG $*" | tee -a $P; }
export VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
export CUDA_HOME=/usr/local/cuda-13.0 PATH=$HOME/hack/vllm-venv/bin:/usr/local/cuda-13.0/bin:$PATH
export TORCH_CUDA_ARCH_LIST=12.1 MAX_JOBS=4 FLASHINFER_NVCC_THREADS=1
[ -d $HOME/hack/claude-models/pydev ] && export CPATH=$HOME/hack/claude-models/pydev/root/usr/include/python3.12:$HOME/hack/claude-models/pydev/root/usr/include
[ -d $HOME/hack/pydev ] && export CPATH=$HOME/hack/pydev/root/usr/include/python3.12:$HOME/hack/pydev/root/usr/include
ENVX=(); GMU=0.8; MAXLEN=65536; F=(); W=$V2/w/$SLUG
case $SLUG in
  glm47-flash) GMU=0.8 ;;
  gemma4-26b-a4b) GMU=0.75 ;;
  gpt-oss-120b) ENVX=(TIKTOKEN_ENCODINGS_BASE=$V2/tiktoken)
    F=(--default-chat-template-kwargs '{"reasoning_effort":"low"}' --reasoning-parser openai_gptoss) ;;
  mistral-small4) GMU=0.82; ENVX=(VLLM_NVFP4_GEMM_BACKEND=marlin PYTHONPATH=$V5/shim)
    F=(--tokenizer-mode mistral --config-format mistral --load-format mistral --kv-cache-dtype fp8 --moe-backend marlin --linear-backend marlin) ;;
esac
now(){ date +%s; }
SPID=
stop_server(){ [ -n "$SPID" ] && { pkill -TERM -g $SPID 2>/dev/null; kill $SPID 2>/dev/null; sleep 8; pkill -9 -g $SPID 2>/dev/null; }
  pkill -f "vllm serve $W" ; sleep 5; pkill -9 -f "vllm serve $W"; sleep 10; SPID=; }
if [ $SERVE = 1 ]; then
  while [ ! -f $W/.READY ]; do [ $HARD -gt 0 ] && [ $(now) -ge $((HARD-2400)) ] && { log "SKIP weights not ready"; exit 0; }; sleep 30; done
  curl -sf -m 3 127.0.0.1:8012/v1/models > /dev/null 2>&1 || curl -sf -m 3 127.0.0.1:8012/v1/embeddings -H 'content-type: application/json' -d '{"input":"x"}' >/dev/null 2>&1 || \
    (setsid nohup $PY $V2/embed_server.py $HOME/hack/claude-models/Qwen3-Embedding-0.6B 8012 > $V5/embed.log 2>&1 < /dev/null &)
  for i in $(seq 1 40); do curl -sf -m 3 127.0.0.1:8012/v1/embeddings -H 'content-type: application/json' -d '{"input":"x"}' > /dev/null && break; sleep 5; done
  log "SERVE gmu=$GMU maxlen=$MAXLEN flags=${F[*]} env=${ENVX[*]}"
  (cd $V5; exec env "${ENVX[@]}" setsid $HOME/hack/vllm-venv/bin/vllm serve $W --served-model-name $SLUG \
     --host 127.0.0.1 --port $PORT --trust-remote-code --gpu-memory-utilization $GMU --max-model-len $MAXLEN \
     --max-num-seqs 4 --max-num-batched-tokens 8192 --enable-chunked-prefill --enable-prefix-caching "${F[@]}" \
     > $O/serve.log 2>&1 < /dev/null) &
  SPID=$!; t0=$(now); up=0
  while [ $(( $(now)-t0 )) -lt 2100 ]; do
    kill -0 $SPID 2>/dev/null || break
    curl -sf -m 5 $URL/v1/models > /dev/null && { up=1; break; }
    sleep 10
  done
  if [ $up = 0 ]; then
    log "FAILSTART after $(( $(now)-t0 ))s"
    grep -E "Error|error|Exception|Traceback|not supported|NotImplemented" $O/serve.log | tail -15 > $O/failstart.txt
    stop_server; exit 1
  fi
  log "UP after $(( $(now)-t0 ))s"
  grep -E "Model loading took|Loading weights took|Available KV cache|GPU KV cache size|Maximum concurrency" $O/serve.log | tail -6 > $O/serve.summary.txt
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv > $O/gpu-mem.txt 2>&1; free -m >> $O/gpu-mem.txt
fi
( while :; do g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "$(date +%s) gpu=${g:-na}" >> $O/load.tsv; sleep 5; done ) &
LPID=$!
cd $V5/repo; export EVAL_GIT_REV=2e532bc
for spec in $RUNS; do
  tag=${spec%%:*}; rest=${spec#*:}; sc=${rest%%:*}; r=${rest##*:}
  if [ $tag = dev ] && [ $DEV_BY -gt 0 ] && [ $(now) -ge $DEV_BY ]; then log "SKIP $tag-$r (late)"; continue; fi
  if [ $HARD -gt 0 ] && [ $(now) -ge $HARD ]; then log "SKIP $tag-$r (hard)"; continue; fi
  curl -s -m 5 $URL/metrics > $O/metrics-before-$tag-$r.txt 2>/dev/null
  log "START $tag-$r"
  $PY $WRAP --scenario eval/scenarios/$sc/scenario.json --condition skills --llm-url $URL/v1 --embed-url $EMB \
     ${VIS:+--vision-llm-url $VIS} --llm-timeout 600 --keep-db --out $O/$tag-skills-$r > $O/logs.$tag-$r.txt 2>&1 &
  RP=$!
  while kill -0 $RP 2>/dev/null; do
    if [ $HARD -gt 0 ] && [ $(now) -ge $HARD ]; then log "HARDSTOP kill $tag-$r"; kill $RP; sleep 5; kill -9 $RP 2>/dev/null; fi
    sleep 10
  done
  wait $RP; rc=$?
  curl -s -m 5 $URL/metrics > $O/metrics-after-$tag-$r.txt 2>/dev/null
  log "END $tag-$r rc=$rc"
done
kill $LPID 2>/dev/null
[ $SERVE = 1 ] && stop_server
log "DONE"
