#!/bin/sh
# Starts Mindloom's bundled MCP helper in place of this script (exec keeps this
# process's parent, Claude Code, as the helper's parent; Mindloom identifies the
# client by it).
#
# Which helper (the product is installed as Mindloom.app, bundle id
# app.mindloom since 2026-10-06):
#   1. MINDLOOM_MCP, when set and executable: a path the owner chose, used as
#      given.
#   2. The product found by its bundle id: the copy that is running first (the
#      one the owner uses; review of 10-6), then the copies LaunchServices
#      knows, those in /Applications or ~/Applications first; then
#      ~/Applications and /Applications by name (Mindloom.app).
#   3. Only when no product copy qualifies: Mindloom Preview
#      (com.bestasr.mindloom.preview), found the same way. It comes last
#      because the product's gate admits only its own helper (review v12-B #9).
# A copy from 2 or 3 is used only when its Info.plist names the bundle id and
# its signature holds: the App and its helper verify (codesign --strict), are
# signed with an Apple-issued developer certificate, and by the same team (by
# MINDLOOM_TEAM, when set).
# MINDLOOM_APP_ID, MINDLOOM_PREVIEW_ID and MINDLOOM_MCP_SKIP_SIGNATURE=1 exist
# for the launcher's tests (AgentLauncherOrderTests); nothing sets them
# otherwise.

app_id="${MINDLOOM_APP_ID:-app.mindloom}"
preview_id="${MINDLOOM_PREVIEW_ID:-com.bestasr.mindloom.preview}"
for id in "$app_id" "$preview_id"; do
  case "$id" in
    *[!A-Za-z0-9.-]* | "") echo "mindloom-mcp: 应用标识无效。" >&2; exit 64 ;;
  esac
done

if [ -n "${MINDLOOM_MCP:-}" ] && [ -x "$MINDLOOM_MCP" ]; then
  exec "$MINDLOOM_MCP" "$@"
fi

team_of() {
  /usr/bin/codesign -dv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'
}

# Prints the helper of the App at $1 when that App's bundle id is $2 and its
# signature holds.
trusted_helper() {
  app=$1
  want=$2
  helper="$app/Contents/Helpers/mindloom-mcp"
  [ -x "$helper" ] || return 1
  id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) \
    || return 1
  [ "$id" = "$want" ] || return 1
  if [ "${MINDLOOM_MCP_SKIP_SIGNATURE:-}" != 1 ]; then
    developer='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists'
    /usr/bin/codesign --verify --strict -R "=$developer and identifier \"$want\"" "$app" \
      >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --strict -R "=$developer" "$helper" >/dev/null 2>&1 || return 1
    app_team=$(team_of "$app")
    [ -n "$app_team" ] && [ "$app_team" != "not set" ] || return 1
    [ "$(team_of "$helper")" = "$app_team" ] || return 1
    if [ -n "${MINDLOOM_TEAM:-}" ] && [ "$app_team" != "$MINDLOOM_TEAM" ]; then return 1; fi
  fi
  printf '%s\n' "$helper"
}

# The copies of bundle id $1: the running ones, then those LaunchServices knows,
# installed ones first.
registered_copies() {
  /usr/bin/osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const home = \$.NSHomeDirectory().js;
    const running = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$1');
    const live = [];
    for (let i = 0; i < running.count; i++) {
      const app = running.objectAtIndex(i);
      if (!app.bundleURL.isNil()) live.push(app.bundleURL.path.js);
    }
    const urls = \$.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier('$1');
    const paths = [];
    for (let i = 0; i < urls.count; i++) paths.push(urls.objectAtIndex(i).path.js);
    const installed = (p) => p.startsWith('/Applications/') || p.startsWith(home + '/Applications/');
    const ordered = live.concat(paths.filter(installed), paths.filter((p) => !installed(p)));
    ordered.filter((p, i) => ordered.indexOf(p) === i).join('\n');
  " 2>/dev/null
}

# Runs the first qualifying helper among bundle id $1's copies: the ones
# LaunchServices knows, then ~/Applications and /Applications.
run_first() {
  want=$1
  shift
  candidates=$(
    registered_copies "$want"
    printf '%s\n' "$HOME/Applications/Mindloom.app" "/Applications/Mindloom.app"
  )
  old_ifs=$IFS
  IFS='
'
  for app in $candidates; do
    IFS=$old_ifs
    [ -d "$app" ] || continue
    if helper=$(trusted_helper "$app" "$want"); then exec "$helper" "$@"; fi
  done
  IFS=$old_ifs
}

run_first "$app_id" "$@"
run_first "$preview_id" "$@"
echo "mindloom-mcp: 无法找到 Mindloom 的连接程序。请先安装并打开 Mindloom，或将 MINDLOOM_MCP 设为它的完整路径。" >&2
exit 1
