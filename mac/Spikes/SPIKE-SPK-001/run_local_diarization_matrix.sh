#!/bin/zsh

set -euo pipefail

if [[ $# -ne 10 ]]; then
  print -u2 "usage: $0 <oracle|automatic> <corpus-dir> <output-dir> <fluid-cli> <fluid-home> <argmax-cli> <argmax-model-dir> <sherpa-cli> <sherpa-segmentation-model> <sherpa-embedding-model>"
  exit 64
fi

matrix_mode="$1"
corpus_dir="$2"
output_dir="$3"
fluid_cli="$4"
fluid_home="$5"
argmax_cli="$6"
argmax_model_dir="$7"
sherpa_cli="$8"
sherpa_segmentation_model="$9"
sherpa_embedding_model="${10}"

if [[ "$matrix_mode" != "oracle" && "$matrix_mode" != "automatic" ]]; then
  print -u2 "matrix mode must be oracle or automatic"
  exit 64
fi

for required_file in "$fluid_cli" "$argmax_cli" "$sherpa_cli" \
  "$sherpa_segmentation_model" "$sherpa_embedding_model"; do
  if [[ ! -f "$required_file" ]]; then
    print -u2 "missing required file: $required_file"
    exit 66
  fi
done

if [[ ! -d "$corpus_dir" || ! -d "$fluid_home" || ! -d "$argmax_model_dir" ]]; then
  print -u2 "missing corpus, Fluid home, or Argmax model directory"
  exit 66
fi

mkdir -p "$output_dir/fluid" "$output_dir/argmax" "$output_dir/sherpa"

setopt null_glob
receipts=("$corpus_dir"/*.receipt.json)
if (( ${#receipts[@]} == 0 )); then
  print -u2 "no corpus receipts found"
  exit 66
fi

for receipt in "${receipts[@]}"; do
  sample_id="$(jq -er '.sampleID' "$receipt")"
  speaker_count="$(jq -er '.speakerCount' "$receipt")"
  audio_path="$corpus_dir/$sample_id.wav"

  mkdir -p \
    "$output_dir/fluid/$sample_id" \
    "$output_dir/argmax/$sample_id" \
    "$output_dir/sherpa/$sample_id"

  if [[ "$matrix_mode" == "oracle" ]]; then
    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/env CFFIXED_USER_HOME="$fluid_home" \
      /usr/bin/time -l "$fluid_cli" process "$audio_path" \
      --mode offline \
      --num-speakers "$speaker_count" \
      --overlapping-segments \
      --output "$output_dir/fluid/$sample_id/result.json" \
      --export-embeddings "$output_dir/fluid/$sample_id/embeddings.json" \
      > "$output_dir/fluid/$sample_id/stdout.log" \
      2> "$output_dir/fluid/$sample_id/stderr.log"

    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/time -l "$argmax_cli" diarize \
      --audio-path "$audio_path" \
      --rttm-path "$output_dir/argmax/$sample_id/result.rttm" \
      --model-path "$argmax_model_dir" \
      --num-speakers "$speaker_count" \
      > "$output_dir/argmax/$sample_id/stdout.log" \
      2> "$output_dir/argmax/$sample_id/stderr.log"

    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/time -l "$sherpa_cli" \
      --clustering.num-clusters="$speaker_count" \
      --segmentation.pyannote-model="$sherpa_segmentation_model" \
      --embedding.model="$sherpa_embedding_model" \
      "$audio_path" \
      > "$output_dir/sherpa/$sample_id/stdout.log" \
      2> "$output_dir/sherpa/$sample_id/stderr.log"
  else
    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/env CFFIXED_USER_HOME="$fluid_home" \
      /usr/bin/time -l "$fluid_cli" process "$audio_path" \
      --mode offline \
      --min-speakers 1 \
      --max-speakers 4 \
      --overlapping-segments \
      --output "$output_dir/fluid/$sample_id/result.json" \
      --export-embeddings "$output_dir/fluid/$sample_id/embeddings.json" \
      > "$output_dir/fluid/$sample_id/stdout.log" \
      2> "$output_dir/fluid/$sample_id/stderr.log"

    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/time -l "$argmax_cli" diarize \
      --audio-path "$audio_path" \
      --rttm-path "$output_dir/argmax/$sample_id/result.rttm" \
      --model-path "$argmax_model_dir" \
      --cluster-distance-threshold 0.6 \
      > "$output_dir/argmax/$sample_id/stdout.log" \
      2> "$output_dir/argmax/$sample_id/stderr.log"

    sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      /usr/bin/time -l "$sherpa_cli" \
      --clustering.cluster-threshold=0.65 \
      --segmentation.pyannote-model="$sherpa_segmentation_model" \
      --embedding.model="$sherpa_embedding_model" \
      "$audio_path" \
      > "$output_dir/sherpa/$sample_id/stdout.log" \
      2> "$output_dir/sherpa/$sample_id/stderr.log"
  fi
done
