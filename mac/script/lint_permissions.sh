#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest_path="$repository_root/config/permissions.json"
project_path="$repository_root/project.yml"
info_plist_path="$repository_root/App/Info.plist"
entitlements_path="$repository_root/App/BestASR.entitlements"
summary_path="$repository_root/artifacts/evidence/permissions/permission-lint-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --manifest)
      manifest_path="$2"
      shift 2
      ;;
    --project)
      project_path="$2"
      shift 2
      ;;
    --info-plist)
      info_plist_path="$2"
      shift 2
      ;;
    --entitlements)
      entitlements_path="$2"
      shift 2
      ;;
    --summary)
      summary_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

for required_tool in jq plutil awk; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required permission lint tool missing: $required_tool"
    exit 2
  }
done

permission_status="pass"
failed_check=""
checked_usage_keys=0

record_failure() {
  if [[ "$permission_status" == "pass" ]]; then
    permission_status="fail"
    failed_check="$1"
  fi
}

project_setting() {
  local requested_key="$1"
  awk -v requested_key="$requested_key" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      prefix = requested_key ":"
      if (index(line, prefix) == 1) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "$project_path"
}

manifest_filter='def nonempty: type == "string" and length > 0;
  .schemaVersion == 1 and
  .appTarget == "BestASR" and
  (.infoPlistFile | nonempty) and
  (.entitlementsFile | nonempty) and
  .appSandboxEnabled == false and
  .injectBaseEntitlements == false and
  .requestPolicy == "on-demand-per-feature" and
  (.requiredEntitlements | type == "array") and
  (.forbiddenEntitlements | type == "array" and length > 0) and
  ([.permissions[].id] | sort) == ["accessibility", "microphone", "system-audio"] and
  all(.permissions[];
    (.requirementRefs | type == "array" and length > 0) and
    (.runtimeAuthorizationAPI | nonempty) and
    .requestTiming == "on-demand" and
    (.deniedBehavior | nonempty)
  ) and
  (.permissions[] | select(.id == "microphone") |
    .usageDescriptionKey == "NSMicrophoneUsageDescription" and
    (.usageDescription | nonempty)
  ) and
  (.permissions[] | select(.id == "system-audio") |
    .usageDescriptionKey == "NSAudioCaptureUsageDescription" and
    (.usageDescription | nonempty)
  ) and
  (.permissions[] | select(.id == "accessibility") |
    .usageDescriptionKey == null and
    .usageDescription == null and
    (.runtimeAuthorizationAPI | startswith("AXIsProcessTrustedWithOptions"))
  ) and
  (.workerPolicy.protectedResourceEntitlements == []) and
  (.workerPolicy.networkEntitlements == [])'

if [[ ! -f "$manifest_path" ]] || ! jq -e "$manifest_filter" "$manifest_path" >/dev/null; then
  record_failure "permission-manifest"
fi

if [[ ! -f "$project_path" ]]; then
  record_failure "project-config"
fi

if [[ "$permission_status" == "pass" ]]; then
  if [[ "$(project_setting GENERATE_INFOPLIST_FILE)" != "NO" ]]; then
    record_failure "GENERATE_INFOPLIST_FILE"
  fi
  if [[ "$(project_setting INFOPLIST_FILE)" != "$(jq -r .infoPlistFile "$manifest_path")" ]]; then
    record_failure "INFOPLIST_FILE"
  fi
  if [[ "$(project_setting ENABLE_APP_SANDBOX)" != "NO" ]]; then
    record_failure "ENABLE_APP_SANDBOX"
  fi
  if [[ "$(project_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS)" != "NO" ]]; then
    record_failure "CODE_SIGN_INJECT_BASE_ENTITLEMENTS"
  fi
  if [[ "$(project_setting CODE_SIGN_ENTITLEMENTS)" != "$(jq -r .entitlementsFile "$manifest_path")" ]]; then
    record_failure "CODE_SIGN_ENTITLEMENTS"
  fi
fi

if [[ ! -f "$info_plist_path" ]] || ! plutil -lint "$info_plist_path" >/dev/null; then
  record_failure "info-plist"
elif [[ "$permission_status" == "pass" ]]; then
  while IFS=$'\t' read -r info_key expected; do
    actual="$(/usr/libexec/PlistBuddy -c "Print :$info_key" "$info_plist_path" 2>/dev/null || true)"
    (( checked_usage_keys += 1 ))
    if [[ -z "$actual" || "$actual" != "$expected" ]]; then
      record_failure "$info_key"
    fi
  done < <(
    jq -r '.permissions[] |
      select(.usageDescriptionKey != null) |
      [.usageDescriptionKey, .usageDescription] | @tsv' "$manifest_path"
  )
fi

if [[ ! -f "$entitlements_path" ]] || ! plutil -lint "$entitlements_path" >/dev/null; then
  record_failure "entitlements-plist"
elif [[ "$permission_status" == "pass" ]]; then
  entitlement_json="$(plutil -convert json -o - "$entitlements_path")"
  required_json="$(jq -c .requiredEntitlements "$manifest_path")"
  forbidden_json="$(jq -c .forbiddenEntitlements "$manifest_path")"
  if ! jq -e \
    --argjson required "$required_json" \
    --argjson forbidden "$forbidden_json" \
    'type == "object" and
      (keys | sort) == ($required | sort) and
      ([keys[]] - $forbidden | length) == (keys | length)' \
    <<< "$entitlement_json" >/dev/null
  then
    record_failure "entitlement-minimum"
  fi
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-permission-lint.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT
jq -n \
  --arg status "$permission_status" \
  --arg failedCheck "$failed_check" \
  --arg manifest "${manifest_path#$repository_root/}" \
  --arg project "${project_path#$repository_root/}" \
  --arg infoPlist "${info_plist_path#$repository_root/}" \
  --arg entitlements "${entitlements_path#$repository_root/}" \
  --argjson checkedPermissionCount "$(jq '.permissions | length' "$manifest_path" 2>/dev/null || print 0)" \
  --argjson checkedUsageDescriptionCount "$checked_usage_keys" \
  '{
    schemaVersion: 1,
    kind: "permission-lint-summary",
    status: $status,
    failedCheck: $failedCheck,
    manifest: $manifest,
    project: $project,
    infoPlist: $infoPlist,
    entitlements: $entitlements,
    checkedPermissionCount: $checkedPermissionCount,
    checkedUsageDescriptionCount: $checkedUsageDescriptionCount,
    requirementsCovered: ["PRD-18.1", "PRD-18.2", "SYS-001..012", "DICT-006..008"]
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

if [[ "$permission_status" != "pass" ]]; then
  print -u2 "permission lint failed: $failed_check"
  exit 1
fi

print "permission lint passed: 3 capabilities, 2 usage descriptions, minimal entitlements"
