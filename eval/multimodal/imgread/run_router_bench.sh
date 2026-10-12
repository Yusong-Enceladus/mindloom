#!/bin/bash
# The image-router measurement on a Spark that serves both models (synthetic mm-v1 images and synthetic scenarios only).
#   Qwen3.6 NVFP4 (vLLM) on QWEN_URL, Step3-VL-10B (llama.cpp) on STEP3_URL, both on 127.0.0.1.
# Part 1: the image-read path on the mm-v1 test split, all-Qwen against the router, two runs each, interleaved.
# Part 2: the whole organizer on three synthetic scenarios (run_eval.py), all-Qwen first with a replay cache, then the
#         router with the same cache: every model call whose request is unchanged replays, so only what the new
#         screenshot readings change is asked again.
# A sampler writes the servers' in-flight/queued request counts every 5 s next to the results, so a run that shared
# the GPU with another client can be told apart.
# Usage (from the repository root on the Spark): PY=/path/to/venv/python OUT=../out eval/multimodal/imgread/run_router_bench.sh
set -u
PY=${PY:-python3}; OUT=${OUT:-../out}; QWEN_URL=${QWEN_URL:-http://127.0.0.1:8000}; STEP3_URL=${STEP3_URL:-http://127.0.0.1:30001}
EMBED_URL=${EMBED_URL:-http://127.0.0.1:8013/v1}
mkdir -p "$OUT"
sample() {
  while :; do
    q=$(curl -s -m3 "$QWEN_URL/metrics" | awk '/^vllm:num_requests_running/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{print r+0, w+0}')
    s=$(curl -s -m3 "$STEP3_URL/metrics" | awk '/^llamacpp:requests_processing/{p=$2} /^llamacpp:requests_deferred/{d=$2} END{print p+0, d+0}')
    echo "$(date +%s) $q $s" >> "$OUT/load.tsv"; sleep 5
  done
}
echo "ts qwen_running qwen_waiting step3_processing step3_deferred" > "$OUT/load.tsv"
sample & SAMPLER=$!; trap 'kill $SAMPLER 2>/dev/null' EXIT

IMG=eval/multimodal/imgread/run_imgread.py
for r in r1 r2; do
  $PY $IMG --root eval/multimodal --split test --url "$QWEN_URL/v1" --out "$OUT/test-allqwen.$r.jsonl" > "$OUT/test-allqwen.$r.log" 2>&1
  $PY $IMG --root eval/multimodal --split test --url "$QWEN_URL/v1" --router stepfun-chat --step3-url "$STEP3_URL" \
      --out "$OUT/test-router.$r.jsonl" > "$OUT/test-router.$r.log" 2>&1
done

for sc in dev-week-v1 holdout-week-v1 holdout-week-v2; do
  $PY eval/run_eval.py --scenario eval/scenarios/$sc/scenario.json --condition skills --llm-url "$QWEN_URL/v1" \
      --embed-url "$EMBED_URL" --replay-cache "$OUT/cache-$sc" --keep-db --force --out "$OUT/e2e-$sc-allqwen" \
      > "$OUT/e2e-$sc-allqwen.log" 2>&1
  ORGANIZER_IMAGE_ROUTER=stepfun-chat ORGANIZER_STEP3_URL="$STEP3_URL" \
  $PY eval/run_eval.py --scenario eval/scenarios/$sc/scenario.json --condition skills --llm-url "$QWEN_URL/v1" \
      --embed-url "$EMBED_URL" --replay-cache "$OUT/cache-$sc" --keep-db --force --out "$OUT/e2e-$sc-router" \
      > "$OUT/e2e-$sc-router.log" 2>&1
done
echo "ALLDONE $(date +%s)" >> "$OUT/progress.txt"
