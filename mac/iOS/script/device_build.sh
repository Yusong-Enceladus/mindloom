#!/bin/zsh
# Build of Mindloom for a physical iPhone (app, keyboard, share, Live Activity, and the Apple Watch
# app with its complication), signed by PHONE_TEAM with Xcode's automatic signing. It is not
# installed.
#
#   PHONE_TEAM=<team id> [PHONE_DEVICE=<udid>] [PHONE_CONFIGURATION=Release|Debug] [PHONE_JOBS=4] \
#     [PHONE_BUILD_ROOT=…] [PHONE_BUNDLE_ID=app.mindloom] [PHONE_APP_GROUP=group.<bundle id>] \
#     [PHONE_WATCH=NO] iOS/script/device_build.sh
#
# The watch app is <bundle id>.watchkitapp and its complication <bundle id>.watchkitapp.widgets;
# automatic signing makes their App IDs and profiles like the iPhone's. PHONE_WATCH=NO builds the
# iPhone app without them (iOS/project-nowatch.yml → MindloomPhoneNoWatch.xcodeproj, generated,
# not committed); mode keychain-nowidget never has them.
#
# The team id is passed here and never committed. Read the paid team's from Xcode:
#   defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier \
#     | awk '/isFreeProvisioningTeam = 0/{f=1} f && /teamID/{gsub(/[ ;"]/,""); split($0,a,"="); print a[2]; exit}'
# PHONE_BUNDLE_ID / PHONE_APP_GROUP override the identity in iOS/project.yml
# (MINDLOOM_PHONE_BUNDLE_ID, MINDLOOM_APP_GROUP); the extensions and keychain groups follow it.
# With PHONE_DEVICE the build targets that phone and registers it with the team
# (-allowProvisioningDeviceRegistration), so the profiles include it.
#
# Release by default: the build people use has no DEBUG hooks (screenshot states, scripted
# recognizer, audio-file input, the voice bench). PHONE_CONFIGURATION=Debug only for the bench
# (iOS/script/device_voice_bench.py needs -MindloomVoiceFile).
#
# It tries, in order, and keeps the first that signs:
#   1. app-group   every target with its own entitlements (the App Group) and the Live Activity
#                  widget. Needs profiles with the group and an Apple ID signed in (Xcode › Settings ›
#                  Accounts); -allowProvisioningUpdates then makes or renews the profiles. The first
#                  launch with the group moves the old private data into it (PhoneStorageMigration).
#   2. keychain    each target signed with its iOS/DeviceTest-*.entitlements (keychain groups, no
#                  App Group) and the widget. The app picks the keychain link at run time.
#   3. keychain-nowidget   as 2, without the widget (its App ID <bundle id>.live needs a
#                  profile too), from iOS/project-nowidget.yml (MindloomPhoneNoWidget.xcodeproj,
#                  generated, not committed).
# PHONE_DEVICE_MODE=<one of the above> forces one. The chosen mode is written to
# $PHONE_BUILD_ROOT/mode. The app lands in $PHONE_BUILD_ROOT/xcode/Build/Products/<configuration>-iphoneos/.
# Install with iOS/script/device_install.sh (over the app, never uninstalling; it records the mode).
#
# No silent downgrade: once a phone has run an app-group build, its pairing, items and outbox are
# in the App Group container, which a keychain build cannot reach (the app then says so on Home and
# sends nothing that waits there). So modes 2 and 3 are refused when device_install.sh recorded an
# app-group install for PHONE_DEVICE (or in this build root), or when PHONE_DEVICE (the phone's
# UDID, connected) has the app's migration marker (its data moved into the App Group).
# PHONE_ALLOW_DOWNGRADE=1 overrides it.

set -uo pipefail

ios_root="$(cd "$(dirname "$0")/.." && pwd)"
team="${PHONE_TEAM:?signing team id}"
jobs="${PHONE_JOBS:-6}"
configuration="${PHONE_CONFIGURATION:-Release}"
bundle_id="${PHONE_BUNDLE_ID:-app.mindloom}"
identity=(MINDLOOM_PHONE_BUNDLE_ID="$bundle_id")
[[ -n "${PHONE_APP_GROUP:-}" ]] && identity+=(MINDLOOM_APP_GROUP="$PHONE_APP_GROUP")
destination=(-destination "generic/platform=iOS")
[[ -n "${PHONE_DEVICE:-}" ]] && destination=(-destination "id=$PHONE_DEVICE" -allowProvisioningDeviceRegistration)

build_root="${PHONE_BUILD_ROOT:-/Volumes/<build-volume>/ios-build/device}"
volume="/Volumes/$(print -r -- "$build_root" | /usr/bin/cut -d/ -f3)"
if [[ ! -d "$volume" ]] || ! /sbin/mount | /usr/bin/grep -Fq " on $volume ("; then
  print -u2 "error: build volume $volume is not mounted; refusing to fall back to the system disk"
  exit 72
fi

export TMPDIR="$build_root/tmp"
/bin/mkdir -p "$build_root/xcode" "$build_root/xcode-packages" "$build_root/xcode-package-cache" "$TMPDIR"

attempt() {
  local mode=$1 project=$2; shift 2
  print "== device build: $mode"
  /usr/bin/xcodebuild build \
    -project "$project" \
    -scheme MindloomPhone \
    -configuration "$configuration" \
    "${destination[@]}" \
    -derivedDataPath "$build_root/xcode" \
    -clonedSourcePackagesDirPath "$build_root/xcode-packages" \
    -packageCachePath "$build_root/xcode-package-cache" \
    -jobs "$jobs" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_STYLE=Automatic \
    "${identity[@]}" \
    "$@" && print -r -- "$mode" > "$build_root/mode"
}

project="$ios_root/MindloomPhone.xcodeproj"
if [[ "${PHONE_WATCH:-YES}" == NO ]]; then
  (cd "$ios_root" && env -u PHONE_WATCH PHONE_WIDGETS=YES xcodegen --spec project-nowatch.yml --quiet) || exit 1
  project="$ios_root/MindloomPhoneNoWatch.xcodeproj"
fi
# Without the App Group each target gets its own keychain groups (the keyboard never sees the
# phone's SSH key or the share extension's copy of it).
fallback=(
  MINDLOOM_ENTITLEMENTS_APP="$ios_root/DeviceTest-App.entitlements"
  MINDLOOM_ENTITLEMENTS_KEYBOARD="$ios_root/DeviceTest-Keyboard.entitlements"
  MINDLOOM_ENTITLEMENTS_SHARE="$ios_root/DeviceTest-Share.entitlements"
)
# True when the phone already keeps its data in the App Group (see the header).
group_in_use() {
  local marker
  for marker in "$build_root/installed-mode-$bundle_id" \
    ${PHONE_DEVICE:+"$HOME/Library/Developer/MindloomPhone/installed-mode-$PHONE_DEVICE-$bundle_id"}; do
    if [[ -f "$marker" && "$(<"$marker")" == app-group ]]; then
      print -u2 "($marker says app-group)"
      return 0
    fi
  done
  # devicectl lists only Library, Documents and tmp of an App Group container, never the group's
  # pairing.json, items/ or outbox/. The app's migration marker, in its own container, says the
  # data went into the group (a build without the group removes the marker again).
  if [[ -n "${PHONE_DEVICE:-}" ]] && /usr/bin/xcrun devicectl device info files --device "$PHONE_DEVICE" \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --subdirectory "Library/Application Support" 2>/dev/null \
    | /usr/bin/grep -Eq '^app-group-migration\.json '; then
    print -u2 "($bundle_id on the phone moved its data into its App Group)"
    return 0
  fi
  return 1
}

# Succeeds (and explains) when a build without the App Group must not be made.
refuse_downgrade() {
  [[ "${PHONE_ALLOW_DOWNGRADE:-0}" == 1 ]] && return 1
  group_in_use || return 1
  print -u2 "error: the app-group build did not sign, and this phone keeps its data in the App Group;"
  print -u2 "       a $1 build could not reach it. Fix the App Group signing (Xcode > Signing &"
  print -u2 "       Capabilities > App Groups), or set PHONE_ALLOW_DOWNGRADE=1 to build $1 anyway."
  return 0
}

modes=(app-group keychain keychain-nowidget)
[[ -n "${PHONE_DEVICE_MODE:-}" ]] && modes=("$PHONE_DEVICE_MODE")

for mode in $modes; do
  case $mode in
    app-group) attempt app-group "$project" "$@" && exit 0 ;;
    keychain)
      refuse_downgrade keychain && exit 66
      attempt keychain "$project" "${fallback[@]}" "$@" && exit 0 ;;
    keychain-nowidget)
      refuse_downgrade keychain-nowidget && exit 66
      # iOS/project-nowidget.yml includes project.yml without the widget include.
      (cd "$ios_root" && env -u PHONE_WIDGETS xcodegen --spec project-nowidget.yml --quiet) || exit 1
      attempt keychain-nowidget "$ios_root/MindloomPhoneNoWidget.xcodeproj" "${fallback[@]}" "$@" && exit 0 ;;
    *) print -u2 "error: unknown PHONE_DEVICE_MODE $mode"; exit 64 ;;
  esac
done
print -u2 "error: no signing mode worked"
exit 65
