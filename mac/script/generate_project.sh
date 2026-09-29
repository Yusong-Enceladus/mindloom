#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
summary_path="$repository_root/artifacts/evidence/environment/workspace-summary.json"

if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "error: XcodeGen 2.45.3 is required; run script/bootstrap.sh for remediation."
  exit 1
fi

xcodegen --spec "$repository_root/project.yml" --project "$repository_root" --quiet

test -f "$repository_root/BestASR.xcodeproj/project.pbxproj"
test -f "$repository_root/BestASR.xcworkspace/contents.xcworkspacedata"

summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-workspace-summary.XXXXXX")"
summary_temp="$summary_temp_directory/workspace-summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT

/usr/bin/plutil -create xml1 "$summary_temp"
/usr/bin/plutil -insert schemaVersion -integer 1 "$summary_temp"
/usr/bin/plutil -insert project -string "BestASR.xcodeproj" "$summary_temp"
/usr/bin/plutil -insert workspace -string "BestASR.xcworkspace" "$summary_temp"
/usr/bin/plutil -insert architecture -string "arm64" "$summary_temp"
/usr/bin/plutil -insert minimumMacOS -string "14.2" "$summary_temp"
/usr/bin/plutil -insert swiftLanguageMode -string "6" "$summary_temp"
/usr/bin/plutil -insert strictConcurrency -string "complete" "$summary_temp"
/usr/bin/plutil -insert targets -json '["BestASR","InferenceWorker","BenchCLI","WorkspaceSmokeTests","BestASRUITests"]' "$summary_temp"
/usr/bin/plutil -insert xcodegenVersion -string "$(xcodegen --version | /usr/bin/sed 's/^Version: //')" "$summary_temp"
/usr/bin/plutil -insert xcodeVersion -string "$(xcodebuild -version | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')" "$summary_temp"
/usr/bin/plutil -insert swiftVersion -string "$(swift --version 2>/dev/null | /usr/bin/sed -n '1p')" "$summary_temp"
/usr/bin/plutil -insert projectSpecSHA256 -string "$(/usr/bin/shasum -a 256 "$repository_root/project.yml" | /usr/bin/awk '{print $1}')" "$summary_temp"
/usr/bin/plutil -insert generatedProjectSHA256 -string "$(/usr/bin/shasum -a 256 "$repository_root/BestASR.xcodeproj/project.pbxproj" | /usr/bin/awk '{print $1}')" "$summary_temp"
/usr/bin/plutil -convert json -r "$summary_temp"

mkdir -p "$(dirname "$summary_path")"
mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

print "Generated BestASR.xcodeproj and $summary_path"
