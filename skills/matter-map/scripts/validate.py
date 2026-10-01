#!/usr/bin/env python3
"""Deterministic validator (and repair) for matter-map output. The JSON schema is checked separately.

validate(output, context) -> list of error strings (empty = valid). Every error starts with its category
in brackets. repair(output, context) -> a copy with the repairable errors fixed (see REPAIRABLE).

context = {
  "items":  {"I12": {"text": shown text (no trailing ellipsis), "date": "YYYY-MM-DD" (capture day),
                     "dates": ["YYYY-MM-DD", ...] (days the text names, resolved against its capture time),
                     "ranges": [["YYYY-MM-DD", "YYYY-MM-DD"], ...] (spans it names), "who": [names]}},
  "facts":  ["f1", ...],                   # the card's facts shown to the model
  "people": [names],                       # the matter's people (labels as shown)
  "owner":  [names],                       # the user's own names ("我" included)
  "others": {"E5": "title anchor", ...},   # other_matters shown (the only matters a blocks entry may name)
  "input_text": str}                       # every text of the input, for the placeholder check

Rules the contract requires (MAP-CONTRACT section 1; a failure is retried once, then the map is dropped):
  [evidence]     every item / fact id is one of the input's.
  [quote]        a knot's quote is a verbatim substring of one of its evidence items (whitespace runs count as
                 one space; nothing else is forgiven).
  [strand]       strand ids and names are unique and a knot's strand exists.
  [strand_dup]   each item is in at most one strand.
  [date]         dates are ISO calendar dates (or "": no date).
  [question]     a question knot is "open" (and only a question knot is "open").
  [commitment]   a commitment knot names a person in `who`.
  [placeholder]  a placeholder (〔…〕) in the output is one of the input's, verbatim.
  [health]       a risk / stuck verdict cites at least one item.
Repairable (REPAIRABLE: not retried; repair() fixes them and the result is validated again):
  [ungrounded_date]  a knot's date is neither the capture day of one of its evidence items nor a day its text
                     names (dates / ranges) -> the date is blanked.
  [who]              a name in `who` appears nowhere (not a person of the matter, not the user, not in the
                     evidence texts or speakers) -> the name is dropped (a commitment left with nobody is dropped).
  [blocks]           a blocks entry that names a matter not offered, cites an unknown item, does not quote it
                     verbatim, has no dependency wording, or does not name the other matter -> the entry is dropped.
  [knot_id]          duplicate knot ids -> renumbered.
  [state]            a knot other than a question is "open" -> "planned" (commitment, deadline) or "doing".
After the retry (salvage(after_retry=True)): contract errors are retried once like any error; when the retry still
breaks a rule inside some knots (a quote that is not verbatim, a commitment by nobody, a question marked done …),
those knots are dropped, an item listed in several strands stays only in one of them ([strand_dup]), and the
map is kept if it still validates and keeps at least half of its knots; anything else is dropped. (The doubly
listed item stays in the smallest strand that lists it: the usual cause is one strand listing every item as "the
main thread" beside the real sub-threads.) On a large
matter (100+ items) the model often lists a meeting that touches two sub-threads under both, or shortens one
quote out of twenty; dropping the whole map for that left 10 of the first 12 lab maps without one.

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import copy
import json
import re
import sys
from datetime import date

REPAIRABLE = frozenset({"ungrounded_date", "who", "blocks", "knot_id", "state"})

_WS = re.compile(r"\s+")
_PLACEHOLDER = re.compile(r"〔[^〔〕]{1,40}〕")
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# Wording that states an order between two things: "等…再", "…之后才…", "取决于", "卡在", "先…再".
CUE = re.compile(r"等[^，。！？,.!?]{0,30}(?:再|才|之后|以后|出来|下来|定了|好了|完|回复|确认|到)|之后才|以后才|才能|才可以|才好|"
                 r"取决于|依赖|前提|卡在|卡着|被.{0,8}(?:卡|挡)|先[^，。！？,.!?]{1,20}再|完了再|好了再|定了再|出来再|"
                 r"下来再|到了再|waiting (?:for|on)|blocked (?:by|on)|depends on|after .{1,30} (?:can|will)", re.I)
_NOT_WORD = re.compile(r"[^0-9A-Za-z㐀-鿿]+")
_CJK = re.compile(r"[㐀-鿿]+")
_LATIN = re.compile(r"[A-Za-z][A-Za-z0-9_.+-]*[A-Za-z0-9]|[A-Za-z]{2,}")
STOP_BIGRAMS = frozenset("""
我们 你们 他们 她们 咱们 一下 一个 一些 这个 那个 这些 那些 这样 那样 这边 那边 这里 那里 今天 明天 昨天 后天 现在 已经 可以
没有 什么 怎么 时候 还是 就是 不是 如果 因为 所以 然后 但是 知道 需要 一起 下周 本周 上周 这周 周末 事情 东西 大家 自己 看看
好的 收到 时间 感觉 觉得 应该 还有 的话 一直 其实 之前 之后 以后 里面 问题 老师 同学 一定 可能 不过 而且 或者 马上 刚才
下午 上午 晚上 中午 早上 今晚 麻烦 谢谢 辛苦 帮我 帮忙 我的 你的 他的 了吗 了吧 一次 两个 三个 几个 多少 这次 上次
下次 目前 还没 回复 确认 发给 发我 给我 告诉 通知 安排 进展 情况 结果 继续 开始 完成 准备 处理 月份 出来 下来 等到 才能
""".split())


def terms(text: str) -> set[str]:
    """Content words: CJK bigrams minus function words, and Latin / alphanumeric tokens (lowercased)."""
    out: set[str] = set()
    for run in _CJK.findall(text or ""):
        for i in range(len(run) - 1):
            bg = run[i:i + 2]
            if bg not in STOP_BIGRAMS:
                out.add(bg)
    for tok in _LATIN.findall(text or ""):
        out.add(tok.lower())
    return out


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


# A knot's quote must be long enough to show what it rests on (SKILL.md asks for 4-20 characters): a two-character
# fragment ("我们") is a substring of almost any item and proves nothing (review finding V7-M3). Blocks edges
# quote a whole dependency statement and are held to the same floor.
MIN_QUOTE_CHARS = 4


def verbatim(quote: str, text: str) -> bool:
    q = squash_ws(quote)
    return len(q) >= MIN_QUOTE_CHARS and q in squash_ws(text)


def _allowed_days(ids: list[str], items: dict) -> set[str]:
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


def _name_grounded(name: str, ids: list[str], context: dict) -> bool:
    n = _norm_name(name)
    if not n:
        return False
    known = [*context.get("people", []), *context.get("owner", []), "我"]
    if any(n == _norm_name(k) for k in known):
        return True
    items = context.get("items") or {}
    for i in ids:
        it = items.get(i) or {}
        if any(n == _norm_name(w) for w in it.get("who") or []):
            return True
        if name.strip() and name.strip() in (it.get("text") or ""):
            return True
    # A short form of a known person ("周师傅" for "周建国", "Ann" for "Ann Li") is grounded by the texts only.
    return False


def _strings(output: dict):
    """The free texts outside the knots (knot_errors checks a knot's own)."""
    for s in output.get("strands") or []:
        yield s.get("name", "")
        yield s.get("summary", "")
    h = output.get("health") or {}
    yield h.get("reason", "")
    for b in output.get("blocks") or []:
        yield b.get("quote", "")


def block_errors(b: dict, context: dict) -> list[str]:
    items = context.get("items") or {}
    others = context.get("others") or {}
    other, iid, quote = b.get("other"), b.get("item_id"), str(b.get("quote") or "")
    if other not in others:
        return [f"[blocks] {other} is not one of other_matters"]
    if iid not in items:
        return [f"[blocks] unknown item {iid}"]
    if not verbatim(quote, items[iid].get("text", "")):
        return [f"[blocks] quote is not verbatim in {iid}"]
    if not CUE.search(quote):
        return [f"[blocks] the quote for {other} states no dependency (等…再 / …之后才… / 取决于)"]
    if not terms(quote) & terms(others[other]):
        return [f"[blocks] the quote does not name {other}"]
    return []


def knot_errors(k: dict, sids: set, context: dict) -> list[str]:
    """The errors of one knot (every rule above that concerns a single knot)."""
    errors: list[str] = []
    items = context.get("items") or {}
    kid = k.get("id")
    ev = list(k.get("evidence") or [])
    unknown = [i for i in ev if i not in items]
    if unknown:
        errors.append(f"[evidence] knot {kid} cites unknown items {unknown}")
    if k.get("strand") and k["strand"] not in sids:
        errors.append(f"[strand] knot {kid} is on strand {k['strand']}, which does not exist")
    quote = str(k.get("quote") or "")
    if not any(verbatim(quote, items[i].get("text", "")) for i in ev if i in items):
        errors.append(f"[quote] knot {kid}: the quote is not copied verbatim from one of its evidence items")
    d = k.get("date") or ""
    if d and not is_iso(d):
        errors.append(f"[date] knot {kid}: {d!r} is not a calendar date")
    elif d and not unknown and d not in _allowed_days(ev, items):
        errors.append(f"[ungrounded_date] knot {kid}: {d} is neither when its evidence was captured nor a day it names")
    kind, state = k.get("kind"), k.get("state")
    if kind == "question" and state != "open":
        errors.append(f"[question] knot {kid}: a question is open until it is answered (state must be open)")
    if kind != "question" and state == "open":
        errors.append(f"[state] knot {kid}: only a question is open; use done / doing / planned")
    who = [w for w in k.get("who") or [] if str(w).strip()]
    if kind == "commitment" and not who:
        errors.append(f"[commitment] knot {kid}: a commitment names the person who promised it")
    for w in who:
        if not _name_grounded(w, ev, context):
            errors.append(f"[who] knot {kid}: {w!r} appears nowhere in the matter")
    source = context.get("input_text") or ""
    for text in (k.get("text"), k.get("quote"), *(k.get("who") or [])):
        for ph in _PLACEHOLDER.findall(str(text or "")):
            if ph not in source:
                errors.append(f"[placeholder] knot {kid}: {ph} is not a placeholder of the input")
    return errors


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    items = context.get("items") or {}
    facts = set(context.get("facts") or [])
    strands = output.get("strands") or []
    knots = output.get("knots") or []
    health = output.get("health") or {}

    # strands
    sids, names, owner_of = set(), set(), {}
    for s in strands:
        sid = s.get("id")
        if sid in sids:
            errors.append(f"[strand] duplicate strand id {sid}")
        sids.add(sid)
        name = squash_ws(s.get("name", ""))
        if name in names:
            errors.append(f"[strand] two strands are both called {name}")
        names.add(name)
        for i in s.get("item_ids") or []:
            if i not in items:
                errors.append(f"[evidence] strand {sid} lists unknown item {i}")
            elif i in owner_of and owner_of[i] != sid:
                errors.append(f"[strand_dup] item {i} is in both {owner_of[i]} and {sid}; an item belongs to at most one strand")
            owner_of[i] = sid
        for f in s.get("fact_ids") or []:
            if f not in facts:
                errors.append(f"[evidence] strand {sid} lists unknown fact {f}")

    # knots
    kids = set()
    for k in knots:
        kid = k.get("id")
        if kid in kids:
            errors.append(f"[knot_id] duplicate knot id {kid}")
        kids.add(kid)
        errors.extend(knot_errors(k, sids, context))

    # health
    hev = health.get("evidence") or []
    if [i for i in hev if i not in items]:
        errors.append("[evidence] health cites unknown items")
    if health.get("level") in ("risk", "stuck") and not hev:
        errors.append("[health] a risk or stuck verdict cites at least one item")

    # blocks
    seen = set()
    for b in output.get("blocks") or []:
        key = (b.get("other"), b.get("direction"))
        if key in seen:
            errors.append(f"[blocks] {key[0]} {key[1]} twice")
            continue
        seen.add(key)
        errors.extend(block_errors(b, context))

    # placeholders
    source = context.get("input_text") or ""
    for s in _strings(output):
        for ph in _PLACEHOLDER.findall(str(s)):
            if ph not in source:
                errors.append(f"[placeholder] {ph} is not a placeholder of the input; keep placeholders verbatim")
    return errors


def repair(output: dict, context: dict) -> dict:
    """Fix the repairable errors (REPAIRABLE) deterministically; never touches anything else."""
    out = copy.deepcopy(output)
    items = context.get("items") or {}
    knots = []
    for k in out.get("knots") or []:
        ev = [i for i in k.get("evidence") or [] if i in items]
        d = k.get("date") or ""
        if d and is_iso(d) and d not in _allowed_days(ev, items):
            k["date"] = ""
        k["who"] = [w for w in k.get("who") or [] if str(w).strip() and _name_grounded(w, ev, context)]
        if k.get("kind") != "question" and k.get("state") == "open":
            k["state"] = "planned" if k.get("kind") in ("commitment", "deadline") else "doing"
        if k.get("kind") == "commitment" and not k["who"]:
            continue  # a promise by nobody the material names is not drawn
        knots.append(k)
    ids = [k.get("id") for k in knots]
    if len(set(ids)) != len(ids):
        for n, k in enumerate(knots, 1):
            k["id"] = f"k{n}"
    out["knots"] = knots
    blocks, seen = [], set()
    for b in out.get("blocks") or []:
        key = (b.get("other"), b.get("direction"))
        if key in seen or block_errors(b, context):
            continue
        seen.add(key)
        blocks.append(b)
    out["blocks"] = blocks
    return out


def trim(output: dict, context: dict) -> dict:
    """The salvage after the retry: a knot that breaks any rule repair() cannot fix is dropped, and an item listed
    in several strands stays in the most specific (smallest) one."""
    out = copy.deepcopy(output)
    sids = {s.get("id") for s in out.get("strands") or []}
    out["knots"] = [k for k in out.get("knots") or [] if categories(knot_errors(k, sids, context)) <= REPAIRABLE]
    # An item listed under several strands stays in the most specific one (the smallest; the first on a tie): the
    # usual cause is a strand that lists every item as "the main thread" next to the real sub-threads.
    strands = out.get("strands") or []
    size = {s.get("id"): len(set(s.get("item_ids") or [])) for s in strands}
    home: dict[str, str] = {}
    for s in strands:
        for i in s.get("item_ids") or []:
            if i not in home or size[s.get("id")] < size[home[i]]:
                home[i] = s.get("id")
    for s in strands:
        s["item_ids"] = [i for i in dict.fromkeys(s.get("item_ids") or []) if home.get(i) == s.get("id")]
    return out


def salvage(candidate: dict | None, errors: list[str], context: dict, after_retry: bool = True) -> dict | None:
    """What the organizer stores when the output failed validation. Before a retry (the first attempt) only when
    every error is repairable: the repaired candidate. After the retry: the candidate with its failing knots
    dropped, doubly listed items kept in their smallest strand and the repairable errors fixed, when that validates
    and keeps at least half of its knots (at least one). None otherwise: the map is dropped."""
    if candidate is None:
        return None
    if not after_retry:
        if not categories(errors) <= REPAIRABLE:
            return None
        fixed = repair(candidate, context)
        return fixed if not validate(fixed, context) else None
    fixed = repair(trim(candidate, context), context)
    before = len(candidate.get("knots") or [])
    if before and (not fixed.get("knots") or 2 * len(fixed["knots"]) < before):
        return None  # most of its knots were wrong: dropped
    return fixed if not validate(fixed, context) else None


def categories(errors: list[str]) -> set[str]:
    return {e[1:e.index("]")] for e in errors if e.startswith("[") and "]" in e}


def main() -> int:
    out = json.loads(open(sys.argv[1], encoding="utf-8").read())
    ctx = json.loads(open(sys.argv[2], encoding="utf-8").read()) if len(sys.argv) > 2 else {}
    errs = validate(out, ctx)
    print(json.dumps(errs, ensure_ascii=False, indent=1))
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
