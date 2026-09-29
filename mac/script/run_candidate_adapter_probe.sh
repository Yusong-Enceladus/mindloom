#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
output_path="${1:-$repository_root/artifacts/evidence/SPIKE-ASR-001/adapter-contract-smoke.json}"

swift run \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  CandidateAdapterProbeCLI \
  --repository-root "$repository_root" \
  --output "$output_path"
