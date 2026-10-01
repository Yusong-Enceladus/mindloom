#!/bin/zsh
# xcodebuild for the iPhone project with every product, package checkout and
# temporary file on the external build volume, six jobs, and the iOS 26.5
# simulator made for this project.
#
#   iOS/script/xcodebuild.sh build
#   iOS/script/xcodebuild.sh test
#   iOS/script/xcodebuild.sh test -only-testing:MindloomPhoneTests
#
# PHONE_BUILD_ROOT overrides /Volumes/<build-volume>/ios-build/phone;
# PHONE_SIMULATOR overrides the simulator name.

set -euo pipefail

ios_root="$(cd "$(dirname "$0")/.." && pwd)"
action="${1:?build or test}"
shift

build_root="${PHONE_BUILD_ROOT:-/Volumes/<build-volume>/ios-build/phone}"
volume="/Volumes/$(print -r -- "$build_root" | /usr/bin/cut -d/ -f3)"
if [[ ! -d "$volume" ]] || ! /sbin/mount | /usr/bin/grep -Fq " on $volume ("; then
  print -u2 "error: build volume $volume is not mounted; refusing to fall back to the system disk"
  exit 72
fi

simulator="${PHONE_SIMULATOR:-Mindloom Phone (iPhone 17)}"
if ! /usr/bin/xcrun simctl list devices | /usr/bin/grep -Fq "$simulator ("; then
  /usr/bin/xcrun simctl create "$simulator" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
    com.apple.CoreSimulator.SimRuntime.iOS-26-5 >/dev/null
fi

export TMPDIR="$build_root/tmp"
/bin/mkdir -p "$build_root/xcode" "$build_root/xcode-packages" "$build_root/xcode-package-cache" "$TMPDIR"

exec /usr/bin/xcodebuild "$action" \
  -project "$ios_root/MindloomPhone.xcodeproj" \
  -scheme MindloomPhone \
  -destination "platform=iOS Simulator,name=$simulator,OS=26.5" \
  -derivedDataPath "$build_root/xcode" \
  -clonedSourcePackagesDirPath "$build_root/xcode-packages" \
  -packageCachePath "$build_root/xcode-package-cache" \
  -jobs 6 \
  "$@"
