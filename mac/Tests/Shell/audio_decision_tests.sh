#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-audio-decision-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

"$repository_root/script/validate_audio_decision.sh" \
  --summary "$temporary_root/valid-summary.json" >/dev/null
[[ "$(jq -r '.status' "$temporary_root/valid-summary.json")" == "pass" ]]
[[ "$(jq -r '.dependentCommitmentAllowed' "$temporary_root/valid-summary.json")" == "false" ]]

sed -E 's/[0-9a-f]{64}/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/g' \
  "$repository_root/docs/architecture/decisions/ADR-0003-audio-journal-timebase.md" \
  > "$temporary_root/tampered-adr.md"
if "$repository_root/script/validate_audio_decision.sh" \
  --adr "$temporary_root/tampered-adr.md" \
  --summary "$temporary_root/tampered-summary.json" >/dev/null 2>&1; then
  print -u2 "expected stale ADR evidence digest to fail"
  exit 1
fi
[[ "$(jq -r '.failureCategory' "$temporary_root/tampered-summary.json")" \
  == "adr-evidence-digest-mismatch" ]]

print "audio decision fixtures passed: live references plus stale digest"
