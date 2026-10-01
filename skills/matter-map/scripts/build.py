#!/usr/bin/env python3
"""The deterministic part of matter-map: how much of each item is shown, the per-call schema enums, the
validator context (all derived from the <data> block, so the organizer and the skill evals build the same
request), and the stored shape of a valid output.

  text_limit(n)                   characters of text shown per item for a matter of n items
  schema_for(schema, data)        the output schema restricted to this call's item / fact / matter ids
  context_for(data, owner)        the validator context (scripts/validate.py)
  finish(output, data)            the stored map: "" -> null for strand / date, the evidence item that holds each
                                  knot's quote (quote_item), strands ordered s1.. (one with no item and no knot left
                                  out) and knots by date then order

Item view (data["items"][]): {"id": "I12", "t": "2026-09-03 20:10", "kind": "口述", "src": "微信", "who": [...],
"text": "...", "dates": [{"said", "date"} | {"said", "from", "to"}], "part_of": "I7" (a segment of a split item)}.
"""

from __future__ import annotations

import copy
import json
from typing import Iterable

# Total characters of item text in one request, and the bounds per item (a 200-item matter shows 60-80
# characters of each item, a 20-item matter up to 360).
TEXT_BUDGET = 15000
MIN_CHARS = 48
MAX_CHARS = 360
MAX_ITEMS = 160          # the most recent items when a matter holds more (earlier ones are counted, not shown)
OTHER_MATTERS = 8        # candidates for a blocks edge: by crossing count, then embedding similarity

KIND_LABEL = {"dictation": "口述", "meeting_online": "线上会议", "meeting_offline": "线下会议", "imported_media": "音视频",
              "text": "文字", "image": "截图", "document": "文档", "file": "文件"}


def text_limit(n: int) -> int:
    return max(MIN_CHARS, min(MAX_CHARS, TEXT_BUDGET // max(1, n)))


def _enum(prop: dict, values: list[str]) -> None:
    prop["enum"] = list(values)
    prop.pop("pattern", None)


def schema_for(schema: dict, data: dict) -> dict:
    s = copy.deepcopy(schema)
    props = s["properties"]
    items = [i["id"] for i in data.get("items") or []]
    facts = [f["id"] for f in data.get("facts") or []]
    others = [m["id"] for m in data.get("other_matters") or []]
    strand = props["strands"]["items"]["properties"]
    knot = props["knots"]["items"]["properties"]
    for prop in (strand["item_ids"]["items"], knot["evidence"]["items"], props["health"]["properties"]["evidence"]["items"],
                 props["blocks"]["items"]["properties"]["item_id"]):
        _enum(prop, items)
    if facts:
        _enum(strand["fact_ids"]["items"], facts)
    else:
        strand["fact_ids"]["maxItems"] = 0
    if others:
        _enum(props["blocks"]["items"]["properties"]["other"], others)
    else:
        props["blocks"]["maxItems"] = 0
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
                           "who": list(it.get("who") or [])}
    matter = data.get("matter") or {}
    others = {m["id"]: " ".join(str(m.get(k) or "") for k in ("title", "anchor")) for m in data.get("other_matters") or []}
    return {"items": items, "facts": [f["id"] for f in data.get("facts") or []],
            "people": list(matter.get("people") or []), "owner": ["我", *[o for o in owner if o]], "others": others,
            "input_text": json.dumps(data, ensure_ascii=False)}


def finish(output: dict, context: dict) -> dict:
    """The stored form of a valid output (handles still short: the organizer maps them to ids)."""
    items = context.get("items") or {}
    strands = []
    for s in sorted(output.get("strands") or [], key=lambda s: s["id"]):
        strands.append({"id": s["id"], "name": s["name"].strip(), "summary": s["summary"].strip(),
                        "item_ids": list(dict.fromkeys(s.get("item_ids") or [])),
                        "fact_ids": list(dict.fromkeys(s.get("fact_ids") or [])), "state": s["state"]})
    knots = []
    for n, k in enumerate(output.get("knots") or []):
        ev = list(dict.fromkeys(k.get("evidence") or []))
        quote = k.get("quote") or ""
        q = " ".join(quote.split())
        holder = next((i for i in ev if q and q in " ".join((items.get(i) or {}).get("text", "").split())), ev[0] if ev else None)
        knots.append({"id": k["id"], "strand": k.get("strand") or None, "kind": k["kind"], "text": k["text"].strip(),
                      "date": k.get("date") or None, "state": k["state"], "who": list(dict.fromkeys(k.get("who") or [])),
                      "evidence": ev, "quote": quote.strip(), "quote_item": holder, "_order": n})
    knots.sort(key=lambda k: (k["date"] or "9999", k["_order"]))
    for k in knots:
        k.pop("_order")
    # A strand with no item and no knot (a salvage can leave one) shows nothing: it is left out.
    used = {k["strand"] for k in knots if k["strand"]}
    strands = [s for s in strands if s["item_ids"] or s["id"] in used]
    h = output.get("health") or {}
    health = {"level": h.get("level", "ok"), "reason": (h.get("reason") or "").strip(),
              "evidence": list(dict.fromkeys(h.get("evidence") or []))} if h else None
    blocks = [{"other": b["other"], "direction": b["direction"], "item_id": b["item_id"], "quote": b["quote"].strip()}
              for b in output.get("blocks") or []]
    return {"strands": strands, "knots": knots, "health": health, "blocks": blocks}
