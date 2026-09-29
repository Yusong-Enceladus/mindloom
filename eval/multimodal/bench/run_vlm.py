#!/usr/bin/env python3
"""Run one VLM endpoint over a split of the mm-v1 eval set and save raw outputs (JSONL).

Standard library only, meant to run on the Spark next to the server (loopback URL), so the measured
latency is the model's, not the SSH tunnel's. Every request uses the frozen prompt and JSON schema from
prompts.py, temperature 0, thinking disabled, and one image as an inline data URI.

  --backend openai   POST {url}/v1/chat/completions (vLLM, llama.cpp server); JSON schema in response_format
  --backend step3    llama.cpp native /completion with an empty <think></think> prefilled and the schema in
                     "json_schema" (Step3-VL always thinks through the chat template; same as the organizer's
                     Step3LlamaNativeClient)

Resumable: ids already present in --out are skipped. A GPU-memory and server-load snapshot is written
next to the output at the start and the end of the run.

  python3 run_vlm.py --root mm --split test --backend openai --url http://127.0.0.1:30000 \
      --label qwen36-q8-llamacpp --concurrency 1 --out out/qwen36-q8.r1.jsonl
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prompts  # noqa: E402


def http_json(url: str, body: dict | None = None, timeout: float = 900.0) -> tuple[int, dict | str]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            status = r.status
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:2000]
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw


def data_uri(path: Path) -> str:
    raw = path.read_bytes()
    mime = "image/png" if raw.startswith(b"\x89PNG") else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(raw).decode()}"


class OpenAIBackend:
    def __init__(self, url: str, model: str | None, max_tokens: int):
        self.url = url.rstrip("/").removesuffix("/v1")
        self.max_tokens = max_tokens
        if not model:
            _, models = http_json(self.url + "/v1/models", timeout=30)
            model = models["data"][0]["id"]
        self.model = model

    def call(self, image_type: str, uri: str) -> dict:
        body = {
            "model": self.model,
            "messages": prompts.messages_for(image_type, uri),
            "temperature": 0,
            "max_tokens": self.max_tokens,
            "chat_template_kwargs": {"enable_thinking": False},
            "response_format": {"type": "json_schema", "json_schema": {
                "name": image_type, "schema": prompts.schema_for(image_type), "strict": True}},
        }
        status, data = http_json(self.url + "/v1/chat/completions", body)
        if status != 200 or not isinstance(data, dict):
            return {"status": status, "error": str(data)[:1000], "content": ""}
        choice = data["choices"][0]
        usage = data.get("usage") or {}
        t = data.get("timings") or {}
        return {"status": status, "content": choice["message"].get("content") or "",
                "finish_reason": choice.get("finish_reason"),
                "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
                "server_prompt_ms": t.get("prompt_ms"), "server_predicted_ms": t.get("predicted_ms")}


class Step3Backend:
    def __init__(self, url: str, model: str | None, max_tokens: int):
        self.url = url.rstrip("/").removesuffix("/v1")
        self.max_tokens = max_tokens
        _, props = http_json(self.url + "/props", timeout=30)
        self.marker = props["media_marker"]
        self.model = model or "step3-vl-10b"

    def call(self, image_type: str, uri: str) -> dict:
        blocks, images = [], []
        for m in prompts.messages_for(image_type, uri):
            parts = [{"type": "text", "text": m["content"]}] if isinstance(m["content"], str) else m["content"]
            text = ""
            for p in parts:
                if p["type"] == "text":
                    text += p["text"].replace("<|", "\\u003c|")
                else:
                    images.append(p["image_url"]["url"].split(",", 1)[1])
                    text += self.marker
            blocks.append(f"<|im_start|>{m['role']}\n{text}<|im_end|>\n")
        prompt = "".join(blocks) + "<|im_start|>assistant\n<think>\n\n</think>\n"
        body = {"prompt": {"prompt_string": prompt, "multimodal_data": images}, "n_predict": self.max_tokens,
                "temperature": 0, "cache_prompt": False, "json_schema": prompts.schema_for(image_type)}
        status, data = http_json(self.url + "/completion", body)
        if status != 200 or not isinstance(data, dict):
            return {"status": status, "error": str(data)[:1000], "content": ""}
        t = data.get("timings") or {}
        finish = "length" if data.get("stop_type") == "limit" else "stop"
        return {"status": status, "content": data.get("content") or "", "finish_reason": finish,
                "prompt_tokens": t.get("prompt_n"), "completion_tokens": t.get("predicted_n"),
                "server_prompt_ms": t.get("prompt_ms"), "server_predicted_ms": t.get("predicted_ms")}


def snapshot(url: str) -> dict:
    snap = {"time": time.time()}
    try:
        q = "--query-compute-apps=pid,process_name,used_memory"
        snap["gpu_apps"] = subprocess.run(["nvidia-smi", q, "--format=csv,noheader"], capture_output=True,
                                          text=True, timeout=30).stdout.strip().splitlines()
        snap["gpu_util"] = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader"],
                                          capture_output=True, text=True, timeout=30).stdout.strip()
        snap["free_g"] = subprocess.run(["free", "-g"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        snap["gpu_error"] = str(exc)
    base = url.rstrip("/").removesuffix("/v1")
    try:
        with urllib.request.urlopen(base + "/metrics", timeout=10) as r:
            lines = r.read().decode(errors="replace").splitlines()
        keep = ("vllm:num_requests_running{", "vllm:num_requests_waiting{", "llamacpp:requests_processing",
                "llamacpp:requests_deferred", "llamacpp:n_busy_slots")
        snap["metrics"] = [ln for ln in lines if ln.startswith(keep)]
    except (OSError, ValueError) as exc:
        snap["metrics_error"] = str(exc)
    return snap


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="dir holding manifest.json and images/")
    ap.add_argument("--split", default="test")
    ap.add_argument("--ids", default="", help="comma-separated ids (overrides --split)")
    ap.add_argument("--backend", choices=["openai", "step3"], required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--label", required=True)
    ap.add_argument("--concurrency", type=int, default=1)
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = Path(args.root)
    manifest = json.loads((root / "manifest.json").read_text())
    wanted = set(filter(None, args.ids.split(",")))
    items = [it for it in manifest["items"] if (it["id"] in wanted if wanted else it["split"] == args.split)]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            row = json.loads(line)
            if row.get("status") == 200:
                done.add(row["id"])
    todo = [it for it in items if it["id"] not in done]
    backend = (OpenAIBackend if args.backend == "openai" else Step3Backend)(args.url, args.model, args.max_tokens)
    meta_path = out.with_suffix(".meta.json")
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {"segments": []}
    seg = {"label": args.label, "backend": args.backend, "model": backend.model, "url": args.url,
           "concurrency": args.concurrency, "max_tokens": args.max_tokens, "prompt_version": prompts.PROMPT_VERSION,
           "n_items": len(todo), "start": snapshot(args.url)}
    lock = threading.Lock()
    t_run = time.time()

    def work(it: dict) -> None:
        uri = data_uri(root / it["image"])
        t0 = time.time()
        try:
            res = backend.call(it["type"], uri)
        except Exception as exc:  # noqa: BLE001 - record and continue; the row is retried on resume
            res = {"status": -1, "error": repr(exc)[:1000], "content": ""}
        t1 = time.time()
        row = {"id": it["id"], "type": it["type"], "label": args.label, "model": backend.model,
               "concurrency": args.concurrency, "t_start": t0, "t_end": t1, "latency_s": round(t1 - t0, 3), **res}
        with lock:
            with out.open("a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(f"{it['id']:<12} {row['latency_s']:7.1f}s status={row['status']} out_tok={row.get('completion_tokens')}",
                  flush=True)

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        list(pool.map(work, todo))
    seg["wall_s"] = round(time.time() - t_run, 2)
    seg["end"] = snapshot(args.url)
    meta["segments"].append(seg)
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    print(f"done {len(todo)} items in {seg['wall_s']}s", flush=True)


if __name__ == "__main__":
    main()
