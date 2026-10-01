#!/usr/bin/env python3
"""Semantic validator for person-resolve output (the JSON schema is checked separately).

validate(output, context) -> list of error strings (empty = valid)
context = {"candidates": ["P2", ...]}   # the handles offered as possible same persons

Rules: same_as is "" or one of the offered candidates; only a person can be the same as someone
(kind role / not_person -> same_as ""); reason is at most 30 display columns (CJK 1, ASCII 0.5).

CLI: python validate.py output.json [context.json]
"""

from __future__ import annotations

import json
import sys

REASON_MAX_WIDTH = 30


def _width(text: str) -> float:
    return sum(0.5 if ord(ch) < 0x2E80 else 1.0 for ch in text or "")


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    offered = set(context.get("candidates") or [])
    same = str(output.get("same_as") or "")
    if same and same not in offered:
        errors.append(f"same_as {same} is not one of the candidates ({', '.join(sorted(offered)) or 'none'}); use \"\"")
    if same and output.get("kind") != "person":
        errors.append("only kind=person can be the same as a candidate; use same_as \"\"")
    if _width(str(output.get("reason") or "")) > REASON_MAX_WIDTH:
        errors.append(f"reason is wider than {REASON_MAX_WIDTH} (中文字算1)")
    return errors


def main() -> int:
    out = json.load(open(sys.argv[1], encoding="utf-8"))
    ctx = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(out, ctx)
    print(json.dumps(errs, ensure_ascii=False, indent=1))
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
