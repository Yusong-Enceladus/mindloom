#!/usr/bin/env python3
"""Why does the organizer over-fragment a scale scenario? Read-only probe of a finished synthetic store.

No model calls. Run it where the store is (a copy of a scale run's organizer.db) with a Python that has
`sqlcipher3` (the organizer's venv). It never writes; the store is opened read-only with the synthetic key.

  python3 eval/tools/frag_probe.py --db <organizer.db> --scenario eval/scenarios/scale-lab/scenario.json \
      [--variant old8:skills/event-assign/scripts/candidates.py:8 --variant new8:other/candidates.py:8:3:0.95] --out probe.json

What it reports (all counts; no item text):
  1. mapping    how many store items were matched to scenario items (by id, else by exact text).
  2. events     final live events by category: main (the largest event of a gold matter), fragment (majority of one
                gold matter, not its main), noise-only, noise-mixed (real and noise items together), and the
                singleton count of each.
  3. assign     the first items of fragments: an item that opened an event of its own although an event of its
                gold matter already held an earlier item ("missed attach"). For those, did the 5 candidates
                event-assign saw (logged in the store) hold the matter's largest event at that time / any event of
                the matter? Then the same question replayed offline with another candidate script and k
                (--variant), on the events as event-assign formed them (merges ignored: the fragmented upper bound).
  4. consolidate  for fragments still alive: never judged / judged and kept (with the right matter as candidate or
                not, with the right matter among the targets or not) / skipped by a guard / invalid / stale.
  5. noise      noise items sitting in real matters: attached by event-assign directly, or carried in by a
                consolidation merge of a noise event.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))


def load_script(path: Path):
    spec = importlib.util.spec_from_file_location("probe_candidates", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def rows(conn, sql, args=()):
    cur = conn.execute(sql, args)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--variant", action="append", default=[],
                    help="label:script:k[:reserve[:fragment_cos[:reserve_min_sim]]] - a candidate script to replay (repeatable)")
    ap.add_argument("--terms-script", default=str(ROOT / "skills/event-consolidate/scripts/validate.py"))
    ap.add_argument("--sample-other", type=int, default=400, help="real items that were attached normally, sampled for the recall check")
    ap.add_argument("--out", required=True)
    ap.add_argument("--src", help="organizer package parent dir (default: this checkout's spark/)")
    args = ap.parse_args()
    if args.src:
        sys.path.insert(0, args.src)
    from organizer import db  # noqa: E402

    variants = []
    for v in args.variant or [f"old{k}:{ROOT / 'skills/event-assign/scripts/candidates.py'}:{k}" for k in (5, 8, 12)]:
        parts = v.split(":")
        label, script, k = parts[0], parts[1], int(parts[2])
        opts = {}
        if len(parts) > 3 and parts[3]:
            opts["reserve"] = int(parts[3])
        if len(parts) > 4 and parts[4]:
            opts["fragment_cos"] = float(parts[4])
        if len(parts) > 5 and parts[5]:
            opts["reserve_min_sim"] = float(parts[5])
        variants.append((label, load_script(Path(script)), k, opts))
    terms_of = load_script(Path(args.terms_script)).terms

    conn = db.open_for_analysis(args.db)
    scen = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    noise_ids = {e["event_id"] for e in scen["events"] if e.get("kind") == "noise"}
    gold_items = {it["item_id"].lower(): it for it in scen["items"]}
    by_text = defaultdict(list)
    for it in scen["items"]:
        t = (it.get("text") or "").strip()
        if t:
            by_text[t].append(it["item_id"].lower())

    # ---- 1. mapping store item -> gold item ------------------------------------------------
    def table_cols(t):
        return {c["name"] for c in rows(conn, f"PRAGMA table_info({t})")}

    purged = " AND purged = 0" if "purged" in table_cols("items") else ""
    items = rows(conn, "SELECT item_id, started_ts, text, kind, source_app FROM items i WHERE revision ="
                       " (SELECT MAX(revision) FROM items j WHERE j.item_id = i.item_id)" + purged)
    seg_parent = {r["child_id"]: r["parent_id"] for r in rows(conn, "SELECT child_id, parent_id FROM item_segments")} \
        if table_cols("item_segments") else {}
    gmap, how = {}, Counter()
    used = set()
    for it in items:
        iid = it["item_id"]
        if iid in seg_parent:
            continue  # a segment takes its parent's gold item below
        if iid.lower() in gold_items:
            gmap[iid] = iid.lower(); how["id"] += 1
            continue
        t = (it["text"] or "").strip()
        cands = [g for g in by_text.get(t, []) if g not in used] if t else []
        if cands:
            gmap[iid] = cands[0]; used.add(cands[0]); how["text"] += 1
        else:
            how["unmapped"] += 1
    for it in items:
        iid = it["item_id"]
        if iid in seg_parent:
            if seg_parent[iid] in gmap:
                gmap[iid] = gmap[seg_parent[iid]]; how["segment_of_mapped_parent"] += 1
            else:
                how["unmapped_segment"] += 1

    def gold_events(iid):
        g = gold_items.get(gmap.get(iid, ""))
        return list(g.get("events") or []) if g else None

    def real_label(iid):
        ev = gold_events(iid)
        if ev is None:
            return None
        real = [e for e in ev if e not in noise_ids]
        return real or ["NOISE"]

    order = sorted(items, key=lambda r: (r["started_ts"], r["item_id"]))
    pos = {r["item_id"]: i for i, r in enumerate(order)}
    ts = {r["item_id"]: r["started_ts"] for r in items}

    # ---- links: final and first (assign-time) -------------------------------------------
    links = rows(conn, "SELECT rowid AS rid, event_id, item_id, attached_by, removed, removed_by FROM event_items ORDER BY rowid")
    first_event, final_event = {}, {}
    for l in links:
        first_event.setdefault(l["item_id"], l["event_id"])
        if not l["removed"]:
            final_event[l["item_id"]] = l["event_id"]
    live = {r["event_id"] for r in rows(conn, "SELECT event_id FROM events WHERE deleted = 0")}
    merged_into = {r["event_id"]: r["merged_into"] for r in rows(conn, "SELECT event_id, merged_into FROM events WHERE deleted = 1")}
    unfiled = {r["item_id"] for r in rows(conn, "SELECT item_id FROM unfiled")} if table_cols("unfiled") else set()

    def members(assign_map):
        out = defaultdict(list)
        for iid, e in assign_map.items():
            out[e].append(iid)
        return out

    final_m, first_m = members(final_event), members(first_event)

    def majority(ids):
        c = Counter()
        for i in ids:
            lab = real_label(i)
            if lab is None:
                continue
            for g in lab:
                c[g] += 1
        return c

    def classify(ms):
        """event_id -> {kind, gold, n, n_real, n_noise}"""
        main_of = {}
        info = {}
        for e, ids in ms.items():
            c = majority(ids)
            real = {g: n for g, n in c.items() if g != "NOISE"}
            n_noise = c.get("NOISE", 0)
            top = max(real, key=real.get) if real else None
            info[e] = {"n": len(ids), "gold": top, "n_top": real.get(top, 0) if top else 0, "n_noise": n_noise,
                       "n_real": sum(1 for i in ids if real_label(i) not in (None, ["NOISE"]))}
        best = {}
        for e, d in info.items():
            g = d["gold"]
            if g and (g not in best or (d["n_top"], -len(e)) > (info[best[g]]["n_top"], -len(best[g]))):
                best[g] = e
        for e, d in info.items():
            if d["gold"] is None:
                d["kind"] = "noise-only"
            elif best[d["gold"]] == e:
                d["kind"] = "main"
            else:
                d["kind"] = "fragment"
            if d["gold"] is not None and d["n_noise"] and d["kind"] != "noise-only":
                d["mixed"] = True
        return info, best

    final_info, final_best = classify({e: ids for e, ids in final_m.items() if e in live})
    kinds = Counter(d["kind"] for d in final_info.values())
    singles = Counter(d["kind"] for d in final_info.values() if d["n"] == 1)
    mixed = sum(1 for d in final_info.values() if d.get("mixed"))
    noise_in_real = sum(d["n_noise"] for d in final_info.values() if d["gold"] is not None)
    noise_total = sum(1 for i in gmap if real_label(i) == ["NOISE"])
    events_report = {"live_events": len(final_info), "gold_matters": len([e for e in scen["events"] if e.get("kind") != "noise"]),
                     "by_kind": dict(kinds), "singletons_by_kind": dict(singles), "events_with_noise_inside_real": mixed,
                     "noise_items_in_real_events": noise_in_real, "noise_items_total": noise_total,
                     "unfiled_items": len(unfiled)}

    # ---- 3. assign-time: missed attaches --------------------------------------------------
    first_info, first_best_final = classify(first_m)
    proposals = rows(conn, "SELECT target_id, payload, status, reason FROM proposals WHERE kind='assign' ORDER BY proposal_id")
    logged = {}
    for p in proposals:
        try:
            logged[p["target_id"]] = json.loads(p["payload"])
        except Exception:  # noqa: BLE001
            continue
    # events as event-assign saw them at time T: items placed earlier, grouped by their first event
    emb_rows = rows(conn, "SELECT item_id, embedding FROM item_derived d WHERE revision = (SELECT MAX(revision) FROM "
                          "item_derived e WHERE e.item_id = d.item_id) AND embedding IS NOT NULL")
    emb = {r["item_id"]: json.loads(r["embedding"]) for r in emb_rows}
    prs = rows(conn, "SELECT item_id, person_id FROM item_persons WHERE role NOT IN ('text_speaker','transcript_speaker','mention')")
    persons_of = defaultdict(set)
    for r in prs:
        persons_of[seg_parent.get(r["item_id"], r["item_id"])].add(r["person_id"])
        persons_of[r["item_id"]].add(r["person_id"])
    freq = Counter(p for s in persons_of.values() for p in s)
    owners = {p for p, n in freq.items() if n > 0.2 * max(1, len(items))}
    src_of = {r["item_id"]: (json.loads(r["source_app"]).get("bundle_id") or json.loads(r["source_app"]).get("name") or "").lower()
              for r in items}

    ev_terms = {r["event_id"]: sorted(terms_of(f'{r.get("anchor") or ""} {r.get("title") or ""}'))
                for r in rows(conn, "SELECT * FROM events")}
    text_of = {r["item_id"]: (r["text"] or "")[:1500] for r in items}
    import random
    rnd = random.Random(7)
    # incremental event features, in processing order
    feat = {}   # event_id -> accum
    miss_cases = []
    first_seen_event = {}  # event_id -> first item pos
    other = Counter()  # recall on items that were attached normally (sampled)
    other_n = 0
    all_real = Counter()
    for r in order:
        iid = r["item_id"]
        e = first_event.get(iid)
        lab = real_label(iid)
        if e is None:
            continue
        gold_g = None if lab in (None, ["NOISE"]) else lab[0]
        # the matter's largest event so far (first-link clusters, items before this one)
        if gold_g is not None:
            cnt = Counter()
            for ev, a in feat.items():
                n = a["gold"].get(gold_g, 0)
                if n:
                    cnt[ev] = n
            main_now = max(cnt, key=lambda ev: (cnt[ev], -first_seen_event[ev])) if cnt else None
            opened_new = e not in feat
            if main_now is not None:
                all_real["with_existing_matter_event"] += 1
            sampled = main_now is not None and not opened_new and rnd.random() < args.sample_other / 2400.0
            if (opened_new and main_now is not None) or sampled:
                lg = logged.get(iid) or {}
                q = {"embedding": emb.get(iid), "ts": r["started_ts"], "person_ids": sorted(persons_of.get(iid, set()) - owners),
                     "source": src_of.get(iid, ""), "terms": sorted(terms_of(text_of.get(iid, "")))}
                events_now = []
                for ev, a in feat.items():
                    cvec = a["centroid"]()
                    events_now.append({"event_id": ev, "centroid": cvec, "centroid_norm": a["norm"](cvec), "first_ts": a["first"],
                                       "last_ts": a["last"], "person_ids": sorted(a["persons"] - owners), "sources": sorted(a["sources"]),
                                       "order": first_seen_event[ev], "n": a["n"], "ts": sorted(a["tss"]),
                                       "terms": ev_terms.get(ev, [])})
                res = {}
                for label, mod, k, opts in variants:
                    top = mod.rank_candidates(q, events_now, [], k, self_ids=sorted(owners), **opts)
                    ids = [c["event_id"] for c in top]
                    res[label] = (main_now in ids, any(c in cnt for c in ids))
                if opened_new:
                    full = variants[0][1].rank_candidates(q, events_now, [], 10_000, self_ids=sorted(owners))
                    rank = next((i for i, c in enumerate(full) if c["event_id"] == main_now), None)
                    mrow = full[rank] if rank is not None else {}
                    case = {"main_rank": rank, "main_sim": mrow.get("similarity"), "main_time": mrow.get("time"),
                            "top1_sim": full[0]["similarity"] if full else None, "n_events": len(full), "main_n_items": cnt[main_now],
                            "item_chars": len(text_of.get(iid, "")), "item": iid, "gold": gold_g, "main_size": cnt[main_now], "n_gold_events_before": len(cnt)}
                    cands = [c["event_id"] for c in (lg.get("candidates") or [])]
                    case["logged_has_main"] = main_now in cands
                    case["logged_has_any_matter_event"] = any(c in cnt for c in cands)
                    case["logged_action"] = (lg.get("derived") or {}).get("action")
                    case["sim"] = res
                    miss_cases.append(case)
                else:
                    other_n += 1
                    cands = [c["event_id"] for c in (lg.get("candidates") or [])]
                    other["logged"] += int(main_now in cands)
                    for label, (m, _a) in res.items():
                        other[label] += int(m)
        # add this item to its first event
        a = feat.get(e)
        if a is None:
            first_seen_event[e] = r["started_ts"]
            a = feat[e] = {"gold": Counter(), "n": 0, "first": r["started_ts"], "last": r["started_ts"], "persons": set(), "sources": set(),
                           "sum": None, "k": 0, "tss": []}
            a["centroid"] = (lambda a=a: [x / a["k"] for x in a["sum"]] if a["k"] else None)
            a["norm"] = (lambda v: math.sqrt(sum(x * x for x in v)) if v else None)
        a["n"] += 1
        a["first"], a["last"] = min(a["first"], r["started_ts"]), max(a["last"], r["started_ts"])
        a["tss"].append(r["started_ts"])
        a["persons"] |= persons_of.get(iid, set())
        a["sources"].add(src_of.get(iid, ""))
        if lab:
            for g in lab:
                a["gold"][g] += 1
        v = emb.get(iid)
        if v:
            a["sum"] = list(v) if a["sum"] is None else [x + y for x, y in zip(a["sum"], v)]
            a["k"] += 1
    n_miss = len(miss_cases)
    assign_report = {"real_items_with_an_existing_event_of_their_matter": all_real["with_existing_matter_event"],
                     "missed_attaches": n_miss}
    if n_miss:
        assign_report["logged_top5_has_largest_matter_event"] = sum(c["logged_has_main"] for c in miss_cases)
        assign_report["logged_top5_has_any_matter_event"] = sum(c["logged_has_any_matter_event"] for c in miss_cases)
        assign_report["logged_action"] = dict(Counter(c["logged_action"] for c in miss_cases))
        for label, *_ in variants:
            assign_report[f"replay_{label}_has_largest_matter_event"] = sum(c["sim"][label][0] for c in miss_cases)
            assign_report[f"replay_{label}_has_any_matter_event"] = sum(c["sim"][label][1] for c in miss_cases)
        assign_report["matter_event_count_before_median"] = sorted(c["n_gold_events_before"] for c in miss_cases)[n_miss // 2]

    if miss_cases:
        ranks = sorted(c["main_rank"] for c in miss_cases if c["main_rank"] is not None)
        sims = sorted(c["main_sim"] for c in miss_cases if c["main_sim"] is not None)
        assign_report["main_rank_percentiles_p25_50_75_90"] = [ranks[int(len(ranks) * q)] for q in (0.25, 0.5, 0.75, 0.9)] if ranks else None
        assign_report["main_similarity_percentiles_p10_50_90"] = [round(sims[int(len(sims) * q)], 3) for q in (0.1, 0.5, 0.9)] if sims else None
        far = [c for c in miss_cases if (c["main_rank"] or 0) >= 12]
        assign_report["misses_with_main_rank_ge_12"] = len(far)
        assign_report["far_main_median_n_items"] = sorted(c["main_n_items"] for c in far)[len(far) // 2] if far else None
        assign_report["far_item_chars_median"] = sorted(c["item_chars"] for c in far)[len(far) // 2] if far else None
        assign_report["near_item_chars_median"] = sorted(c["item_chars"] for c in miss_cases if (c["main_rank"] or 0) < 12)[
            max(0, (len(miss_cases) - len(far)) // 2)] if len(miss_cases) > len(far) else None
    assign_report["sampled_normal_attaches"] = other_n
    if other_n:
        assign_report["sampled_normal_logged_top5_has_largest_matter_event"] = other["logged"]
        for label, *_ in variants:
            assign_report[f"sampled_normal_replay_{label}_has_largest_matter_event"] = other[label]

    # ---- 4. consolidation of the live fragments ----------------------------------------------
    checks = {r["event_id"]: r for r in rows(conn, "SELECT * FROM consolidate_checks")} if table_cols("consolidate_checks") else {}
    cons = defaultdict(list)
    for p in rows(conn, "SELECT target_id, payload, status, reason, proposal_id FROM proposals WHERE kind='consolidate' AND target_id != 'pass' ORDER BY proposal_id"):
        try:
            cons[p["target_id"]].append((p, json.loads(p["payload"])))
        except Exception:  # noqa: BLE001
            pass
    handle_of = {r["event_id"]: r["handle"] for r in rows(conn, "SELECT event_id, handle FROM events")} if \
        "handle" in table_cols("events") else {}
    frag_report = Counter()
    frag_examples = []
    for e, d in final_info.items():
        if d["kind"] != "fragment":
            continue
        ck = checks.get(e)
        hist = cons.get(e, [])
        size_bucket = "1" if d["n"] == 1 else "2-3" if d["n"] <= 3 else "4-9" if d["n"] <= 9 else "10+"
        if not ck and not hist:
            frag_report[f"never_judged(n={size_bucket})"] += 1
            continue
        last = hist[-1][1] if hist else {}
        verdict = last.get("verdict")
        rel = last.get("relation")
        main_ev = final_best.get(d["gold"])
        main_h = handle_of.get(main_ev)
        cand = last.get("candidate")
        targets = last.get("targets") or []
        cand_ok = bool(main_h) and cand == f"E{main_h}"
        in_targets = bool(main_h) and f"E{main_h}" in targets
        outcome = (ck or {}).get("outcome", "?")
        frag_report[f"{outcome}|verdict={verdict}|rel={rel}|cand_is_main={cand_ok}|main_in_targets={in_targets}"] += 1
        frag_report[f"n_checks={(ck or {}).get('n_checks', 0)}"] += 1
    # ---- 5. noise carried into real events -----------------------------------------------
    route = Counter()
    for iid, e in final_event.items():
        if real_label(iid) == ["NOISE"] and e in final_info and final_info[e]["gold"] is not None:
            fe = first_event.get(iid)
            if fe == e:
                route["assigned_directly_into_the_real_event"] += 1
            else:
                fi = first_info.get(fe, {})
                route[f"carried_by_merge_from_{'noise-only' if fi.get('gold') is None else 'real'}_first_event(n={'1' if fi.get('n', 0) == 1 else '2+'})"] += 1
    result = {"mapping": {"store_items": len(items), "mapped": len(gmap), "by": dict(how)}, "events": events_report,
              "assign": assign_report, "consolidate_of_live_fragments": dict(frag_report), "noise_routes": dict(route),
              "miss_cases_head": [{k: v for k, v in c.items() if k not in ("item", "sim")} for c in miss_cases[:8]]}
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "miss_cases_head"}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
