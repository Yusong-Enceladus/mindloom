#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
result_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-corpus-tests.XXXXXX")"
trap 'rm -rf "$result_root"' EXIT

"$repository_root/script/validate_corpus_manifests.sh" >/dev/null

missing_root="$result_root/missing"
/bin/cp -R "$repository_root/Corpus" "$missing_root"
/bin/rm "$missing_root/public/manifest.json"
set +e
"$repository_root/script/validate_corpus_manifests.sh" \
  --root "$missing_root" >/dev/null 2>&1
missing_exit_code=$?
set -e
if (( missing_exit_code == 0 )); then
  print -u2 "expected a missing corpus tier manifest to fail"
  exit 1
fi

private_root="$result_root/private-reference"
/bin/cp -R "$repository_root/Corpus" "$private_root"
jq '.samples[0].assetReference = "fixture://private/unsafe"' \
  "$private_root/private-consented/manifest.json" \
  > "$private_root/private-consented/manifest.tmp.json"
/bin/mv \
  "$private_root/private-consented/manifest.tmp.json" \
  "$private_root/private-consented/manifest.json"
set +e
"$repository_root/script/validate_corpus_manifests.sh" \
  --root "$private_root" >/dev/null 2>&1
private_exit_code=$?
set -e
if (( private_exit_code == 0 )); then
  print -u2 "expected a private corpus fixture reference to fail"
  exit 1
fi

synthetic_root="$result_root/synthetic-local-reference"
/bin/cp -R "$repository_root/Corpus" "$synthetic_root"
jq '(.samples[] | select(.assetReference | startswith("local-corpus://")) | .tags) -= ["local-only"]' \
  "$synthetic_root/product-synthetic/manifest.json" \
  > "$synthetic_root/product-synthetic/manifest.tmp.json"
/bin/mv \
  "$synthetic_root/product-synthetic/manifest.tmp.json" \
  "$synthetic_root/product-synthetic/manifest.json"
set +e
"$repository_root/script/validate_corpus_manifests.sh" \
  --root "$synthetic_root" >/dev/null 2>&1
synthetic_exit_code=$?
set -e
if (( synthetic_exit_code == 0 )); then
  print -u2 "expected an unmarked local synthetic corpus reference to fail"
  exit 1
fi

git_root="$result_root/git-fixture"
/bin/mkdir -p \
  "$git_root/Corpus/private-consented" \
  "$git_root/Corpus/product-synthetic"
git -C "$git_root" init -q
print '{}' > "$git_root/Corpus/private-consented/manifest.json"
print '{}' > "$git_root/Corpus/product-synthetic/manifest.json"
git -C "$git_root" add Corpus
"$repository_root/script/check_corpus_git_safety.sh" --root "$git_root" >/dev/null

print 'planted private audio' > "$git_root/Corpus/private-consented/planted.wav"
git -C "$git_root" add Corpus/private-consented/planted.wav
set +e
"$repository_root/script/check_corpus_git_safety.sh" \
  --root "$git_root" >/dev/null 2>&1
tracked_private_exit_code=$?
set -e
if (( tracked_private_exit_code == 0 )); then
  print -u2 "expected tracked private audio to fail"
  exit 1
fi

print "corpus manifest and Git safety fixtures passed"
