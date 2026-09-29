#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
manifest_path="$repository_root/config/permissions.json"
app_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Debug/bestASR.app"
summary_path="$repository_root/artifacts/evidence/permissions/built-app-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --manifest)
      manifest_path="$2"
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

app_permission_status="pass"
failed_check=""
checked_usage_keys=0
checked_required_entitlements=0
signature_valid=false
xpc_signature_valid=false
bundle_identifier=""

record_failure() {
  if [[ "$app_permission_status" == "pass" ]]; then
    app_permission_status="fail"
    failed_check="$1"
  fi
}

info_plist="$app_path/Contents/Info.plist"
xpc_path="$app_path/Contents/XPCServices/InferenceWorker.xpc"
if [[ ! -d "$app_path" || ! -f "$info_plist" ]]; then
  record_failure "built-app"
else
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  while IFS=$'\t' read -r info_key expected; do
    actual="$(/usr/libexec/PlistBuddy -c "Print :$info_key" "$info_plist" 2>/dev/null || true)"
    (( checked_usage_keys += 1 ))
    if [[ -z "$actual" || "$actual" != "$expected" ]]; then
      record_failure "built-$info_key"
    fi
  done < <(
    jq -r '.permissions[] |
      select(.usageDescriptionKey != null) |
      [.usageDescriptionKey, .usageDescription] | @tsv' "$manifest_path"
  )

  if /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    signature_valid=true
  else
    record_failure "app-signature"
  fi
  if [[ -d "$xpc_path" ]] \
    && /usr/bin/codesign --verify --strict "$xpc_path" >/dev/null 2>&1
  then
    xpc_signature_valid=true
  else
    record_failure "xpc-signature"
  fi

  entitlements_dump="$(/usr/bin/codesign --display --entitlements :- "$app_path" 2>&1 || true)"
  while IFS= read -r required_entitlement; do
    (( checked_required_entitlements += 1 ))
    if [[ "$entitlements_dump" != *"<key>$required_entitlement</key>"* ]]; then
      record_failure "built-missing-entitlement:$required_entitlement"
    fi
  done < <(jq -r '.requiredEntitlements[]' "$manifest_path")
  while IFS= read -r forbidden_entitlement; do
    if [[ "$entitlements_dump" == *"<key>$forbidden_entitlement</key>"* ]]; then
      record_failure "built-forbidden-entitlement:$forbidden_entitlement"
    fi
  done < <(jq -r '.forbiddenEntitlements[]' "$manifest_path")
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-built-permissions.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT
jq -n \
  --arg status "$app_permission_status" \
  --arg failedCheck "$failed_check" \
  --arg appBundle "build-product://bestASR.app" \
  --arg bundleIdentifier "$bundle_identifier" \
  --argjson checkedUsageDescriptionCount "$checked_usage_keys" \
  --argjson checkedRequiredEntitlementCount "$checked_required_entitlements" \
  --argjson signatureValid "$signature_valid" \
  --argjson xpcSignatureValid "$xpc_signature_valid" \
  '{
    schemaVersion: 1,
    kind: "built-app-permission-summary",
    status: $status,
    failedCheck: $failedCheck,
    appBundle: $appBundle,
    bundleIdentifier: $bundleIdentifier,
    checkedUsageDescriptionCount: $checkedUsageDescriptionCount,
    checkedRequiredEntitlementCount: $checkedRequiredEntitlementCount,
    signatureValid: $signatureValid,
    xpcSignatureValid: $xpcSignatureValid,
    forbiddenEntitlementCount: 0
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

if [[ "$app_permission_status" != "pass" ]]; then
  print -u2 "built app permission verification failed: $failed_check"
  exit 1
fi

print "built app permissions passed: 2 usage descriptions, required entitlement, App/XPC signatures valid"
