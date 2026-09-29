#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-privacy-tests.XXXXXX")"
trap '[[ ! -d "$fixture_root" ]] || find "$fixture_root" -depth -delete' EXIT

printf 'public synthetic fixture\n' > "$fixture_root/safe.txt"
"$repository_root/script/privacy_scan.sh" \
  --root "$fixture_root" \
  --allowlist "$fixture_root/no-allowlist.txt" \
  --summary "$fixture_root/pass-summary.json" >/dev/null

# A linked worktree stores a gitdir pointer as a .git file, rather than a
# directory. Exclude only this exact metadata name, not similarly named files.
printf 'gitdir: /Users/synthetic/Desktop/repository/.git/worktrees/fixture\n' > "$fixture_root/.git"
"$repository_root/script/privacy_scan.sh" \
  --root "$fixture_root" \
  --allowlist "$fixture_root/no-allowlist.txt" \
  --summary "$fixture_root/worktree-pointer-summary.json" >/dev/null
test "$(jq -r '.findingCount' "$fixture_root/worktree-pointer-summary.json")" = "0"
printf 'BESTASR_PLANTED_SECRET\n' > "$fixture_root/.git-copy"
if "$repository_root/script/privacy_scan.sh" \
  --root "$fixture_root" \
  --allowlist "$fixture_root/no-allowlist.txt" \
  --summary "$fixture_root/similar-name-summary.json" >/dev/null 2>&1
then
  print -u2 "expected similarly named nonmetadata content to fail"
  exit 1
fi
jq -e '.findings | index("content-signature:.git-copy") != null' \
  "$fixture_root/similar-name-summary.json" >/dev/null
rm "$fixture_root/.git" "$fixture_root/.git-copy"
mkdir "$fixture_root/.git"
printf 'BESTASR_PLANTED_SECRET\n' > "$fixture_root/.git/config"
printf 'synthetic git metadata audio marker\n' > "$fixture_root/.git/fixture.wav"
"$repository_root/script/privacy_scan.sh" \
  --root "$fixture_root" \
  --allowlist "$fixture_root/no-allowlist.txt" \
  --summary "$fixture_root/git-directory-summary.json" >/dev/null
test "$(jq -r '.findingCount' "$fixture_root/git-directory-summary.json")" = "0"

printf '%s\n%s\n%s\n' \
  '-----BEGIN PRIVATE KEY-----' \
  'BESTASR_PLANTED_SECRET' \
  '/Users/synthetic/Documents/private-corpus' > "$fixture_root/planted.pem"
printf 'synthetic audio marker\n' > "$fixture_root/sample.wav"
printf 'synthetic full text marker\n' > "$fixture_root/full.transcript.txt"
printf 'synthetic vector marker\n' > "$fixture_root/speaker.embedding.json"
printf 'synthetic dictionary marker\n' > "$fixture_root/private.dictionary.json"
printf 'synthetic model marker\n' > "$fixture_root/unregistered.onnx"
printf 'synthetic signing marker\n' > "$fixture_root/signing.p12"
set +e
"$repository_root/script/privacy_scan.sh" \
  --root "$fixture_root" \
  --allowlist "$fixture_root/no-allowlist.txt" \
  --summary "$fixture_root/fail-summary.json" >/dev/null 2>&1
exit_code=$?
set -e

if (( exit_code == 0 )); then
  print -u2 "expected planted privacy fixture to fail"
  exit 1
fi
test "$(jq -r '.status' "$fixture_root/fail-summary.json")" = "fail"
test "$(jq -r '.findingCount' "$fixture_root/fail-summary.json")" -ge 7

print "privacy scan fixtures passed: benign input, exact Git metadata exclusion, and planted secret"
