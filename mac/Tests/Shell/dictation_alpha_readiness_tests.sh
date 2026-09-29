#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$repository_root/Tests/Fixtures/DictationAlphaReadiness"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-dictation-alpha-readiness-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

generate_fixture() {
  local name="$1"
  "$repository_root/script/generate_dictation_alpha_readiness.sh" \
    --gates "$fixture_root/$name-gates.json" \
    --json "$temporary_root/$name.json" \
    --markdown "$temporary_root/$name.md" >/dev/null
}

generate_fixture pass
generate_fixture conditional
generate_fixture fail

[[ "$(jq -r '.dictationAlphaConclusion' "$temporary_root/pass.json")" == "pass" ]]
[[ "$(jq -r '.dictationAlphaReady' "$temporary_root/pass.json")" == "true" ]]
[[ "$(jq -r '.formalMVPConclusion' "$temporary_root/pass.json")" == "conditional" ]]
[[ "$(jq -r '.formalMVPReady' "$temporary_root/pass.json")" == "false" ]]
[[ "$(jq -r '.v1Ready' "$temporary_root/pass.json")" == "false" ]]
[[ "$(jq -r '.unresolvedWholeProductGaps | length' "$temporary_root/pass.json")" == "3" ]]
[[ "$(jq -r '.dictationAlphaConclusion' "$temporary_root/conditional.json")" == "conditional" ]]
[[ "$(jq -r '.dictationAlphaReady' "$temporary_root/conditional.json")" == "false" ]]
[[ "$(jq -r '.dictationAlphaConclusion' "$temporary_root/fail.json")" == "fail" ]]
[[ "$(jq -r '.separationInvariant' "$temporary_root/fail.json")" == "true" ]]
rg -Fq "Whole-product gaps" "$temporary_root/pass.md"

print "dictation alpha readiness fixtures passed: pass, conditional, fail, and whole-product separation"
