#!/usr/bin/env python3
"""Score the item-split skill alone on a scenario with segment truth (items[].segments [{event_id, quote}]).

Every item goes through the organizer's own path (transcript parse -> units -> pre-filter -> item-split
via the real Harness -> units.segments_from_output), without assignment. Per item:
  gold parts   = its gold segments (items with fewer than two are "one matter": the right answer is whole)
  pred parts   = the derived segments, or the whole item when it is not split
Metrics: split decision accuracy (split iff >= 2 gold parts), exact part count, and part-level P/R/F1
where a predicted part and a gold part match (one to one) when the predicted span covers at least half of
the gold quote and at least half of the predicted span lies inside that quote.

  python3 eval/tools/split_eval.py eval/scenarios/split-dev/scenario.json --llm-url http://127.0.0.1:8000/v1 \
      --out /tmp/split-eval.json [--n 1] [--threads 6]
"""

from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(ROOT / "eval"))

import score as scorer  # noqa: E402
from organizer import transcripts  # noqa: E402
from organizer.skills import Harness, SkillRegistry  # noqa: E402
from organizer.store import Store  # noqa: E402


def _overlap(a: tuple[int, int], b: tuple[int, int]) -> int:
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def match_parts(pred: list[tuple[int, int]], gold: list[tuple[int, int]]) -> int:
    pairs = sorted(((_overlap(p, g), i, j) for i, p in enumerate(pred) for j, g in enumerate(gold)
                    if _overlap(p, g) >= 0.5 * (g[1] - g[0]) and _overlap(p, g) >= 0.5 * (p[1] - p[0])), reverse=True)
    used_p, used_g, n = set(), set(), 0
    for _, i, j in pairs:
        if i not in used_p and j not in used_g:
            used_p.add(i)
            used_g.add(j)
            n += 1
    return n


def split_one(registry, harness, units_mod, item: dict) -> dict:
    text = scorer.api_text(item)
    tx = transcripts.parse(text)
    units = units_mod.build_units(text, tx["turns"] if tx else None)
    if not units_mod.prefilter(text, len(units), item["kind"], tx is not None):
        return {"segments": [], "prefiltered": True}
    ids = [u["u"] for u in units]
    data = units_mod.build_data(item["kind"], item["source_app"], item["t"], units, tx["format"] if tx else "")
    import copy
    schema = copy.deepcopy(registry.skills["item-split"].schema)
    seg = schema["properties"]["segments"]["items"]["properties"]
    for key in ("from", "to"):
        seg[key]["enum"] = ids
        seg[key].pop("pattern", None)
    res = harness.run("split", data, context={"unit_ids": ids}, schema=schema, subject=item["ref"])
    out = res.output if res.ok else units_mod.salvage(
        res.candidate, res.errors, lambda o: registry.skills["item-split"].validator(o, {"unit_ids": ids}))
    segs = units_mod.segments_from_output(out, units) if out else []
    return {"segments": segs, "valid": res.ok, "salvaged": bool(out) and not res.ok, "errors": res.errors,
            "matters": (out or {}).get("matters")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario")
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--threads", type=int, default=6)
    args = ap.parse_args(argv)
    from organizer.clients import OpenAIChatClient

    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    registry = SkillRegistry(ROOT / "skills")
    units_mod = registry.script("item-split", "units")
    harness = Harness(registry, OpenAIChatClient(args.llm_url, "auto", 300.0), Store(":memory:"))
    rows = []
    jobs = [(r, it) for r in range(args.n) for it in scenario["items"]]
    with ThreadPoolExecutor(args.threads) as pool:
        results = list(pool.map(lambda job: split_one(registry, harness, units_mod, job[1]), jobs))
    tp = n_pred = n_gold = decision_ok = count_ok = 0
    for (rep, item), res in zip(jobs, results):
        text = scorer.api_text(item)
        gold = [(text.find(s["quote"]), text.find(s["quote"]) + len(s["quote"])) for s in scorer.gold_segments(item)]
        gold_n = len(gold)
        pred = [(s["start"], s["end"]) for s in res["segments"]]
        should_split = gold_n >= 2
        decision_ok += (bool(pred) == should_split)
        if not should_split:
            count_ok += not pred
            continue
        pred_parts = pred or [(0, len(text))]
        count_ok += len(pred_parts) == gold_n
        m = match_parts(pred_parts, gold)
        tp += m
        n_pred += len(pred_parts)
        n_gold += gold_n
        rows.append({"rep": rep, "ref": item["ref"], "gold": gold_n, "pred": len(pred), "matched": m,
                     "gists": [s["gist"] for s in res["segments"]], "valid": res.get("valid"),
                     "salvaged": res.get("salvaged")})
    for (rep, item), res in zip(jobs, results):
        if len(scorer.gold_segments(item)) < 2:
            rows.append({"rep": rep, "ref": item["ref"], "gold": 1 if item.get("events") else 0,
                         "pred": len(res["segments"]), "prefiltered": res.get("prefiltered", False),
                         "gists": [s["gist"] for s in res["segments"]]})
    prec = tp / n_pred if n_pred else 0.0
    rec = tp / n_gold if n_gold else 0.0
    summary = {"items": len(jobs), "decision_accuracy": round(decision_ok / len(jobs), 3),
               "count_exact": round(count_ok / len(jobs), 3), "part_precision": round(prec, 3),
               "part_recall": round(rec, 3), "part_f1": round(2 * prec * rec / (prec + rec), 3) if prec + rec else 0.0,
               "oversplit_single": sum(1 for r in rows if r["gold"] <= 1 and r["pred"] >= 2),
               "unsplit_multi": sum(1 for r in rows if r["gold"] >= 2 and r["pred"] == 0),
               "salvaged": sum(1 for r in results if r.get("salvaged")),
               "invalid": sum(1 for r in results if r.get("valid") is False and not r.get("salvaged")),
               "skill_version": registry.skills["item-split"].version,
               "prompt_hash": registry.skills["item-split"].prompt_hash, "model": harness.client.model_id}
    Path(args.out).write_text(json.dumps({"summary": summary, "items": rows}, ensure_ascii=False, indent=1),
                              encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    for r in rows:
        if r["gold"] != r["pred"] and not (r["gold"] <= 1 and r["pred"] == 0):
            print(f"  {r['ref']}: gold {r['gold']} pred {r['pred']} {r.get('gists')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
