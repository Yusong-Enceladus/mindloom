# Deploying the demo organizer on a Spark

How the long-running demo instance that the Mac app talks to is deployed. It is separate from any development or evaluation instance on the same machine. It uses synthetic data only. `YOUR_SPARK` is the Spark's SSH alias on the Mac, and `/home/YOU` is the Spark user's home directory.

## Layout

The demo lives in its own directory and never shares a venv, data directory, pid file or port with other instances:

```
~/hack/zhiji-demo/
  app/      code from `git archive origin/main spark skills LICENSE README.md` (+ REVISION)
  venv/     organizer venv: fastapi, uvicorn, pydantic, httpx, pyyaml, sqlcipher3-wheels (+ pytest); file-read
            adds defusedxml, openpyxl, xlrd, pypdfium2, pillow, olefile (docs/FILE_READ.md)
  data/     0700: link_token (0600), organizer.db* (SQLCipher-encrypted), store.keyid (0600, the key id
            only), inbox.db (the phone inbox), organizer.sock
  logs/     organizer.log, embed.log
  units/    zhiji-demo-organizer.service, zhiji-demo-embed.service
  ctl.sh    start | stop | restart | status | health | logs [organizer|embed] [N] | reset --yes
```

`spark/ctl.sh` in this repository is not used for the demo. By default it keeps its pid files and logs under the shared `~/hack/run` and `~/hack/logs`; set `ORGANIZER_RUN_DIR` and `ORGANIZER_LOG_DIR` (with `ORGANIZER_DATA_DIR` and `ORGANIZER_VENV`) to run a separate instance with it.

## Privacy contract v6 (encrypted, locked at start)

- The store is encrypted with SQLCipher and **starts locked** after every (re)start. The Mac app unlocks it with its library key (`POST /v1/unlock`) over the SSH tunnel, as its first data call; the key lives only in the organizer's memory. While locked, `/v1/health` answers (`locked: true`, `key_id` of the store on disk) and every data route answers 423.
- A store from before v6 (plaintext `organizer.db`) is encrypted on its first unlock and the plaintext file is removed. The first key to unlock a store owns it: another key gets 409 until the store is wiped (`POST /v1/wipe`, the app's "让 Spark 忘掉我的内容").
- Harnesses on synthetic data unlock with the fixed synthetic key: `ctl.sh unlock-synthetic` (repository `spark/ctl.sh`), `eval/smoke_api.py` does it by itself. Never unlock a store that holds a real library with it (it only works on a store that key created).
- Install the new dependency into an existing venv: `venv/bin/pip install "sqlcipher3-wheels>=0.5.7"`.

## Services

Both services are systemd **user** units, installed into `~/.config/systemd/user/` and enabled for `default.target`. They need no sudo and no docker.

```ini
# zhiji-demo-embed.service: Qwen3-Embedding-0.6B, vLLM pooling runner, 127.0.0.1:8013
[Unit]
StartLimitIntervalSec=600
StartLimitBurst=5
[Service]
Environment=EMBED_PORT=8013
Environment=EMBED_GPU_UTIL=0.05
Environment=EMBED_MODEL_DIR=/home/YOU/hack/models/Qwen3-Embedding-0.6B
ExecStart=/bin/bash /home/YOU/hack/zhiji-demo/app/spark/serve_embed.sh
UMask=0077
Restart=on-failure
RestartSec=15
StandardOutput=append:/home/YOU/hack/zhiji-demo/logs/embed.log
StandardError=inherit
[Install]
WantedBy=default.target
```

```ini
# zhiji-demo-organizer.service: private Unix socket only
[Unit]
Wants=zhiji-demo-embed.service
After=zhiji-demo-embed.service
StartLimitIntervalSec=600
StartLimitBurst=5
[Service]
WorkingDirectory=/home/YOU/hack/zhiji-demo/app/spark
Environment=ORGANIZER_DATA_DIR=/home/YOU/hack/zhiji-demo/data
Environment=ORGANIZER_SKILLS_DIR=/home/YOU/hack/zhiji-demo/app/skills
Environment=ORGANIZER_UDS=/home/YOU/hack/zhiji-demo/data/organizer.sock
Environment=ORGANIZER_TCP=0
Environment=ORGANIZER_TZ=Asia/Shanghai
Environment=ORGANIZER_CLOCK=wall
Environment=ORGANIZER_LLM_URL=http://127.0.0.1:8000/v1
Environment=ORGANIZER_EMBED_URL=http://127.0.0.1:8013/v1
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/bin/mkdir -p /home/YOU/hack/zhiji-demo/data
ExecStartPre=/bin/chmod 700 /home/YOU/hack/zhiji-demo/data
ExecStart=/home/YOU/hack/zhiji-demo/venv/bin/python -m organizer
UMask=0077
Restart=on-failure
RestartSec=5
StandardOutput=append:/home/YOU/hack/zhiji-demo/logs/organizer.log
StandardError=inherit
[Install]
WantedBy=default.target
```

- **Chat model:** the organizer uses the chat model that already serves on `127.0.0.1:8000`. The demo does not manage it.
- **Embeddings:** the demo runs its own embedding server with a small memory reservation: about 1.1 GiB of weights plus a 4.2 GiB KV cache at `0.05`.
- **Socket permissions:** the socket file is 0666, but it sits in the 0700 data directory, so only the Spark user can reach it.
- **User manager:** check `loginctl show-user $USER -p Linger`.
  - With linger off, the user manager runs only while the user has a session. Long-running nohup processes keep their session open.
  - Once the user manager is gone, for example after a reboot, the next SSH login starts it again. That also starts the enabled units, and an `ssh -N` forward counts as a login.
  - The chat model must be restarted separately after a reboot.

## Operating it

```bash
~/hack/zhiji-demo/ctl.sh status        # unit states, embedding /v1/models, organizer health
~/hack/zhiji-demo/ctl.sh logs embed 100
~/hack/zhiji-demo/ctl.sh reset --yes   # stop organizer, delete everything in data/ except link_token, start
```

- **Health checks:** `ctl.sh` checks health over the socket with the link token. It pipes the header through `curl -H @-`, so the token never shows up in a process list.
- **Reset:** the token and socket path stay the same, but `store_id` changes. The Mac then clears its projection and re-sends the items it still has.
  - To start a demo from zero, reset the Spark and also launch the Mac app on a fresh synthetic data root.

To update the code from a checkout on the Mac:

```bash
git fetch && git archive --format=tar origin/main spark skills LICENSE README.md |
  ssh YOUR_SPARK 'cd ~/hack/zhiji-demo && rm -rf app.new && mkdir app.new && tar -x -C app.new && \
    rm -rf app.old && mv app app.old && mv app.new app' && \
  ssh YOUR_SPARK "echo $(git rev-parse origin/main) > ~/hack/zhiji-demo/app/REVISION && ~/hack/zhiji-demo/ctl.sh restart"
```

If `spark/pyproject.toml` gained dependencies, install them into the demo venv first.

## Mac app settings

The bestASR app has no settings UI for the link target yet. Write these preferences and relaunch the app. The host has no built-in default: until `preferences.spark-organizer-host` is written, the app keeps the link off and sends nothing. The bundle id is `com.bestasr.app` for Release and `com.bestasr.app.debug` for Debug.

```bash
defaults write com.bestasr.app preferences.spark-organizer-host YOUR_SPARK
defaults write com.bestasr.app preferences.spark-organizer-socket-path '~/hack/zhiji-demo/data/organizer.sock'
defaults write com.bestasr.app preferences.spark-organizer-token-path '~/hack/zhiji-demo/data/link_token'
```

- **Quoting:** keep the single quotes. The `~` is resolved on the Spark, not on the Mac.
- **What the app does:** it runs `cd <socket dir> && pwd -P` on the Spark to get the absolute socket path. It then forwards `127.0.0.1:<random port>` to that socket and reads the token with a separate `ssh YOUR_SPARK cat <token path>`.
- **SSH requirements:** both commands use `BatchMode=yes` and `StrictHostKeyChecking=yes`, so key login and a known-hosts entry must already work.
- **Data root:** launch the app on a synthetic data root. Create one with `script/make_synthetic_data_root.sh <abs path>` and pass `-BestASRDataRoot <path>`. The link does not send from the real library.
- **Switch:** turn on the Spark switch in Settings.

Manual check from the Mac:

```bash
ssh -N -L 127.0.0.1:18799:/home/YOU/hack/zhiji-demo/data/organizer.sock YOUR_SPARK &
TOKEN=$(ssh YOUR_SPARK cat hack/zhiji-demo/data/link_token)
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -s -H @- http://127.0.0.1:18799/v1/health; unset TOKEN; kill %1
```

## Acceptance at deployment

These checks passed when the demo was deployed from `3c65a4a`:

1. `pytest` on a full copy of the revision with the demo venv passed all 171 tests.
2. **Files and listeners:**
   - `data/` is 0700 and `link_token` is 0600.
   - The organizer holds no TCP listener.
   - A request without the token gets 401.
3. `/v1/health` returned:
   - `ok: true`
   - `retrieval_mode: embedding`, with the demo's own embedding server
   - `clock: wall`
4. **Round trip:** one fictional text item was posted once and then again.
   - The second post counted as a duplicate.
   - An event with a status line appeared in `/v1/state` about 4 s later.
5. **Reset:** `reset --yes` left 0 items and 0 events, gave a new `store_id` and kept the same token.
6. **Mac path:** an SSH forward from the Mac to the socket, plus the token read over ssh, returned `ok: true`. The same request without the token returned 401.

## Backfills and scale replays

A stream of items captured days or weeks before they reach the organizer (an import, a backfill, the
synthetic scale scenarios) is historical. Run it with the replay clock, never the wall clock:

```ini
Environment=ORGANIZER_CLOCK=replay
```

- **Why replay:** question expiry (72 h) and the home rank's "today" follow the organizer clock. With
  `wall` on a historical stream the first same_event and same_person questions are never answered and
  never expire, so the question budget stays full for the whole run: every later "unsure" becomes a
  provisional new event, every "these two events are one" question is dropped, and no person question is
  asked. All three scale runs of 2026-09-28 used `wall` and show exactly this.
- **Live use** (the Mac sending items as they are captured) keeps `wall`.
- `/v1/health` reports `clock_warning` when a wall-clock organizer processes an item captured more than
  two days earlier.
