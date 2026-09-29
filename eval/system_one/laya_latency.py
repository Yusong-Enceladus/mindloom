"""Latency per decision (p50/p90) and served-vs-offline parity for the Laya candidate.

In-process: laya Agent.system_one(state, {"event": question}) -- the library's public path.
HTTP (--url): POST /v1/systemone on laya-serve, the Jev wire shape.
Parity: the returned probabilities must equal softmax(logits / T_bucket) from scores_val.jsonl.
"""
import argparse
import json
import os
import sys
import time
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from laya_calibrate import bucket, softmax  # noqa: E402
from laya_s1 import choice_state_question  # noqa: E402
from s1_common import load_jsonl  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--data", required=True)
ap.add_argument("--n", type=int, default=300)
ap.add_argument("--url", default="")
ap.add_argument("--model", default="", help="checkpoint dir for in-process mode (default RUN/model)")
args = ap.parse_args()

rows = load_jsonl(f"{args.data}/choice_val.jsonl")[:args.n]
ref = {s["id"]: s for s in load_jsonl(f"{args.run}/scores_val.jsonl")}
cal = json.load(open(f"{args.run}/calibration.json"))
temps = cal["calibration"]["temperature_by_options"]
glob = cal["calibration"]["temperature"][0]

if args.url:
    def call(state, q):
        body = json.dumps({"state": state, "questions": {"event": q}, "model": "multilingual"}).encode()
        req = urllib.request.Request(args.url.rstrip("/") + "/v1/systemone", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())["answers"]["event"]
else:
    import torch
    torch.zeros(1, device="cuda")
    torch.cuda.set_per_process_memory_fraction(min(1.0, 2.5 / (torch.cuda.get_device_properties(0).total_memory / 1e9)))
    from laya.agent import Agent
    agent = Agent(args.model or f"{args.run}/model", device="cuda")

    def call(state, q):
        return agent.system_one(state, {"event": q})["answers"]["event"]

lats, diffs, agree = [], [], 0
for i, r in enumerate(rows):
    state, q, keys = choice_state_question(r)
    t0 = time.perf_counter()
    a = call(state, q)
    dt = (time.perf_counter() - t0) * 1000
    if i >= 5:
        lats.append(dt)
    s = ref.get(r["id"])
    if s:
        p_ref = softmax(np.asarray(s["logits"]) / temps.get(bucket(len(s["logits"])), glob))
        letters = list(q["criteria"].keys())
        p = np.array([a["probabilities"][L] for L in letters])
        diffs.append(float(np.abs(p - p_ref).max()))
        agree += int(int(p.argmax()) == int(p_ref.argmax()))
out = {"mode": "http" if args.url else "in-process", "n": len(lats),
       "p50_ms": float(np.percentile(lats, 50)), "p90_ms": float(np.percentile(lats, 90)),
       "mean_ms": float(np.mean(lats)), "parity_max_abs_prob_diff": float(np.max(diffs)) if diffs else None,
       "parity_argmax_agree": agree / max(len(diffs), 1)}
print(json.dumps(out))
json.dump(out, open(f"{args.run}/latency.json", "w"), indent=1)
json.dump(out, open(f"{args.run}/latency_{out['mode']}.json", "w"), indent=1)
