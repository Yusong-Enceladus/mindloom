#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-supply-chain-tests.XXXXXX")"
package_root="$test_root/bestASR.app"
summary_root="$test_root/summaries"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$package_root/Contents" "$summary_root"
cp "$repository_root/Tests/Fixtures/SupplyChain/Info.plist" \
  "$package_root/Contents/Info.plist"

generator_arguments=(
  --package "$package_root"
  --dependencies "$repository_root/config/dependencies.json"
  --models "$repository_root/config/model-artifacts.json"
  --policy "$repository_root/config/release-package-policy.json"
  --notices "$repository_root/THIRD-PARTY-NOTICES.md"
)
validator_arguments=(
  --package "$package_root"
  --dependencies "$repository_root/config/dependencies.json"
  --models "$repository_root/config/model-artifacts.json"
  --policy "$repository_root/config/release-package-policy.json"
  --notices "$repository_root/THIRD-PARTY-NOTICES.md"
)

"$repository_root/script/generate_supply_chain.sh" \
  "${generator_arguments[@]}" \
  --sbom "$test_root/sbom.json" \
  --manifest "$test_root/release-manifest.json" \
  --validation-summary "$summary_root/valid-generation.json" >/dev/null

"$repository_root/script/validate_release_package.sh" \
  "${validator_arguments[@]}" \
  --sbom "$test_root/sbom.json" \
  --manifest "$test_root/release-manifest.json" \
  --summary "$summary_root/valid-validation.json" >/dev/null

expect_failure() {
  local scenario="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  exit_code=$?
  set -e
  if (( exit_code == 0 )); then
    print -u2 "expected supply-chain failure: $scenario"
    exit 1
  fi
}

mkdir -p "$package_root/Contents/MacOS"
cp /bin/echo "$package_root/Contents/MacOS/unregistered-tool"
expect_failure "frozen-manifest-rejects-unregistered-binary" \
  "$repository_root/script/validate_release_package.sh" \
  "${validator_arguments[@]}" \
  --sbom "$test_root/sbom.json" \
  --manifest "$test_root/release-manifest.json" \
  --summary "$summary_root/unregistered-binary.json"
expect_failure "generator-rejects-unregistered-binary" \
  "$repository_root/script/generate_supply_chain.sh" \
  "${generator_arguments[@]}" \
  --sbom "$test_root/binary-sbom.json" \
  --manifest "$test_root/binary-manifest.json" \
  --validation-summary "$summary_root/binary-generation.json"
rm -f "$package_root/Contents/MacOS/unregistered-tool"

print -n "synthetic unregistered model" \
  > "$package_root/Contents/unregistered-model.onnx"
expect_failure "frozen-manifest-rejects-unregistered-model" \
  "$repository_root/script/validate_release_package.sh" \
  "${validator_arguments[@]}" \
  --sbom "$test_root/sbom.json" \
  --manifest "$test_root/release-manifest.json" \
  --summary "$summary_root/unregistered-model.json"
expect_failure "generator-rejects-unregistered-model" \
  "$repository_root/script/generate_supply_chain.sh" \
  "${generator_arguments[@]}" \
  --sbom "$test_root/model-sbom.json" \
  --manifest "$test_root/model-manifest.json" \
  --validation-summary "$summary_root/model-generation.json"
rm -f "$package_root/Contents/unregistered-model.onnx"

plutil -insert FixtureMutation -string planted \
  "$package_root/Contents/Info.plist"
expect_failure "frozen-manifest-rejects-digest-mismatch" \
  "$repository_root/script/validate_release_package.sh" \
  "${validator_arguments[@]}" \
  --sbom "$test_root/sbom.json" \
  --manifest "$test_root/release-manifest.json" \
  --summary "$summary_root/digest-mismatch.json"

print "supply-chain fixtures passed: valid, unregistered binary/model, digest mismatch"
