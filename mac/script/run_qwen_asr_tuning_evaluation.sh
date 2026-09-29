#!/bin/zsh

# Uses the same prepared public/synthetic corpus as the Fluid and Whisper
# comparisons. Does not download models, change the App, or create a build root.
set -euo pipefail
umask 077

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
evaluation_kind="${1:-full}"
[[ $# -le 1 && ( "$evaluation_kind" == "pilot" || "$evaluation_kind" == "full" \
  || "$evaluation_kind" == "alignment-pilot" || "$evaluation_kind" == "alignment-full" \
  || "$evaluation_kind" == "alignment-controls" || "$evaluation_kind" == "native-pilot" \
  || "$evaluation_kind" == "native-full" ) ]] || {
  print -u2 "usage: run_qwen_asr_tuning_evaluation.sh [pilot|full|alignment-pilot|alignment-full|alignment-controls|native-pilot|native-full]"
  exit 64
}

binary_root="$BESTASR_SWIFTPM_SCRATCH/arm64-apple-macosx/debug"
corpus_root="$BESTASR_CORPUS_CACHE/tuning/fleurs-public-asr-v1"
evaluation_root="$BESTASR_BUILD_ROOT/evaluations/qwen3-asr-1.7b-fleurs-v1"
output_root="$evaluation_root/$evaluation_kind"
model_store="$BESTASR_BUILD_ROOT/model-stores/qwen3-asr-evaluation"
model_source="$BESTASR_BUILD_ROOT/model-sources/evaluation/qwen3-asr-1.7b-8bit-a8379a2e"
asr_version="$model_store/versions/qwen3-asr-1.7b-8bit-a8379a2e/a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
alignment_source="$BESTASR_BUILD_ROOT/model-sources/evaluation/qwen3-forced-aligner-0.6b-8bit-0e1a68e9"
alignment_version="$model_store/versions/qwen3-forced-aligner-0.6b-8bit-0e1a68e9/0e1a68e91d815300c7c9754b2a7639378b23db15"
# A verified active artifact is also a valid local activation source. Reuse
# the canonical store; disposable downloads need not survive every evaluation.
[[ ! -d "$asr_version" ]] || model_source="$asr_version"
[[ ! -d "$alignment_version" ]] || alignment_source="$alignment_version"
metal_bundle="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Debug/mlx-swift_Cmlx.bundle"
if [[ "$evaluation_kind" == alignment-* ]]; then
  corpus_root="$BESTASR_CORPUS_CACHE/tuning/ami-alignment-v1"
  evaluation_root="$BESTASR_BUILD_ROOT/evaluations/qwen3-forced-alignment-ami-v1"
  output_root="$evaluation_root/${evaluation_kind#alignment-}"
  model_source="$alignment_source"
fi
if [[ "$evaluation_kind" == "alignment-controls" ]]; then
  corpus_root="$BESTASR_CORPUS_CACHE/tuning/fleurs-public-asr-v1"
fi
evaluation_backend="qwen3-asr"
model_registry="$repository_root/config/qwen3-asr-evaluation-models.json"
additional_arguments=()
if [[ "$evaluation_kind" == native-* ]]; then
  evaluation_root="$BESTASR_BUILD_ROOT/evaluations/qwen3-native-final-fleurs-v1"
  output_root="$evaluation_root/${evaluation_kind#native-}"
  evaluation_backend="qwen3-native"
  model_registry="$repository_root/config/model-artifacts.json"
  additional_arguments=(--alignment-source "$alignment_source")
fi

[[ -x "$binary_root/AlphaASREvalCLI" && -f "$corpus_root/local-run.json" \
  && -d "$corpus_root/audio" && -d "$model_source" ]] || {
  print -u2 "error: build AlphaASREvalCLI in the canonical external scratch and prepare the pinned corpus/model first"
  exit 1
}
[[ -f "$metal_bundle/Contents/Resources/default.metallib" ]] || {
  print -u2 "error: MLX Metal resources are missing from the canonical native App build; no local build fallback is allowed"
  exit 1
}
# Same packaging requirement as run_installed_model_dictation_probe.sh. Keep
# the sole CLI resource copy inside the already shared external SwiftPM root.
/usr/bin/ditto "$metal_bundle" "$binary_root/mlx-swift_Cmlx.bundle"

mkdir -p "$output_root"
local_run="$corpus_root/local-run.json"
if [[ "$evaluation_kind" == "alignment-controls" ]]; then
  /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    "$binary_root/AlphaASREvalCLI" alignment-controls \
    --local-run "$local_run" --audio-root "$corpus_root/audio" \
    --transcript-diagnostics "$BESTASR_BUILD_ROOT/evaluations/qwen3-asr-1.7b-fleurs-v1/full/diagnostics.json" \
    --model-registry "$repository_root/config/qwen3-asr-evaluation-models.json" \
    --model-source "$model_source" \
    --model-store "$model_store" \
    --output-root "$output_root" --network-denied true
  exit 0
fi
if [[ "$evaluation_kind" == alignment-* ]]; then
  alignment_limit=()
  [[ "$evaluation_kind" != "alignment-pilot" ]] || alignment_limit=(--limit 1)
  /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    "$binary_root/AlphaASREvalCLI" evaluate-alignment \
    --local-run "$local_run" --audio-root "$corpus_root/audio" \
    --model-registry "$repository_root/config/qwen3-asr-evaluation-models.json" \
    --model-source "$model_source" \
    --model-store "$model_store" \
    --output-root "$output_root" --network-denied true "${alignment_limit[@]}"
  exit 0
fi
if [[ "$evaluation_kind" == "pilot" || "$evaluation_kind" == "native-pilot" ]]; then
  local_run="$output_root/local-run.json"
  jq '.samples = .samples[0:1]' "$corpus_root/local-run.json" > "$local_run"
fi

/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$binary_root/AlphaASREvalCLI" evaluate \
  --backend "$evaluation_backend" \
  --local-run "$local_run" \
  --audio-root "$corpus_root/audio" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --benchmark-id "asr-qwen3-1-7b-8bit-fleurs-$evaluation_kind" \
  --benchmark-output "$output_root/benchmark.json" \
  --decision-output "$output_root/decision.json" \
  --local-diagnostics-root "$evaluation_root" \
  --local-diagnostics-output "$output_root/diagnostics.json" \
  --network-denied true "${additional_arguments[@]}"
