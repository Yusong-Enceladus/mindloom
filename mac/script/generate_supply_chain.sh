#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app"
dependencies_path="$repository_root/config/dependencies.json"
models_path="$repository_root/config/model-artifacts.json"
policy_path="$repository_root/config/release-package-policy.json"
notices_path="$repository_root/THIRD-PARTY-NOTICES.md"
sbom_path="$repository_root/artifacts/evidence/supply-chain/sbom.cdx.json"
manifest_path="$repository_root/artifacts/evidence/supply-chain/release-manifest.json"
validation_summary_path="$repository_root/artifacts/evidence/supply-chain/release-package-validation-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --package)
      package_path="$2"
      shift 2
      ;;
    --dependencies)
      dependencies_path="$2"
      shift 2
      ;;
    --models)
      models_path="$2"
      shift 2
      ;;
    --policy)
      policy_path="$2"
      shift 2
      ;;
    --notices)
      notices_path="$2"
      shift 2
      ;;
    --sbom)
      sbom_path="$2"
      shift 2
      ;;
    --manifest)
      manifest_path="$2"
      shift 2
      ;;
    --validation-summary)
      validation_summary_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

for required_tool in jq shasum stat file; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required supply-chain tool missing: $required_tool"
    exit 2
  }
done

for required_path in \
  "$package_path" \
  "$dependencies_path" \
  "$models_path" \
  "$policy_path" \
  "$notices_path"
do
  [[ -e "$required_path" ]] || {
    print -u2 "error: missing supply-chain input: $required_path"
    exit 1
  }
done

work_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-supply-chain.XXXXXX")"
file_records="$work_root/files.jsonl"
artifact_summary="$work_root/artifact-summary.json"
trap 'rm -f "$work_root"/*; rmdir "$work_root" 2>/dev/null || true' EXIT

"$repository_root/script/validate_artifacts.sh" \
  --dependencies "$dependencies_path" \
  --models "$models_path" \
  --summary "$artifact_summary" >/dev/null

policy_filter='.schemaVersion == 1 and
  (.packageIdentifier | type == "string" and length > 0) and
  (.packageVersion | type == "string" and length > 0) and
  .buildConfiguration == "Release" and
  .allowSymlinks == false and
  (.firstPartyMachOPaths | type == "array" and length > 0 and unique == .) and
  (.modelFileExtensions | type == "array" and length > 0 and unique == .)'
if ! jq -e "$policy_filter" "$policy_path" >/dev/null; then
  print -u2 "error: invalid release package policy"
  exit 1
fi

while IFS= read -r notice_heading; do
  if ! grep -Fq "## $notice_heading" "$notices_path"; then
    print -u2 "error: dependency notice missing: $notice_heading"
    exit 1
  fi
done < <(jq -r '.dependencies[].noticeHeading' "$dependencies_path")

if find "$package_path" -type l -print -quit | grep -q .; then
  print -u2 "error: release package contains a symlink but policy forbids symlinks"
  exit 1
fi

info_plist="$package_path/Contents/Info.plist"
package_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
package_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
if [[ "$package_identifier" != "$(jq -r .packageIdentifier "$policy_path")" \
  || "$package_version" != "$(jq -r .packageVersion "$policy_path")" ]]
then
  print -u2 "error: release package identity/version does not match policy"
  exit 1
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
      return 0
    fi
    if jq -e --arg path "$relative_path" \
      '[.dependencies[] | select(.shipped) | .packagePaths[]] |
        index($path) != null' "$dependencies_path" >/dev/null
    then
      print "dependency-mach-o"
      return 0
    fi
    print -u2 "error: unregistered Mach-O in release package: $relative_path"
    return 1
  fi
  if is_model_path "$relative_path"; then
    if ! jq -e --arg path "$relative_path" \
      '[.models[].files[] | select(.packagePath == $path)] | length == 1' \
      "$models_path" >/dev/null
    then
      print -u2 "error: unregistered model in release package: $relative_path"
      return 1
    fi
    print "model-artifact"
    return 0
  fi
  print "resource"
}

: > "$file_records"
while IFS= read -r packaged_file; do
  relative_path="${packaged_file#$package_path/}"
  file_kind="$(classify_file "$packaged_file" "$relative_path")"
  file_size="$(/usr/bin/stat -f %z "$packaged_file")"
  file_digest="$(/usr/bin/shasum -a 256 "$packaged_file" | /usr/bin/awk '{print $1}')"

  if [[ "$file_kind" == "model-artifact" ]]; then
    expected_size="$(jq -r --arg path "$relative_path" \
      '.models[].files[] | select(.packagePath == $path) | .sizeBytes' \
      "$models_path")"
    expected_digest="$(jq -r --arg path "$relative_path" \
      '.models[].files[] | select(.packagePath == $path) | .sha256' \
      "$models_path")"
    if [[ "$file_size" != "$expected_size" || "$file_digest" != "$expected_digest" ]]; then
      print -u2 "error: packaged model digest/size mismatch: $relative_path"
      exit 1
    fi
  fi

  jq -n \
    --arg relativePath "$relative_path" \
    --arg kind "$file_kind" \
    --arg sha256 "$file_digest" \
    --argjson sizeBytes "$file_size" \
    '{relativePath: $relativePath, kind: $kind, sizeBytes: $sizeBytes, sha256: $sha256}' \
    >> "$file_records"
done < <(find "$package_path" -type f -print | LC_ALL=C sort)

dependency_manifest_digest="$(/usr/bin/shasum -a 256 "$dependencies_path" | /usr/bin/awk '{print $1}')"
model_manifest_digest="$(/usr/bin/shasum -a 256 "$models_path" | /usr/bin/awk '{print $1}')"
notice_digest="$(/usr/bin/shasum -a 256 "$notices_path" | /usr/bin/awk '{print $1}')"

mkdir -p "$(dirname "$sbom_path")" "$(dirname "$manifest_path")"
jq -S -n \
  --slurpfile dependencies "$dependencies_path" \
  --slurpfile models "$models_path" \
  --arg packageVersion "$package_version" \
  --arg selectionStatus "$(jq -r .selectionStatus "$models_path")" \
  '{
    bomFormat: "CycloneDX",
    specVersion: "1.6",
    version: 1,
    metadata: {
      component: {
        type: "application",
        name: "bestASR",
        version: $packageVersion,
        "bom-ref": ("application:bestASR@" + $packageVersion)
      },
      properties: [
        {name: "bestasr:model-selection-status", value: $selectionStatus},
        {name: "bestasr:runtime-network-default", value: "offline"}
      ]
    },
    components: (
      [
        $dependencies[0].dependencies[] | {
          type: (if .id == "xcodegen" then "application" else "library" end),
          name: .id,
          version: .exactVersion,
          "bom-ref": ("dependency:" + .id + "@" + .exactVersion),
          hashes: [{alg: "SHA-256", content: .sha256}],
          licenses: [{license: {name: .license}}],
          externalReferences: [{type: "distribution", url: .source}],
          properties: [
            {name: "bestasr:required-attribution", value: .requiredAttribution},
            {name: "bestasr:network-behavior", value: .networkBehavior},
            {name: "bestasr:runtime-behavior", value: .runtimeBehavior},
            {name: "bestasr:distribution-impact", value: .distributionImpact},
            {name: "bestasr:shipped", value: (.shipped | tostring)}
          ]
        }
      ] + [
        $models[0].models[] | {
          type: "machine-learning-model",
          name: .id,
          version: .exactVersion,
          "bom-ref": ("model:" + .id + "@" + .exactVersion),
          hashes: [.files[] | {alg: "SHA-256", content: .sha256}],
          licenses: [{license: {name: .license}}],
          externalReferences: [{type: "distribution", url: .source}],
          properties: [
            {name: "bestasr:required-attribution", value: .requiredAttribution},
            {name: "bestasr:network-behavior", value: .networkBehavior},
            {name: "bestasr:runtime-behavior", value: .runtimeBehavior},
            {name: "bestasr:distribution-impact", value: .distributionImpact}
          ]
        }
      ]
    )
  }' > "$sbom_path"

sbom_digest="$(/usr/bin/shasum -a 256 "$sbom_path" | /usr/bin/awk '{print $1}')"
jq -S -s \
  --arg packageIdentifier "$package_identifier" \
  --arg packageVersion "$package_version" \
  --arg dependencyManifestSHA256 "$dependency_manifest_digest" \
  --arg modelManifestSHA256 "$model_manifest_digest" \
  --arg noticeSHA256 "$notice_digest" \
  --arg sbomSHA256 "$sbom_digest" \
  '{
    schemaVersion: 1,
    kind: "release-manifest",
    packageIdentifier: $packageIdentifier,
    packageVersion: $packageVersion,
    buildConfiguration: "Release",
    packageRoot: "build-product://bestASR.app",
    dependencyManifestSHA256: $dependencyManifestSHA256,
    modelManifestSHA256: $modelManifestSHA256,
    noticeSHA256: $noticeSHA256,
    sbomPath: "artifacts/evidence/supply-chain/sbom.cdx.json",
    sbomSHA256: $sbomSHA256,
    fileCount: length,
    files: sort_by(.relativePath)
  }' "$file_records" > "$manifest_path"

"$repository_root/script/validate_release_package.sh" \
  --package "$package_path" \
  --manifest "$manifest_path" \
  --sbom "$sbom_path" \
  --dependencies "$dependencies_path" \
  --models "$models_path" \
  --policy "$policy_path" \
  --notices "$notices_path" \
  --summary "$validation_summary_path"

print "supply chain generated: SBOM plus $(jq -r .fileCount "$manifest_path") release files"
