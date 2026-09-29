"""System One client: one HTTP call per decision (all k+2 options batched) to the vLLM
score model on 127.0.0.1:8021, then the linear head, temperature and fast-path threshold.

    from s1_client import SystemOne
    s1 = SystemOne(run_dir)                       # reads head.json + calibration.json
    out = s1.choose(row)                          # row in choice_*.jsonl form
    out -> {"probs": {"A": .., "NEW": .., "NONE": ..}, "choice": "A", "confidence": .93,
            "fast": True, "latency_ms": 41.0}

`fast` is True when the calibrated confidence clears tau (chosen on VALIDATION for >= 97%
precision); otherwise the caller escalates to System Two (the LLM).

Run as a script to measure latency and check parity with the offline scores:
    python s1_client.py --run RUN --data DATA --split val --n 300
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import choice_features, choice_pairs, load_jsonl, merge_pair_text

URL = os.environ.get("S1_URL", "http://127.0.0.1:8021")
MODEL = os.environ.get("S1_MODEL", "s1-reranker")


def _post(path, body, timeout=30):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def ce_logits(texts):
    res = _post("/classify", {"model": MODEL, "input": texts})
    out = []
    for d in res["data"]:
        p = d["probs"][-1] if isinstance(d.get("probs"), list) else d["probs"]
        p = min(max(float(p), 1e-7), 1 - 1e-7)
        out.append(math.log(p / (1 - p)))
    return out


class SystemOne:
    def __init__(self, run_dir):
        head = json.load(open(os.path.join(run_dir, "head.json")))
        cal = json.load(open(os.path.join(run_dir, "calibration.json")))
        self.w = np.array(head["w"])
        self.a = head["a"]
        self.T = cal["calibration"]["temperature"]
        iso = cal["calibration"].get("isotonic")
        self.iso = (np.array(iso[0]), np.array(iso[1])) if iso else None
        self.tau = cal["fast_path"]["tau"]
        self.merge = cal.get("merge", {})

    def choose(self, row):
        t0 = time.perf_counter()
        keys, texts = choice_pairs(row)
        ce = np.array(ce_logits(texts))
        lat = (time.perf_counter() - t0) * 1000
        z = (self.a * ce + np.array(choice_features(row)) @ self.w) / self.T
        p = np.exp(z - z.max())
        p /= p.sum()
        i = int(p.argmax())
        conf = float(np.interp(p[i], *self.iso)) if self.iso else float(p[i])
        return {"probs": {k: float(v) for k, v in zip(keys, p)}, "choice": keys[i], "confidence": conf,
                "fast": conf >= self.tau, "latency_ms": lat, "ce": ce.tolist()}

    def same(self, row, task):
        """P(same) for a person-merge or event-merge pair row."""
        m = self.merge[task]
        z = ce_logits([merge_pair_text(row, task)])[0]
        p = 1 / (1 + math.exp(-(z / m["temperature"] + m["bias"])))
        return {"p_same": p, "merge": p >= m["same_threshold_97"]}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--split", default="val")
    ap.add_argument("--n", type=int, default=300)
    args = ap.parse_args()
    s1 = SystemOne(args.run)
    rows = load_jsonl(f"{args.data}/choice_{args.split}.jsonl")[:args.n]
    ref_path = f"{args.run}/parity_hf.json"
    ref = json.load(open(ref_path)) if os.path.exists(ref_path) else {}
    for r in rows[:5]:  # warm-up
        s1.choose(r)
    lats, diffs, agree = [], [], 0
    for r in rows:
        o = s1.choose(r)
        lats.append(o["latency_ms"])
        if r["id"] in ref:  # served vs HF reference logits
            off = np.array(ref[r["id"]])
            diffs.append(float(np.abs(off - np.array(o["ce"])).max()))
            z = s1.a * off + np.array(choice_features(r)) @ s1.w
            agree += int(np.argmax(z) == list(o["probs"]).index(o["choice"]))
    nopt = [len(r["options"]) for r in rows]
    res = {"n": len(rows), "options_per_decision_mean": float(np.mean(nopt)),
           "latency_ms_p50": float(np.percentile(lats, 50)), "latency_ms_p90": float(np.percentile(lats, 90)),
           "latency_ms_max": float(np.max(lats)),
           "parity_rows": len(diffs),
           "parity_max_abs_logit_diff_p50": float(np.median(diffs)) if diffs else None,
           "parity_max_abs_logit_diff_max": float(np.max(diffs)) if diffs else None,
           "argmax_agreement_with_hf": agree / len(diffs) if diffs else None}
    print(json.dumps(res, indent=1))
    json.dump(res, open(f"{args.run}/serve_latency_{args.split}.json", "w"), indent=1)
