#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
scratch_root="$BESTASR_SWIFTPM_SCRATCH"
module_cache_root="$BESTASR_SWIFTPM_MODULE_CACHE"
clang_cache_root="$BESTASR_CLANG_MODULE_CACHE"
summary_file="$repository_root/artifacts/evidence/SPIKE-INS-001/compatibility-summary.json"
target_id=""
target_classes=""
expected_bundle_id=""
standard_trials=20
fallback_trials=5

while (( $# > 0 )); do
  case "$1" in
    --summary) summary_file="$2"; shift 2 ;;
    --target-id) target_id="$2"; shift 2 ;;
    --target-classes) target_classes="$2"; shift 2 ;;
    --expected-bundle-id) expected_bundle_id="$2"; shift 2 ;;
    --standard-trials) standard_trials="$2"; shift 2 ;;
    --fallback-trials) fallback_trials="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

if [[ -z "$target_id" || -z "$target_classes" || -z "$expected_bundle_id" ]]; then
  print -u2 "error: --target-id, --target-classes, and --expected-bundle-id are required"
  exit 64
fi

mkdir -p "$module_cache_root" "$clang_cache_root"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_root"
export CLANG_MODULE_CACHE_PATH="$clang_cache_root"

swift build \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_root" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product AXCompatibilityProbeCLI
binary_root="$(
  swift build \
    --package-path "$repository_root/Packages/BestASRCore" \
    --scratch-path "$scratch_root" \
    --cache-path "$BESTASR_SWIFTPM_CACHE" \
    --show-bin-path
)"

"$binary_root/AXCompatibilityProbeCLI" \
  --summary "$summary_file" \
  --target-id "$target_id" \
  --target-classes "$target_classes" \
  --expected-bundle-id "$expected_bundle_id" \
  --standard-trials "$standard_trials" \
  --fallback-trials "$fallback_trials"
