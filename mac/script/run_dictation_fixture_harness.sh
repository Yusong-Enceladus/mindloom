#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
output_path="$repository_root/artifacts/evidence/dictation-alpha/deterministic-vertical-slice.json"
scratch_path="$BESTASR_SWIFTPM_SCRATCH"

while (( $# > 0 )); do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    --scratch-path)
      scratch_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

swift run \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_path" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  DictationFixtureHarnessCLI \
  --output "$output_path"
