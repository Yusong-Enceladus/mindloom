#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-bootstrap-tests.XXXXXX")"
trap 'rm -f "$fixture_root"/*.json; rmdir "$fixture_root" 2>/dev/null || true' EXIT

assert_failure() {
  local name="$1"
  local expected_check="$2"
  shift 2
  local summary="$fixture_root/$name.json"

  set +e
  BESTASR_TEST_MODE=1 "$@" --summary "$summary" >/dev/null 2>&1
  local exit_code=$?
  set -e

  if (( exit_code == 0 )); then
    print -u2 "expected $name to fail"
    exit 1
  fi
  test -f "$summary"
  test "$(/usr/bin/plutil -extract status raw -o - "$summary")" = "fail"
  test "$(/usr/bin/plutil -extract failedCheck raw -o - "$summary")" = "$expected_check"
}

assert_failure \
  command-line-tools-only \
  xcode \
  env BESTASR_TEST_DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  "$repository_root/script/bootstrap.sh"

assert_failure \
  xcode-version-mismatch \
  xcodeVersion \
  env BESTASR_TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BESTASR_TEST_XCODE_VERSION=25.0 \
  "$repository_root/script/bootstrap.sh"

assert_failure \
  metal-toolchain-missing \
  metalToolchain \
  env BESTASR_TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BESTASR_TEST_XCODE_VERSION=27.0 \
  BESTASR_TEST_METAL_TOOLCHAIN_STATUS=missing \
  "$repository_root/script/bootstrap.sh"

assert_failure \
  disk-hard-watermark \
  diskHardWatermark \
  env BESTASR_TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BESTASR_TEST_XCODE_VERSION=27.0 \
  BESTASR_TEST_SWIFT_VERSION=6.4 \
  BESTASR_TEST_XCODEGEN_VERSION=2.45.3 \
  BESTASR_TEST_AVAILABLE_BYTES=5368709120 \
  "$repository_root/script/bootstrap.sh"

assert_failure \
  disk-soft-watermark \
  diskSoftWatermark \
  env BESTASR_TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BESTASR_TEST_XCODE_VERSION=27.0 \
  BESTASR_TEST_SWIFT_VERSION=6.4 \
  BESTASR_TEST_XCODEGEN_VERSION=2.45.3 \
  BESTASR_TEST_AVAILABLE_BYTES=32212254720 \
  "$repository_root/script/bootstrap.sh" \
  --required-bytes 10737418240

print "bootstrap fixtures passed: Command Line Tools-only, version mismatch, Metal Toolchain, hard watermark, soft watermark"
