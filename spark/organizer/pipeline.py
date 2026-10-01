"""Concurrent model calls with a deterministic outcome (contract D; ORGANIZER_WORKERS > 1).

Serial mode (workers = 1) organizes one item at a time: image-read / split / embedding, then
event-assign, then event-brief for every touched event, then the next item. Most of that time is spent
waiting on the model, and most of the calls do not depend on each other.

Pipeline mode keeps the part that must be ordered serial and runs the rest on a bounded thread pool:

  item-local work   image-read, item-split and the embedding of queued items depend only on the
                    item itself (stored per revision), so they are prefetched for the next few jobs in
                    queue order while earlier items are being assigned.
  assignment        event-assign, persons, questions and decisions stay on the worker thread, one item
                    at a time in queue order (started_at, item_id), exactly as in serial mode.
  briefs, rank      launched at a barrier and applied at a later barrier, in launch order.

Barriers are numbered by the item jobs processed (n). At barrier n, before assigning item n:
  1. wait for and apply every brief / rank launched at barrier <= n - lag (in launch order);
  2. launch a brief for every event marked needs_brief that has none in flight (snapshot taken now,
     i.e. reflecting the assignments of items < n) and, every rank_every_n_items items, one rank.
So the assignment of item n sees exactly the briefs launched up to barrier n - lag: which results it
sees depends only on the order of the queue, never on how fast a thread finished. The same queue gives
the same events, titles and questions for any pool size (the pool size changes only the speed); only
the lag changes semantics (lag = 2 by default: an assignment does not wait for the briefs of the two
items before it). A brief whose event only grew meanwhile is kept and the event is briefed again; one
whose items were removed or revised meanwhile is discarded (brief_apply), as in serial mode.

When the queue is empty everything in flight is applied, remaining briefs run (concurrently) and the
home rank runs, so an idle organizer ends in the same state as serial processing of the same briefs.
"""

from __future__ import annotations

import logging
import time
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Optional

from .clients import ModelUnavailable, safe_error

log = logging.getLogger("organizer.pipeline")


@dataclass
class _Pending:
    kind: str            # "brief" | "rank"
    barrier: int
    key: str             # event_id or "home"
    ctx: dict
    future: Future


class Pipeline:
    def __init__(self, org: Any, workers: int, lag: int = 2, prefetch_ahead: Optional[int] = None):
        self.org = org
        self.workers = max(1, int(workers))
        self.lag = max(1, int(lag))
        self.prefetch_ahead = prefetch_ahead if prefetch_ahead is not None else self.workers * 2
        self.pool = ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix="organizer-model")
        self.n = 0
        self.pending: deque[_Pending] = deque()
        self.inflight: dict[str, int] = {}
        self.rank_inflight = False
        self.prefetched: dict[tuple[str, int], Future] = {}

    # ---- the worker's unit of work ----------------------------------------------------

    def step(self) -> bool:
        org = self.org
        job = org.store.claim_next_job()
        if job:
            self._prefetch(job)
            self.n += 1
            self._apply_due(self.n - self.lag)
            self._launch_briefs()
            fut = self.prefetched.pop((job["item_id"], job["revision"]), None)
            if fut is not None:
                fut.result()  # never raises: prefetch failures are redone inline by process_item
            org._run_job(job)
            if org.consolidator.due():
                # Every N items, at this barrier: its calls run on the pool, results are applied in order.
                org.consolidator.run(pool=self.pool)
            if org.people_pass.due():
                org.people_pass.run(pool=self.pool)
            return True
        # Idle: settle everything, then brief what is left (concurrently), consolidate, and rank.
        if self.pending:
            self._apply_due(None)
            return True
        if self._launch_briefs():
            self._apply_due(None)
            return True
        if org.consolidator.idle_due():
            org.consolidator.run(pool=self.pool)
            return True
        if org.people_pass.idle_due():
            org.people_pass.run(pool=self.pool)
            return True
        if org._rank_dirty or org._day_changed():
            org.rank()
            return True
        org._expire_questions()
        return False

    def launch_rank(self) -> None:
        """Called every rank_every_n_items items. One rank at a time; if one is in flight the next one
        waits for the idle rank (the flag stays dirty)."""
        if self.rank_inflight:
            self.org._rank_dirty = True
            return
        ctx = self.org.rank_prepare()
        if ctx is None:
            return
        self.rank_inflight = True
        self.pending.append(_Pending("rank", self.n, "home", ctx, self.pool.submit(self._in_session(self.org.rank_call), ctx)))

    def reset(self) -> None:
        """Forget the work of a previous unlock session (after a lock). Results still being computed are
        dropped when they finish; events keep needs_brief=1 in the store, so their briefs run again."""
        self.pending.clear()
        self.inflight.clear()
        self.prefetched.clear()
        self.rank_inflight = False

    def shutdown(self) -> None:
        self.pool.shutdown(wait=False, cancel_futures=True)

    # ---- internals ------------------------------------------------------------------

    def _in_session(self, fn):
        """fn bound, on its pool thread, to the unlock session it was launched in: a call that returns after a
        lock or a wipe writes nothing into the store (Organizer.in_session, Store.bind)."""
        return self.org.in_session(fn)

    def _prefetch(self, current: dict) -> None:
        store = self.org.store
        queued = store.all("SELECT item_id, revision FROM jobs WHERE state='queued' AND not_before <= ?"
                           " ORDER BY started_ts, item_id LIMIT ?", (time.time(), self.prefetch_ahead))
        wanted = [(current["item_id"], current["revision"])] + [(r["item_id"], r["revision"]) for r in queued]
        for key in wanted:
            if key not in self.prefetched:
                self.prefetched[key] = self.pool.submit(self._in_session(self.org.prefetch), *key)
        if len(self.prefetched) > 4 * self.prefetch_ahead + 8:
            keep = set(wanted)
            for key in [k for k, f in self.prefetched.items() if k not in keep and f.done()]:
                del self.prefetched[key]

    def _launch_briefs(self) -> int:
        store = self.org.store
        rows = store.all("SELECT event_id FROM events WHERE needs_brief=1 AND deleted=0 ORDER BY handle")
        launched = 0
        for row in rows:
            event_id = row["event_id"]
            if event_id in self.inflight:
                continue
            ctx = self.org.brief_prepare(event_id)
            if ctx is None:
                continue
            self.inflight[event_id] = self.n
            self.pending.append(_Pending("brief", self.n, event_id, ctx, self.pool.submit(self._in_session(self.org.brief_call), ctx)))
            launched += 1
        return launched

    def _apply_due(self, limit: Optional[int]) -> None:
        while self.pending and (limit is None or self.pending[0].barrier <= limit):
            p = self.pending.popleft()
            try:
                res = p.future.result()
            except ModelUnavailable:
                self._settled(p)
                raise  # the event keeps needs_brief=1 (or the rank stays dirty); the worker backs off
            except Exception as exc:  # recorded in runs by the harness; do not retry forever
                log.warning("%s for %s failed: %s", p.kind, p.key, safe_error(exc))
                self._settled(p)
                if p.kind == "brief":
                    self.org.store.update_event(p.key, needs_brief=0)
                continue
            self._settled(p)
            if p.kind == "brief":
                self.org.brief_apply(p.ctx, res, accept_growth=True)
            else:
                self.org.rank_apply(p.ctx, res)

    def _settled(self, p: _Pending) -> None:
        if p.kind == "brief":
            if self.inflight.get(p.key) == p.barrier:
                del self.inflight[p.key]
        else:
            self.rank_inflight = False
            if p.future.exception() is not None:
                self.org._rank_dirty = True
