#!/usr/bin/env bash
# Serve the fine-tuned System One cross-encoder as a vLLM score/classify model on 127.0.0.1:8021.
# The checkpoint is a plain Qwen3ForCausalLM; hf-overrides turn it into a sequence classifier whose
# single logit is lm_head[yes] - lm_head[no] (the Qwen3-Reranker conversion), so /classify returns
# p(yes) = sigmoid(ce).  The client formats the full prompt itself (s1_common.pair_text), so no
# score template is involved and the served text is byte-identical to training.
set -euo pipefail
MODEL_DIR=${1:?usage: serve_s1.sh RUN_DIR/model}
MEM=${S1_GPU_UTIL:-0.04}   # fraction of the 121 GB unified memory (~4.9 GB)
exec ~/hack/claude-files/vllm-venv/bin/python -m vllm.entrypoints.cli.main serve "$MODEL_DIR" \
  --served-model-name s1-reranker --runner pooling \
  --hf-overrides '{"architectures":["Qwen3ForSequenceClassification"],"classifier_from_token":["no","yes"],"is_original_qwen3_reranker":true}' \
  --host 127.0.0.1 --port 8021 --dtype bfloat16 \
  --max-model-len 1536 --max-num-seqs 32 --gpu-memory-utilization "$MEM"
