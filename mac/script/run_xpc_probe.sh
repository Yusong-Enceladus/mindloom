#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
derived_data_path="$BESTASR_XCODE_DERIVED_DATA"

xcodebuild \
  -workspace "$repository_root/BestASR.xcworkspace" \
  -scheme InferenceXPCProbe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  build

probe_path="$derived_data_path/Build/Products/Debug/InferenceXPCProbe.app/Contents/MacOS/InferenceXPCProbe"
if [[ ! -x "$probe_path" ]]; then
  print -u2 "error: expected XPC probe is missing: $probe_path"
  exit 2
fi

"$probe_path" \
  --summary "$repository_root/artifacts/evidence/SPIKE-XPC-001/summary.json" \
  --matrix "$repository_root/artifacts/evidence/SPIKE-XPC-001/matrix.json"
