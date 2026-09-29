#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
storage_script="$repository_root/script/build_storage.sh"

# The default volume is /Volumes/BestASRBuild; a developer may point the build
# at any other mounted volume with BESTASR_BUILD_VOLUME, and every path must
# follow it.
expected_root="${BESTASR_BUILD_VOLUME:-/Volumes/BestASRBuild}/bestASR"
output="$(env -u BESTASR_BUILD_ROOT "$storage_script")"
print -r -- "$output" | /usr/bin/grep -Fqx "BESTASR_BUILD_ROOT=$expected_root"
print -r -- "$output" | /usr/bin/grep -Fqx "BESTASR_XCODE_DERIVED_DATA=$expected_root/xcode/DerivedData"
print -r -- "$output" | /usr/bin/grep -Fqx "BESTASR_SWIFTPM_SCRATCH=$expected_root/swiftpm/Scratch"
print -r -- "$output" | /usr/bin/grep -Fqx "BESTASR_CORPUS_CACHE=$expected_root/corpora"

failure_log="$(mktemp "${TMPDIR:-/tmp}/bestasr-build-storage-test.XXXXXX")"
trap 'rm -f "$failure_log"' EXIT
if BESTASR_BUILD_VOLUME=/Volumes/bestASR-intentionally-unmounted "$storage_script" >"$failure_log" 2>&1; then
  print -u2 'expected an unmounted build volume to fail closed'
  exit 1
fi
/usr/bin/grep -Fq 'Build stopped to prevent a large local fallback.' "$failure_log"

print 'build storage tests passed'
