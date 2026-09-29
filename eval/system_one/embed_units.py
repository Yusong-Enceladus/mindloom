#!/usr/bin/env python3
"""Embed every unit's embed_text with the organizer's embedding endpoint (Qwen3-Embedding-0.6B).

  python3 embed_units.py DATA_DIR --embed-url http://127.0.0.1:8013/v1
Reads DATA_DIR/units.jsonl, writes DATA_DIR/embeddings.npy (float32, one row per distinct text) and
DATA_DIR/embed_index.json ({unit_id: row}); progress in DATA_DIR/embed.progress.
"""
import json
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np

data = Path(sys.argv[1])
url = sys.argv[sys.argv.index("--embed-url") + 1] if "--embed-url" in sys.argv else "http://127.0.0.1:8013/v1"
units = [json.loads(l) for l in open(data / "units.jsonl", encoding="utf-8")]
texts, row_of, index = [], {}, {}
for u in units:
    t = u["embed_text"]
    if t not in row_of:
        row_of[t] = len(texts)
        texts.append(t)
    index[u["unit_id"]] = row_of[t]
model = json.loads(urllib.request.urlopen(url + "/models", timeout=30).read())["data"][0]["id"]
vecs = []
B = 32
t0 = time.time()
for i in range(0, len(texts), B):
    body = json.dumps({"model": model, "input": texts[i:i + B]}).encode()
    for attempt in range(6):
        try:
            req = urllib.request.Request(url + "/embeddings", body, {"Content-Type": "application/json"})
            out = json.loads(urllib.request.urlopen(req, timeout=300).read())
            break
        except Exception as exc:  # noqa: BLE001
            if attempt == 5:
                raise
            time.sleep(5)
    vecs += [d["embedding"] for d in sorted(out["data"], key=lambda d: d["index"])]
    (data / "embed.progress").write_text(f"{len(vecs)}/{len(texts)} {time.time()-t0:.0f}s\n")
np.save(data / "embeddings.npy", np.asarray(vecs, dtype=np.float32))
(data / "embed_index.json").write_text(json.dumps({"model": model, "url": url, "index": index}))
(data / "embed.progress").write_text(f"done {len(vecs)}/{len(texts)} {time.time()-t0:.0f}s\n")
