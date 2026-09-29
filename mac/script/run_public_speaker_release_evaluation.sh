#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"

package_root="$repository_root/Packages/BestASRCore"
plan="$repository_root/config/ami-speaker-evaluation.json"
tuning_manifest="$repository_root/Corpus/public/ami-speaker-manifest.json"
release_manifest="$repository_root/Corpus/release-holdout/ami-speaker-manifest.json"
model_registry="$repository_root/config/model-artifacts.json"
corpus_root="$BESTASR_BUILD_ROOT/corpora"
downloads_root="$corpus_root/downloads/ami-1.6.2"
annotations_root="$downloads_root/annotations"
tuning_root="$corpus_root/tuning/ami-speaker-v1"
release_root="$corpus_root/release-holdout/ami-speaker-v1"
state_root="$corpus_root/speaker-release-state/fluid-ami-v1"
model_source="$BESTASR_BUILD_ROOT/model-sources/downloads/fluid-speaker-diarization-coreml-1ed7a662"
model_store="$BESTASR_BUILD_ROOT/model-stores/speaker-release-fluid"
diagnostics_root="$BESTASR_BUILD_ROOT/evaluations/speaker/fluid-ami-v1"
frozen_profile="$state_root/frozen-identity-model.json"
tuning_benchmark="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-tuning-benchmark.json"
tuning_decision="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-tuning-decision.json"
release_benchmark="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-release-holdout-benchmark.json"
release_decision="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-release-holdout-decision.json"

for required_tool in swift jq shasum curl ditto /usr/bin/sandbox-exec; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: missing public speaker evaluation tool: $required_tool"
    exit 2
  }
done

for required_file in "$plan" "$tuning_manifest" "$release_manifest" "$model_registry"; do
  [[ -f "$required_file" ]] || {
    print -u2 "error: missing public speaker evaluation input: $required_file"
    exit 1
  }
done

[[ -d "$model_source" ]] || {
  print -u2 "error: pinned Fluid speaker model source is unavailable on the build volume"
  exit 1
}

mkdir -p \
  "$downloads_root" \
  "$state_root" \
  "$model_store" \
  "$diagnostics_root" \
  "$(dirname "$tuning_benchmark")"

verify_or_download() {
  local file_name="$1"
  local url="$2"
  local expected_size="$3"
  local expected_digest="$4"
  local destination="$downloads_root/$file_name"
  if [[ -f "$destination" ]]; then
    local actual_size="$(stat -f %z "$destination")"
    local actual_digest="$(shasum -a 256 "$destination" | awk '{print $1}')"
    [[ "$actual_size" == "$expected_size" && "$actual_digest" == "$expected_digest" ]] || {
      print -u2 "error: cached AMI artifact failed verification: $file_name"
      print -u2 "Remove only that reproducible public cache file, then rerun."
      return 1
    }
    return 0
  fi
  curl -fL --retry 4 --retry-delay 2 --continue-at - \
    --output "$destination" "$url"
  [[ "$(stat -f %z "$destination")" == "$expected_size" ]] || {
    print -u2 "error: AMI artifact size mismatch after download: $file_name"
    return 1
  }
  [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_digest" ]] || {
    print -u2 "error: AMI artifact digest mismatch after download: $file_name"
    return 1
  }
}

archive_row="$(jq -r '[.annotationArchive.fileName, .annotationArchive.url, (.annotationArchive.sizeBytes|tostring), .annotationArchive.sha256] | @tsv' "$plan")"
IFS=$'\t' read -r archive_name archive_url archive_size archive_digest <<< "$archive_row"
verify_or_download "$archive_name" "$archive_url" "$archive_size" "$archive_digest"

while IFS=$'\t' read -r file_name url size digest; do
  verify_or_download "$file_name" "$url" "$size" "$digest"
done < <(jq -r '.audioArtifacts[] | [.fileName, .url, (.sizeBytes|tostring), .sha256] | @tsv' "$plan")

if [[ ! -d "$annotations_root" ]]; then
  extraction_root="$(mktemp -d "$BESTASR_BUILD_TMP/ami-annotations.XXXXXX")"
  ditto -x -k "$downloads_root/$archive_name" "$extraction_root"
  [[ -f "$extraction_root/segments/ES2004a.A.segments.xml" ]] || {
    print -u2 "error: AMI annotation archive did not contain the pinned segment layout"
    exit 1
  }
  mv "$extraction_root" "$annotations_root"
fi
for annotation in \
  ES2004a.A ES2004a.B ES2004a.C ES2004a.D \
  ES2004c.A ES2004c.B ES2004c.C ES2004c.D \
  ES2005a.A ES2005a.B ES2005a.C ES2005a.D
do
  [[ -f "$annotations_root/segments/$annotation.segments.xml" ]] || {
    print -u2 "error: missing pinned AMI annotation: $annotation"
    exit 1
  }
done

swift build \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --product PublicSpeakerEvalCLI
binary_root="$(swift build \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --show-bin-path)"
cli="$binary_root/PublicSpeakerEvalCLI"
toolchain_version="$(swift --version | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//')"

/usr/bin/sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  "$cli" prepare \
  --plan "$plan" \
  --downloads-root "$downloads_root" \
  --annotations-root "$annotations_root" \
  --tuning-root "$tuning_root" \
  --release-root "$release_root" \
  --tuning-manifest-template "$tuning_manifest" \
  --release-manifest-template "$release_manifest"

calibration_policy="(version 1) (allow default) (deny network*) (deny file-read-data (subpath \"$release_root\"))"
BESTASR_TOOLCHAIN_VERSION="$toolchain_version" \
  /usr/bin/sandbox-exec -p "$calibration_policy" \
  "$cli" calibrate \
  --tuning-root "$tuning_root" \
  --release-root "$release_root" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --frozen-profile-output "$frozen_profile" \
  --benchmark-output "$tuning_benchmark" \
  --decision-output "$tuning_decision" \
  --diagnostics-output "$diagnostics_root/tuning-diagnostics.json" \
  --threshold-margin 0.03 \
  --network-denied true

jq -e '
  .schemaVersion == 1 and
  .kind == "speaker-release-evaluation-decision" and
  .phase == "tuning-calibration" and
  .eligibleForHoldout == true and
  .selectionEligible == false and
  .networkDeniedByParentSandbox == true and
  ([.observedModes[]] | sort) == (["dictation", "imported-media", "room-microphone", "system-audio"] | sort)
' "$tuning_decision" >/dev/null || {
  print -u2 "error: Fluid tuning calibration did not pass; holdout remains sealed"
  exit 1
}

release_policy="(version 1) (allow default) (deny network*) (deny file-read-data (subpath \"$tuning_root\"))"
BESTASR_TOOLCHAIN_VERSION="$toolchain_version" \
  /usr/bin/sandbox-exec -p "$release_policy" \
  "$cli" evaluate \
  --tuning-root "$tuning_root" \
  --release-root "$release_root" \
  --model-registry "$model_registry" \
  --model-source "$model_source" \
  --model-store "$model_store" \
  --frozen-profile "$frozen_profile" \
  --benchmark-output "$release_benchmark" \
  --decision-output "$release_decision" \
  --diagnostics-output "$diagnostics_root/release-holdout-diagnostics.json" \
  --network-denied true

jq -e '
  .schemaVersion == 1 and
  .kind == "speaker-release-evaluation-decision" and
  .phase == "release-holdout" and
  .selectionEligible == ([.gates[].status] | all(. == "pass")) and
  .networkDeniedByParentSandbox == true and
  .knownWrongCount == 0 and
  .falseMergeCount == 0 and
  ([.metrics[].name] | contains([
    "der",
    "jer",
    "speaker-confusion-rate",
    "false-merge-count",
    "realtime-factor",
    "peak-rss"
  ]))
' "$release_decision" >/dev/null || {
  print -u2 "error: invalid Fluid AMI release-holdout decision artifact"
  exit 1
}

if jq -e '[.. | objects | keys[]] | any(
  . == "vector" or
  . == "embedding" or
  . == "speakerEmbedding" or
  . == "participantName" or
  . == "absolutePath" or
  . == "transcript" or
  . == "text"
)' "$tuning_benchmark" "$tuning_decision" "$release_benchmark" "$release_decision" >/dev/null; then
  print -u2 "error: committed speaker evidence contains prohibited local content"
  exit 1
fi

if ! jq -e '.selectionEligible == true and .status == "pass"' "$release_decision" >/dev/null; then
  print -u2 "error: Fluid did not pass the independent AMI release holdout"
  exit 1
fi

print "public speaker release evaluation passed"
print "frozen local profile: $frozen_profile"
print "release decision sha256: $(shasum -a 256 "$release_decision" | awk '{print $1}')"
