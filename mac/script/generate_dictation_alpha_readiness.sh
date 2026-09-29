#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
gates_path="$repository_root/config/dictation-alpha-readiness-gates.json"
json_path="$repository_root/artifacts/evidence/readiness/dictation-alpha-readiness-report.json"
markdown_path="$repository_root/artifacts/evidence/readiness/dictation-alpha-readiness-report.md"

while (( $# > 0 )); do
  case "$1" in
    --gates)
      gates_path="$2"
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

for required_tool in jq shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required alpha-readiness tool missing: $required_tool"
    exit 2
  }
done

jq -e '
  .schemaVersion == 1 and
  .kind == "dictation-alpha-readiness-gates" and
  (.alphaGates | type == "array" and length > 0) and
  (.wholeProductGaps | type == "array" and length > 0) and
  ([.alphaGates[].id, .wholeProductGaps[].id] | length == (unique | length)) and
  all((.alphaGates[]), (.wholeProductGaps[]);
    (.id | type == "string" and test("^[a-z0-9-]+$")) and
    (.evidencePath | type == "string" and test("^(artifacts/evidence/|config/|Tests/Fixtures/)[A-Za-z0-9._/-]+$")) and
    (.field | type == "string" and test("^[A-Za-z0-9.]+$")) and
    (.expectedValue != null) and
    (.unmetStatus == "fail" or .unmetStatus == "conditional") and
    (.taskRefs | type == "array" and length > 0) and
    (.blocker | type == "string" and length > 0)
  ) and
  all(.wholeProductGaps[]; .scope == "formalMVP" or .scope == "v1" or .scope == "both")
' "$gates_path" >/dev/null || {
  print -u2 "error: invalid dictation alpha readiness configuration"
  exit 1
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-dictation-alpha-readiness.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
alpha_gates="$temporary_root/alpha-gates.json"
whole_gaps="$temporary_root/whole-gaps.json"
formal_gates="$temporary_root/formal-gates.json"
v1_gates="$temporary_root/v1-gates.json"
report_temp="$temporary_root/report.json"
markdown_temp="$temporary_root/report.md"

evaluate_group() {
  local selector="$1"
  local output_path="$2"
  local lines_path="$temporary_root/$(basename "$output_path").ndjson"
  : > "$lines_path"
  local count="$(jq -r "$selector | length" "$gates_path")"
  for (( index = 0; index < count; index++ )); do
    local gate="$(jq -c "${selector}[$index]" "$gates_path")"
    local evidence_path="$(jq -r '.evidencePath' <<< "$gate")"
    [[ "/$evidence_path/" != *"/../"* && "/$evidence_path/" != *"/./"* ]] || {
      print -u2 "error: unsafe alpha readiness evidence path"
      exit 1
    }
    local field="$(jq -r '.field' <<< "$gate")"
    local expected="$(jq -c '.expectedValue' <<< "$gate")"
    local gate_status="$(jq -r '.unmetStatus' <<< "$gate")"
    local observed="null"
    local evidence_sha256=""
    if [[ -f "$repository_root/$evidence_path" ]]; then
      evidence_sha256="$(shasum -a 256 "$repository_root/$evidence_path" | awk '{print $1}')"
      observed="$(
        jq -c --arg field "$field" '
          try getpath(
            $field | split(".") | map(if test("^[0-9]+$") then tonumber else . end)
          ) catch null
        ' "$repository_root/$evidence_path" 2>/dev/null || print null
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
      }' >> "$lines_path"
  done
  jq -s '.' "$lines_path" > "$output_path"
}

conclusion_for() {
  local gates="$1"
  local fail_count="$(jq '[.[] | select(.status == "fail")] | length' "$gates")"
  local conditional_count="$(jq '[.[] | select(.status == "conditional")] | length' "$gates")"
  if (( fail_count > 0 )); then
    print fail
  elif (( conditional_count > 0 )); then
    print conditional
  else
    print pass
  fi
}

evaluate_group '.alphaGates' "$alpha_gates"
evaluate_group '.wholeProductGaps' "$whole_gaps"
jq -s '.[0] + [.[1][] | select(.scope == "formalMVP" or .scope == "both")]' \
  "$alpha_gates" "$whole_gaps" > "$formal_gates"
jq -s '.[0] + [.[1][] | select(.scope == "v1" or .scope == "both")]' \
  "$alpha_gates" "$whole_gaps" > "$v1_gates"

alpha_conclusion="$(conclusion_for "$alpha_gates")"
formal_conclusion="$(conclusion_for "$formal_gates")"
v1_conclusion="$(conclusion_for "$v1_gates")"

jq -n \
  --arg alphaConclusion "$alpha_conclusion" \
  --arg formalConclusion "$formal_conclusion" \
  --arg v1Conclusion "$v1_conclusion" \
  --arg gatesSHA256 "$(shasum -a 256 "$gates_path" | awk '{print $1}')" \
  --slurpfile alpha "$alpha_gates" \
  --slurpfile gaps "$whole_gaps" \
  --slurpfile formal "$formal_gates" \
  --slurpfile v1 "$v1_gates" \
  '{
    schemaVersion: 1,
    kind: "dictation-alpha-readiness-report",
    dictationAlphaConclusion: $alphaConclusion,
    dictationAlphaReady: ($alphaConclusion == "pass"),
    formalMVPConclusion: $formalConclusion,
    formalMVPReady: ($formalConclusion == "pass"),
    v1Conclusion: $v1Conclusion,
    v1Ready: ($v1Conclusion == "pass"),
    separationInvariant: true,
    gatesSHA256: $gatesSHA256,
    alphaGateCounts: {
      pass: ([$alpha[0][] | select(.status == "pass")] | length),
      conditional: ([$alpha[0][] | select(.status == "conditional")] | length),
      fail: ([$alpha[0][] | select(.status == "fail")] | length)
    },
    alphaGates: $alpha[0],
    wholeProductGaps: $gaps[0],
    unresolvedAlphaBlockers: (
      [$alpha[0][] | select(.status != "pass") | .blocker] | unique
    ),
    unresolvedWholeProductGaps: (
      [$gaps[0][] | select(.status != "pass") | {
        id: .id,
        scope: .scope,
        status: .status,
        blocker: .blocker
      }]
    ),
    formalGateCount: ($formal[0] | length),
    v1GateCount: ($v1[0] | length)
  }' > "$report_temp"

{
  print -r -- "# bestASR dictation alpha readiness"
  print -r -- ""
  print -r -- "- Dictation alpha: **$alpha_conclusion**"
  print -r -- "- Formal MVP: **$formal_conclusion**"
  print -r -- "- V1: **$v1_conclusion**"
  print -r -- ""
  print -r -- "Dictation alpha is calculated only from built-in-microphone dictation gates. Formal MVP and V1 additionally include the visible whole-product gaps below."
  print -r -- ""
  print -r -- "## Dictation alpha gates"
  print -r -- ""
  print -r -- "| Gate | Status | Observed | Expected |"
  print -r -- "|---|---:|---|---|"
  jq -r '.alphaGates[] | "| `\(.id)` | \(.status) | `\(.observedValue)` | `\(.expectedValue)` |"' \
    "$report_temp"
  print -r -- ""
  print -r -- "## Whole-product gaps"
  print -r -- ""
  print -r -- "| Gap | Scope | Status |"
  print -r -- "|---|---|---:|"
  jq -r '.wholeProductGaps[] | "| `\(.id)` | \(.scope) | \(.status) |"' \
    "$report_temp"
} > "$markdown_temp"

mkdir -p "$(dirname "$json_path")" "$(dirname "$markdown_path")"
mv "$report_temp" "$json_path"
mv "$markdown_temp" "$markdown_path"
print "dictation alpha readiness: $alpha_conclusion; formal MVP: $formal_conclusion; V1: $v1_conclusion"
