#!/bin/zsh
# Prints the Apple signing team id builds pass as DEVELOPMENT_TEAM. The team id is never
# committed (project.yml, the generated project and the iOS project carry none):
#   MINDLOOM_TEAM, when set; otherwise the paid (not free) team of the Apple ID signed in
#   to Xcode (Xcode > Settings > Accounts), read from Xcode's own preferences the same way
#   iOS/script/device_build.sh documents for PHONE_TEAM.
set -euo pipefail

team="${MINDLOOM_TEAM:-}"
if [[ -z "$team" ]]; then
  team="$(/usr/bin/defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | /usr/bin/awk '/isFreeProvisioningTeam = 0/{f=1} f && /teamID/{gsub(/[ ;"]/,""); split($0,a,"="); print a[2]; exit}')"
fi
if [[ ! "$team" =~ '^[A-Z0-9]{10}$' ]]; then
  print -u2 "error: no signing team. Set MINDLOOM_TEAM, or sign in to Xcode > Settings > Accounts with the paid team."
  exit 69
fi
print -r -- "$team"
