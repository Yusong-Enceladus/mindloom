#!/usr/bin/env python3
"""Semantic validator for event-assign output (the JSON schema is checked separately).

validate(output, context) -> list of error strings (empty = valid)
context = {"candidate_ids": [...best first], "candidate_item_ids": [...]}

The decision must agree with the model's own facets (see decide.py): attach when exactly one
candidate (the best-ranked if several) is the same object, ask when it is only unsure, none only for a
non-matter, new otherwise. (The organizer's anchor-overlap guard is applied afterwards and
is not a validation error.) A failed check triggers the harness's single retry; if the
retry still disagrees, the organizer applies decide.derive(), which never attaches on doubt.

CLI: python validate.py output.json [context.json]
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("event_assign_decide", Path(__file__).with_name("decide.py"))
_decide = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_decide)  # type: ignore[union-attr]

_HINT = {
    "attach": "有候选 match=same_object 时 decision 必须是 attach，event_id 填排在最前面的 same_object 候选",
    "ask": "没有 same_object、但有候选 match=unsure 时 decision 必须是 ask，event_id 填排在最前面的 unsure 候选",
    "none": "item_is_matter=false 且没有候选是同一对象时 decision 必须是 none",
    "new": "没有候选是同一对象且 item_is_matter=true 时 decision 必须是 new",
}


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    decision = output.get("decision")
    event_id = output.get("event_id", "")
    order = list(context.get("candidate_ids", []))
    candidates = set(order)
    known_items = set(context.get("candidate_item_ids", []))
    if decision not in ("attach", "new", "none", "ask"):
        return [f"unknown decision {decision!r}"]
    if not str(output.get("item_object", "")).strip():
        errors.append("item_object is empty: name the concrete object/place/deliverable the item is about")
    judged = output.get("judged") or []
    ids = [j.get("event_id") for j in judged]
    for jid in ids:
        if jid not in candidates:
            errors.append(f"judged cites {jid!r}, which is not a candidate")
    if len(ids) != len(set(ids)):
        errors.append("judged lists the same candidate twice")
    if decision in ("attach", "ask"):
        if event_id not in candidates:
            errors.append(f"decision={decision} needs event_id from the candidates, got {event_id!r}")
        elif event_id not in ids:
            errors.append(f"decision={decision} on {event_id} needs a judged entry for {event_id}")
    elif event_id:
        errors.append(f"decision={decision} must use event_id \"\"")
    if decision == "none" and output.get("item_is_matter") is not False:
        errors.append("decision=none means the item is no matter at all: item_is_matter must be false")
    if decision == "new" and output.get("item_is_matter") is False:
        errors.append("item_is_matter=false: choose none instead of new")
    if not errors:
        rank = {cid: i for i, cid in enumerate(order)}
        want = _decide.derive(output, rank)
        if want["action"] != decision:
            errors.append(f"decision={decision} contradicts judged/item_is_matter (expected {want['action']}): "
                          + _HINT[want["action"]])
        elif decision in ("attach", "ask") and want["target"] != event_id:
            errors.append(f"decision={decision} should target {want['target']} (the best-ranked linked candidate)")
    evidence = output.get("evidence") or []
    if not evidence:
        errors.append("evidence must not be empty")
    for i, ev in enumerate(evidence):
        if not str(ev.get("reason", "")).strip():
            errors.append(f"evidence[{i}].reason is empty")
        for ref in ev.get("item_ids", []):
            if ref not in known_items:
                errors.append(f"evidence[{i}] cites unknown item {ref}")
    if decision == "attach" and not any(ev.get("item_ids") for ev in evidence):
        errors.append("attach needs at least one evidence entry citing a candidate item id")
    return errors


def main() -> int:
    output = json.load(open(sys.argv[1], encoding="utf-8"))
    context = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(output, context)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
