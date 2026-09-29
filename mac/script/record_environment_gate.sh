#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
run_id=""
evidence_root="$repository_root/artifacts/evidence/environment"
derived_root="$BESTASR_BUILD_ROOT/environment-gate"

usage() {
  print "usage: script/record_environment_gate.sh [--run-id ID]"
}

while (( $# > 0 )); do
  case "$1" in
    --run-id)
      [[ $# -ge 2 ]] || { print -u2 "error: --run-id needs a value"; exit 64; }
      run_id="$2"
      shift 2
      ;;
    --evidence-root)
      [[ $# -ge 2 ]] || { print -u2 "error: --evidence-root needs a value"; exit 64; }
      if [[ "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
        print -u2 "error: --evidence-root is accepted only with BESTASR_TEST_MODE=1"
        exit 64
      fi
      evidence_root="$2"
      shift 2
      ;;
    --derived-root)
      [[ $# -ge 2 ]] || { print -u2 "error: --derived-root needs a value"; exit 64; }
      if [[ "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
        print -u2 "error: --derived-root is accepted only with BESTASR_TEST_MODE=1"
        exit 64
      fi
      derived_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$run_id" ]]; then
  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
fi

if ! print -r -- "$run_id" | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'; then
  print -u2 "error: run ID must start with an alphanumeric character and contain only alphanumerics, dot, underscore, or hyphen"
  exit 64
fi

evidence_run_directory="$evidence_root/$run_id"
derived_run_directory="$derived_root/$run_id"
derived_data_path="$derived_run_directory/DerivedData"

if [[ -e "$evidence_run_directory" ]]; then
  print -u2 "error: evidence run already exists; choose a new run ID: $run_id"
  exit 65
fi
if [[ -e "$derived_run_directory" ]]; then
  print -u2 "error: derived-data run already exists; a Gate run must start from an unused path: $run_id"
  exit 65
fi

mkdir -p "$evidence_run_directory" "$derived_run_directory"

check_summary_path="$evidence_run_directory/check-summary.json"
toolchain_summary_path="$evidence_run_directory/toolchain-summary.json"
command_summary_path="$evidence_run_directory/command-summary.json"
test_summary_path="$evidence_run_directory/test-summary.json"
gate_summary_path="$evidence_run_directory/gate-run.json"

if [[ "$evidence_root" == "$repository_root"/* && "$derived_root" == "$repository_root"/* ]]; then
  evidence_run_label="${evidence_run_directory#$repository_root/}"
  derived_data_label="${derived_data_path#$repository_root/}"
else
  evidence_run_label="$evidence_run_directory"
  derived_data_label="$derived_data_path"
fi

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
xcode_version="$(xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//' || true)"
swift_version="$(swift --version 2>/dev/null | /usr/bin/sed -n '1p' || true)"
xcodegen_version="$(xcodegen --version 2>/dev/null | /usr/bin/sed 's/^Version: //' || true)"
macos_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
architecture="$(uname -m)"

jq -n \
  --arg xcode "$xcode_version" \
  --arg swift "$swift_version" \
  --arg xcodegen "$xcodegen_version" \
  --arg macOS "$macos_version" \
  --arg architecture "$architecture" \
  '{
    schemaVersion: 1,
    xcode: $xcode,
    swift: $swift,
    xcodegen: $xcodegen,
    macOS: $macOS,
    architecture: $architecture
  }' > "$toolchain_summary_path"

set +e
"$repository_root/script/check.sh" \
  --summary "$check_summary_path" \
  --derived-data "$derived_data_path"
check_exit_code=$?
set -e

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if (( check_exit_code == 0 )); then
  gate_status="pass"
else
  gate_status="fail"
fi

jq -n \
  --arg status "$gate_status" \
  --arg summary "$evidence_run_label/check-summary.json" \
  --arg derivedData "$derived_data_label" \
  --argjson exitCode "$check_exit_code" \
  '{
    schemaVersion: 1,
    status: $status,
    command: [
      "script/check.sh",
      "--summary", $summary,
      "--derived-data", $derivedData
    ],
    exitCode: $exitCode
  }' > "$command_summary_path"

if [[ -f "$check_summary_path" ]]; then
  jq '{
    schemaVersion: 1,
    overallStatus: .status,
    tests: [
      .stages[] |
      select(
        .name == "swift-package-tests" or
        .name == "unit-tests" or
        .name == "ui-tests"
      )
    ]
  }' "$check_summary_path" > "$test_summary_path"
else
  jq -n \
    --arg status "$gate_status" \
    '{schemaVersion: 1, overallStatus: $status, tests: []}' > "$test_summary_path"
fi

toolchain_digest="$(/usr/bin/shasum -a 256 "$toolchain_summary_path" | /usr/bin/awk '{print $1}')"
command_digest="$(/usr/bin/shasum -a 256 "$command_summary_path" | /usr/bin/awk '{print $1}')"
test_digest="$(/usr/bin/shasum -a 256 "$test_summary_path" | /usr/bin/awk '{print $1}')"
if [[ -f "$check_summary_path" ]]; then
  check_digest="$(/usr/bin/shasum -a 256 "$check_summary_path" | /usr/bin/awk '{print $1}')"
else
  check_digest=""
fi

jq -n \
  --arg runID "$run_id" \
  --arg status "$gate_status" \
  --arg startedAt "$started_at" \
  --arg finishedAt "$finished_at" \
  --arg evidenceDirectory "$evidence_run_label" \
  --arg derivedData "$derived_data_label" \
  --arg toolchainDigest "$toolchain_digest" \
  --arg commandDigest "$command_digest" \
  --arg testDigest "$test_digest" \
  --arg checkDigest "$check_digest" \
  --argjson exitCode "$check_exit_code" \
  '{
    schemaVersion: 1,
    runID: $runID,
    status: $status,
    startedAt: $startedAt,
    finishedAt: $finishedAt,
    freshDerivedDataAtStart: true,
    evidenceDirectory: $evidenceDirectory,
    derivedData: $derivedData,
    exitCode: $exitCode,
    files: {
      toolchain: {path: "toolchain-summary.json", sha256: $toolchainDigest},
      command: {path: "command-summary.json", sha256: $commandDigest},
      tests: {path: "test-summary.json", sha256: $testDigest},
      check: {path: "check-summary.json", sha256: $checkDigest}
    }
  }' > "$gate_summary_path"

print "environment Gate $gate_status"
print "evidence: $evidence_run_directory"
exit "$check_exit_code"
