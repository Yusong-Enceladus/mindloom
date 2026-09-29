#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
result_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-permission-tests.XXXXXX")"
trap 'rm -f "$result_root"/*; rmdir "$result_root" 2>/dev/null || true' EXIT

lint_arguments=(
  --manifest "$repository_root/config/permissions.json"
  --project "$repository_root/project.yml"
  --info-plist "$repository_root/App/Info.plist"
  --entitlements "$repository_root/App/BestASR.entitlements"
)

"$repository_root/script/lint_permissions.sh" \
  "${lint_arguments[@]}" \
  --summary "$result_root/valid.json" >/dev/null

expect_failure() {
  local scenario="$1"
  shift
  set +e
  "$repository_root/script/lint_permissions.sh" \
    "$@" \
    --summary "$result_root/$scenario-summary.json" >/dev/null 2>&1
  exit_code=$?
  set -e
  if (( exit_code == 0 )); then
    print -u2 "expected permission lint failure: $scenario"
    exit 1
  fi
}

for permission_id in microphone system-audio accessibility; do
  mutated_manifest="$result_root/missing-$permission_id.json"
  jq --arg permission_id "$permission_id" \
    '.permissions |= map(select(.id != $permission_id))' \
    "$repository_root/config/permissions.json" > "$mutated_manifest"
  expect_failure "missing-$permission_id" \
    --manifest "$mutated_manifest" \
    --project "$repository_root/project.yml" \
    --info-plist "$repository_root/App/Info.plist" \
    --entitlements "$repository_root/App/BestASR.entitlements"
done

required_project_keys=(
  CODE_SIGN_ENTITLEMENTS
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS
  ENABLE_APP_SANDBOX
  GENERATE_INFOPLIST_FILE
  INFOPLIST_FILE
)
for required_key in "${required_project_keys[@]}"; do
  mutated_project="$result_root/missing-$required_key.yml"
  awk -v required_key="$required_key" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, required_key ":") != 1) {
        print $0
      }
    }
  ' "$repository_root/project.yml" > "$mutated_project"
  expect_failure "missing-$required_key" \
    --manifest "$repository_root/config/permissions.json" \
    --project "$mutated_project" \
    --info-plist "$repository_root/App/Info.plist" \
    --entitlements "$repository_root/App/BestASR.entitlements"
done

for info_key in NSAudioCaptureUsageDescription NSMicrophoneUsageDescription; do
  mutated_info_plist="$result_root/missing-$info_key.plist"
  cp "$repository_root/App/Info.plist" "$mutated_info_plist"
  plutil -remove "$info_key" "$mutated_info_plist"
  expect_failure "missing-$info_key" \
    --manifest "$repository_root/config/permissions.json" \
    --project "$repository_root/project.yml" \
    --info-plist "$mutated_info_plist" \
    --entitlements "$repository_root/App/BestASR.entitlements"
done

expect_failure "forbidden-network-entitlement" \
  --manifest "$repository_root/config/permissions.json" \
  --project "$repository_root/project.yml" \
  --info-plist "$repository_root/App/Info.plist" \
  --entitlements "$repository_root/Tests/Fixtures/Permissions/Forbidden.entitlements"

expect_failure "missing-required-audio-input-entitlement" \
  --manifest "$repository_root/config/permissions.json" \
  --project "$repository_root/project.yml" \
  --info-plist "$repository_root/App/Info.plist" \
  --entitlements "$repository_root/Tests/Fixtures/Permissions/MissingRequired.entitlements"

print "permission lint fixtures passed: valid plus 12 fail-closed mutations"
