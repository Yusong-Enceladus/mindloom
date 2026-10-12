#!/bin/bash
# Step3-VL-10B (StepFun) Q8_0 + F16 vision projector, served by llama.cpp on 127.0.0.1 only.
# User space, no sudo, no docker. Restart-on-crash through a setsid supervisor, because Linger=no on the
# demo Spark (a systemd --user unit would stop at logout). It only manages its own pid files and log.
#
# Layout on the Spark (the files are copied once from the node that built them; sha256 checked):
#   ~/hack/stepfun/llama-bin/llama-server        llama.cpp d834d44 build (CUDA 13, sm_121)
#   ~/hack/stepfun/models/Step3-VL-10B-Q8_0.gguf
#   ~/hack/stepfun/models/mmproj-Step3-VL-10B-F16.gguf
#   ~/hack/stepfun/run/  logs/
#
# Usage: step3vl_ctl.sh start|stop|restart|status|health|logs [N]
# Env:   PORT (30001)  CTX (32768)  NP (2 slots; the context is split between them)
set -u
D=${STEPFUN_DIR:-$HOME/hack/stepfun}; RUN=$D/run; LOG=$D/logs/step3vl.log
PORT=${PORT:-30001}; CTX=${CTX:-32768}; NP=${NP:-2}
mkdir -p "$RUN" "$D/logs"
alive() { [ -f "$RUN/step3vl.sup" ] && kill -0 "$(cat "$RUN/step3vl.sup")" 2>/dev/null; }
serve() {
  export LD_LIBRARY_PATH=$D/llama-bin
  exec "$D/llama-bin/llama-server" \
    -m "$D/models/Step3-VL-10B-Q8_0.gguf" --mmproj "$D/models/mmproj-Step3-VL-10B-F16.gguf" \
    --alias step3-vl-10b --host 127.0.0.1 --port "$PORT" \
    -ngl 99 -fa on -c "$CTX" -np "$NP" -b 2048 -ub 2048 -lm none --no-webui --metrics
}
supervise() {
  rm -f "$RUN/step3vl.stop"; n=0
  while true; do
    echo "[supervise $(date '+%F %T')] starting step3-vl-10b on 127.0.0.1:$PORT (ctx $CTX, slots $NP)"
    serve &
    CHILD=$!; echo $CHILD > "$RUN/step3vl.child"
    wait $CHILD; rc=$?
    [ -f "$RUN/step3vl.stop" ] && { echo "[supervise $(date '+%F %T')] stopped (rc=$rc)"; exit 0; }
    n=$((n+1)); echo "[supervise $(date '+%F %T')] exited rc=$rc; restart #$n in 15 s"
    [ $n -ge 10 ] && { echo "[supervise] giving up after $n restarts"; exit 1; }
    sleep 15
  done
}
health() { curl -s -m 5 "http://127.0.0.1:$PORT/health"; echo; }
case "${1:-status}" in
  _supervise) supervise ;;
  start)
    if alive; then echo "already running (supervisor $(cat "$RUN/step3vl.sup"))"; exit 0; fi
    setsid nohup "$0" _supervise >> "$LOG" 2>&1 < /dev/null &
    echo $! > "$RUN/step3vl.sup"
    for _ in $(seq 1 120); do
      curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { echo "ready"; exit 0; }
      alive || { echo "supervisor exited; see $LOG" >&2; exit 1; }
      sleep 1
    done
    echo "not ready after 120 s; see $LOG" >&2; exit 1 ;;
  stop)
    if ! alive; then echo "not running"; rm -f "$RUN/step3vl.sup" "$RUN/step3vl.child"; exit 0; fi
    sup=$(cat "$RUN/step3vl.sup"); touch "$RUN/step3vl.stop"
    [ -f "$RUN/step3vl.child" ] && kill -TERM "$(cat "$RUN/step3vl.child")" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$sup" 2>/dev/null || break; sleep 1; done
    kill -TERM -- -"$sup" 2>/dev/null
    rm -f "$RUN/step3vl.sup" "$RUN/step3vl.child"; echo "stopped" ;;
  restart) "$0" stop; "$0" start ;;
  status)
    if alive; then echo "running: supervisor $(cat "$RUN/step3vl.sup"), server $(cat "$RUN/step3vl.child" 2>/dev/null)"; else echo "stopped"; fi
    health ;;
  health) health ;;
  logs) tail -n "${2:-60}" "$LOG" ;;
  *) echo "usage: $0 start|stop|restart|status|health|logs [N]"; exit 2 ;;
esac
