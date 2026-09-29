#!/usr/bin/env python3
"""Native-prompt OCR run over the mm-v1 test split (stdlib only). Each OCR specialist gets its own card prompt,
temperature 0, max 4096 tokens, one image per request, concurrency 1. Output: JSONL with the raw text and latency.
usage: ocr_native.py MMROOT URL MODEL PROMPT OUT.jsonl"""
import base64, json, sys, time, urllib.request
from pathlib import Path

root, url, model, prompt, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], Path(sys.argv[5])
man = json.load(open(root / "manifest.json"))
items = man["items"] if isinstance(man, dict) and "items" in man else man
items = [it for it in items if it.get("split") == "test"]
done = {json.loads(l)["id"] for l in open(out)} if out.exists() else set()
with open(out, "a") as f:
    for it in items:
        if it["id"] in done:
            continue
        img = root / it["image"]
        mime = "image/png" if img.suffix == ".png" else "image/jpeg"
        body = {"model": model, "temperature": 0, "max_tokens": 4096,
                "messages": [{"role": "user", "content": [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64," + base64.b64encode(img.read_bytes()).decode()}},
                    {"type": "text", "text": prompt}]}]}
        t0 = time.time()
        try:
            req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
            d = json.load(urllib.request.urlopen(req, timeout=600))
            row = {"id": it["id"], "type": it.get("type"), "status": 200, "latency_s": round(time.time() - t0, 3),
                   "content": d["choices"][0]["message"].get("content") or "",
                   "finish_reason": d["choices"][0].get("finish_reason"),
                   "completion_tokens": d.get("usage", {}).get("completion_tokens")}
        except Exception as e:  # noqa: BLE001
            row = {"id": it["id"], "type": it.get("type"), "status": "error", "latency_s": round(time.time() - t0, 3), "error": repr(e)[:300]}
        f.write(json.dumps(row, ensure_ascii=False) + "\n"); f.flush()
        print(it["id"], row["status"], row["latency_s"], flush=True)
