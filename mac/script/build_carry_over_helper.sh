#!/bin/zsh
# Builds the switch's one-shot keychain helper (mindloom-carry-over, 2026-10-06) and wraps it in a
# small bundle signed with bestASR's identifier and the paid team's Apple Development certificate,
# so it satisfies the access lists of the login-keychain items bestASR's builds made and hands
# them to Mindloom without a password prompt (Packages/BestASRCore/Sources/MindloomCarryOverHelper).
#
#   script/build_carry_over_helper.sh <output folder> [<signing identifier>] [<bundle name>]
#
# The identifier defaults to bestASR's (com.bestasr.app, script/identity.sh); the switch's dry run
# passes a check identity (com.bestasr.mindloom.check.*), which the helper hands over only to
# another check identity. Signed as Mindloom (app.mindloom) it is the rollback's login-item helper:
# `--unregister-login-item` turns Mindloom's 「登录时打开」 off (review of 10-6); build it as
# mindloom-login-item.app. The bundle is <output folder>/<bundle name> (default
# mindloom-carry-over.app), never registered with LaunchServices. Prints its designated
# requirement. The team is passed at build time (script/signing_team.sh) and never written into
# the repository.
set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"
source "$repository_root/script/identity.sh"

(( $# >= 1 && $# <= 3 )) || {
  print -u2 "usage: $0 <output folder> [<signing identifier>] [<bundle name>]"
  exit 64
}
output="${1:A}"
identifier="${2:-$MINDLOOM_PREVIOUS_BUNDLE_ID}"
bundle_name="${3:-mindloom-carry-over.app}"
[[ "$identifier" =~ '^[A-Za-z0-9.-]+$' ]] || { print -u2 "error: invalid identifier"; exit 64; }
[[ "$bundle_name" =~ '^[A-Za-z0-9.-]+\.app$' ]] || { print -u2 "error: invalid bundle name"; exit 64; }
case "$identifier" in
  "$MINDLOOM_PREVIOUS_BUNDLE_ID"|"$MINDLOOM_BUNDLE_ID"|com.bestasr.mindloom.check.*) ;;
  *) print -u2 "error: the helper is signed as bestASR, Mindloom or a check identity only"; exit 64 ;;
esac

signing_team="$("$repository_root/script/signing_team.sh")"
development_identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development:/{if (!found) {value=$2; found=1}} END{print value}')"
[[ -n "$development_identity" ]] || { print -u2 "error: no Apple Development identity"; exit 1; }

SWIFTPM_MODULECACHE_OVERRIDE="$BESTASR_SWIFTPM_MODULE_CACHE" \
  CLANG_MODULE_CACHE_PATH="$BESTASR_CLANG_MODULE_CACHE" \
  swift build -c release --product mindloom-carry-over \
    --package-path "$repository_root/Packages/BestASRCore" \
    --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" >&2
binary="$(swift build -c release --show-bin-path \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE")/mindloom-carry-over"
[[ -x "$binary" ]] || { print -u2 "error: $binary was not built"; exit 70; }

bundle="$output/$bundle_name"
mkdir -p "$output"
[[ -e "$bundle" ]] && find "$bundle" -depth -delete
mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/mindloom-carry-over"
plist="$bundle/Contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string "$identifier" "$plist"
plutil -insert CFBundleExecutable -string mindloom-carry-over "$plist"
plutil -insert CFBundleName -string "mindloom-carry-over" "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
plutil -insert CFBundleShortVersionString -string 1.0 "$plist"
plutil -insert CFBundleVersion -string 1 "$plist"
plutil -insert LSUIElement -bool YES "$plist"
plutil -insert LSBackgroundOnly -bool YES "$plist"
plutil -insert BestASRBuildRevision -string "$(git -C "$repository_root" rev-parse HEAD)" "$plist"

codesign --force --sign "$development_identity" --identifier "$identifier" --options runtime \
  "$bundle" >/dev/null
codesign --verify --strict "$bundle"
team="$(codesign -dv --verbose=4 "$bundle" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
[[ "$team" == "$signing_team" ]] || { print -u2 "error: the helper is signed by another team"; exit 70; }
requirement="$(codesign -d -r- "$bundle" 2>&1 | awk '/^designated =>/{value=$0} END{print value}')"
[[ "$requirement" == "designated => identifier \"$identifier\" and "* ]] || {
  print -u2 "error: the helper's designated requirement does not name $identifier"
  exit 70
}
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$bundle" >/dev/null 2>&1 || true
print -r -- "helper: $bundle"
print -r -- "$requirement"
