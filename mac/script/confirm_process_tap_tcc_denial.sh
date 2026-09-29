#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
observation_path="/private/tmp/bestasr-process-tap-tcc-denial.json"
evidence_path="$repository_root/artifacts/evidence/SPIKE-CAP-001/tcc-denial.json"
operator_confirmed=0

while (( $# > 0 )); do
  case "$1" in
    --observation)
      observation_path="$2"
      shift 2
      ;;
    --evidence)
      evidence_path="$2"
      shift 2
      ;;
    --operator-confirmed-denial)
      operator_confirmed=1
      shift
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

if (( operator_confirmed != 1 )); then
  print -u2 "error: --operator-confirmed-denial is required"
  exit 64
fi

if [[ ! -f "$observation_path" ]]; then
  print -u2 "error: TCC denial observation is missing"
  exit 2
fi

expected_bundle_id="com.bestasr.spike.process-tap-tcc-denial-probe.v2"
if ! jq -e \
  --arg expectedBundleID "$expected_bundle_id" \
  '.schemaVersion == 1 and
    .kind == "process-tap-tcc-denial" and
    .spikeID == "SPIKE-CAP-001" and
    .probeBundleIdentifier == $expectedBundleID and
    .status == "conditional" and
    .denialObserved == true and
    .operatorConfirmedDenial == false and
    .tapCreated == true and
    .createTapStatus == 0 and
    .tapCountBefore >= 0 and
    .tapCountBefore == .tapCountAfter and
    .aggregateDeviceCountBefore >= 0 and
    .aggregateDeviceCountBefore == .aggregateDeviceCountAfter and
    .syntheticSourceOnly == true and
    .sourceAudioPersisted == false and
    .audioContentSuppressed == true and
    .watermarkDetected == false and
    (
      (
        .captureStarted == false and
        .startCaptureStatus != 0 and
        .callbackCount == 0 and
        .frameCount == 0 and
        .failureCategory ==
          "start-tap-io-rejected-awaiting-operator-confirmation"
      ) or
      (
        .captureStarted == true and
        .startCaptureStatus == 0 and
        .callbackCount > 0 and
        .frameCount >= 128 and
        .capturedRMS <= 0.000001 and
        .capturedWatermarkAmplitude < 0.001 and
        .failureCategory ==
          "audio-content-suppressed-awaiting-operator-confirmation"
      )
    )' \
  "$observation_path" >/dev/null
then
  print -u2 "error: observation does not prove a clean TCC denial"
  exit 1
fi

evidence_directory="$(dirname "$evidence_path")"
mkdir -p "$evidence_directory"
temporary_directory="$(
  mktemp -d "${TMPDIR:-/tmp}/bestasr-tcc-denial-confirm.XXXXXX"
)"
temporary_evidence="$temporary_directory/tcc-denial.json"
trap 'rm -f "$temporary_evidence"; rmdir "$temporary_directory" 2>/dev/null || true' EXIT

jq '
  .status = "pass"
  | .operatorConfirmedDenial = true
  | .failureCategory = if .captureStarted
      then "tcc-denied-audio-content-suppressed"
      else "tcc-denied-before-capture-start"
    end
' "$observation_path" > "$temporary_evidence"
mv "$temporary_evidence" "$evidence_path"
rmdir "$temporary_directory"
trap - EXIT

print "actual TCC denial evidence confirmed: $evidence_path"
