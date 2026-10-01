#!/bin/zsh
# End-to-end test of the agent access (AGENT-CONTRACT §4) with synthetic data:
# builds the `mindloom-mcp` helper and the synthetic-root harness with SwiftPM,
# then drives the helper over stdio with the Python MCP client.
#
#   script/agent_e2e/run.sh [--helper <path to a bundled mindloom-mcp>]
#
# The work folder must be short: a Unix socket path holds 103 bytes.
set -euo pipefail
repository_root="${0:A:h:h:h}"
source "$repository_root/script/build_storage.sh"
helper=""
if [[ "${1:-}" == "--helper" ]]; then helper="$2"; fi
swift build --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" -j 4 \
  --product mindloom-mcp
swift build --package-path "$repository_root/Packages/BestASRCore" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" --cache-path "$BESTASR_SWIFTPM_CACHE" -j 4 \
  --product MindloomAgentTestHost
products="$BESTASR_SWIFTPM_SCRATCH/debug"
work="$BESTASR_WORK_ROOT/agent-e2e"
mkdir -p "$work" "$BESTASR_BUILD_LOG_ROOT"
exec python3 "$repository_root/script/agent_e2e/mcp_e2e.py" \
  --helper "${helper:-$products/mindloom-mcp}" --host "$products/MindloomAgentTestHost" \
  --work "$work" --summary "$BESTASR_BUILD_LOG_ROOT/agent-e2e-summary.json"
