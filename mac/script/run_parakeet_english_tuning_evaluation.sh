#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"

package_root="$repository_root/Packages/BestASRCore"
plan="$repository_root/config/fleurs-asr-evaluation.json"
tracked_manifest="$repository_root/Corpus/public/fleurs-asr-tuning-manifest.json"
synthetic_run="$repository_root/benchmarks/results/local/alpha-asr-v1/local-run.json"
synthetic_manifest="$repository_root/Corpus/product-synthetic/alpha-asr-manifest.json"
synthetic_audio_root="$repository_root/RuntimeData/Corpus/product-synthetic/alpha-asr-v1/audio"
model_registry="$repository_root/config/model-artifacts.json"
model_id="fluid-parakeet-unified-en-int8-4252711f"
model_revision="4252711f6f060f9a2f91e5f081a806d7f45eebd8"
downloads_root="$BESTASR_CORPUS_CACHE/public/fleurs/70bb2e84b976b7e960aa89f1c648e09c59f894dd"
corpus_root="$BESTASR_CORPUS_CACHE/tuning/fleurs-public-asr-v1"
model_source="$BESTASR_BUILD_ROOT/model-sources/downloads/$model_id"
model_store="$BESTASR_BUILD_ROOT/model-stores/public-asr-parakeet"
diagnostics_root="$BESTASR_BUILD_ROOT/evaluations/asr/fluid-parakeet-fleurs-english-v1"
benchmark_output="$repository_root/artifacts/evidence/SPIKE-ASR-002/fluid-parakeet-fleurs-english-tuning-benchmark.json"
decision_output="$repository_root/artifacts/evidence/SPIKE-ASR-002/fluid-parakeet-fleurs-english-tuning-decision.json"

for required_tool in python3 swift jq shasum curl hf /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing English ASR evaluation tool: $required_tool"
    exit 2
  }
done

for required_file in \
  "$plan" \
  "$tracked_manifest" \
  "$synthetic_run" \
  "$synthetic_manifest" \
  "$model_registry"
do
  [[ -f "$required_file" ]] || {
    print -u2 "error: missing English ASR evaluation input"
    exit 1
  }
done

mkdir -p \
  "$downloads_root" \
  "$corpus_root" \
  "$model_source" \
  "$model_store" \
  "$diagnostics_root" \
  "$(dirname "$benchmark_output")"

verify_or_download_corpus_artifact() {
  local subset_id="$1"
  local file_name="$2"
  local url="$3"
  local expected_size="$4"
  local expected_digest="$5"
  local destination_directory="$downloads_root/$subset_id"
  local destination="$destination_directory/$file_name"
  mkdir -p "$destination_directory"
  if [[ ! -f "$destination" ]]; then
    curl -fL --retry 4 --retry-delay 2 --continue-at - \
      --output "$destination" "$url"
  fi
  [[ "$(stat -f %z "$destination")" == "$expected_size" \
    && "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_digest" ]] || {
    print -u2 "error: pinned FLEURS artifact failed verification: $subset_id/$file_name"
    return 1
  }
}

while IFS=$'\t' read -r subset_id file_name url size digest; do
  verify_or_download_corpus_artifact \
    "$subset_id" "$file_name" "$url" "$size" "$digest"
done < <(
  jq -r '.subsets[] as $subset | [$subset.metadata, $subset.audioArchive][] | [$subset.id, .fileName, .url, (.sizeBytes|tostring), .sha256] | @tsv' "$plan"
)

python3 "$repository_root/script/build_public_asr_corpus.py" \
  --plan "$plan" \
  --downloads-root "$downloads_root" \
  --corpus-root "$corpus_root" \
  --synthetic-run "$synthetic_run" \
  --synthetic-manifest "$synthetic_manifest" \
  --synthetic-audio-root "$synthetic_audio_root"

[[ "$(jq -S -c . "$corpus_root/content-manifest.json")" \
  == "$(jq -S -c . "$tracked_manifest")" ]] || {
  print -u2 "error: prepared public ASR corpus does not match its content-free manifest"
  exit 1
}

if ! jq -e --arg id "$model_id" --arg revision "$model_revision" '
  any(.models[]; .id == $id and .sourceRevision == $revision)
' "$model_registry" >/dev/null; then
  print -u2 "error: pinned Parakeet artifact is absent from the model registry"
  exit 1
fi

missing_model_file=false
while IFS= read -r relative_path; do
  [[ -f "$model_source/$relative_path" ]] || missing_model_file=true
done < <(jq -r --arg id "$model_id" '.models[] | select(.id == $id) | .files[].relativePath' "$model_registry")
if [[ "$missing_model_file" == true ]]; then
  hf download FluidInference/parakeet-unified-en-0.6b-coreml \
    --revision "$model_revision" \
    --local-dir "$model_source" \
    --include 'parakeet_unified_encoder_int8.mlmodelc/*' \
    --include 'parakeet_unified_decoder.mlmodelc/*' \
    --include 'parakeet_unified_joint_decision_single_step.mlmodelc/*' \
    --include 'vocab.json' \
    --include 'metadata.json' \
    --include 'README.md' \
    --quiet
fi

while IFS=$'\t' read -r relative_path expected_size expected_digest; do
  candidate="$model_source/$relative_path"
  [[ -f "$candidate" && ! -L "$candidate" \
    && "$(stat -f %z "$candidate")" == "$expected_size" \
    && "$(shasum -a 256 "$candidate" | awk '{print $1}')" == "$expected_digest" ]] || {
    print -u2 "error: pinned Parakeet model file failed verification"
    exit 1
  }
done < <(
  jq -r --arg id "$model_id" '.models[] | select(.id == $id) | .files[] | [.relativePath, (.sizeBytes|tostring), .sha256] | @tsv' "$model_registry"
)

swift build \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product AlphaASREvalCLI
binary_root="$(swift build \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --show-bin-path)"
toolchain_version="$(swift --version | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//')"

BESTASR_TOOLCHAIN_VERSION="$toolchain_version" \
  /usr/bin/sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  "$binary_root/AlphaASREvalCLI" evaluate \
  --local-run "$corpus_root/local-run-en.json" \
  --audio-root "$corpus_root/audio" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --backend parakeet \
  --evaluation-profile english \
  --benchmark-id "asr-public-fluid-parakeet-fleurs-english-v1" \
  --benchmark-output "$benchmark_output" \
  --decision-output "$decision_output" \
  --local-diagnostics-root "$diagnostics_root" \
  --local-diagnostics-output "$diagnostics_root/diagnostics.json" \
  --network-denied true

jq -e --arg model "$model_id" '
  .schemaVersion == 1 and
  .kind == "alpha-asr-evaluation-decision" and
  .evaluationProfile == "english" and
  .corpusManifestID == "fleurs-public-asr-tuning-v1" and
  .corpusVersion == "1.0.0" and
  .sampleCount == 32 and
  .modelArtifact.artifactID == $model and
  .networkDeniedByParentSandbox == true and
  (.selectionEligible == ([.gates[].status] | all(. == "pass")))
' "$decision_output" >/dev/null || {
  print -u2 "error: invalid Parakeet English tuning decision artifact"
  exit 1
}

if jq -e '[.. | objects | keys[]] | any(
  . == "reference" or
  . == "hypothesis" or
  . == "transcript" or
  . == "text" or
  . == "absolutePath"
)' "$benchmark_output" "$decision_output" >/dev/null; then
  print -u2 "error: committed Parakeet evidence contains prohibited content fields"
  exit 1
fi

print "Parakeet English tuning evaluation recorded"
print "status: $(jq -r .status "$decision_output")"
print "decision sha256: $(shasum -a 256 "$decision_output" | awk '{print $1}')"
