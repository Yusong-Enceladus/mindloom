#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-inference-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

"$repository_root/script/validate_inference_evidence.sh" \
  --summary "$temporary_root/valid-summary.json" >/dev/null
[[ "$(jq -r '.status' "$temporary_root/valid-summary.json")" == "pass" ]]

jq '.manifestSHA256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$repository_root/artifacts/evidence/SPIKE-ASR-001/adapter-contract-smoke.json" \
  > "$temporary_root/tampered-asr.json"
if "$repository_root/script/validate_inference_evidence.sh" \
  --asr-contract "$temporary_root/tampered-asr.json" \
  --summary "$temporary_root/tampered-summary.json" >/dev/null 2>&1; then
  print -u2 "expected tampered inference report reference to fail"
  exit 1
fi
[[ "$(jq -r '.failureCategory' "$temporary_root/tampered-summary.json")" \
  == "asr-registry-digest-mismatch" ]]

jq '.selectionEligible = false | .status = "fail"' \
  "$repository_root/artifacts/evidence/SPIKE-ASR-001/fluid-sensevoice-alpha-decision.json" \
  > "$temporary_root/tampered-alpha-decision.json"
if "$repository_root/script/validate_inference_evidence.sh" \
  --asr-alpha-decision "$temporary_root/tampered-alpha-decision.json" \
  --summary "$temporary_root/tampered-alpha-summary.json" >/dev/null 2>&1; then
  print -u2 "expected tampered alpha ASR decision to fail"
  exit 1
fi
[[ "$(jq -r '.failureCategory' "$temporary_root/tampered-alpha-summary.json")" \
  == "alpha-evidence-digest-mismatch" ]]

jq '.candidates[0].automatic.benchmarkResultSHA256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$repository_root/artifacts/evidence/SPIKE-SPK-001/recommended-memory-synthetic-smoke-summary.json" \
  > "$temporary_root/tampered-speaker.json"
if "$repository_root/script/validate_inference_evidence.sh" \
  --speaker-recommended-smoke "$temporary_root/tampered-speaker.json" \
  --summary "$temporary_root/tampered-speaker-summary.json" >/dev/null 2>&1; then
  print -u2 "expected tampered speaker evidence reference to fail"
  exit 1
fi
[[ "$(jq -r '.failureCategory' "$temporary_root/tampered-speaker-summary.json")" \
  == "speaker-summary-reference-mismatch" ]]

jq '.networkDeniedByParentSandbox = false' \
  "$repository_root/artifacts/evidence/privacy/installed-model-dictation-summary.json" \
  > "$temporary_root/tampered-installed-model.json"
if "$repository_root/script/validate_inference_evidence.sh" \
  --installed-model-dictation "$temporary_root/tampered-installed-model.json" \
  --summary "$temporary_root/tampered-installed-model-summary.json" \
  >/dev/null 2>&1; then
  print -u2 "expected tampered installed-model dictation evidence to fail"
  exit 1
fi
[[ "$(jq -r '.failureCategory' "$temporary_root/tampered-installed-model-summary.json")" \
  == "installed-model-dictation-contract-invalid" ]]

print "inference evidence fixtures passed: alpha/release, installed-model privacy, and tamper rejection"
