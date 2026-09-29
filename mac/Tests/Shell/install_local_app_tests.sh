#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
source "$repository_root/script/build_storage.sh"
test_root="$(mktemp -d "$BESTASR_BUILD_TMP/install-local-app.XXXXXX")"
source_app="$test_root/source/bestASR.app"
applications_dir="$test_root/Applications"
backup_dir="$test_root/installation-backups"
expected_revision="$(git -C "$repository_root" rev-parse HEAD)"
# Inspect metadata only: installation must not create, remove, or repoint the
# user's existing cache, including a link to a different build volume. All App
# and backup writes below remain inside the temporary fixture directories.
cache_link="$HOME/Library/Caches/com.bestasr.app"
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

mkdir -p "$source_app/Contents/MacOS" "$applications_dir/bestASR.app/Contents"
cp "$repository_root/App/Info.plist" "$source_app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.bestasr.app "$source_app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string bestASR "$source_app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.1.0 "$source_app/Contents/Info.plist"
plutil -replace CFBundleVersion -string 2 "$source_app/Contents/Info.plist"
plutil -replace BestASRBuildRevision -string "$expected_revision" "$source_app/Contents/Info.plist"
cp /usr/bin/true "$source_app/Contents/MacOS/bestASR"
chmod +x "$source_app/Contents/MacOS/bestASR"
codesign --force --deep --sign - "$source_app" >/dev/null

print "old installation" > "$applications_dir/bestASR.app/Contents/marker.txt"
"$repository_root/script/install_local_app.sh" \
  --source "$source_app" \
  --applications-dir "$applications_dir" \
  --backup-dir "$backup_dir" \
  --expected-revision "$expected_revision" \
  --allow-ad-hoc-for-tests \
  --no-launch >/dev/null
[[ "$(cache_link_state)" == "$original_cache_state" ]]

installed_revision="$(plutil -extract BestASRBuildRevision raw -o - "$applications_dir/bestASR.app/Contents/Info.plist")"
[[ "$installed_revision" == "$expected_revision" ]]
backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name 'bestASR-backup-*.rollback' | wc -l | tr -d ' ')"
[[ "$backup_count" == "1" ]]
registerable_backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$registerable_backup_count" == "0" ]]
visible_backup_count="$(find "$applications_dir" -maxdepth 1 -type d -name 'bestASR-backup-*.app' | wc -l | tr -d ' ')"
[[ "$visible_backup_count" == "0" ]]

for suffix in 20200101-000001-1 20200101-000002-2 20200101-000003-3; do
  mkdir -p "$backup_dir/bestASR-backup-$suffix.rollback/Contents"
done
"$repository_root/script/install_local_app.sh" \
  --source "$source_app" \
  --applications-dir "$applications_dir" \
  --backup-dir "$backup_dir" \
  --expected-revision "$expected_revision" \
  --allow-ad-hoc-for-tests \
  --no-launch >/dev/null
[[ "$(cache_link_state)" == "$original_cache_state" ]]
retained_rollback_count="$(find "$backup_dir" -maxdepth 1 -type d -name 'bestASR-backup-*.rollback' | wc -l | tr -d ' ')"
[[ "$retained_rollback_count" == "2" ]]
registerable_backup_count="$(find "$backup_dir" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$registerable_backup_count" == "0" ]]

plutil -replace CFBundleIdentifier -string com.bestasr.app.debug "$source_app/Contents/Info.plist"
codesign --force --deep --sign - "$source_app" >/dev/null
if "$repository_root/script/install_local_app.sh" \
  --source "$source_app" \
  --applications-dir "$applications_dir" \
  --backup-dir "$backup_dir" \
  --expected-revision "$expected_revision" \
  --allow-ad-hoc-for-tests \
  --no-launch >/dev/null 2>&1
then
  print -u2 "error: installer accepted a Debug bundle"
  exit 1
fi

[[ "$(cache_link_state)" == "$original_cache_state" ]]
print "install local app tests passed (existing runtime cache preserved)"
