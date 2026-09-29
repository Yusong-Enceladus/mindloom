#!/bin/bash
# Control the organizer service and its embedding server on the Spark (user space, no sudo, no docker).
# Usage: ctl.sh start|stop|restart|status|logs | embed-start|embed-stop|embed-status|embed-logs
#
# Organizer: python -m organizer on the Unix socket $DATA/organizer.sock only. The Mac forwards to
# the socket over SSH and this script talks to it directly: the data directory is 0700, so no other
# local process can stand in for the organizer there, even while it is stopped, and the link token
# is never sent to a TCP port another user could hold. ORGANIZER_TCP=1 additionally serves
# 127.0.0.1:$ORGANIZER_PORT (explicit opt-in; nothing here uses it).
# Embedding: vLLM pooling runner for Qwen3-Embedding-0.6B on 127.0.0.1:8002 (serve_embed.sh).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)          # .../organizer/spark
ROOT=$(dirname "$HERE")                      # .../organizer (contains spark/ and skills/)
VENV=${ORGANIZER_VENV:-$HOME/hack/organizer-venv}
DATA=${ORGANIZER_DATA_DIR:-$HOME/hack/organizer-data}
RUN=$HOME/hack/run
LOGS=$HOME/hack/logs
PIDFILE=$RUN/organizer.pid
EPIDFILE=$RUN/embed.pid
PORT=${ORGANIZER_PORT:-8765}
SOCK=$DATA/organizer.sock
mkdir -p "$RUN" "$LOGS" "$DATA"
chmod 700 "$DATA"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# GET /v1/health with the link token, over the private socket only. The header goes through stdin,
# so the token never appears in a process argument list.
health() {
  [ -S "$SOCK" ] || { echo "no organizer socket at $SOCK"; return 1; }
  local tok=""
  [ -f "$DATA/link_token" ] && tok=$(< "$DATA/link_token")
  printf 'Authorization: Bearer %s\n' "$tok" | curl -s -m "$1" --unix-socket "$SOCK" -H @- "http://organizer/v1/health"
}

stop_pid() {
  local f=$1
  if alive "$f"; then
    local p; p=$(cat "$f")
    kill "$p" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    kill -0 "$p" 2>/dev/null && kill -9 "$p"
  fi
  rm -f "$f"
}

case "${1:-status}" in
  start)
    if alive "$PIDFILE"; then echo "organizer already running pid $(cat "$PIDFILE")"; exit 0; fi
    (
      cd "$HERE" || exit 1
      umask 077
      ORGANIZER_DATA_DIR="$DATA" ORGANIZER_SKILLS_DIR="$ROOT/skills" \
      ORGANIZER_HOST=127.0.0.1 ORGANIZER_PORT="$PORT" ORGANIZER_TCP="${ORGANIZER_TCP:-0}" \
      ORGANIZER_UDS="$SOCK" \
      ORGANIZER_LLM_URL="${ORGANIZER_LLM_URL:-http://127.0.0.1:8000/v1}" \
      ORGANIZER_EMBED_URL="${ORGANIZER_EMBED_URL:-http://127.0.0.1:8002/v1}" \
      setsid nohup "$VENV/bin/python" -m organizer > "$LOGS/organizer.log" 2>&1 < /dev/null &
      echo $! > "$PIDFILE"
    )
    for _ in $(seq 1 30); do
      alive "$PIDFILE" || break
      health 2 > /dev/null && break
      sleep 1
    done
    echo "organizer pid $(cat "$PIDFILE"); log $LOGS/organizer.log"
    health 5; echo
    ;;
  stop)
    stop_pid "$PIDFILE"; echo "organizer stopped"
    ;;
  restart)
    "$0" stop; "$0" start
    ;;
  status)
    if alive "$PIDFILE"; then
      echo "organizer running pid $(cat "$PIDFILE")"
      health 5; echo
    else
      echo "organizer not running"
    fi
    if alive "$EPIDFILE"; then echo "embedding running pid $(cat "$EPIDFILE")"; else echo "embedding not running"; fi
    ;;
  logs)
    tail -n "${2:-60}" "$LOGS/organizer.log"
    ;;
  embed-start)
    if alive "$EPIDFILE"; then echo "embedding already running pid $(cat "$EPIDFILE")"; exit 0; fi
    setsid nohup "$HERE/serve_embed.sh" > "$LOGS/embed.log" 2>&1 < /dev/null &
    echo $! > "$EPIDFILE"
    echo "embedding pid $(cat "$EPIDFILE"); log $LOGS/embed.log; ready in ~1-2 min: curl -s 127.0.0.1:8002/v1/models"
    ;;
  embed-stop)
    stop_pid "$EPIDFILE"; echo "embedding stopped"
    ;;
  embed-status)
    if alive "$EPIDFILE"; then echo "embedding running pid $(cat "$EPIDFILE")"; else echo "embedding not running"; fi
    curl -s -m 5 http://127.0.0.1:8002/v1/models | head -c 300; echo
    ;;
  embed-logs)
    tail -n "${2:-60}" "$LOGS/embed.log"
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|logs | embed-start|embed-stop|embed-status|embed-logs"; exit 2
    ;;
esac
