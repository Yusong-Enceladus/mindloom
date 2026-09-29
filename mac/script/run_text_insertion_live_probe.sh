#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
scratch_root="$BESTASR_SWIFTPM_SCRATCH"
module_cache_root="$BESTASR_SWIFTPM_MODULE_CACHE"
clang_cache_root="$BESTASR_CLANG_MODULE_CACHE"
summary_file="$repository_root/artifacts/evidence/SPIKE-INS-001/live-summary.json"
working_root="$BESTASR_WORK_ROOT/AXLiveProbe"

while (( $# > 0 )); do
  case "$1" in
    --summary) summary_file="$2"; shift 2 ;;
    --working-root) working_root="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

mkdir -p "$module_cache_root" "$clang_cache_root" "$working_root"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_root"
export CLANG_MODULE_CACHE_PATH="$clang_cache_root"

swift build \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_root" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product AXInsertionFixture
swift build \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_root" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product AXLiveProbeCLI

binary_root="$(
  swift build \
    --package-path "$repository_root/Packages/BestASRCore" \
    --scratch-path "$scratch_root" \
    --cache-path "$BESTASR_SWIFTPM_CACHE" \
    --show-bin-path
)"
fixture_app="$working_root/AXInsertionFixture.app"
fixture_executable="$fixture_app/Contents/MacOS/AXInsertionFixture"
probe_executable="$binary_root/AXLiveProbeCLI"
mkdir -p "$fixture_app/Contents/MacOS"
cp -f "$binary_root/AXInsertionFixture" "$fixture_executable"
cp -f \
  "$repository_root/Spikes/SPIKE-INS-001/AXInsertionFixture/Info.plist" \
  "$fixture_app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$fixture_app" >/dev/null

"$probe_executable" \
  --fixture "$fixture_executable" \
  --summary "$summary_file" \
  --working-root "$working_root"
