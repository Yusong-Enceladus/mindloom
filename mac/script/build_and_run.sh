#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
derived_data_path="$BESTASR_XCODE_DERIVED_DATA"
summary_path="$repository_root/artifacts/evidence/environment/build-and-run-summary.json"
run_mode="launch"

while (( $# > 0 )); do
  case "$1" in
    --smoke)
      run_mode="smoke"
      shift
      ;;
    --build-only)
      run_mode="build-only"
      shift
      ;;
    --derived-data)
      derived_data_path="$2"
      shift 2
      ;;
    --summary)
      summary_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

model_state_digest() {
  local state_temp_directory state_temp model_root
  state_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-model-state.XXXXXX")"
  state_temp="$state_temp_directory/state.txt"
  touch "$state_temp"
  for model_root in Models ModelCache; do
    if [[ -d "$repository_root/$model_root" ]]; then
      (
        cd "$repository_root"
        find "$model_root" -type f -exec stat -f '%N|%z|%m' {} \;
      ) >> "$state_temp"
    fi
  done
  /usr/bin/sort -o "$state_temp" "$state_temp"
  /usr/bin/shasum -a 256 "$state_temp" | /usr/bin/awk '{print $1}'
  rm -f "$state_temp"
  rmdir "$state_temp_directory"
}

model_state_before="$(model_state_digest)"
build_revision="$(git -C "$repository_root" rev-parse HEAD)"

xcodebuild \
  -workspace "$repository_root/BestASR.xcworkspace" \
  -scheme BestASR \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  BESTASR_GIT_REVISION="$build_revision" \
  build

model_state_after="$(model_state_digest)"
if [[ "$model_state_before" != "$model_state_after" ]]; then
  print -u2 "error: build changed model state; implicit model mutation is forbidden"
  exit 1
fi

app_path="$derived_data_path/Build/Products/Debug/bestASR.app"
app_executable="$app_path/Contents/MacOS/bestASR"
test -d "$app_path"
test -x "$app_executable"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")"
if [[ "$bundle_identifier" != "com.bestasr.app.debug" ]]; then
  print -u2 "error: unexpected bundle identifier: $bundle_identifier"
  exit 1
fi

process_launched=false
process_exit_kind="not-launched"
if [[ "$run_mode" == "smoke" ]]; then
  smoke_log="$BESTASR_BUILD_LOG_ROOT/build-and-run-smoke.log"
  "$app_executable" --smoke-run > "$smoke_log" 2>&1 &
  app_pid=$!
  trap 'if kill -0 "$app_pid" 2>/dev/null; then kill -TERM "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi' EXIT

  for _ in {1..50}; do
    if kill -0 "$app_pid" 2>/dev/null; then
      process_launched=true
      break
    fi
    sleep 0.1
  done
  if [[ "$process_launched" != "true" ]]; then
    print -u2 "error: built app did not remain alive for the smoke probe"
    exit 1
  fi

  kill -TERM "$app_pid"
  wait "$app_pid" 2>/dev/null || true
  process_exit_kind="terminated-after-health-check"
  trap - EXIT
elif [[ "$run_mode" == "launch" ]]; then
  open "$app_path"
  process_launched=true
  process_exit_kind="left-running-for-user"
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-build-run.XXXXXX")"
summary_temp="$summary_temp_directory/summary.json"
trap 'rm -f "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT

jq -n \
  --arg status "pass" \
  --arg configuration "Debug" \
  --arg bundleIdentifier "$bundle_identifier" \
  --arg runMode "$run_mode" \
  --argjson processLaunched "$process_launched" \
  --arg processExitKind "$process_exit_kind" \
  --arg modelStateBefore "$model_state_before" \
  --arg modelStateAfter "$model_state_after" \
  '{
    schemaVersion: 1,
    status: $status,
    configuration: $configuration,
    bundleIdentifier: $bundleIdentifier,
    runMode: $runMode,
    processLaunched: $processLaunched,
    processExitKind: $processExitKind,
    implicitModelMutation: ($modelStateBefore != $modelStateAfter),
    modelStateBefore: $modelStateBefore,
    modelStateAfter: $modelStateAfter
  }' > "$summary_temp"

mv "$summary_temp" "$summary_path"
rmdir "$summary_temp_directory"
trap - EXIT

print "build-and-run $run_mode passed for $bundle_identifier"
print "summary: $summary_path"
