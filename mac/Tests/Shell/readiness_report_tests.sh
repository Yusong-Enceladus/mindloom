#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$repository_root/Tests/Fixtures/Readiness"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-readiness-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

generate_fixture() {
  local name="$1"
  local tasks="$2"
  "$repository_root/script/generate_engineering_readiness.sh" \
    --gates "$fixture_root/$name-gates.json" \
    --tasks "$fixture_root/$tasks.md" \
    --json "$temporary_root/$name.json" \
    --markdown "$temporary_root/$name.md" >/dev/null
}

generate_fixture pass tasks-complete
generate_fixture conditional tasks-pending
generate_fixture fail tasks-complete

[[ "$(jq -r '.conclusion' "$temporary_root/pass.json")" == "pass" ]]
[[ "$(jq -r '.verified' "$temporary_root/pass.json")" == "true" ]]
[[ "$(jq -r '.conclusion' "$temporary_root/conditional.json")" == "conditional" ]]
[[ "$(jq -r '.verified' "$temporary_root/conditional.json")" == "false" ]]
[[ "$(jq -r '.pendingTaskCount' "$temporary_root/conditional.json")" == "1" ]]
[[ "$(jq -r '.gates[0].observedValue' "$temporary_root/conditional.json")" == "false" ]]
[[ "$(jq -r '.conclusion' "$temporary_root/fail.json")" == "fail" ]]
[[ "$(jq -r '.releaseEligible' "$temporary_root/fail.json")" == "false" ]]
rg -Fq "Delivery status" "$temporary_root/fail.md"

print "readiness report fixtures passed: pass, conditional, and fail"
