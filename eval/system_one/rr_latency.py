"""Latency per decision (p50/p90) for the served reranker System One: POST /v1/choose on 127.0.0.1:8021,
one decision = all k+2 (item, option) pairs scored in one call, plus the head, temperature and tau.
Also checks served probabilities against the offline dump (runs/r1/scores_val.jsonl).

  python rr_latency.py --run ../runs/r1 --data ../data --n 300
"""
import argparse
import json
import os
import sys
import time
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import choice_features, load_jsonl  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--data", required=True)
ap.add_argument("--n", type=int, default=300)
ap.add_argument("--url", default="http://127.0.0.1:8021")
args = ap.parse_args()
rows = load_jsonl(f"{args.data}/choice_val.jsonl")[:args.n]
ref = {s["id"]: s for s in load_jsonl(f"{args.run}/scores_val.jsonl")}
head = json.load(open(f"{args.run}/head.json"))
srv = json.load(open(f"{args.run}/serving.json"))
lats, diffs, agree = [], [], 0
for i, r in enumerate(rows):
    body = json.dumps({"row": r}).encode()
    t0 = time.perf_counter()
    req = urllib.request.Request(args.url + "/v1/choose", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as f:
        out = json.loads(f.read())
    dt = (time.perf_counter() - t0) * 1000
    if i >= 5:
        lats.append(dt)
    s = ref[r["id"]]
    z = (head["a"] * np.array(s["ce"]) + np.array(choice_features(r)) @ np.array(head["w"])) / srv["temperature"]
    p_ref = np.exp(z - z.max())
    p_ref /= p_ref.sum()
    p = np.array([out["probs"][k] for k in s["keys"]])
    diffs.append(float(np.abs(p - p_ref).max()))
    agree += int(p.argmax() == p_ref.argmax())
res = {"mode": "http /v1/choose (PyTorch server)", "n": len(lats), "options_mean": float(np.mean([len(r["options"]) for r in rows])),
       "p50_ms": float(np.percentile(lats, 50)), "p90_ms": float(np.percentile(lats, 90)), "mean_ms": float(np.mean(lats)),
       "parity_max_abs_prob_diff": float(np.max(diffs)), "parity_argmax_agree": agree / len(diffs)}
print(json.dumps(res))
json.dump(res, open(f"{args.run}/latency.json", "w"), indent=1)
