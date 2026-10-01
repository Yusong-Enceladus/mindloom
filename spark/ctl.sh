#!/bin/bash
# Control the organizer service and its embedding server on the Spark (user space, no sudo, no docker).
# Usage: ctl.sh start|stop|restart|status|logs | lock | unlock-synthetic | gate-wrapper <abs path>
#        | embed-start|embed-stop|embed-status|embed-logs
#
# Privacy (docs/PRIVACY.md): the store is encrypted and starts LOCKED after every start. The user's Mac unlocks
# it over its SSH tunnel with a key that never touches this disk. `lock` locks it now. `unlock-synthetic` is
# for harnesses on synthetic data only (eval runs, scale runs, demos): it unlocks with the fixed public
# synthetic key (organizer/keys.py), which a real library never uses; a store that belongs to another key
# answers 409 and stays locked.
#
# Organizer: python -m organizer on the Unix socket $DATA/organizer.sock only. The Mac forwards to
# the socket over SSH and this script talks to it directly: the data directory is 0700, so no other
# local process can stand in for the organizer there, even while it is stopped, and the link token
# is never sent to a TCP port another user could hold. ORGANIZER_TCP=1 additionally serves
# 127.0.0.1:$ORGANIZER_PORT (explicit opt-in; nothing here uses it).
# Embedding: vLLM pooling runner for Qwen3-Embedding-0.6B on 127.0.0.1:8002 (serve_embed.sh).
#
# gate-wrapper <abs path>: write a small zhiji-inbox wrapper for THIS instance (its venv and data directory
# baked in). A phone key's forced command must be one absolute path, so an instance outside the default
# directories pairs phones through its wrapper: `<wrapper> authorize-phone …` writes the wrapper's path into
# authorized_keys (docs/PHONE.md).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)          # .../organizer/spark
ROOT=$(dirname "$HERE")                      # .../organizer (contains spark/ and skills/)
VENV=${ORGANIZER_VENV:-$HOME/hack/organizer-venv}
DATA=${ORGANIZER_DATA_DIR:-$HOME/hack/organizer-data}
# Separate instances keep separate pid files and logs (the service logs ids and counts, never content).
RUN=${ORGANIZER_RUN_DIR:-$HOME/hack/run}
LOGS=${ORGANIZER_LOG_DIR:-$HOME/hack/logs}
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

# POST to the organizer over the socket, the token read inside Python (never in argv or env).
# $1 = path, $2 = "synthetic-key" to send the fixed synthetic library key as {"key": ...}.
post() {
  [ -S "$SOCK" ] || { echo "no organizer socket at $SOCK"; return 1; }
  ( cd "$HERE" && ORGANIZER_CTL_DATA="$DATA" ORGANIZER_CTL_SOCK="$SOCK" "$VENV/bin/python" - "$1" "${2:-}" <<'PY'
import json, os, pathlib, sys
import httpx
path, body = sys.argv[1], sys.argv[2]
data = pathlib.Path(os.environ["ORGANIZER_CTL_DATA"])
tok = (data / "link_token").read_text().strip() if (data / "link_token").exists() else ""
payload = {}
if body == "synthetic-key":
    from organizer.keys import synthetic_library_key
    payload = {"key": synthetic_library_key().hex()}
with httpx.Client(transport=httpx.HTTPTransport(uds=os.environ["ORGANIZER_CTL_SOCK"]), timeout=600,
                  trust_env=False) as c:
    r = c.post("http://organizer" + path, json=payload, headers={"Authorization": "Bearer " + tok})
print(r.status_code, json.dumps(r.json(), ensure_ascii=False))
raise SystemExit(0 if r.status_code == 200 else 1)
PY
  )
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
      ORGANIZER_LOG_FILE="$LOGS/organizer.log" setsid nohup "$VENV/bin/python" -m organizer >> "$LOGS/organizer.log" 2>&1 < /dev/null &
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
  lock)
    post /v1/lock
    ;;
  unlock-synthetic)
    post /v1/unlock synthetic-key
    ;;
  gate-wrapper)
    DEST=${2:-}
    case "$DEST" in
      /*) ;;
      *) echo "usage: $0 gate-wrapper <absolute path of the wrapper to write>"; exit 2 ;;
    esac
    case "$DEST" in *[!A-Za-z0-9._/+-]*|*..*) echo "gate-wrapper: use only A-Z a-z 0-9 . _ / + - in the path"; exit 2 ;; esac
    # the gate lets a command through only when it names zhiji-inbox, so the wrapper keeps that name
    case "$DEST" in */zhiji-inbox) ;; *) echo "gate-wrapper: the wrapper must be called zhiji-inbox (…/zhiji-inbox)"; exit 2 ;; esac
    case "$VENV$DATA$HERE" in *"'"*) echo "gate-wrapper: the venv, data or code path contains a quote"; exit 2 ;; esac
    mkdir -p "$(dirname "$DEST")"
    TMP="$DEST.tmp.$$"
    cat > "$TMP" <<EOF
#!/bin/sh
# zhiji-inbox for the organizer instance whose data directory is $DATA (written by ctl.sh gate-wrapper).
export ORGANIZER_VENV='$VENV' ORGANIZER_DATA_DIR='$DATA' ZHIJI_INBOX_GATE='$DEST'
exec '$HERE/zhiji-inbox' "\$@"
EOF
    chmod 755 "$TMP" && mv -f "$TMP" "$DEST"
    echo "wrote $DEST"
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
    echo "usage: $0 start|stop|restart|status|logs | lock | unlock-synthetic | gate-wrapper <abs path> | embed-start|embed-stop|embed-status|embed-logs"; exit 2
    ;;
esac
