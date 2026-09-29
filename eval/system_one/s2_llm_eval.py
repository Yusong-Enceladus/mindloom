"""System Two baseline on a 300-decision TEST sample: the organizer's own event-assign skill
(real Harness: SKILL.md, schema-guided decoding, validate.py, one retry; action from decide.derive)
on the shared Qwen (:8000), over the same options System One sees.

Also a calibrated-by-construction LLM variant: the dataset's direct prompt ("answer only the option
code"), one short completion, confidence = the answer-token probability from top_logprobs.

Sample: every holdout-week-v2 decision + a seeded random draw from scale-lab, 300 in total.
Live-system gaps (documented): candidate cards carry no event title/anchor/status line (the replay
has no event-brief output), so the skill sees the seed item and the two latest items per event.

  python s2_llm_eval.py --data ../data --repo ../repo --out ../runs/s2 [--workers 4]
"""
import argparse
import json
import math
import os
import random
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import load_jsonl  # noqa: E402

LETTERS = "ABCDEFGH"


def sample_rows(rows, n=300, seed=20260928):
    hold = [r for r in rows if r["stream"] == "holdout-week-v2"]
    rest = [r for r in rows if r["stream"] != "holdout-week-v2"]
    rng = random.Random(seed)
    return hold + rng.sample(rest, n - len(hold))


def to_assign_data(r):
    q = r["query"]
    item = {"item_id": "I0", "kind": q.get("kind", "text"), "source_app": q.get("source_app", ""),
            "started_at": q.get("t", ""), "persons": q.get("people") or [], "text": q.get("text", "")}
    cands, handles, anchors, item_ids = [], {}, {}, []
    j = 0
    for o in r["options"]:
        if "card" not in o:
            continue
        j += 1
        h = f"E{j}"
        handles[h] = o["key"]
        c = o["card"]
        views = []
        for n, s in enumerate(c.get("snippets") or []):
            iid = f"I{j}{n + 1}"
            item_ids.append(iid)
            views.append({"item_id": iid, "kind": "text", "source_app": s.get("source_app", ""),
                          "started_at": s.get("when", ""), "persons": [], "text": s.get("text", "")})
        ret = o.get("retrieval", {})
        cands.append({"event_id": h, "anchor": "", "title": "", "status_line": "",
                      "started_at": c.get("first_seen", ""), "updated_at": c.get("last_seen", ""),
                      "item_count": c.get("n_items", 0), "persons": (c.get("people") or [])[:6],
                      "first_item": views[0] if views else None, "recent_items": views[1:],
                      "retrieval": {"score": ret.get("score"), "similarity": ret.get("similarity"),
                                    "time": ret.get("time"), "same_source": ret.get("same_source"),
                                    "shared_persons": []}})
        anchors[h] = (views[0]["text"][:60] if views else "")
    return {"item": item, "candidates": cands}, handles, anchors, item_ids


def post(url, body, timeout=300):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as f:
        return json.loads(f.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--only", default="skill,logprob")
    ap.add_argument("--limit", type=int, default=0, help="debug: first N of the sample")
    ap.add_argument("--split", default="test", help="val: fit the logprob variant's temperature and tau")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    sys.path.insert(0, os.path.join(args.repo, "spark"))
    sys.path.insert(0, os.path.join(args.repo, "eval"))
    from organizer.clients import OpenAIChatClient
    from organizer.skills import Harness, SkillRegistry
    from organizer.store import Store
    import run_skill_evals as rse

    rows = sample_rows(load_jsonl(f"{args.data}/choice_{args.split}.jsonl"), args.n)
    sfx = "" if args.split == "test" else f"_{args.split}"
    json.dump([r["id"] for r in rows], open(f"{args.out}/sample_ids{sfx}.json", "w"))
    if args.limit:
        rows = rows[40:40 + args.limit]
    registry = SkillRegistry(os.path.join(args.repo, "skills"))
    derive = registry.script("event-assign", "decide").derive

    def skill_one(r):
        data, handles, anchors, _ = to_assign_data(r)
        job, data, schema, context = rse.build_request(registry, "event-assign", {"fixture": {"data": data}})
        harness = Harness(registry, OpenAIChatClient(args.llm_url, "auto", 300.0), Store(":memory:"))
        t0 = time.time()
        res = harness.run(job, data, context=context, schema=schema, subject=r["id"])
        dt = (time.time() - t0) * 1000
        if not res.ok:
            return {"id": r["id"], "stream": r["stream"], "label": r["label"], "valid": False, "ms": dt,
                    "pred": None, "action": "invalid"}
        rank = {h: i for i, h in enumerate(handles)}
        d = derive(res.output, rank, anchors)
        if d["action"] == "attach":
            pred = handles.get(d["target"])
        elif d["action"] == "new":
            pred = "NEW"
        elif d["action"] == "none":
            pred = "NONE"
        else:
            pred = None  # ask: System Two itself escalates to the user
        prov = {"new": "NEW", "none": "NONE"}.get(d.get("provisional") or "", None)
        return {"id": r["id"], "stream": r["stream"], "label": r["label"], "valid": True, "ms": dt,
                "action": d["action"], "pred": pred, "provisional": prov, "attempts": res.attempts}

    def lp_one(r):
        keys = [o["key"] for o in r["options"]]
        body = {"model": MODEL, "messages": [{"role": "user", "content": r["prompt"]}], "max_tokens": 4,
                "temperature": 0, "logprobs": True, "top_logprobs": 20,
                "chat_template_kwargs": {"enable_thinking": False}}
        t0 = time.time()
        out = post(args.llm_url + "/chat/completions", body)
        dt = (time.time() - t0) * 1000
        ch = out["choices"][0]
        text = (ch["message"].get("content") or "").strip()
        probs = {k: 0.0 for k in keys}
        first = ch["logprobs"]["content"][0]["top_logprobs"] if ch.get("logprobs") else []
        for t in first:
            tok = t["token"].strip().strip("[]")
            if tok in probs:
                probs[tok] += math.exp(t["logprob"])
        mass = sum(probs.values())
        pred = next((k for k in sorted(keys, key=len, reverse=True) if text.strip("[] ").startswith(k)), None)
        if mass > 0:
            probs = {k: v / mass for k, v in probs.items()}
        elif pred:
            probs[pred] = 1.0
        return {"id": r["id"], "stream": r["stream"], "label": r["label"], "keys": keys, "text": text,
                "probs": probs, "mass": mass, "ms": dt, "gold": keys.index(r["label"])}

    global MODEL
    MODEL = json.loads(urllib.request.urlopen(args.llm_url + "/models", timeout=10).read())["data"][0]["id"]
    for name, fn in (("logprob", lp_one), ("skill", skill_one)):
        if name not in args.only:
            continue
        t0 = time.time()
        with ThreadPoolExecutor(args.workers) as ex, open(f"{args.out}/s2_{name}{sfx}.jsonl", "w") as f:
            for i, res in enumerate(ex.map(fn, rows)):
                f.write(json.dumps(res, ensure_ascii=False) + "\n")
                f.flush()
                if i % 25 == 0:
                    print(json.dumps({"stage": name, "done": i + 1, "of": len(rows),
                                      "min": round((time.time() - t0) / 60, 1)}), flush=True)
        print(json.dumps({"stage": name, "done": len(rows)}), flush=True)


MODEL = None
if __name__ == "__main__":
    main()
