"""The organizer's source of model-visible and semantic time.

Wall-clock time must never leak into a prompt or into an ordering when a backlog of historical
items is replayed (an eval run, or the Mac flushing a queue after the optional link was off).

- WallClock: the live default. now() is datetime.now().
- ReplayClock: now() is the latest capture time observed so far (monotonic). Asking before any item
  was observed is an error, so a missing observe() cannot silently fall back to the wall clock.
- FixedClock: a constant, for tests.

Audit fields (items.received_at, runs, jobs, proposals) keep the wall clock on purpose; semantic
fields (events/event_items/questions/decisions/constraints/persons created_at) use this clock.
"""

from __future__ import annotations

import os
import threading
from datetime import datetime, timezone
from typing import Optional


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def wall_now() -> datetime:
    """Now in ORGANIZER_TZ (an IANA zone; default this host's zone), the zone UTC item stamps are read in."""
    name = os.environ.get("ORGANIZER_TZ", "").strip()
    if name:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo(name))
    return datetime.now(timezone.utc).astimezone()


class Clock:
    mode = "abstract"

    def now(self) -> datetime:
        raise NotImplementedError

    def now_iso(self) -> str:
        return _iso(self.now())

    def observe(self, iso: Optional[str]) -> None:
        """Called with each processed item's capture time. No-op for the wall clock."""


class WallClock(Clock):
    mode = "wall"

    def now(self) -> datetime:
        return wall_now()


class ReplayClock(Clock):
    mode = "replay"

    def __init__(self) -> None:
        self._latest: Optional[datetime] = None
        self._lock = threading.Lock()

    def observe(self, iso: Optional[str]) -> None:
        if not iso:
            return
        t = datetime.fromisoformat(iso)
        with self._lock:
            if self._latest is None or t > self._latest:
                self._latest = t

    def now(self) -> datetime:
        with self._lock:
            if self._latest is None:
                raise RuntimeError("replay clock read before any item was observed")
            return self._latest


class FixedClock(Clock):
    mode = "fixed"

    def __init__(self, iso: str) -> None:
        self._t = datetime.fromisoformat(iso)

    def set(self, iso: str) -> None:
        self._t = datetime.fromisoformat(iso)

    def now(self) -> datetime:
        return self._t


def from_setting(value: Optional[str]) -> Clock:
    value = (value or "wall").strip()
    if value == "wall":
        return WallClock()
    if value == "replay":
        return ReplayClock()
    if value.startswith("fixed:"):
        return FixedClock(value[len("fixed:"):])
    raise ValueError(f"unknown clock setting {value!r} (wall | replay | fixed:<ISO>)")
