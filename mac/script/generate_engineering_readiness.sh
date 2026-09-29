#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
gates_path="$repository_root/config/readiness-gates.json"
tasks_path="$repository_root/IMPLEMENTATION_STATUS.md"
json_path="$repository_root/artifacts/evidence/readiness/engineering-readiness-report.json"
markdown_path="$repository_root/artifacts/evidence/readiness/engineering-readiness-report.md"

while (( $# > 0 )); do
  case "$1" in
    --gates)
      gates_path="$2"
      shift 2
      ;;
    --tasks)
      tasks_path="$2"
      shift 2
      ;;
    --json)
      json_path="$2"
      shift 2
      ;;
    --markdown)
      markdown_path="$2"
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
    print -u2 "error: required readiness tool missing: $required_tool"
    exit 2
  }
done

jq -e '
  .schemaVersion == 1 and
  .kind == "engineering-readiness-gates" and
  (.gates | type == "array" and length > 0) and
  ([.gates[].id] | length == (unique | length)) and
  all(.gates[];
    (.id | type == "string" and test("^[a-z0-9-]+$")) and
    (.evidencePath | type == "string" and test("^(artifacts/evidence/|config/|Tests/Fixtures/)[A-Za-z0-9._/-]+$")) and
    (.field | type == "string" and test("^[A-Za-z0-9.]+$")) and
    (.expectedValue != null) and
    (.unmetStatus == "fail" or .unmetStatus == "conditional") and
    (.taskRefs | type == "array" and length > 0) and
    (.blocker | type == "string" and length > 0)
  )' "$gates_path" >/dev/null || {
    print -u2 "error: invalid readiness gate configuration"
    exit 1
  }

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-readiness.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
gate_lines="$temporary_root/gates.ndjson"
gate_array="$temporary_root/gates.json"
pending_lines="$temporary_root/pending.txt"
completed_lines="$temporary_root/completed.txt"
pending_json="$temporary_root/pending.json"
completed_json="$temporary_root/completed.json"
report_temp="$temporary_root/report.json"
markdown_temp="$temporary_root/report.md"

gate_count="$(jq -r '.gates | length' "$gates_path")"
for (( gate_index = 0; gate_index < gate_count; gate_index++ )); do
  gate="$(jq -c ".gates[$gate_index]" "$gates_path")"
  evidence_path="$(jq -r '.evidencePath' <<< "$gate")"
  [[ "/$evidence_path/" != *"/../"* && "/$evidence_path/" != *"/./"* ]] || {
    print -u2 "error: unsafe readiness evidence path"
    exit 1
  }
  field="$(jq -r '.field' <<< "$gate")"
  expected="$(jq -c '.expectedValue' <<< "$gate")"
  unmet_status="$(jq -r '.unmetStatus' <<< "$gate")"
  observed="null"
  evidence_sha256=""
  gate_status="$unmet_status"

  if [[ -f "$repository_root/$evidence_path" ]]; then
    evidence_sha256="$(shasum -a 256 "$repository_root/$evidence_path" | awk '{print $1}')"
    observed="$(
      jq -c --arg field "$field" 'try getpath($field | split(".")) catch null' \
        "$repository_root/$evidence_path" 2>/dev/null || print null
    )"
    if jq -ne --argjson observed "$observed" --argjson expected "$expected" \
      '$observed == $expected' >/dev/null; then
      gate_status="pass"
    fi
  fi

  jq -cn \
    --argjson gate "$gate" \
    --arg status "$gate_status" \
    --argjson observedValue "$observed" \
    --arg evidenceSHA256 "$evidence_sha256" \
    '$gate + {
      status: $status,
      observedValue: $observedValue,
      evidenceSHA256: $evidenceSHA256
    }' >> "$gate_lines"
done
jq -s '.' "$gate_lines" > "$gate_array"

rg '^- \[ \] ' "$tasks_path" | sed -E 's/^- \[ \] //' > "$pending_lines" || true
rg '^- \[x\] ' "$tasks_path" | sed -E 's/^- \[x\] //' > "$completed_lines" || true
jq -R -s 'split("\n") | map(select(length > 0))' "$pending_lines" > "$pending_json"
jq -R -s 'split("\n") | map(select(length > 0))' "$completed_lines" > "$completed_json"

fail_count="$(jq '[.[] | select(.status == "fail")] | length' "$gate_array")"
conditional_count="$(jq '[.[] | select(.status == "conditional")] | length' "$gate_array")"
pass_count="$(jq '[.[] | select(.status == "pass")] | length' "$gate_array")"
pending_count="$(jq 'length' "$pending_json")"
if (( fail_count > 0 )); then
  conclusion="fail"
elif (( conditional_count > 0 || pending_count > 0 )); then
  conclusion="conditional"
else
  conclusion="pass"
fi

jq -n \
  --arg conclusion "$conclusion" \
  --arg gatesSHA256 "$(shasum -a 256 "$gates_path" | awk '{print $1}')" \
  --arg tasksSHA256 "$(shasum -a 256 "$tasks_path" | awk '{print $1}')" \
  --argjson passCount "$pass_count" \
  --argjson failCount "$fail_count" \
  --argjson conditionalCount "$conditional_count" \
  --slurpfile gates "$gate_array" \
  --slurpfile pending "$pending_json" \
  --slurpfile completed "$completed_json" \
  '{
    schemaVersion: 1,
    kind: "engineering-readiness-report",
    conclusion: $conclusion,
    verified: ($conclusion == "pass" and ($pending[0] | length) == 0),
    releaseEligible: ($conclusion == "pass" and ($pending[0] | length) == 0),
    deliveryStatus: (if $conclusion == "pass" and ($pending[0] | length) == 0 then "ready" else "incomplete" end),
    gatesSHA256: $gatesSHA256,
    tasksSHA256: $tasksSHA256,
    gateCounts: {
      pass: $passCount,
      fail: $failCount,
      conditional: $conditionalCount
    },
    completedTaskCount: ($completed[0] | length),
    pendingTaskCount: ($pending[0] | length),
    gates: $gates[0],
    pendingTasks: $pending[0],
    unresolvedDependencies: (
      ([ $gates[0][] | select(.status != "pass") | .blocker ] + $pending[0])
      | unique
    )
  }' > "$report_temp"

{
  print -r -- "# bestASR engineering readiness"
  print -r -- ""
  print -r -- "- Conclusion: **$(jq -r '.conclusion' "$report_temp")**"
  print -r -- "- Delivery status: **$(jq -r '.deliveryStatus' "$report_temp")**"
  print -r -- "- Gates: $pass_count pass / $conditional_count conditional / $fail_count fail"
  print -r -- "- Tasks: $(jq -r '.completedTaskCount' "$report_temp") completed / $pending_count pending"
  print -r -- ""
  print -r -- "## Gate results"
  print -r -- ""
  print -r -- "| Gate | Status | Observed | Expected |"
  print -r -- "|---|---:|---|---|"
  jq -r '.gates[] | "| `\(.id)` | \(.status) | `\(.observedValue)` | `\(.expectedValue)` |"' \
    "$report_temp"
  print -r -- ""
  print -r -- "## Pending tasks"
  print -r -- ""
  if (( pending_count == 0 )); then
    print -r -- "None."
  else
    jq -r '.pendingTasks[] | "- " + .' "$report_temp"
  fi
  print -r -- ""
  print -r -- "A non-pass report keeps the product ineligible for release."
} > "$markdown_temp"

mkdir -p "$(dirname "$json_path")" "$(dirname "$markdown_path")"
mv "$report_temp" "$json_path"
mv "$markdown_temp" "$markdown_path"
print "engineering readiness: $conclusion ($pass_count pass, $conditional_count conditional, $fail_count fail)"
