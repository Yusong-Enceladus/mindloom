#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app"
manifest_path="$repository_root/artifacts/evidence/supply-chain/release-manifest.json"
sbom_path="$repository_root/artifacts/evidence/supply-chain/sbom.cdx.json"
dependencies_path="$repository_root/config/dependencies.json"
models_path="$repository_root/config/model-artifacts.json"
policy_path="$repository_root/config/release-package-policy.json"
notices_path="$repository_root/THIRD-PARTY-NOTICES.md"
summary_path="$repository_root/artifacts/evidence/supply-chain/release-package-validation-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --package) package_path="$2"; shift 2 ;;
    --manifest) manifest_path="$2"; shift 2 ;;
    --sbom) sbom_path="$2"; shift 2 ;;
    --dependencies) dependencies_path="$2"; shift 2 ;;
    --models) models_path="$2"; shift 2 ;;
    --policy) policy_path="$2"; shift 2 ;;
    --notices) notices_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

package_validation_status="pass"
failed_check=""
actual_file_count=0
registered_file_count=0

record_failure() {
  if [[ "$package_validation_status" == "pass" ]]; then
    package_validation_status="fail"
    failed_check="$1"
  fi
}

manifest_filter='def digest: type == "string" and test("^[0-9a-f]{64}$");
  .schemaVersion == 1 and
  .kind == "release-manifest" and
  (.packageIdentifier | type == "string" and length > 0) and
  (.packageVersion | type == "string" and length > 0) and
  .buildConfiguration == "Release" and
  .packageRoot == "build-product://bestASR.app" and
  (.dependencyManifestSHA256 | digest) and
  (.modelManifestSHA256 | digest) and
  (.noticeSHA256 | digest) and
  (.sbomSHA256 | digest) and
  (.files | type == "array" and length > 0) and
  .fileCount == (.files | length) and
  ([.files[].relativePath] | unique | length) == .fileCount and
  all(.files[];
    (.relativePath | type == "string" and length > 0 and
      startswith("/") == false and
      (split("/") | index("..")) == null) and
    (.kind == "resource" or .kind == "first-party-mach-o" or
      .kind == "dependency-mach-o" or .kind == "model-artifact") and
    (.sizeBytes | type == "number" and . >= 0) and
    (.sha256 | digest)
  )'

for required_file in \
  "$manifest_path" "$sbom_path" "$dependencies_path" \
  "$models_path" "$policy_path" "$notices_path"
do
  [[ -f "$required_file" ]] || record_failure "missing-input"
done
[[ -d "$package_path" ]] || record_failure "missing-package"

if [[ "$package_validation_status" == "pass" ]] \
  && ! jq -e "$manifest_filter" "$manifest_path" >/dev/null
then
  record_failure "release-manifest-schema"
fi

if [[ "$package_validation_status" == "pass" ]]; then
  registered_file_count="$(jq -r .fileCount "$manifest_path")"
  [[ "$(/usr/bin/shasum -a 256 "$dependencies_path" | /usr/bin/awk '{print $1}')" \
    == "$(jq -r .dependencyManifestSHA256 "$manifest_path")" ]] \
    || record_failure "dependency-manifest-digest"
  [[ "$(/usr/bin/shasum -a 256 "$models_path" | /usr/bin/awk '{print $1}')" \
    == "$(jq -r .modelManifestSHA256 "$manifest_path")" ]] \
    || record_failure "model-manifest-digest"
  [[ "$(/usr/bin/shasum -a 256 "$notices_path" | /usr/bin/awk '{print $1}')" \
    == "$(jq -r .noticeSHA256 "$manifest_path")" ]] \
    || record_failure "notice-digest"
  [[ "$(/usr/bin/shasum -a 256 "$sbom_path" | /usr/bin/awk '{print $1}')" \
    == "$(jq -r .sbomSHA256 "$manifest_path")" ]] \
    || record_failure "sbom-digest"
fi

if [[ "$package_validation_status" == "pass" ]]; then
  expected_component_count=$((
    $(jq '.dependencies | length' "$dependencies_path")
    + $(jq '.models | length' "$models_path")
  ))
  if ! jq -e --argjson expected "$expected_component_count" \
    '.bomFormat == "CycloneDX" and .specVersion == "1.6" and
      .version == 1 and (.components | length) == $expected' \
    "$sbom_path" >/dev/null
  then
    record_failure "sbom-components"
  fi
fi

if [[ "$package_validation_status" == "pass" ]] \
  && find "$package_path" -type l -print -quit | grep -q .
then
  record_failure "package-symlink"
fi

is_model_path() {
  local lower_path="${1:l}"
  local extension
  while IFS= read -r extension; do
    if [[ "$lower_path" == *."$extension" || "$lower_path" == *."$extension"/* ]]; then
      return 0
    fi
  done < <(jq -r '.modelFileExtensions[]' "$policy_path")
  return 1
}

classify_file() {
  local file_path="$1"
  local relative_path="$2"
  local file_description
  file_description="$(/usr/bin/file -b "$file_path")"
  if [[ "$file_description" == Mach-O* ]]; then
    if jq -e --arg path "$relative_path" \
      '.firstPartyMachOPaths | index($path) != null' "$policy_path" >/dev/null
    then
      print "first-party-mach-o"
    elif jq -e --arg path "$relative_path" \
      '[.dependencies[] | select(.shipped) | .packagePaths[]] |
        index($path) != null' "$dependencies_path" >/dev/null
    then
      print "dependency-mach-o"
    else
      print "unapproved-mach-o"
    fi
  elif is_model_path "$relative_path"; then
    print "model-artifact"
  else
    print "resource"
  fi
}

if [[ "$package_validation_status" == "pass" ]]; then
  while IFS= read -r packaged_file; do
    (( actual_file_count += 1 ))
    relative_path="${packaged_file#$package_path/}"
    manifest_entry="$(jq -c --arg path "$relative_path" \
      '.files[] | select(.relativePath == $path)' "$manifest_path")"
    if [[ -z "$manifest_entry" ]]; then
      record_failure "unregistered-file:$relative_path"
      continue
    fi
    actual_kind="$(classify_file "$packaged_file" "$relative_path")"
    if [[ "$actual_kind" == "unapproved-mach-o" ]]; then
      record_failure "unregistered-binary:$relative_path"
      continue
    fi
    actual_size="$(/usr/bin/stat -f %z "$packaged_file")"
    actual_digest="$(/usr/bin/shasum -a 256 "$packaged_file" | /usr/bin/awk '{print $1}')"
    if [[ "$actual_kind" != "$(jq -r .kind <<< "$manifest_entry")" \
      || "$actual_size" != "$(jq -r .sizeBytes <<< "$manifest_entry")" \
      || "$actual_digest" != "$(jq -r .sha256 <<< "$manifest_entry")" ]]
    then
      record_failure "file-digest-or-kind:$relative_path"
    fi
    if [[ "$actual_kind" == "model-artifact" ]]; then
      if ! jq -e \
        --arg path "$relative_path" \
        --arg digest "$actual_digest" \
        --argjson size "$actual_size" \
        '[.models[].files[] |
          select(.packagePath == $path and .sha256 == $digest and .sizeBytes == $size)] |
          length == 1' "$models_path" >/dev/null
      then
        record_failure "unregistered-model:$relative_path"
      fi
    fi
  done < <(find "$package_path" -type f -print | LC_ALL=C sort)

  if (( actual_file_count != registered_file_count )); then
    record_failure "package-file-count"
  fi
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-release-validation.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT
jq -n \
  --arg status "$package_validation_status" \
  --arg failedCheck "$failed_check" \
  --arg packageRoot "build-product://bestASR.app" \
  --argjson actualFileCount "$actual_file_count" \
  --argjson registeredFileCount "$registered_file_count" \
  '{
    schemaVersion: 1,
    kind: "release-package-validation-summary",
    status: $status,
    failedCheck: $failedCheck,
    packageRoot: $packageRoot,
    actualFileCount: $actualFileCount,
    registeredFileCount: $registeredFileCount,
    sbomValidated: ($status == "pass"),
    noticeValidated: ($status == "pass"),
    unregisteredBinaryOrModelCount: (if $status == "pass" then 0 else 1 end)
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

if [[ "$package_validation_status" != "pass" ]]; then
  print -u2 "release package validation failed: $failed_check"
  exit 1
fi

print "release package passed: $actual_file_count registered files"
