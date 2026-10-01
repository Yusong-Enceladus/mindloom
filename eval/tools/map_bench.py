#!/usr/bin/env python3
"""Score matter maps (skill matter-map) on a scale scenario: strand coherence against the scenario's own
sub-threads, knot coverage of the scenario's facts, and cost per matter.

Sub-threads: a matter the organizer built often holds items of several scenario events (a merged look-alike, a
project and its demo, a paper and its supplement), and a split meeting's segments carry their own scenario event.
Where a matter's labelled items span at least two scenario events with at least two units each, those events are
its sub-threads, and a good map puts each one on its own strand(s). Units are items, or segments of split items
(labelled by the scenario quote their span overlaps most). Scored per such matter:
  B-cubed precision / recall / F1 of the strands against the sub-threads, over the labelled units the map put on a
  strand (noise units are left out), and coverage (labelled units on some strand / labelled units of the matter);
  the same for the one-strand baseline (everything on one strand), which is what the view shows without a map;
  and separation: of the unit pairs from two different sub-threads, the share the map put on different strands,
  against the chance level for strands of the same sizes. Strands also split one scenario event into its own
  sub-threads (writing / experiments of one paper), which B-cubed recall counts as an error, so precision and
  separation are the numbers that say whether a map keeps different sub-threads apart.
Knot coverage: for the matter's main scenario events, the share of their facts whose introducing item is cited by
some knot. Cost: prompt / completion tokens and seconds per matter (from map_offline's summary). Ropes (where the
scenario links its events, scale-lab): the share of sibling pairs on a rope whose main scenario events are the same
event or linked (`related` / `lookalike_of`).

  python eval/tools/map_bench.py --state lab-state.json --summary lab-state.summary.json \\
      --scenario eval/scenarios/scale-lab/scenario.json --idmap mac-id-to-scenario-id.json --out bench.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "eval"))

from score import Gold  # noqa: E402


def bcubed(pred: dict[str, str], gold: dict[str, str]) -> tuple[float, float, float]:
    units = [u for u in pred if u in gold]
    if not units:
        return 0.0, 0.0, 0.0
    p = r = 0.0
    for u in units:
        same_pred = [v for v in units if pred[v] == pred[u]]
        same_gold = [v for v in units if gold[v] == gold[u]]
        both = sum(1 for v in same_pred if gold[v] == gold[u])
        p += both / len(same_pred)
        r += both / len(same_gold)
    p, r = p / len(units), r / len(units)
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--idmap", help="organizer item id -> scenario item id (a Mac-run store)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    summary = json.loads(Path(args.summary).read_text(encoding="utf-8"))
    gold = Gold(json.loads(Path(args.scenario).read_text(encoding="utf-8")))
    idmap = {k.lower(): v.lower() for k, v in json.loads(Path(args.idmap).read_text()).items()} if args.idmap else {}
    cost = {m["event_id"]: m for m in summary["maps"]}
    facts_by_event: dict[str, list[dict]] = {}
    for f in gold.raw.get("facts", []):
        facts_by_event.setdefault(f["event_id"], []).append(f)

    def sid(item_id: str) -> str:
        return idmap.get(item_id.lower(), item_id.lower())

    def label(item_id: str, span) -> str | None:
        s = sid(item_id)
        if span is not None and s in gold.item_segments:
            a, b = span
            best, cover = None, 0
            for ev, x, y in gold.item_segments[s]:
                c = max(0, min(b, y) - max(a, x))
                if c > cover:
                    best, cover = ev, c
            if best:
                return best
        evs = gold.item_events.get(s)
        if evs is None:
            return None
        if not evs:
            return "noise"
        return next(iter(evs)) if len(evs) == 1 else None

    rows = []
    for ev in state["events"]:
        m = ev.get("map")
        if ev.get("deleted") or not m:
            continue
        spans = {(g["item_id"], g["seg_id"]): (g["start"], g["end"]) for g in ev.get("segments") or []}
        seg_items = {g["item_id"] for g in ev.get("segments") or []}
        units: dict[tuple, str] = {}
        for it in ev["item_ids"]:
            if it not in seg_items:
                units[(it, None)] = label(it, None)
        for (it, sg), span in spans.items():
            units[(it, sg)] = label(it, span)
        strand_of: dict[tuple, str] = {}
        for s in m["strands"]:
            segs = {(r["item_id"], r["seg_id"]) for r in s["segment_refs"]}
            for u in segs:
                strand_of[u] = s["id"]
            for it in s["item_ids"]:
                if it not in seg_items:
                    strand_of[(it, None)] = s["id"]
        labelled = {u: g for u, g in units.items() if g and g != "noise"}
        counts: dict[str, int] = {}
        for g in labelled.values():
            counts[g] = counts.get(g, 0) + 1
        threads = sorted(g for g, n in counts.items() if n >= 2)
        c = cost.get(ev["event_id"], {})
        cited = {i for k in m["knots"] for i in k["evidence"]}
        main_events = [g for g, n in counts.items() if n >= max(2, 0.2 * len(labelled))]
        fs = [f for g in main_events for f in facts_by_event.get(g, []) if f.get("valid_from")]
        member_scen = {sid(i) for i in ev["item_ids"]}
        fs = [f for f in fs if f["valid_from"].lower() in member_scen]
        cited_scen = {sid(i) for i in cited}
        row = {"event_id": ev["event_id"], "handle": ev.get("handle"), "title": ev["title"], "units": len(units),
               "labelled": len(labelled), "gold_events": counts, "sub_threads": len(threads),
               "strands": len(m["strands"]), "knots": len(m["knots"]), "health": (m.get("health") or {}).get("level"),
               "fact_coverage": (sum(1 for f in fs if f["valid_from"].lower() in cited_scen) / len(fs)) if fs else None,
               "facts": len(fs), "prompt_tokens": c.get("prompt_tokens"), "completion_tokens": c.get("completion_tokens"),
               "seconds": c.get("seconds"), "attempts": c.get("attempts"), "status": c.get("status"), "home": c.get("home")}
        if len(threads) >= 2:
            g = {u: labelled[u] for u in labelled if labelled[u] in threads}
            pred = {u: strand_of[u] for u in g if u in strand_of}
            p, r, f1 = bcubed(pred, g)
            bp, br, bf = bcubed({u: "one" for u in g}, g)
            # Separation: of the unit pairs from two different sub-threads (both on a strand), the share on different
            # strands; the chance level keeps the strand sizes (1 - sum of squared strand shares).
            us = list(pred)
            diff = [(a, b) for i, a in enumerate(us) for b in us[i + 1:] if g[a] != g[b]]
            sep = sum(1 for a, b in diff if pred[a] != pred[b]) / len(diff) if diff else None
            sizes: dict[str, int] = {}
            for u in us:
                sizes[pred[u]] = sizes.get(pred[u], 0) + 1
            chance = 1 - sum((n / len(us)) ** 2 for n in sizes.values()) if us else None
            row.update({"coverage": len(pred) / len(g), "b3_p": p, "b3_r": r, "b3_f1": f1,
                        "one_strand_b3_f1": bf, "one_strand_b3_p": bp, "separation": sep, "separation_chance": chance})
        rows.append(row)
    # Ropes against the scenario's own links (scale-lab: each event lists `related` and `lookalike_of` events): two
    # matters on one rope agree when their main scenario events are the same event or linked.
    main_of: dict[str, str] = {}
    for ev in state["events"]:
        if ev.get("deleted"):
            continue
        counts: dict[str, int] = {}
        for it in ev["item_ids"]:
            g = label(it, None)
            if g and g != "noise":
                counts[g] = counts.get(g, 0) + 1
        if counts:
            main_of[ev["event_id"]] = max(counts, key=lambda g: (counts[g], g))
    linked = {g: set(e.get("related") or []) | set(e.get("lookalike_of") or []) for g, e in gold.events.items()}
    rope_rows = []
    titles = {e["event_id"]: e["title"] for e in state["events"]}
    for r in state.get("ropes") or []:
        kids = [k for k in r["children"] if k in main_of]
        pairs = [(a, b) for i, a in enumerate(kids) for b in kids[i + 1:]]
        agree = sum(1 for a, b in pairs if main_of[a] == main_of[b] or main_of[b] in linked.get(main_of[a], set())
                    or main_of[a] in linked.get(main_of[b], set()))
        rope_rows.append({"title": r["title"], "kind": r.get("kind"), "parent": r.get("parent"),
                          "children": [titles.get(k, k) for k in r["children"]], "pairs": len(pairs), "agree": agree,
                          "reason": r.get("reason")})
    has_links = any(linked.values())
    scored = [r for r in rows if "b3_f1" in r]
    mean = lambda xs: round(statistics.mean(xs), 3) if xs else None  # noqa: E731
    out = {
        "maps": len(rows), "with_sub_threads": len(scored),
        "strand_b3_f1": mean([r["b3_f1"] for r in scored]), "strand_b3_p": mean([r["b3_p"] for r in scored]),
        "strand_b3_r": mean([r["b3_r"] for r in scored]), "one_strand_b3_f1": mean([r["one_strand_b3_f1"] for r in scored]),
        "one_strand_b3_p": mean([r["one_strand_b3_p"] for r in scored]),
        "separation": mean([r["separation"] for r in scored if r["separation"] is not None]),
        "separation_chance": mean([r["separation_chance"] for r in scored if r["separation_chance"] is not None]),
        "coverage": mean([r["coverage"] for r in scored]),
        "fact_coverage": mean([r["fact_coverage"] for r in rows if r["fact_coverage"] is not None]),
        "prompt_tokens_mean": mean([r["prompt_tokens"] for r in rows if r["prompt_tokens"]]),
        "completion_tokens_mean": mean([r["completion_tokens"] for r in rows if r["completion_tokens"]]),
        "seconds_mean": mean([r["seconds"] for r in rows if r["seconds"]]),
        "seconds_p95": (sorted(r["seconds"] for r in rows if r["seconds"])[int(0.95 * (len(rows) - 1))] if rows else None),
        "rope_pairs": sum(r["pairs"] for r in rope_rows) if has_links else None,
        "rope_pairs_linked": sum(r["agree"] for r in rope_rows) if has_links else None,
        "ropes": rope_rows,
        "rows": rows,
    }
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in out.items() if k not in ("rows", "ropes")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
