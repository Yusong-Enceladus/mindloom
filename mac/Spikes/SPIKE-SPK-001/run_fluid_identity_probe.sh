#!/bin/zsh

set -euo pipefail

if [[ $# -ne 5 ]]; then
  print -u2 "usage: $0 <manifest> <audio-dir> <output-dir> <fluid-cli> <fluid-home>"
  exit 64
fi

manifest="$1"
audio_dir="$2"
output_dir="$3"
fluid_cli="$4"
fluid_home="$5"

if [[ ! -f "$manifest" || ! -f "$fluid_cli" || ! -d "$audio_dir" || ! -d "$fluid_home" ]]; then
  print -u2 "missing manifest, audio directory, Fluid CLI, or Fluid home"
  exit 66
fi

mkdir -p "$output_dir"
sample_ids=("${(@f)$(jq -er '.entries[].sampleID' "$manifest")}")
for sample_id in "${sample_ids[@]}"; do
  sample_output="$output_dir/$sample_id"
  mkdir -p "$sample_output"
  sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    /usr/bin/env CFFIXED_USER_HOME="$fluid_home" \
    /usr/bin/time -l "$fluid_cli" process "$audio_dir/$sample_id.wav" \
    --mode offline \
    --num-speakers 1 \
    --min-segment-duration 0.5 \
    --output "$sample_output/result.json" \
    --export-embeddings "$sample_output/embeddings.json" \
    > "$sample_output/stdout.log" \
    2> "$sample_output/stderr.log"
done
