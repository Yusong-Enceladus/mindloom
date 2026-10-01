#!/usr/bin/env python3
"""The deterministic part of matter-group: the per-call schema enums and the validator context, both derived
from the <data> block (the organizer and the skill evals build the same request).

  schema_for(schema, data)   placements name exactly the matters of this call; ropes / parents name a shown rope
                             or a new key; evidence names one of the shown samples
  context_for(data)          the validator context (scripts/validate.py)

data = {"owner": [...], "ropes": [{"id": "R2", "title", "kind", "parent": "R1" | "", "matters": ["E3 标题", ...],
        "confirmed": bool}], "rejected": [titles], "types": [...],
        "matters": [{"id": "E5", "title", "anchor", "status_line", "item_count", "span", "people", "sample",
                     "sample_id": "I12"}],
        "placed": [{"id": "E3", "title", "rope": "R2"}]}
"""

from __future__ import annotations

import copy
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("matter_group_validate_for_build", Path(__file__).with_name("validate.py"))
_validate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_validate)

BATCH = 30          # matters placed per call
PLACED_SHOWN = 80   # already placed matters listed for context
NEW_KEYS = [f"N{i}" for i in range(1, 9)]


def _enum(prop: dict, values: list[str]) -> None:
    prop["enum"] = list(values)
    prop.pop("pattern", None)


def schema_for(schema: dict, data: dict) -> dict:
    s = copy.deepcopy(schema)
    props = s["properties"]
    matters = [m["id"] for m in data.get("matters") or []]
    ropes = [r["id"] for r in data.get("ropes") or []]
    movable = [r["id"] for r in data.get("ropes") or [] if not r.get("confirmed") and not r.get("parent")]
    samples = [m["sample_id"] for m in data.get("matters") or [] if m.get("sample_id")]
    new = props["new_ropes"]["items"]["properties"]
    _enum(new["parent"], [""] + ropes + NEW_KEYS)
    if samples:
        _enum(new["evidence"]["items"], samples)
    else:
        props["new_ropes"]["maxItems"] = 0
    place = props["placements"]["items"]["properties"]
    _enum(place["matter"], matters)
    _enum(place["rope"], [""] + ropes + NEW_KEYS)
    props["placements"]["maxItems"] = max(1, len(matters))
    if movable:
        _enum(props["nest"]["items"]["properties"]["rope"], movable)
        _enum(props["nest"]["items"]["properties"]["parent"], ropes + NEW_KEYS)
    else:
        props["nest"]["maxItems"] = 0
    return s


def context_for(data: dict) -> dict:
    ropes = {r["id"]: {"parent": r.get("parent") or "", "movable": not r.get("confirmed") and not r.get("parent")}
             for r in data.get("ropes") or []}
    rope_matters: dict[str, list[str]] = {}
    for r in data.get("ropes") or []:
        rope_matters[r["id"]] = [str(m).split(" ", 1)[0] for m in r.get("matters") or []]
    return {"judge": [m["id"] for m in data.get("matters") or []], "ropes": ropes,
            "titles": {r["id"]: _validate.norm_title(r.get("title", "")) for r in data.get("ropes") or []},
            "rejected": [_validate.norm_title(t) for t in data.get("rejected") or []],
            "raw_titles": {r["id"]: r.get("title", "") for r in data.get("ropes") or []},
            "rejected_raw": list(data.get("rejected") or []),
            "samples": {m["id"]: m.get("sample_id") for m in data.get("matters") or [] if m.get("sample_id")},
            "rope_matters": rope_matters}
