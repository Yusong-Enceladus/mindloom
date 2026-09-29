#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-consistency-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

"$repository_root/script/validate_product_consistency.sh" \
  --contract "$repository_root/config/product-consistency.json" \
  --summary "$temporary_root/valid-summary.json" >/dev/null

if "$repository_root/script/validate_product_consistency.sh" \
  --contract "$repository_root/Tests/Fixtures/Consistency/planted-conflict.json" \
  --summary "$temporary_root/conflict-summary.json" >/dev/null 2>&1; then
  print -u2 "expected planted product conflict to fail"
  exit 1
fi

[[ "$(jq -r '.status' "$temporary_root/conflict-summary.json")" == "fail" ]]
[[ "$(jq -r '.failureCategory' "$temporary_root/conflict-summary.json")" \
  == "planted-or-live-constraint-conflict" ]]

print "product consistency fixtures passed: 5 live invariants plus planted conflict"
