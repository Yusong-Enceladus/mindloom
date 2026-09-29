#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
duration_seconds="${BESTASR_LONG_RECORDING_SECONDS:-7200}"

swift run \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  LongRecordingProbeCLI \
  --duration-seconds "$duration_seconds" \
  --evidence "$repository_root/artifacts/evidence/SPIKE-JRN-001/long-recording.json" \
  --working-root "$BESTASR_WORK_ROOT/LongRecordingProbe"
