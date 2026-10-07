#!/bin/zsh
# Installs the build from iOS/script/device_build.sh on the phone, over the app that is there.
# Never uninstalls first: that would delete the phone's pairing, items and outbox.
#
#   PHONE_DEVICE=<udid> [PHONE_CONFIGURATION=Release|Debug] [PHONE_BUILD_ROOT=…] \
#     iOS/script/device_install.sh
#
# Records the installed mode in $PHONE_BUILD_ROOT/installed-mode-<bundle id> and
# ~/Library/Developer/MindloomPhone/installed-mode-<udid>-<bundle id>, which device_build.sh reads to
# refuse a silent fall back to a build without the App Group. The bundle id is the built app's.
#
# Before an app-group install it counts (file names only) what the share extension of a keychain
# build still holds unsent in its own container: those parts move into the group, and are sent,
# the next time something is shared. It warns and does not refuse (an expiring signature must
# still be renewable).

set -uo pipefail

device="${PHONE_DEVICE:?the phone's UDID}"
configuration="${PHONE_CONFIGURATION:-Release}"
build_root="${PHONE_BUILD_ROOT:-/Volumes/<build-volume>/ios-build/device}"
app="$build_root/xcode/Build/Products/$configuration-iphoneos/MindloomPhone.app"
if [[ ! -d "$app" || ! -f "$build_root/mode" ]]; then
  print -u2 "error: no build at $app (run device_build.sh)"
  exit 66
fi
mode="$(<"$build_root/mode")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" || exit 66

if [[ "$mode" == app-group ]]; then
  waiting=$(/usr/bin/xcrun devicectl device info files --device "$device" \
    --domain-type appDataContainer --domain-identifier "$bundle_id.share" \
    --subdirectory "Library/Application Support/share/outbox" 2>/dev/null \
    | /usr/bin/grep -Ec '^(queued|held)/[^ ]')
  if (( waiting > 0 )); then
    print -u2 "warning: the share extension still holds $waiting unsent part(s) in its own container."
    print -u2 "         They move into the App Group (and are sent) the next time something is shared;"
    print -u2 "         share something once after this install so they leave."
  fi
fi

/usr/bin/xcrun devicectl device install app --device "$device" "$app" || exit $?
print -r -- "$mode" > "$build_root/installed-mode-$bundle_id"
/bin/mkdir -p "$HOME/Library/Developer/MindloomPhone"
print -r -- "$mode" > "$HOME/Library/Developer/MindloomPhone/installed-mode-$device-$bundle_id"
print "installed $bundle_id $mode ($configuration) on $device"
