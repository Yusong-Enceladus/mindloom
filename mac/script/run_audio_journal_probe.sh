#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"

swift run \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  AudioJournalProbeCLI \
  --summary "$repository_root/artifacts/evidence/SPIKE-JRN-001/summary.json" \
  --matrix "$repository_root/artifacts/evidence/SPIKE-JRN-001/matrix.json"
