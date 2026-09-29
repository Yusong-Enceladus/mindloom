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
downloads_root="$BESTASR_CORPUS_CACHE/public/fleurs/70bb2e84b976b7e960aa89f1c648e09c59f894dd"
corpus_root="$BESTASR_CORPUS_CACHE/tuning/fleurs-public-asr-v1"
model_source="$BESTASR_BUILD_ROOT/model-sources/downloads/fluid-sensevoice-small-int8-0e0bf30b"
model_store="$BESTASR_BUILD_ROOT/model-stores/public-asr-sensevoice"
diagnostics_root="$BESTASR_BUILD_ROOT/evaluations/asr/fluid-sensevoice-fleurs-v1"
benchmark_output="$repository_root/artifacts/evidence/SPIKE-ASR-002/fluid-sensevoice-fleurs-tuning-benchmark.json"
decision_output="$repository_root/artifacts/evidence/SPIKE-ASR-002/fluid-sensevoice-fleurs-tuning-decision.json"

for required_tool in python3 swift jq shasum curl /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing public ASR evaluation tool: $required_tool"
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
    print -u2 "error: missing public ASR evaluation input"
    exit 1
  }
done

[[ -d "$synthetic_audio_root" && -d "$model_source" ]] || {
  print -u2 "error: local synthetic ASR audio or pinned model source is unavailable"
  exit 1
}

mkdir -p \
  "$downloads_root" \
  "$corpus_root" \
  "$model_store" \
  "$diagnostics_root" \
  "$(dirname "$benchmark_output")"

verify_or_download() {
  local subset_id="$1"
  local file_name="$2"
  local url="$3"
  local expected_size="$4"
  local expected_digest="$5"
  local destination_directory="$downloads_root/$subset_id"
  local destination="$destination_directory/$file_name"
  mkdir -p "$destination_directory"
  if [[ -f "$destination" ]]; then
    [[ "$(stat -f %z "$destination")" == "$expected_size" \
      && "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_digest" ]] || {
      print -u2 "error: cached FLEURS artifact failed verification: $subset_id/$file_name"
      print -u2 "Remove only that reproducible public cache file, then rerun."
      return 1
    }
    return 0
  fi
  curl -fL --retry 4 --retry-delay 2 --continue-at - \
    --output "$destination" "$url"
  [[ "$(stat -f %z "$destination")" == "$expected_size" \
    && "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_digest" ]] || {
    print -u2 "error: FLEURS artifact verification failed after download: $subset_id/$file_name"
    return 1
  }
}

while IFS=$'\t' read -r subset_id file_name url size digest; do
  verify_or_download "$subset_id" "$file_name" "$url" "$size" "$digest"
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
  --local-run "$corpus_root/local-run.json" \
  --audio-root "$corpus_root/audio" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --benchmark-id "asr-public-fluid-sensevoice-fleurs-v1" \
  --benchmark-output "$benchmark_output" \
  --decision-output "$decision_output" \
  --local-diagnostics-root "$diagnostics_root" \
  --local-diagnostics-output "$diagnostics_root/diagnostics.json" \
  --network-denied true

jq -e '
  .schemaVersion == 1 and
  .kind == "alpha-asr-evaluation-decision" and
  .corpusManifestID == "fleurs-public-asr-tuning-v1" and
  .corpusVersion == "1.0.0" and
  .sampleCount == 64 and
  .networkDeniedByParentSandbox == true and
  (.selectionEligible == ([.gates[].status] | all(. == "pass"))) and
  ([.metrics[].name] | contains([
    "cer",
    "wer",
    "mer",
    "dangerous-token-errors",
    "latency-p95",
    "realtime-factor",
    "peak-rss"
  ]))
' "$decision_output" >/dev/null || {
  print -u2 "error: invalid public ASR tuning decision artifact"
  exit 1
}

if jq -e '[.. | objects | keys[]] | any(
  . == "reference" or
  . == "hypothesis" or
  . == "transcript" or
  . == "text" or
  . == "absolutePath"
)' "$benchmark_output" "$decision_output" >/dev/null; then
  print -u2 "error: committed public ASR evidence contains prohibited content fields"
  exit 1
fi

print "public ASR tuning evaluation recorded"
print "status: $(jq -r .status "$decision_output")"
print "decision sha256: $(shasum -a 256 "$decision_output" | awk '{print $1}')"
