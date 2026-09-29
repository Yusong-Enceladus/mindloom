#!/bin/bash
# Nemotron-3-Super-120B-A12B NVFP4 on one DGX Spark (spark-G), following the model card's DGX Spark
# recipe, adapted to vLLM 0.30.0:
#   - marlin NVFP4 GEMM: VLLM_NVFP4_GEMM_BACKEND=marlin (0.27 spelling) and --linear-backend marlin (0.30 spelling)
#   - --moe-backend marlin, --kv-cache-dtype fp8, --mamba-ssm-cache-dtype float16, --max-num-seqs 4
#   - super_v3 reasoning parser plugin from the model repo
#   - quantization is auto-detected from the checkpoint (modelopt MIXED_PRECISION: NVFP4 + FP8);
#     vLLM 0.30 has no "fp4" quantization alias
#   - MTP=1 uses the checkpoint's own BF16 MTP layer; the card's recipe instead loads a separate
#     BF16-MTPv2 draft checkpoint that we did not download
set -u
D=~/hack/claude-models/nemotron3-super
export VLLM_NVFP4_GEMM_BACKEND=marlin VLLM_NO_USAGE_STATS=1 TORCH_CUDA_ARCH_LIST=12.1 CUDA_HOME=/usr/local/cuda-13.0
export VLLM_CACHE_ROOT=$D/cache/vllm TORCHINDUCTOR_CACHE_DIR=$D/cache/inductor
# flashinfer JIT-builds its prefill module with ninja from the venv
export PATH=$HOME/hack/vllm-venv/bin:$CUDA_HOME/bin:$PATH
SPEC=()
if [ "${MTP:-1}" = 1 ]; then
  SPEC=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${NSPEC:-3},\"moe_backend\":\"triton\"}")
fi
exec ~/hack/vllm-venv/bin/vllm serve $D/weights --served-model-name nemotron-3-super-120b-a12b-nvfp4 \
  --host 127.0.0.1 --port 8120 --async-scheduling --dtype auto --kv-cache-dtype fp8 \
  --tensor-parallel-size 1 --trust-remote-code --gpu-memory-utilization "${GMU:-0.85}" \
  --enable-chunked-prefill --enable-prefix-caching --max-num-seqs 4 --max-model-len 65536 --max-num-batched-tokens 8192 \
  --moe-backend marlin --linear-backend marlin --mamba-ssm-cache-dtype float16 \
  --reasoning-parser-plugin $D/weights/super_v3_reasoning_parser.py --reasoning-parser super_v3 \
  "${SPEC[@]}"
