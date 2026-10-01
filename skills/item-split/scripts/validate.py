#!/usr/bin/env python3
"""Semantic validator for item-split output.

validate(output, context) -> list of error strings (empty = valid). context: {"unit_ids": ["U1", ...],
"known": ["E3", ...]} (the known matters shown, if any).

Rules: ranges use this call's unit ids, from <= to, segments are in text order and never overlap,
every segment's matter is one of `matters` (1-based) or 0 (a stretch that is no matter at all), every listed matter has a segment, and a gist
fits in 20 display columns (CJK 1, ASCII 0.5), and `known` (optional) has one entry per matter, each "" or a
known matter that was shown.

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import json
import sys

GIST_MAX_WIDTH = 20


def _width(text: str) -> float:
    return sum(0.5 if ord(ch) < 0x2E80 else 1.0 for ch in text or "")


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    ids = list(context.get("unit_ids") or [])
    pos = {u: i for i, u in enumerate(ids)}
    matters = output.get("matters") or []
    segments = output.get("segments") or []
    prev_end = -1
    used = set()
    for i, seg in enumerate(segments):
        a, b = pos.get(seg.get("from")), pos.get(seg.get("to"))
        if a is None or b is None:
            errors.append(f"segments[{i}]: unknown unit id (use U1..U{len(ids)})")
            continue
        if b < a:
            errors.append(f"segments[{i}]: from {seg['from']} is after to {seg['to']}")
            continue
        if a <= prev_end:
            errors.append(f"segments[{i}]: overlaps or is out of order with the previous segment")
        prev_end = max(prev_end, b)
        m = seg.get("matter")
        if isinstance(m, int) and m == 0:
            pass  # a stretch that is no matter at all (寒暄、闲聊、通知): kept apart, never filed
        elif not isinstance(m, int) or not 1 <= m <= len(matters):
            errors.append(f"segments[{i}].matter must be 1..{len(matters)} (an index into matters), or 0 for no matter")
        else:
            used.add(m)
        gist = str(seg.get("gist") or "").strip()
        if not gist:
            errors.append(f"segments[{i}].gist is empty")
        elif _width(gist) > GIST_MAX_WIDTH:
            errors.append(f"segments[{i}].gist is wider than {GIST_MAX_WIDTH} (中文字算1)")
    for n in range(1, len(matters) + 1):
        if n not in used and segments:
            errors.append(f"matters[{n - 1}] has no segment; drop it or give it its units")
    if matters and not segments:
        errors.append("matters listed but no segments")
    known = output.get("known")
    if known is not None:
        shown = set(context.get("known") or [])
        if len(known) != len(matters):
            errors.append(f"known must have one entry per matter ({len(matters)}); use \"\" for a matter not in known_matters")
        for i, k in enumerate(known):
            if k and k not in shown:
                errors.append(f"known[{i}] {k} is not in known_matters; use \"\"")
    return errors


def main() -> int:
    out = json.load(open(sys.argv[1], encoding="utf-8"))
    ctx = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(out, ctx)
    print(json.dumps(errs, ensure_ascii=False, indent=1))
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
