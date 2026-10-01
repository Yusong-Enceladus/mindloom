#!/usr/bin/env python3
"""The deterministic part of handover-pack: which items are shown and how much of each, the per-call schema
enums, the validator context (all derived from the <data> block, so the organizer and the skill evals build the
same request), and the stored shape of a valid output.

  select(ids, cited, n)            which items to show: every item a card fact or a map knot cites, then the most
                                   recent ones, up to n, in time order
  text_limit(n)                    characters of text shown per item for n items
  schema_for(schema, data)         the output schema restricted to this call's item handles
  context_for(data, owner)         the validator context (scripts/validate.py)
  finish(output, context)          the stored pack: the evidence item that holds each quote (quote_item), open
                                   commitments first, deadlines by date, duplicates gone

Item view (data["items"][]): {"id": "I12", "t": "2026-09-03 20:10", "kind": "口述", "src": "微信", "who": [...],
"text": "...", "dates": [{"said", "date"} | {"said", "from", "to"}]}.
"""

from __future__ import annotations

import copy
import json
from typing import Iterable

TEXT_BUDGET = 16000
MIN_CHARS = 60
MAX_CHARS = 420
MAX_ITEMS = 120

KIND_LABEL = {"dictation": "口述", "meeting_online": "线上会议", "meeting_offline": "线下会议", "imported_media": "音视频",
              "text": "文字", "image": "截图", "document": "文档", "file": "文件"}

EVIDENCE_LISTS = ("commitments", "deadlines", "decisions", "open_questions", "next_steps")


def select(ids: list[str], cited: Iterable[str], n: int = MAX_ITEMS) -> list[str]:
    """`ids` in time order; the cited ones always stay (up to n), the rest is filled from the most recent."""
    cited = [i for i in dict.fromkeys(cited) if i in set(ids)][:n]
    keep = set(cited)
    for i in reversed(ids):
        if len(keep) >= n:
            break
        keep.add(i)
    return [i for i in ids if i in keep]


def text_limit(n: int) -> int:
    return max(MIN_CHARS, min(MAX_CHARS, TEXT_BUDGET // max(1, n)))


def _enum(prop: dict, values: list[str]) -> None:
    prop["enum"] = list(values)
    prop.pop("pattern", None)


def schema_for(schema: dict, data: dict) -> dict:
    s = copy.deepcopy(schema)
    props = s["properties"]
    items = [i["id"] for i in data.get("items") or []]
    _enum(props["status"]["properties"]["evidence"]["items"], items)
    for key in EVIDENCE_LISTS:
        _enum(props[key]["items"]["properties"]["evidence"]["items"], items)
    _enum(props["links"]["items"]["properties"]["item"], items)
    return s


def context_for(data: dict, owner: Iterable[str] = ()) -> dict:
    items = {}
    for it in data.get("items") or []:
        text = it.get("text") or ""
        if text.endswith("…"):
            text = text[:-1]  # the excerpt marker is not part of the material
        dates, ranges = [], []
        for d in it.get("dates") or []:
            if d.get("date"):
                dates.append(d["date"])
            elif d.get("from") and d.get("to"):
                ranges.append([d["from"], d["to"]])
        items[it["id"]] = {"text": text, "date": (it.get("t") or "")[:10], "dates": dates, "ranges": ranges,
                           "who": list(it.get("who") or []), "kind": it.get("kind") or "", "src": it.get("src") or "",
                           "t": it.get("t") or ""}
    matter = data.get("matter") or {}
    people = list(matter.get("people") or [])
    for key in ("from", "to"):
        if matter.get(key):
            people.append(matter[key])
    for k in data.get("knots") or []:
        people.extend(k.get("who") or [])
    return {"items": items, "people": people, "owner": ["我", *[o for o in owner if o]],
            "input_text": json.dumps(data, ensure_ascii=False)}


def _squash(text: str) -> str:
    return " ".join((text or "").split())


def quote_item(entry: dict, items: dict):
    q = _squash(entry.get("quote") or "")
    ev = list(entry.get("evidence") or [])
    return next((i for i in ev if q and q in _squash((items.get(i) or {}).get("text", ""))), ev[0] if ev else None)


def finish(output: dict, context: dict) -> dict:
    """The stored form of a valid output (handles still short: the organizer maps them to item ids)."""
    items = context.get("items") or {}

    def clean(entry: dict, keys: tuple) -> dict:
        out = {k: (entry.get(k).strip() if isinstance(entry.get(k), str) else entry.get(k)) for k in keys}
        out["evidence"] = list(dict.fromkeys(entry.get("evidence") or []))
        if "quote" in keys:
            out["quote_item"] = quote_item(entry, items)
        return out

    def dedupe(entries: list[dict], key) -> list[dict]:
        seen, out = set(), []
        for e in entries:
            k = key(e)
            if k in seen:
                continue
            seen.add(k)
            out.append(e)
        return out

    st = output.get("status") or {}
    commitments = [clean(c, ("who", "to", "what", "due", "state", "quote")) for c in output.get("commitments") or []]
    commitments = dedupe(commitments, lambda c: (c["who"], _squash(c["what"])))
    commitments.sort(key=lambda c: (c["state"] != "open", c["due"] or "9999", c["who"]))
    deadlines = dedupe([clean(d, ("what", "date", "quote")) for d in output.get("deadlines") or []],
                       lambda d: (_squash(d["what"]), d["date"]))
    deadlines.sort(key=lambda d: d["date"] or "9999")
    decisions = dedupe([dict(clean(d, ("what", "date", "quote")), who=list(dict.fromkeys(d.get("who") or [])))
                        for d in output.get("decisions") or []], lambda d: _squash(d["what"]))
    decisions.sort(key=lambda d: d["date"] or "0000")
    questions = dedupe([clean(q, ("what", "quote")) for q in output.get("open_questions") or []],
                       lambda q: _squash(q["what"]))
    links = dedupe([{"item": ln["item"], "why": ln["why"].strip()} for ln in output.get("links") or []],
                   lambda ln: ln["item"])
    steps = dedupe([clean(s, ("what",)) for s in output.get("next_steps") or []], lambda s: _squash(s["what"]))
    return {"status": {"text": (st.get("text") or "").strip(), "evidence": list(dict.fromkeys(st.get("evidence") or []))},
            "commitments": commitments, "deadlines": deadlines, "decisions": decisions, "open_questions": questions,
            "links": links, "next_steps": steps}


def cited(pack: dict) -> list[str]:
    """Every item handle (or id) a stored pack cites, in first-cited order."""
    out: list[str] = list(pack.get("status", {}).get("evidence") or [])
    for key in EVIDENCE_LISTS:
        for e in pack.get(key) or []:
            out.extend(e.get("evidence") or [])
            if e.get("quote_item"):
                out.append(e["quote_item"])
    out.extend(ln["item"] for ln in pack.get("links") or [])
    return list(dict.fromkeys(out))
