#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
# The old AX direct-write probe is historical evidence, not the current delivery policy.
summary_path="$repository_root/artifacts/evidence/text-delivery/contract-summary.json"

while (( $# > 0 )); do
  case "$1" in
    --summary)
      summary_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

mkdir -p "$(dirname "$summary_path")"
# A failed or interrupted run must not leave yesterday's passing evidence in place.
rm -f "$summary_path"
source "$repository_root/script/build_storage.sh"
run_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-delivery-contract.XXXXXX")"
trap 'rm -rf "$run_root"' EXIT
test_exit_code=0
swift test \
  --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --parallel \
  --filter '^BestASRDeliveryTests\.(DeliveryInsertionPortTests|DeliveryVerdictTests|PasteboardPromiseTests|BoundarySpacingTests)/' \
  --xunit-output "$run_root/tests.xml" || test_exit_code=$?

python3 "$repository_root/script/delivery_contract_evidence.py" \
  --xunit "$run_root/tests.xml" \
  --test-exit-code "$test_exit_code" \
  --summary "$summary_path"
