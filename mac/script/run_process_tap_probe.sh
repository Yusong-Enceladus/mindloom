#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
derived_data_path="$BESTASR_XCODE_DERIVED_DATA"
summary_path="$repository_root/artifacts/evidence/SPIKE-CAP-001/summary.json"
matrix_path="$repository_root/artifacts/evidence/SPIKE-CAP-001/matrix.json"
allow_output_device_switch=0
tcc_denial_evidence=""

while (( $# > 0 )); do
  case "$1" in
    --derived-data)
      derived_data_path="$2"
      shift 2
      ;;
    --summary)
      summary_path="$2"
      shift 2
      ;;
    --matrix)
      matrix_path="$2"
      shift 2
      ;;
    --allow-output-device-switch)
      allow_output_device_switch=1
      shift
      ;;
    --tcc-denial-evidence)
      tcc_denial_evidence="$2"
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
  -scheme ProcessTapProbe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  build

products_path="$derived_data_path/Build/Products/Debug"
probe_path="$products_path/ProcessTapProbe.app/Contents/MacOS/ProcessTapProbe"
selected_player_path="$products_path/SelectedWatermarkPlayer.app/Contents/MacOS/SelectedWatermarkPlayer"
nonselected_player_path="$products_path/NonselectedWatermarkPlayer.app/Contents/MacOS/NonselectedWatermarkPlayer"

for executable_path in "$probe_path" "$selected_player_path" "$nonselected_player_path"; do
  if [[ ! -x "$executable_path" ]]; then
    print -u2 "error: expected executable is missing: $executable_path"
    exit 2
  fi
done

probe_arguments=(
  --selected-player "$selected_player_path"
  --nonselected-player "$nonselected_player_path"
  --summary "$summary_path"
  --matrix "$matrix_path"
)
if (( allow_output_device_switch == 1 )); then
  probe_arguments+=(--allow-output-device-switch)
fi
if [[ -n "$tcc_denial_evidence" ]]; then
  if [[ ! -f "$tcc_denial_evidence" ]]; then
    print -u2 "error: TCC denial evidence is missing: $tcc_denial_evidence"
    exit 2
  fi
  probe_arguments+=(--tcc-denial-evidence "$tcc_denial_evidence")
fi

"$probe_path" "${probe_arguments[@]}"
