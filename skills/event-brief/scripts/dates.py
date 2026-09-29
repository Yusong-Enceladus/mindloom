#!/usr/bin/env python3
"""Deterministic relative-date resolver for event-brief input (stdlib only).

resolve(text, captured_at) -> [{"said": "下周二", "date": "2026-09-22"}, ...]

Resolved against the item's own capture time, never "now": a line written days later must still
turn 明天 in a 9/18 message into 9/19. Only unambiguous forms are resolved; anything else is left to
the model (and the brief must then not invent a date).

  今天/今日 明天/明日 后天 大后天 昨天 前天
  下周X / 下星期X        weekday X of the next calendar week (weeks start on Monday)
  本周X / 这周X          weekday X of the capture week
  上周X                  weekday X of the previous week
  周X / 星期X / 礼拜X     the next such weekday on or after the capture day
  N号 / N日              day N of the capture month, or of the next month if N is before the capture day
  M月N日 / M月N号        that date in the capture year

resolve_ranges(text, captured_at) -> [{"said": "下周", "from": "2026-09-28", "to": "2026-10-04"}, ...]

A phrase that names a span, not a day, becomes a range, so a brief can say "9月28日那周" or
"10月4日前" instead of picking a day the source never gave:

  下周 / 下星期 (no weekday after it)   Monday..Sunday of the next week
  这周 / 本周 (no weekday after it)     the capture day..Sunday of the capture week
  周末 / 这周末 / 本周末                Saturday..Sunday of the capture week
  下周末                                Saturday..Sunday of the next week
  下个月 / 下月                         the whole next month
  月底 / 这个月底 / M月底               the last 7 days of that month (the capture month, or M)
  下个月底                              the last 7 days of the next month
  N天内                                 the capture day..N days later
  N个工作日 / M-N个工作日                the capture day..N working days later (Mon-Fri)

An entry has "edge": "end" / "start" when the text itself names that end ("月底前", "下个月起",
"7天内"); that day is then as good as written.

format_captured(iso) -> "2026-03-05 周四 09:10"

Local time: an item's own non-UTC offset is the capturing device's wall clock and is kept. A UTC
stamp ("Z" / +00:00) or a naive one carries no wall clock, so it is read in ORGANIZER_TZ (an IANA
zone name; default: this host's zone). Without this, a Mac that sends UTC would have 明天 in a
07:30 (UTC+8) dictation resolved against the previous day.

CLI: python dates.py "下周一开工" 2026-03-05T09:10:00+08:00 [--ranges]
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import date, datetime, timedelta, tzinfo

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None  # type: ignore[assignment]

WEEKDAYS = "一二三四五六日"
_WD = {"一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6}
_CN = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_NUM = r"(\d{1,2}|[一二三四五六七八九十]{1,3})"


def _num(s: str) -> int | None:
    if s.isdigit():
        return int(s)
    if s == "十":
        return 10
    if s.startswith("十"):
        return 10 + _CN.get(s[1:], 0) if len(s) == 2 else None
    if len(s) == 1:
        return _CN.get(s)
    if len(s) == 2 and s[1] == "十":
        return _CN.get(s[0], 0) * 10
    if len(s) == 3 and s[1] == "十":
        return _CN.get(s[0], 0) * 10 + _CN.get(s[2], 0)
    return None


def _zone() -> tzinfo | None:
    name = os.environ.get("ORGANIZER_TZ", "").strip()
    return ZoneInfo(name) if name and ZoneInfo is not None else None


def to_local(value: str | datetime) -> datetime:
    """The item's wall-clock time (see the module docstring)."""
    t = value if isinstance(value, datetime) else datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if t.tzinfo is None:
        zone = _zone()
        return t.replace(tzinfo=zone) if zone is not None else t.astimezone()
    if t.utcoffset() == timedelta(0):
        return t.astimezone(_zone())
    return t


def local_iso(value: str | datetime) -> str:
    return to_local(value).isoformat(timespec="seconds")


def format_captured(iso: str) -> str:
    t = to_local(iso)
    return f"{t:%Y-%m-%d} 周{WEEKDAYS[t.weekday()]} {t:%H:%M}"


def _add_month(d: date, day: int) -> date | None:
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    try:
        return date(y, m, day)
    except ValueError:
        return None


_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"大后天"), "d+3"),
    (re.compile(r"(?<!大)后天"), "d+2"),
    (re.compile(r"今天|今日|今晚|今早"), "d+0"),
    (re.compile(r"明天|明日|明早|明晚"), "d+1"),
    (re.compile(r"昨天|昨日|昨晚"), "d-1"),
    (re.compile(r"前天"), "d-2"),
    (re.compile(_NUM + r"月" + _NUM + r"[日号]"), "month_day"),
    (re.compile(r"(?<![月\d里路街巷弄楼栋室第期])" + _NUM + r"[号日](?![楼线])"), "day"),
    (re.compile(r"下(?:个)?(?:周|星期|礼拜)([一二三四五六日天])"), "next_week"),
    (re.compile(r"(?:本|这个?)(?:周|星期|礼拜)([一二三四五六日天])"), "this_week"),
    (re.compile(r"上(?:个)?(?:周|星期|礼拜)([一二三四五六日天])"), "last_week"),
    (re.compile(r"(?<![下本这上每个])(?:周|星期|礼拜)([一二三四五六日天])"), "weekday"),
]


def resolve(text: str, captured_at: str) -> list[dict]:
    if not text or not captured_at:
        return []
    d = to_local(captured_at).date()
    monday = d - timedelta(days=d.weekday())
    found: list[tuple[int, str, date]] = []
    taken: list[tuple[int, int]] = []
    for pattern, kind in _PATTERNS:
        for m in pattern.finditer(text):
            if any(a < m.end() and m.start() < b for a, b in taken):
                continue  # already covered by a more specific form (下周二 before 周二)
            if kind == "weekday" and any(0 <= m.start() - b <= 1 for _, b in taken):
                continue  # "3月12号周四" / "3月12日（周四）": the weekday only annotates that date
            target: date | None = None
            if kind.startswith("d") and kind[1] in "+-":
                target = d + timedelta(days=int(kind[1:]))
            elif kind in ("next_week", "this_week", "last_week"):
                offset = {"next_week": 7, "this_week": 0, "last_week": -7}[kind]
                target = monday + timedelta(days=offset + _WD[m.group(1)])
            elif kind == "weekday":
                target = d + timedelta(days=(_WD[m.group(1)] - d.weekday()) % 7)
            elif kind == "month_day":
                mo, dy = _num(m.group(1)), _num(m.group(2))
                if mo and dy and 1 <= mo <= 12:
                    try:
                        target = date(d.year, mo, dy)
                    except ValueError:
                        target = None
            elif kind == "day":
                dy = _num(m.group(1))
                if dy and 1 <= dy <= 31:
                    if dy >= d.day:
                        try:
                            target = date(d.year, d.month, dy)
                        except ValueError:
                            target = None
                    else:
                        target = _add_month(d, dy)
            if target is not None:
                taken.append((m.start(), m.end()))
                found.append((m.start(), m.group(0), target))
    out, seen = [], set()
    for _, said, target in sorted(found):
        key = (said, target.isoformat())
        if key not in seen:
            seen.add(key)
            out.append({"said": said, "date": target.isoformat()})
    return out[:8]


def _month_end(y: int, m: int) -> date:
    return (date(y + 1, 1, 1) if m == 12 else date(y, m + 1, 1)) - timedelta(days=1)


_WEEK = r"(?:周|星期|礼拜)"
_RANGE_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"下(?:个)?" + _WEEK + r"末"), "next_weekend"),
    (re.compile(r"(?:这个?|本)?" + _WEEK + r"末"), "weekend"),
    (re.compile(r"下(?:个)?" + _WEEK + r"(?![一二三四五六日天末])"), "next_week"),
    (re.compile(r"(?:这个?|本)" + _WEEK + r"(?![一二三四五六日天末])"), "this_week"),
    (re.compile(r"下(?:个)?月底"), "next_month_end"),
    (re.compile(_NUM + r"月底"), "month_end_of"),
    (re.compile(r"(?<![上下\d月])(?:这个?|本)?月底"), "month_end"),
    (re.compile(r"下(?:个)?月(?![底初中\d一二三四五六七八九十])"), "next_month"),
    (re.compile(r"(?:\d{1,2}\s*[-~～到至]\s*)?(\d{1,2}|[一二两三四五六七八九十]{1,3})\s*个?工作日"), "workdays"),
    (re.compile(r"(\d{1,2}|[一二两三四五六七八九十]{1,3})\s*(?:天|日)(?:之)?内"), "days_within"),
]
_EDGE_END = re.compile(r"^(?:之?内|之?前|以前|为止)")
_EDGE_START = re.compile(r"^(?:起|开始|以后|之后)")


def _add_workdays(d: date, n: int) -> date:
    while n > 0:
        d += timedelta(days=1)
        if d.weekday() < 5:
            n -= 1
    return d


def resolve_ranges(text: str, captured_at: str) -> list[dict]:
    """Spans (not days) named in text, against the item's own capture time. See the module docstring."""
    if not text or not captured_at:
        return []
    d = to_local(captured_at).date()
    monday = d - timedelta(days=d.weekday())
    ny, nm = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    found: list[tuple[int, str, date, date, str]] = []
    taken: list[tuple[int, int]] = []
    for pattern, kind in _RANGE_PATTERNS:
        for m in pattern.finditer(text):
            if any(a < m.end() and m.start() < b for a, b in taken):
                continue
            if kind == "next_weekend":
                a, b = monday + timedelta(days=12), monday + timedelta(days=13)
            elif kind == "weekend":
                a, b = monday + timedelta(days=5), monday + timedelta(days=6)
            elif kind == "next_week":
                a, b = monday + timedelta(days=7), monday + timedelta(days=13)
            elif kind == "this_week":
                a, b = d, monday + timedelta(days=6)
            elif kind == "next_month":
                a, b = date(ny, nm, 1), _month_end(ny, nm)
            elif kind == "next_month_end":
                b = _month_end(ny, nm)
                a = b - timedelta(days=6)
            elif kind == "month_end_of":
                mo = _num(m.group(1))
                if not mo or not 1 <= mo <= 12:
                    continue
                b = _month_end(d.year, mo)
                a = b - timedelta(days=6)
            elif kind in ("workdays", "days_within"):
                n = _num(m.group(1))
                if not n or n > 60:
                    continue
                a = d
                b = _add_workdays(d, n) if kind == "workdays" else d + timedelta(days=n)
            else:  # month_end
                b = _month_end(d.year, d.month)
                a = b - timedelta(days=6)
            rest = text[m.end():]
            edge = "end" if kind == "days_within" or _EDGE_END.match(rest) else \
                "start" if _EDGE_START.match(rest) else ""
            taken.append((m.start(), m.end()))
            found.append((m.start(), m.group(0), a, b, edge))
    out, seen = [], set()
    for _, said, a, b, edge in sorted(found):
        key = (said, a.isoformat(), b.isoformat())
        if key not in seen:
            seen.add(key)
            r = {"said": said, "from": a.isoformat(), "to": b.isoformat()}
            if edge:
                r["edge"] = edge  # the source itself names that end ("月底前", "下个月起", "7天内")
            out.append(r)
    return out[:4]


def main() -> int:
    if len(sys.argv) > 3 and sys.argv[3] == "--ranges":
        json.dump(resolve_ranges(sys.argv[1], sys.argv[2]), sys.stdout, ensure_ascii=False)
        print()
        return 0
    json.dump(resolve(sys.argv[1], sys.argv[2]), sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
