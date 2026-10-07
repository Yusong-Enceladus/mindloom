#!/bin/zsh
# Installs a verified Release build as the one product App:
# <applications dir>/Mindloom.app, bundle id app.mindloom (script/identity.sh; owner's decision
# 2026-10-06).
#
# Every installed copy of the product in the applications folder is found by its bundle
# id (LaunchServices, then the name Mindloom.app), quit gracefully by bundle id when it runs
# from that folder (never killed), unregistered and kept as Mindloom-backup-*.rollback in the
# backup folder (no .app suffix, so LaunchServices and TCC never see an old copy as a
# second App). A Mindloom.app with another bundle id (Mindloom Preview) is not replaced:
# the installer stops and says so (the switch script moves the preview aside first).
#
# bestASR (com.bestasr.app) is not this installer's: the switch from bestASR
# (mindloom-switch.sh) quits it, moves its library and hands its keychain items over. This
# installer moves no library, preferences or login item; the App repairs 「登录时打开」 on its
# first launch from a new place.

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"
source "$repository_root/script/identity.sh"

product_id="$MINDLOOM_BUNDLE_ID"
source_app="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/$MINDLOOM_APP_NAME"
applications_dir="$HOME/Applications"
backup_dir="$BESTASR_BUILD_ROOT/installation-backups"
expected_revision="$(git -C "$repository_root" rev-parse HEAD)"
launch_after_install=true
positional_source_seen=false
allow_ad_hoc=false
lsregister="${BESTASR_LSREGISTER_PATH:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

while (( $# > 0 )); do
  case "$1" in
    --source) source_app="$2"; shift 2 ;;
    --applications-dir) applications_dir="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --expected-revision) expected_revision="$2"; shift 2 ;;
    --product-id) product_id="$2"; shift 2 ;;
    --no-launch) launch_after_install=false; shift ;;
    --allow-ad-hoc-for-tests) allow_ad_hoc=true; shift ;;
    --*) print -u2 "error: unknown argument: $1"; exit 64 ;;
    *)
      if [[ "$positional_source_seen" == true ]]; then
        print -u2 "error: only one positional source bundle is supported"
        exit 64
      fi
      source_app="$1"
      positional_source_seen=true
      shift
      ;;
  esac
done

applications_dir="${applications_dir:A}"
[[ "$product_id" =~ '^[A-Za-z0-9.-]+$' ]] || { print -u2 "error: invalid product id"; exit 64; }
[[ "$applications_dir" != *[\'\\]* ]] || { print -u2 "error: unsupported applications folder path"; exit 64; }
destination_app="$applications_dir/Mindloom.app"
timestamp="$(date +%Y%m%d-%H%M%S)"
staging_app="$applications_dir/.Mindloom-installing-$timestamp-$$.app"
typeset -a moved_from moved_to
install_succeeded=0

remove_tree() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  find "$target" -depth -delete
}

bundle_id_of() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# The product's copies directly in the applications folder: what LaunchServices knows
# by bundle id, then its name.
installed_copies() {
  local found
  found="$(/usr/bin/osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const urls = \$.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier('$product_id');
    const out = [];
    for (let i = 0; i < urls.count; i++) out.push(urls.objectAtIndex(i).path.js);
    out.join('\n');
  " 2>/dev/null || true)"
  {
    print -r -- "$found"
    print -r -- "$applications_dir/Mindloom.app"
  } | while IFS= read -r candidate; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    [[ "${candidate:A:h}" == "$applications_dir" ]] || continue
    [[ "$(bundle_id_of "$candidate")" == "$product_id" ]] || continue
    print -r -- "${candidate:A}"
  done | /usr/bin/awk '!seen[$0]++'
}

# Running copies of the product launched from the applications folder (copies elsewhere,
# such as a build folder, are not this installation's).
running_count() {
  /usr/bin/osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$product_id');
    let n = 0;
    for (let i = 0; i < apps.count; i++) {
      const url = apps.objectAtIndex(i).bundleURL;
      if (!url.isNil() && url.path.js.startsWith('$applications_dir/')) n++;
    }
    n;
  " 2>/dev/null || print 0
}

# Asks those copies to quit (as 退出 in the App's menu does) and waits; never kills.
quit_product() {
  (( $(running_count) > 0 )) || return 0
  /usr/bin/osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$product_id');
    for (let i = 0; i < apps.count; i++) {
      const app = apps.objectAtIndex(i);
      if (!app.bundleURL.isNil() && app.bundleURL.path.js.startsWith('$applications_dir/')) app.terminate;
    }
  " >/dev/null 2>&1 || true
  for _ in {1..100}; do
    (( $(running_count) == 0 )) && return 0
    sleep 0.2
  done
  return 1
}

rollback() {
  local exit_status=$?
  if (( install_succeeded == 0 )); then
    remove_tree "$staging_app"
    local i
    for (( i = ${#moved_to[@]}; i >= 1; i-- )); do
      if [[ -d "${moved_to[$i]}" && ! -e "${moved_from[$i]}" ]]; then
        mv "${moved_to[$i]}" "${moved_from[$i]}"
        print -u2 "restored ${moved_from[$i]} after failed installation"
      fi
    done
  fi
  exit "$exit_status"
}
trap rollback EXIT INT TERM

[[ -d "$source_app" ]] || {
  print -u2 "error: build not found: $source_app"
  exit 1
}
source_info="$source_app/Contents/Info.plist"
[[ -f "$source_info" ]] || {
  print -u2 "error: source bundle has no Info.plist"
  exit 1
}

bundle_identifier="$(bundle_id_of "$source_app")"
source_revision="$(plutil -extract BestASRBuildRevision raw -o - "$source_info" 2>/dev/null || true)"
if [[ "$bundle_identifier" != "$product_id" ]]; then
  print -u2 "error: refusing non-Release bundle identifier: ${bundle_identifier:-missing}"
  exit 1
fi
if [[ -z "$source_revision" || "$source_revision" == "uncommitted" || "$source_revision" == "unidentified" ]]; then
  print -u2 "error: refusing bundle without an immutable build revision"
  exit 1
fi
if [[ "$source_revision" != "$expected_revision" ]]; then
  print -u2 "error: source revision $source_revision does not match expected $expected_revision"
  exit 1
fi
codesign --verify --deep --strict "$source_app"
source_authority="$(codesign -dv --verbose=4 "$source_app" 2>&1 \
  | awk '/^Authority=/{if (!found) {sub(/^Authority=/, ""); value=$0; found=1}} END{print value}')"
source_team_identifier="$(codesign -dv --verbose=4 "$source_app" 2>&1 \
  | awk '/^TeamIdentifier=/{sub(/^TeamIdentifier=/, ""); value=$0} END{print value}')"
if [[ "$allow_ad_hoc" != true ]]; then
  if [[ "$source_authority" != Apple\ Development:* \
    || -z "$source_team_identifier" || "$source_team_identifier" == "not set" ]]; then
    print -u2 "error: refusing an ad-hoc or unstable Release signing identity"
    exit 1
  fi
fi

if [[ -e "$destination_app" && "$(bundle_id_of "$destination_app")" != "$product_id" ]]; then
  print -u2 "error: $destination_app is another App ($(bundle_id_of "$destination_app")); move it aside first"
  print -u2 "       (the switch script mindloom-switch.sh keeps Mindloom Preview in its backup folder)"
  exit 1
fi

mkdir -p "$applications_dir" "$backup_dir"
remove_tree "$staging_app"
ditto "$source_app" "$staging_app"
codesign --verify --deep --strict "$staging_app"
staging_designated_requirement="$(codesign -dr - "$staging_app" 2>&1 \
  | awk '/^designated =>/{value=$0} END{print value}')"
source_designated_requirement="$(codesign -dr - "$source_app" 2>&1 \
  | awk '/^designated =>/{value=$0} END{print value}')"
if [[ "$staging_designated_requirement" != "$source_designated_requirement" ]]; then
  print -u2 "error: staged app signing identity changed during copy"
  exit 1
fi

if ! quit_product; then
  print -u2 "error: the installed app did not quit; nothing was replaced (quit it from its menu and retry)"
  exit 1
fi

# Every installed copy goes to the backup folder, unregistered first.
n=0
for copy in ${(f)"$(installed_copies)"}; do
  [[ -n "$copy" && -d "$copy" ]] || continue
  n=$(( n + 1 ))
  backup_app="$backup_dir/Mindloom-backup-$timestamp-$$-$n.rollback"
  "$lsregister" -u "$copy" >/dev/null 2>&1 || true
  mv "$copy" "$backup_app"
  moved_from+=("$copy")
  moved_to+=("$backup_app")
done
[[ ! -e "$destination_app" ]] || {
  print -u2 "error: $destination_app is still there after the backup"
  exit 1
}
mv "$staging_app" "$destination_app"

installed_info="$destination_app/Contents/Info.plist"
installed_revision="$(plutil -extract BestASRBuildRevision raw -o - "$installed_info")"
installed_identifier="$(bundle_id_of "$destination_app")"
codesign --verify --deep --strict "$destination_app"
if [[ "$installed_identifier" != "$product_id" || "$installed_revision" != "$expected_revision" ]]; then
  print -u2 "error: installed bundle identity does not match the verified source"
  exit 1
fi

if [[ "$launch_after_install" == true ]]; then
  open "$destination_app"
  for _ in {1..50}; do
    (( $(running_count) > 0 )) && break
    sleep 0.1
  done
  if (( $(running_count) == 0 )); then
    print -u2 "error: installed app did not launch from the standard location"
    exit 1
  fi
fi

install_succeeded=1
trap - EXIT INT TERM
prune_generated_rollbacks() {
  local keep_count=2
  local count excess target
  count="$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
    -name 'Mindloom-backup-*.rollback' | wc -l | tr -d ' ')"
  (( count > keep_count )) || return 0
  excess=$(( count - keep_count ))
  while IFS= read -r target; do
    [[ "$target:h" == "$backup_dir" \
      && "$target:t" == Mindloom-backup-*.rollback ]] || {
      print -u2 "warning: refused unexpected rollback cleanup target"
      return 1
    }
    remove_tree "$target"
  done < <(
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
      -name 'Mindloom-backup-*.rollback' | sort | head -n "$excess"
  )
}
prune_generated_rollbacks ||
  print -u2 "warning: installed successfully but old rollback cleanup was incomplete"
if [[ "$source_app" == "$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/$MINDLOOM_APP_NAME" ]]; then
  "$repository_root/script/unregister_build_app.sh" --hide-product "$source_app"
fi
print "installed: $destination_app"
print "revision: $installed_revision"
for backup_app in "${moved_to[@]}"; do
  print "backup: $backup_app"
done
