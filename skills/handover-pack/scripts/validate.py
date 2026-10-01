#!/usr/bin/env python3
"""Deterministic validator (and repair) for handover-pack output. The JSON schema is checked separately.

validate(output, context) -> list of error strings (empty = valid). Every error starts with its category in
brackets and names the entry ("commitments[2]"). salvage(candidate, errors, context, after_retry) -> a usable
copy or None.

context = {
  "items":  {"I12": {"text": shown text (no trailing ellipsis), "date": capture day, "dates": [days the text
                     names], "ranges": [[from, to]], "who": [speakers]}},
  "people": [names],  "owner": [the user's names, "我" included],  "input_text": str}

Rules (a failure is retried once):
  [evidence]     every cited id is one of the input's items; the status cites at least one.
  [quote]        a commitment's, deadline's, decision's or question's quote is a verbatim substring (whitespace runs
                 count as one space; at least 4 characters) of one of its evidence items, and it is about the
                 claim: it shares a word with the entry's "what" (two CJK characters in a row, a Latin word or a
                 number) or, for a commitment, names who promised it (review finding V8R-16: a 4-character run of
                 any evidence item tied nothing to the claim).
  [date]         dates are ISO calendar dates or "".
  [commitment]   a commitment names who promised it.
  [placeholder]  a placeholder (〔…〕) in the output is one of the input's, verbatim.
Repairable (REPAIRABLE: not retried; repair() fixes them and the result is validated again):
  [ungrounded_date]  a date that is neither the capture day of one of the entry's evidence items nor a day its
                     text names -> blanked (a pack never invents a day).
  [who]              a name that appears nowhere in the matter -> dropped (a commitment left with nobody is dropped;
                     a "to" that appears nowhere becomes "").
  [duplicate]        the same commitment / deadline / decision / question / link twice -> the later one goes.
After the retry (salvage(after_retry=True)): an entry that still breaks a rule is dropped; the pack is kept when
its status is valid and at least half of its entries survive.

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import copy
import json
import re
import sys
from datetime import date

REPAIRABLE = frozenset({"ungrounded_date", "who", "duplicate"})
LISTS = ("commitments", "deadlines", "decisions", "open_questions", "next_steps")
QUOTED = ("commitments", "deadlines", "decisions", "open_questions")

_WS = re.compile(r"\s+")
_PLACEHOLDER = re.compile(r"〔[^〔〕]{1,40}〕")
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_CAT = re.compile(r"^\[([a-z_]+)\]")
_LOC = re.compile(r"^\[[a-z_]+\] ([a-z_]+)\[(\d+)\]")
MIN_QUOTE_CHARS = 4


def squash_ws(text: str) -> str:
    return _WS.sub(" ", text or "").strip()


def is_iso(value: str) -> bool:
    if not _ISO.match(value or ""):
        return False
    try:
        date.fromisoformat(value)
        return True
    except ValueError:
        return False


def verbatim(quote: str, text: str) -> bool:
    q = squash_ws(quote)
    return len(q) >= MIN_QUOTE_CHARS and "…" not in q and q in squash_ws(text)


_CJK = re.compile(r"[\u3400-\u9fff]")
_WORD = re.compile(r"[A-Za-z]{2,}|\d+")


def _terms(text: str) -> set[str]:
    """CJK bigrams, Latin words and numbers of a text (placeholders left out: they are the same in any text)."""
    text = _PLACEHOLDER.sub(" ", text or "")
    terms = {w.lower() for w in _WORD.findall(text)}
    for run in re.findall(r"[\u3400-\u9fff]+", text):
        terms |= {run[i:i + 2] for i in range(len(run) - 1)}
    return terms


def about(quote: str, e: dict) -> bool:
    """The quote speaks to this claim (V8R-16): it shares a term with its "what", or (a commitment) names its
    promiser."""
    q = squash_ws(quote)
    if _terms(q) & _terms(str(e.get("what") or "")):
        return True
    who = str(e.get("who") or "").strip() if isinstance(e.get("who"), str) else ""
    return bool(who) and who in q


def allowed_days(ids: list[str], items: dict) -> set[str]:
    days: set[str] = set()
    for i in ids:
        it = items.get(i) or {}
        if it.get("date"):
            days.add(it["date"])
        days.update(it.get("dates") or [])
        for a, b in it.get("ranges") or []:
            try:
                d0, d1 = date.fromisoformat(a), date.fromisoformat(b)
            except (TypeError, ValueError):
                continue
            n = 0
            while d0 <= d1 and n < 62:
                days.add(d0.isoformat())
                d0 = date.fromordinal(d0.toordinal() + 1)
                n += 1
    return days


def _norm_name(name: str) -> str:
    return re.sub(r"[\s·•.\-]", "", name or "").lower()


def name_grounded(name: str, context: dict) -> bool:
    """A name is grounded when it is a person of the matter, the user, a speaker of any item, or written in any
    item of the matter (a handover pack may name someone from another item than the entry's own)."""
    n = _norm_name(name)
    if not n:
        return False
    known = [*context.get("people", []), *context.get("owner", []), "我"]
    if any(n == _norm_name(k) for k in known):
        return True
    for it in (context.get("items") or {}).values():
        if any(n == _norm_name(w) for w in it.get("who") or []):
            return True
        if name.strip() and name.strip() in (it.get("text") or ""):
            return True
    return False


def categories(errors: list[str]) -> set[str]:
    return {m.group(1) for m in (_CAT.match(e) for e in errors) if m}


def entry_errors(key: str, n: int, e: dict, context: dict) -> list[str]:
    items = context.get("items") or {}
    where = f"{key}[{n}]"
    errors: list[str] = []
    ev = list(e.get("evidence") or [])
    unknown = [i for i in ev if i not in items]
    if unknown or not ev:
        errors.append(f"[evidence] {where} cites unknown items {unknown}" if unknown else
                      f"[evidence] {where} cites no item")
    if key in QUOTED and not any(verbatim(str(e.get("quote") or ""), items[i].get("text", "")) for i in ev if i in items):
        errors.append(f"[quote] {where}: the quote is not copied verbatim (4+ characters) from one of its evidence items")
    elif key in QUOTED and not about(str(e.get("quote") or ""), e):
        errors.append(f"[quote] {where}: the quote does not speak to the entry (no word in common with its what)")
    for field in ("due", "date"):
        d = e.get(field) or ""
        if not d:
            continue
        if not is_iso(d):
            errors.append(f"[date] {where}: {d!r} is not a calendar date")
        elif not unknown and d not in allowed_days(ev, items):
            errors.append(f"[ungrounded_date] {where}: {d} is neither when its evidence was captured nor a day it names")
    if key == "commitments":
        if not str(e.get("who") or "").strip():
            errors.append(f"[commitment] {where}: a commitment names the person who promised it")
        elif not name_grounded(e["who"], context):
            errors.append(f"[who] {where}: {e['who']!r} appears nowhere in the matter")
        if str(e.get("to") or "").strip() and not name_grounded(e["to"], context):
            errors.append(f"[who] {where}: {e['to']!r} appears nowhere in the matter")
    if key == "decisions":
        for w in e.get("who") or []:
            if not name_grounded(w, context):
                errors.append(f"[who] {where}: {w!r} appears nowhere in the matter")
    source = context.get("input_text") or ""
    for text in (e.get("what"), e.get("quote"), e.get("who"), e.get("to")):
        for ph in _PLACEHOLDER.findall(json.dumps(text, ensure_ascii=False) if not isinstance(text, str) else (text or "")):
            if ph not in source:
                errors.append(f"[placeholder] {where}: {ph} is not a placeholder of the input")
    return errors


def _key(key: str, e: dict):
    if key == "commitments":
        return (_norm_name(str(e.get("who"))), squash_ws(e.get("what", "")))
    return squash_ws(e.get("what", ""))


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    items = context.get("items") or {}
    st = output.get("status") or {}
    sev = list(st.get("evidence") or [])
    if not sev or [i for i in sev if i not in items]:
        errors.append("[evidence] status cites no item or an unknown one")
    source = context.get("input_text") or ""
    for ph in _PLACEHOLDER.findall(st.get("text") or ""):
        if ph not in source:
            errors.append(f"[placeholder] status: {ph} is not a placeholder of the input")
    for key in LISTS:
        seen = set()
        for n, e in enumerate(output.get(key) or []):
            errors.extend(entry_errors(key, n, e, context))
            k = _key(key, e)
            if k in seen:
                errors.append(f"[duplicate] {key}[{n}] repeats an earlier entry")
            seen.add(k)
    seen_links = set()
    for n, ln in enumerate(output.get("links") or []):
        if ln.get("item") not in items:
            errors.append(f"[evidence] links[{n}] names unknown item {ln.get('item')}")
        if ln.get("item") in seen_links:
            errors.append(f"[duplicate] links[{n}] names {ln.get('item')} again")
        seen_links.add(ln.get("item"))
        for ph in _PLACEHOLDER.findall(ln.get("why") or ""):
            if ph not in source:
                errors.append(f"[placeholder] links[{n}]: {ph} is not a placeholder of the input")
    return errors


def repair(output: dict, context: dict) -> dict:
    """Fix the repairable errors (REPAIRABLE) deterministically; never touches anything else."""
    out = copy.deepcopy(output)
    items = context.get("items") or {}
    for key in LISTS:
        kept, seen = [], set()
        for e in out.get(key) or []:
            ev = [i for i in e.get("evidence") or [] if i in items]
            for field in ("due", "date"):
                d = e.get(field) or ""
                if d and is_iso(d) and d not in allowed_days(ev, items):
                    e[field] = ""
            if key == "commitments":
                if str(e.get("who") or "").strip() and not name_grounded(e["who"], context):
                    continue  # a promise by nobody the material names is not written
                if str(e.get("to") or "").strip() and not name_grounded(e["to"], context):
                    e["to"] = ""
            if key == "decisions":
                e["who"] = [w for w in e.get("who") or [] if name_grounded(w, context)]
            k = _key(key, e)
            if k in seen:
                continue
            seen.add(k)
            kept.append(e)
        out[key] = kept
    links, seen = [], set()
    for ln in out.get("links") or []:
        if ln.get("item") in seen:
            continue
        seen.add(ln.get("item"))
        links.append(ln)
    out["links"] = links
    return out


def _count(output: dict) -> int:
    return sum(len(output.get(k) or []) for k in LISTS) + len(output.get("links") or [])


def salvage(candidate, errors: list[str], context: dict, after_retry: bool = False):
    """A usable pack from a schema-valid candidate, or None. Before the retry only repairable errors are fixed;
    after it, entries that still break a rule are dropped too (the pack is kept if its status is valid and at
    least half of its entries survive)."""
    if not isinstance(candidate, dict):
        return None
    if not after_retry and not categories(errors) <= REPAIRABLE:
        return None
    fixed = repair(candidate, context)
    if after_retry:
        bad: dict[str, set[int]] = {}
        for e in validate(fixed, context):
            m = _LOC.match(e)
            if m and categories([e]) - REPAIRABLE:
                bad.setdefault(m.group(1), set()).add(int(m.group(2)))
        before = _count(fixed)
        for key, idx in bad.items():
            fixed[key] = [x for n, x in enumerate(fixed.get(key) or []) if n not in idx]
        if before and _count(fixed) * 2 < before:
            return None
    return fixed if not validate(fixed, context) else None


if __name__ == "__main__":
    out = json.load(open(sys.argv[1], encoding="utf-8"))
    ctx = json.load(open(sys.argv[2], encoding="utf-8"))
    errs = validate(out, ctx)
    print("\n".join(errs) if errs else "OK")
    sys.exit(1 if errs else 0)
