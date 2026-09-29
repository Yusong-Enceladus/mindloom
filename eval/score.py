#!/usr/bin/env python3
"""Score an organizer's /v1/state snapshots against a gold scenario.json (stdlib only).

Usage:
  python3 score.py --gold scenarios/dev-week-v1/scenario.json --snapshots runs/<run>/snapshots [--md out.md] [--json out.json]
  python3 score.py --gold scenarios/dev-week-v1/scenario.json --state final_state.json
  python3 score.py --gold scenarios/dev-week-v1/scenario.json --validate

--snapshots is a directory holding <checkpoint_id>.json files (what run_eval.py writes).
The final snapshot is --state if given, else the snapshot of the last checkpoint.
See README.md for the metric definitions.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import sys
import unicodedata
from datetime import date, datetime
from pathlib import Path

_BRIEF_VALIDATE = Path(__file__).resolve().parents[1] / "skills" / "event-brief" / "scripts" / "validate.py"
_brief = None


def brief_rules():
    """The event-brief validator module (stdlib only): completion claims, evidence and relative-date rules."""
    global _brief
    if _brief is None:
        spec = importlib.util.spec_from_file_location("event_brief_validate_for_score", _BRIEF_VALIDATE)
        _brief = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_brief)  # type: ignore[union-attr]
    return _brief

# ------------------------------------------------------------------------------------------
# Text normalisation (numbers and dates) used for status-line fact matching
# ------------------------------------------------------------------------------------------

_CN_DIGITS = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_CN_SMALL_UNITS = {"十": 10, "百": 100, "千": 1000}
_CN_BIG_UNITS = {"万": 10_000, "亿": 100_000_000}
_CN_NUM_CHARS = "零〇一二两三四五六七八九十百千万亿"
# A bare Chinese digit run without units is converted only before one of these measure words,
# so 一起/一定/周三 stay words while 三年/两杯/九月 become 3年/2杯/9月.
_MEASURE = "杯个次天周年月日号点元块张人位份斤家台层米分岁页章"
_SPAN_RE = re.compile(r"(?:\d+(?:\.\d+)?|[%s])+" % _CN_NUM_CHARS)


class _NotANumber(ValueError):
    pass


def _parse_number_span(span: str) -> float:
    """Parse a mixed Arabic/Chinese numeral span such as 1.5万, 一万五, 3万2, 二十八, 两千八."""
    tokens = re.findall(r"\d+(?:\.\d+)?|.", span)
    if not any(t in _CN_SMALL_UNITS or t in _CN_BIG_UNITS for t in tokens):
        # Positional digits only (e.g. 二〇二六): read them left to right.
        digits = []
        for t in tokens:
            if t in _CN_DIGITS:
                digits.append(str(_CN_DIGITS[t]))
            elif t.replace(".", "", 1).isdigit():
                digits.append(t)
            else:
                raise _NotANumber(span)
        return float("".join(digits))
    total = 0.0
    section = 0.0
    number = None  # pending digit value
    last_unit = 0
    zero_seen = False
    prev_was_digit = False
    for t in tokens:
        if t in _CN_DIGITS or t[0].isdigit():
            value = float(t) if t[0].isdigit() else float(_CN_DIGITS[t])
            if t in ("零", "〇"):
                zero_seen = True
                prev_was_digit = False
                continue
            if prev_was_digit:
                raise _NotANumber(span)  # 两三千 (an approximate range): leave as text
            number = value
            prev_was_digit = True
        elif t in _CN_SMALL_UNITS:
            unit = _CN_SMALL_UNITS[t]
            if number is None:
                if unit != 10:
                    raise _NotANumber(span)
                number = 1.0  # 十二 = 12
            section += number * unit
            number = None
            last_unit = unit
            zero_seen = False
            prev_was_digit = False
        elif t in _CN_BIG_UNITS:
            unit = _CN_BIG_UNITS[t]
            section += number or 0.0
            if section == 0:
                raise _NotANumber(span)
            total += section * unit
            section = 0.0
            number = None
            last_unit = unit
            zero_seen = False
            prev_was_digit = False
        else:
            raise _NotANumber(span)
    if number is not None:
        if last_unit >= 100 and not zero_seen:
            number *= last_unit / 10  # colloquial tail: 一万五 = 15000, 三千二 = 3200
        section += number
    return total + section


def _fmt_number(value: float) -> str:
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return ("%.6f" % value).rstrip("0").rstrip(".")


def _convert_numbers(text: str) -> str:
    out = []
    pos = 0
    for m in _SPAN_RE.finditer(text):
        span = m.group(0)
        start, end = m.start(), m.end()
        # Leading big/small units other than 十 are words (万一, 千万别): keep them as text.
        while span and span[0] in "百千万亿":
            start += 1
            span = span[1:]
        if not span or not any(ch in _CN_NUM_CHARS for ch in span):
            continue  # pure Arabic: nothing to do
        has_unit = any(ch in "十百千万亿" for ch in span)
        nxt = text[end] if end < len(text) else ""
        prev = text[start - 1] if start > 0 else ""
        if not has_unit and not (nxt and nxt in _MEASURE):
            continue
        if not has_unit and len(span) == 1 and prev in ("周", "期", "拜"):
            continue  # weekday names (周六日, 星期三) stay words
        try:
            value = _parse_number_span(span)
        except _NotANumber:
            continue
        out.append(text[pos:start])
        out.append(_fmt_number(value))
        pos = end
    out.append(text[pos:])
    return "".join(out)


_WEEKDAY_RE = re.compile(r"(?:星期|礼拜|周)([一二三四五六日天1-7])")
_WEEKDAY_MAP = {"一": "一", "二": "二", "三": "三", "四": "四", "五": "五", "六": "六", "日": "日", "天": "日",
                "1": "一", "2": "二", "3": "三", "4": "四", "5": "五", "6": "六", "7": "日"}


def normalize_text(text: str) -> str:
    """Canonical form for fact matching: 1.5万/一万五/15,000 -> 15000; 9/28, 9月28号, 九月二十八日 -> 9月28日."""
    s = unicodedata.normalize("NFKC", text or "").lower()
    s = re.sub(r"(?<=\d),(?=\d{3})", "", s)          # 15,000 -> 15000
    s = re.sub(r"\s+", "", s)
    s = _WEEKDAY_RE.sub(lambda m: "周" + _WEEKDAY_MAP[m.group(1)], s)
    s = re.sub(r"(\d+(?:\.\d+)?)w(?![a-z])", lambda m: _fmt_number(float(m.group(1)) * 10_000), s)
    s = re.sub(r"(\d+(?:\.\d+)?)k(?![a-z])", lambda m: _fmt_number(float(m.group(1)) * 1_000), s)
    s = _convert_numbers(s)
    s = re.sub(r"(\d+)号", r"\1日", s)
    s = re.sub(r"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)",
               lambda m: "%d年%d月%d日" % (int(m.group(1)), int(m.group(2)), int(m.group(3))), s)
    s = re.sub(r"(?<![\d.])(\d{1,2})/(\d{1,2})(?![\d/])",
               lambda m: ("%d月%d日" % (int(m.group(1)), int(m.group(2))))
               if 1 <= int(m.group(1)) <= 12 and 1 <= int(m.group(2)) <= 31 else m.group(0), s)
    s = re.sub(r"(?<!\d)0(\d)(?=[月日])", r"\1", s)     # 09月05日 -> 9月5日
    s = re.sub(r"(?<=\d)块钱?", "元", s)
    s = re.sub(r"[¥￥](\d+(?:\.\d+)?)", r"\1元", s)
    s = re.sub(r"rmb(?=\d)", "", s)
    return s


def _occurs(key: str, line: str) -> bool:
    if not key:
        return False
    start = 0
    while True:
        idx = line.find(key, start)
        if idx < 0:
            return False
        before = line[idx - 1] if idx > 0 else ""
        after = line[idx + len(key)] if idx + len(key) < len(line) else ""
        ok_before = not (key[0].isdigit() and (before.isdigit() or before == "."))
        ok_after = not (key[-1].isdigit() and (after.isdigit() or after == "."))
        if ok_before and ok_after:
            return True
        start = idx + 1


def fact_matches(keys: list[str], text: str) -> bool:
    """True if every key (with '|' alternatives) occurs in the normalised text."""
    line = normalize_text(text)
    for key in keys:
        alternatives = [normalize_text(a) for a in key.split("|")]
        if not any(_occurs(a, line) for a in alternatives if a):
            return False
    return True


# ------------------------------------------------------------------------------------------
# Gold scenario
# ------------------------------------------------------------------------------------------

def _nid(value) -> str:
    return str(value).strip().lower()


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value)


class Gold:
    def __init__(self, scenario: dict):
        self.raw = scenario
        self.scenario_id = scenario.get("scenario_id", "?")
        self.owner = scenario.get("owner_person_id")
        self.people = {p["person_id"]: p for p in scenario.get("people", [])}
        self.owner_ids = {pid for pid, p in self.people.items() if p.get("is_owner")} | ({self.owner} if self.owner else set())
        self.events = {e["event_id"]: e for e in scenario.get("events", [])}
        indexed = list(enumerate(scenario.get("items", [])))
        indexed.sort(key=lambda pair: (parse_time(pair[1]["t"]), pair[0]))
        self.items = [it for _, it in indexed]
        self.order = {_nid(it["item_id"]): i for i, it in enumerate(self.items)}
        self.by_id = {_nid(it["item_id"]): it for it in self.items}
        noise_events = {eid for eid, e in self.events.items() if e.get("kind") == "noise"}
        self.item_events = {_nid(it["item_id"]): set(it.get("events", [])) - noise_events for it in self.items}
        self.item_persons = {_nid(it["item_id"]): set(it.get("persons", [])) for it in self.items}
        self.facts = {f["fact_id"]: f for f in scenario.get("facts", [])}
        self.checkpoints = scenario.get("checkpoints", [])
        self.noise_items = {_nid(it["item_id"]) for it in self.items if not self.item_events[_nid(it["item_id"])]}
        # Segment-level truth: item -> [(event_id, start, end)] of each quote in the sent text.
        self.item_text = {_nid(it["item_id"]): api_text(it) for it in self.items}
        self.item_segments: dict[str, list[tuple[str, int, int]]] = {}
        for it in self.items:
            text = self.item_text[_nid(it["item_id"])]
            spans = []
            for seg in gold_segments(it):
                if seg["event_id"] is None or seg["event_id"] in noise_events:  # an aside or noise
                    continue
                at = text.find(seg["quote"])
                if at >= 0:
                    spans.append((seg["event_id"], at, at + len(seg["quote"])))
            if spans:
                self.item_segments[_nid(it["item_id"])] = spans

    def universe(self, upto: int | None = None) -> list[str]:
        ids = [_nid(it["item_id"]) for it in self.items]
        return ids if upto is None else ids[: upto + 1]

    def item_order(self, item_id: str) -> int:
        return self.order[_nid(item_id)]

    def fact_valid_order(self, fact_id: str) -> int:
        return self.item_order(self.facts[fact_id]["valid_from"])

    def sources_of(self, person_id: str) -> set:
        return {it["source_app"] for it in self.items if person_id in it.get("persons", [])}


def voice_segments(item: dict) -> list[dict]:
    """A meeting's speaker segments (start_ms/end_ms/person_id/text)."""
    return [s for s in item.get("segments") or [] if "quote" not in s]


def gold_segments(item: dict) -> list[dict]:
    """Optional segment-level truth for an item covering several matters: [{event_id, quote}], given in
    `segments` next to (never mixed with) voice segments, or as `event_segments` (scale-lab calls it
    `event_spans`, scale-pm `matter_segments`). event_id null marks an unrelated aside."""
    extra = (item.get("event_segments") or []) + (item.get("event_spans") or []) + (item.get("matter_segments") or [])
    return [s for s in (item.get("segments") or []) + extra if "quote" in s]


def api_text(item: dict) -> str:
    """The item text exactly as eval/tools/to_items.py sends it (segment offsets refer to it)."""
    if item.get("kind") == "document" and item.get("filename"):
        return f"{item['filename']}\n\n{item.get('text') or ''}"
    return item.get("text") or ""


def item_content(item: dict) -> str:
    parts = []
    if item.get("filename"):
        parts.append(item["filename"])
    if item.get("text"):
        parts.append(item["text"])
    if item.get("file_text"):  # gold reading of an attached file (eval/files-multiformat scenarios)
        parts.append(item["file_text"])
    for seg in voice_segments(item):
        parts.append(seg["text"])
    parts.extend(image_text(item))
    return "\n".join(parts)


def image_text(item: dict) -> list[str]:
    """The gold text drawn in an item's screenshot: its ground_truth_text if given (scale-startup), else the
    chat messages plus, for other styles, image.ocr_text (scale-lab) or the drawn fields (scale-pm)."""
    if item.get("ground_truth_text"):
        return [item["ground_truth_text"]]
    image = item.get("image") or {}
    parts = ["%s：%s" % (msg["sender"], msg["text"]) for msg in image.get("messages", [])]
    if image.get("messages"):
        return parts
    if image.get("ocr_text"):
        return parts + [image["ocr_text"]]
    for key in ("title", "subtitle", "note", "body", "footer"):
        if image.get(key) and image.get("style", "generic_im") != "generic_im":
            parts.append(str(image[key]))
    if image.get("columns"):
        parts.append(" | ".join(map(str, image["columns"])))
    for k, v in image.get("kpis") or []:
        parts.append(f"{k} {v}")
    for row in image.get("rows") or []:
        parts.append(" | ".join(map(str, row)))
    for fld in image.get("fields") or []:
        parts.append("%s：%s" % (fld.get("label", ""), fld.get("value", "")) if isinstance(fld, dict) else "：".join(map(str, fld)))
    for block in image.get("blocks") or []:
        parts.append("%s：%s" % (block.get("label", ""), block.get("text", "")))
    for key in ("annotations", "paragraphs", "lines"):
        parts.extend(map(str, image.get(key) or []))
    return parts


# What each image style must carry (any one of the listed fields); see eval/schema/scenario.schema.json.
_IMAGE_NEEDS = {"generic_im": ("messages",), "generic_table": ("rows",), "generic_terminal": ("lines",),
                "generic_card": ("fields",), "generic_design": ("blocks",), "generic_doc": ("paragraphs",),
                "board": ("title",), "doc": ("title",), "table": ("title",), "whiteboard": ("title",), "photo": ("title",)}

_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_KINDS = {"dictation", "meeting_online", "meeting_offline", "imported_media", "text", "image", "document"}


def validate_scenario(scenario: dict) -> tuple[list[str], list[str]]:
    """Consistency checks beyond the JSON Schema. Returns (errors, warnings)."""
    errors: list[str] = []
    warnings: list[str] = []
    if scenario.get("synthetic") is not True:
        errors.append("scenario must set synthetic: true")
    people = {p.get("person_id"): p for p in scenario.get("people", [])}
    owners = [pid for pid, p in people.items() if p.get("is_owner")]
    if len(owners) != 1 or scenario.get("owner_person_id") not in owners:
        errors.append("exactly one person must be is_owner and match owner_person_id")
    voice_ids = [p["voice"]["mac_person_id"] for p in people.values() if p.get("voice")]
    if len(voice_ids) != len(set(v.lower() for v in voice_ids)):
        errors.append("duplicate voice.mac_person_id")
    events = {e.get("event_id"): e for e in scenario.get("events", [])}
    for eid, e in events.items():
        if e.get("kind") not in ("main", "decoy", "noise"):
            errors.append(f"event {eid}: bad kind")
        if e.get("kind") == "decoy":
            if e.get("difficulty") not in ("hard", "easy"):
                errors.append(f"decoy {eid}: difficulty must be hard|easy")
            if events.get(e.get("decoy_of"), {}).get("kind") != "main":
                errors.append(f"decoy {eid}: decoy_of must name a main event")
    seen = set()
    for it in scenario.get("items", []):
        iid = str(it.get("item_id", ""))
        tag = it.get("ref") or iid
        if not _UUID_RE.match(iid.lower()):
            errors.append(f"item {tag}: item_id is not a UUID")
        if iid.lower() in seen:
            errors.append(f"item {tag}: duplicate item_id")
        seen.add(iid.lower())
        try:
            t = parse_time(it["t"])
            if t.utcoffset() is None or t.utcoffset().total_seconds() != 8 * 3600:
                errors.append(f"item {tag}: t must carry +08:00")
        except (KeyError, ValueError):
            errors.append(f"item {tag}: bad t")
        kind = it.get("kind")
        if kind not in _KINDS:
            errors.append(f"item {tag}: kind {kind!r} is not an API item kind")
        if kind in ("meeting_online", "meeting_offline") and not voice_segments(it):
            errors.append(f"item {tag}: meetings need segments")
        image = it.get("image") or {}
        style = image.get("style") or "generic_im"
        if kind == "image" and not it.get("file"):
            need = _IMAGE_NEEDS.get(style)
            if need is None:
                errors.append(f"item {tag}: unknown image style {style!r}")
            elif not any(image.get(k) for k in need):
                errors.append(f"item {tag}: {style} image needs image.{' or image.'.join(need)}")
        if kind in ("dictation", "text", "document") and not it.get("text") and not (kind == "document" and it.get("file")):
            errors.append(f"item {tag}: {kind} needs text")
        if it.get("file") and not (it.get("filename") and it.get("mime_type")):
            errors.append(f"item {tag}: a file item needs filename and mime_type")
        for seg in gold_segments(it):
            if seg.get("event_id") is not None and seg.get("event_id") not in it.get("events", []):
                errors.append(f"item {tag}: gold segment event {seg.get('event_id')} is not one of the item's events")
            # A screenshot's quotes are checked against its drawn text or gold reading; the scorer only uses quotes found in
            # the sent text, so an image's segment truth is not scored at segment level.
            where = api_text(it) + ("\n" + "\n".join(image_text(it) + [it.get("reading") or ""]) if kind == "image" else "")
            if not seg.get("quote") or seg["quote"] not in where:
                errors.append(f"item {tag}: gold segment quote not found in the item text")
        for seg in voice_segments(it):
            if seg.get("end_ms", 0) <= seg.get("start_ms", 0):
                errors.append(f"item {tag}: segment end_ms must exceed start_ms")
            speaker = people.get(seg.get("person_id"))
            if not speaker:
                errors.append(f"item {tag}: unknown segment speaker {seg.get('person_id')}")
            elif not speaker.get("voice"):
                errors.append(f"item {tag}: speaker {seg.get('person_id')} has no voice")
            elif seg.get("person_id") not in it.get("persons", []):
                errors.append(f"item {tag}: speaker {seg.get('person_id')} missing from persons")
        for pid in it.get("persons", []):
            if pid not in people:
                errors.append(f"item {tag}: unknown person {pid}")
        for eid in it.get("events", []):
            if eid not in events:
                errors.append(f"item {tag}: unknown event {eid}")
    if errors:
        return errors, warnings
    gold = Gold(scenario)
    for eid, e in events.items():
        if e.get("kind") != "noise" and not any(eid in s for s in gold.item_events.values()):
            warnings.append(f"event {eid} has no items")
    facts = gold.facts
    for fid, f in facts.items():
        if f.get("event_id") not in events:
            errors.append(f"fact {fid}: unknown event")
            continue
        if _nid(f.get("valid_from")) not in gold.order:
            errors.append(f"fact {fid}: valid_from is not an item")
            continue
        evidence = gold.by_id[_nid(f["valid_from"])]
        if f["event_id"] not in evidence.get("events", []):
            errors.append(f"fact {fid}: valid_from item is not labelled with {f['event_id']}")
        if not fact_matches(f["keys"], f["text"]):
            errors.append(f"fact {fid}: its own text does not satisfy its keys")
        if not fact_matches(f["keys"], item_content(evidence)):
            warnings.append(f"fact {fid}: keys not found in its valid_from item")
        nxt = f.get("superseded_by")
        if nxt:
            if nxt not in facts:
                errors.append(f"fact {fid}: superseded_by {nxt} does not exist")
            elif facts[nxt]["event_id"] != f["event_id"]:
                errors.append(f"fact {fid}: superseded_by is in another event")
            elif gold.fact_valid_order(nxt) <= gold.fact_valid_order(fid):
                errors.append(f"fact {fid}: successor must become valid later")
    for cp in gold.checkpoints:
        cid = cp.get("checkpoint_id")
        if _nid(cp.get("after_item_id")) not in gold.order:
            errors.append(f"checkpoint {cid}: after_item_id is not an item")
            continue
        at = gold.item_order(cp["after_item_id"])
        for eid, fids in cp.get("expected", {}).items():
            if eid not in events:
                errors.append(f"checkpoint {cid}: unknown event {eid}")
            for fid in fids:
                f = facts.get(fid)
                if not f:
                    errors.append(f"checkpoint {cid}: unknown fact {fid}")
                    continue
                if f["event_id"] != eid:
                    errors.append(f"checkpoint {cid}: fact {fid} belongs to {f['event_id']}")
                if gold.fact_valid_order(fid) > at:
                    errors.append(f"checkpoint {cid}: fact {fid} is not valid yet")
                nxt = f.get("superseded_by")
                if nxt and nxt in facts and gold.fact_valid_order(nxt) <= at:
                    errors.append(f"checkpoint {cid}: fact {fid} is already superseded")
        home = cp.get("home")
        if home is not None:
            grades = home.get("grades") or {}
            present = {g for i in gold.universe(at) for g in gold.item_events[i]}
            for eid, g in grades.items():
                if eid not in events:
                    errors.append(f"checkpoint {cid}: home grades unknown event {eid}")
                elif eid not in present:
                    errors.append(f"checkpoint {cid}: home grades {eid}, which has no items yet")
                if not isinstance(g, int) or not 0 <= g <= 3:
                    errors.append(f"checkpoint {cid}: home grade of {eid} must be an integer 0..3")
            for eid in sorted(present - set(grades)):
                errors.append(f"checkpoint {cid}: home grades miss {eid}")
    for fid, f in facts.items():
        if "state" in f and f["state"] not in ("planned", "in_progress", "done", "cancelled", "info"):
            errors.append(f"fact {fid}: bad state {f['state']!r}")
    return errors, warnings


# ------------------------------------------------------------------------------------------
# Snapshot normalisation (tolerant of field-name variants)
# ------------------------------------------------------------------------------------------

def _ids(value, keys=("item_id", "id", "person_id", "event_id")) -> list[str]:
    out = []
    for v in value or []:
        if isinstance(v, dict):
            for k in keys:
                if v.get(k):
                    out.append(_nid(v[k]))
                    break
        elif v is not None:
            out.append(_nid(v))
    return out


def _first(d: dict, *names, default=None):
    for n in names:
        if n in d and d[n] is not None:
            return d[n]
    return default


def normalize_state(raw: dict) -> dict:
    """Accepts /v1/state variants. Returns events, item_events, item_persons (or None), persons, questions."""
    if isinstance(raw, dict) and isinstance(raw.get("state"), dict):
        raw = raw["state"]
    raw = raw or {}
    events = []
    item_events: dict[str, set] = {}
    item_segments: dict[str, list] = {}
    item_persons: dict[str, set] = {}
    have_item_persons = False
    for e in raw.get("events") or []:
        if e.get("deleted") or e.get("merged_into"):
            continue
        eid = _nid(_first(e, "event_id", "id", default=""))
        status = _first(e, "status_line", "status", "now", "progress", default="") or ""
        facts = _first(e, "status_facts", default=[]) or []
        item_ids = _ids(_first(e, "item_ids", "items", "members", default=[]))
        person_ids = _ids(_first(e, "person_ids", "persons", "people", default=[]))
        events.append({"event_id": eid, "title": e.get("title") or "", "status_line": status,
                       "status_facts": [f if isinstance(f, str) else json.dumps(f, ensure_ascii=False) for f in facts],
                       "facts_raw": [f for f in facts if isinstance(f, dict)],
                       "item_ids": item_ids, "person_ids": person_ids,
                       "importance": e.get("importance"), "importance_reason": e.get("importance_reason") or "",
                       "pinned": bool(e.get("pinned")), "feature_less": bool(e.get("feature_less")),
                       "updated_at": e.get("updated_at") or ""})
        for iid in item_ids:
            item_events.setdefault(iid, set()).add(eid)
        for seg in e.get("segments") or []:
            if isinstance(seg, dict) and seg.get("item_id") is not None:
                item_segments.setdefault(_nid(seg["item_id"]), []).append(
                    (eid, int(seg.get("start") or 0), int(seg.get("end") or 0)))
    live = {e["event_id"] for e in events}
    for it in raw.get("items") or []:
        iid = _nid(_first(it, "item_id", "id", default=""))
        evs = _first(it, "event_ids", "events", default=None)
        if evs is not None:
            for eid in _ids(evs):
                if eid in live or not events:
                    item_events.setdefault(iid, set()).add(eid)
        pids = _first(it, "person_ids", "persons", default=None)
        if pids is not None:
            have_item_persons = True
            item_persons.setdefault(iid, set()).update(_ids(pids))
    persons = []
    for p in _first(raw, "persons", "people", default=[]) or []:
        if p.get("merged_into"):
            continue
        pid = _nid(_first(p, "person_id", "id", default=""))
        its = _first(p, "item_ids", "items", default=None)
        if its is not None:
            have_item_persons = True
            for iid in _ids(its):
                item_persons.setdefault(iid, set()).add(pid)
        persons.append({"person_id": pid, "display_name": p.get("display_name") or p.get("name") or ""})
    for link in raw.get("item_persons") or []:
        have_item_persons = True
        item_persons.setdefault(_nid(link.get("item_id")), set()).add(_nid(link.get("person_id")))
    questions = []
    for q in raw.get("questions") or []:
        subjects = _ids(_first(q, "subject_ids", "ids", default=None) or [q.get("a"), q.get("b")])
        prov = q.get("provisional")
        if isinstance(prov, str):
            try:
                prov = json.loads(prov)
            except ValueError:
                prov = None
        b_items = q.get("b_items_at_ask")
        if isinstance(b_items, str):
            try:
                b_items = json.loads(b_items)
            except ValueError:
                b_items = None
        questions.append({"kind": q.get("kind", ""), "status": q.get("status", "open"), "subjects": subjects,
                          "day_key": q.get("day_key") or (q.get("created_at") or "")[:10] or None,
                          "provisional": prov, "b_items": [_nid(i) for i in b_items] if b_items else None})
    asked_total = _first(raw, "questions_asked_total", default=None)
    unfiled = [_nid(u.get("item_id") if isinstance(u, dict) else u) for u in raw.get("unfiled") or []]
    return {"events": events, "item_events": item_events, "item_segments": item_segments,
            "item_persons": item_persons if have_item_persons else None,
            "persons": persons, "questions": questions, "questions_asked_total": asked_total,
            "unfiled": unfiled, "assign_log": raw.get("assign_log") or []}


# ------------------------------------------------------------------------------------------
# Metrics
# ------------------------------------------------------------------------------------------

def _safe_div(a: float, b: float) -> float | None:
    return a / b if b else None


def _f1(p, r) -> float:
    p = p or 0.0
    r = r or 0.0
    return 2 * p * r / (p + r) if p + r > 0 else 0.0


def bcubed_extended(gold_map: dict, pred_map: dict, universe: list[str]) -> dict:
    """Extended B-cubed for overlapping clusters (Amigó et al., 2009).

    Precision averages over items with >=1 predicted event, recall over items with >=1 gold event;
    items with nothing assigned are skipped for precision (abstention) but still count as misses for
    recall. A noise item placed in an event scores 0 precision against every co-member.
    """
    g = {i: gold_map.get(i, set()) for i in universe}
    p = {i: pred_map.get(i, set()) for i in universe}
    precisions, recalls = [], []
    for e in universe:
        if p[e]:
            vals = []
            for e2 in universe:
                shared_pred = len(p[e] & p[e2])
                if shared_pred:
                    vals.append(min(shared_pred, len(g[e] & g[e2])) / shared_pred)
            precisions.append(sum(vals) / len(vals))
        if g[e]:
            vals = []
            for e2 in universe:
                shared_gold = len(g[e] & g[e2])
                if shared_gold:
                    vals.append(min(len(p[e] & p[e2]), shared_gold) / shared_gold)
            recalls.append(sum(vals) / len(vals))
    prec = sum(precisions) / len(precisions) if precisions else 0.0
    rec = sum(recalls) / len(recalls) if recalls else 0.0
    return {"precision": prec, "recall": rec, "f1": _f1(prec, rec)}


def hungarian_max(weights: list[list[float]]) -> list[tuple[int, int]]:
    """Maximum-weight one-to-one assignment for a rectangular matrix (rows x cols)."""
    n_rows = len(weights)
    n_cols = len(weights[0]) if n_rows else 0
    if n_rows == 0 or n_cols == 0:
        return []
    transposed = n_rows > n_cols
    if transposed:
        weights = [list(col) for col in zip(*weights)]
        n_rows, n_cols = n_cols, n_rows
    big = max(max(row) for row in weights)
    cost = [[big - w for w in row] for row in weights]
    inf = float("inf")
    u = [0.0] * (n_rows + 1)
    v = [0.0] * (n_cols + 1)
    match = [0] * (n_cols + 1)  # match[col] = row (1-based)
    way = [0] * (n_cols + 1)
    for i in range(1, n_rows + 1):
        match[0] = i
        j0 = 0
        minv = [inf] * (n_cols + 1)
        used = [False] * (n_cols + 1)
        while True:
            used[j0] = True
            i0 = match[j0]
            delta = inf
            j1 = 0
            for j in range(1, n_cols + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j] = cur
                        way[j] = j0
                    if minv[j] < delta:
                        delta = minv[j]
                        j1 = j
            for j in range(n_cols + 1):
                if used[j]:
                    u[match[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if match[j0] == 0:
                break
        while True:
            j1 = way[j0]
            match[j0] = match[j1]
            j0 = j1
            if j0 == 0:
                break
    pairs = [(match[j] - 1, j - 1) for j in range(1, n_cols + 1) if match[j]]
    if transposed:
        pairs = [(c, r) for r, c in pairs]
    return sorted(pairs)


def match_clusters(gold_map: dict, pred_map: dict, universe: list[str]) -> dict:
    """One-to-one gold->pred mapping maximising item overlap. Returns {pred_id: gold_id}."""
    gold_ids = sorted({g for i in universe for g in gold_map.get(i, set())})
    pred_ids = sorted({p for i in universe for p in pred_map.get(i, set())})
    if not gold_ids or not pred_ids:
        return {}
    gi = {g: k for k, g in enumerate(gold_ids)}
    pi = {p: k for k, p in enumerate(pred_ids)}
    w = [[0.0] * len(pred_ids) for _ in gold_ids]
    for i in universe:
        for g in gold_map.get(i, set()):
            for p in pred_map.get(i, set()):
                w[gi[g]][pi[p]] += 1
    mapping = {}
    for r, c in hungarian_max(w):
        if w[r][c] > 0:
            mapping[pred_ids[c]] = gold_ids[r]
    return mapping


def link_prf(gold_map: dict, pred_map: dict, universe: list[str], mapping: dict) -> dict:
    tp = n_pred = n_gold = 0
    for i in universe:
        gold = gold_map.get(i, set())
        pred = pred_map.get(i, set())
        n_gold += len(gold)
        n_pred += len(pred)
        tp += sum(1 for p in pred if mapping.get(p) in gold)
    prec = _safe_div(tp, n_pred) or 0.0
    rec = _safe_div(tp, n_gold) or 0.0
    return {"precision": prec, "recall": rec, "f1": _f1(prec, rec), "tp": tp, "n_pred": n_pred, "n_gold": n_gold}


def segment_link_prf(gold: Gold, state: dict, universe: list[str], mapping: dict) -> dict | None:
    """Segment-level Link P/R/F1 (items may belong to several events, `segments` [{event_id, quote}]).

    Units: a predicted unit is (item, event, span): one per `events[].segments` entry, or the whole item
    when the item is linked without segments. A gold unit is one quote of an item with segment truth, or
    (item, event) for items without it. Events are compared through the item-level 1:1 mapping.
    - A gold quote is found when the predicted spans of this item in the mapped event together cover at
      least half of it (a part cut into two pieces that both went to the right event still counts).
    - A predicted unit is correct when at least half of its span lies inside this item's quotes for the
      gold event its event maps to (an unsplit multi-matter item filed whole is mostly other matters: wrong).
    Items without segment truth are scored per (item, event) exactly like item-level Link F1.
    None when the scenario has no segment truth."""
    if not gold.item_segments:
        return None
    pred_segs = state.get("item_segments") or {}
    tp_pred = n_pred = tp_gold = n_gold = 0

    def inside(span: tuple[int, int], spans: list[tuple[int, int]]) -> int:
        covered, (a, b) = 0, span
        for x, y in sorted(spans):  # quotes and segments of one item do not overlap each other
            covered += max(0, min(b, y) - max(a, x))
        return covered

    for i in universe:
        length = len(gold.item_text.get(i, ""))
        segs: dict[str, list] = {}
        for eid, a, b in pred_segs.get(i, []):
            segs.setdefault(eid, []).append((a, b))
        units = [(eid, span) for eid in sorted(state["item_events"].get(i, set()))
                 for span in (segs.get(eid) or [(0, length)])]
        truth = gold.item_segments.get(i)
        n_pred += len(units)
        if truth is None:
            g_events = gold.item_events.get(i, set())
            tp_pred += sum(1 for eid, _ in units if mapping.get(eid) in g_events)
            n_gold += len(g_events)
            tp_gold += sum(1 for g in g_events if any(mapping.get(eid) == g for eid, _ in units))
            continue
        quotes: dict[str, list] = {}
        for g, a, b in truth:
            quotes.setdefault(g, []).append((a, b))
        for eid, span in units:
            g = mapping.get(eid)
            if g in quotes and inside(span, quotes[g]) >= 0.5 * max(1, span[1] - span[0]):
                tp_pred += 1
        n_gold += len(truth)
        for g, a, b in truth:
            spans = [span for eid, span in units if mapping.get(eid) == g]
            if inside((a, b), spans) >= 0.5 * max(1, b - a):
                tp_gold += 1
    prec = _safe_div(tp_pred, n_pred) or 0.0
    rec = _safe_div(tp_gold, n_gold) or 0.0
    return {"precision": prec, "recall": rec, "f1": _f1(prec, rec), "tp_pred": tp_pred, "n_pred": n_pred,
            "tp_gold": tp_gold, "n_gold": n_gold,
            "split_items_pred": sum(1 for i in universe if pred_segs.get(i)),
            "split_items_gold": sum(1 for i in universe if len(gold.item_segments.get(i, [])) >= 2)}


def decoy_leakage(gold: Gold, pred_map: dict, universe: list[str]) -> dict:
    """Pairwise co-assignment rate between a decoy's items and its look-alike main event's items.

    Items gold-labelled with both events are excluded. 0 = perfectly separated, 1 = fully merged.
    """
    per = {}
    for eid, e in gold.events.items():
        if e.get("kind") != "decoy":
            continue
        target = e.get("decoy_of")
        d_items = [i for i in universe if eid in gold.item_events[i] and target not in gold.item_events[i]]
        m_items = [i for i in universe if target in gold.item_events[i] and eid not in gold.item_events[i]]
        pairs = leaked = 0
        for d in d_items:
            for m in m_items:
                pairs += 1
                if pred_map.get(d, set()) & pred_map.get(m, set()):
                    leaked += 1
        per[eid] = {"difficulty": e.get("difficulty"), "decoy_of": target, "pairs": pairs,
                    "leakage": _safe_div(leaked, pairs), "decoy_items": len(d_items)}
    out = {}
    for level in ("hard", "easy"):
        vals = [v["leakage"] for v in per.values() if v["difficulty"] == level and v["leakage"] is not None]
        out[level] = sum(vals) / len(vals) if vals else None
    return {"hard": out["hard"], "easy": out["easy"], "per_decoy": per}


def noise_abstention(gold: Gold, pred_map: dict, universe: list[str]) -> dict:
    """Where noise went, and what else was left unfiled.

    unfiled        noise item in no event (the goal)
    singleton      noise item in an event that holds only noise (a clutter card, but harmless to matters)
    in_real_event  noise item inside an event that also holds real items (the harmful case)
    false_unfiled  real items left in no event; unfiled_precision = share of unfiled items that are noise
    """
    noise = [i for i in universe if not gold.item_events[i]]
    members: dict[str, list] = {}
    for i in universe:
        for p in pred_map.get(i, set()):
            members.setdefault(p, []).append(i)
    abstained = [i for i in noise if not pred_map.get(i)]
    singleton = [i for i in noise if pred_map.get(i) and all(
        all(not gold.item_events[m] for m in members[p]) for p in pred_map[i])]
    in_real = [i for i in noise if any(any(gold.item_events[m] for m in members[p]) for p in pred_map.get(i, set()))]
    real_unfiled = [i for i in universe if gold.item_events[i] and not pred_map.get(i)]
    unfiled_total = len(abstained) + len(real_unfiled)
    return {"noise_items": len(noise), "abstained": len(abstained), "rate": _safe_div(len(abstained), len(noise)),
            "singleton_rate": _safe_div(len(singleton), len(noise)), "in_real_event_rate": _safe_div(len(in_real), len(noise)),
            "false_unfiled": len(real_unfiled), "unfiled_precision": _safe_div(len(abstained), unfiled_total),
            "false_unfiled_items": real_unfiled}


def question_metrics(gold: Gold, state: dict, universe: list[str]) -> dict:
    qs = state["questions"]
    by_kind: dict[str, int] = {}
    for q in qs:
        by_kind[q["kind"]] = by_kind.get(q["kind"], 0) + 1
    # For each predicted event / person, its majority gold label, so we can tell whether "yes" is the true answer.
    def majority(pred_to_items: dict, gold_of) -> dict:
        out = {}
        for pid, items in pred_to_items.items():
            counts: dict[str, int] = {}
            for i in items:
                for g in gold_of(i):
                    counts[g] = counts.get(g, 0) + 1
            if counts:
                out[pid] = max(sorted(counts), key=lambda g: counts[g])
        return out
    ev_items: dict[str, list] = {}
    for i in universe:
        for p in state["item_events"].get(i, set()):
            ev_items.setdefault(p, []).append(i)
    ev_major = majority(ev_items, lambda i: gold.item_events[i])
    per_items: dict[str, list] = {}
    for i, ps in (state["item_persons"] or {}).items():
        if i in gold.item_persons:
            for p in ps:
                per_items.setdefault(p, []).append(i)
    per_major = majority(per_items, lambda i: gold.item_persons[i])
    in_universe = set(universe)

    def event_side(subject: str, b_items=None):
        # The organizer asks same_event(item, event): an item subject is judged by its own gold labels.
        # The event side is judged by its members when the question was asked (b_items_at_ask), so a
        # target merged or deleted later stays resolvable; without that record, by its final majority.
        if b_items:
            labels = majority({"b": [i for i in b_items if i in in_universe]}, lambda i: gold.item_events[i])
            return {labels["b"]} if "b" in labels else None
        if subject in ev_major:
            return {ev_major[subject]}
        if subject in in_universe:
            return gold.item_events[subject]
        return None

    resolvable = yes = merged = 0
    same_event = [q for q in qs if q["kind"] == "same_event"]
    useful = judged_useful = 0
    per_day: dict[str, int] = {}
    for q in same_event:
        if q.get("day_key"):
            per_day[q["day_key"]] = per_day.get(q["day_key"], 0) + 1
    for q in qs:
        if len(q["subjects"]) != 2:
            continue
        a, b = q["subjects"]
        if q["kind"] == "same_event":
            ga, gb = event_side(a), event_side(b, q.get("b_items"))
            if ga is None or gb is None:
                merged += 1
                continue
            resolvable += 1
            truth = bool(ga & gb)
            yes += truth
            prov = (q.get("provisional") or {}).get("action")
            if prov:
                judged_useful += 1
                # Useful = the placement made while waiting for the answer is wrong per gold, so an answer fixes it.
                # (a merge question is useful when the two events are in fact one matter)
                useful += (prov in ("new", "none", "merge") and truth) or (prov in ("stay", "attach") and not truth)
        elif q["kind"] == "same_person" and a in per_major and b in per_major:
            resolvable += 1
            yes += per_major[a] == per_major[b]
    total = state.get("questions_asked_total")
    suppressed = sum(1 for r in state.get("assign_log") or [] if str(r.get("reason", "")).startswith("ask_budget"))
    return {"count": len(qs), "asked_total": total, "by_kind": by_kind,
            "per_100_items": round(100.0 * (total if isinstance(total, int) else len(qs)) / max(1, len(universe)), 2),
            "resolvable": resolvable, "true_yes_rate": _safe_div(yes, resolvable),
            "unresolvable_merged": merged,
            "asks_total": len(same_event),
            "asks_per_100_items": round(100.0 * len(same_event) / max(1, len(universe)), 2),
            "max_asks_per_day": max(per_day.values()) if per_day else 0,
            "ask_useful_rate": _safe_div(useful, judged_useful), "asks_suppressed": suppressed}


# ------------------------------------------------------------------------------------------
# Cards: plan-vs-done, unsupported completions, relative dates, UI fit
# ------------------------------------------------------------------------------------------

_CLAUSE_SPLIT = re.compile(r"[，,。；;！!？?\n、]")
# Strict item-side evidence words per claimed verb family (stricter than the brief validator, which also
# has the model's quote to check).
_EVIDENCE_WORDS = {
    "签": ("签了", "已签", "签好", "签完"), "送": ("送到了", "送达", "到货", "收到", "签收", "到了"),
    "验收": ("验收通过", "验收完", "验收了"), "完成": ("完成", "完工", "做完", "做了", "搞定", "全部通过", "修好"),
    "开工": ("开工了", "开始"), "退": ("退回", "退款", "退了"), "上线": ("上线了", "已上线"),
    "安装": ("装好", "装完", "安装了"), "修": ("修好", "修完"), "印": ("印好",), "下单": ("下单",), "付": ("已付", "付了", "转了"),
}


def _clauses(text: str) -> list[str]:
    return [c for c in _CLAUSE_SPLIT.split(text or "") if c.strip()]


def _item_text(gold: Gold, iid: str) -> str:
    it = gold.by_id.get(_nid(iid))
    return item_content(it) if it else ""


def _supported_claim(gold: Gold, family: str, member_ids: list[str], claim_clause: str) -> bool:
    rules = brief_rules()
    caps = [parse_time(gold.by_id[i]["t"]).date() for i in member_ids if i in gold.by_id]
    if caps:
        latest = max(caps)
        for m in re.finditer(r"(\d{1,2})月(\d{1,2})[日号]", normalize_text(claim_clause)):
            try:
                if date(latest.year, int(m.group(1)), int(m.group(2))) > latest:
                    return False  # "已于9月22日完成" written from evidence captured before 9/22
            except ValueError:
                pass
    for iid in member_ids:
        for clause in _clauses(_item_text(gold, iid)):
            if any(w in clause for w in _EVIDENCE_WORDS.get(family, ())) and rules.DONE_MARKER.search(clause) \
                    and not rules.FUTURE_MARKER.search(clause):
                return True
    return False


def card_audit(gold: Gold, state: dict, universe: list[str]) -> dict:
    """Unsupported completion claims and relative dates in stored cards (status_line and status_facts)."""
    rules = brief_rules()
    in_u = set(universe)
    unsupported, relative, details = 0, 0, []
    ungrounded, dates_detail = 0, []
    for e in state["events"]:
        members = [i for i in e["item_ids"] if i in in_u]
        if not members:
            continue
        line = e["status_line"] or ""
        for clause in _clauses(line):
            fams = rules.claims(clause)
            if any(not _supported_claim(gold, f, members, clause) for f in fams):
                unsupported += 1
                details.append({"event_id": e["event_id"], "where": "status_line", "text": line})
                break
        items = {i: {"text": _item_text(gold, i), "captured_at": gold.by_id[i]["t"]} for i in members if i in gold.by_id}
        for f in e["facts_raw"]:
            if not f.get("state"):
                continue  # cards written before fact states existed: only the line is audited
            f2 = dict(f, item_ids=[_nid(i) for i in f.get("item_ids") or []])
            if rules.check_fact_evidence(f2, items):
                unsupported += 1
                details.append({"event_id": e["event_id"], "where": "status_fact", "text": f.get("text", "")})
        texts = [e["title"], line] + [str(f.get("text", "")) for f in e["facts_raw"]]
        if any(rules._relative_errors("card", t) for t in texts if t):
            relative += 1
        # Added metric (2026-09-28): dates in the status line / facts that the cited items do not give.
        for where, text in ungrounded_card_dates(rules, e, items):
            ungrounded += 1
            dates_detail.append({"event_id": e["event_id"], "where": where, "text": text})
    return {"unsupported_completion": unsupported, "relative_date_in_card": relative, "details": details,
            "ungrounded_card_dates": ungrounded, "ungrounded_details": dates_detail}


def ungrounded_card_dates(rules, e: dict, items: dict) -> list[tuple[str, str]]:
    """Every M月D日 / N日 in a stored status line (grounded by any member item) or fact text, and every fact
    `date` field, that is not a date written in / resolved from the cited items or their capture day (a
    range the source gave, e.g. 下周, grounds only its ends said as a range). One entry per mention."""
    if not items:
        return []
    out = []
    year = max(parse_time(v["captured_at"]).year for v in items.values())
    exact, ranges = rules.grounding(items)
    line = e["status_line"] or ""
    out += [("status_line", f"{line} [{m['said']}]") for m in rules.ungrounded_dates(line, exact, ranges, year)]
    for f in e["facts_raw"]:
        ids = [_nid(i) for i in f.get("item_ids") or [] if _nid(i) in items]
        fx, fr = rules.grounding(items, ids)
        text = str(f.get("text", ""))
        out += [("status_fact", f"{text} [{m['said']}]") for m in rules.ungrounded_dates(text, fx, fr, year)]
        if not rules.fact_date_ok(f, fx, fr):
            out.append(("fact_date", f"{text} [date {f.get('date')}]"))
    return out


HOME_LINE_WIDTH = 24  # added 2026-09-28: what fits one Home card line (a CJK char 1, an ASCII char 0.5)


def display_width(text: str) -> float:
    """Card display width, defined here (not taken from the skill) so a skill change cannot move the metric."""
    return sum(0.5 if unicodedata.east_asian_width(ch) in ("Na", "H", "N") else 1.0 for ch in (text or "").strip())


def _repeats_own_date(fact: dict) -> bool:
    try:
        d = date.fromisoformat(str(fact.get("date") or ""))
    except ValueError:
        return False
    return any((int(m.group(1)), int(m.group(2))) == (d.month, d.day)
               for m in re.finditer(r"(\d{1,2})月(\d{1,2})[日号]", normalize_text(str(fact.get("text", "")))))


def ui_fit(state: dict, title_max: int = 20, status_max: int = 54) -> dict:
    rules = brief_rules()
    live = [e for e in state["events"] if e["item_ids"]]
    long_titles = [e["title"] for e in live if len(e["title"]) > title_max]
    long_lines = [e["status_line"] for e in live if len(e["status_line"]) > status_max]
    multi = [e["status_line"] for e in live if e["status_line"] and rules._SENTENCE_END.findall(e["status_line"].strip()[:-1])]
    rel = [e["status_line"] for e in live if rules.RELATIVE.search(e["status_line"] or "")]
    # Added metrics (the ones above keep their frozen definitions): Home-card width and facts whose text
    # repeats the date already in their date field.
    widths = [display_width(e["status_line"]) for e in live if e["status_line"]]
    repeated = sum(1 for e in live for f in e["facts_raw"] if _repeats_own_date(f))
    return {"cards": len(live), "titles_over": len(long_titles), "status_over": len(long_lines),
            "multi_sentence": len(multi), "relative_date_lines": len(rel), "examples": (long_titles + long_lines)[:3],
            "status_over_width": sum(1 for w in widths if w > HOME_LINE_WIDTH), "status_widths": widths,
            "fact_date_repeated": repeated,
            "facts_total": sum(len(e["facts_raw"]) for e in live)}


# ------------------------------------------------------------------------------------------
# Home ranking against checkpoint grades
# ------------------------------------------------------------------------------------------

def _dcg(gains: list[float]) -> float:
    return sum(g / math.log2(i + 2) for i, g in enumerate(gains))


def home_metrics(gold: Gold, cp: dict, state: dict, universe: list[str], mapping: dict, k: int = 5) -> dict | None:
    """Order cards exactly like the Mac (pinned, importance, updated_at) and compare with graded gold.

    A mapped card takes the max grade of gold events holding >= 1/3 of its items (lenient for merged
    cards); a noise-only card is grade 0 (clutter); an unmapped fragment of a real event is a duplicate:
    gain 0 and left out of pairwise checks. rank_ran is False (metrics n/a) when every card still has the
    default importance 0.5 and no reason, i.e. home-rank never ran.
    """
    grades = (cp.get("home") or {}).get("grades")
    if not grades:
        return None
    in_u = set(universe)
    cards = []
    for e in state["events"]:
        members = [i for i in e["item_ids"] if i in in_u]
        if not members:
            continue
        counts: dict[str, int] = {}
        for i in members:
            for g in gold.item_events[i]:
                counts[g] = counts.get(g, 0) + 1
        if e["event_id"] in mapping:
            share = [g for g, n in counts.items() if n * 3 >= len(members)] + [mapping[e["event_id"]]]
            grade, role = max(grades.get(g, 0) for g in share), "mapped"
        elif not counts:
            grade, role = 0, "noise"
        else:
            grade, role = 0, "fragment"
        cards.append({"event_id": e["event_id"], "grade": grade, "role": role, "gold": mapping.get(e["event_id"]),
                      "importance": e["importance"] if e["importance"] is not None else 0.5,
                      "reason": e["importance_reason"], "pinned": e["pinned"], "updated_at": e["updated_at"]})
    rank_ran = any(abs(c["importance"] - 0.5) > 1e-9 or c["reason"] for c in cards)

    def order(cs, by_recency=False):
        cs = sorted(cs, key=lambda c: c["updated_at"], reverse=True)
        if by_recency:
            return cs
        cs = sorted(cs, key=lambda c: c["importance"], reverse=True)
        return sorted(cs, key=lambda c: c["pinned"], reverse=True)

    present = {g for i in universe for g in gold.item_events[i]}
    ideal = sorted((grades[g] for g in present if g in grades), reverse=True)[:k]
    idcg = _dcg([2 ** g - 1 for g in ideal])

    def ndcg(cs):
        return _dcg([(2 ** c["grade"] - 1) if c["role"] != "fragment" else 0.0 for c in cs[:k]]) / idcg if idcg else None

    ranked = order(cards)
    pairs = inverted = 0
    judged = [c for c in ranked if c["role"] != "fragment"]
    for i, hi in enumerate(judged):
        for lo in judged[i + 1:]:
            if abs(hi["grade"] - lo["grade"]) >= 2:
                pairs += 1
                inverted += lo["grade"] > hi["grade"]
    top3 = ranked[:3]
    g3 = [g for g in present if grades.get(g) == 3]
    return {"rank_ran": rank_ran,
            "ndcg5": ndcg(ranked) if rank_ran else None,
            "ndcg5_recency": ndcg(order(cards, by_recency=True)),
            "top3_precision": _safe_div(sum(c["grade"] >= 2 and c["role"] != "fragment" for c in top3), len(top3))
            if rank_ran else None,
            "g3_recall3": _safe_div(sum(any(c["gold"] == g for c in top3) for g in g3), len(g3)) if rank_ran else None,
            "gross_inversions": inverted if rank_ran else None, "gross_pairs": pairs,
            "clutter5": sum(c["role"] == "noise" for c in ranked[:k]) if rank_ran else None,
            "order": [(c["event_id"], c["gold"] or c["role"], c["grade"], c["importance"]) for c in ranked]}


# ------------------------------------------------------------------------------------------
# Decoys and new matters
# ------------------------------------------------------------------------------------------

def decoy_seed(gold: Gold, pred_map: dict, universe: list[str]) -> dict:
    """Was each decoy's first item kept away from its look-alike's items? One seed decision decides
    whether a whole decoy leaks (the wrong seed attach snowballs), so it is reported on its own."""
    per = {}
    for eid, e in gold.events.items():
        if e.get("kind") != "decoy":
            continue
        target = e.get("decoy_of")
        d_items = [i for i in universe if eid in gold.item_events[i] and target not in gold.item_events[i]]
        m_items = [i for i in universe if target in gold.item_events[i] and eid not in gold.item_events[i]]
        if not d_items:
            continue
        seed = d_items[0]
        target_events = {p for m in m_items for p in pred_map.get(m, set())}
        per[eid] = {"seed": seed, "ok": not (pred_map.get(seed, set()) & target_events)}
    return {"ok": sum(v["ok"] for v in per.values()), "total": len(per), "per_decoy": per}


def absorbed_matters(gold: Gold, pred_map: dict, universe: list[str]) -> dict:
    """Main events that are the majority of no predicted event (a new matter absorbed into another)."""
    members: dict[str, list] = {}
    for i in universe:
        for p in pred_map.get(i, set()):
            members.setdefault(p, []).append(i)
    majorities = set()
    for items in members.values():
        counts: dict[str, int] = {}
        for i in items:
            for g in gold.item_events[i]:
                counts[g] = counts.get(g, 0) + 1
        if counts:
            top = max(counts.values())
            majorities |= {g for g, n in counts.items() if n == top}
    mains = [eid for eid, e in gold.events.items() if e.get("kind") in ("main", "decoy")
             and sum(eid in gold.item_events[i] for i in universe) >= 2]
    missing = sorted(g for g in mains if g not in majorities)
    return {"missing": missing, "rate": _safe_div(len(mains) - len(missing), len(mains))}


def _norm_name(s: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", s or "")).lower()


def person_metrics(gold: Gold, state: dict, universe: list[str], ev_mapping: dict) -> dict:
    """Person linking across sources.

    Item level (preferred, needs item->person links in the snapshot): gold persons are mapped one-to-one
    to predicted persons by item overlap; accuracy = share of gold (item, person) pairs whose item carries
    the mapped predicted person. The owner is mapped but excluded from the scores. cross_source restricts
    to people who appear in >= 2 source apps. Falls back to event-level name matching otherwise.
    """
    non_owner = [pid for pid in gold.people if pid not in gold.owner_ids]
    cross = {pid for pid in non_owner if len(gold.sources_of(pid)) >= 2}
    names = {}
    for pid, p in gold.people.items():
        for n in [p.get("display_name", "")] + list(p.get("aliases") or []):
            if n:
                names.setdefault(_norm_name(n), pid)
    pred_names = {p["person_id"]: p["display_name"] for p in state["persons"]}
    if state["item_persons"] is not None:
        pred_items = {i: state["item_persons"].get(i, set()) for i in universe}
        gold_items = {i: gold.item_persons[i] for i in universe}
        mapping = match_clusters(gold_items, pred_items, universe)  # pred -> gold
        inv = {g: p for p, g in mapping.items()}
        def acc(subset):
            total = hit = 0
            for i in universe:
                for g in gold_items[i] & subset:
                    total += 1
                    hit += inv.get(g) in pred_items[i]
            return _safe_div(hit, total), total
        acc_all, n_all = acc(set(non_owner))
        acc_cross, n_cross = acc(cross)
        tp = n_pred = 0
        for i in universe:
            for p in pred_items[i]:
                g = mapping.get(p)
                if g is None or g in gold.owner_ids:
                    continue
                n_pred += 1
                tp += g in gold_items[i]
        fragments = {}
        for g in non_owner:
            clusters = {p for i in universe if g in gold_items[i] for p in pred_items[i]}
            if any(g in gold_items[i] for i in universe):
                fragments[g] = len(clusters)
        named = [g for g in non_owner if g in inv]
        name_ok = sum(1 for g in named if names.get(_norm_name(pred_names.get(inv[g], ""))) == g)
        return {"mode": "item_level", "accuracy": acc_all, "pairs": n_all,
                "accuracy_cross_source": acc_cross, "pairs_cross_source": n_cross,
                "precision_mapped": _safe_div(tp, n_pred),
                "mean_clusters_per_person": _safe_div(sum(fragments.values()), len(fragments)),
                "name_match": _safe_div(name_ok, len(named)),
                "mapping": {p: g for p, g in mapping.items()}}
    # Event-level fallback: predicted persons are matched to gold people by display name / alias.
    to_gold = {p["person_id"]: names.get(_norm_name(p["display_name"])) for p in state["persons"]}
    by_event = {e["event_id"]: e for e in state["events"]}
    total = hit = total_c = hit_c = 0
    for pred_eid, gold_eid in ev_mapping.items():
        gold_people = set()
        for i in universe:
            if gold_eid in gold.item_events[i]:
                gold_people |= gold.item_persons[i]
        gold_people -= gold.owner_ids
        pred_people = {to_gold.get(p) for p in by_event.get(pred_eid, {}).get("person_ids", [])}
        total += len(gold_people)
        hit += len(gold_people & pred_people)
        total_c += len(gold_people & cross)
        hit_c += len(gold_people & cross & pred_people)
    return {"mode": "event_level_name_match", "accuracy": _safe_div(hit, total), "pairs": total,
            "accuracy_cross_source": _safe_div(hit_c, total_c), "pairs_cross_source": total_c,
            "precision_mapped": None, "mean_clusters_per_person": None, "name_match": None}


def _stale_candidates(gold: Gold, event_id: str, at: int) -> list[tuple[str, str]]:
    """(old_fact, current_fact) pairs for facts of event_id that are superseded by checkpoint order `at`."""
    out = []
    for fid, f in gold.facts.items():
        if f["event_id"] != event_id or gold.fact_valid_order(fid) > at:
            continue
        nxt = f.get("superseded_by")
        if not nxt or gold.fact_valid_order(nxt) > at:
            continue
        cur = nxt
        while gold.facts[cur].get("superseded_by") and gold.fact_valid_order(gold.facts[cur]["superseded_by"]) <= at:
            cur = gold.facts[cur]["superseded_by"]
        out.append((fid, cur))
    return out


def status_metrics(gold: Gold, cp: dict, state: dict, ev_mapping: dict, with_status_facts: bool = False) -> dict:
    at = gold.item_order(cp["after_item_id"])
    inv = {g: p for p, g in ev_mapping.items()}
    by_event = {e["event_id"]: e for e in state["events"]}

    def line_for(gold_eid: str) -> str:
        e = by_event.get(inv.get(gold_eid, ""), None)
        if not e:
            return ""
        line = e["status_line"]
        if with_status_facts and e["status_facts"]:
            line = line + "\n" + "\n".join(e["status_facts"])
        return line

    details = {}
    expected_n = recalled_n = plan_done_n = 0
    claims = brief_rules().claims
    for gold_eid, fids in cp.get("expected", {}).items():
        line = line_for(gold_eid)
        got, as_done = [], []
        for fid in fids:
            f = gold.facts[fid]
            if not fact_matches(f["keys"], line):
                continue
            # A planned fact stated as completed ("已于9月22日按计划完成") is a violation, not a recall.
            if f.get("state") == "planned" and any(
                    fact_matches(f["keys"], c) and claims(c) for c in _clauses(line)):
                as_done.append(fid)
            else:
                got.append(fid)
        expected_n += len(fids)
        recalled_n += len(got)
        plan_done_n += len(as_done)
        details[gold_eid] = {"pred_event": inv.get(gold_eid), "status_line": line,
                             "recalled": got, "missing": [f for f in fids if f not in got]}
        if as_done:
            details[gold_eid]["plan_as_done"] = as_done
    stale_n = applicable_n = 0
    for gold_eid in gold.events:
        line = line_for(gold_eid)
        if not line.strip():
            continue
        for old, cur in _stale_candidates(gold, gold_eid, at):
            applicable_n += 1
            if fact_matches(gold.facts[old]["keys"], line) and not fact_matches(gold.facts[cur]["keys"], line):
                stale_n += 1
                details.setdefault(gold_eid, {"status_line": line}).setdefault("stale", []).append(old)
    # Independent of the organizer's guard (validate.py): a gold fact that is still `planned` at this
    # checkpoint, matched by its gold keys to a card fact the model itself labelled done / in_progress.
    state_n = 0
    for gold_eid, fids in cp.get("expected", {}).items():
        e = by_event.get(inv.get(gold_eid, ""), None)
        if not e:
            continue
        labelled_done = []
        for raw in e["status_facts"]:
            try:
                f = json.loads(raw) if isinstance(raw, str) else raw
            except ValueError:
                continue
            if isinstance(f, dict) and f.get("state") in ("done", "in_progress"):
                labelled_done.append(str(f.get("text", "")))
        hits = [fid for fid in fids if gold.facts[fid].get("state") == "planned"
                and any(fact_matches(gold.facts[fid]["keys"], t) for t in labelled_done)]
        state_n += len(hits)
        if hits:
            details.setdefault(gold_eid, {}).setdefault("plan_labelled_done", hits)
    return {"expected": expected_n, "recalled": recalled_n, "fact_recall": _safe_div(recalled_n, expected_n),
            "plan_as_done": plan_done_n, "plan_labelled_done": state_n,
            "stale_applicable": applicable_n, "stale": stale_n, "stale_rate": _safe_div(stale_n, applicable_n),
            "details": details}


def _pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, int(q * len(v)))]


def clustering_metrics(gold: Gold, state: dict, universe: list[str]) -> dict:
    pred_map = {i: set(state["item_events"].get(i, set())) for i in universe}
    gold_map = {i: gold.item_events[i] for i in universe}
    mapping = match_clusters(gold_map, pred_map, universe)
    pred_events = {p for i in universe for p in pred_map[i]}
    gold_events = {g for i in universe for g in gold_map[i]}
    return {
        "bcubed": bcubed_extended(gold_map, pred_map, universe),
        "link": link_prf(gold_map, pred_map, universe, mapping),
        "decoy_leakage": decoy_leakage(gold, pred_map, universe),
        "decoy_seed": decoy_seed(gold, pred_map, universe),
        "absorbed": absorbed_matters(gold, pred_map, universe),
        "noise_abstention": noise_abstention(gold, pred_map, universe),
        "pred_event_count": len(pred_events),
        "pred_event_count_multi_item": sum(1 for p in pred_events if sum(p in pred_map[i] for i in universe) >= 2),
        "gold_event_count": len(gold_events),
        "unassigned_items": sum(1 for i in universe if gold_map[i] and not pred_map[i]),
        "segment_link": segment_link_prf(gold, state, universe, mapping),
        "mapping": mapping,
    }


def score(scenario: dict, snapshots: dict, final_state: dict | None = None, with_status_facts: bool = False) -> dict:
    """snapshots: {checkpoint_id: raw /v1/state}. final_state defaults to the last checkpoint's snapshot."""
    gold = Gold(scenario)
    per_cp = []
    for cp in gold.checkpoints:
        raw = snapshots.get(cp["checkpoint_id"])
        if raw is None:
            per_cp.append({"checkpoint_id": cp["checkpoint_id"], "missing": True})
            continue
        state = normalize_state(raw)
        at = gold.item_order(cp["after_item_id"])
        universe = gold.universe(at)
        clus = clustering_metrics(gold, state, universe)
        stat = status_metrics(gold, cp, state, clus["mapping"], with_status_facts)
        # Added metric: the same frozen matching over the whole card (status line + status facts).
        card = status_metrics(gold, cp, state, clus["mapping"], True)
        audit = card_audit(gold, state, universe)
        home = home_metrics(gold, cp, state, universe, clus["mapping"])
        per_cp.append({"checkpoint_id": cp["checkpoint_id"], "label": cp.get("label"), "n_items": len(universe),
                       "bcubed_f1": clus["bcubed"]["f1"], "link_f1": clus["link"]["f1"],
                       "pred_event_count": clus["pred_event_count"], "gold_event_count": clus["gold_event_count"],
                       **{k: stat[k] for k in ("expected", "recalled", "fact_recall", "plan_as_done", "plan_labelled_done",
                                               "stale_applicable", "stale", "stale_rate")},
                       "unsupported_completion": audit["unsupported_completion"],
                       "relative_date_in_card": audit["relative_date_in_card"], "card_audit": audit["details"],
                       "ungrounded_card_dates": audit["ungrounded_card_dates"],
                       "ungrounded_date_details": audit["ungrounded_details"],
                       "card_recalled": card["recalled"],
                       "ui_fit": ui_fit(state), "home": home,
                       "status_details": stat["details"]})
    if final_state is None:
        last = [c for c in gold.checkpoints if c["checkpoint_id"] in snapshots]
        final_state = snapshots[last[-1]["checkpoint_id"]] if last else {}
    state = normalize_state(final_state)
    universe = gold.universe()
    clus = clustering_metrics(gold, state, universe)
    persons = person_metrics(gold, state, universe, clus["mapping"])
    questions = question_metrics(gold, state, universe)
    done = [c for c in per_cp if not c.get("missing")]
    exp = sum(c["expected"] for c in done)
    rec = sum(c["recalled"] for c in done)
    app = sum(c["stale_applicable"] for c in done)
    stl = sum(c["stale"] for c in done)
    homes = [c["home"] for c in done if c.get("home") and c["home"]["rank_ran"]]

    def mean(key, rows=homes):
        vals = [r[key] for r in rows if r.get(key) is not None]
        return sum(vals) / len(vals) if vals else None
    home_graded = [c["home"] for c in done if c.get("home")]
    noise = clus["noise_abstention"]
    summary = {
        "bcubed_precision": clus["bcubed"]["precision"],
        "bcubed_recall": clus["bcubed"]["recall"],
        "bcubed_f1": clus["bcubed"]["f1"],
        "link_precision": clus["link"]["precision"],
        "link_recall": clus["link"]["recall"],
        "link_f1": clus["link"]["f1"],
        "segment_link_precision": (clus["segment_link"] or {}).get("precision"),
        "segment_link_recall": (clus["segment_link"] or {}).get("recall"),
        "segment_link_f1": (clus["segment_link"] or {}).get("f1"),
        "split_items_pred": (clus["segment_link"] or {}).get("split_items_pred"),
        "split_items_gold": (clus["segment_link"] or {}).get("split_items_gold"),
        "hard_decoy_leakage": clus["decoy_leakage"]["hard"],
        "easy_decoy_leakage": clus["decoy_leakage"]["easy"],
        "noise_abstention": clus["noise_abstention"]["rate"],
        "noise_unfiled_rate": noise["rate"],
        "noise_singleton_rate": noise["singleton_rate"],
        "noise_in_real_event_rate": noise["in_real_event_rate"],
        "false_unfiled": noise["false_unfiled"],
        "unfiled_precision": noise["unfiled_precision"],
        "decoy_seed_ok": f"{clus['decoy_seed']['ok']}/{clus['decoy_seed']['total']}",
        "absorbed_matters": ",".join(clus["absorbed"]["missing"]) or "none",
        "pred_event_count": clus["pred_event_count"],
        "gold_event_count": clus["gold_event_count"],
        "question_count": questions["asked_total"] if isinstance(questions["asked_total"], int) else questions["count"],
        "asks_total": questions["asks_total"],
        "asks_per_100_items": questions["asks_per_100_items"],
        "max_asks_per_day": questions["max_asks_per_day"],
        "ask_useful_rate": questions["ask_useful_rate"],
        "ask_true_yes_rate": questions["true_yes_rate"],
        "asks_suppressed": questions["asks_suppressed"],
        "status_fact_recall": _safe_div(rec, exp),
        "plan_as_done": sum(c["plan_as_done"] for c in done),
        "plan_labelled_done": sum(c["plan_labelled_done"] for c in done),
        "unsupported_completion": sum(c["unsupported_completion"] for c in done),
        "relative_date_in_card": sum(c["relative_date_in_card"] for c in done),
        "stale_fact_rate": _safe_div(stl, app),
        "home_rank_ran": f"{len(homes)}/{len(home_graded)}" if home_graded else None,
        "home_ndcg5": mean("ndcg5"),
        "home_ndcg5_recency": mean("ndcg5_recency", home_graded),
        "home_top3_precision": mean("top3_precision"),
        "home_g3_recall3": mean("g3_recall3"),
        "home_gross_inversions": sum(h["gross_inversions"] for h in homes) if homes else None,
        "home_clutter5": sum(h["clutter5"] for h in homes) if homes else None,
        "ui_titles_over_20": sum(c["ui_fit"]["titles_over"] for c in done),
        "ui_status_over_54": sum(c["ui_fit"]["status_over"] for c in done),
        "card_fact_recall": _safe_div(sum(c["card_recalled"] for c in done), exp),
        "ui_status_over_24w": sum(c["ui_fit"]["status_over_width"] for c in done),
        "ui_status_width_p50": _pct([w for c in done for w in c["ui_fit"]["status_widths"]], 0.5),
        "ui_status_width_p90": _pct([w for c in done for w in c["ui_fit"]["status_widths"]], 0.9),
        "ui_status_width_max": max([w for c in done for w in c["ui_fit"]["status_widths"]], default=None),
        "ui_fact_date_repeated": sum(c["ui_fit"]["fact_date_repeated"] for c in done),
        "ungrounded_card_dates": sum(c["ungrounded_card_dates"] for c in done),
        "person_link_accuracy": persons["accuracy"],
        "person_link_accuracy_cross_source": persons["accuracy_cross_source"],
        "checkpoints_scored": len(done),
        "checkpoints_total": len(gold.checkpoints),
    }
    return {"scenario_id": gold.scenario_id, "split": scenario.get("split"), "n_items": len(universe),
            "summary": summary,
            "final": {"clustering": {k: v for k, v in clus.items() if k != "mapping"},
                      "event_mapping": clus["mapping"], "persons": persons, "questions": questions},
            "checkpoints": per_cp}


# ------------------------------------------------------------------------------------------
# Reporting
# ------------------------------------------------------------------------------------------

SUMMARY_ROWS = [
    ("bcubed_precision", "B-cubed P (extended, multi-label)"),
    ("bcubed_recall", "B-cubed R"),
    ("bcubed_f1", "B-cubed F1"),
    ("link_precision", "Link P (item→event, 1:1 mapped)"),
    ("link_recall", "Link R"),
    ("link_f1", "Link F1"),
    ("segment_link_precision", "Segment Link P (added; items with segment truth)"),
    ("segment_link_recall", "Segment Link R (added)"),
    ("segment_link_f1", "Segment Link F1 (added)"),
    ("split_items_pred", "Items filed by segments (pred)"),
    ("split_items_gold", "Items with 2+ gold segments"),
    ("hard_decoy_leakage", "Hard-decoy leakage ↓"),
    ("easy_decoy_leakage", "Easy-decoy leakage ↓"),
    ("noise_abstention", "Noise abstention (= noise unfiled rate)"),
    ("noise_singleton_rate", "Noise as its own one-item event"),
    ("noise_in_real_event_rate", "Noise inside a real event ↓"),
    ("false_unfiled", "Real items left unfiled ↓"),
    ("unfiled_precision", "Unfiled precision (share that is noise)"),
    ("decoy_seed_ok", "Decoy seed kept apart"),
    ("absorbed_matters", "Matters absorbed into another event ↓"),
    ("pred_event_count", "Predicted events"),
    ("gold_event_count", "Gold events"),
    ("question_count", "Questions asked"),
    ("asks_total", "Same-event questions"),
    ("asks_per_100_items", "Same-event questions per 100 items"),
    ("max_asks_per_day", "Max same-event questions per day"),
    ("ask_useful_rate", "Useful asks (provisional placement was wrong)"),
    ("ask_true_yes_rate", "Questions whose true answer is yes"),
    ("asks_suppressed", "Asks suppressed by budget"),
    ("status_fact_recall", "Status-line fact recall"),
    ("plan_as_done", "Planned facts written as done (guard's claim regex) ↓"),
    ("plan_labelled_done", "Planned facts labelled done/in_progress (gold state, independent of the guard) ↓"),
    ("unsupported_completion", "Unsupported completion claims in cards ↓"),
    ("relative_date_in_card", "Cards with relative dates ↓"),
    ("stale_fact_rate", "Stale-fact rate ↓"),
    ("home_rank_ran", "Home rank ran (checkpoints)"),
    ("home_ndcg5", "Home NDCG@5"),
    ("home_ndcg5_recency", "Home NDCG@5, recency-only order"),
    ("home_top3_precision", "Home top-3 precision (grade ≥ 2)"),
    ("home_g3_recall3", "Home grade-3 recall@3"),
    ("home_gross_inversions", "Home gross inversions (grade gap ≥ 2) ↓"),
    ("home_clutter5", "Noise cards in home top 5 ↓"),
    ("ui_titles_over_20", "Titles over 20 chars ↓"),
    ("ui_status_over_54", "Status lines over 54 chars ↓"),
    ("card_fact_recall", "Card fact recall (status line + status facts; added metric)"),
    ("ui_status_over_24w", "Status lines wider than a Home card line (24) ↓ (added)"),
    ("ui_status_width_p50", "Status line width p50 (added)"),
    ("ui_status_width_p90", "Status line width p90 (added)"),
    ("ui_status_width_max", "Status line width max (added)"),
    ("ui_fact_date_repeated", "Facts repeating their own date in the text ↓ (added)"),
    ("ungrounded_card_dates", "Dates in status lines / facts not given by the cited items ↓ (added)"),
    ("person_link_accuracy", "Person linking accuracy"),
    ("person_link_accuracy_cross_source", "Person linking (cross-source people)"),
]


def fmt(value) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return "%.3f" % value
    return str(value)


def markdown_report(result: dict, title: str | None = None) -> str:
    s = result["summary"]
    lines = [f"### {title or result['scenario_id']} ({result.get('split')}, {result['n_items']} items)", "",
             "| Metric | Value |", "|---|---|"]
    for key, label in SUMMARY_ROWS:
        lines.append(f"| {label} | {fmt(s.get(key))} |")
    lines += ["", "| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate"
              " | Home NDCG@5 |",
              "|---|---|---|---|---|---|---|---|---|"]
    for c in result["checkpoints"]:
        if c.get("missing"):
            lines.append(f"| {c['checkpoint_id']} | – | missing | | | | | | |")
            continue
        home = c.get("home") or {}
        lines.append(f"| {c['checkpoint_id']} | {c['n_items']} | {fmt(c['bcubed_f1'])} | {fmt(c['link_f1'])} | "
                     f"{c['pred_event_count']}/{c['gold_event_count']} | {c['recalled']}/{c['expected']} "
                     f"({fmt(c['fact_recall'])}) | {c.get('plan_as_done', 0)} | {c['stale']}/{c['stale_applicable']} | "
                     f"{fmt(home.get('ndcg5'))} |")
    return "\n".join(lines) + "\n"


def load_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_snapshots(directory: str) -> dict:
    snaps = {}
    for name in sorted(os.listdir(directory)):
        if name.endswith(".json"):
            snaps[name[:-5]] = load_json(os.path.join(directory, name))
    return snaps


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gold", required=True, help="scenario.json")
    ap.add_argument("--snapshots", help="directory of <checkpoint_id>.json snapshots")
    ap.add_argument("--state", help="final /v1/state snapshot (defaults to the last checkpoint snapshot)")
    ap.add_argument("--with-status-facts", action="store_true", help="also search events[].status_facts")
    ap.add_argument("--validate", action="store_true", help="only validate the scenario")
    ap.add_argument("--json", help="write the full result JSON here")
    ap.add_argument("--md", help="write the markdown table here")
    args = ap.parse_args(argv)
    scenario = load_json(args.gold)
    errors, warnings = validate_scenario(scenario)
    for w in warnings:
        print("warning:", w, file=sys.stderr)
    for e in errors:
        print("error:", e, file=sys.stderr)
    if args.validate or errors:
        if not errors:
            print(f"{scenario.get('scenario_id')}: ok ({len(scenario['items'])} items, {len(scenario['events'])} events, "
                  f"{len(scenario['facts'])} facts, {len(scenario['checkpoints'])} checkpoints)")
        return 1 if errors else 0
    snaps = load_snapshots(args.snapshots) if args.snapshots else {}
    final = load_json(args.state) if args.state else None
    if not snaps and final is None:
        ap.error("give --snapshots and/or --state")
    if final is not None and not snaps:
        last = scenario["checkpoints"][-1]["checkpoint_id"]
        snaps = {last: final}
    result = score(scenario, snaps, final, args.with_status_facts)
    md = markdown_report(result)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(result, fh, ensure_ascii=False, indent=2)
    if args.md:
        with open(args.md, "w", encoding="utf-8") as fh:
            fh.write(md)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
