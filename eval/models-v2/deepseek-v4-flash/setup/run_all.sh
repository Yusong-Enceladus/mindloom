#!/bin/bash
# Organizer quality eval, DeepSeek-V4-Flash (thinking off via chat_template_kwargs) as organizer LLM.
# Code: claude/multimodal @ 2e532bc (git archive). Embeddings: local Qwen3-Embedding-0.6B :8012.
# Vision (image-read only): shared Qwen3.6-35B-A3B NVFP4 on spark-C, loopback tunnel :28731.
set -u
D=~/hack/claude-models/dsv4-organizer
cd $D/repo
PY=~/hack/vllm-venv/bin/python
P=$D/progress.txt
echo "start $(date +%T)" >> $P
for i in $(seq 1 180); do
  curl -sf -m 5 127.0.0.1:28731/v1/models > /dev/null && break
  [ $i = 1 ] && echo "waiting for vision $(date +%T)" >> $P
  sleep 10
done
curl -sf -m 5 127.0.0.1:28731/v1/models > /dev/null && VIS=(--vision-llm-url http://127.0.0.1:28731/v1) || { VIS=(); echo "vision NOT available, running without $(date +%T)" >> $P; }
for sc in dev-week-v1:dev holdout-week-v2:h2; do
  name=${sc%%:*}; tag=${sc##*:}
  out=$D/out/$tag-skills-dsv4-r1
  echo "run $name -> $out $(date +%T)" >> $P
  $PY eval/run_eval.py --scenario eval/scenarios/$name/scenario.json --condition skills \
    --llm-url http://127.0.0.1:8100/v1 --embed-url http://127.0.0.1:8012/v1 "${VIS[@]}" \
    --llm-timeout 600 --keep-db --out $out > $D/logs/$tag.log 2>&1
  echo "done $name rc=$? $(date +%T)" >> $P
done
echo "ALLDONE $(date +%T)" >> $P
