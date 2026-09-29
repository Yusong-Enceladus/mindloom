#!/usr/bin/env bash
# Control only this isolated demonstration deployment, never the shared chat model.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=${MEMORY_DEMO_ROOT:-$(cd -- "$HERE/../.." && pwd)}
# Unit names; override to manage units started under other names.
ORG=${MEMORY_DEMO_ORG_UNIT:-memory-demo-organizer.service}
EMBED=${MEMORY_DEMO_EMBED_UNIT:-memory-demo-embed.service}

start_existing() {
  if [ "$(systemctl --user show "$1" -p LoadState --value)" = loaded ]; then
    systemctl --user start "$1"
    return 0
  fi
  return 1
}

case "${1:-status}" in
  start)
    test -x "$ROOT/venv/bin/python"
    test -f "$ROOT/source/spark/organizer/api.py"
    if ! start_existing "$EMBED"; then
      systemd-run --user --unit="$EMBED" --property=UMask=0077 \
        --setenv=VLLM_NO_USAGE_STATS=1 --setenv=DO_NOT_TRACK=1 \
        --setenv=HF_HUB_OFFLINE=1 --setenv=HF_HUB_DISABLE_TELEMETRY=1 \
        --setenv=CUDA_HOME=/usr/local/cuda-13.0 \
        --setenv="PATH=$HOME/hack/vllm-venv/bin:/usr/local/cuda-13.0/bin:/usr/bin:/bin" \
        --setenv="CPATH=$HOME/hack/pydev/root/usr/include/python3.12:$HOME/hack/pydev/root/usr/include" \
        --setenv=MAX_JOBS=4 --setenv=FLASHINFER_NVCC_THREADS=1 \
        "$HOME/hack/vllm-venv/bin/vllm" serve "$HOME/hack/models/Qwen3-Embedding-0.6B" \
        --served-model-name qwen3-embedding-0.6b --runner pooling --host 127.0.0.1 --port 8003 \
        --gpu-memory-utilization 0.06 --max-model-len 8192 --max-num-seqs 16 --enforce-eager
    fi
    mkdir -p "$ROOT/demo-data"
    chmod 700 "$ROOT/demo-data"
    if ! start_existing "$ORG"; then
      systemd-run --user --unit="$ORG" --property="WorkingDirectory=$ROOT/source/spark" \
        --property=Restart=on-failure --property=RestartSec=5 --property=UMask=0077 \
        --setenv="ORGANIZER_DATA_DIR=$ROOT/demo-data" --setenv="ORGANIZER_SKILLS_DIR=$ROOT/source/skills" \
        --setenv="ORGANIZER_UDS=$ROOT/demo-data/organizer.sock" \
        --setenv=ORGANIZER_EMBED_URL=http://127.0.0.1:8003/v1 \
        --setenv=ORGANIZER_LLM_URL=http://127.0.0.1:8000/v1 \
        "$ROOT/venv/bin/python" -m organizer
    fi
    echo 'Processes started; allow the embedding model to load, then run status.'
    ;;
  status)
    systemctl --user show "$ORG" "$EMBED" -p Id -p ActiveState -p SubState -p NRestarts
    # Over the private socket only (never a TCP port another user could hold). The link token is
    # read inside Python from the data directory, never passed in argv or env.
    MEMORY_DEMO_DATA="$ROOT/demo-data" "$ROOT/venv/bin/python" -c 'import httpx,json,os,pathlib; d=pathlib.Path(os.environ["MEMORY_DEMO_DATA"]); tok=(d/"link_token").read_text().strip(); c=httpx.Client(transport=httpx.HTTPTransport(uds=str(d/"organizer.sock")),timeout=15,trust_env=False); r=c.get("http://organizer/v1/health",headers={"Authorization":"Bearer "+tok}); r.raise_for_status(); h=r.json(); print(json.dumps(h,ensure_ascii=False,indent=2)); raise SystemExit(0 if h["ok"] and h["embed_model"] else 1)'
    ;;
  stop)
    systemctl --user stop "$ORG" "$EMBED"
    echo 'Only the isolated organizer and its embedding service were stopped. Data is preserved.'
    ;;
  logs)
    journalctl --user -u "$ORG" -u "$EMBED" -n "${2:-60}" --no-pager
    ;;
  *) echo 'Usage: bash ops/spark_demo.sh start|status|stop|logs [lines]' >&2; exit 2 ;;
esac
