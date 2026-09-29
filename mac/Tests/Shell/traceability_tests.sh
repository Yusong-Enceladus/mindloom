#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$repository_root/Tests/Fixtures/Traceability"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-trace-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

run_validator() {
  local fixture_name="$1"
  "$repository_root/script/validate_traceability.sh" \
    --manifest "$fixture_root/$fixture_name.json" \
    --summary "$temporary_root/$fixture_name-summary.json"
}

run_validator valid >/dev/null

for rejected_fixture in orphan-id stale-path missing-evidence; do
  if run_validator "$rejected_fixture" >/dev/null 2>&1; then
    print -u2 "expected traceability fixture to fail: $rejected_fixture"
    exit 1
  fi
  [[ "$(jq -r '.status' "$temporary_root/$rejected_fixture-summary.json")" == "fail" ]]
done

print "traceability fixtures passed: valid plus 3 fail-closed mutations"
