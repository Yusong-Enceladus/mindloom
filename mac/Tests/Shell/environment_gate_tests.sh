#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
result_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-environment-gate.XXXXXX")"
trap 'rm -rf "$result_root"' EXIT

evidence_root="$result_root/evidence"
derived_root="$result_root/derived"
run_id="fixture-pass"

BESTASR_TEST_MODE=1 \
  BESTASR_TEST_STUB_STAGES=1 \
  "$repository_root/script/record_environment_gate.sh" \
    --run-id "$run_id" \
    --evidence-root "$evidence_root" \
    --derived-root "$derived_root" >/dev/null

run_directory="$evidence_root/$run_id"
test -f "$run_directory/gate-run.json"
test -f "$run_directory/toolchain-summary.json"
test -f "$run_directory/command-summary.json"
test -f "$run_directory/test-summary.json"
test -f "$run_directory/check-summary.json"

jq -e '
  .status == "pass" and
  .exitCode == 0 and
  .freshDerivedDataAtStart == true and
  (.files.toolchain.sha256 | length) == 64 and
  (.files.command.sha256 | length) == 64 and
  (.files.tests.sha256 | length) == 64 and
  (.files.check.sha256 | length) == 64
' "$run_directory/gate-run.json" >/dev/null
jq -e '
  .status == "pass" and
  .exitCode == 0 and
  .command[0] == "script/check.sh" and
  (.command | length) == 5
' "$run_directory/command-summary.json" >/dev/null
jq -e '
  .overallStatus == "pass" and
  (.tests | length) == 3 and
  ([.tests[] | select(.status == "pass")] | length) == 3
' "$run_directory/test-summary.json" >/dev/null
jq -e '
  .architecture == "arm64" and
  (.xcode | length) > 0 and
  (.swift | length) > 0 and
  (.xcodegen | length) > 0
' "$run_directory/toolchain-summary.json" >/dev/null

set +e
BESTASR_TEST_MODE=1 \
  BESTASR_TEST_STUB_STAGES=1 \
  "$repository_root/script/record_environment_gate.sh" \
    --run-id "$run_id" \
    --evidence-root "$evidence_root" \
    --derived-root "$derived_root" >/dev/null 2>&1
duplicate_exit_code=$?
set -e
if (( duplicate_exit_code == 0 )); then
  print -u2 "expected duplicate environment Gate run to fail"
  exit 1
fi

preexisting_run_id="preexisting-derived-data"
mkdir -p "$derived_root/$preexisting_run_id/DerivedData"
set +e
BESTASR_TEST_MODE=1 \
  BESTASR_TEST_STUB_STAGES=1 \
  "$repository_root/script/record_environment_gate.sh" \
    --run-id "$preexisting_run_id" \
    --evidence-root "$evidence_root" \
    --derived-root "$derived_root" >/dev/null 2>&1
preexisting_exit_code=$?
set -e
if (( preexisting_exit_code == 0 )); then
  print -u2 "expected a preexisting DerivedData run to fail"
  exit 1
fi
test ! -e "$evidence_root/$preexisting_run_id"

print "environment Gate fixtures passed"
