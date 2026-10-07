#!/bin/zsh
# xcodebuild for the iPhone project with every product, package checkout and
# temporary file on the external build volume, six jobs, and an iPhone 17 Pro
# simulator on the newest installed iOS runtime.
#
#   iOS/script/xcodebuild.sh build
#   iOS/script/xcodebuild.sh test
#   iOS/script/xcodebuild.sh test -only-testing:MindloomPhoneTests
#
# PHONE_BUILD_ROOT overrides /Volumes/<build-volume>/ios-build/phone;
# PHONE_SIMULATOR overrides the simulator name (default "iPhone 17 Pro");
# PHONE_SIMULATOR_OS overrides the OS of the destination (default "latest",
# the newest installed iOS runtime; "26.5" and the like pin one).

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

simulator="${PHONE_SIMULATOR:-iPhone 17 Pro}"
simulator_os="${PHONE_SIMULATOR_OS:-latest}"
if ! /usr/bin/xcrun simctl list devices | /usr/bin/grep -Fq "$simulator ("; then
  # Make it on the newest installed iOS runtime (or the pinned one).
  runtime="$(/usr/bin/xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
want = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and (want == "latest" or r.get("version", "").startswith(want))]
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".") if x.isdigit()])
print(runtimes[-1]["identifier"] if runtimes else "")
' "$simulator_os")"
  if [[ -z "$runtime" ]]; then
    print -u2 "error: no installed iOS simulator runtime matches OS=$simulator_os (xcrun simctl runtime list)"
    exit 69
  fi
  /usr/bin/xcrun simctl create "$simulator" \
    "com.apple.CoreSimulator.SimDeviceType.${simulator// /-}" "$runtime" >/dev/null
fi

export TMPDIR="$build_root/tmp"
/bin/mkdir -p "$build_root/xcode" "$build_root/xcode-packages" "$build_root/xcode-package-cache" "$TMPDIR"

exec /usr/bin/xcodebuild "$action" \
  -project "$ios_root/MindloomPhone.xcodeproj" \
  -scheme MindloomPhone \
  -destination "platform=iOS Simulator,name=$simulator,OS=$simulator_os" \
  -derivedDataPath "$build_root/xcode" \
  -clonedSourcePackagesDirPath "$build_root/xcode-packages" \
  -packageCachePath "$build_root/xcode-package-cache" \
  -jobs 6 \
  "$@"
