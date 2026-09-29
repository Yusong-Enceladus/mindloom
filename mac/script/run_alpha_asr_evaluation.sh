#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_root="$repository_root/Packages/BestASRCore"
local_run="$repository_root/benchmarks/results/local/alpha-asr-v1/local-run.json"
audio_root="$repository_root/RuntimeData/Corpus/product-synthetic/alpha-asr-v1/audio"
tracked_manifest="$repository_root/Corpus/product-synthetic/alpha-asr-manifest.json"
generated_manifest="$repository_root/benchmarks/results/local/alpha-asr-v1/content-manifest.json"
model_registry="$repository_root/config/model-artifacts.json"
model_source="$repository_root/Models/downloads/fluid-sensevoice-small-int8-0e0bf30b"
model_store="$repository_root/Models/installed-alpha"
benchmark_output="$repository_root/artifacts/evidence/SPIKE-ASR-001/fluid-sensevoice-alpha-corpus.json"
decision_output="$repository_root/artifacts/evidence/SPIKE-ASR-001/fluid-sensevoice-alpha-decision.json"
local_diagnostics_output="$repository_root/benchmarks/results/local/alpha-asr-v1/diagnostics.json"

for required_tool in swift jq shasum /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing alpha ASR evaluation tool: $required_tool"
    exit 2
  }
done

for required_file in \
  "$local_run" \
  "$tracked_manifest" \
  "$generated_manifest" \
  "$model_registry"
do
  [[ -f "$required_file" ]] || {
    print -u2 "error: missing alpha ASR evaluation input"
    exit 1
  }
done

[[ -d "$audio_root" && -d "$model_source" ]] || {
  print -u2 "error: local alpha ASR audio or model is unavailable"
  exit 1
}

tracked_canonical="$(jq -S -c . "$tracked_manifest")"
generated_canonical="$(jq -S -c . "$generated_manifest")"
[[ "$tracked_canonical" == "$generated_canonical" ]] || {
  print -u2 "error: local alpha ASR corpus does not match its content-free manifest"
  exit 1
}

mkdir -p "$(dirname "$benchmark_output")" "$model_store"
swift build --package-path "$package_root" --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" --product AlphaASREvalCLI
binary_root="$(swift build --package-path "$package_root" --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" --show-bin-path)"
toolchain_version="$(swift --version | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//')"

BESTASR_TOOLCHAIN_VERSION="$toolchain_version" \
  /usr/bin/sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  "$binary_root/AlphaASREvalCLI" evaluate \
  --local-run "$local_run" \
  --audio-root "$audio_root" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --benchmark-output "$benchmark_output" \
  --decision-output "$decision_output" \
  --local-diagnostics-output "$local_diagnostics_output" \
  --network-denied true

jq -e '
  .schemaVersion == 1 and
  .kind == "alpha-asr-evaluation-decision" and
  .corpusManifestID == "product-synthetic-alpha-asr-v1" and
  .corpusVersion == "1.1.0" and
  .sampleCount == 16 and
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
  print -u2 "error: invalid alpha ASR decision artifact"
  exit 1
}

if jq -e '[.. | objects | keys[]] | any(
  . == "reference" or
  . == "hypothesis" or
  . == "transcript" or
  . == "text" or
  . == "absolutePath"
)' "$benchmark_output" "$decision_output" >/dev/null; then
  print -u2 "error: alpha ASR evidence contains prohibited content fields"
  exit 1
fi

benchmark_digest="$(shasum -a 256 "$benchmark_output" | awk '{print $1}')"
decision_digest="$(shasum -a 256 "$decision_output" | awk '{print $1}')"
print "alpha ASR evaluation artifacts passed"
print "benchmark sha256: $benchmark_digest"
print "decision sha256: $decision_digest"
