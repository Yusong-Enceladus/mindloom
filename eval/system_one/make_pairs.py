#!/usr/bin/env python3
"""PERSON-MERGE and EVENT-MERGE pair sets, from TRAIN streams only (synthetic).

PERSON-MERGE: mentions of people (a surface form plus the sentence around it, its source app and time)
from scale-startup, scale-pm, dev-week-v1 and split-dev, plus the chat/transcript person names the
partial scale runs actually created (mapped to a scenario person by exact name/alias). Pairs are
labelled same/different by the scenario person. Positives: two different surfaces of one person
(aliases, nicknames, English names), and a few same-surface pairs; hard negatives: surfaces the
organizer's own near-match rule (organizer.persons._near) would put a same_person question to, or that
share a character; plus random negatives. VALIDATION = pairs touching a held-out person (every 5th
non-owner person of each stream, by person order).

EVENT-MERGE: the events the partial scale runs produced (scratchpad/partial/{startup,pm}-state.json)
mapped to truth through the run ledgers (organizer item id -> scenario ref): each member item (or
segment, matched to the gold segment quote it overlaps most) votes for its gold event; an event's truth
is the majority (purity reported). Pairs: every same-truth pair, plus each event's 8 nearest events by
member-embedding centroid and 2 random events as negatives. Each side is rendered as a card from what
the organizer has (its own title/anchor/status line, size, time span, member snippets, people names).
VALIDATION = pairs touching a held-out truth matter (every 5th event id: E05, E10, E15, E20).

  python3 eval/system_one/make_pairs.py DATA_DIR
Needs DATA_DIR/units.jsonl, embeddings.npy, embed_index.json.
"""
from __future__ import annotations

import itertools
import json
import random
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent / "spark"))
from build_units import LEDGERS, STATES, STREAMS  # noqa: E402
from make_choice import TZ8, clip, when  # noqa: E402
from organizer.persons import _near, core, norm  # noqa: E402

TRAIN = ["scale-startup", "scale-pm", "dev-week-v1", "split-dev"]
rng = random.Random(20260928)


def bigrams(s: str) -> set:
    s = re.sub(r"\s+", "", s or "")
    return {s[i:i + 2] for i in range(len(s) - 1)}


def jacc(a: set, b: set) -> float:
    return len(a & b) / max(1, min(len(a), len(b)))


# ---------------------------------------------------------------- persons
def person_mentions(stream: str) -> tuple[list[dict], dict, set]:
    sc = json.loads(STREAMS[stream][0].read_text(encoding="utf-8"))
    owner = sc["owner_person_id"]
    people = {p["person_id"]: p for p in sc["people"]}
    names = {pid: sorted({p["display_name"], *(p.get("aliases") or [])} - {"我"}, key=len, reverse=True)
             for pid, p in people.items()}
    ment = []
    for it in sc["items"]:
        text = it.get("text") or it.get("reading") or it.get("ground_truth_text") or ""
        if it.get("segments") and not text:
            text = "\n".join(s["text"] for s in it["segments"])
        found = []
        if it.get("person_mentions"):
            found = [(m["person_id"], m["surface"]) for m in it["person_mentions"]]
        else:
            for pid in it.get("persons") or []:
                if pid == owner or pid not in names:
                    continue
                for nm in names[pid]:
                    if len(nm) >= 2 and nm in text:
                        found.append((pid, nm))
                        break
        for pid, surf in found:
            if pid == owner or pid not in people:
                continue
            pos = text.find(surf)
            ctx = clip(text[max(0, pos - 40): pos + len(surf) + 40], 100) if pos >= 0 else ""
            ment.append({"stream": stream, "person": pid, "surface": surf, "context": ctx,
                         "source_app": it["source_app"], "when": when(datetime.fromisoformat(it["t"]).timestamp()),
                         "origin": "scenario_text", "ref": it.get("ref")})
    # the names the live runs created, mapped by exact name/alias
    if stream in STATES and STATES[stream].exists():
        st = json.loads(STATES[stream].read_text(encoding="utf-8"))
        alias2pid = defaultdict(set)
        for pid, ns in names.items():
            for n in ns:
                alias2pid[norm(n)].add(pid)
        for p in st["persons"]:
            dn = p["display_name"] or ""
            cands = set()
            for part in [dn] + dn.split(" ")[:1]:
                cands |= alias2pid.get(norm(part), set())
            if len(cands) == 1:
                pid = next(iter(cands))
                if pid != owner:
                    ment.append({"stream": stream, "person": pid, "surface": dn, "context": "",
                                 "source_app": {"chat": "聊天记录", "transcript": "会议记录"}.get(p["origin"], p["origin"]),
                                 "when": "", "origin": "organizer_person", "ref": None})
    order = [p for p in people if p != owner]
    held = {pid for i, pid in enumerate(order) if i % 5 == 4}
    return ment, {pid: people[pid]["display_name"] for pid in people}, held


def person_prompt(a: dict, b: dict) -> str:
    def side(m, tag):
        s = f"[{tag}] 称呼「{m['surface']}」"
        if m["source_app"] or m["when"]:
            s += f"（{m['when']} {m['source_app']}）".replace("（ ", "（")
        if m["context"]:
            s += f"\n    上下文：{m['context']}"
        return s
    return ("下面两个称呼指的是不是同一个人？\n" + side(a, "甲") + "\n" + side(b, "乙") +
            "\n只回答 same 或 different。")


def person_pairs() -> tuple[list[dict], dict]:
    rows = []
    stats = {}
    for stream in TRAIN:
        ment, display, held = person_mentions(stream)
        by_p = defaultdict(lambda: defaultdict(list))
        for m in ment:
            key = (m["context"], m["source_app"])
            if key not in {(x["context"], x["source_app"]) for x in by_p[m["person"]][m["surface"]]}:
                by_p[m["person"]][m["surface"]].append(m)
        pairs = []
        # positives
        for pid, surfs in by_p.items():
            ss = list(surfs)
            for s1, s2 in itertools.combinations(ss, 2):
                for _ in range(2):
                    pairs.append((rng.choice(surfs[s1]), rng.choice(surfs[s2]), "same",
                                  "alias" if not _near(s1, s2) else "near_alias"))
            for s in ss:
                if len(surfs[s]) >= 2:
                    a, b = rng.sample(surfs[s], 2)
                    pairs.append((a, b, "same", "same_surface"))
        n_pos = len(pairs)
        # negatives
        allsurf = [(pid, s) for pid, surfs in by_p.items() for s in surfs]
        hard = []
        for (p1, s1), (p2, s2) in itertools.combinations(allsurf, 2):
            if p1 == p2:
                continue
            if _near(s1, s2) or core(s1)[:1] == core(s2)[:1] or set(re.sub(r"[^一-鿿]", "", s1)) & set(re.sub(r"[^一-鿿]", "", s2)):
                hard.append(((p1, s1), (p2, s2), "near_rule" if _near(s1, s2) else "shared_char"))
        rng.shuffle(hard)
        hard = sorted(hard, key=lambda h: h[2] != "near_rule")[: max(n_pos, 50)]
        for (p1, s1), (p2, s2), why in hard:
            pairs.append((rng.choice(by_p[p1][s1]), rng.choice(by_p[p2][s2]), "different", why))
        n_rand = max(0, int(1.5 * n_pos) - len(hard))
        for _ in range(n_rand * 3):
            if n_rand <= 0:
                break
            (p1, s1), (p2, s2) = rng.sample(allsurf, 2)
            if p1 != p2:
                pairs.append((rng.choice(by_p[p1][s1]), rng.choice(by_p[p2][s2]), "different", "random"))
                n_rand -= 1
        seen = set()
        for a, b, lab, why in pairs:
            if rng.random() < 0.5:
                a, b = b, a
            key = (a["surface"], a["context"], b["surface"], b["context"])
            if key in seen or (a["surface"] == b["surface"] and a["context"] == b["context"]):
                continue
            seen.add(key)
            split = "val" if (a["person"] in held or b["person"] in held) else "train"
            rows.append({"stream": stream, "split": split, "a": {k: a[k] for k in ("surface", "context", "source_app", "when", "origin")},
                         "b": {k: b[k] for k in ("surface", "context", "source_app", "when", "origin")},
                         "label": lab, "kind": why, "person_a": a["person"], "person_b": b["person"],
                         "prompt": person_prompt(a, b)})
        stats[stream] = {"mentions": len(ment), "persons_with_mentions": len(by_p), "held_out_persons": len(held)}
    return rows, stats


# ---------------------------------------------------------------- events
def event_pairs(units: list[dict], emb: np.ndarray, index: dict) -> tuple[list[dict], dict]:
    rows, stats = [], {}
    for stream in ("scale-startup", "scale-pm"):
        sc = json.loads(STREAMS[stream][0].read_text(encoding="utf-8"))
        by_ref = {it["ref"]: it for it in sc["items"]}
        id2ref = {}
        for line in open(LEDGERS[stream], encoding="utf-8"):
            j = json.loads(line)
            if "id" in j:
                id2ref[j["id"].lower()] = j["ref"]
        st = json.loads(STATES[stream].read_text(encoding="utf-8"))
        pname = {p["person_id"]: p["display_name"] for p in st["persons"]}
        su = {u["unit_id"]: u for u in units if u["stream"] == stream}
        units_of_item = defaultdict(list)
        for u in su.values():
            units_of_item[u["item_id"]].append(u)
        evs = [e for e in st["events"] if not e.get("deleted") and not e.get("merged_into")]
        info = {}
        for e in evs:
            votes = Counter()
            vecs, snippets = [], []
            seg_items = defaultdict(list)
            for s in e.get("segments") or []:
                seg_items[s["item_id"].lower()].append(s)
            for iid in e["item_ids"]:
                ref = id2ref.get(iid.lower())
                it = by_ref.get(ref)
                if it is None:
                    continue
                gold = it.get("events") or []
                us = units_of_item[it["item_id"]]
                segs = seg_items.get(iid.lower())
                if segs and len(us) > 1:
                    body = (f"{it['filename']}\n\n{it['text']}" if it["kind"] == "document" and it.get("filename")
                            else it.get("text") or "")
                    for s in segs:
                        span = body[s["start"]: s["end"]] + " " + (s.get("gist") or "")
                        best = max(us, key=lambda u: jacc(bigrams(span), bigrams(u["text"])))
                        votes[best["gold"][0] if best["gold"] else "NONE"] += 1
                        vecs.append(emb[index[best["unit_id"]]])
                        snippets.append((best["ts"], best["source_app"], body[s["start"]: s["end"]] or best["text"]))
                else:
                    if gold:
                        for g in gold:
                            votes[g] += 1.0 / len(gold)
                    else:
                        votes["NONE"] += 1
                    vecs += [emb[index[u["unit_id"]]] for u in us]
                    u0 = us[0]
                    snippets.append((u0["ts"], u0["source_app"], u0["text"] if len(us) == 1 else it.get("text") or u0["text"]))
            if not votes:
                continue
            truth, v = votes.most_common(1)[0]
            snippets.sort()
            info[e["event_id"]] = {
                "truth": truth, "purity": round(v / sum(votes.values()), 3), "n": len(e["item_ids"]),
                "vec": np.mean(vecs, axis=0) if vecs else None,
                "card": {"title": e.get("title") or "", "anchor": e.get("anchor") or "",
                         "status_line": e.get("status_line") or "", "n_items": len(e["item_ids"]),
                         "first_seen": when(datetime.fromisoformat(e["started_at"]).timestamp()),
                         "last_seen": when(datetime.fromisoformat(e["updated_at"]).timestamp()),
                         "people": [pname.get(p, "") for p in (e.get("person_ids") or [])][:6],
                         "snippets": [{"when": when(t), "source_app": a, "text": clip(x, 110)}
                                      for t, a, x in (snippets[:2] + snippets[-1:] if len(snippets) > 3 else snippets)]}}
        ids = [i for i in info if info[i]["vec"] is not None]
        M = np.stack([info[i]["vec"] / np.linalg.norm(info[i]["vec"]) for i in ids])
        S = M @ M.T
        pairs = {}
        for a, b in itertools.combinations(range(len(ids)), 2):
            ta, tb = info[ids[a]]["truth"], info[ids[b]]["truth"]
            if ta == tb and ta != "NONE":
                pairs[(a, b)] = "same_truth"
        for a in range(len(ids)):
            nn = [b for b in np.argsort(-S[a]) if b != a][:8]
            for b in nn:
                pairs.setdefault((min(a, b), max(a, b)), "nearest")
            for b in rng.sample(range(len(ids)), 2):
                if b != a:
                    pairs.setdefault((min(a, b), max(a, b)), "random")
        held = {"E05", "E10", "E15", "E20"}
        for (a, b), why in pairs.items():
            ea, eb = info[ids[a]], info[ids[b]]
            same = ea["truth"] == eb["truth"] and ea["truth"] != "NONE"
            if rng.random() < 0.5:
                ea, eb = eb, ea
            split = "val" if (ea["truth"] in held or eb["truth"] in held) else "train"
            rows.append({"stream": stream, "split": split, "a": ea["card"], "b": eb["card"],
                         "label": "same" if same else "different", "kind": why, "similarity": round(float(S[a, b]), 4),
                         "truth_a": ea["truth"], "truth_b": eb["truth"], "purity_a": ea["purity"], "purity_b": eb["purity"],
                         "prompt": event_prompt(ea["card"], eb["card"])})
        pur = [info[i]["purity"] for i in info]
        stats[stream] = {"events": len(evs), "mapped": len(info), "mean_purity": round(float(np.mean(pur)), 3),
                         "truth_noise_events": sum(1 for i in info if info[i]["truth"] == "NONE"),
                         "distinct_truth": len({info[i]["truth"] for i in info}),
                         "state_covers_until": max(e["updated_at"] for e in evs)}
    return rows, stats


def event_prompt(a: dict, b: dict) -> str:
    def side(c, tag):
        lines = [f"[{tag}] 「{c['title']}」 共{c['n_items']}条，{c['first_seen']} 至 {c['last_seen']}",
                 f"    锚点：{c['anchor']}　现状：{c['status_line']}　人：{'、'.join(p for p in c['people'] if p) or '无'}"]
        lines += [f"    - {s['when']} {s['source_app']}：{s['text']}" for s in c["snippets"]]
        return "\n".join(lines)
    return "下面两个事件是不是同一件事（应该合并）？\n" + side(a, "甲") + "\n" + side(b, "乙") + "\n只回答 same 或 different。"


def summarize(rows: list[dict]) -> dict:
    out = {}
    for split in ("train", "val"):
        r = [x for x in rows if x["split"] == split]
        out[split] = {"n": len(r), "labels": dict(Counter(x["label"] for x in r)),
                      "kinds": dict(Counter(f"{x['label']}/{x['kind']}" for x in r))}
    return out


def main() -> int:
    data = Path(sys.argv[1])
    units = [json.loads(l) for l in open(data / "units.jsonl", encoding="utf-8")]
    emb = np.load(data / "embeddings.npy")
    index = json.loads((data / "embed_index.json").read_text())["index"]
    prow, pstats = person_pairs()
    erow, estats = event_pairs(units, emb, index)
    for name, rows in (("person_merge", prow), ("event_merge", erow)):
        for split in ("train", "val"):
            with open(data / f"{name}_{split}.jsonl", "w", encoding="utf-8") as fh:
                for r in rows:
                    if r["split"] == split:
                        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    summ = {"person_merge": {"sources": pstats, **summarize(prow)}, "event_merge": {"sources": estats, **summarize(erow)}}
    (data / "pairs_summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summ, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
