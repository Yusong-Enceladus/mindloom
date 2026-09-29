#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
derived_data_path="$BESTASR_XCODE_DERIVED_DATA"

while (( $# > 0 )); do
  case "$1" in
    --derived-data)
      derived_data_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

xcodebuild \
  -workspace "$repository_root/BestASR.xcworkspace" \
  -scheme ProcessTapTCCDenialProbe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  build

app_path="$derived_data_path/Build/Products/Debug/ProcessTapTCCDenialProbeV2.app"
player_path="$derived_data_path/Build/Products/Debug/SelectedWatermarkPlayer.app"

for bundle_path in "$app_path" "$player_path"; do
  if [[ ! -d "$bundle_path" ]]; then
    print -u2 "error: expected app bundle is missing: $bundle_path"
    exit 2
  fi
  /usr/bin/codesign --verify --strict "$bundle_path"
done

actual_bundle_id="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app_path/Contents/Info.plist"
)"
expected_bundle_id="com.bestasr.spike.process-tap-tcc-denial-probe.v2"
if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
  print -u2 "error: denial probe bundle identifier mismatch"
  exit 2
fi

print -r -- "$app_path"
