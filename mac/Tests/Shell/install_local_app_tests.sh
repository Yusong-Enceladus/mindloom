#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
source "$repository_root/script/build_storage.sh"
test_root="$(mktemp -d "$BESTASR_BUILD_TMP/install-local-app.XXXXXX")"
source_app="$test_root/source/Mindloom.app"
applications_dir="$test_root/Applications"
backup_dir="$test_root/installation-backups"
expected_revision="$(git -C "$repository_root" rev-parse HEAD)"
# A bundle id of this run's own: LaunchServices knows no copy of it, and no App running
# on this Mac carries it, so the installer never finds or quits anything outside the
# fixture (the real product's id is app.mindloom).
product_id="com.bestasr.test.install.$$"
# Inspect metadata only: installation must not create, remove, or repoint the
# user's existing cache, including a link to a different build volume. All App
# and backup writes below remain inside the temporary fixture directories.
cache_link="$HOME/Library/Caches/app.mindloom"
cache_link_state() {
  if [[ -L "$cache_link" ]]; then
    print -r -- "symlink:$(readlink "$cache_link")"
  elif [[ -e "$cache_link" ]]; then
    stat -f 'existing:%d:%i:%m' "$cache_link"
  else
    print missing
  fi
}
original_cache_state="$(cache_link_state)"

cleanup() {
  [[ -d "$test_root" ]] && find "$test_root" -depth -delete
}
trap cleanup EXIT

stub_app() {
  local app="$1" id="$2"
  mkdir -p "$app/Contents/MacOS"
  cp "$repository_root/App/Info.plist" "$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$id" "$app/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string Mindloom "$app/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string 0.2.0 "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string 3 "$app/Contents/Info.plist"
  plutil -replace BestASRBuildRevision -string "$expected_revision" "$app/Contents/Info.plist"
  cp /usr/bin/true "$app/Contents/MacOS/Mindloom"
  chmod +x "$app/Contents/MacOS/Mindloom"
  codesign --force --deep --sign - "$app" >/dev/null
}

install() {
  "$repository_root/script/install_local_app.sh" \
    --source "$source_app" \
    --applications-dir "$applications_dir" \
    --backup-dir "$backup_dir" \
    --expected-revision "$expected_revision" \
    --product-id "$product_id" \
    --allow-ad-hoc-for-tests \
    --no-launch "$@"
}

stub_app "$source_app" "$product_id"

# bestASR (another bundle id) is not this installer's: it stays where it is.
stub_app "$applications_dir/bestASR.app" "com.bestasr.test.install-old.$$"
# An installed Mindloom.app is replaced and kept as a rollback copy.
stub_app "$applications_dir/Mindloom.app" "$product_id"
print "old installation" > "$applications_dir/Mindloom.app/Contents/marker.txt"
install >/dev/null
[[ "$(cache_link_state)" == "$original_cache_state" ]]
[[ -d "$applications_dir/bestASR.app" ]]
[[ ! -e "$applications_dir/Mindloom.app/Contents/marker.txt" ]]
installed_revision="$(plutil -extract BestASRBuildRevision raw -o - "$applications_dir/Mindloom.app/Contents/Info.plist")"
[[ "$installed_revision" == "$expected_revision" ]]
backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name 'Mindloom-backup-*.rollback' | wc -l | tr -d ' ')"
[[ "$backup_count" == "1" ]]
[[ -f "$(find "$backup_dir" -maxdepth 1 -type d -name 'Mindloom-backup-*.rollback')/Contents/marker.txt" ]]
registerable_backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$registerable_backup_count" == "0" ]]
visible_backup_count="$(find "$applications_dir" -maxdepth 1 -type d -name 'Mindloom-backup-*.app' | wc -l | tr -d ' ')"
[[ "$visible_backup_count" == "0" ]]

# Reinstalling over Mindloom.app keeps at most two generated rollbacks.
for suffix in 20200101-000001-1 20200101-000002-2 20200101-000003-3; do
  mkdir -p "$backup_dir/Mindloom-backup-$suffix.rollback/Contents"
done
install >/dev/null
[[ "$(cache_link_state)" == "$original_cache_state" ]]
[[ -d "$applications_dir/Mindloom.app" ]]
retained_rollback_count="$(find "$backup_dir" -maxdepth 1 -type d -name 'Mindloom-backup-*.rollback' | wc -l | tr -d ' ')"
[[ "$retained_rollback_count" == "2" ]]
registerable_backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$registerable_backup_count" == "0" ]]

# Another App at Mindloom.app (Mindloom Preview) is never replaced.
find "$applications_dir/Mindloom.app" -depth -delete
stub_app "$applications_dir/Mindloom.app" "com.bestasr.test.install-preview.$$"
if install >/dev/null 2>&1; then
  print -u2 "error: installer replaced another App at Mindloom.app"
  exit 1
fi
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$applications_dir/Mindloom.app/Contents/Info.plist")" == "com.bestasr.test.install-preview.$$" ]]
find "$applications_dir/Mindloom.app" -depth -delete

plutil -replace CFBundleIdentifier -string app.mindloom.debug "$source_app/Contents/Info.plist"
codesign --force --deep --sign - "$source_app" >/dev/null
if install >/dev/null 2>&1; then
  print -u2 "error: installer accepted a Debug bundle"
  exit 1
fi

[[ "$(cache_link_state)" == "$original_cache_state" ]]
print "install local app tests passed (existing runtime cache preserved)"
