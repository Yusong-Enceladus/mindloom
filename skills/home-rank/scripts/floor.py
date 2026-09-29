#!/usr/bin/env python3
"""Deterministic floor applied after home-rank (stdlib only).

Rule: an event with an open follow-up dated within the next `window_days` days (a planned or
in_progress status fact whose date is today .. today + window_days) never ranks below an event that
has only info / past items: no open fact that is undated or dated today or later, and no upcoming
date in any of its items (`upcoming`; a card's 1-4 facts can miss a plan its items still mention). When the model scored
it at or below the best such event, it is lifted just above it; lifted events keep their relative
order. Feature-less events (the user asked to see less of them) and pinned events are left alone,
and pinned events do not set the floor (the app shows them first anyway).

apply_floor(ranking, events, today, window_days=7) -> (ranking, lifted)
  ranking: [{"event_id", "importance", "reason"}] (model output, event ids as in `events`)
  events:  {event_id: {"status_facts": [...], "upcoming": ["YYYY-MM-DD", ...], "feature_less": bool,
            "pinned": bool}}
  today:   "YYYY-MM-DD" in the organizer's clock
Returns a new ranking and the list of lifted event ids.

CLI: python floor.py input.json  where input = {"ranking": [...], "events": {...}, "today": "..."}
"""

from __future__ import annotations

import json
import sys
from datetime import date, timedelta

OPEN_STATES = ("planned", "in_progress")
STEP = 0.01


def _day(value) -> date | None:
    try:
        return date.fromisoformat(str(value or ""))
    except ValueError:
        return None


def next_followup(facts: list[dict], today: date, window_days: int) -> dict | None:
    """The earliest open fact dated within [today, today + window_days], or None."""
    end = today + timedelta(days=window_days)
    best = None
    for f in facts or []:
        d = _day(f.get("date"))
        if f.get("state") in OPEN_STATES and d is not None and today <= d <= end:
            if best is None or d < _day(best["date"]):
                best = f
    return best


def nothing_open(facts: list[dict], today: date, upcoming: list[str] = ()) -> bool:
    """Only info / done / cancelled facts, or plans whose date has passed, and no upcoming date in the
    event's items."""
    if any((_day(d) or date.min) >= today for d in upcoming or ()):
        return False
    for f in facts or []:
        if f.get("state") not in OPEN_STATES:
            continue
        d = _day(f.get("date"))
        if d is None or d >= today:
            return False
    return True


def apply_floor(ranking: list[dict], events: dict, today: str, window_days: int = 7) -> tuple[list[dict], list[str]]:
    t = _day(today)
    if t is None:
        return ranking, []
    imp = {r["event_id"]: float(r["importance"]) for r in ranking}
    closed = [imp[e] for e, v in events.items() if e in imp and not v.get("pinned") and not v.get("feature_less")
              and nothing_open(v.get("status_facts") or [], t, v.get("upcoming") or [])]
    if not closed:
        return ranking, []
    floor = max(closed)
    out, lifted = [], []
    for r in ranking:
        v = events.get(r["event_id"]) or {}
        f = None if v.get("feature_less") or v.get("pinned") else next_followup(v.get("status_facts") or [], t, window_days)
        if f is not None and imp[r["event_id"]] <= floor:
            new = min(1.0, round(floor + STEP + STEP * imp[r["event_id"]], 3))
            d = _day(f["date"])
            reason = f"{d.month}月{d.day}日还有待办：{f.get('text', '')}"[:30]
            out.append(dict(r, importance=new, reason=reason))
            lifted.append(r["event_id"])
        else:
            out.append(r)
    return out, lifted


def main() -> int:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    ranking, lifted = apply_floor(data["ranking"], data["events"], data["today"], int(data.get("window_days", 7)))
    json.dump({"ranking": ranking, "lifted": lifted}, sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
