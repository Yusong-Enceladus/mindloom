#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
live_path="$repository_root/artifacts/evidence/SPIKE-INS-001/live-summary.json"
compatibility_path="$repository_root/artifacts/evidence/SPIKE-INS-001/compatibility-summary.json"
summary_path="$repository_root/artifacts/evidence/dictation-alpha/target-compatibility-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --live) live_path="$2"; shift 2 ;;
    --compatibility) compatibility_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

for required_tool in jq shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing alpha target validation tool: $required_tool"
    exit 2
  }
done

validation_status="pass"
failed_check=""
if [[ ! -f "$live_path" || ! -f "$compatibility_path" ]]; then
  validation_status="fail"
  failed_check="missing-input"
elif ! jq -e '
  .schemaVersion == 1 and
  .kind == "ax-live-insertion-probe" and
  .conclusion == "pass" and
  .liveAccessibilityEvaluated == true and
  ([.scenarios[].scenarioID] | sort) == ([
    "live-clipboard-fallback-restores-owned-pasteboard",
    "live-focus-race-fails-closed",
    "live-noneditable-rejected",
    "live-permission-denial-fails-before-write",
    "live-secure-field-rejected",
    "live-selection-race-fails-closed",
    "live-selection-replace"
  ] | sort) and
  all(.scenarios[];
    .status == "pass" and
    .wrongTargetWriteCount == 0 and
    .durationMilliseconds >= 0
  )
' "$live_path" >/dev/null; then
  validation_status="fail"
  failed_check="live-safety-matrix"
elif ! jq -e '
  .schemaVersion == 1 and
  .kind == "ax-compatibility-matrix" and
  .persistedTargetText == false and
  .persistedWindowTitle == false and
  .persistedClipboardContent == false and
  ([.targets[] | select(
    .targetID == "textedit" or
    .targetID == "chrome" or
    .targetID == "vscode-screen-reader-mode"
  )] | length) == 3 and
  all(.targets[] | select(
    .targetID == "textedit" or
    .targetID == "chrome" or
    .targetID == "vscode-screen-reader-mode"
  );
    .status == "pass" and
    .standardTrialCount >= 20 and
    .forcedFallbackTrialCount >= 5 and
    .successfulTrialCount == (.standardTrialCount + .forcedFallbackTrialCount) and
    .successRate == 1 and
    .clipboardRestoreFailureCount == 0 and
    .wrongTargetWriteCount == 0 and
    .unexpectedSideEffectCount == 0 and
    .cleanupSucceeded == true
  ) and
  ([.targets[] | select(.targetID == "textedit") | .targetClasses[]] | contains(["apple-editor"])) and
  ([.targets[] | select(.targetID == "chrome") | .targetClasses[]] | contains(["browser"])) and
  ([.targets[] | select(.targetID == "vscode-screen-reader-mode") | .targetClasses[]] | contains(["electron"]))
' "$compatibility_path" >/dev/null; then
  validation_status="fail"
  failed_check="selected-target-matrix"
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-alpha-targets.XXXXXX")"
temporary_summary="$temporary_root/summary.json"
trap 'rm -f "$temporary_summary"; rmdir "$temporary_root" 2>/dev/null || true' EXIT
mkdir -p "$(dirname "$summary_path")"

if [[ "$validation_status" == "pass" ]]; then
  jq -S -n \
    --arg status "$validation_status" \
    --arg liveSHA256 "$(shasum -a 256 "$live_path" | awk '{print $1}')" \
    --arg compatibilitySHA256 "$(shasum -a 256 "$compatibility_path" | awk '{print $1}')" \
    --slurpfile compatibility "$compatibility_path" '
    {
      schemaVersion: 1,
      kind: "dictation-alpha-target-compatibility",
      status: $status,
      selectedSupportSet: [
        "textedit",
        "chrome",
        "vscode-screen-reader-mode"
      ],
      selectedTargetCount: 3,
      standardTrialsPerTargetMinimum: 20,
      forcedFallbackTrialsPerTargetMinimum: 5,
      directInsertionCovered: true,
      clipboardFallbackCovered: true,
      secureFieldRejectionCovered: true,
      focusAndSelectionConflictCovered: true,
      exactlyOnceCovered: true,
      wrongTargetWriteCount: 0,
      clipboardRestoreFailureCount: 0,
      persistedUserContent: false,
      broaderReleaseMatrixConclusion: $compatibility[0].conclusion,
      terminalReleaseClassPending: (
        $compatibility[0].unmetCriteria |
        any(test("terminal"; "i"))
      ),
      liveEvidenceSHA256: $liveSHA256,
      compatibilityEvidenceSHA256: $compatibilitySHA256
    }
  ' > "$temporary_summary"
else
  jq -S -n \
    --arg status "$validation_status" \
    --arg failedCheck "$failed_check" '
    {
      schemaVersion: 1,
      kind: "dictation-alpha-target-compatibility",
      status: $status,
      failedCheck: $failedCheck,
      persistedUserContent: false
    }
  ' > "$temporary_summary"
fi

mv "$temporary_summary" "$summary_path"
rmdir "$temporary_root"
trap - EXIT

if [[ "$validation_status" != "pass" ]]; then
  print -u2 "dictation alpha target validation failed: $failed_check"
  exit 1
fi

print "dictation alpha target support set passed; broader Terminal matrix remains conditional"
