#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
summary_path="$repository_root/artifacts/evidence/environment/preflight-summary.json"
required_bytes=0

readonly expected_xcode_version="27.0"
readonly expected_xcodegen_version="2.45.3"
readonly expected_swift_version="6.4"
readonly disk_hard_reserve_bytes=10737418240
readonly disk_soft_reserve_bytes=26843545600

usage() {
  print "usage: script/bootstrap.sh [--required-bytes N] [--summary PATH]"
}

while (( $# > 0 )); do
  case "$1" in
    --required-bytes)
      [[ $# -ge 2 ]] || { print -u2 "error: --required-bytes needs a value"; exit 64; }
      required_bytes="$2"
      shift 2
      ;;
    --summary)
      [[ $# -ge 2 ]] || { print -u2 "error: --summary needs a value"; exit 64; }
      summary_path="$2"
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

if [[ ! "$required_bytes" =~ '^[0-9]+$' ]]; then
  print -u2 "error: --required-bytes must be a non-negative integer"
  exit 64
fi

test_override_names=(
  BESTASR_TEST_DEVELOPER_DIR
  BESTASR_TEST_XCODE_VERSION
  BESTASR_TEST_METAL_TOOLCHAIN_STATUS
  BESTASR_TEST_XCODEGEN_VERSION
  BESTASR_TEST_SWIFT_VERSION
  BESTASR_TEST_AVAILABLE_BYTES
)
for override_name in "${test_override_names[@]}"; do
  if [[ -n "${(P)override_name:-}" && "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
    print -u2 "error: $override_name is accepted only with BESTASR_TEST_MODE=1"
    exit 64
  fi
done

preflight_status="pass"
failed_check=""
error_category=""
remediation=""
xcode_status="not-run"
swift_status="not-run"
xcodegen_status="not-run"
disk_status="not-run"
license_status="not-run"
first_launch_status="not-run"
metal_toolchain_status="${BESTASR_TEST_METAL_TOOLCHAIN_STATUS:-not-run}"
developer_directory="${BESTASR_TEST_DEVELOPER_DIR:-}"
xcode_version="${BESTASR_TEST_XCODE_VERSION:-}"
swift_version="${BESTASR_TEST_SWIFT_VERSION:-}"
xcodegen_version="${BESTASR_TEST_XCODEGEN_VERSION:-}"
available_bytes="${BESTASR_TEST_AVAILABLE_BYTES:-0}"
sdk_path=""
disk_check_path="$repository_root"

if [[ "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
  source "$repository_root/script/build_storage.sh"
  disk_check_path="$BESTASR_BUILD_ROOT"
fi

write_summary() {
  local summary_directory summary_temp_directory summary_temp
  summary_directory="$(dirname "$summary_path")"
  mkdir -p "$summary_directory"
  summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-preflight.XXXXXX")"
  summary_temp="$summary_temp_directory/preflight-summary.json"
  trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT

  /usr/bin/plutil -create xml1 "$summary_temp"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$summary_temp"
  /usr/bin/plutil -insert status -string "$preflight_status" "$summary_temp"
  /usr/bin/plutil -insert failedCheck -string "$failed_check" "$summary_temp"
  /usr/bin/plutil -insert errorCategory -string "$error_category" "$summary_temp"
  /usr/bin/plutil -insert remediation -string "$remediation" "$summary_temp"
  /usr/bin/plutil -insert requiredBytes -integer "$required_bytes" "$summary_temp"
  /usr/bin/plutil -insert availableBytes -integer "$available_bytes" "$summary_temp"
  /usr/bin/plutil -insert diskHardReserveBytes -integer "$disk_hard_reserve_bytes" "$summary_temp"
  /usr/bin/plutil -insert diskSoftReserveBytes -integer "$disk_soft_reserve_bytes" "$summary_temp"
  /usr/bin/plutil -insert architecture -string "$(uname -m)" "$summary_temp"
  /usr/bin/plutil -insert checks -dictionary "$summary_temp"
  /usr/bin/plutil -insert checks.xcode -dictionary "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.status -string "$xcode_status" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.expectedVersion -string "$expected_xcode_version" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.actualVersion -string "$xcode_version" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.developerDirectory -string "$developer_directory" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.licenseStatus -string "$license_status" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.firstLaunchStatus -string "$first_launch_status" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.metalToolchainStatus -string "$metal_toolchain_status" "$summary_temp"
  /usr/bin/plutil -insert checks.xcode.sdkPath -string "$sdk_path" "$summary_temp"
  /usr/bin/plutil -insert checks.swift -dictionary "$summary_temp"
  /usr/bin/plutil -insert checks.swift.status -string "$swift_status" "$summary_temp"
  /usr/bin/plutil -insert checks.swift.expectedVersion -string "$expected_swift_version" "$summary_temp"
  /usr/bin/plutil -insert checks.swift.actualVersion -string "$swift_version" "$summary_temp"
  /usr/bin/plutil -insert checks.xcodegen -dictionary "$summary_temp"
  /usr/bin/plutil -insert checks.xcodegen.status -string "$xcodegen_status" "$summary_temp"
  /usr/bin/plutil -insert checks.xcodegen.expectedVersion -string "$expected_xcodegen_version" "$summary_temp"
  /usr/bin/plutil -insert checks.xcodegen.actualVersion -string "$xcodegen_version" "$summary_temp"
  /usr/bin/plutil -insert checks.disk -dictionary "$summary_temp"
  /usr/bin/plutil -insert checks.disk.status -string "$disk_status" "$summary_temp"
  /usr/bin/plutil -insert checks.disk.path -string "$disk_check_path" "$summary_temp"
  /usr/bin/plutil -convert json -r "$summary_temp"

  mv "$summary_temp" "$summary_path"
  rmdir "$summary_temp_directory"
  trap - EXIT
}

fail_preflight() {
  local exit_code="$1"
  preflight_status="fail"
  write_summary
  print -u2 "preflight failed [$failed_check]: $remediation"
  print -u2 "summary: $summary_path"
  exit "$exit_code"
}

if [[ "$(uname -m)" != "arm64" ]]; then
  failed_check="architecture"
  error_category="unsupportedArchitecture"
  remediation="Use an Apple Silicon Mac; Intel is outside the V1 support boundary."
  fail_preflight 10
fi

if [[ -z "$developer_directory" ]]; then
  if ! command -v xcode-select >/dev/null 2>&1; then
    failed_check="xcode"
    error_category="xcodeSelectMissing"
    remediation="Install full Xcode 27.0, then select /Applications/Xcode.app/Contents/Developer."
    fail_preflight 11
  fi
  developer_directory="$(xcode-select -p 2>/dev/null || true)"
fi

if [[ "$developer_directory" != */Xcode.app/Contents/Developer ]]; then
  failed_check="xcode"
  error_category="fullXcodeMissing"
  remediation="Select full Xcode with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  xcode_status="fail"
  fail_preflight 12
fi

if [[ -z "$xcode_version" ]]; then
  xcode_version="$(xcodebuild -version 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
fi
if [[ "$xcode_version" != "$expected_xcode_version" ]]; then
  failed_check="xcodeVersion"
  error_category="toolVersionMismatch"
  remediation="Install and select Xcode $expected_xcode_version; found $xcode_version."
  xcode_status="fail"
  fail_preflight 13
fi
xcode_status="pass"

if [[ "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
  if xcodebuild -license check >/dev/null 2>&1; then
    license_status="pass"
  else
    failed_check="xcodeLicense"
    error_category="xcodeLicenseNotAccepted"
    remediation="Accept the Xcode license with: sudo xcodebuild -license accept"
    license_status="fail"
    xcode_status="fail"
    fail_preflight 14
  fi

  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    first_launch_status="pass"
  else
    failed_check="xcodeFirstLaunch"
    error_category="xcodeFirstLaunchIncomplete"
    remediation="Complete Xcode components with: sudo xcodebuild -runFirstLaunch"
    first_launch_status="fail"
    xcode_status="fail"
    fail_preflight 15
  fi
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  metal_toolchain_status="$(xcodebuild -showComponent MetalToolchain 2>/dev/null | /usr/bin/sed -n 's/^Status: //p' | /usr/bin/head -n 1)"
else
  license_status="test-bypassed"
  first_launch_status="test-bypassed"
  metal_toolchain_status="${BESTASR_TEST_METAL_TOOLCHAIN_STATUS:-test-bypassed}"
  sdk_path="test-fixture"
fi

if [[ "$metal_toolchain_status" != "installed" && "$metal_toolchain_status" != "test-bypassed" ]]; then
  failed_check="metalToolchain"
  error_category="metalToolchainMissing"
  remediation="Install the Xcode $expected_xcode_version Metal Toolchain with: xcodebuild -downloadComponent MetalToolchain"
  xcode_status="fail"
  fail_preflight 19
fi

if [[ -z "$swift_version" ]]; then
  swift_version="$(swift --version 2>/dev/null | /usr/bin/sed -nE 's/.*Apple Swift version ([0-9.]+).*/\1/p' | /usr/bin/head -n 1)"
fi
if [[ "$swift_version" != "$expected_swift_version" ]]; then
  failed_check="swiftVersion"
  error_category="toolVersionMismatch"
  remediation="Select the Xcode $expected_xcode_version toolchain; expected Swift $expected_swift_version, found $swift_version."
  swift_status="fail"
  fail_preflight 16
fi
swift_status="pass"

if ! command -v xcodegen >/dev/null 2>&1 && [[ -z "$xcodegen_version" ]]; then
  failed_check="xcodegen"
  error_category="xcodegenMissing"
  remediation="Install XcodeGen $expected_xcodegen_version and ensure xcodegen is on PATH."
  xcodegen_status="fail"
  fail_preflight 17
fi
if [[ -z "$xcodegen_version" ]]; then
  xcodegen_version="$(xcodegen --version | /usr/bin/sed 's/^Version: //')"
fi
if [[ "$xcodegen_version" != "$expected_xcodegen_version" ]]; then
  failed_check="xcodegenVersion"
  error_category="toolVersionMismatch"
  remediation="Install XcodeGen $expected_xcodegen_version; found $xcodegen_version."
  xcodegen_status="fail"
  fail_preflight 18
fi
xcodegen_status="pass"

if [[ "$available_bytes" == "0" ]]; then
  available_kib="$(/bin/df -Pk "$disk_check_path" | /usr/bin/awk 'NR == 2 { print $4 }')"
  available_bytes=$(( available_kib * 1024 ))
fi

hard_required_bytes=$(( required_bytes + disk_hard_reserve_bytes ))
soft_required_bytes=$(( required_bytes + disk_soft_reserve_bytes ))
if (( available_bytes < hard_required_bytes )); then
  failed_check="diskHardWatermark"
  error_category="insufficientDiskHard"
  remediation="Refusing operation: required artifact bytes=$required_bytes, available bytes=$available_bytes, hard reserve bytes=$disk_hard_reserve_bytes. Preserve source audio; free non-source space and retry."
  disk_status="hard-stop"
  fail_preflight 20
fi
if (( available_bytes < soft_required_bytes )); then
  failed_check="diskSoftWatermark"
  error_category="insufficientDiskSoft"
  remediation="Refusing model/corpus operation: required artifact bytes=$required_bytes, available bytes=$available_bytes, soft reserve bytes=$disk_soft_reserve_bytes. Preserve source audio; free non-source space and retry."
  disk_status="soft-stop"
  fail_preflight 21
fi
disk_status="pass"

write_summary
print "preflight passed: Xcode $xcode_version, Swift $swift_version, XcodeGen $xcodegen_version"
print "available bytes: $available_bytes; requested artifact bytes: $required_bytes"
print "summary: $summary_path"
