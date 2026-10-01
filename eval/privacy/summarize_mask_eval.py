#!/usr/bin/env python3
"""Summarize run_mask_eval.py runs into one JSON: every run, mean ± sd per (set, masking), on - off.

  python3 eval/privacy/summarize_mask_eval.py OUT_ROOT --identifiers DIR/identifiers.json \
      --numbers DIR/scenario.json -o mask-eval.json

OUT_ROOT holds one directory per run named <set>-<off|on>-r<n> (set = holdout | numbers), each with
mask_report.json, score.json, score_unmasked.json, stats.json, meta.json and snapshots/.

Quality is read from score_unmasked.json (what the Mac shows after unmask); the raw score (what the Spark
holds) is kept per run. Beyond score.py it adds, per run, item placement against gold at the final
checkpoint, split into items that carry an inserted identifier and items that do not, and the agreement of
item placements between runs (within one condition and across conditions), so a masking effect can be told
apart from run-to-run noise.
"""

from __future__ import annotations

import argparse
import itertools
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import score as scorer  # noqa: E402

METRICS = [
    ("bcubed_f1", "B³ F1"), ("bcubed_precision", "B³ P"), ("bcubed_recall", "B³ R"), ("link_f1", "Link F1"),
    ("card_fact_recall", "card fact recall"), ("status_fact_recall", "status-line fact recall"),
    ("hard_decoy_leakage", "hard-decoy leakage ↓"), ("easy_decoy_leakage", "easy-decoy leakage ↓"),
    ("noise_unfiled_rate", "noise left unfiled"), ("noise_in_real_event_rate", "noise inside a real event ↓"),
    ("false_unfiled", "real items left unfiled ↓"), ("pred_event_count", "predicted events (gold 7)"),
    ("home_ndcg5", "home NDCG@5"), ("person_link_accuracy", "person linking"),
    ("unsupported_completion", "unsupported 已… claims ↓"), ("ungrounded_card_dates", "ungrounded card dates ↓"),
    ("question_count", "questions asked"), ("split_items_pred", "items filed by segments"),
]
RUN_RE = re.compile(r"^(holdout|numbers|probe)-(off|on)-r(\d+)$")


def mean_sd(values: list) -> dict:
    vals = [v for v in values if isinstance(v, (int, float))]
    if not vals:
        return {"n": 0}
    return {"n": len(vals), "mean": round(statistics.mean(vals), 4),
            "sd": round(statistics.stdev(vals), 4) if len(vals) > 1 else None,
            "min": round(min(vals), 4), "max": round(max(vals), 4)}


def placements(scenario: dict, snap: dict) -> tuple[dict, dict]:
    """(item -> frozenset of gold events its predicted events map to, item -> placed right) at the final
    checkpoint. Noise items are right when left unfiled."""
    gold = scorer.Gold(scenario)
    state = scorer.normalize_state(snap)
    universe = gold.universe()
    pred_map = {i: set(state["item_events"].get(i, set())) for i in universe}
    gold_map = {i: gold.item_events[i] for i in universe}
    mapping = scorer.match_clusters(gold_map, pred_map, universe)
    placed, right = {}, {}
    for i in universe:
        mapped = frozenset(mapping.get(p) or "unmatched" for p in pred_map[i])
        placed[i] = mapped
        right[i] = (not pred_map[i]) if not gold_map[i] else bool(set(mapped) & set(gold_map[i]))
    return placed, right


def agreement(a: dict, b: dict) -> float:
    keys = set(a) & set(b)
    return sum(1 for k in keys if a[k] == b[k]) / len(keys) if keys else float("nan")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root")
    ap.add_argument("--identifiers", required=True)
    ap.add_argument("--numbers", required=True, help="the stress scenario.json")
    ap.add_argument("--holdout", default=str(HERE.parent / "scenarios" / "holdout-week-v2" / "scenario.json"))
    ap.add_argument("--probe-dir", help="directory of mask_stress.py --probe (scenario.json, identifiers.json)")
    ap.add_argument("--similarity", help="mask_similarity.py output to include")
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args(argv)
    ids = json.loads(Path(args.identifiers).read_text(encoding="utf-8"))
    scen = {"numbers": json.loads(Path(args.numbers).read_text(encoding="utf-8")),
            "holdout": json.loads(Path(args.holdout).read_text(encoding="utf-8"))}
    if args.probe_dir:
        scen["probe"] = json.loads((Path(args.probe_dir) / "scenario.json").read_text(encoding="utf-8"))
    id_items = {r["item_id"].lower() for r in ids["occurrences"]}

    runs, place = [], {}
    for d in sorted(Path(args.root).iterdir()):
        m = RUN_RE.match(d.name)
        if not m or not (d / "mask_report.json").exists():
            continue
        s, mask, rep = m.group(1), m.group(2), int(m.group(3))
        rep_json = json.loads((d / "mask_report.json").read_text(encoding="utf-8"))
        stats = json.loads((d / "stats.json").read_text(encoding="utf-8"))
        unm = rep_json["score_unmasked"]
        snaps = scorer.load_snapshots(str(d / "snapshots_unmasked"))
        last = scen[s]["checkpoints"][-1]["checkpoint_id"]
        placed, right = placements(scen[s], snaps[last])
        place[(s, mask, rep)] = placed
        with_id = [right[i] for i in right if i in id_items]
        without = [right[i] for i in right if i not in id_items]
        brief = stats["per_job"].get("brief", {})
        n_items = len(scen[s]["items"])
        runs.append({
            "set": s, "mask": mask, "repeat": rep,
            **{k: unm.get(k) for k, _ in METRICS},
            "raw_score_differs_from_unmasked": sorted(rep_json["score_diff_unmasked_vs_raw"]),
            "items_placed_right": sum(right.values()),
            "items_with_identifier_placed_right": f"{sum(with_id)}/{len(with_id)}" if s == "numbers" else None,
            "items_without_identifier_placed_right": f"{sum(without)}/{len(without)}" if s == "numbers" else None,
            "brief_accepted": f"{brief.get('ok')}/{brief.get('calls')}",
            "wall_s": rep_json["wall_s"], "s_per_item": round(rep_json["wall_s"] / n_items, 1),
            "wire_raw_left": rep_json["wire_raw_left"], "wire_raw_left_by_format": rep_json["wire_raw_left_by_format"],
            "prompts": rep_json["prompts"], "store_raw_slots": (rep_json.get("store") or {}).get("raw_identifier_slots"),
            "store_tables_with_raw": sorted(((rep_json.get("store") or {}).get("tables_with_raw") or {})),
            "outputs_final": {k: rep_json["outputs_final"].get(k) for k in
                              ("placeholders", "placeholders_by_field", "attribution", "raw_identifiers",
                               "raw_identifiers_by_field", "examples")},
            "outputs_all_checkpoints": rep_json["outputs_all_checkpoints"],
            "outputs_all_calls": (rep_json.get("outputs_all_calls") or {}).get("total"),
            "outputs_all_calls_examples": (rep_json.get("outputs_all_calls") or {}).get("examples"),
            "mac_map_size": rep_json["mac_map_size"], "model": rep_json["model"], "git": rep_json["git"],
        })

    agg: dict = defaultdict(dict)
    for (s, mask), rows in itertools.groupby(sorted(runs, key=lambda r: (r["set"], r["mask"])),
                                             key=lambda r: (r["set"], r["mask"])):
        rows = list(rows)
        agg[s][mask] = {k: {**mean_sd([r[k] for r in rows]), "values": [r[k] for r in rows]}
                        for k, _ in METRICS + [("items_placed_right", ""), ("s_per_item", "")]}
    diff: dict = defaultdict(dict)
    for s in agg:
        if "on" in agg[s] and "off" in agg[s]:
            for k in agg[s]["on"]:
                a, b = agg[s]["on"][k], agg[s]["off"][k]
                if a.get("n") and b.get("n"):
                    diff[s][k] = round(a["mean"] - b["mean"], 4)

    # Placement agreement between runs: within a condition vs across conditions.
    agree: dict = {}
    for s in ("numbers", "holdout"):
        keys = [k for k in place if k[0] == s]
        within, across = [], []
        for a, b in itertools.combinations(keys, 2):
            (within if a[1] == b[1] else across).append(agreement(place[a], place[b]))
        if keys:
            agree[s] = {"within_condition": mean_sd(within), "across_conditions": mean_sd(across)}

    # Restoration, over every masked run.
    restoration = {"final": Counter(), "all_checkpoints": Counter(), "attribution": Counter(),
                   "by_field": defaultdict(Counter), "examples": [], "all_calls": defaultdict(Counter),
                   "all_calls_examples": []}
    raw_in_outputs = defaultdict(Counter)
    for r in runs:
        raw_in_outputs[(r["set"], r["mask"])]["runs"] += 1
        raw_in_outputs[(r["set"], r["mask"])]["raw_identifiers_final"] += r["outputs_final"]["raw_identifiers"] or 0
        if r["mask"] != "on":
            continue
        restoration["final"].update(r["outputs_final"]["placeholders"] or {})
        restoration["all_checkpoints"].update(r["outputs_all_checkpoints"] or {})
        restoration["attribution"].update(r["outputs_final"]["attribution"] or {})
        for f, c in (r["outputs_final"]["placeholders_by_field"] or {}).items():
            restoration["by_field"][f].update(c)
        restoration["examples"] += [dict(e, run=f"{r['set']}-on-r{r['repeat']}") for e in r["outputs_final"]["examples"]]
        restoration["all_calls"][r["set"]].update(r["outputs_all_calls"] or {})
        restoration["all_calls_examples"] += [dict(e, run=f"{r['set']}-on-r{r['repeat']}")
                                              for e in r["outputs_all_calls_examples"] or []]


    # Paired shadow calls (run_mask_eval.py --shadow): shadow-s<n> on the stress set, probeshadow-s<n> on the probe.
    shadow: dict = {}
    for d in sorted(Path(args.root).iterdir()):
        m = re.match(r"^(shadow|probeshadow)-s(\d+)$", d.name)
        if not m or not (d / "mask_report.json").exists():
            continue
        rep_json = json.loads((d / "mask_report.json").read_text(encoding="utf-8"))
        s_name = "numbers" if m.group(1) == "shadow" else "probe"
        entry = shadow.setdefault(s_name, {"runs": [], "total": defaultdict(Counter)})
        entry["runs"].append({"run": d.name, "shadow": rep_json["shadow"],
                              "bcubed_f1": rep_json["score_unmasked"]["bcubed_f1"],
                              "link_f1": rep_json["score_unmasked"]["link_f1"],
                              "card_fact_recall": rep_json["score_unmasked"]["card_fact_recall"],
                              "outputs_final": rep_json["outputs_final"]["placeholders"]})
        for job, c in (rep_json["shadow"] or {}).items():
            entry["total"][job].update(c)
        entry.setdefault("all_model_outputs", Counter()).update((rep_json.get("outputs_all_calls") or {}).get("total") or {})
        entry.setdefault("all_model_outputs_examples", []).extend(
            dict(e, run=d.name) for e in (rep_json.get("outputs_all_calls") or {}).get("examples") or [])
    for v in shadow.values():
        v["total"] = {k: dict(c) for k, c in v["total"].items()}
        v["all_model_outputs"] = dict(v.get("all_model_outputs") or {})

    fmt_tot, fmt_caught = Counter(), Counter()
    on_numbers = [r for r in runs if r["set"] == "numbers" and r["mask"] == "on"]
    left = on_numbers[0]["wire_raw_left_by_format"] if on_numbers else {}
    for r in ids["occurrences"]:
        fmt_tot[r["format"]] += 1
    for f, n in fmt_tot.items():
        fmt_caught[f] = n - min(n, left.get(f, 0))
    out = {
        "question": "Does masking identifiers before they reach the Spark change organizing quality?",
        "numbers_set": {"seed": ids["seed"], "scenario_sha256": ids["scenario_sha256"],
                        "source_sha256": ids["source_sha256"], "occurrences": len(ids["occurrences"]),
                        "distinct_values": len({r["slot"] for r in ids["occurrences"]}),
                        "items_touched": len(id_items),
                        "by_type": dict(Counter(r["type"] for r in ids["occurrences"])),
                        "masked_on_the_wire_by_format": {f: f"{fmt_caught[f]}/{n}" for f, n in sorted(fmt_tot.items())}},
        "metrics": dict(METRICS),
        "aggregate": agg, "on_minus_off": diff, "placement_agreement": agree,
        "restoration": {"final": dict(restoration["final"]), "all_checkpoints": dict(restoration["all_checkpoints"]),
                        "attribution": dict(restoration["attribution"]),
                        "by_field": {k: dict(v) for k, v in restoration["by_field"].items()},
                        "examples": restoration["examples"][:30],
                        "all_model_outputs": {k: dict(v) for k, v in restoration["all_calls"].items()},
                        "all_model_outputs_examples": restoration["all_calls_examples"][:40]},
        "raw_identifiers_in_final_outputs": {f"{s}-{m}": dict(c) for (s, m), c in raw_in_outputs.items()},
        "shadow": shadow,
        "similarity": json.loads(Path(args.similarity).read_text(encoding="utf-8")) if args.similarity else None,
        "runs": runs,
    }
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    for s in agg:
        for k in ("bcubed_f1", "link_f1", "card_fact_recall", "hard_decoy_leakage", "items_placed_right"):
            row = [f"{m}: {agg[s][m][k].get('mean')}±{agg[s][m][k].get('sd')} {agg[s][m][k]['values']}"
                   for m in ("off", "on") if m in agg[s]]
            print(s, k, " | ".join(row), "diff", diff[s].get(k))
    print("agreement", json.dumps(agree))
    print("restoration", json.dumps(out["restoration"]["final"], ensure_ascii=False),
          json.dumps(out["restoration"]["attribution"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
