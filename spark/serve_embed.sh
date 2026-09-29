#!/bin/bash
# Qwen/Qwen3-Embedding-0.6B on 127.0.0.1:${EMBED_PORT:-8002} (OpenAI /v1/embeddings) with vLLM's pooling runner.
# Reuses the vLLM venv from ~/hack/vllm-venv. Small memory footprint.
export VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
export CUDA_HOME=/usr/local/cuda-13.0
export PATH=$HOME/hack/vllm-venv/bin:$CUDA_HOME/bin:$PATH
export TORCH_CUDA_ARCH_LIST=12.1 MAX_JOBS=4 FLASHINFER_NVCC_THREADS=1
export CPATH=$HOME/hack/pydev/root/usr/include/python3.12:$HOME/hack/pydev/root/usr/include
MODEL_DIR=${EMBED_MODEL_DIR:-$HOME/hack/models/Qwen3-Embedding-0.6B}
exec "$HOME/hack/vllm-venv/bin/vllm" serve "$MODEL_DIR" \
  --served-model-name qwen3-embedding-0.6b \
  --runner pooling \
  --host 127.0.0.1 --port "${EMBED_PORT:-8002}" \
  --gpu-memory-utilization "${EMBED_GPU_UTIL:-0.06}" \
  --max-model-len 8192 \
  --max-num-seqs 16 \
  --enforce-eager
