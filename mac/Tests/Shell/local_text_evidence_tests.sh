#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-local-text-tests.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

evidence="$work_root/evidence.json"
suite="$work_root/suite.json"
models="$work_root/models.json"
summary="$work_root/summary.json"
cp "$repository_root/artifacts/evidence/local-text/qwen3-1.7b-alpha-polish-gate.json" "$evidence"
cp "$repository_root/Tests/Fixtures/LocalText/alpha-polish-real-model-suite.json" "$suite"
cp "$repository_root/config/model-artifacts.json" "$models"

"$repository_root/script/validate_local_text_evidence.sh" \
  --evidence "$evidence" \
  --suite "$suite" \
  --models "$models" \
  --summary "$summary" >/dev/null
jq -e '.status == "pass"' "$summary" >/dev/null

jq '.factualFailureCount = 1 | .hardGateEligible = false' \
  "$evidence" > "$work_root/factual-failure.json"
if "$repository_root/script/validate_local_text_evidence.sh" \
  --evidence "$work_root/factual-failure.json" \
  --suite "$suite" \
  --models "$models" \
  --summary "$summary" >/dev/null 2>&1
then
  print -u2 "error: factual failure evidence unexpectedly passed"
  exit 1
fi
jq -e '.status == "fail"' "$summary" >/dev/null

jq '.samples[0].outputText = "transcript content must not be stored"' \
  "$evidence" > "$work_root/content-leak.json"
if "$repository_root/script/validate_local_text_evidence.sh" \
  --evidence "$work_root/content-leak.json" \
  --suite "$suite" \
  --models "$models" \
  --summary "$summary" >/dev/null 2>&1
then
  print -u2 "error: content-bearing evidence unexpectedly passed"
  exit 1
fi

print "local-text evidence validator tests passed"
