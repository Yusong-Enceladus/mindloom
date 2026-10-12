#!/usr/bin/env python3
"""Deterministic planning for the consolidation pass (no model, stdlib only).

plan(events, checks, apart, **budget) picks
  * the matter directory: the `directory_size` largest live events with at least `directory_min_items`
    items (ties by creation order), shown to the model in creation order. It is fixed for the whole pass,
    so every call in a pass starts with the same prompt prefix (the model server's prefix cache reuses it);
  * the subjects: events small enough to be judged (<= subject_max_items items), not protected by a user
    decision, smallest first, each with its `nearest` events (embedding centroid cosine, any size) and the
    events it may be merged with (`targets`): every directory event plus its nearest events outside the
    directory. The organizer keeps the larger event of a merged pair, so a target may also be smaller than
    the subject (the subject's twin that is still a fragment). An event of detail_min_items or more may only
    be merged with one of its `detail_targets` nearest events, which the model then sees with their items
    ("detail"): joining two sizeable events needs evidence from both. An event of twin_min_items or more
    only joins an event at most twin_max_ratio times its size (or smaller). A pair the user kept apart is
    never a target. An event with nothing to merge with is still judged when it is small enough to go back to
    Unfiled (a first item that is only a pickup code).

A subject is judged once, and again only when it matters: it doubled in size since its last check, a possible
home (an event of 3+ items, at least its size) entered its `near_watch` nearest, a home it already had next to it
grew (it doubled and holds `grow_min` items or more), or the last check was dropped as stale (the store changed while
the model was thinking) or invalid (the model's output failed validation twice: nothing was decided). No event is
judged more than `max_checks` times. At most `max_calls` subjects per pass.

Sweep (`sweep=True`, the organizer runs it once the queue has drained and nothing else is eligible): every event of
`sweep_max_items` items or fewer that was judged before, kept or skipped, not swept yet and judged at least `sweep_gap`
items ago (`total_items` now, `checks[...]["at_items"]` then) is judged once more against the directory as it is now.
A fragment that was judged when its matter was still one or two items long is otherwise never looked at again.
`checks[...]["swept"]` marks the events already swept.

Input event dict: {event_id, order (creation number), n (items), centroid (list|None), protected (bool)}.
checks: {event_id: {n_items, near: [event_id...], near_n: {event_id: items}, outcome, n_checks, swept, at_items}}.

CLI: python directory.py < input.json   (input = {"events": [...], "checks": {...}, "apart": [[a, b]...]})
"""

from __future__ import annotations

import json
import math
import operator
import sys
from typing import Iterable, Optional


def _unit(v: Optional[list[float]]) -> Optional[list[float]]:
    if not v:
        return None
    n = math.sqrt(sum(map(operator.mul, v, v)))
    return [x / n for x in v] if n else None


def _larger(x: dict, y: dict) -> bool:
    """y may absorb x: more items, or as many and created earlier."""
    return y["n"] > x["n"] or (y["n"] == x["n"] and y["order"] < x["order"])


def eligible(x: dict, nearest: list[str], check: Optional[dict], max_checks: int,
             size: Optional[dict] = None, *, near_watch: int = 3, grow_min: int = 0, sweep: bool = False,
             sweep_max_items: int = 6, total_items: int = 0, sweep_gap: int = 100) -> bool:
    """Judged before: again only if it doubled, went stale or invalid, a possible home for it (an event of at least
    3 items and at least its own size) entered its `near_watch` nearest, or (grow_min > 0) a home it had next to it
    doubled and holds grow_min items or more. Another new fragment next to it does not count: that fragment is
    judged itself, with this event among its targets. In a sweep, a small event judged before and not yet swept."""
    if check is None:
        return True
    if int(check.get("n_checks") or 0) >= max_checks:
        return False
    if check.get("outcome") in ("stale", "invalid"):
        return True
    if x["n"] >= 2 * max(1, int(check.get("n_items") or 0)):
        return True
    known = set(check.get("near") or [])
    size = size or {}
    if any(h not in known and size.get(h, 0) >= max(3, x["n"]) for h in nearest[:near_watch]):
        return True
    if grow_min > 0:
        then = check.get("near_n") or {}
        if any(h in known and size.get(h, 0) >= grow_min and size.get(h, 0) >= 2 * max(1, int(then.get(h) or 0))
               and size.get(h, 0) >= x["n"] for h in nearest[:near_watch]):
            return True
    return bool(sweep and x["n"] <= sweep_max_items and not check.get("swept")
                and check.get("outcome") in ("kept", "skipped")
                and total_items - int(check.get("at_items") or 0) >= sweep_gap)


def plan(events: Iterable[dict], checks: Optional[dict] = None, apart: Iterable = (), *, max_calls: int = 40,
         subject_max_items: int = 120, unfile_max_items: int = 9, directory_size: int = 32,
         directory_min_items: int = 3, nearest_k: int = 4, max_checks: int = 4, detail_min_items: int = 10,
         detail_targets: int = 3, twin_min_items: int = 20, twin_max_ratio: float = 4.0, near_watch: int = 3,
         grow_min: int = 0, sweep: bool = False, sweep_max_items: int = 6, total_items: int = 0,
         sweep_gap: int = 100) -> dict:
    checks = checks or {}
    evs = [dict(e) for e in events if e.get("n", 0) > 0]
    for e in evs:
        e["_u"] = _unit(e.get("centroid"))
    apart_set = {tuple(sorted(p)) for p in apart}
    by_size = sorted(evs, key=lambda e: (-e["n"], e["order"]))
    directory = [e for e in by_size if e["n"] >= directory_min_items][:directory_size]
    dir_order = [e["event_id"] for e in sorted(directory, key=lambda e: e["order"])]
    subjects = []
    waiting = 0
    for x in sorted((e for e in evs if not e.get("protected") and e["n"] <= subject_max_items),
                    key=lambda e: (e["n"], e["order"])):
        others = [y for y in evs if y is not x and tuple(sorted((x["event_id"], y["event_id"]))) not in apart_set]
        can_unfile = x["n"] <= unfile_max_items
        if not others and not can_unfile:
            continue  # nothing to merge with and too big to unfile: nothing to decide
        if x["_u"] is not None:
            def sim(y: dict) -> float:
                return sum(map(operator.mul, x["_u"], y["_u"])) if y["_u"] else -1.0  # no centroid: last
            sims = sorted(others, key=lambda y: (-sim(y), -y["n"], y["order"]))
        else:
            sims = sorted(others, key=lambda y: (-y["n"], y["order"]))
        nearest = [y["event_id"] for y in sims[:nearest_k]]
        if not eligible(x, nearest, checks.get(x["event_id"]), max_checks, {y["event_id"]: y["n"] for y in others},
                        near_watch=near_watch, grow_min=grow_min, sweep=sweep, sweep_max_items=sweep_max_items,
                        total_items=total_items, sweep_gap=sweep_gap):
            continue
        if len(subjects) >= max_calls:
            waiting += 1
            continue
        allowed = {y["event_id"] for y in others}
        if x["n"] >= detail_min_items:
            # A sizeable event is merged only with one of its nearest few, shown with their items. An established
            # event (twin_min_items or more) only joins an event of comparable size: a sizeable workstream next to
            # an event many times larger is the part-of pattern (a demo, a ticket, an interface of a big project),
            # and absorbing it would bury its own card.
            size = {y["event_id"]: y["n"] for y in others}
            targets = [h for h in nearest[:detail_targets]
                       if min(size[h], x["n"]) < twin_min_items
                       or max(size[h], x["n"]) <= twin_max_ratio * min(size[h], x["n"])]
            extra = list(targets)
        else:
            extra = [h for h in nearest if h not in dir_order]
            targets = [h for h in dir_order if h in allowed] + extra
        subjects.append({"event_id": x["event_id"], "n": x["n"], "nearest": nearest, "targets": targets,
                         "extra": extra, "can_unfile": can_unfile, "detail": x["n"] >= detail_min_items,
                         "near_n": {h: next(y["n"] for y in others if y["event_id"] == h) for h in nearest},
                         "sweep": bool(sweep and checks.get(x["event_id"]) is not None)})
    return {"directory": dir_order, "subjects": subjects, "waiting": waiting}


def main() -> int:
    data = json.load(sys.stdin)
    print(json.dumps(plan(data["events"], data.get("checks"), data.get("apart", [])), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
