#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
app_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app"
dmg_path="$BESTASR_RELEASE_ARTIFACT_ROOT/bestASR-0.1.0.dmg"
summary_path="$repository_root/artifacts/evidence/release/release-smoke-summary.json"
signing_enabled="${BESTASR_RELEASE_SIGNING_ENABLED:-0}"
developer_id_identity="${BESTASR_DEVELOPER_IDENTITY:-}"
notary_profile="${BESTASR_NOTARY_KEYCHAIN_PROFILE:-}"

while (( $# > 0 )); do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --dmg) dmg_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

release_smoke_status="pass"
release_status="blocked"
failed_check=""
hardened_runtime_status="not-run"
architecture_status="not-run"
minimum_os_status="not-run"
app_signature_status="not-run"
xpc_signature_status="not-run"
dmg_status="not-run"
developer_id_status="blocked"
notarization_status="blocked"
staple_status="blocked"
gatekeeper_status="blocked"
developer_id_identity_count=0
notarization_submission_id=""
dmg_digest=""
dmg_size=0
blockers=()

record_failure() {
  if [[ "$release_smoke_status" == "pass" ]]; then
    release_smoke_status="fail"
    release_status="fail"
    failed_check="$1"
  fi
}

for required_tool in codesign hdiutil lipo security shasum jq ditto; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required release tool missing: $required_tool"
    exit 2
  }
done

[[ -d "$app_path" ]] || {
  print -u2 "error: Release App missing: $app_path"
  exit 1
}

work_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-release-smoke.XXXXXX")"
staging_root="$work_root/staging"
staged_app="$staging_root/bestASR.app"
notary_result="$work_root/notary-result.json"
trap 'rm -rf "$work_root"' EXIT
mkdir -p "$staging_root" "$(dirname "$dmg_path")"
/usr/bin/ditto --rsrc --extattr --acl "$app_path" "$staged_app"

identity_output="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
developer_id_identity_count="$(print -r -- "$identity_output" | grep -c '"Developer ID Application:' || true)"

if [[ "$signing_enabled" == "1" ]]; then
  if [[ -z "$developer_id_identity" ]] \
    || [[ "$identity_output" != *"$developer_id_identity"* ]]
  then
    blockers+=("configured-developer-id-identity-unavailable")
  elif [[ -z "$notary_profile" ]]; then
    blockers+=("notary-keychain-profile-missing")
  else
    staged_xpc="$staged_app/Contents/XPCServices/InferenceWorker.xpc"
    /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$developer_id_identity" "$staged_xpc"
    /usr/bin/codesign --force --options runtime --timestamp \
      --entitlements "$repository_root/App/BestASR.entitlements" \
      --sign "$developer_id_identity" "$staged_app"
    developer_id_status="pass"
    release_status="running"
    "$repository_root/script/generate_supply_chain.sh" --package "$staged_app" >/dev/null
  fi
else
  if (( developer_id_identity_count == 0 )); then
    blockers+=("developer-id-application-identity-missing")
  else
    blockers+=("release-signing-opt-in-not-enabled")
  fi
  if [[ -z "$notary_profile" ]]; then
    blockers+=("notary-keychain-profile-missing")
  fi
fi

app_signature_details="$(/usr/bin/codesign -dv --verbose=4 "$staged_app" 2>&1 || true)"
xpc_path="$staged_app/Contents/XPCServices/InferenceWorker.xpc"
xpc_signature_details="$(/usr/bin/codesign -dv --verbose=4 "$xpc_path" 2>&1 || true)"
app_entitlements="$work_root/app-entitlements.plist"
xpc_entitlements="$work_root/xpc-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$staged_app" \
  > "$app_entitlements" 2>/dev/null || true
/usr/bin/codesign -d --entitlements :- "$xpc_path" \
  > "$xpc_entitlements" 2>/dev/null || true

if /usr/bin/codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
  app_signature_status="pass"
else
  app_signature_status="fail"
  record_failure "app-signature"
fi
if /usr/bin/codesign --verify --strict "$xpc_path" >/dev/null 2>&1; then
  xpc_signature_status="pass"
else
  xpc_signature_status="fail"
  record_failure "xpc-signature"
fi
if [[ "$app_signature_details" == *"runtime"* \
  && "$xpc_signature_details" == *"runtime"* \
  && "$(<"$app_entitlements")" != *"com.apple.security.get-task-allow"* \
  && "$(<"$xpc_entitlements")" != *"com.apple.security.get-task-allow"* ]]
then
  hardened_runtime_status="pass"
else
  hardened_runtime_status="fail"
  record_failure "hardened-runtime"
fi

app_architectures="$(/usr/bin/lipo -archs "$staged_app/Contents/MacOS/bestASR")"
xpc_architectures="$(/usr/bin/lipo -archs "$xpc_path/Contents/MacOS/InferenceWorker")"
if [[ "$app_architectures" == "arm64" && "$xpc_architectures" == "arm64" ]]; then
  architecture_status="pass"
else
  architecture_status="fail"
  record_failure "architecture"
fi

app_build_version="$(xcrun vtool -show-build "$staged_app/Contents/MacOS/bestASR" 2>/dev/null || true)"
xpc_build_version="$(xcrun vtool -show-build "$xpc_path/Contents/MacOS/InferenceWorker" 2>/dev/null || true)"
if [[ "$app_build_version" == *"minos 14.2"* \
  && "$xpc_build_version" == *"minos 14.2"* ]]
then
  minimum_os_status="pass"
else
  minimum_os_status="fail"
  record_failure "minimum-os"
fi

if [[ "$release_smoke_status" == "pass" ]]; then
  /usr/bin/hdiutil create \
    -ov \
    -fs HFS+ \
    -format UDZO \
    -volname bestASR \
    -srcfolder "$staging_root" \
    "$dmg_path" >/dev/null
  if /usr/bin/hdiutil verify "$dmg_path" >/dev/null; then
    dmg_status="pass"
    dmg_digest="$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print $1}')"
    dmg_size="$(/usr/bin/stat -f %z "$dmg_path")"
  else
    dmg_status="fail"
    record_failure "dmg-verification"
  fi
fi

if [[ "$release_smoke_status" == "pass" \
  && "$developer_id_status" == "pass" ]]
then
  /usr/bin/codesign --force --timestamp \
    --sign "$developer_id_identity" "$dmg_path"
  if xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$notary_profile" \
    --wait \
    --output-format json > "$notary_result"
  then
    notarization_submission_id="$(jq -r '.id // ""' "$notary_result")"
    if [[ "$(jq -r '.status // ""' "$notary_result")" == "Accepted" ]]; then
      notarization_status="pass"
      xcrun stapler staple "$dmg_path" >/dev/null
      xcrun stapler validate "$dmg_path" >/dev/null
      staple_status="pass"
      if /usr/sbin/spctl -a -t open \
        --context context:primary-signature -v "$dmg_path" >/dev/null 2>&1
      then
        gatekeeper_status="pass"
        release_status="pass"
      else
        gatekeeper_status="fail"
        record_failure "gatekeeper"
      fi
    else
      notarization_status="fail"
      record_failure "notarization"
    fi
  else
    notarization_status="fail"
    record_failure "notarization-submit"
  fi
fi

if [[ "$release_smoke_status" == "pass" \
  && "$release_status" != "pass" \
  && ${#blockers[@]} -eq 0 ]]
then
  blockers+=("developer-id-or-notarization-result-unavailable")
fi

blockers_json="$(printf '%s\n' "${blockers[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp="$work_root/release-smoke-summary.json"
jq -n \
  --arg status "$release_status" \
  --arg smokeStatus "$release_smoke_status" \
  --arg failedCheck "$failed_check" \
  --arg hardenedRuntime "$hardened_runtime_status" \
  --arg architecture "$architecture_status" \
  --arg minimumOS "$minimum_os_status" \
  --arg appSignature "$app_signature_status" \
  --arg xpcSignature "$xpc_signature_status" \
  --arg dmg "$dmg_status" \
  --arg developerID "$developer_id_status" \
  --arg notarization "$notarization_status" \
  --arg staple "$staple_status" \
  --arg gatekeeper "$gatekeeper_status" \
  --arg dmgSHA256 "$dmg_digest" \
  --arg notarizationSubmissionID "$notarization_submission_id" \
  --argjson dmgSizeBytes "$dmg_size" \
  --argjson developerIDIdentityCount "$developer_id_identity_count" \
  --argjson blockers "$blockers_json" \
  '{
    schemaVersion: 1,
    kind: "release-smoke-summary",
    status: $status,
    smokeStatus: $smokeStatus,
    releaseEligible: ($status == "pass"),
    failedCheck: $failedCheck,
    package: "build-product://bestASR.app",
    dmg: {
      path: "build-product://bestASR-0.1.0.dmg",
      sizeBytes: $dmgSizeBytes,
      sha256: $dmgSHA256
    },
    checks: {
      hardenedRuntime: $hardenedRuntime,
      architecture: $architecture,
      minimumOS: $minimumOS,
      appSignature: $appSignature,
      xpcSignature: $xpcSignature,
      dmg: $dmg,
      developerID: $developerID,
      notarization: $notarization,
      staple: $staple,
      gatekeeper: $gatekeeper
    },
    developerIDIdentityCount: $developerIDIdentityCount,
    notarizationSubmissionID: $notarizationSubmissionID,
    blockers: $blockers
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"

if [[ "$release_smoke_status" != "pass" ]]; then
  print -u2 "release smoke failed: $failed_check"
  exit 1
fi
if [[ "$release_status" == "blocked" ]]; then
  print "release smoke passed locally; Developer ID/notarization remains blocked"
else
  print "release smoke passed with Developer ID, notarization, staple, and Gatekeeper"
fi
