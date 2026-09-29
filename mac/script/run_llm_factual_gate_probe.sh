#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
summary_path="$repository_root/artifacts/evidence/SPIKE-LLM-001/summary.json"
matrix_path="$repository_root/artifacts/evidence/SPIKE-LLM-001/matrix.json"

swift run \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  LLMFactualGateProbeCLI \
  --repository-root "$repository_root" \
  --summary "$summary_path" \
  --matrix "$matrix_path"
