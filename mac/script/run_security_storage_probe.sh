#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
probe_root="$repository_root/Spikes/SPIKE-SEC-001/SQLCipherProbe"
artifact_root="$probe_root/Artifacts"
framework_path="$artifact_root/SQLCipher.xcframework"
archive_path="${BESTASR_SQLCIPHER_ARCHIVE:-}"
summary_path="$repository_root/artifacts/evidence/SPIKE-SEC-001/summary.json"
matrix_path="$repository_root/artifacts/evidence/SPIKE-SEC-001/matrix.json"
expected_size="50207727"
expected_digest="510fd00fa51fb017909a159bb1cc233b012e8ce18dc9c2f09014fe47f557c1a6"

while (( $# > 0 )); do
  case "$1" in
    --archive)
      archive_path="$2"
      shift 2
      ;;
    --summary)
      summary_path="$2"
      shift 2
      ;;
    --matrix)
      matrix_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

if [[ ! -d "$framework_path" ]]; then
  if [[ -z "$archive_path" || ! -f "$archive_path" ]]; then
    print -u2 "error: verified SQLCipher 4.16.0 archive is required via --archive or BESTASR_SQLCIPHER_ARCHIVE"
    exit 2
  fi
  actual_size="$(stat -f '%z' "$archive_path")"
  actual_digest="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_size" != "$expected_size" || "$actual_digest" != "$expected_digest" ]]; then
    print -u2 "error: SQLCipher archive size or digest mismatch"
    exit 3
  fi

  mkdir -p "$artifact_root"
  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-sqlcipher-artifact.XXXXXX")"
  trap '/bin/rm -rf -- "$staging_root"' EXIT
  ditto -x -k "$archive_path" "$staging_root"
  if [[ ! -d "$staging_root/SQLCipher.xcframework" ]]; then
    print -u2 "error: archive does not contain SQLCipher.xcframework"
    exit 4
  fi
  mv "$staging_root/SQLCipher.xcframework" "$framework_path"
  rmdir "$staging_root"
  trap - EXIT
fi

macos_framework="$framework_path/macos-arm64_x86_64/SQLCipher.framework"
codesign --verify --deep --strict "$macos_framework"

swift run \
  --package-path "$probe_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH-security" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  SecurityStorageProbeCLI \
  --summary "$summary_path" \
  --matrix "$matrix_path"

jq -e '
  .schemaVersion == 1 and
  .kind == "spike-summary" and
  .spikeID == "SPIKE-SEC-001" and
  (.conclusion == "pass" or .conclusion == "conditional" or .conclusion == "fail") and
  (.matrix | type == "array" and length >= 10) and
  (.unmetCriteria | type == "array")
' "$summary_path" >/dev/null

print "security storage probe evidence: $summary_path"
