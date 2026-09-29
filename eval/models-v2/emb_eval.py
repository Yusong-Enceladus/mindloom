#!/usr/bin/env python3
"""Same-event retrieval probe for text embedding models (synthetic scenarios only, no tuning).

For every scenario item that belongs to at least one gold event, embed its text (text / transcript; image items
use their drawn chat messages joined, i.e. a perfect-reading stand-in), then rank all other items by cosine.
Relevant = items sharing a gold event. Reports Recall@5, MRR and nDCG@10, averaged over queries, per scenario.
Raw text is embedded for every model (no instruction prefix), so no model gets a tuned prompt.

usage: emb_eval.py URL MODEL OUT.json scenario.json [scenario.json ...]
"""
import json, math, sys, time, urllib.request

url, model, out = sys.argv[1], sys.argv[2], sys.argv[3]


def item_text(it):
    if it.get("text"):
        return it["text"]
    img = it.get("image") or {}
    parts = [img.get("chat_title", "")] + [f"{m.get('sender','')}: {m.get('text','')}" for m in img.get("messages", [])]
    for k in ("title", "body", "lines", "caption"):
        v = img.get(k)
        if isinstance(v, str):
            parts.append(v)
        elif isinstance(v, list):
            parts += [x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) for x in v]
    t = "\n".join(p for p in parts if p)
    return t or json.dumps(img, ensure_ascii=False)[:2000]


def embed(texts):
    vecs = []
    for i in range(0, len(texts), 16):
        body = json.dumps({"model": model, "input": texts[i:i + 16]}).encode()
        req = urllib.request.Request(url.rstrip("/") + "/v1/embeddings", data=body, headers={"Content-Type": "application/json"})
        d = json.load(urllib.request.urlopen(req, timeout=600))
        vecs += [e["embedding"] for e in sorted(d["data"], key=lambda e: e["index"])]
    out = []
    for v in vecs:
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        out.append([x / n for x in v])
    return out


res = {"model": model, "url": url, "scenarios": {}}
for sp in sys.argv[4:]:
    sc = json.load(open(sp))
    items = [it for it in sc["items"] if it.get("events")]
    texts = [item_text(it)[:6000] for it in items]
    t0 = time.time()
    V = embed(texts)
    dt = time.time() - t0
    r5 = mrr = ndcg = 0.0
    nq = 0
    for i, it in enumerate(items):
        ev = set(it["events"])
        rel = {j for j, jt in enumerate(items) if j != i and ev & set(jt["events"])}
        if not rel:
            continue
        nq += 1
        sims = sorted(((sum(a * b for a, b in zip(V[i], V[j])), j) for j in range(len(items)) if j != i), reverse=True)
        ranked = [j for _, j in sims]
        r5 += len(rel & set(ranked[:5])) / min(5, len(rel))
        mrr += next(1.0 / (k + 1) for k, j in enumerate(ranked) if j in rel)
        dcg = sum(1.0 / math.log2(k + 2) for k, j in enumerate(ranked[:10]) if j in rel)
        idcg = sum(1.0 / math.log2(k + 2) for k in range(min(10, len(rel))))
        ndcg += dcg / idcg
    res["scenarios"][sc.get("scenario_id", sp)] = {
        "queries": nq, "items": len(items), "recall@5": round(r5 / nq, 4), "mrr": round(mrr / nq, 4),
        "ndcg@10": round(ndcg / nq, 4), "embed_seconds": round(dt, 2), "dim": len(V[0])}
json.dump(res, open(out, "w"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False))
