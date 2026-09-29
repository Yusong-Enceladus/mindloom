#!/usr/bin/env python3
"""Semantic validator for file-read output (after the JSON schema).

validate(output, context) -> list of error strings (empty = valid)
  context["text"]  the reading text the model saw (the full text, not only the excerpt it was shown)
  context["extra_numbers"]  numbers the organizer counted itself (pages, sheets, ...), allowed in the summary

Rules:
  - summary: one line, not empty, no stand-in opener ("这是一份…"), and every number in it appears in the
    text or in extra_numbers (no sums, conversions or computed dates);
  - fields: no invented fields: every value (and every non-empty label) is found in the text, verbatim up to
    whitespace / full-width forms; no stand-in values; no repeated (key, value); only for the doc kinds that carry
    key fields (receipt_invoice, booking_ticket, contract, form).

sanitize(output, context) -> (cleaned copy, number of values dropped): what the organizer keeps when the
output still fails after the retry: bad fields are dropped and a summary with a made-up number is emptied
(the organizer then writes its own plain summary), never rewritten.

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import copy
import json
import re
import sys
import unicodedata

_WS = re.compile(r"\s+")
_NUM = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")
_PUNCT = str.maketrans({"：": ":", "，": ",", "。": ".", "（": "(", "）": ")", "－": "-", "—": "-", "–": "-",
                        "／": "/", "¥": "￥", "“": '"', "”": '"', "‘": "'", "’": "'"})
FIELD_KINDS = {"receipt_invoice", "booking_ticket", "contract", "form"}
STAND_INS = {"未知", "不详", "不明", "暂无", "无", "无法识别", "n/a", "na", "unknown", "none", "null", "tbd", "?", "？", "-"}
OPENERS = re.compile(r"^(这是|此为|这份|该文件|该文档|本文件|本文档|这个文件|文件内容为|This (is|file|document))", re.I)
_MONTHS = {m: str(i + 1) for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
_MONTH_WORD = re.compile(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?(?![a-z])", re.I)


def norm(s) -> str:
    return _WS.sub("", unicodedata.normalize("NFKC", str(s or "")).translate(_PUNCT)).lower()


def numbers(s) -> list[str]:
    """Canonical forms of every number in s: thousands separators removed, leading / trailing zeros dropped."""
    out = []
    for tok in _NUM.findall(unicodedata.normalize("NFKC", str(s or ""))):
        tok = tok.replace(",", "")
        if "." in tok:
            tok = tok.rstrip("0").rstrip(".")
        tok = tok.lstrip("0") or "0"
        if tok.startswith("."):
            tok = "0" + tok
        out.append(tok)
    return out


def text_numbers(text: str) -> set:
    nums = set(numbers(text))
    # A date printed as 2026-03-07 also yields 3 and 7 through the split above; a month name counts as its
    # number, so "Mar 3" supports "3 月 3 日".
    nums.update(_MONTHS[m.group(1).lower()] for m in _MONTH_WORD.finditer(text or ""))
    return nums


def _s(x) -> str:
    return x.strip() if isinstance(x, str) else ""


def _summary_errors(summary: str, ctx: dict, allowed: set) -> list[str]:
    errs = []
    if not summary:
        return ["summary 为空：用一句话说这个文件在讲什么事"]
    if "\n" in summary:
        errs.append("summary 只能是一行")
    if OPENERS.match(summary):
        errs.append("summary 不要用'这是一份……'开场，直接说事")
    bad = [n for n in dict.fromkeys(numbers(summary)) if n not in allowed]
    if bad:
        errs.append(f"summary 里的数字 {'、'.join(bad)} 在文件文字里找不到：只写文件里有的数字，不要计算或推算")
    return errs


def _field_errors(fields: list, doc_kind: str, text_n: str, given: set) -> list[tuple[int, str]]:
    errs: list[tuple[int, str]] = []
    if fields and doc_kind not in FIELD_KINDS:
        return [(i, f"fields[{i}]：doc_kind 为 {doc_kind} 时 fields 写 []") for i in range(len(fields))]
    seen = set()
    for i, f in enumerate(fields):
        if not isinstance(f, dict):
            errs.append((i, f"fields[{i}] 不是对象"))
            continue
        key, label, value = _s(f.get("key")), _s(f.get("label")), _s(f.get("value"))
        if (key, norm(value)) in seen:
            errs.append((i, f"fields[{i}]：{key} 重复"))
        seen.add((key, norm(value)))
        if key in given:
            errs.append((i, f"fields[{i}]：{key} 已由代码给出，不要重复"))
        if value.lower() in STAND_INS:
            errs.append((i, f"fields[{i}].value 是占位词：文件里没有的字段不要输出"))
        elif norm(value) not in text_n:
            errs.append((i, f"fields[{i}].value「{value}」在文件文字里找不到：逐字照抄，或者不输出这个字段"))
        if label and norm(label) not in text_n:
            errs.append((i, f"fields[{i}].label「{label}」在文件文字里找不到：写文中的字段名原文或 \"\""))
    return errs


def validate(output: dict, context: dict) -> list[str]:
    text = context.get("text") or ""
    allowed = text_numbers(text) | {n for x in context.get("extra_numbers") or [] for n in numbers(x)}
    errs = _summary_errors(_s(output.get("summary")), context, allowed)
    given = {_s(k) for k in context.get("given_keys") or []}
    errs += [e for _, e in _field_errors(output.get("fields") or [], _s(output.get("doc_kind")), norm(text), given)]
    return errs


def sanitize(output: dict, context: dict) -> tuple[dict, int]:
    out = copy.deepcopy(output) if isinstance(output, dict) else {}
    text = context.get("text") or ""
    allowed = text_numbers(text) | {n for x in context.get("extra_numbers") or [] for n in numbers(x)}
    dropped = 0
    if _summary_errors(_s(out.get("summary")), context, allowed):
        out["summary"] = ""
        dropped += 1
    given = {_s(k) for k in context.get("given_keys") or []}
    fields = out.get("fields") if isinstance(out.get("fields"), list) else []
    bad = {i for i, _ in _field_errors(fields, _s(out.get("doc_kind")), norm(text), given)}
    out["fields"] = [f for i, f in enumerate(fields) if i not in bad]
    dropped += len(bad)
    if out.get("doc_kind") not in FIELD_KINDS | {"notice", "report", "minutes", "plan", "resume", "letter", "manual",
                                                  "dataset", "code", "other"}:
        out["doc_kind"] = "other"
    return out, dropped


if __name__ == "__main__":
    o = json.load(open(sys.argv[1], encoding="utf-8"))
    c = json.load(open(sys.argv[2], encoding="utf-8"))
    errs = validate(o, c)
    print(json.dumps(errs, ensure_ascii=False, indent=1))
    sys.exit(1 if errs else 0)
