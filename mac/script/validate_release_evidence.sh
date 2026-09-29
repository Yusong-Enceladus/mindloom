#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
summary_path="$repository_root/artifacts/evidence/release/release-smoke-summary.json"

summary_filter='.schemaVersion == 1 and
  .kind == "release-smoke-summary" and
  (.status == "pass" or .status == "blocked") and
  .smokeStatus == "pass" and
  (.releaseEligible == (.status == "pass")) and
  .checks.hardenedRuntime == "pass" and
  .checks.architecture == "pass" and
  .checks.minimumOS == "pass" and
  .checks.appSignature == "pass" and
  .checks.xpcSignature == "pass" and
  .checks.dmg == "pass" and
  (.dmg.sizeBytes | type == "number" and . > 0) and
  (.dmg.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (if .status == "blocked" then
    (.blockers | type == "array" and length > 0) and
    .checks.developerID == "blocked" and
    .checks.notarization == "blocked"
   else
    (.blockers | length == 0) and
    .checks.developerID == "pass" and
    .checks.notarization == "pass" and
    .checks.staple == "pass" and
    .checks.gatekeeper == "pass"
   end)'

if [[ ! -f "$summary_path" ]] || ! jq -e "$summary_filter" "$summary_path" >/dev/null; then
  print -u2 "release evidence validation failed"
  exit 1
fi

print "release evidence valid: $(jq -r .status "$summary_path")"
