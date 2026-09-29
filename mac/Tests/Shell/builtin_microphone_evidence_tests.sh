#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-mic-evidence-tests.XXXXXX")"
trap 'rm -f "$temporary_root"/*; rmdir "$temporary_root" 2>/dev/null || true' EXIT

cp "$repository_root/artifacts/evidence/dictation-alpha/builtin-microphone-smoke.json" \
  "$temporary_root/evidence.json"
"$repository_root/script/validate_builtin_microphone_evidence.sh" \
  --evidence "$temporary_root/evidence.json" \
  --summary "$temporary_root/pass.json" >/dev/null
[[ "$(jq -r .status "$temporary_root/pass.json")" == "pass" ]]

jq '.audioPersisted = true' "$temporary_root/evidence.json" \
  > "$temporary_root/tampered.json"
if "$repository_root/script/validate_builtin_microphone_evidence.sh" \
  --evidence "$temporary_root/tampered.json" \
  --summary "$temporary_root/fail.json" >/dev/null 2>&1
then
  print -u2 "error: persisted microphone content unexpectedly passed"
  exit 1
fi
[[ "$(jq -r .failedCheck "$temporary_root/fail.json")" == "microphone-evidence-contract" ]]

print "built-in microphone evidence fixtures passed: valid and privacy tamper rejection"
