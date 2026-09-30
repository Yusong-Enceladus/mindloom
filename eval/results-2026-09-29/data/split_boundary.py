"""item-split quality measured on the production scale runs (no new model calls).

For every scenario item with text, compare the parts the Spark organizer actually made (organizer.db
item_segments, active rows, offsets into the text the Spark received) with the scenario's segment truth
(event_segments / event_spans / matter_segments quotes, located in that same text). Gold quotes are
grouped by event ("matters"); a quote with event_id null is an aside and is not a matter. An item with two
or more matters should be split. A matter is recovered when one predicted part (one to one) holds at least
half of that matter's quoted characters; a part's purity is the share of the quoted characters inside it
that belong to its majority matter. Prints aggregates only.

usage: python3 split_boundary.py ORGANIZER_DB SCENARIO_JSON MAC_ID_MAP_JSON
"""
import json
import sqlite3
import sys

db, scen, idmap = sys.argv[1:4]
c = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
scenario = json.load(open(scen))
mac_to_scn = json.load(open(idmap))
scn_to_mac = {v: k for k, v in mac_to_scn.items()}

texts = {}
for iid, rev, text in c.execute("select item_id, revision, text from items"):
    if iid not in texts or rev > texts[iid][0]:
        texts[iid] = (rev, text or "")
segs = {}
children = {}
for child, parent, prev, start, end, active in c.execute(
        "select child_id, parent_id, parent_revision, start, \"end\", active from item_segments"):
    if active:
        segs.setdefault(parent, []).append((start, end))
        children.setdefault(parent, []).append(child)
ev_of = {}
for ev, iid in c.execute("select event_id, item_id from event_items where removed = 0"):
    ev_of.setdefault(iid, set()).add(ev)


def gold_quotes(item):
    extra = (item.get("event_segments") or []) + (item.get("event_spans") or []) + (item.get("matter_segments") or [])
    return [s for s in (item.get("segments") or []) + extra if "quote" in s]


def overlap(a, b):
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def match(pred, gold):
    pairs = sorted(((overlap(p, g), i, j) for i, p in enumerate(pred) for j, g in enumerate(gold)
                    if overlap(p, g) >= 0.5 * (g[1] - g[0]) and overlap(p, g) >= 0.5 * (p[1] - p[0])), reverse=True)
    up, ug, n = set(), set(), 0
    for _, i, j in pairs:
        if i not in up and j not in ug:
            up.add(i); ug.add(j); n += 1
    return n


st = {"items_scored": 0, "skipped_no_text": 0, "skipped_quote_not_found": 0, "gold_multi": 0, "pred_multi": 0,
      "tp": 0, "fp": 0, "fn": 0, "tn": 0, "exact_count": 0, "multi_exact_count": 0, "gold_matters_in_multi": 0,
      "matters_recovered": 0, "multi_all_recovered": 0, "multi_any_recovered": 0, "pred_parts_in_multi": 0,
      "pred_parts_matched": 0, "quotes_per_multi_item": 0, "oversplit_items": 0, "oversplit_same_event": 0,
      "oversplit_several_events": 0, "oversplit_some_part_unfiled": 0}
purities = []
for item in scenario["items"]:
    mac = scn_to_mac.get(item["item_id"])
    if not mac or mac not in texts or item.get("kind") == "image":
        st["skipped_no_text"] += 1
        continue
    text = texts[mac][1]
    groups = {}
    ok = True
    for s in gold_quotes(item):
        k = text.find(s["quote"])
        if k < 0:
            ok = False
            break
        groups.setdefault(s.get("event_id") or "_aside", []).append((k, k + len(s["quote"])))
    if not ok:
        st["skipped_quote_not_found"] += 1
        continue
    matters = {e: sp for e, sp in groups.items() if e != "_aside"}
    gm = len(matters) >= 2
    p = sorted(segs.get(mac, []))
    pm = len(p) >= 2
    pred = p if pm else [(0, len(text))]
    st["items_scored"] += 1
    st["gold_multi"] += gm; st["pred_multi"] += pm
    st["tp"] += gm and pm; st["fp"] += (not gm) and pm; st["fn"] += gm and not pm; st["tn"] += (not gm) and not pm
    if pm and not gm:
        evs = [ev_of.get(ch, set()) for ch in children.get(mac, [])]
        st["oversplit_items"] += 1
        if any(not e for e in evs):
            st["oversplit_some_part_unfiled"] += 1
        allev = set().union(*evs) if evs else set()
        if len(allev) == 1 and all(evs):
            st["oversplit_same_event"] += 1
        elif len(allev) > 1:
            st["oversplit_several_events"] += 1
    n_gold = max(1, len(matters))
    st["exact_count"] += len(pred) == n_gold
    if not gm:
        continue
    st["multi_exact_count"] += len(pred) == n_gold
    st["quotes_per_multi_item"] += sum(len(v) for v in groups.values())
    tot = {e: sum(b - a for a, b in sp) for e, sp in matters.items()}
    cov = {(i, e): sum(overlap(pp, x) for x in sp) for i, pp in enumerate(pred) for e, sp in matters.items()}
    pairs = sorted(((v, i, e) for (i, e), v in cov.items() if tot[e] and v >= 0.5 * tot[e]), reverse=True)
    ui, ue = set(), set()
    for v, i, e in pairs:
        if i not in ui and e not in ue:
            ui.add(i); ue.add(e)
    st["gold_matters_in_multi"] += len(matters)
    st["matters_recovered"] += len(ue)
    st["multi_all_recovered"] += len(ue) == len(matters)
    st["multi_any_recovered"] += len(ue) >= 1
    st["pred_parts_in_multi"] += len(pred); st["pred_parts_matched"] += len(ui)
    if pm:
        for i in range(len(pred)):
            vals = [cov[(i, e)] for e in matters]
            if sum(vals) > 0:
                purities.append(max(vals) / sum(vals))
n = st["items_scored"]
P = st["tp"] / max(1, st["tp"] + st["fp"]); R = st["tp"] / max(1, st["tp"] + st["fn"])
st["quotes_per_multi_item"] = round(st["quotes_per_multi_item"] / max(1, st["gold_multi"]), 1)
st.update({
    "split_decision_accuracy": round((st["tp"] + st["tn"]) / max(1, n), 3),
    "split_decision_precision": round(P, 3), "split_decision_recall": round(R, 3),
    "split_decision_f1": round(2 * P * R / max(1e-9, P + R), 3),
    "single_matter_oversplit_rate": round(st["fp"] / max(1, st["fp"] + st["tn"]), 3),
    "exact_part_count_rate": round(st["exact_count"] / max(1, n), 3),
    "multi_exact_part_count_rate": round(st["multi_exact_count"] / max(1, st["gold_multi"]), 3),
    "matter_recall_in_multi": round(st["matters_recovered"] / max(1, st["gold_matters_in_multi"]), 3),
    "part_precision_in_multi": round(st["pred_parts_matched"] / max(1, st["pred_parts_in_multi"]), 3),
    "multi_all_matters_recovered": round(st["multi_all_recovered"] / max(1, st["gold_multi"]), 3),
    "multi_any_matter_recovered": round(st["multi_any_recovered"] / max(1, st["gold_multi"]), 3),
    "part_purity_mean": round(sum(purities) / len(purities), 3) if purities else None,
    "parts_with_purity_ge_0.9": round(sum(1 for x in purities if x >= 0.9) / len(purities), 3) if purities else None,
})
print(json.dumps(st))
