#!/usr/bin/env python3
"""Semantic validator for event-brief output.

validate(output, context) -> list of error strings (empty = valid)
context = {"item_ids": [...], "title_locked": bool, "current_title": str,
           "items": {item_id: {"text": <excerpt shown to the model>, "captured_at": ISO}}}   (optional)

Format checks: one-line title that names a concrete matter, a one-sentence status line with no meta
description, facts citing shown items.

Evidence checks (only when context.items is given):
  a. A done / in_progress / cancelled fact must carry a `quote` that is a verbatim clause of a cited
     item, contains a completion / acceptance / start / cancel marker, and no future or conditional
     marker ("下周一出发，当天回" and "月底来取吧" are plans, not completions).
  b. A done / in_progress fact may not be dated later than its latest cited evidence was captured.
  c. A planned / info fact may not claim completion ("已签""已送达""已完成"...).
  d. A completion claim in status_line needs a validated done / in_progress fact of the same verb
     family; a passed plan date is never evidence.
  e. No relative time words (今天/明天/下周…) in title, status_line or facts; bare weekdays are allowed
     only in parentheses right after an absolute date, e.g. "9月22日（周二）". A bare 下周 is tolerated
     when a shown item says 下周 and that week is still the week after as_of (it is then true as of
     the card's own time); the skill asks for "9月28日那周" / "10月4日前" instead.
  f. Date provenance: every M月D日 / N日 in the status line and in a fact, and every fact `date`, must be
     a date written in or resolved (dates.py) from the cited items (the status line: any shown item), or
     their capture day, to the day. A range the source gave (下周 -> 9/28..10/4) grounds only its ends,
     said as a range ("9月28日那周", "10月4日前"), never a day inside it. A weekday in brackets must be
     that date's weekday. salvage() drops an ungrounded date instead of the whole fact or line.
  g. A quote that only records a decision ("行，那就这么定") supports "已决定/已同意…", never a signed /
     paid / shipped / ordered / done-handling fact, and does not back such a claim in the status line.
UI fit: the status line is the Home card's one line. Its display width (a CJK character 1, an ASCII
character 0.5) is at most STATUS_MAX_WIDTH (24); STATUS_TARGET_WIDTH (18) is what the skill aims for.
Error texts start with a category tag ([unsupported_completion], [relative_date], [ungrounded_date],
[format], [length])
that the organizer records when a brief is rejected.

tidy(output) removes a fact's own date from its text when the `date` field already carries it
("9月28日（周一）上午10点汇报" with date 2026-09-28 -> "上午10点汇报"); the organizer applies it to every
brief it stores. salvage() also cuts an over-long status line at a clause boundary.

CLI: python validate.py output.json [context.json]
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import unicodedata
from datetime import date, timedelta
from pathlib import Path

_spec = importlib.util.spec_from_file_location("event_brief_dates", Path(__file__).with_name("dates.py"))
_dates = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dates)  # type: ignore[union-attr]

GENERIC_TITLES = {"事件", "未命名", "未命名事件", "会议", "会议记录", "聊天", "聊天记录", "工作", "笔记", "口述", "记录", "新事件"}
_SENTENCE_END = re.compile(r"[。！？!?；;]")
_META = ("本事件", "该事件", "这些素材", "共有", "条记录", "条素材")

# A clause that says something already happened / was accepted / started / was cancelled.
DONE_MARKER = re.compile(r"已|了|过|完成|通过|签收|收到|到账|可以|没问题|同意|就定|定了|这么定|说定|定下|取消|不做|搞定|好的|"
                         r"好呀|好啊|好嘞|^行[，,。！!]|^好[，,。！!]")
# A clause that talks about the future or a condition. Its presence makes a quote a plan.
FUTURE_MARKER = re.compile(r"将(?!近)|会(?![员议谈场计])|要(?![求点紧])|计划|准备|打算|预计|争取|的话|如果|明天|明日|后天|下周|"
                           r"下个月|等.{0,6}再|吧[。！!～~]?$")
# Completion claims in cards. Group "verb" names the verb family.
_CLAIM_VERBS = r"完成|完工|完事|开工|验收|送达|送到|到货|签|上线|退|安装|装好|修好|印好|下单|付|发货|寄出"
CLAIM = re.compile(r"已(?:经)?(?:于[^，。；]{0,14})?[续再重]?(?P<verb>" + _CLAIM_VERBS + r")"
                   r"|(?P<plan>按计划完成)|(?P<tail>(?:完成|完工|搞定)了)")
# A clause that states a plan ("约定9月26日完工", "定于25日签约") is not a completion claim.
PLAN_CLAUSE = re.compile(r"定于|(?<!按)计划|预计|约定|将于|打算|准备|拟于")
_CLAUSE = re.compile(r"[，,。；;！!？?\n]")
FAMILIES = {
    "签": ("签",),
    "送": ("送达", "送到", "到货", "到了", "收到", "签收"),
    "验收": ("验收", "通过"),
    "完成": ("完成", "完工", "完事", "做完", "看完", "搞定", "通过", "好了"),
    "开工": ("开工", "开始"),
    "退": ("退",),
    "上线": ("上线",),
    "安装": ("安装", "装好", "装了"),
    "修": ("修好", "修了", "修完"),
    "印": ("印",),
    "下单": ("下单",),
    "付": ("付",),
    "发": ("发货", "发出", "寄出"),
}
_VERB_FAMILY = {"完成": "完成", "完工": "完成", "完事": "完成", "开工": "开工", "验收": "验收", "送达": "送",
                "送到": "送", "到货": "送", "签": "签", "上线": "上线", "退": "退", "安装": "安装", "装好": "安装",
                "修好": "修", "印好": "印", "下单": "下单", "付": "付",
                "发货": "发", "寄出": "发"}
# Families a decision alone never completes: a contract is signed, money paid, goods shipped or ordered,
# work done by someone acting on it, not by agreeing to it.
PROCEDURAL = {"签", "付", "送", "发", "下单", "退", "上线", "安装", "修", "印", "开工", "验收"}
_PROCEDURAL_WORDS = {"签": ("签",), "付": ("付", "转账", "打款", "汇款", "缴"), "发": ("发货", "发出", "寄出", "寄了", "快递"),
                     "送": ("送达", "送到", "到货"), "下单": ("下单", "订购"), "退": ("退",), "上线": ("上线",),
                     "安装": ("安装", "装好"), "修": ("修好", "修了", "修完"), "印": ("印好", "印了"),
                     "开工": ("开工",), "验收": ("验收",)}
# A fact that states the decision itself ("已同意先签一个月") is not a claim that the step was carried out.
_DECISION_FRAME = re.compile(r"决定|同意|说定|谈妥|确定|敲定|选定|定下|打算|准备|计划|约定|答应")
# Decision / acceptance phrases. What is left of a quote after removing them must still say something
# happened, or the quote records only a decision.
_DECISION_PHRASE = re.compile(r"(?:那就|就|那)?(?:这么|这样)?(?:说)?定(?:下来)?了?|(?:那就|就)?这么办吧?|就这样吧?|同意了?|"
                              r"可以了?|没问题|好的|好呀|好啊|好嘞|成交了?|^行|^好")
_HAPPENED = re.compile(r"已|了|过|完成|通过|签收|收到|到账|搞定|取消")


def decision_only(quote: str) -> bool:
    """True when the quote's only 'done' content is a decision or an acceptance ("行，那就这么定")."""
    q = _norm(quote)
    return bool(q) and not _HAPPENED.search(_DECISION_PHRASE.sub("", q))


def _procedural_claims(text: str) -> set[str]:
    """Procedural families a done / in_progress fact's text says were carried out."""
    if _DECISION_FRAME.search(text or ""):
        return set()
    return {f for f, words in _PROCEDURAL_WORDS.items() if any(w in (text or "") for w in words)}


RELATIVE = re.compile(r"今天|今日|今晚|今早|明天|明日|明早|明晚|后天|昨天|昨日|前天|本周|这周|下周|上周|周末|"
                      r"下个月|这个月|本月|下星期|上星期|这星期")
_BARE_WEEKDAY = re.compile(r"(?:周|星期|礼拜)[一二三四五六日天]")
_MONTH_DAY = re.compile(r"(\d{1,2})月(\d{1,2})[日号]")
_DAY_ONLY = re.compile(r"(?<![月\d])(\d{1,2})[日号]")


STATUS_TARGET_WIDTH = 18
STATUS_MAX_WIDTH = 24


def line_width(text: str) -> float:
    """Display width on the Home card: wide (CJK, fullwidth) characters 1, narrow (ASCII) 0.5."""
    return sum(0.5 if unicodedata.east_asian_width(ch) in ("Na", "H", "N") else 1.0 for ch in (text or "").strip())


def _cut_line(line: str, limit: float = STATUS_MAX_WIDTH) -> str | None:
    """The longest leading run of whole clauses that fits `limit`, or None if even the first does not."""
    parts = re.split(r"(?<=[，,；;、])", (line or "").strip())
    out = ""
    for p in parts:
        if line_width(out + p) > limit:
            break
        out += p
    out = out.rstrip("，,；;、 ")
    return out if out and line_width(out) >= 4 else None


_WEEKDAY_PAREN = r"(?:[（(](?:周|星期|礼拜)[一二三四五六日天][）)])?"
# A date followed by a relation word keeps its date in the text: "9月30日前交" is a deadline, not a when.
_RELATION_AFTER = re.compile(r"^(?:之?前|以前|前后|起|之?后|以后|止|为止|截止|底|左右)")


def strip_own_date(text: str, iso: str) -> str:
    """Remove the fact's own date (from its `date` field) from its text, when that is the only date in it."""
    try:
        d = date.fromisoformat(iso)
    except (TypeError, ValueError):
        return text
    pat = re.compile(r"(?:(?:定于|于|在)\s*)?(?:%d年)?0?%d月0?%d[日号]%s" % (d.year, d.month, d.day, _WEEKDAY_PAREN))
    others = [m for m in _MONTH_DAY.finditer(text) if (int(m.group(1)), int(m.group(2))) != (d.month, d.day)]
    m = pat.search(text)
    if not m or others or len(pat.findall(text)) != 1 or _RELATION_AFTER.match(text[m.end():]):
        return text
    out = (text[:m.start()] + text[m.end():]).strip()
    out = re.sub(r"^[，,、；;：:\s]+|[，,、；;：:\s]+$", "", out)
    out = re.sub(r"[，,、]{2,}", "，", out)
    return out if len(out) >= 2 else text


def tidy(output: dict) -> dict:
    """Deterministic clean-up applied to every stored brief: no fact repeats the date in its date field."""
    if not isinstance(output, dict):
        return output
    facts = []
    for f in output.get("status_facts") or []:
        if isinstance(f, dict) and f.get("date") and isinstance(f.get("text"), str):
            f = dict(f, text=strip_own_date(f["text"], f["date"]))
        facts.append(f)
    return dict(output, status_facts=facts) if "status_facts" in output else output


def _norm(text: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", text or ""))


def _capture_date(items: dict, ids: list[str]) -> date | None:
    days = []
    for i in ids:
        at = (items.get(i) or {}).get("captured_at")
        if at:
            try:
                days.append(_dates.to_local(at).date())  # the capture's own wall-clock day
            except ValueError:
                pass
    return max(days) if days else None


def _dates_in(text: str, ref: date) -> list[date]:
    out = []
    for m in _MONTH_DAY.finditer(text):
        try:
            out.append(date(ref.year, int(m.group(1)), int(m.group(2))))
        except ValueError:
            pass
    stripped = _MONTH_DAY.sub("", text)
    for m in _DAY_ONLY.finditer(stripped):
        try:
            out.append(date(ref.year, ref.month, int(m.group(1))))
        except ValueError:
            pass
    return out


def claims(text: str) -> list[str]:
    """Verb families of every completion claim in text ('完成' for generic claims). Clauses that state a
    plan are skipped."""
    fams = []
    for clause in _CLAUSE.split(text or ""):
        if PLAN_CLAUSE.search(clause):
            continue
        for m in CLAIM.finditer(clause):
            verb = m.group("verb")
            fams.append(_VERB_FAMILY.get(verb, "完成") if verb else "完成")
    return fams


_BARE_NEXT_WEEK = re.compile(r"下(?:个)?(?:周|星期|礼拜)(?![一二三四五六日天末])")


def _relative_errors(label: str, text: str, allow_next_week: bool = False) -> list[str]:
    errs = []
    m = next((m for m in RELATIVE.finditer(text or "")
              if not (allow_next_week and _BARE_NEXT_WEEK.match(text, m.start()))), None)
    if m:
        errs.append(f"[relative_date] {label} 用了相对时间「{m.group(0)}」，请按该素材的 captured_at 换算成绝对日期，如「9月22日」")
    for w in _BARE_WEEKDAY.finditer(text or ""):
        before = text[max(0, w.start() - 1):w.start()]
        if before not in ("（", "("):
            errs.append(f"[relative_date] {label} 里的「{w.group(0)}」要写成绝对日期，星期只能放在日期后的括号里，如「9月22日（周二）」")
            break
    return errs


def check_fact_evidence(fact: dict, items: dict) -> list[str]:
    """Evidence rules a–c for one fact. Also used by eval/score.py to audit stored cards."""
    errs: list[str] = []
    state = fact.get("state", "info")
    text = str(fact.get("text", ""))
    refs = fact.get("item_ids") or []
    quote = _norm(fact.get("quote", ""))
    if state in ("done", "in_progress", "cancelled"):
        if not quote:
            errs.append(f"[unsupported_completion] 事实「{text}」标为 {state}，必须在 quote 里摘录引用素材中明确说已发生的原话")
        else:
            sources = [_norm((items.get(r) or {}).get("text", "")) for r in refs]
            if not any(quote in s for s in sources if s):
                errs.append(f"[unsupported_completion] 事实「{text}」的 quote「{fact.get('quote')}」不是所引用素材里的原话")
            if not DONE_MARKER.search(quote):
                errs.append(f"[unsupported_completion] quote「{fact.get('quote')}」没有说已经发生（缺少 已/了/完成/通过…）；计划请标 planned")
            fm = FUTURE_MARKER.search(quote)
            if fm:
                errs.append(f"[unsupported_completion] quote「{fact.get('quote')}」里有「{fm.group(0)}」，说的是计划或条件，不能标 {state}")
        cap = _capture_date(items, refs)
        if cap is not None and state in ("done", "in_progress"):
            later = [d for d in _dates_in(text, cap) if d > cap]
            if fact.get("date"):
                try:
                    if date.fromisoformat(fact["date"]) > cap:
                        later.append(date.fromisoformat(fact["date"]))
                except ValueError:
                    pass
            if later:
                errs.append(f"[unsupported_completion] 事实「{text}」标为 {state}，但日期 {later[0].isoformat()} 晚于证据素材的时间 "
                            f"{cap.isoformat()}；把已发生的部分和计划的部分拆成两条")
        if quote and state in ("done", "in_progress") and decision_only(quote):
            fams = _procedural_claims(text)
            if fams:
                errs.append(f"[unsupported_completion] quote「{fact.get('quote')}」只说做了决定，不能证明「{text}」已办完"
                            f"（{'/'.join(sorted(fams))}）；写成「已决定/已同意…」，或摘录明确说已经办完的原话")
    elif claims(text):
        errs.append(f"[unsupported_completion] 事实「{text}」标为 {state}，却写成已完成；计划写成「定于/计划…」")
    return errs


# ---- f. date provenance ------------------------------------------------------------------------

_CARD_DATE = re.compile(r"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号]")
_CARD_DAY = re.compile(r"(?<![月\d里路街巷弄楼栋室第期年])(\d{1,2})[日号](?![楼线])")
_WEEKDAY_AFTER = re.compile(r"^\s*[（(](?:周|星期|礼拜)([一二三四五六日天])[）)]")
_RANGE_START_CUE = re.compile(r"^\s*(?:[（(](?:周|星期|礼拜)[一二三四五六日天][）)])?\s*(?:那一?周|这一?周|当周|起|开始|以后|之后|至|到|—|–|-|~|～)")
_RANGE_END_CUE = re.compile(r"^\s*(?:[（(](?:周|星期|礼拜)[一二三四五六日天][）)])?\s*(?:之?前|以前|为止|截止|止)")
_RANGE_END_BEFORE = re.compile(r"(?:至|到|—|–|-|~|～|截止|截至)\s*$")
_RANGE_WORDS = re.compile(r"那一?周|这一?周|当周|之?前|以前|为止|截止|起|以后|之后|左右|前后|内|底")


def _to_date(iso: str) -> date | None:
    try:
        return date.fromisoformat(str(iso))
    except (TypeError, ValueError):
        return None


def grounding(items: dict, ids: list[str] | None = None) -> tuple[set[date], list[tuple[date, date]]]:
    """Dates the cited items (all items when ids is None) give: exact days (written, resolved, capture
    day) and ranges (下周 -> Monday..Sunday)."""
    exact: set[date] = set()
    ranges: list[tuple[date, date]] = []
    for i in (ids if ids is not None else list(items)):
        it = items.get(i) or {}
        text, at = str(it.get("text") or ""), it.get("captured_at")
        if not at:
            continue
        try:
            exact.add(_dates.to_local(at).date())
        except ValueError:
            continue
        for d in _dates.resolve(text, at):
            if _to_date(d["date"]):
                exact.add(_to_date(d["date"]))
        for m in _CARD_DATE.finditer(text):  # a written date beyond resolve()'s 8-entry cap
            try:
                exact.add(date(int(m.group(1)) if m.group(1) else _dates.to_local(at).year, int(m.group(2)), int(m.group(3))))
            except ValueError:
                pass
        for r in _dates.resolve_ranges(text, at):
            a, b = _to_date(r["from"]), _to_date(r["to"])
            if a and b:
                ranges.append((a, b))
                if r.get("edge") == "end":  # "月底前" / "7天内": the source names that day itself
                    exact.add(b)
                elif r.get("edge") == "start":  # "下个月起"
                    exact.add(a)
    return exact, ranges


def _ref_year(items: dict, ids: list[str] | None) -> int | None:
    days = [_capture_date(items, [i]) for i in (ids if ids is not None else list(items))]
    days = [d for d in days if d]
    return max(days).year if days else None


def card_dates(text: str, year: int) -> list[dict]:
    """Every M月D日 / N日 in a card text: {"start", "end", "date" (None for a day-only mention), "day",
    "weekday" (0-6 or None), "after", "before"}."""
    out = []
    spans = []
    for m in _CARD_DATE.finditer(text or ""):
        y = int(m.group(1)) if m.group(1) else year
        try:
            d = date(y, int(m.group(2)), int(m.group(3)))
        except ValueError:
            d = None
        spans.append((m.start(), m.end()))
        w = _WEEKDAY_AFTER.match(text[m.end():])
        out.append({"start": m.start(), "end": m.end(), "date": d, "day": int(m.group(3)), "said": m.group(0),
                    "weekday": _WD_INDEX.get(w.group(1)) if w else None, "after": text[m.end():m.end() + 8],
                    "before": text[max(0, m.start() - 3):m.start()]})
    for m in _CARD_DAY.finditer(text or ""):
        if any(a <= m.start() < b for a, b in spans):
            continue
        w = _WEEKDAY_AFTER.match(text[m.end():])
        out.append({"start": m.start(), "end": m.end(), "date": None, "day": int(m.group(1)), "said": m.group(0),
                    "weekday": _WD_INDEX.get(w.group(1)) if w else None, "after": text[m.end():m.end() + 8],
                    "before": text[max(0, m.start() - 3):m.start()]})
    return sorted(out, key=lambda x: x["start"])


_WD_INDEX = {"一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6}


def _mention_ok(m: dict, exact: set[date], ranges: list[tuple[date, date]]) -> bool:
    starts = {a for a, _ in ranges}
    ends = {b for _, b in ranges}
    as_start = bool(_RANGE_START_CUE.match(m["after"]))
    as_end = bool(_RANGE_END_CUE.match(m["after"])) or bool(_RANGE_END_BEFORE.search(m["before"]))
    if m["date"] is not None:
        cands = [m["date"]]
    else:  # a day-only mention ("29日前"): any grounded date with that day of the month
        cands = sorted({d for d in exact | starts | ends if d.day == m["day"]})
    for d in cands:
        if m["weekday"] is not None and d.weekday() != m["weekday"]:
            continue
        if d in exact or (d in starts and as_start) or (d in ends and as_end):
            return True
    return False


def ungrounded_dates(text: str, exact: set[date], ranges: list[tuple[date, date]], year: int) -> list[dict]:
    """The date mentions in text that the given grounding does not support (rule f)."""
    return [m for m in card_dates(text, year) if not _mention_ok(m, exact, ranges)]


def fact_date_ok(fact: dict, exact: set[date], ranges: list[tuple[date, date]]) -> bool:
    d = _to_date(fact.get("date"))
    if d is None:
        return True
    if d in exact:
        return True
    ends = {a for a, _ in ranges} | {b for _, b in ranges}
    return d in ends and bool(_RANGE_WORDS.search(str(fact.get("text", ""))))


def _mention_hint(m: dict, exact: set[date], ranges: list[tuple[date, date]]) -> str:
    d = m["date"]
    if d is not None and m["weekday"] is not None and d.weekday() != m["weekday"]:
        return f"星期写错了：{d.month}月{d.day}日是周{'一二三四五六日'[d.weekday()]}"
    return _range_hint(exact, ranges)


def _range_hint(exact: set[date], ranges: list[tuple[date, date]]) -> str:
    if not ranges:
        return "素材里没有这个日期；只写素材写了或 dates 换算出的日期，没有就不写日期"
    a, b = ranges[0]
    return (f"素材只给了一个范围（{a.month}月{a.day}日–{b.month}月{b.day}日）；写「{a.month}月{a.day}日那周」"
            f"或「{b.month}月{b.day}日前」，或者不写日期，不要挑其中某一天")


def provenance_errors(output: dict, context: dict) -> list[str]:
    """Rule f for a whole brief (needs context.items)."""
    items = context.get("items") or {}
    if not items:
        return []
    errs = []
    year = _ref_year(items, None) or date.today().year
    exact_all, ranges_all = grounding(items)
    line = str(output.get("status_line", ""))
    for m in ungrounded_dates(line, exact_all, ranges_all, year):
        errs.append(f"[ungrounded_date] status_line 里的「{m['said']}」不在任何素材里；{_mention_hint(m, exact_all, ranges_all)}")
        break
    for i, f in enumerate(output.get("status_facts") or []):
        if not isinstance(f, dict):
            continue
        ids = [r for r in f.get("item_ids") or [] if r in items]
        exact, ranges = grounding(items, ids)
        bad = ungrounded_dates(str(f.get("text", "")), exact, ranges, _ref_year(items, ids) or year)
        if bad:
            errs.append(f"[ungrounded_date] status_facts[{i}]「{f.get('text')}」里的「{bad[0]['said']}」不在它引用的素材里；"
                        f"{_mention_hint(bad[0], exact, ranges)}")
        elif not fact_date_ok(f, exact, ranges):
            errs.append(f"[ungrounded_date] status_facts[{i}] 的 date {f.get('date')} 不在它引用的素材里；"
                        f"{_range_hint(exact, ranges)}（没有就留空 \"\"）")
    return errs


_PLAN_OR_DONE = re.compile(r"已|了|过|完成|待|计划|约定|约好|定于|将|要|准备|打算|预计")


def drop_dates(text: str, bad: list[dict], keep_plan: bool = False) -> str:
    """Remove the given date mentions (with a bracketed weekday, 于/在 before and a relation word or clock
    time after). With keep_plan (the status line, which has no state field) a plan clause keeps its plan
    meaning: "9月29日修热水器" -> "待修热水器", "热水器9月29日修" -> "热水器待修"."""
    for m in sorted(bad, key=lambda x: -x["start"]):
        start, end = m["start"], m["end"]
        pre = re.search(r"(?:定于|于|在)\s*$", text[:start])
        if pre:
            start = pre.start()
        post = re.match(r"\s*(?:[（(](?:周|星期|礼拜)[一二三四五六日天][）)])?\s*(?:那一?周|之?前|以前|起|以后|之后|左右|前后)?"
                        r"(?:上午|下午|晚上|中午|早上)?(?:\d{1,2}[点:：]\d{0,2}分?半?)?", text[end:])
        end += post.end() if post else 0
        clause_start = max(text.rfind(c, 0, start) for c in "，,。；;、") + 1
        clause_end = min([p for p in (text.find(c, end) for c in "，,。；;、") if p >= 0] or [len(text)])
        clause = text[clause_start:start] + text[end:clause_end]
        at_start = not text[clause_start:start].strip()
        filler = "待" if keep_plan and not _PLAN_OR_DONE.search(clause) and (at_start or clause_end - end <= 3) else ""
        text = text[:start] + filler + text[end:]
    text = re.sub(r"[，,、；;]{2,}", "，", text)
    return re.sub(r"^[，,、；;：:\s]+|[，,、；;：:\s]+$", "", text).strip()


def fix_ungrounded(output: dict, context: dict) -> dict:
    """Drop every ungrounded date (rule f): from the status line and fact texts, and a fact's date field.
    A fact whose text is left under 2 characters is dropped."""
    items = context.get("items") or {}
    if not items or not isinstance(output, dict):
        return output
    year = _ref_year(items, None) or date.today().year
    exact_all, ranges_all = grounding(items)
    out = dict(output)
    line = str(out.get("status_line", ""))
    bad = ungrounded_dates(line, exact_all, ranges_all, year)
    if bad:
        out["status_line"] = drop_dates(line, bad, keep_plan=True)
    facts = []
    for f in out.get("status_facts") or []:
        if not isinstance(f, dict):
            continue
        ids = [r for r in f.get("item_ids") or [] if r in items]
        exact, ranges = grounding(items, ids)
        text = str(f.get("text", ""))
        bad = ungrounded_dates(text, exact, ranges, _ref_year(items, ids) or year)
        g = dict(f)
        if bad:
            g["text"] = drop_dates(text, bad)
        if not fact_date_ok(g, exact, ranges):
            g["date"] = ""
        if len(g["text"]) >= 2:
            facts.append(g)
    out["status_facts"] = facts
    return out


def _next_week_ok(context: dict) -> bool:
    """A bare 下周 in the card is true as of the card's time: a shown item says 下周 and that week is
    still the week after as_of."""
    items, as_of = context.get("items") or {}, context.get("as_of")
    if not items or not as_of:
        return False
    try:
        a = _dates.to_local(as_of).date()
    except ValueError:
        return False
    nxt = a - timedelta(days=a.weekday()) + timedelta(days=7)
    for it in items.values():
        for r in _dates.resolve_ranges(str(it.get("text") or ""), it.get("captured_at") or ""):
            if r["said"].startswith("下") and r["said"].endswith(("周", "星期", "礼拜")) and r["from"] == nxt.isoformat():
                return True
    return False


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    title = str(output.get("title", "")).strip()
    line = str(output.get("status_line", "")).strip()
    if not context.get("title_locked"):
        if not title:
            errors.append("[format] title is empty")
        elif title in GENERIC_TITLES:
            errors.append(f"[format] title {title!r} is a category, name the concrete matter")
        if "\n" in title:
            errors.append("[format] title must be one line")
        errors.extend(_relative_errors("title", title))
    if "\n" in line:
        errors.append("[format] status_line must be one line")
    inner = _SENTENCE_END.findall(line[:-1]) if line else []
    if inner:
        errors.append("[format] status_line must be exactly one sentence")
    if any(m in line for m in _META):
        errors.append("[format] status_line must state progress, not describe the event or count items")
    if line_width(line) > STATUS_MAX_WIDTH:
        errors.append(f"[length] status_line 太长（{line_width(line):g} 字宽，上限 {STATUS_MAX_WIDTH}，目标 {STATUS_TARGET_WIDTH}）："
                      "只写现在的状态或下一个有日期的步骤，金额、人名等细节放进 status_facts")
    known = set(context.get("item_ids", []))
    items = context.get("items") or {}
    next_week = _next_week_ok(context)
    facts = output.get("status_facts") or []
    if not facts:
        errors.append("[format] status_facts must not be empty")
    backed: set[str] = set()
    for i, fact in enumerate(facts):
        refs = fact.get("item_ids") or []
        if not refs:
            errors.append(f"[format] status_facts[{i}] cites no item")
        bad = [r for r in refs if known and r not in known]
        if bad:
            errors.append(f"[format] status_facts[{i}] cites unknown item ids {bad}")
        errors.extend(_relative_errors(f"status_facts[{i}]", str(fact.get("text", "")), next_week))
        if items:
            ferrs = check_fact_evidence(fact, items)
            errors.extend(ferrs)
            if not ferrs and fact.get("state") in ("done", "in_progress"):
                blob = str(fact.get("text", "")) + _norm(fact.get("quote", ""))
                fams = {f for f, words in FAMILIES.items() if any(w in blob for w in words)}
                if decision_only(fact.get("quote", "")):
                    fams -= PROCEDURAL  # a decision backs "已决定…", not "已签/已付/已发货"
                backed.update(fams)
    errors.extend(_relative_errors("status_line", line, next_week))
    if items:
        errors.extend(provenance_errors(output, context))
        for fam in claims(line):
            if fam not in backed:
                errors.append('[unsupported_completion] status_line 写了"已…"但没有被引用素材明确说已完成；'
                              '改写为"定于/计划…"，或补一条 state=done 且带原话 quote 的事实')
                break
    off = output.get("off_anchor_item_ids") or []
    bad_off = [r for r in off if known and r not in known]
    if bad_off:
        errors.append(f"[format] off_anchor_item_ids cites unknown item ids {bad_off}")
    if known and off and set(off) >= known:
        errors.append("[format] off_anchor_item_ids cannot list every item of the event")
    return errors


def salvage(output: dict, context: dict) -> dict | None:
    """For an invalid output (evidence / date / length errors are not retried; others after two attempts),
    keep what is individually valid instead of leaving the card stale.

    Returns {"title": str | None, "status_line": str | None, "status_facts": [...], "off_anchor_item_ids": [...]}
    with None for a part that must not be applied (the organizer keeps the previous value), or None if
    nothing is usable. Facts are kept one by one when they cite shown items and pass the evidence and
    relative-date rules (a done / in_progress fact without a supporting quote is kept as info if its text
    claims no completion); the status line only if all its checks pass with the kept facts. Ungrounded
    dates (rule f) are dropped first, so a fact or line that only invented a day is kept without it.
    """
    if not isinstance(output, dict) or not isinstance(output.get("status_facts"), list):
        return None
    known = set(context.get("item_ids", []))
    items = context.get("items") or {}
    next_week = _next_week_ok(context)
    output = fix_ungrounded(output, context)  # rule f: drop an invented date, keep the rest
    kept = []
    for fact in output["status_facts"]:
        if not isinstance(fact, dict):
            continue
        refs = fact.get("item_ids") or []
        if not refs or (known and not set(refs) <= known):
            continue
        if _relative_errors("fact", str(fact.get("text", "")), next_week):
            continue
        ferrs = check_fact_evidence(fact, items) if items else []
        if ferrs:
            # A done / in_progress fact whose quote does not show it happened: keep it as planned (its
            # quote states a plan or its date is after the evidence) or info ("集点和核销测试通过" quoting
            # "都正常") when its text claims no completion; else drop it.
            plan = any("计划或条件" in e or "晚于证据" in e for e in ferrs)
            retag = dict(fact, state="planned" if plan else "info", quote="")
            text = str(fact.get("text", ""))
            if fact.get("state") in ("done", "in_progress") and "已" not in text and not claims(text) \
                    and not check_fact_evidence(retag, items):
                kept.append(retag)
            continue
        kept.append(fact)
    placeholder = [{"text": "占位", "state": "info", "date": "", "quote": "", "item_ids": [next(iter(known), "")]}]
    line = str(output.get("status_line", "")).strip()
    if line_width(line) > STATUS_MAX_WIDTH:
        # Too long for the card: keep the leading clauses that fit (the line leads with the current
        # state or the next step), if they pass every other check on their own.
        line = _cut_line(line) or ""
    trial = dict(output, status_line=line, status_facts=kept or placeholder)
    errs = validate(trial, context)
    line_ok = bool(line) and not any("status_line" in e for e in errs)
    title_ok = not any("title" in e for e in errs)
    off = [r for r in output.get("off_anchor_item_ids") or [] if r in known]
    if not kept and not line_ok and not title_ok:
        return None
    return {"title": str(output.get("title", "")).strip() if title_ok else None,
            "status_line": line if line_ok else None,
            "status_facts": kept, "off_anchor_item_ids": off if len(off) < len(known) else []}


def main() -> int:
    output = json.load(open(sys.argv[1], encoding="utf-8"))
    context = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(output, context)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
