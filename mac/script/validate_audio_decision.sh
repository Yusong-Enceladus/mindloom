#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
adr_path="$repository_root/docs/architecture/decisions/ADR-0003-audio-journal-timebase.md"
technical_design_path="$repository_root/docs/architecture/TECHNICAL_DESIGN.md"
summary_path="$repository_root/artifacts/evidence/SPIKE-JRN-001/audio-decision-validation.json"

while (( $# > 0 )); do
  case "$1" in
    --adr) adr_path="$2"; shift 2 ;;
    --technical-design) technical_design_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

for required_tool in jq rg shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required audio decision tool missing: $required_tool"
    exit 2
  }
done

evidence_paths=(
  artifacts/evidence/SPIKE-CAP-001/summary.json
  artifacts/evidence/SPIKE-CAP-001/matrix.json
  artifacts/evidence/SPIKE-CAP-001/tcc-denial.json
  artifacts/evidence/SPIKE-TIM-001/summary.json
  artifacts/evidence/SPIKE-TIM-001/matrix.json
  artifacts/evidence/SPIKE-JRN-001/summary.json
  artifacts/evidence/SPIKE-JRN-001/matrix.json
  artifacts/evidence/SPIKE-JRN-001/long-recording.json
  artifacts/evidence/SPIKE-WRK-001/summary.json
  artifacts/evidence/SPIKE-WRK-001/matrix.json
)
validation_status="pass"
failure_category=""
decision_conclusion="pass"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-audio-decision.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
evidence_lines="$temporary_root/evidence.ndjson"

semantic_digest() {
  jq -cS '
    walk(
      if type == "object" then
        del(.runID, .generatedAt)
      else
        .
      end
    )
  ' "$1" | shasum -a 256 | awk '{print $1}'
}

write_summary() {
  local evidence_array summary_temp
  evidence_array="$temporary_root/evidence.json"
  summary_temp="$temporary_root/summary.json"
  if [[ -f "$evidence_lines" ]]; then
    jq -s '.' "$evidence_lines" > "$evidence_array"
  else
    print -r -- '[]' > "$evidence_array"
  fi
  mkdir -p "$(dirname "$summary_path")"
  jq -n \
    --arg status "$validation_status" \
    --arg failureCategory "$failure_category" \
    --arg decisionConclusion "$decision_conclusion" \
    --slurpfile evidence "$evidence_array" \
    '{
      schemaVersion: 1,
      kind: "audio-decision-validation",
      status: $status,
      failureCategory: $failureCategory,
      decisionConclusion: $decisionConclusion,
      dependentCommitmentAllowed: ($status == "pass" and $decisionConclusion == "pass"),
      evidence: $evidence[0]
    }' > "$summary_temp"
  mv "$summary_temp" "$summary_path"
}

fail_validation() {
  failure_category="$1"
  validation_status="fail"
  write_summary
  print -u2 "audio decision validation failed: $failure_category"
  exit 1
}

[[ -f "$adr_path" && -f "$technical_design_path" ]] \
  || fail_validation "decision-document-missing"

has_conditional=false
has_fail=false
for evidence_path in "${evidence_paths[@]}"; do
  absolute_path="$repository_root/$evidence_path"
  [[ -f "$absolute_path" ]] || fail_validation "required-evidence-missing"
  digest="$(semantic_digest "$absolute_path")"
  conclusion="$(jq -r '.conclusion // .status // "matrix"' "$absolute_path")"
  rg -Fq -- "$digest" "$adr_path" \
    || fail_validation "adr-evidence-digest-mismatch"
  if [[ "$conclusion" == "fail" ]]; then
    has_fail=true
  elif [[ "$conclusion" == "conditional" || "$conclusion" == "blocked" ]]; then
    has_conditional=true
  fi
  jq -cn \
    --arg path "$evidence_path" \
    --arg sha256 "$digest" \
    --arg conclusion "$conclusion" \
    '{path: $path, sha256: $sha256, conclusion: $conclusion}' >> "$evidence_lines"
done

if [[ "$has_fail" == "true" ]]; then
  decision_conclusion="fail"
elif [[ "$has_conditional" == "true" ]]; then
  decision_conclusion="conditional"
fi

rg -Fq -- "综合结论：\`$decision_conclusion\`" "$adr_path" \
  || fail_validation "adr-conclusion-mismatch"
if [[ "$decision_conclusion" != "pass" ]]; then
  rg -q '^- 状态：Proposed' "$adr_path" \
    || fail_validation "conditional-or-failed-adr-accepted"
fi
rg -Fq -- "捕获可行性 | $decision_conclusion" "$technical_design_path" \
  || fail_validation "technical-design-conclusion-mismatch"

write_summary
print "audio decision references passed; dependent conclusion is $decision_conclusion"
