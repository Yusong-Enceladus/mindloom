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


def salvage(candidate: Optional[dict], errors: list[str], validate) -> Optional[dict]:
    """An output rejected twice only for over-long gists: clip them and re-validate. Else None."""
    if not candidate or not errors or not all("gist is wider" in e for e in errors):
        return None
    fixed = dict(candidate, segments=[dict(seg, gist=clip_gist(seg.get("gist", ""))) for seg in candidate.get("segments") or []])
    return fixed if not validate(fixed) else None


def build_data(kind: str, source_app: str, started_at: str, units: list[dict], fmt: str = "") -> dict:
    """The <data> the skill reads (the organizer and eval/run_skill_evals.py build it the same way)."""
    return {"item": {"kind": kind, "source_app": source_app, "started_at": started_at, "format": fmt},
            "units": [{"u": u["u"], "speaker": u["speaker"], "text": u["text"]} if u["speaker"]
                      else {"u": u["u"], "text": u["text"]} for u in units],
            "unit_count": len(units)}


def _substantial(parts: list[dict], units: list[dict]) -> bool:
    n_units = sum(p["b"] - p["a"] + 1 for p in parts)
    chars = sum(units[p["b"]]["end"] - units[p["a"]]["start"] for p in parts)
    return n_units >= SUBSTANTIAL_UNITS or chars >= SUBSTANTIAL_CHARS


def segments_from_output(output: dict, units: list[dict]) -> list[dict]:
    """Model ranges -> [{seg_id, start, end, gist, matter, no_matter}] in text order. Adjacent segments of
    the same matter are joined. matter 0 marks a stretch that is no matter at all (greetings, chit-chat,
    a notice read out): it becomes a segment with no_matter=True that the organizer leaves unfiled without
    an assign call. The item is split only when at least two distinct matters are substantial (>= 2 units
    or >= 12 characters each); otherwise it is filed whole (returns [])."""
    index = {u["u"]: i for i, u in enumerate(units)}
    raw = []
    for seg in output.get("segments") or []:
        a, b = index.get(seg.get("from")), index.get(seg.get("to"))
        if a is None or b is None or b < a:
            continue
        raw.append({"a": a, "b": b, "matter": int(seg.get("matter") or 0), "gist": str(seg.get("gist") or "").strip()})
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
    if sum(1 for parts in by_matter.values() if _substantial(parts, units)) < 2:
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
