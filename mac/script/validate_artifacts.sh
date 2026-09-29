#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
dependencies_path="$repository_root/config/dependencies.json"
models_path="$repository_root/config/model-artifacts.json"
summary_path="$repository_root/artifacts/evidence/supply-chain/artifact-validation-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --dependencies)
      dependencies_path="$2"
      shift 2
      ;;
    --models)
      models_path="$2"
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

for required_tool in jq shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required validation tool missing: $required_tool"
    exit 2
  }
done

validation_filter='def nonempty: type == "string" and length > 0;
  def digest: type == "string" and test("^[0-9a-f]{64}$");
  def revision: type == "string" and test("^[0-9a-f]{40}$");
  .schemaVersion == 1 and
  (.dependencies | type == "array") and
  all(.dependencies[];
    (.id | nonempty) and
    (.exactVersion | nonempty) and
    (.source | nonempty) and
    (.license | nonempty) and
    (.requiredAttribution | nonempty) and
    (.noticeHeading | nonempty) and
    (.minimumOS | nonempty) and
    (.hardware | nonempty) and
    (.sizeBytes | type == "number" and . >= 0) and
    (.sha256 | digest) and
    (.networkBehavior | nonempty) and
    (.runtimeBehavior | nonempty) and
    (.distributionImpact | nonempty) and
    (.packagePaths | type == "array") and
    (if .shipped then (.packagePaths | length > 0) else (.packagePaths | length == 0) end) and
    (.shipped | type == "boolean") and
    (if (.productionCandidate // false) then
      (.sourceRevision | revision) and
      (.licenseSource | nonempty) and
      (.licenseFile | nonempty) and
      (.licenseSHA256 | digest)
    else true end)
  )'

model_filter='def nonempty: type == "string" and length > 0;
  def digest: type == "string" and test("^[0-9a-f]{64}$");
  def revision: type == "string" and test("^[0-9a-f]{40}$");
  def safe_relative_path:
    type == "string" and length > 0 and
    (startswith("/") | not) and
    (test("(^|/)\\.\\.(/|$)") | not);
  .schemaVersion == 1 and
  (.models | type == "array") and
  (.selectionStatus | nonempty) and
  all(.models[];
    (.id | nonempty) and
    (.exactVersion | nonempty) and
    (.activationSequence | type == "number" and . > 0 and floor == .) and
    (.source | nonempty) and
    (.sourceRevision | revision) and
    (.treeSHA256 | digest) and
    (.treeDigestAlgorithm == "sha256-shasum-path-list-v1") and
    (.license | nonempty) and
    (.licenseSource | nonempty) and
    (.licenseRevision | revision) and
    (.licenseFile | safe_relative_path) and
    (.licenseSHA256 | digest) and
    (.requiredAttribution | nonempty) and
    (.minimumOS | nonempty) and
    (.hardware | nonempty) and
    (.totalSizeBytes | type == "number" and . > 0) and
    (.networkBehavior | nonempty) and
    (.runtimeBehavior | nonempty) and
    (.distributionImpact | nonempty) and
    (.files | type == "array" and length > 0) and
    (([.files[].relativePath] | unique | length) == (.files | length)) and
    (([.files[].packagePath] | unique | length) == (.files | length)) and
    (([.files[].sizeBytes] | add) == .totalSizeBytes) and
    all(.files[];
      (.relativePath | safe_relative_path) and
      (.packagePath | safe_relative_path and startswith("Contents/")) and
      (.sizeBytes | type == "number" and . > 0) and
      (.sha256 | digest)
    )
  )'

license_snapshots_valid() {
  local manifest_path="$1"
  local records_filter="$2"
  local relative_path
  local expected_digest
  local actual_digest

  while IFS=$'\t' read -r relative_path expected_digest; do
    [[ -n "$relative_path" && "$relative_path" == Legal/* ]] || return 1
    [[ -f "$repository_root/$relative_path" ]] || return 1
    actual_digest="$(shasum -a 256 "$repository_root/$relative_path" | awk '{print $1}')"
    [[ "$actual_digest" == "$expected_digest" ]] || return 1
  done < <(jq -r "$records_filter | @tsv" "$manifest_path")
}

model_tree_digests_valid() {
  local manifest_path="$1"
  local artifact_id
  local expected_digest
  local actual_digest

  while IFS=$'\t' read -r artifact_id expected_digest; do
    actual_digest="$(
      jq -r --arg id "$artifact_id" '
        .models[] | select(.id == $id) |
        .files | sort_by(.relativePath)[] |
        "\(.sha256)  ./\(.relativePath)"
      ' "$manifest_path" | shasum -a 256 | awk '{print $1}'
    )"
    [[ "$actual_digest" == "$expected_digest" ]] || return 1
  done < <(jq -r '.models[] | [.id, .treeSHA256] | @tsv' "$manifest_path")
}

validation_status="pass"
failed_manifest=""
if ! jq -e "$validation_filter" "$dependencies_path" >/dev/null; then
  validation_status="fail"
  failed_manifest="dependencies"
elif ! jq -e "$model_filter" "$models_path" >/dev/null; then
  validation_status="fail"
  failed_manifest="models"
elif ! model_tree_digests_valid "$models_path"; then
  validation_status="fail"
  failed_manifest="model-tree-digest"
elif ! license_snapshots_valid "$dependencies_path" \
  '.dependencies[] | select(.productionCandidate // false) | [.licenseFile, .licenseSHA256]'
then
  validation_status="fail"
  failed_manifest="dependency-license-snapshot"
elif ! license_snapshots_valid "$models_path" \
  '.models[] | [.licenseFile, .licenseSHA256]'
then
  validation_status="fail"
  failed_manifest="model-license-snapshot"
elif [[ ! -s "$repository_root/THIRD-PARTY-NOTICES.md" ]]; then
  validation_status="fail"
  failed_manifest="notices"
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-artifact-validation.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT

jq -n \
  --arg status "$validation_status" \
  --arg failedManifest "$failed_manifest" \
  --arg dependencies "$(basename "$dependencies_path")" \
  --arg models "$(basename "$models_path")" \
  '{
    schemaVersion: 1,
    status: $status,
    failedManifest: $failedManifest,
    dependenciesManifest: $dependencies,
    modelManifest: $models
  }' > "$summary_temp"

mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

if [[ "$validation_status" != "pass" ]]; then
  print -u2 "artifact validation failed: $failed_manifest"
  exit 1
fi

print "artifact manifests passed"
