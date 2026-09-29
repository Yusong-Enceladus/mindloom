#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

shell_files=(
  "$repository_root"/script/*.sh(N)
  "$repository_root"/Tests/Shell/*.sh(N)
)
for shell_file in "${shell_files[@]}"; do
  zsh -n "$shell_file"
done

xcrun swift-format lint --recursive --strict \
  "$repository_root/App" \
  "$repository_root/InferenceWorker" \
  "$repository_root/Tools" \
  "$repository_root/Tests/WorkspaceSmokeTests" \
  "$repository_root/UITests" \
  "$repository_root/Packages/BestASRCore"

json_files=(
  "$repository_root"/config/*.json(N)
  "$repository_root"/schemas/**/*.json(N)
  "$repository_root"/Tests/Fixtures/**/*.json(N)
  "$repository_root"/artifacts/evidence/**/*.json(N)
)
for json_file in "${json_files[@]}"; do
  jq -e . "$json_file" >/dev/null
done

"$repository_root/script/lint_permissions.sh"

# The own-device organizer's data-provenance guard must hold in every build
# configuration (Debug and Release alike), so its module and the app glue may
# not branch on conditional compilation.
organizer_guard_files=(
  "$repository_root"/Packages/BestASRCore/Sources/BestASRRemoteOrganizer/*.swift(N)
  "$repository_root/App/DictationAppModel+RemoteOrganizer.swift"
)
if /usr/bin/grep -nE '^[[:space:]]*#(if|elseif)([[:space:]]|$)' "${organizer_guard_files[@]}"; then
  print -u2 "error: conditional compilation in the organizer link or its provenance guard"
  exit 1
fi

print "static checks passed"
