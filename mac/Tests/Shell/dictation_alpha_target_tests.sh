#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-alpha-target-tests.XXXXXX")"
trap 'rm -f "$temporary_root"/*; rmdir "$temporary_root" 2>/dev/null || true' EXIT

cp "$repository_root/artifacts/evidence/SPIKE-INS-001/live-summary.json" \
  "$temporary_root/live.json"
cp "$repository_root/artifacts/evidence/SPIKE-INS-001/compatibility-summary.json" \
  "$temporary_root/compatibility.json"

"$repository_root/script/validate_dictation_alpha_targets.sh" \
  --live "$temporary_root/live.json" \
  --compatibility "$temporary_root/compatibility.json" \
  --summary "$temporary_root/pass.json" >/dev/null
[[ "$(jq -r .status "$temporary_root/pass.json")" == "pass" ]]
[[ "$(jq -r .selectedTargetCount "$temporary_root/pass.json")" == "3" ]]
# Terminal passed its release class on 2026-08-28 (2da6a89); nothing is pending.
[[ "$(jq -r .terminalReleaseClassPending "$temporary_root/pass.json")" == "false" ]]
[[ "$(jq -r .broaderReleaseMatrixConclusion "$temporary_root/pass.json")" == "pass" ]]

jq '(.targets[] | select(.targetID == "chrome") | .wrongTargetWriteCount) = 1' \
  "$temporary_root/compatibility.json" > "$temporary_root/tampered.json"
if "$repository_root/script/validate_dictation_alpha_targets.sh" \
  --live "$temporary_root/live.json" \
  --compatibility "$temporary_root/tampered.json" \
  --summary "$temporary_root/fail.json" >/dev/null 2>&1
then
  print -u2 "error: tampered alpha target evidence unexpectedly passed"
  exit 1
fi
[[ "$(jq -r .failedCheck "$temporary_root/fail.json")" == "selected-target-matrix" ]]

print "dictation alpha target fixtures passed: selected support set and tamper rejection"
