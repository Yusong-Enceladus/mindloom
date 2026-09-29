#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"

source_app="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app"
applications_dir="$HOME/Applications"
backup_dir="$BESTASR_BUILD_ROOT/installation-backups"
expected_revision="$(git -C "$repository_root" rev-parse HEAD)"
launch_after_install=true
positional_source_seen=false
allow_ad_hoc=false

while (( $# > 0 )); do
  case "$1" in
    --source) source_app="$2"; shift 2 ;;
    --applications-dir) applications_dir="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --expected-revision) expected_revision="$2"; shift 2 ;;
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

destination_app="$applications_dir/bestASR.app"
destination_executable="$destination_app/Contents/MacOS/bestASR"
timestamp="$(date +%Y%m%d-%H%M%S)"
# Keep the previous signed bundle byte-for-byte recoverable without giving it
# an .app extension. Mounted .app backups are registered by LaunchServices and
# appear as separate TCC permission targets, which can make macOS show or grant
# permissions for an old test copy instead of the single installed product.
backup_app="$backup_dir/bestASR-backup-$timestamp-$$.rollback"
staging_app="$applications_dir/.bestASR-installing-$timestamp-$$.app"
destination_moved=0
install_succeeded=0

remove_tree() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  find "$target" -depth -delete
}

prune_generated_rollbacks() {
  local keep_count=2
  local count excess target
  count="$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
    -name 'bestASR-backup-*.rollback' | wc -l | tr -d ' ')"
  (( count > keep_count )) || return 0
  excess=$(( count - keep_count ))
  while IFS= read -r target; do
    [[ "$target:h" == "$backup_dir" \
      && "$target:t" == bestASR-backup-*.rollback ]] || {
      print -u2 "warning: refused unexpected rollback cleanup target"
      return 1
    }
    remove_tree "$target"
  done < <(
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
      -name 'bestASR-backup-*.rollback' | sort | head -n "$excess"
  )
}

rollback() {
  local exit_status=$?
  if (( install_succeeded == 0 )); then
    remove_tree "$staging_app"
    if (( destination_moved == 1 )) && [[ -d "$backup_app" ]]; then
      remove_tree "$destination_app"
      mv "$backup_app" "$destination_app"
      print -u2 "restored previous app after failed installation"
    fi
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

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$source_info" 2>/dev/null || true)"
source_revision="$(plutil -extract BestASRBuildRevision raw -o - "$source_info" 2>/dev/null || true)"
if [[ "$bundle_identifier" != "com.bestasr.app" ]]; then
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

if [[ -x "$destination_executable" ]]; then
  running_pid_lines="$(ps -axo pid=,command= | awk -v executable="$destination_executable" '$2 == executable {print $1}')"
  if [[ -n "$running_pid_lines" ]]; then
    while IFS= read -r running_pid; do
      kill -TERM "$running_pid"
    done <<< "$running_pid_lines"
    for _ in {1..50}; do
      still_running="$(ps -axo command= | awk -v executable="$destination_executable" '$1 == executable {found=1} END {if (found) print executable}')"
      [[ -z "$still_running" ]] && break
      sleep 0.1
    done
    still_running="$(ps -axo command= | awk -v executable="$destination_executable" '$1 == executable {found=1} END {if (found) print executable}')"
    if [[ -n "$still_running" ]]; then
      print -u2 "error: installed app did not exit; existing bundle was left untouched"
      exit 1
    fi
  fi
fi

# App replacement does not migrate runtime caches. Cache relocation remains
# an explicit, separate operation through configure_runtime_cache.sh.

if [[ -d "$destination_app" ]]; then
  mv "$destination_app" "$backup_app"
  destination_moved=1
fi
mv "$staging_app" "$destination_app"

installed_info="$destination_app/Contents/Info.plist"
installed_revision="$(plutil -extract BestASRBuildRevision raw -o - "$installed_info")"
installed_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$installed_info")"
codesign --verify --deep --strict "$destination_app"
if [[ "$installed_identifier" != "com.bestasr.app" || "$installed_revision" != "$expected_revision" ]]; then
  print -u2 "error: installed bundle identity does not match the verified source"
  exit 1
fi

if [[ "$launch_after_install" == true ]]; then
  open "$destination_app"
  for _ in {1..50}; do
    running="$(ps -axo command= | awk -v executable="$destination_executable" '$1 == executable {found=1} END {if (found) print executable}')"
    [[ -n "$running" ]] && break
    sleep 0.1
  done
  if [[ -z "${running:-}" ]]; then
    print -u2 "error: installed app did not launch from the standard location"
    exit 1
  fi
fi

install_succeeded=1
trap - EXIT INT TERM
prune_generated_rollbacks ||
  print -u2 "warning: installed successfully but old rollback cleanup was incomplete"
if [[ "$source_app" == "$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app" ]]; then
  "$repository_root/script/unregister_build_app.sh" --hide-product "$source_app"
fi
print "installed: $destination_app"
print "revision: $installed_revision"
if [[ -d "$backup_app" ]]; then
  print "backup: $backup_app"
fi
