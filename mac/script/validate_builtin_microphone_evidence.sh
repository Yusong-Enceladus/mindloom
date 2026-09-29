#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_path="$repository_root/artifacts/evidence/dictation-alpha/builtin-microphone-smoke.json"
summary_path="$repository_root/artifacts/evidence/dictation-alpha/builtin-microphone-validation.json"

while (( $# > 0 )); do
  case "$1" in
    --evidence) evidence_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

validation_status="pass"
failed_check=""
if [[ ! -f "$evidence_path" ]]; then
  validation_status="fail"
  failed_check="missing-evidence"
elif ! jq -e '
  .schemaVersion == 1 and
  .kind == "builtin-microphone-smoke" and
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
  .cancelFrameCount > 0 and
  .networkDeniedByParentSandbox == true and
  .audioPersisted == false and
  .userContentRecordedInEvidence == false and
  ([.. | objects | keys[]] | any(
    . == "audioBytes" or
    . == "audioPath" or
    . == "absolutePath" or
    . == "deviceUID" or
    . == "text" or
    . == "transcript"
  ) | not)
' "$evidence_path" >/dev/null; then
  validation_status="fail"
  failed_check="microphone-evidence-contract"
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-mic-validation.XXXXXX")"
temporary_summary="$temporary_root/summary.json"
trap 'rm -f "$temporary_summary"; rmdir "$temporary_root" 2>/dev/null || true' EXIT
mkdir -p "$(dirname "$summary_path")"
jq -S -n \
  --arg status "$validation_status" \
  --arg failedCheck "$failed_check" \
  --arg evidenceSHA256 "$(
    if [[ -f "$evidence_path" ]]; then
      shasum -a 256 "$evidence_path" | awk '{print $1}'
    fi
  )" '
  {
    schemaVersion: 1,
    kind: "builtin-microphone-evidence-validation",
    status: $status,
    failedCheck: $failedCheck,
    evidenceSHA256: $evidenceSHA256,
    audioContentPersisted: false
  }
' > "$temporary_summary"
mv "$temporary_summary" "$summary_path"
rmdir "$temporary_root"
trap - EXIT

if [[ "$validation_status" != "pass" ]]; then
  print -u2 "built-in microphone evidence validation failed: $failed_check"
  exit 1
fi

print "built-in microphone evidence passed"
