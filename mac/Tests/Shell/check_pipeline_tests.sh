#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
result_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-check-pipeline.XXXXXX")"
trap 'rm -f "$result_root"/*.json; rmdir "$result_root" 2>/dev/null || true' EXIT

stage_names=(
  bootstrap
  project-regeneration
  static-analysis
  foundation-fixtures
  swift-package-tests
  xcode-build
  unit-tests
  ui-tests
  privacy-scan
  artifact-manifests
)

for stage_name in "${stage_names[@]}"; do
  summary_path="$result_root/$stage_name.json"
  set +e
  BESTASR_TEST_MODE=1 \
    BESTASR_TEST_STUB_STAGES=1 \
    BESTASR_TEST_FAIL_STAGE="$stage_name" \
    "$repository_root/script/check.sh" \
      --summary "$summary_path" \
      --derived-data "$result_root/DerivedData" >/dev/null 2>&1
  exit_code=$?
  set -e

  if (( exit_code == 0 )); then
    print -u2 "expected injected stage to fail: $stage_name"
    exit 1
  fi
  jq -e \
    --arg stage "$stage_name" \
    '.status == "fail" and
     .failedStage == $stage and
     ([.stages[] | select(.status == "fail")] | length) == 1 and
     ([.stages[] | select(.name == $stage and .status == "fail")] | length) == 1' \
    "$summary_path" >/dev/null
done

print "check pipeline fixtures passed: every injected stage is fail-closed"
