#!/bin/bash
# Organizer quality eval with Nemotron-3-Super-120B-A12B NVFP4 (thinking off: the organizer client already sends
# chat_template_kwargs.enable_thinking=false, which this model's template reads) as the organizer LLM.
# Code: claude/multimodal @ 2e532bc (git archive). Embeddings: local Qwen3-Embedding-0.6B on :8012 (transformers).
# Vision (image-detect / image-read only): shared Qwen3.6-35B-A3B NVFP4 on spark-C, loopback tunnel :28762.
set -u
D=~/hack/claude-models/nemotron3-super
cd $D/repo
PY=~/hack/vllm-venv/bin/python
P=$D/progress.txt
mkdir -p $D/out $D/logs
echo "start $(date +%T)" >> $P
if curl -sf -m 5 127.0.0.1:28762/v1/models > /dev/null; then
  VIS=(--vision-llm-url http://127.0.0.1:28762/v1)
else
  VIS=(); echo "vision NOT available, running without $(date +%T)" >> $P
fi
for sc in ${SCENARIOS:-dev-week-v1:dev holdout-week-v2:h2}; do
  name=${sc%%:*}; tag=${sc##*:}
  out=$D/out/$tag-skills-nemotron3super-r1
  echo "run $name -> $out $(date +%T)" >> $P
  $PY eval/run_eval.py --scenario eval/scenarios/$name/scenario.json --condition skills \
    --llm-url http://127.0.0.1:8120/v1 --embed-url http://127.0.0.1:8012/v1 "${VIS[@]}" \
    --llm-timeout 600 --keep-db --out $out > $D/logs/$tag.log 2>&1
  echo "done $name rc=$? $(date +%T)" >> $P
done
echo "ALLDONE $(date +%T)" >> $P
