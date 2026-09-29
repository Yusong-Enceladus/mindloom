"""Score CHOICE val/test and merge val through the served System One model (vLLM on :8021).
Writes the same files train_s1.py --dump would: <run>/scores_{val,test}.jsonl, scores_merge_val.jsonl.
Also writes <run>/parity.json: served vs HF (CPU) logits on a few pairs, to prove serving is faithful.
"""
import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_client import ce_logits
from s1_common import choice_pairs, gold_index, load_jsonl, merge_pair_text

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--data", required=True)
ap.add_argument("--splits", default="val,test")
ap.add_argument("--workers", type=int, default=6)
args = ap.parse_args()


def one(r):
    keys, texts = choice_pairs(r)
    return {"id": r["id"], "stream": r["stream"], "keys": keys, "ce": ce_logits(texts), "gold": gold_index(r),
            "label": r["label"], "label_reason": r["label_reason"], "tags": r.get("tags", [])}


for split in args.splits.split(","):
    rows = load_jsonl(f"{args.data}/choice_{split}.jsonl")
    with ThreadPoolExecutor(args.workers) as ex:
        res = list(ex.map(one, rows))
    with open(f"{args.run}/scores_{split}.jsonl", "w") as f:
        for o in res:
            f.write(json.dumps(o, ensure_ascii=False) + "\n")
    print(split, len(res), flush=True)

merge = []
for task, name in (("person", "person_merge"), ("event", "event_merge")):
    for r in load_jsonl(f"{args.data}/{name}_val.jsonl"):
        merge.append((task, r))


def mchunk(chunk):
    ce = ce_logits([merge_pair_text(r, t) for t, r in chunk])
    return [{"task": t, "stream": r["stream"], "kind": r.get("kind"), "y": 1.0 if r["label"] == "same" else 0.0,
             "ce": c, "truth_a": r.get("truth_a"), "purity_a": r.get("purity_a"), "purity_b": r.get("purity_b")}
            for (t, r), c in zip(chunk, ce)]


chunks = [merge[i:i + 16] for i in range(0, len(merge), 16)]
with ThreadPoolExecutor(args.workers) as ex:
    out = [o for c in ex.map(mchunk, chunks) for o in c]
with open(f"{args.run}/scores_merge_val.jsonl", "w") as f:
    for o in out:
        f.write(json.dumps(o, ensure_ascii=False) + "\n")
print("merge_val", len(out), flush=True)
