#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_root="$repository_root/Packages/BestASRCore"
summary_path="$repository_root/artifacts/evidence/dictation-alpha/builtin-microphone-smoke.json"

for required_tool in swift jq /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing built-in microphone smoke tool: $required_tool"
    exit 2
  }
done

swift build \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product MicrophoneCaptureSmokeCLI >/dev/null
binary_root="$(swift build --package-path "$package_root" --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" --show-bin-path)"
payload="$({
  BESTASR_RUN_MICROPHONE_SMOKE=1 /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$binary_root/MicrophoneCaptureSmokeCLI"
})"

jq -e '
  .status == "pass" and
  .builtIn == true and
  .sampleRateHertz > 0 and
  .channelCount > 0 and
  .chunkCount > 0 and
  .frameCount > 0 and
  .pauseResumeSucceeded == true and
  .pauseBufferedChunkDelta >= 0 and
  .pauseBufferedChunkDelta <= 1 and
  .cancelSucceeded == true and
  .cancelChunkCount > 0 and
  .cancelFrameCount > 0
' <<< "$payload" >/dev/null || {
  print -u2 "error: built-in microphone smoke failed"
  exit 1
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-builtin-mic.XXXXXX")"
temporary_summary="$temporary_root/summary.json"
trap 'rm -f "$temporary_summary"; rmdir "$temporary_root" 2>/dev/null || true' EXIT
mkdir -p "$(dirname "$summary_path")"
jq -S '
  . + {
    schemaVersion: 1,
    kind: "builtin-microphone-smoke",
    networkDeniedByParentSandbox: true,
    audioPersisted: false,
    userContentRecordedInEvidence: false
  }
' <<< "$payload" > "$temporary_summary"
mv "$temporary_summary" "$summary_path"
rmdir "$temporary_root"
trap - EXIT

"$repository_root/script/validate_builtin_microphone_evidence.sh" >/dev/null
print "built-in microphone start/pause/resume/end/cancel smoke passed"
