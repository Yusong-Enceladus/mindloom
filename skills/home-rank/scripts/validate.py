#!/usr/bin/env python3
"""Semantic validator for home-rank output.

validate(output, context) -> list of error strings (empty = valid)
context = {"event_ids": [...], "feature_less": [...]}

CLI: python validate.py output.json [context.json]
"""

from __future__ import annotations

import json
import sys
from collections import Counter


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    ranking = output.get("ranking") or []
    ids = [r.get("event_id") for r in ranking]
    expected = list(context.get("event_ids", []))
    counts = Counter(ids)
    dupes = [i for i, n in counts.items() if n > 1]
    if dupes:
        errors.append(f"event ids ranked more than once: {dupes[:5]}")
    missing = [e for e in expected if e not in counts]
    if missing:
        errors.append(f"events missing from ranking: {missing[:5]}")
    extra = [i for i in counts if expected and i not in set(expected)]
    if extra:
        errors.append(f"unknown event ids: {extra[:5]}")
    less = set(context.get("feature_less", []))
    for r in ranking:
        imp = r.get("importance")
        if not isinstance(imp, (int, float)) or not 0 <= imp <= 1:
            errors.append(f"importance of {r.get('event_id')} must be within [0, 1]")
        elif r.get("event_id") in less and imp > 0.2:
            errors.append(f"{r.get('event_id')} is feature_less, importance must be <= 0.2")
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
