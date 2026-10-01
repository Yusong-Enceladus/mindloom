#!/bin/zsh
# Generate iOS/MindloomPhone.xcodeproj (and the Info.plist / entitlements
# files it declares) from iOS/project.yml, the same way the Mac project is
# generated from the repository's project.yml.

set -euo pipefail

ios_root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "error: XcodeGen 2.45.3 is required (the Mac project uses the same version)."
  exit 1
fi

xcodegen --spec "$ios_root/project.yml" --project "$ios_root" --quiet
test -f "$ios_root/MindloomPhone.xcodeproj/project.pbxproj"
print "Generated $ios_root/MindloomPhone.xcodeproj"
