#!/usr/bin/env python3
"""On-camera shot S3: Step3-VL reading a chat screenshot inside the organizer, on the Spark.

Run on the Spark against a throwaway organizer started by ops/step3_shot.sh (fictional data only, its own empty
store, ORGANIZER_IMAGE_ROUTER=stepfun-chat). For each image it posts a real intake item through the organizer's API,
waits for the reading, and prints which model answered each step, taken from the organizer's own run records
(/v1/debug/runs), and what was read. A chat screenshot shows Step3-VL for the extraction; a chart shows Qwen3.6.

  python3 ops/step3_shot.py --uds <data>/organizer.sock --token-file <data>/link_token IMG [IMG ...]
  --plain   no colors      --hold SECONDS   pause between lines (slow it down for the camera)
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import sys
import time
import uuid
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "spark"))
from organizer.keys import synthetic_library_key  # noqa: E402

NAMES = {"step3-vl-10b": "StepFun Step3-VL-10B", "qwen3.6-35b-a3b-nvfp4": "Qwen3.6-35B-A3B NVFP4"}
KINDS = {"chat_screenshot": "聊天截图", "chart_dashboard": "图表/看板", "slide": "幻灯片",
         "whiteboard_handwriting": "手写/白板", "receipt_invoice": "小票/发票", "scanned_document": "扫描件",
         "form_label_sign": "标签/面单/标牌", "other": "其他"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uds", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--plain", action="store_true")
    ap.add_argument("--hold", type=float, default=0.0)
    ap.add_argument("--default", action="append", default=[], help="images to read when none are named")
    ap.add_argument("images", nargs="*")
    a = ap.parse_args()
    a.images = a.images or a.default
    if not a.images:
        ap.error("no images")
    bold, dim, green, cyan, off = (("", "", "", "", "") if a.plain else
                                   ("\033[1m", "\033[2m", "\033[32m", "\033[36m", "\033[0m"))

    def say(text: str = "") -> None:
        print(text, flush=True)
        time.sleep(a.hold)

    headers = {"Authorization": "Bearer " + Path(a.token_file).read_text(encoding="ascii").strip()}
    with httpx.Client(base_url="http://organizer", transport=httpx.HTTPTransport(uds=a.uds), timeout=30,
                      trust_env=False, headers=headers) as c:
        if c.get("/v1/health").json().get("locked"):  # fictional data: the fixed synthetic key, as in eval/smoke_api.py
            c.post("/v1/unlock", json={"key": synthetic_library_key().hex()}).raise_for_status()
        say(f"{bold}织机整理器 · 读图路由{off}   聊天截图 → StepFun Step3-VL    其余图片 → Qwen3.6 NVFP4    "
            f"{dim}（虚构数据）{off}")
        say()
        for n, path in enumerate(a.images):
            data = Path(path).read_bytes()
            item_id = str(uuid.uuid4())
            started = time.time()
            item = {"item_id": item_id, "revision": 0, "kind": "image", "source_app": {"name": "微信"},
                    "started_at": time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime(started)),
                    "image_b64": base64.b64encode(data).decode(), "sha256": hashlib.sha256(data).hexdigest()}
            c.post("/v1/items", json={"items": [item]}).raise_for_status()
            say(f"[{0.0:5.1f} s] 收到图片 {Path(path).name}")
            reading, deadline, printed = None, started + 240, set()

            def show_steps() -> None:
                runs = [r for r in c.get("/v1/debug/runs?limit=50").json()["runs"]
                        if r.get("subject") == item_id and r["job_type"] in ("image_detect", "image_read")]
                for r in sorted(runs, key=lambda r: r["started_at"]):
                    if r["run_id"] in printed:
                        continue
                    printed.add(r["run_id"])
                    what = "判断类型" if r["job_type"] == "image_detect" else "读取内容"
                    model = NAMES.get(r["model"], r["model"])
                    tag = f"{green}{model}{off}" if "step3" in (r["model"] or "") else f"{cyan}{model}{off}"
                    say(f"[{r['ended_at'] - started:5.1f} s] {what:<4} → {tag}   {dim}（用时 {r['ended_at'] - r['started_at']:.1f} s）{off}")

            while time.time() < deadline:
                show_steps()                      # each step is printed when its run is recorded, in real time
                reading = c.get("/v1/state").json().get("readings", {}).get(item_id)
                if reading:
                    show_steps()
                    break
                time.sleep(0.25)
            if not reading:
                say("读图超时")
                return 1
            say(f"          类型：{KINDS.get(reading['type'], reading['type'])}    {dim}{reading.get('summary', '')}{off}")
            for m in reading["messages"][:6]:
                who = "我" if m.get("is_self") else m.get("sender") or "?"
                say(f"            {who:<4} {m.get('time') or '     ':<6} {m.get('text', '')[:34]}")
            if n < len(a.images) - 1:
                while time.time() < deadline and c.get("/v1/health").json().get("queue"):  # placement done, then the next
                    time.sleep(0.3)
                say()
        say()
        reads = c.get("/v1/infra/health").json()["organizer"].get("image_reads") or {}
        for kind, models in sorted(reads.get("reads", {}).items()):
            for model, count in sorted(models.items()):
                say(f"读图计数  {KINDS.get(kind, kind):<8} → {NAMES.get(model, model)} × {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
