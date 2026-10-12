#!/usr/bin/env bash
# Isolated synthetic finals organizer. The existing Qwen/embedding services are never managed here.
set -euo pipefail
D=${FINALS_DEMO_ROOT:-$HOME/hack/mindloom-finals-demo}
export ORGANIZER_VENV="$D/venv" ORGANIZER_DATA_DIR="$D/demo-data"
export ORGANIZER_RUN_DIR="$D/run" ORGANIZER_LOG_DIR="$D/logs"
export ORGANIZER_LLM_URL=${FINALS_QWEN_URL:-http://127.0.0.1:8000/v1}
export ORGANIZER_EMBED_URL=${FINALS_EMBED_URL:-http://127.0.0.1:8013/v1}
export ORGANIZER_IMAGE_ROUTER=stepfun-chat
export ORGANIZER_STEP3_URL=${FINALS_STEP3_URL:-http://127.0.0.1:30011}
export ORGANIZER_CLOCK=wall ORGANIZER_TZ=Asia/Shanghai ORGANIZER_WORKERS=1
CTL="$D/source/spark/ctl.sh"
check_organizer_pid() {
  "$ORGANIZER_VENV/bin/python" - "$D" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
p = d / "run/organizer.pid"
if p.exists():
    pid = p.read_text().strip()
    proc = pathlib.Path("/proc") / pid / "cmdline"
    if proc.exists():
        args = proc.read_bytes().split(b"\0")
        expected = [str(d / "venv/bin/python").encode(), b"-m", b"organizer"]
        if args[:3] != expected:
            raise SystemExit("Refusing to manage a PID that is not this demo organizer.")
PY
}
case "${1:-status}" in
  start)
    test -x "$ORGANIZER_VENV/bin/python"
    "$ORGANIZER_VENV/bin/python" -c 'import uvicorn, fastapi, httpx, sqlcipher3'
    check_organizer_pid
    bash "$CTL" gate-wrapper "$D/zhiji-inbox"
    bash "$CTL" start
    "$ORGANIZER_VENV/bin/python" - "$D" <<'PY'
import pathlib, sys
import httpx
d = pathlib.Path(sys.argv[1]) / "demo-data"
with httpx.Client(transport=httpx.HTTPTransport(uds=str(d / "organizer.sock")), timeout=10,
                  trust_env=False) as c:
    r = c.get("http://organizer/v1/health",
              headers={"Authorization": "Bearer " + (d / "link_token").read_text().strip()})
    r.raise_for_status()
    h = r.json()
    if not h.get("ok"):
        raise SystemExit("Organizer health failed; run finals_demo.sh status.")
print("Organizer health confirmed; run status to check the optional image model.")
PY
    ;;
  stop) check_organizer_pid; bash "$CTL" stop ;;
  status)
    for endpoint in /v1/health /v1/infra/health; do
      "$ORGANIZER_VENV/bin/python" "$D/source/spark/owner-call.py" GET "$endpoint" < /dev/null
    done
    ;;
  logs) bash "$CTL" logs "${2:-30}" ;;
  step3-start|step3-stop|step3-status)
    action=${1#step3-}
    export STEPFUN_DIR="$D/stepfun" PORT=30011
    test -x "$STEPFUN_DIR/llama-bin/llama-server"
    test -f "$STEPFUN_DIR/models/Step3-VL-10B-Q8_0.gguf"
    test -f "$STEPFUN_DIR/models/mmproj-Step3-VL-10B-F16.gguf"
    "$D/source/ops/step3vl_ctl.sh" "$action"
    ;;
  *) echo 'Usage: finals_demo.sh start|stop|status|logs [N]|step3-start|step3-stop|step3-status' >&2; exit 2 ;;
esac
