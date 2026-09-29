#!/bin/zsh

set -euo pipefail

if [[ $# -ne 7 ]]; then
  print -u2 "usage: $0 <corpus-dir> <matrix-root> <identity-root> <input-dir> <result-dir> <collator-cli> <bench-cli>"
  exit 64
fi

corpus_dir="$1"
matrix_root="$2"
identity_root="$3"
input_dir="$4"
result_dir="$5"
collator_cli="$6"
bench_cli="$7"

for required_directory in "$corpus_dir" "$matrix_root" "$identity_root"; do
  [[ -d "$required_directory" ]] || {
    print -u2 "missing required directory: $required_directory"
    exit 66
  }
done

for required_executable in "$collator_cli" "$bench_cli"; do
  [[ -x "$required_executable" ]] || {
    print -u2 "missing required executable: $required_executable"
    exit 66
  }
done

mkdir -p "$input_dir" "$result_dir"

collate() {
  local candidate="$1"
  local mode="$2"
  local run_id="$3"
  local revision="$4"
  local artifact_id="$5"
  local artifact_sha256="$6"
  local provider="$7"
  local identity_result="$8"
  local input_path="$input_dir/$candidate-$mode.json"
  local result_path="$result_dir/$candidate-$mode.json"

  [[ -f "$identity_result" ]] || {
    print -u2 "missing identity result: $identity_result"
    return 66
  }

  "$collator_cli" \
    --candidate "$candidate" \
    --matrix-mode "$mode" \
    --corpus-dir "$corpus_dir" \
    --candidate-output-dir "$matrix_root/$mode/$candidate" \
    --benchmark-id "speaker-$candidate-$mode-recommended-memory-smoke" \
    --run-id "$run_id" \
    --implementation-revision "$revision" \
    --artifact-id "$artifact_id" \
    --artifact-sha256 "$artifact_sha256" \
    --provider "$provider" \
    --corpus-manifest-id "product-synthetic-speaker-smoke" \
    --corpus-version "1.0.0" \
    --environment-ref "artifacts/evidence/environment/preflight-summary.json" \
    --toolchain-version "Xcode 27.0; Swift 6.4" \
    --identity-result "$identity_result" \
    --output "$input_path"

  "$bench_cli" score --input "$input_path" --output "$result_path"
}

fluid_identity="$identity_root/identity-fluid-evaluation.json"
argmax_identity="$identity_root/identity-argmax-evaluation-v2.json"
sherpa_identity="$identity_root/identity-sherpa-evaluation.json"

collate \
  fluid oracle 31000000-0000-4000-8000-000000000001 \
  19600a485baa4998812e4654b70d2bab8f2c9949 \
  fluid-speaker-diarization-coreml@1ed7a662fdc7109e36d822db793ee6eebdaf8594 \
  a91670d08b56d441b516fe0ec5532f02dfbd10f6752ebddec49ce6324af1f932 \
  coreml-cpu-and-neural-engine "$fluid_identity"
collate \
  argmax oracle 31000000-0000-4000-8000-000000000002 \
  25c62997041c134b03ca82731ce2f6fd2cae1eb9 \
  argmax-speakerkit-coreml@86ec9c929b52208b6656eb6a6361ed0d822a1f78 \
  69ffa676b5e1eeacf0a4593172a8005521d77f40e578e148358b09f98f58d7a4 \
  coreml-cpu-and-neural-engine "$argmax_identity"
collate \
  sherpa oracle 31000000-0000-4000-8000-000000000003 \
  13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24 \
  sherpa-speaker-model-set@v1.13.2 \
  785c40512db184221c560db6b2b628eb4e5622f5ec11a220c0cf453e67f152c9 \
  onnxruntime-cpu "$sherpa_identity"
collate \
  fluid automatic 31000000-0000-4000-8000-000000000004 \
  19600a485baa4998812e4654b70d2bab8f2c9949 \
  fluid-speaker-diarization-coreml@1ed7a662fdc7109e36d822db793ee6eebdaf8594 \
  a91670d08b56d441b516fe0ec5532f02dfbd10f6752ebddec49ce6324af1f932 \
  coreml-cpu-and-neural-engine "$fluid_identity"
collate \
  argmax automatic 31000000-0000-4000-8000-000000000005 \
  25c62997041c134b03ca82731ce2f6fd2cae1eb9 \
  argmax-speakerkit-coreml@86ec9c929b52208b6656eb6a6361ed0d822a1f78 \
  69ffa676b5e1eeacf0a4593172a8005521d77f40e578e148358b09f98f58d7a4 \
  coreml-cpu-and-neural-engine "$argmax_identity"
collate \
  sherpa automatic 31000000-0000-4000-8000-000000000006 \
  13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24 \
  sherpa-speaker-model-set@v1.13.2 \
  785c40512db184221c560db6b2b628eb4e5622f5ec11a220c0cf453e67f152c9 \
  onnxruntime-cpu "$sherpa_identity"

print "speaker evidence collated: 6 benchmark results"
