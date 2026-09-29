#!/usr/bin/env python3
"""Decision units for System One datasets (synthetic scenarios only).

A decision unit is what the live organizer decides a placement for: a whole item, or one matter of a
multi-matter item (the gold matter/event segments stand in for item-split's output). For each unit this
writes the text the organizer would see and embed (source app name + text, 2000 chars), the persons the
live system knows (voice speakers; chat speakers parsed from the text by organizer.persons), its time,
and the gold labels (kept apart from everything the live system sees).

Screenshots: the live system reads them with image-read. Where the partial scale runs recorded a
screenshot-read for the item (state.readings, mapped by the run ledger), that reading is used; otherwise
the generator's own rendering of the image content (chat lines / card fields) stands in for a reading.

  python3 eval/system_one/build_units.py --out DIR
Writes DIR/units.jsonl (one row per unit, in stream order per scenario) and DIR/units_summary.json.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "spark"))
from organizer.persons import speakers_in_text  # noqa: E402

# Run-specific inputs (the scale runs' ledgers and partial state dumps) live outside the repo:
# S1_WORK_DIR/{startup,pm}-ledger.jsonl and S1_WORK_DIR/{startup,pm}-state.json.
PARTIAL = Path(os.environ.get("S1_WORK_DIR", str(HERE / "work")))
LEDGERS = {"scale-startup": PARTIAL / "startup-ledger.jsonl", "scale-pm": PARTIAL / "pm-ledger.jsonl"}
STATES = {"scale-startup": PARTIAL / "startup-state.json", "scale-pm": PARTIAL / "pm-state.json"}

# stream -> (scenario path, split role). TEST streams are replayed for evaluation only.
STREAMS = {
    "scale-startup": (ROOT / "eval/scenarios/scale-startup/scenario.json", "train"),
    "scale-pm": (ROOT / "eval/scenarios/scale-pm/scenario.json", "train"),
    "dev-week-v1": (ROOT / "eval/scenarios/dev-week-v1/scenario.json", "train"),
    "split-dev": (ROOT / "eval/scenarios/split-dev/scenario.json", "train"),
    "scale-lab": (ROOT / "eval/scenarios/scale-lab/scenario.json", "test"),
    "holdout-week-v2": (ROOT / "eval/scenarios/holdout-week-v2/scenario.json", "test"),
}
EMBED_TEXT_CHARS = 2000


def excerpt(text: str, limit: int) -> str:
    text = (text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def render_image(spec: dict, caption: str = "") -> str:
    lines = []
    if spec.get("chat_title"):
        lines.append(spec["chat_title"])
    if spec.get("title"):
        lines.append(spec["title"])
    for m in spec.get("messages") or []:
        who = m.get("sender") or ""
        tm = f"[{m['time']}] " if m.get("time") else ""
        lines.append(f"{tm}{who}：{m.get('text', '')}")
    for f in spec.get("fields") or []:
        lines.append(f"{f.get('label', '')}：{f.get('value', '')}")
    for k in ("body", "text", "lines"):
        v = spec.get(k)
        if isinstance(v, str):
            lines.append(v)
        elif isinstance(v, list):
            lines.extend(str(x) for x in v)
    if caption:
        lines.append(caption)
    return "\n".join(x for x in lines if x)


def load_readings(stream: str) -> dict[str, str]:
    if stream not in STATES or not STATES[stream].exists():
        return {}
    id2ref = {}
    for line in open(LEDGERS[stream], encoding="utf-8"):
        j = json.loads(line)
        if "id" in j:
            id2ref[j["id"].lower()] = j["ref"]
    st = json.loads(STATES[stream].read_text(encoding="utf-8"))
    out = {}
    for iid, r in (st.get("readings") or {}).items():
        ref = id2ref.get(iid.lower())
        if ref and r.get("text"):
            out[ref] = r["text"]
    return out


def item_text(item: dict, people: dict, readings: dict) -> tuple[str, str]:
    """(text the organizer sees, where it came from)."""
    kind = item["kind"]
    if kind in ("meeting_online", "meeting_offline", "imported_media") and item.get("segments"):
        lines = []
        for s in item["segments"]:
            p = people.get(s["person_id"], {})
            v = p.get("voice") or {}
            lab = v.get("user_label") or p.get("display_name") or "?"
            lines.append(f"{lab}：{s['text']}")
        return "\n".join(lines), "meeting_segments"
    if kind == "image":
        if item.get("ref") in readings:
            return readings[item["ref"]], "screenshot_read"
        if item.get("reading"):
            return item["reading"], "generator_reading"
        if item.get("ground_truth_text"):
            return item["ground_truth_text"], "generator_reading"
        return render_image(item.get("image") or {}, item.get("text") or ""), "generator_render"
    if kind == "document" and item.get("filename"):
        return f"{item['filename']}\n\n{item['text']}", "text"
    return item.get("text") or "", "text"


def seg_groups(item: dict) -> list[tuple[str, list[str]]]:
    """[(event_id, [quotes])] in order of first appearance, from matter/event segments or spans."""
    segs = item.get("matter_segments") or item.get("event_segments") or item.get("event_spans") or []
    order: list[str] = []
    quotes: dict[str, list[str]] = {}
    text = item.get("text") or ""
    for s in sorted(segs, key=lambda s: (text.find(s["quote"]) if text.find(s["quote"]) >= 0 else 10 ** 9)):
        ev = s["event_id"]
        if ev not in quotes:
            order.append(ev)
            quotes[ev] = []
        if s["quote"] not in quotes[ev]:
            quotes[ev].append(s["quote"])
    return [(ev, quotes[ev]) for ev in order]


def build(stream: str, path: Path, role: str) -> list[dict]:
    sc = json.loads(path.read_text(encoding="utf-8"))
    if sc.get("synthetic") is not True:
        raise SystemExit(f"{path}: not synthetic")
    people = {p["person_id"]: p for p in sc["people"]}
    owner = sc["owner_person_id"]
    owner_names = set(people[owner].get("aliases") or []) | {people[owner]["display_name"], "我"}
    readings = load_readings(stream)
    items = sorted(enumerate(sc["items"]), key=lambda x: (datetime.fromisoformat(x[1]["t"]).timestamp(), x[0]))
    units = []
    for order, (_, it) in enumerate(items):
        ts = datetime.fromisoformat(it["t"]).timestamp()
        text, text_src = item_text(it, people, readings)
        gold = list(it.get("events") or [])
        voice = []
        if it["kind"] in ("meeting_online", "meeting_offline", "imported_media"):
            for s in it.get("segments") or []:
                if s["person_id"] != owner and s["person_id"] not in voice:
                    voice.append(s["person_id"])
        base = {"stream": stream, "role": role, "ref": it.get("ref"), "item_id": it["item_id"], "kind": it["kind"],
                "source_app": it["source_app"], "t": it["t"], "ts": ts, "item_order": order,
                "text_source": text_src, "voice_persons": voice,
                "voice_labels": [((people[p].get("voice") or {}).get("user_label") or people[p]["display_name"])
                                 for p in voice],
                "tags": it.get("tags") or []}
        groups = seg_groups(it) if len(gold) > 1 else []
        if groups:
            for j, (ev, qs) in enumerate(groups):
                utext = " … ".join(qs)
                units.append(dict(base, unit_id=f"{it['item_id']}#{j}", segment_index=j, n_segments=len(groups),
                                  ts=ts + 0.001 * (j + 1), text=utext, gold=[ev]))
            missing = [e for e in gold if e not in {g for g, _ in groups}]
            if missing:
                base["uncovered_gold"] = missing
        else:
            units.append(dict(base, unit_id=it["item_id"], segment_index=None, n_segments=1, text=text, gold=gold))
    for u in units:
        spk = [n for n in speakers_in_text(u["text"]) if n not in owner_names]
        u["text_speakers"] = spk
        u["embed_text"] = f"{u['source_app']}\n{excerpt(u['text'], EMBED_TEXT_CHARS)}"
        u["event_kinds"] = {e["event_id"]: e.get("kind", "main") for e in sc["events"] if e["event_id"] in u["gold"]}
    return units


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    allu = []
    summ = {}
    for stream, (path, role) in STREAMS.items():
        us = build(stream, path, role)
        allu += us
        summ[stream] = {"role": role, "units": len(us), "items": len({u["item_id"] for u in us}),
                        "segment_units": sum(1 for u in us if u["segment_index"] is not None),
                        "noise_units": sum(1 for u in us if not u["gold"]),
                        "multi_label_whole_units": sum(1 for u in us if len(u["gold"]) > 1),
                        "text_source": dict(Counter(u["text_source"] for u in us))}
    with open(out / "units.jsonl", "w", encoding="utf-8") as fh:
        for u in allu:
            fh.write(json.dumps(u, ensure_ascii=False) + "\n")
    (out / "units_summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summ, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
