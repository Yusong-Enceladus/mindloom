#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_path="$repository_root/artifacts/evidence/local-text/qwen3-1.7b-alpha-polish-gate.json"
suite_path="$repository_root/Tests/Fixtures/LocalText/alpha-polish-real-model-suite.json"
models_path="$repository_root/config/model-artifacts.json"
summary_path="$repository_root/artifacts/evidence/local-text/validation-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --evidence) evidence_path="$2"; shift 2 ;;
    --suite) suite_path="$2"; shift 2 ;;
    --models) models_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

for required in "$evidence_path" "$suite_path" "$models_path"; do
  [[ -f "$required" ]] || {
    print -u2 "error: missing local-text evidence input: $required"
    exit 1
  }
done

artifact_id="qwen3-1.7b-mlx-4bit-21457c6f"
exact_version="$(jq -r --arg id "$artifact_id" \
  '.models[] | select(.id == $id) | .exactVersion' "$models_path")"
tree_digest="$(jq -r --arg id "$artifact_id" \
  '.models[] | select(.id == $id) | .treeSHA256' "$models_path")"

validation_status="pass"
failed_check=""
if ! jq -e \
  --arg artifact "$artifact_id" \
  --arg version "$exact_version" \
  --arg tree "$tree_digest" \
  --slurpfile suite "$suite_path" '
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    .schemaVersion == 2 and
    .kind == "local-text-real-model-gate-summary" and
    .suiteID == $suite[0].suiteID and
    .artifactID == $artifact and
    .sourceRevision == $version and
    .treeSHA256 == $tree and
    (.runtimeRevision | type == "string" and length == 40) and
    .generationCountPerSample == $suite[0].generationCountPerSample and
    .generationInvocationCount == (.sampleCount * .generationCountPerSample) and
    .sampleCount == ($suite[0].samples | length) and
    .minimumStylePassCount == $suite[0].minimumStylePassCount and
    .maximumModelLoadMilliseconds == $suite[0].maximumModelLoadMilliseconds and
    .maximumP95LatencyMilliseconds == $suite[0].maximumP95LatencyMilliseconds and
    .maximumPeakResidentBytes == $suite[0].maximumPeakResidentBytes and
    .modelLoadMilliseconds <= .maximumModelLoadMilliseconds and
    .p95LatencyMilliseconds <= .maximumP95LatencyMilliseconds and
    .peakResidentBytes <= .maximumPeakResidentBytes and
    .factualFailureCount == 0 and
    .generationFailureCount == 0 and
    .deterministicMismatchCount == 0 and
    .stylePassCount >= .minimumStylePassCount and
    .changedSampleCount == .sampleCount and
    .resourceGatePassed == true and
    .hardGateEligible == true and
    (.generationConfiguration.temperature == 0) and
    (.generationConfiguration.thinkingEnabled == false) and
    (.generationConfiguration.maximumOutputTokens > 0) and
    (.generationConfiguration.maximumKVCacheTokens >= .generationConfiguration.maximumOutputTokens) and
    ([.samples[].sampleUUID] | sort) == ([$suite[0].samples[].sampleUUID] | sort) and
    all(.samples[];
      (keys - [
        "changed", "deterministicOutputMatched", "errorCode",
        "factualGatePassed", "forbiddenSubstringsRemoved",
        "latencyMilliseconds", "sampleUUID", "styleGatePassed",
        "terminalPunctuationPresent", "violatedCategories"
      ] | length == 0) and
      .factualGatePassed == true and
      .deterministicOutputMatched == true and
      .styleGatePassed == true and
      .changed == true and
      ((has("errorCode") | not) or .errorCode == null) and
      (.violatedCategories | length == 0)
    )
  ' "$evidence_path" >/dev/null
then
  validation_status="fail"
  failed_check="local-text-real-model-gate"
fi

mkdir -p "$(dirname "$summary_path")"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-local-text-validation.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT
jq -n \
  --arg status "$validation_status" \
  --arg failedCheck "$failed_check" \
  --arg artifactID "$artifact_id" \
  --argjson factualFailures "$(jq -r '.factualFailureCount // -1' "$evidence_path")" \
  --argjson deterministicMismatches "$(jq -r '.deterministicMismatchCount // -1' "$evidence_path")" \
  --argjson p95Milliseconds "$(jq -r '.p95LatencyMilliseconds // -1' "$evidence_path")" \
  --argjson peakResidentBytes "$(jq -r '.peakResidentBytes // -1' "$evidence_path")" \
  '{
    schemaVersion: 1,
    kind: "local-text-evidence-validation-summary",
    status: $status,
    failedCheck: $failedCheck,
    artifactID: $artifactID,
    factualFailureCount: $factualFailures,
    deterministicMismatchCount: $deterministicMismatches,
    p95LatencyMilliseconds: $p95Milliseconds,
    peakResidentBytes: $peakResidentBytes
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

if [[ "$validation_status" != "pass" ]]; then
  print -u2 "local-text evidence validation failed: $failed_check"
  exit 1
fi

print "local-text evidence passed"
