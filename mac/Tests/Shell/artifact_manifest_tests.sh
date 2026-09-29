#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$repository_root/Tests/Fixtures/Artifacts"
result_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-artifact-tests.XXXXXX")"
trap 'rm -f "$result_root"/*.json; rmdir "$result_root" 2>/dev/null || true' EXIT

"$repository_root/script/validate_artifacts.sh" \
  --dependencies "$fixture_root/dependencies-valid.json" \
  --models "$fixture_root/models-empty.json" \
  --summary "$result_root/valid.json" >/dev/null

for invalid_fixture in dependencies-missing-digest.json dependencies-missing-license.json; do
  set +e
  "$repository_root/script/validate_artifacts.sh" \
    --dependencies "$fixture_root/$invalid_fixture" \
    --models "$fixture_root/models-empty.json" \
    --summary "$result_root/$invalid_fixture.json" >/dev/null 2>&1
  exit_code=$?
  set -e
  if (( exit_code == 0 )); then
    print -u2 "expected artifact fixture to fail: $invalid_fixture"
    exit 1
  fi
done

for invalid_model_fixture in \
  models-missing-license-snapshot.json \
  models-license-digest-mismatch.json
do
  set +e
  "$repository_root/script/validate_artifacts.sh" \
    --dependencies "$fixture_root/dependencies-valid.json" \
    --models "$fixture_root/$invalid_model_fixture" \
    --summary "$result_root/$invalid_model_fixture.json" >/dev/null 2>&1
  exit_code=$?
  set -e
  if (( exit_code == 0 )); then
    print -u2 "expected model artifact fixture to fail: $invalid_model_fixture"
    exit 1
  fi
done

tree_tampered="$result_root/models-tree-digest-mismatch.json"
jq '(.models[0].files[] | select(.relativePath == "README.md") | .relativePath) = "README-copy.md"' \
  "$repository_root/config/model-artifacts.json" > "$tree_tampered"
set +e
"$repository_root/script/validate_artifacts.sh" \
  --dependencies "$fixture_root/dependencies-valid.json" \
  --models "$tree_tampered" \
  --summary "$result_root/tree-tampered-summary.json" >/dev/null 2>&1
exit_code=$?
set -e
if (( exit_code == 0 )); then
  print -u2 "expected model tree path tamper to fail"
  exit 1
fi
[[ "$(jq -r '.failedManifest' "$result_root/tree-tampered-summary.json")" \
  == "model-tree-digest" ]]

print "artifact manifest fixtures passed: valid plus missing/tampered dependency, license, and model-tree metadata"
