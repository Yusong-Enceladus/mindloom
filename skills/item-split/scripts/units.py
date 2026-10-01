#!/usr/bin/env python3
"""Units, pre-filter and offsets for item-split (deterministic, stdlib only).

The model never writes character offsets. The organizer cuts the item text into numbered units
(U1, U2, ...): one per transcript turn, otherwise one per sentence (short sentences joined to the one
before). The model answers in unit ranges; `segments_from_output` turns them into character offsets
into the item text, so transcript segments are always turn-aligned.

prefilter(text, n_units, kind) is the cheap gate before the model call: only items long enough to hold
more than one matter are sent to the skill.

CLI:  python units.py < item.txt     prints the units as JSON.
"""

from __future__ import annotations

import json
import re
import sys
from typing import Optional

MIN_CHARS = 90           # shorter items are never split (a three-matter dictation can be ~100 characters)
MIN_TRANSCRIPT_CHARS = 90
MIN_UNITS = 3            # ... nor items with fewer units (sentences, chat lines or transcript turns)
MAX_UNITS = 80           # longer items are grouped into at most this many units
UNIT_TEXT_CHARS = 160    # each unit as the model sees it
SHORT_SENTENCE = 8       # sentences shorter than this join the previous unit
SPLIT_KINDS = {"dictation", "meeting_online", "meeting_offline", "imported_media", "text", "document"}
# A matter counts toward a split only when it has at least this many units or this many characters: a
# trivial aside ("记得多喝水") next to one real matter is not a second matter. A to-do list item is often a
# single 13-30 character sentence, so the character bar stays low (split-dev: a 30-character bar left 6
# real multi-matter dictations whole).
SUBSTANTIAL_UNITS = 2
SUBSTANTIAL_CHARS = 12
# ... and it is not a passing mention: at least this share of the item's matter text, or at least this many
# characters on its own (a long meeting's short second topic still counts). At scale (1.3.0 on the lab and
# pm weeks) 19-23% of one-matter items were still split, mostly for a sentence about another project; this
# rule halves that for a small loss of real second matters.
SUBSTANTIAL_SHARE = 0.15
SUBSTANTIAL_MIN_CHARS = 150

_SENT_END = re.compile(r"[^。！？!?；;\n]*(?:[。！？!?；;]+[”’」』)]?|\n|$)")


def display_width(text: str) -> float:
    """CJK and full-width characters count 1, ASCII counts 0.5."""
    return sum(0.5 if ord(ch) < 0x2E80 else 1.0 for ch in text or "")


def _sentences(text: str) -> list[tuple[int, int]]:
    spans = []
    for m in _SENT_END.finditer(text):
        s, e = m.start(), m.end()
        while s < e and text[s].isspace():
            s += 1
        while e > s and text[e - 1].isspace():
            e -= 1
        if e > s:
            spans.append((s, e))
    merged: list[list[int]] = []
    for s, e in spans:
        if merged and (e - s) < SHORT_SENTENCE and "\n" not in text[merged[-1][1]:s]:
            merged[-1][1] = e
        else:
            merged.append([s, e])
    return [(s, e) for s, e in merged]


def _group(spans: list[dict], limit: int) -> list[dict]:
    if len(spans) <= limit:
        return spans
    size = -(-len(spans) // limit)
    out = []
    for i in range(0, len(spans), size):
        chunk = spans[i:i + size]
        speakers = [c.get("speaker") for c in chunk if c.get("speaker")]
        bodies = [c["body"] for c in chunk if c.get("body")]
        out.append({"start": chunk[0]["start"], "end": chunk[-1]["end"],
                    "speaker": "、".join(dict.fromkeys(speakers)) if speakers else "",
                    **({"body": "\n".join(bodies)} if bodies else {})})
    return out


def build_units(text: str, turns: Optional[list[dict]] = None, max_units: int = MAX_UNITS) -> list[dict]:
    """[{u: "U1", start, end, speaker, text}] covering the item text in order."""
    if turns:
        # A turn's unit text is what was said (the "Name(00:01:02):" header is its speaker field).
        spans = [{"start": t["start"], "end": t["end"], "speaker": t.get("speaker") or "", "body": t["text"]}
                 for t in turns]
    else:
        spans = [{"start": s, "end": e, "speaker": ""} for s, e in _sentences(text or "")]
    grouped = _group(spans, max_units)
    units = []
    for n, sp in enumerate(grouped, 1):
        body = (sp.get("body") or text[sp["start"]:sp["end"]] or "").strip()
        view = body if len(body) <= UNIT_TEXT_CHARS else body[:UNIT_TEXT_CHARS - 1] + "…"
        units.append({"u": f"U{n}", "start": sp["start"], "end": sp["end"], "speaker": sp["speaker"], "text": view})
    return units


def prefilter(text: Optional[str], n_units: int, kind: str, transcript: bool = False) -> bool:
    """Cheap gate: long enough and with enough units (turns) to hold more than one matter."""
    need = MIN_TRANSCRIPT_CHARS if transcript else MIN_CHARS
    return kind in SPLIT_KINDS and len((text or "").strip()) >= need and n_units >= MIN_UNITS


GIST_MAX_WIDTH = 20


def clip_gist(gist: str, limit: float = GIST_MAX_WIDTH) -> str:
    """Keep the leading clauses that fit in `limit` display columns (a too-long gist is the most common
    reason an otherwise good split fails validation twice)."""
    gist = (gist or "").strip()
    if display_width(gist) <= limit:
        return gist
    out = ""
    for clause in re.split(r"(?<=[，、；,;])", gist):
        if display_width(out + clause) > limit:
            break
        out += clause
    if not out:
        for ch in gist:
            if display_width(out + ch) > limit:
                break
            out += ch
    return out.rstrip("，、；,; ")


def _repairable(error: str) -> bool:
    return (error.startswith("known") or "gist is wider" in error or "has no segment" in error
            or "overlaps or is out of order" in error)


def salvage(candidate: Optional[dict], errors: list[str], validate) -> Optional[dict]:
    """An output rejected twice only for repairable reasons is repaired deterministically and re-validated:
    over-long gists are clipped, known ids that were not shown are dropped (the whole list when its length is
    wrong), segments are put in text order with overlapping ones dropped (the first kept), and matters that
    got no segment are dropped (the others renumbered). Anything else: None (the item is organized whole)."""
    if not candidate or not errors or not all(_repairable(e) for e in errors):
        return None
    segs = [dict(seg, gist=clip_gist(seg.get("gist", ""))) for seg in candidate.get("segments") or []]
    order = {u: i for i, u in enumerate(_unit_order(segs))}
    segs.sort(key=lambda g: (order.get(g.get("from"), 0), order.get(g.get("to"), 0)))
    kept, last = [], -1
    for g in segs:
        a, b = order.get(g.get("from"), -1), order.get(g.get("to"), -1)
        if a <= last or b < a:
            continue
        kept.append(g)
        last = b
    matters = list(candidate.get("matters") or [])
    known = list(candidate.get("known") or [])
    bad = {k for e in errors for k in re.findall(r"known\[\d+\] (E\d+)", e)}
    known = [k if k not in bad else "" for k in known]
    if known and len(known) != len(matters):
        known = []
    used = sorted({g["matter"] for g in kept if isinstance(g.get("matter"), int) and g["matter"] > 0})
    renum = {m: n for n, m in enumerate(used, 1)}
    fixed = {"matters": [matters[m - 1] for m in used if m - 1 < len(matters)],
             "segments": [dict(g, matter=renum.get(g.get("matter"), 0)) for g in kept]}
    if known:
        fixed["known"] = [known[m - 1] for m in used if m - 1 < len(known)]
    if not fixed["segments"]:
        return None
    return fixed if not validate(fixed) else None


def _unit_order(segs: list[dict]) -> list[str]:
    """Unit ids in numeric order (U2 before U10)."""
    ids = {g.get(k) for g in segs for k in ("from", "to") if g.get(k)}
    return sorted(ids, key=lambda u: int(re.sub(r"\D", "", u) or 0))


KNOWN_MAX = 24          # the user's current matters shown beside the item (the largest live events)
KNOWN_MIN_ITEMS = 3


def build_data(kind: str, source_app: str, started_at: str, units: list[dict], fmt: str = "",
               known: Optional[list[dict]] = None) -> dict:
    """The <data> the skill reads (the organizer and eval/run_skill_evals.py build it the same way).
    `known`: the user's current matters [{"id": "E12", "title": ...}] (known_matters); omitted when empty."""
    data = {"item": {"kind": kind, "source_app": source_app, "started_at": started_at, "format": fmt},
            "units": [{"u": u["u"], "speaker": u["speaker"], "text": u["text"]} if u["speaker"]
                      else {"u": u["u"], "text": u["text"]} for u in units],
            "unit_count": len(units)}
    if known:
        data["known_matters"] = [{"id": k["id"], "title": k["title"]} for k in known]
    return data


def known_matters(events: list[dict], limit: int = KNOWN_MAX, min_items: int = KNOWN_MIN_ITEMS) -> list[dict]:
    """The directory item-split sees: events [{"id", "title", "n", "order"}] with at least `min_items` items,
    the `limit` largest (ties: created first), shown in creation order."""
    big = [e for e in events if e["n"] >= min_items and (e.get("title") or "").strip()]
    big.sort(key=lambda e: (-e["n"], e["order"]))
    return [{"id": e["id"], "title": e["title"].strip()} for e in sorted(big[:limit], key=lambda e: e["order"])]


def _chars(parts: list[dict], units: list[dict]) -> int:
    return sum(units[p["b"]]["end"] - units[p["a"]]["start"] for p in parts)


def _substantial(parts: list[dict], units: list[dict], total: int) -> bool:
    n_units = sum(p["b"] - p["a"] + 1 for p in parts)
    chars = _chars(parts, units)
    if not (n_units >= SUBSTANTIAL_UNITS or chars >= SUBSTANTIAL_CHARS):
        return False
    return chars >= SUBSTANTIAL_MIN_CHARS or chars >= SUBSTANTIAL_SHARE * max(1, total)


def joined_matters(output: dict) -> dict[int, int]:
    """matter number -> the number it is organized under. Matters the model placed under the same known
    matter (`known`, parallel to `matters`) are one matter: the first of them keeps its number."""
    known = list(output.get("known") or [])
    first: dict[str, int] = {}
    out: dict[int, int] = {}
    for n in range(1, len(output.get("matters") or []) + 1):
        k = str(known[n - 1]).strip() if n - 1 < len(known) else ""
        if k:
            out[n] = first.setdefault(k, n)
        else:
            out[n] = n
    return out


def segments_from_output(output: dict, units: list[dict]) -> list[dict]:
    """Model ranges -> [{seg_id, start, end, gist, matter, no_matter}] in text order. Matters that belong to
    the same known matter (joined_matters) are one matter. Adjacent segments of the same matter are joined.
    matter 0 marks a stretch that is no matter at all (greetings, chit-chat, a notice read out): it becomes
    a segment with no_matter=True that the organizer leaves unfiled without an assign call. The item is split
    only when at least two distinct matters are substantial (>= 2 units or >= 12 characters, and >= 15% of
    the matter text or >= 150 characters); otherwise it is filed whole (returns [])."""
    index = {u["u"]: i for i, u in enumerate(units)}
    join = joined_matters(output)
    raw = []
    for seg in output.get("segments") or []:
        a, b = index.get(seg.get("from")), index.get(seg.get("to"))
        if a is None or b is None or b < a:
            continue
        m = int(seg.get("matter") or 0)
        raw.append({"a": a, "b": b, "matter": join.get(m, m), "gist": str(seg.get("gist") or "").strip()})
    raw.sort(key=lambda s: (s["a"], s["b"]))
    joined: list[dict] = []
    for s in raw:
        if joined and s["a"] <= joined[-1]["b"]:
            continue  # overlapping range: the validator rejects it; keep the first if it slips through
        if joined and s["matter"] == joined[-1]["matter"] and s["a"] == joined[-1]["b"] + 1:
            joined[-1]["b"] = s["b"]
            continue
        joined.append(dict(s))
    by_matter: dict[int, list[dict]] = {}
    for s in joined:
        if s["matter"] > 0:
            by_matter.setdefault(s["matter"], []).append(s)
    total = sum(_chars(parts, units) for parts in by_matter.values())
    if sum(1 for parts in by_matter.values() if _substantial(parts, units, total)) < 2:
        return []
    return [{"seg_id": f"s{n}", "start": units[s["a"]]["start"], "end": units[s["b"]]["end"],
             "gist": s["gist"], "matter": s["matter"], "no_matter": s["matter"] == 0}
            for n, s in enumerate(joined, 1)]


def main() -> int:
    text = sys.stdin.read()
    json.dump(build_units(text), sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
