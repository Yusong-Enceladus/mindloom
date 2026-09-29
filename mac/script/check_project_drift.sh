#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$repository_root/BestASR.xcodeproj/project.pbxproj"
summary_file="$repository_root/artifacts/evidence/environment/workspace-summary.json"
workspace_file="$repository_root/BestASR.xcworkspace/contents.xcworkspacedata"

test -f "$project_file" || {
  print -u2 "error: generated project is missing; run script/generate_project.sh"
  exit 1
}
test -f "$summary_file" || {
  print -u2 "error: workspace evidence is missing; run script/generate_project.sh"
  exit 1
}
test -f "$workspace_file"
/usr/bin/xmllint --noout "$workspace_file"

project_before="$(/usr/bin/shasum -a 256 "$project_file" | /usr/bin/awk '{print $1}')"
summary_before="$(/usr/bin/shasum -a 256 "$summary_file" | /usr/bin/awk '{print $1}')"

"$repository_root/script/generate_project.sh" >/dev/null

project_after="$(/usr/bin/shasum -a 256 "$project_file" | /usr/bin/awk '{print $1}')"
summary_after="$(/usr/bin/shasum -a 256 "$summary_file" | /usr/bin/awk '{print $1}')"

if [[ "$project_before" != "$project_after" || "$summary_before" != "$summary_after" ]]; then
  print -u2 "error: XcodeGen output drifted. Review the regenerated project, then rerun the gate."
  exit 1
fi

print "project regeneration is deterministic: $project_after"

