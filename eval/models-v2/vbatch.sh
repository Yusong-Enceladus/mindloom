#!/bin/bash
# Unattended model benchmark batch for one DGX Spark (synthetic data only: mm-v1 images, dev-week-v1 /
# holdout-week-v2 scenarios). Usage: vbatch.sh SLUG [SLUG ...]
# For each slug, in order: wait for its weights (.READY from dlq.sh), start vLLM 0.30.0 on 127.0.0.1:8130,
# wait for health (one start attempt only; a failed start is logged with the log tail and the batch moves on),
# then warm (7 dev images), r1 (mm-v1 test split, 98 images, conc 1), c4 (28-image subset, conc 4) and, for
# organizer candidates, the organizer eval on dev-week-v1 and holdout-week-v2 (skills on, thinking off).
# Times on the Sparks are CST (PDT + 15 h). No new server starts after NOSTART; nothing new after HARDSTOP.
set -u
C=$HOME/hack/claude-models; V=$C/v2; MM=$V/mm; PY=$HOME/hack/vllm-venv/bin/python
PORT=8130; URL=http://127.0.0.1:$PORT
NOSTART=${NOSTART:-1800}   # 03:00 PDT
HARDSTOP=${HARDSTOP:-1835} # 03:35 PDT
P=$V/progress.log
log(){ echo "$(date '+%F %T %Z') $*" | tee -a $P; }
now(){ date +%H%M; }
SUB=chat-00,chat-01,chat-02,chat-03,chart-00,chart-01,chart-02,chart-04,slide-00,slide-01,slide-02,slide-03,board-00,board-01,board-02,board-04,receipt-01,receipt-02,receipt-03,receipt-04,scan-00,scan-03,scan-04,scan-05,label-00,label-01,label-02,label-03
WARM=chat-06,chart-03,slide-04,board-03,receipt-00,scan-01,label-04
export VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
export CUDA_HOME=/usr/local/cuda-13.0 PATH=$HOME/hack/vllm-venv/bin:/usr/local/cuda-13.0/bin:$PATH
export TORCH_CUDA_ARCH_LIST=12.1 MAX_JOBS=4 FLASHINFER_NVCC_THREADS=1
[ -d $C/pydev ] && export CPATH=$C/pydev/root/usr/include/python3.12:$C/pydev/root/usr/include
[ -d $HOME/hack/pydev ] && export CPATH=$HOME/hack/pydev/root/usr/include/python3.12:$HOME/hack/pydev/root/usr/include

flags(){ # model-specific vLLM flags; ORG=1 marks organizer candidates
  ORG=0; NOVLM=0; ENVX=(); GMU=0.5; MAXLEN=32768
  case $1 in
    nano-omni) ENVX=(VLLM_NVFP4_GEMM_BACKEND=marlin)
      F=(--kv-cache-dtype fp8 --mamba-ssm-cache-dtype float16 --moe-backend marlin --linear-backend marlin) ;;
    muse-glimmer) ENVX=(VLLM_NVFP4_GEMM_BACKEND=marlin); F=(--kv-cache-dtype fp8 --linear-backend marlin) ;;
    gemma4-31b-qat) F=(--kv-cache-dtype fp8) ;;
    mistral-small4) ORG=1; GMU=0.82; MAXLEN=65536; ENVX=(VLLM_NVFP4_GEMM_BACKEND=marlin)
      F=(--tokenizer-mode mistral --config-format mistral --load-format mistral --kv-cache-dtype fp8
         --moe-backend marlin --linear-backend marlin) ;;
    keye-vl-2-30b) GMU=0.8; F=(--kv-cache-dtype fp8) ;;
    gpt-oss-120b) ORG=1; NOVLM=1; GMU=0.8; MAXLEN=65536
      F=(--default-chat-template-kwargs '{"reasoning_effort":"low"}' --reasoning-parser openai_gptoss) ;;
    paddleocr-vl-1.6|glm-ocr) GMU=0.3; MAXLEN=16384; F=() ;;
    deepseek-ocr-2) GMU=0.3; MAXLEN=8192; F=() ;;
    *) F=() ;;
  esac
}

wait_health(){ # $1 pid, $2 timeout s
  local t=0
  while [ $t -lt $2 ]; do
    kill -0 $1 2>/dev/null || return 1
    curl -sf -m 5 $URL/v1/models > /dev/null && return 0
    sleep 10; t=$((t+10))
  done
  return 2
}

stop_server(){ [ -n "${SPID:-}" ] && { kill $SPID 2>/dev/null; sleep 5; kill -9 $SPID 2>/dev/null; }
  pkill -f "vllm serve $V/w/"; for i in $(seq 1 30); do pgrep -f "vllm serve $V/w/" > /dev/null || break; sleep 3; done
  pkill -9 -f "vllm serve $V/w/"; sleep 15; SPID=; }

run(){ local name=$1; shift; log "START $SLUG $name"; "$@" > $O/logs.$name.txt 2>&1; local rc=$?; log "END $SLUG $name rc=$rc"; return $rc; }

EMBSTARTED=0
start_embed(){
  [ $EMBSTARTED = 1 ] && return
  curl -sf -m 3 127.0.0.1:8012/v1/models > /dev/null 2>&1 || \
    (setsid nohup $PY $V/embed_server.py $C/Qwen3-Embedding-0.6B 8012 > $V/logs/embed.log 2>&1 < /dev/null &)
  for i in $(seq 1 40); do curl -sf -m 3 127.0.0.1:8012/v1/embeddings -H 'content-type: application/json' -d '{"input":"x"}' > /dev/null && break; sleep 5; done
  EMBSTARTED=1
}

mkdir -p $V/out $V/logs
log "BATCH start: $*"
for SLUG in "$@"; do
  W=$V/w/$SLUG; O=$V/out/$SLUG; mkdir -p $O
  while [ ! -f $W/.READY ] && [ $(now) -lt $NOSTART ]; do sleep 30; done
  if [ ! -f $W/.READY ]; then log "SKIP $SLUG weights not ready by $NOSTART CST"; continue; fi
  if [ $(now) -ge $NOSTART ]; then log "SKIP $SLUG too late to start ($(now) CST)"; continue; fi
  flags $SLUG
  log "SERVE $SLUG gmu=$GMU maxlen=$MAXLEN flags=${F[*]} env=${ENVX[*]}"
  (cd $V; exec env "${ENVX[@]}" setsid $HOME/hack/vllm-venv/bin/vllm serve $W --served-model-name $SLUG \
     --host 127.0.0.1 --port $PORT --trust-remote-code --gpu-memory-utilization $GMU --max-model-len $MAXLEN \
     --max-num-seqs 4 --max-num-batched-tokens 8192 --enable-chunked-prefill --enable-prefix-caching "${F[@]}" \
     > $O/serve.log 2>&1 < /dev/null) &
  SPID=$!
  echo $SPID > $O/serve.pid
  t0=$(date +%s)
  wait_health $SPID 2100; rc=$?
  if [ $rc != 0 ]; then
    log "FAILSTART $SLUG rc=$rc after $(( $(date +%s)-t0 ))s"
    grep -E "Error|error|Exception|Traceback|not supported|NotImplemented" $O/serve.log | grep -v "Unexpected gate" | tail -12 > $O/failstart.txt
    stop_server; continue
  fi
  log "UP $SLUG after $(( $(date +%s)-t0 ))s"
  grep -E "Model loading took|Loading weights took|Available KV cache|GPU KV cache size|Maximum concurrency" $O/serve.log | tail -6 > $O/serve.summary.txt
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv > $O/gpu-mem.txt 2>&1; free -m >> $O/gpu-mem.txt
  ( while :; do g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
      m=$(curl -s -m 3 $URL/metrics 2>/dev/null)
      r=$(echo "$m" | grep '^vllm:num_requests_running{' | awk '{s+=$2} END {printf "%d", s}')
      w=$(echo "$m" | grep '^vllm:num_requests_waiting{' | awk '{s+=$2} END {printf "%d", s}')
      echo "$(date +%s) gpu=${g:-na} p$PORT=${r:-0}/${w:-0}" >> $O/load.tsv; sleep 5; done ) &
  LPID=$!
  VLM="python3 bench/run_vlm.py --root . --backend openai --url $URL --model $SLUG --label $SLUG-vllm"
  cd $MM
  if [ $NOVLM = 0 ]; then
  run warm $VLM --ids $WARM --out $O/$SLUG.warm.jsonl
  [ $(now) -lt $HARDSTOP ] && run r1 $VLM --split test --out $O/$SLUG.r1.jsonl
  [ $(now) -lt $HARDSTOP ] && run c4 $VLM --ids $SUB --concurrency 4 --out $O/$SLUG.c4.jsonl
  fi
  if [ $ORG = 1 ]; then
    start_embed; VISARG=(--vision-llm-url $URL/v1); [ $NOVLM = 1 ] && VISARG=()
    cd $V/repo; export EVAL_GIT_REV=$(cat GIT_COMMIT)
    for sc in dev-week-v1:dev holdout-week-v2:h2; do
      [ $(now) -ge $HARDSTOP ] && { log "SKIP $SLUG org ${sc%%:*} (late)"; continue; }
      run org-${sc##*:} $PY eval/run_eval.py --scenario eval/scenarios/${sc%%:*}/scenario.json --condition skills \
        --llm-url $URL/v1 --embed-url http://127.0.0.1:8012/v1 ${VISARG[@]} --llm-timeout 600 \
        --keep-db --out $O/org/${sc##*:}-skills-r1
    done
  fi
  kill $LPID 2>/dev/null
  stop_server
  log "DONE $SLUG"
done
log "BATCH ALLDONE"
