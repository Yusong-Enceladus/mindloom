#!/usr/bin/env python3
"""Do placeholders make unrelated items look alike to retrieval? Embedding similarity with and without masking.

Embeds every item of the holdout set, of its numbers stress variant as written, and of the stress variant
after Mac-side masking, with the organizer's own embedding text (source app + excerpt of the item text,
organizer.Organizer.embed_doc) and the retrieval embedding model, then compares cosine similarity of item
pairs that share a gold event against pairs that do not. The worry it tests: every masked phone number reads
`〔手机号·xxxxxx〕`, so two unrelated items that both carry a phone number share a literal token that two
different raw numbers do not.

  python3 eval/privacy/mask_similarity.py --numbers DIR/scenario.json --identifiers DIR/identifiers.json \
      --embed-url http://127.0.0.1:8013/v1 -o similarity.json
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "spark"))
sys.path.insert(0, str(HERE.parent / "tools"))

import to_items  # noqa: E402
from organizer import masking  # noqa: E402
from organizer.clients import OpenAIEmbedClient  # noqa: E402
from organizer.keys import derive_keys, synthetic_library_key  # noqa: E402
from organizer.organizer import Organizer  # noqa: E402

MASK_KEY = derive_keys(synthetic_library_key())[2]
HOLDOUT = HERE.parent / "scenarios" / "holdout-week-v2" / "scenario.json"


def body(item: dict) -> str:
    if item.get("segments") and item["kind"] != "dictation":
        return "\n".join(s["text"] for s in item["segments"])
    return item.get("text") or ""


def cos(a, b) -> float:
    return sum(x * y for x, y in zip(a, b)) / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def stats(vals: list[float]) -> dict:
    return {"n": len(vals), "mean": round(statistics.mean(vals), 4), "sd": round(statistics.stdev(vals), 4)} \
        if len(vals) > 1 else {"n": len(vals)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--numbers", required=True)
    ap.add_argument("--identifiers", required=True)
    ap.add_argument("--embed-url", required=True)
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args(argv)
    scen = json.loads(Path(args.numbers).read_text(encoding="utf-8"))
    gold = {i["item_id"]: set(i["events"]) for i in scen["items"]}
    id_items = {r["item_id"] for r in json.loads(Path(args.identifiers).read_text(encoding="utf-8"))["occurrences"]}
    variants = {
        "holdout": to_items.build_items(str(HOLDOUT), render_missing=False),
        "numbers_raw": to_items.build_items(args.numbers, render_missing=False),
    }
    variants["numbers_masked"] = [
        dict(it, text=masking.mask_text(it.get("text"), MASK_KEY),
             segments=[dict(s, text=masking.mask_text(s["text"], MASK_KEY)) for s in it.get("segments") or []])
        for it in variants["numbers_raw"]]
    client = OpenAIEmbedClient(args.embed_url, timeout_s=60.0)
    vecs = {}
    for name, items in variants.items():
        docs = {it["item_id"]: Organizer.embed_doc(it, body(it)) for it in items if body(it).strip()}
        ids = list(docs)
        vecs[name] = dict(zip(ids, client.embed([docs[i] for i in ids])))
    out: dict = {"model": client.model_id, "pairs": {}}
    common = sorted(set.intersection(*(set(v) for v in vecs.values())))
    for name, v in vecs.items():
        groups: dict[str, list[float]] = {k: [] for k in (
            "same_event", "different_event", "different_event_both_with_identifiers",
            "different_event_one_or_none_with_identifiers")}
        for a, b in itertools.combinations(common, 2):
            s = cos(v[a], v[b])
            if not gold[a] or not gold[b]:
                continue  # noise pairs are scored separately by the organizer's noise handling
            if gold[a] & gold[b]:
                groups["same_event"].append(s)
            else:
                groups["different_event"].append(s)
                both = a in id_items and b in id_items
                groups["different_event_both_with_identifiers" if both else
                       "different_event_one_or_none_with_identifiers"].append(s)
        out["pairs"][name] = {k: stats(g) for k, g in groups.items()}
        out["pairs"][name]["separation"] = round(statistics.mean(groups["same_event"])
                                                 - statistics.mean(groups["different_event"]), 4)
    # Paired change per item pair, masked minus raw.
    delta = {"different_event_both_with_identifiers": [], "same_event_both_with_identifiers": [],
             "any_pair_with_an_identifier_item": []}
    for a, b in itertools.combinations(common, 2):
        if not gold[a] or not gold[b]:
            continue
        d = cos(vecs["numbers_masked"][a], vecs["numbers_masked"][b]) - cos(vecs["numbers_raw"][a], vecs["numbers_raw"][b])
        if a in id_items or b in id_items:
            delta["any_pair_with_an_identifier_item"].append(d)
        if a in id_items and b in id_items:
            delta["same_event_both_with_identifiers" if gold[a] & gold[b] else
                  "different_event_both_with_identifiers"].append(d)
    out["masked_minus_raw"] = {k: stats(v) for k, v in delta.items()}
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
