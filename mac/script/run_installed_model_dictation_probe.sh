#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_root="$repository_root/Packages/BestASRCore"
audio_input="$repository_root/RuntimeData/Corpus/product-synthetic/alpha-asr-v1/audio/mixed-dangerous.aiff"
model_registry="$repository_root/config/model-artifacts.json"
candidate_registry="$repository_root/config/inference-candidates.json"
model_source="$repository_root/Models/downloads/fluid-sensevoice-small-int8-0e0bf30b"
polish_model_source="$repository_root/Models/downloads/qwen3-1.7b-mlx-4bit-21457c6f"
model_store="$repository_root/Models/installed-alpha"
summary="$repository_root/artifacts/evidence/privacy/installed-model-dictation-summary.json"
probe_work_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-installed-model-probe.XXXXXX")"
build_configuration="release"

cleanup() {
  /bin/rm -rf -- "$probe_work_root"
}
trap cleanup EXIT

for required_tool in swift jq shasum /usr/bin/ditto /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing installed-model probe tool: $required_tool"
    exit 2
  }
done

for required_file in \
  "$audio_input" \
  "$model_registry" \
  "$candidate_registry"
do
  [[ -f "$required_file" ]] || {
    print -u2 "error: missing installed-model probe input"
    exit 1
  }
done
[[ -d "$model_source" ]] || {
  print -u2 "error: verified local SenseVoice source is unavailable"
  exit 1
}
[[ -d "$polish_model_source" ]] || {
  print -u2 "error: verified local Qwen source is unavailable"
  exit 1
}

mkdir -p "$model_store" "$(dirname "$summary")"
swift build \
  -c "$build_configuration" \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product InstalledModelDictationProbeCLI
binary_root="$(swift build \
  -c "$build_configuration" \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --show-bin-path)"
metal_bundle_source=""
for candidate in \
  "$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/mlx-swift_Cmlx.bundle" \
  "$BESTASR_XCODE_DERIVED_DATA/Build/Products/Debug/mlx-swift_Cmlx.bundle"
do
  if [[ -f "$candidate/Contents/Resources/default.metallib" ]]; then
    metal_bundle_source="$candidate"
    break
  fi
done
[[ -n "$metal_bundle_source" ]] || {
  print -u2 "error: MLX Metal resource bundle is unavailable; build the app first"
  exit 1
}
/usr/bin/ditto \
  "$metal_bundle_source" \
  "$binary_root/mlx-swift_Cmlx.bundle"

/usr/bin/sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  "$binary_root/InstalledModelDictationProbeCLI" \
  --audio "$audio_input" \
  --model-registry "$model_registry" \
  --candidate-registry "$candidate_registry" \
  --model-source "$model_source" \
  --polish-model-source "$polish_model_source" \
  --model-store "$model_store" \
  --work-root "$probe_work_root" \
  --summary "$summary" \
  --build-configuration "$build_configuration" \
  --network-denied true

jq -e '
  .schemaVersion == 6 and
  .kind == "installed-model-dictation-probe" and
  .status == "pass" and
  .appVersion == "0.1.0" and
  .buildConfiguration == "release" and
  .networkDeniedByParentSandbox == true and
  .modelArtifactID == "fluid-sensevoice-small-int8-0e0bf30b" and
  .polishModelArtifactID == "qwen3-1.7b-mlx-4bit-21457c6f" and
  .polishModelVersion == "21457c6f51ed54a7c16e988c0844db973815c137" and
  .polishModelTreeSHA256 == "09570edbadcacc0bb3abc5c58d688f92978cd62601cf98e11cf38356fd5bd7be" and
  (.polishModelActivation == "activated" or
    .polishModelActivation == "alreadyActive" or
    .polishModelActivation == "repaired") and
  .finalPhase == "completed" and
  .sourceAudioRangeCount > 0 and
  .sourceAudioPreserved == true and
  .transcriptCharacterCount > 0 and
  .transcriptSegmentCount > 0 and
  .polishDisposition == "model" and
  .insertionMethod == "retainedForCopy" and
  .externalInsertionPerformed == false and
  .dictionaryEntryCount == 1 and
  .sessionSpeakerCount == 1 and
  .speakerOccurrenceCount == .sourceAudioRangeCount and
  .speakerJobState == "queued" and
  .firstRunToReadyMilliseconds > 0 and
  .readyToFirstLiveTextMilliseconds > 0 and
  .finishToFinalTextMilliseconds > 0 and
  .liveTranscriptCharacterCount > 0 and
  .maximumLiveQueueDepth >= 0 and
  .maximumLiveQueueDepth <= 1 and
  .offlineRelaunchReady == true and
  .recoveryOutcome == "sealed-source-readable" and
  .asrProcessingMilliseconds > 0 and
  .postASRProcessingMilliseconds > 0 and
  .pipelineOverheadMilliseconds >= 0 and
  .dictationProcessingMilliseconds > 0 and
  ((.asrProcessingMilliseconds + .postASRProcessingMilliseconds +
    .pipelineOverheadMilliseconds) - .dictationProcessingMilliseconds | abs) < 0.01 and
  .firstRunToReadyMilliseconds < .elapsedMilliseconds and
  .dictationProcessingMilliseconds < .elapsedMilliseconds and
  .elapsedMilliseconds > 0 and
  .peakRSSBytes > 0
' "$summary" >/dev/null || {
  print -u2 "error: installed-model dictation summary failed its contract"
  exit 1
}

if jq -e '[.. | objects | keys[]] | any(
  . == "text" or
  . == "transcript" or
  . == "dictionaryTerms" or
  . == "absolutePath" or
  . == "audioPath"
)' "$summary" >/dev/null; then
  print -u2 "error: installed-model dictation evidence contains private fields"
  exit 1
fi

summary_digest="$(shasum -a 256 "$summary" | awk '{print $1}')"
print "installed-model dictation evidence passed"
print "summary sha256: $summary_digest"
