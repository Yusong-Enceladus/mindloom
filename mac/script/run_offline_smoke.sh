#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
summary_path="$repository_root/artifacts/evidence/privacy/offline-smoke-summary.json"
scratch_path="$BESTASR_SWIFTPM_SCRATCH"

while (( $# > 0 )); do
  case "$1" in
    --summary)
      [[ $# -ge 2 ]] || { print -u2 "error: --summary needs a value"; exit 64; }
      summary_path="$2"
      shift 2
      ;;
    --scratch-path)
      [[ $# -ge 2 ]] || { print -u2 "error: --scratch-path needs a value"; exit 64; }
      scratch_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

[[ -x /usr/bin/sandbox-exec ]] || {
  print -u2 "error: macOS sandbox-exec is required for deny-all network evidence"
  exit 2
}

swift build \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_path" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product OfflineSmokeSuiteCLI >/dev/null
binary_directory="$(swift build \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$scratch_path" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --show-bin-path)"
binary_path="$binary_directory/OfflineSmokeSuiteCLI"
[[ -x "$binary_path" ]] || {
  print -u2 "error: offline smoke executable was not built"
  exit 1
}

profile_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-offline-profile.XXXXXX")"
profile_path="$profile_directory/deny-network.sb"
trap 'rm -f "$profile_path"; rmdir "$profile_directory" 2>/dev/null || true' EXIT
print '(version 1)' > "$profile_path"
print '(allow default)' >> "$profile_path"
print '(deny network*)' >> "$profile_path"

/usr/bin/sandbox-exec \
  -f "$profile_path" \
  "$binary_path" \
  --summary "$summary_path"

jq -e '
  .schemaVersion == 1 and
  .kind == "offline-smoke-summary" and
  .status == "pass" and
  .networkPolicy == "deny-all" and
  .enforcement == "macos-sandbox-exec" and
  .networkDenialProbe.attempted == true and
  .networkDenialProbe.blocked == true and
  .requestAudit.attemptedRequests == 0 and
  .requestAudit.allowedRequests == 0 and
  (.capabilities | length) == 5 and
  ([.capabilities[] | select(.status == "pass")] | length) == 5
' "$summary_path" >/dev/null

print "deny-all offline smoke evidence passed"
