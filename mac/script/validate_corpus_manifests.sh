#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
corpus_root="$repository_root/Corpus"

while (( $# > 0 )); do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { print -u2 "error: --root needs a value"; exit 64; }
      corpus_root="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { print -u2 "error: jq is required"; exit 2; }
[[ -d "$corpus_root" ]] || { print -u2 "error: corpus root is missing: $corpus_root"; exit 1; }

tiers=(
  public
  product-synthetic
  device-lab
  private-consented
  adversarial
  release-holdout
)
manifest_paths=()

for tier in "${tiers[@]}"; do
  primary_manifest_path="$corpus_root/$tier/manifest.json"
  [[ -f "$primary_manifest_path" ]] || {
    print -u2 "error: missing corpus manifest for tier: $tier"
    exit 1
  }

  for manifest_path in "$corpus_root/$tier"/*manifest.json(N); do
    manifest_paths+=("$manifest_path")
    if ! jq -e --arg tier "$tier" '
    def safe_reference($pattern):
      test($pattern) and
      (test("/\\.\\.?(/|$)") | not) and
      (test(":///") | not);
    ((keys | sort) == ([
      "containsPrivateContent",
      "kind",
      "manifestID",
      "releaseHoldout",
      "samples",
      "schemaVersion",
      "tier",
      "version"
    ] | sort)) and
    .schemaVersion == 1 and
    .kind == "corpus-manifest" and
    .tier == $tier and
    (.manifestID | type == "string" and length > 0) and
    (.version | type == "string" and length > 0) and
    (.releaseHoldout == ($tier == "release-holdout")) and
    (.containsPrivateContent == ($tier == "private-consented")) and
    (.samples | type == "array" and length > 0) and
    all(.samples[];
      ((keys | sort) == ([
        "assetReference",
        "consentClass",
        "contentDigest",
        "languages",
        "sampleUUID",
        "tags"
      ] | sort)) and
      (.sampleUUID | test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
      (.contentDigest | test("^[0-9a-f]{64}$")) and
      (.languages | type == "array" and length > 0) and
      all(.languages[]; type == "string" and test("^[a-z]{2}(-[A-Z]{2})?$")) and
      (.tags | type == "array") and
      all(.tags[]; type == "string" and length > 0) and
      (
        if $tier == "private-consented" then
          .consentClass == "consented-private" and
          (.assetReference | safe_reference("^local-corpus://[A-Za-z0-9._/-]+$"))
        elif $tier == "public" then
          .consentClass == "public" and
          (.assetReference | safe_reference("^(fixture|external-corpus)://[A-Za-z0-9._/-]+$"))
        elif $tier == "product-synthetic" then
          .consentClass == "synthetic" and
          (.assetReference | safe_reference("^(fixture|local-corpus)://[A-Za-z0-9._/-]+$")) and
          (if (.assetReference | startswith("local-corpus://")) then
            (.tags | index("local-only") != null)
          else
            true
          end)
        elif $tier == "device-lab" then
          .consentClass == "device-lab" and
          (.assetReference | safe_reference("^fixture://[A-Za-z0-9._/-]+$"))
        elif $tier == "adversarial" then
          .consentClass == "adversarial" and
          (.assetReference | safe_reference("^fixture://[A-Za-z0-9._/-]+$"))
        else
          (
            (.consentClass == "synthetic" and
              (.assetReference | safe_reference("^fixture://[A-Za-z0-9._/-]+$"))) or
            (.consentClass == "public" and
              (.assetReference | safe_reference("^external-corpus://[A-Za-z0-9._/-]+$")))
          )
        end
      )
    ) and
    ([.. | objects | keys[]] | all(
      . != "transcript" and
      . != "text" and
      . != "speakerEmbedding" and
      . != "participantName" and
      . != "absolutePath"
    ))
    ' "$manifest_path" >/dev/null; then
      print -u2 "error: invalid or privacy-unsafe corpus manifest: $manifest_path"
      exit 1
    fi
  done
done

if ! jq -s -e '
  [.[].manifestID] as $manifestIDs |
  [.[].samples[].sampleUUID] as $sampleIDs |
  [.[].samples[].contentDigest] as $digests |
  ($manifestIDs | length) == ($manifestIDs | unique | length) and
  ($sampleIDs | length) == ($sampleIDs | unique | length) and
  ($digests | length) == ($digests | unique | length)
' "${manifest_paths[@]}" >/dev/null; then
  print -u2 "error: corpus manifest IDs, sample UUIDs, and digests must be globally unique"
  exit 1
fi

if find "$corpus_root" -type l -print -quit | /usr/bin/grep -q .; then
  print -u2 "error: corpus manifests must not rely on repository symlinks"
  exit 1
fi

print "corpus manifests passed: ${#manifest_paths[@]} tiers"
