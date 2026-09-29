"""Serve the fine-tuned reranker System One on 127.0.0.1:8021 with plain PyTorch (no vLLM: on the shared
GB10 vLLM wants a fixed memory pool larger than what is free; this process caps itself at --mem-gb).

Endpoints
  GET  /health
  POST /classify   {"input": [pair texts]}             -> {"data": [{"probs": [p_no, p_yes]}]}  (vLLM wire shape;
                   s1_client.ce_logits works unchanged)
  POST /v1/choose  {"row": CHOICE row}                  -> {"probs": {key: p}, "choice", "confidence", "fast",
                   "tau", "escalate_to": "system-two" | null, "latency_ms"}
  POST /v1/merge   {"row": pair row, "task": "person"|"event"} -> {"p_same", "merge", "threshold"}

The scoring math is identical to train_s1.py (same pair text, left padding, explicit position ids, last
token, yes/no rows of the output embedding), so served logits equal the offline dump.

  python serve_rr.py --run ../runs/r1 [--port 8021] [--mem-gb 2.5]
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import torch
from fastapi import FastAPI
from transformers import AutoModelForCausalLM, AutoTokenizer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import choice_features, choice_pairs, merge_pair_text  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--port", type=int, default=8021)
ap.add_argument("--mem-gb", type=float, default=2.5)
ap.add_argument("--max-len", type=int, default=768)
args = ap.parse_args()

total = torch.cuda.get_device_properties(0).total_memory / 1e9
torch.cuda.set_per_process_memory_fraction(min(1.0, args.mem_gb / total))
dev = torch.device("cuda")
tok = AutoTokenizer.from_pretrained(f"{args.run}/model")
tok.padding_side = "left"
model = AutoModelForCausalLM.from_pretrained(f"{args.run}/model", dtype=torch.bfloat16).to(dev).eval()
W_yn = model.lm_head.weight[[tok.convert_tokens_to_ids("yes"), tok.convert_tokens_to_ids("no")]].detach().float()
head = json.load(open(f"{args.run}/head.json"))
cal = json.load(open(f"{args.run}/serving.json"))  # written by report step: T, tau, merge T/b/threshold
w_head, a_head = np.array(head["w"]), head["a"]


@torch.no_grad()
def ce_logits(texts):
    out = []
    for k in range(0, len(texts), 12):
        enc = tok(texts[k:k + 12], padding=True, truncation=True, max_length=args.max_len,
                  return_tensors="pt").to(dev)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            pos = (enc.attention_mask.cumsum(-1) - 1).clamp(min=0)
            h = model.model(input_ids=enc.input_ids, attention_mask=enc.attention_mask,
                            position_ids=pos).last_hidden_state[:, -1]
        lg = h.float() @ W_yn.T
        out += (lg[:, 0] - lg[:, 1]).tolist()
    return out


app = FastAPI(title="Mindloom System One (reranker)")


@app.get("/health")
def health():
    return {"ok": True, "model": "s1-reranker", "tau": cal["tau"]}


@app.post("/classify")
def classify(body: dict):
    ce = ce_logits(body["input"])
    return {"data": [{"index": i, "probs": [1 - 1 / (1 + math.exp(-z)), 1 / (1 + math.exp(-z))]}
                     for i, z in enumerate(ce)]}


@app.post("/v1/choose")
def choose(body: dict):
    t0 = time.perf_counter()
    row = body["row"]
    keys, texts = choice_pairs(row)
    ce = np.array(ce_logits(texts))
    z = (a_head * ce + np.array(choice_features(row)) @ w_head) / cal["temperature"]
    p = np.exp(z - z.max())
    p /= p.sum()
    i = int(p.argmax())
    fast = bool(p[i] >= cal["tau"])
    return {"probs": {k: float(v) for k, v in zip(keys, p)}, "choice": keys[i], "confidence": float(p[i]),
            "fast": fast, "tau": cal["tau"], "escalate_to": None if fast else "system-two",
            "latency_ms": (time.perf_counter() - t0) * 1000}


@app.post("/v1/merge")
def merge(body: dict):
    task = body.get("task", "person")
    m = cal["merge"][task]
    z = ce_logits([merge_pair_text(body["row"], task)])[0]
    p = 1 / (1 + math.exp(-(z / m["temperature"] + m["bias"])))
    return {"p_same": p, "merge": p >= m["same_threshold_97"], "threshold": m["same_threshold_97"]}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
