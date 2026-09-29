#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest_path="$repository_root/config/traceability.json"
summary_path="$repository_root/artifacts/evidence/traceability/validation-summary.json"

while (( $# > 0 )); do
  case "$1" in
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

for required_tool in jq rg shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required traceability tool missing: $required_tool"
    exit 2
  }
done

validation_status="pass"
failure_category=""

write_summary() {
  local summary_directory summary_temp_directory summary_temp digest entry_count
  summary_directory="$(dirname "$summary_path")"
  mkdir -p "$summary_directory"
  summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-trace-summary.XXXXXX")"
  summary_temp="$summary_temp_directory/summary.json"
  digest=""
  entry_count=0
  if [[ -f "$manifest_path" ]]; then
    digest="$(shasum -a 256 "$manifest_path" | awk '{print $1}')"
    entry_count="$(jq -r '.entries | length // 0' "$manifest_path" 2>/dev/null || print 0)"
  fi
  jq -n \
    --arg status "$validation_status" \
    --arg failureCategory "$failure_category" \
    --arg manifestSHA256 "$digest" \
    --argjson entryCount "$entry_count" \
    '{
      schemaVersion: 1,
      kind: "traceability-validation-summary",
      status: $status,
      failureCategory: $failureCategory,
      manifestSHA256: $manifestSHA256,
      entryCount: $entryCount
    }' > "$summary_temp"
  mv "$summary_temp" "$summary_path"
  rmdir "$summary_temp_directory"
}

fail_validation() {
  failure_category="$1"
  validation_status="fail"
  write_summary
  print -u2 "traceability validation failed: $failure_category"
  exit 1
}

[[ -f "$manifest_path" ]] || fail_validation "manifest-missing"

structure_filter='def unique_array:
    type == "array" and length > 0 and length == (unique | length);
  .schemaVersion == 1 and
  .kind == "traceability" and
  (.manifestID | type == "string" and length > 0) and
  (.entries | type == "array" and length > 0) and
  all(.entries[];
    (.requirementIDs | unique_array) and
    (.threatIDs | unique_array) and
    (.scenarioIDs | unique_array) and
    (.tests | unique_array) and
    (.evidence | unique_array) and
    all(.requirementIDs[]; test("^[A-Z][A-Z0-9]*-[0-9]{3}$")) and
    all(.threatIDs[]; test("^TM-[0-9]{2}$")) and
    all(.scenarioIDs[]; type == "string" and length > 0) and
    all(.tests[]; test("^(Packages|Tests|Spikes|script)/[A-Za-z0-9._/-]+$")) and
    all(.evidence[]; test("^(artifacts/evidence/|fixture://Tests/Fixtures/)[A-Za-z0-9._/-]+$"))
  )'
jq -e "$structure_filter" "$manifest_path" >/dev/null \
  || fail_validation "invalid-structure-or-missing-evidence"

while IFS= read -r requirement_id; do
  rg -Fq "**${requirement_id} " "$repository_root/PRODUCT_REQUIREMENTS.md" \
    || fail_validation "orphan-requirement-id"
done < <(jq -r '.entries[].requirementIDs[]' "$manifest_path" | sort -u)

while IFS= read -r threat_id; do
  rg -Fq "| ${threat_id} |" "$repository_root/docs/security/THREAT_MODEL.md" \
    || fail_validation "orphan-threat-id"
done < <(jq -r '.entries[].threatIDs[]' "$manifest_path" | sort -u)

while IFS= read -r test_path; do
  [[ "/$test_path/" != *"/../"* && "/$test_path/" != *"/./"* ]] \
    || fail_validation "unsafe-test-path"
  [[ -f "$repository_root/$test_path" ]] \
    || fail_validation "stale-test-path"
done < <(jq -r '.entries[].tests[]' "$manifest_path" | sort -u)

while IFS= read -r evidence_reference; do
  if [[ "$evidence_reference" == fixture://* ]]; then
    evidence_path="${evidence_reference#fixture://}"
  else
    evidence_path="$evidence_reference"
  fi
  [[ "/$evidence_path/" != *"/../"* && "/$evidence_path/" != *"/./"* ]] \
    || fail_validation "unsafe-evidence-path"
  [[ -f "$repository_root/$evidence_path" ]] \
    || fail_validation "missing-evidence-path"
done < <(jq -r '.entries[].evidence[]' "$manifest_path" | sort -u)

write_summary
print "traceability validation passed: $(jq -r '.entries | length' "$manifest_path") entries"
