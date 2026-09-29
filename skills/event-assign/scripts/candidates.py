#!/usr/bin/env python3
"""Deterministic candidate retrieval for event-assign (no model, stdlib only).

Score = 0.55 * cosine(item embedding, event centroid)
      + 0.20 * time proximity   exp(-gap_hours / 72), gap = distance to the event's time span
      + 0.15 * shared persons   |item persons ∩ event persons| / |item persons|, owner excluded
      + 0.10 * same source app

The owner (self_ids) is removed from both sides before the persons ratio: every dictation carries
the owner's voice, so counting it made every dictation "share a person" with every event that holds
one. An item whose only person is the owner gets a persons term of 0.

Decisions are honoured before scoring: deleted/merged events and events the user removed this
item from (forbidden) are never candidates. Ties are broken by the event's creation order (`order`,
its short handle number), never by a random id. Each candidate carries `margin` (its score minus the
next candidate's) for logging only; it is not a reliable signal to ask on.

CLI:  python candidates.py < input.json   where input = {"item": {...}, "events": [...],
      "forbidden": [...], "k": 5}; prints the ranked candidates as JSON.
"""

from __future__ import annotations

import json
import math
import operator
import sys
from typing import Iterable, Optional

WEIGHTS = {"similarity": 0.55, "time": 0.20, "persons": 0.15, "source": 0.10}
TIME_SCALE_HOURS = 72.0


def _norm(v: list[float]) -> float:
    return math.sqrt(sum(map(operator.mul, v, v)))


def cosine(a: Optional[list[float]], b: Optional[list[float]], na: Optional[float] = None,
           nb: Optional[float] = None) -> float:
    """Cosine similarity clipped at 0. na / nb: precomputed norms (a stream of items scored against
    hundreds of events computes each norm once)."""
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(map(operator.mul, a, b))
    na = _norm(a) if na is None else na
    nb = _norm(b) if nb is None else nb
    if na == 0 or nb == 0:
        return 0.0
    return max(0.0, dot / (na * nb))


def time_proximity(ts: float, first_ts: float, last_ts: float) -> float:
    if first_ts <= ts <= last_ts:
        gap = 0.0
    else:
        gap = min(abs(ts - first_ts), abs(ts - last_ts))
    return math.exp(-(gap / 3600.0) / TIME_SCALE_HOURS)


def rank_candidates(item: dict, events: Iterable[dict], forbidden: Iterable[str] = (), k: int = 5,
                    min_score: float = 0.0, self_ids: Iterable[str] = ()) -> list[dict]:
    """item: {embedding, ts, person_ids, source}; events: [{event_id, centroid, first_ts, last_ts,
    person_ids, sources, deleted, order}]. Returns up to k candidates, best first, ties broken by
    creation order."""
    banned = set(forbidden)
    selfs = set(self_ids)
    item_persons = set(item.get("person_ids") or []) - selfs
    q = item.get("embedding")
    qn = _norm(q) if q else None
    out = []
    for ev in events:
        if ev.get("deleted") or ev["event_id"] in banned:
            continue
        sim = cosine(q, ev.get("centroid"), qn, ev.get("centroid_norm"))
        tprox = time_proximity(item["ts"], ev["first_ts"], ev["last_ts"])
        shared = item_persons & (set(ev.get("person_ids") or []) - selfs)
        persons = len(shared) / len(item_persons) if item_persons else 0.0
        source = 1.0 if item.get("source") and item["source"] in set(ev.get("sources") or []) else 0.0
        score = (WEIGHTS["similarity"] * sim + WEIGHTS["time"] * tprox
                 + WEIGHTS["persons"] * persons + WEIGHTS["source"] * source)
        if score < min_score:
            continue
        out.append({
            "event_id": ev["event_id"],
            "score": round(score, 4),
            "similarity": round(sim, 4),
            "time": round(tprox, 4),
            "shared_persons": sorted(shared),
            "same_source": bool(source),
            "order": ev.get("order", 0),
        })
    out.sort(key=lambda c: (-c["score"], c["order"], c["event_id"]))
    out = out[:k]
    for i, c in enumerate(out):
        nxt = out[i + 1]["score"] if i + 1 < len(out) else 0.0
        c["margin"] = round(c["score"] - nxt, 4)
    return out


def main() -> int:
    data = json.load(sys.stdin)
    result = rank_candidates(data["item"], data.get("events", []), data.get("forbidden", []), int(data.get("k", 5)),
                             self_ids=data.get("self_ids", []))
    json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
