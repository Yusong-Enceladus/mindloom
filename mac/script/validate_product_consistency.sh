#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
contract_path="$repository_root/config/product-consistency.json"
summary_path="$repository_root/artifacts/evidence/traceability/consistency-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --contract)
      contract_path="$2"
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
    print -u2 "error: required consistency tool missing: $required_tool"
    exit 2
  }
done

validation_status="pass"
failure_category=""

write_summary() {
  local directory temporary_root temporary_summary digest invariant_count assertion_count
  directory="$(dirname "$summary_path")"
  mkdir -p "$directory"
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-consistency.XXXXXX")"
  temporary_summary="$temporary_root/summary.json"
  digest=""
  invariant_count=0
  assertion_count=0
  if [[ -f "$contract_path" ]]; then
    digest="$(shasum -a 256 "$contract_path" | awk '{print $1}')"
    invariant_count="$(jq -r '.invariants | length // 0' "$contract_path" 2>/dev/null || print 0)"
    assertion_count="$(jq -r '[.invariants[].sources[]] | length // 0' "$contract_path" 2>/dev/null || print 0)"
  fi
  jq -n \
    --arg status "$validation_status" \
    --arg failureCategory "$failure_category" \
    --arg contractSHA256 "$digest" \
    --argjson invariantCount "$invariant_count" \
    --argjson sourceAssertionCount "$assertion_count" \
    '{
      schemaVersion: 1,
      kind: "product-consistency-summary",
      status: $status,
      failureCategory: $failureCategory,
      contractSHA256: $contractSHA256,
      invariantCount: $invariantCount,
      sourceAssertionCount: $sourceAssertionCount
    }' > "$temporary_summary"
  mv "$temporary_summary" "$summary_path"
  rmdir "$temporary_root"
}

fail_validation() {
  failure_category="$1"
  validation_status="fail"
  write_summary
  print -u2 "product consistency validation failed: $failure_category"
  exit 1
}

[[ -f "$contract_path" ]] || fail_validation "contract-missing"

structure_filter='def nonempty_unique:
    type == "array" and length > 0 and length == (unique | length) and
    all(.[]; type == "string" and length > 0);
  .schemaVersion == 1 and
  .kind == "product-consistency-contract" and
  (.invariants | type == "array" and length > 0) and
  ([.invariants[].id] | length == (unique | length)) and
  all(.invariants[];
    (.id | type == "string" and test("^[a-z0-9-]+$")) and
    (.description | type == "string" and length > 0) and
    (.sources | type == "array" and length > 0) and
    all(.sources[];
      (.path | type == "string" and test("^(PRODUCT_REQUIREMENTS.md|IMPLEMENTATION_STATUS.md|Packages/|Tests/|docs/|config/)[A-Za-z0-9._/-]*$")) and
      (.requiredLiterals | nonempty_unique) and
      (.forbiddenLiterals | type == "array" and length == (unique | length) and
        all(.[]; type == "string" and length > 0))
    )
  )'
jq -e "$structure_filter" "$contract_path" >/dev/null \
  || fail_validation "invalid-contract-structure"

invariant_count="$(jq -r '.invariants | length' "$contract_path")"
for (( invariant_index = 0; invariant_index < invariant_count; invariant_index++ )); do
  source_count="$(jq -r ".invariants[$invariant_index].sources | length" "$contract_path")"
  for (( source_index = 0; source_index < source_count; source_index++ )); do
    source_path="$(jq -r ".invariants[$invariant_index].sources[$source_index].path" "$contract_path")"
    [[ "/$source_path/" != *"/../"* && "/$source_path/" != *"/./"* ]] \
      || fail_validation "unsafe-source-path"
    [[ -f "$repository_root/$source_path" ]] \
      || fail_validation "stale-source-path"

    while IFS= read -r required_literal; do
      rg -Fq -- "$required_literal" "$repository_root/$source_path" \
        || fail_validation "required-constraint-missing"
    done < <(
      jq -r ".invariants[$invariant_index].sources[$source_index].requiredLiterals[]" \
        "$contract_path"
    )

    while IFS= read -r forbidden_literal; do
      if rg -Fq -- "$forbidden_literal" "$repository_root/$source_path"; then
        fail_validation "planted-or-live-constraint-conflict"
      fi
    done < <(
      jq -r ".invariants[$invariant_index].sources[$source_index].forbiddenLiterals[]" \
        "$contract_path"
    )
  done
done

write_summary
print "product consistency passed: $invariant_count invariants"
