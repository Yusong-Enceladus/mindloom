#!/bin/bash
# Shot S3 (15-25 s): StepFun Step3-VL reading a chat screenshot inside the organizer, on the Spark.
# A throwaway organizer (its own empty store, fictional data only) runs next to the Step3-VL service
# (ops/step3vl_ctl.sh) and the Qwen3.6 server that already serves on 127.0.0.1:8000. It never touches the demo or
# preview instances.
#
#   ops/step3_shot.sh up        start the throwaway organizer (not on camera)
#   ops/step3_shot.sh run IMG..  on camera: read the images through the real intake API (default: the fictional
#                                chat screenshot and one chart); add --hold 0.4 to slow the printing down
#   ops/step3_shot.sh capture    the same, plain text with a seconds stamp on every line (feeds render_terminal_frames.py)
#   ops/step3_shot.sh log       the organizer's own log lines for the reads (counts only, no content)
#   ops/step3_shot.sh down      stop it and delete its data
#
# Env: APP (code checkout, default ~/hack/stepfun/app)  PY (a python with the organizer's dependencies)
#      QWEN_URL (default http://127.0.0.1:8000/v1)  STEP3_URL (default http://127.0.0.1:30001)
set -u
APP=${APP:-$HOME/hack/stepfun/app}; PY=${PY:-$HOME/hack/mindloom-preview/venv/bin/python}
D=${SHOT_DIR:-$HOME/hack/stepfun/shot}; DATA=$D/data; RUN=$D/run
QWEN_URL=${QWEN_URL:-http://127.0.0.1:8000/v1}; STEP3_URL=${STEP3_URL:-http://127.0.0.1:30001}
alive() { [ -f "$RUN/organizer.pid" ] && kill -0 "$(cat "$RUN/organizer.pid")" 2>/dev/null; }
case "${1:-}" in
  up)
    if alive; then echo "already running"; exit 0; fi
    mkdir -p "$DATA" "$RUN"; chmod 700 "$D" "$DATA"
    cd "$APP/spark" || exit 1
    ORGANIZER_DATA_DIR=$DATA ORGANIZER_SKILLS_DIR=$APP/skills ORGANIZER_UDS=$DATA/organizer.sock ORGANIZER_TCP=0 \
    ORGANIZER_LLM_URL=$QWEN_URL ORGANIZER_EMBED_URL= ORGANIZER_CLOCK=wall ORGANIZER_TZ=Asia/Shanghai ORGANIZER_WORKERS=1 \
    ORGANIZER_IMAGE_ROUTER=stepfun-chat ORGANIZER_STEP3_URL=$STEP3_URL ORGANIZER_LOG_FILE=$D/organizer.log \
    PYTHONUNBUFFERED=1 setsid nohup "$PY" -m organizer >> "$D/organizer.log" 2>&1 < /dev/null &
    echo $! > "$RUN/organizer.pid"
    for _ in $(seq 1 60); do [ -S "$DATA/organizer.sock" ] && [ -f "$DATA/link_token" ] && { echo "ready"; exit 0; }; sleep 1; done
    echo "not ready; see $D/organizer.log" >&2; exit 1 ;;
  run)
    shift
    exec "$PY" "$APP/ops/step3_shot.py" --uds "$DATA/organizer.sock" --token-file "$DATA/link_token" \
      --default "$APP/eval/scenarios/dev-week-v1/assets/d2-03.png" --default "$APP/eval/multimodal/images/chart-03.png" "$@" ;;
  capture)
    # the same run, plain text, each line stamped with the seconds since the start (for ops/render_terminal_frames.py)
    shift
    "$0" run --plain "$@" | "$PY" -c "import sys,time; t0=time.time()
for l in sys.stdin:
    print('%.2f\t%s' % (time.time()-t0, l.rstrip('\n')), flush=True)" ;;
  log)
    grep -E "image_router|image-read" "$D/organizer.log" | sed -E 's/^[0-9-]+ //' | tail -n "${2:-20}" ;;
  down)
    if alive; then kill -TERM "$(cat "$RUN/organizer.pid")"; sleep 2; fi
    case "$D" in */hack/stepfun/shot) find "$D" -mindepth 1 -delete; rmdir "$D" ;; esac
    echo "stopped, data removed" ;;
  *) echo "usage: $0 up | run [IMG ...] | capture [IMG ...] | log [N] | down"; exit 2 ;;
esac
