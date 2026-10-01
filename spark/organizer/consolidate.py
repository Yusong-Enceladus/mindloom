"""Consolidation pass: merge fragment events into the matter they belong to, and put non-matters back
into Unfiled (skill event-consolidate).

The organizer files one item at a time, so the first items of a matter often seed events of their own
before the matter's main event is found, and a chat line, an ad or a pickup code can become a one-item
event. At scale (1,500-1,600 items a week) this left 11-17 times as many events as matters. Questions
cannot fix it: the question budget is small and during a backfill nobody answers.

Schedule and budget (the organizer's scheduler calls this; no user action):
  * every `every_items` processed item jobs (at an item barrier, in pipeline mode), and
  * when the queue is empty (idle): after `idle_min_items` new items, after `idle_after_s` without a new item,
    or straight after a pass that merged or unfiled something (and on a fresh start), while events remain
    eligible;
  * at most `max_calls` events judged per pass (plus one second-look call per merge that needs it); in
    pipeline mode the calls run on the model pool.

Per pass (skills/event-consolidate/scripts/directory.py is the deterministic part):
  1. the matter directory = the largest live events (fixed for the pass, shown in creation order);
  2. subjects = unprotected events with <= subject_max_items items, smallest first, each judged once and
     again only after it doubled, gained a new nearest neighbour or went stale (max_checks in all);
  3. event-consolidate names the most similar matter (candidate), says how the small event relates to it
     (same / part / related / none) and decides merge (only `same`, quoting a line grounded in the target) /
     own_matter / not_matter (only for events of <= unfile_max_items items); a merge of an event of 10+
     items, or of two events that both hold 3+ items, is asked a second time with only the chosen event
     beside it (more of its items, no directory) and applied only if the model says merge again; two
     events of 10+ items each are joined only if their titles/anchors share two content words;
  4. results are applied in subject order, each re-checked against the store under its lock:
     merge -> the smaller event's items move to the larger one as model placements and the smaller event
     is deleted with merged_into (the Mac follows it exactly as after a user merge), the kept event is
     re-briefed;
     not_matter -> its items go to Unfiled (reason "none", as when event-assign finds no matter) and the
     event is deleted; own_matter -> nothing changes. Every verdict is recorded (proposals kind
     'consolidate', table consolidate_checks).

User decisions always win: an event whose title the user edited, that is pinned, or that holds an item a
user placed is never merged away or unfiled; a pair the user kept apart is never merged; an item the user
removed from the target keeps the small event where it is. A subject that changed during the model call
is dropped (stale) and judged again next pass, unless the only change was another fragment merged into it
by this same pass.

Privacy (docs/PRIVACY.md): a pass runs only while the store is unlocked, inside the worker's step, and every
model call on the pool is bound to the unlock session it was planned in (Organizer.in_session): after a lock,
or a wipe and an unlock with a new key, nothing of it is written. Each call records the items whose text its
input holds (the subject's items, the target's items, the directory samples), so deleting any of them clears
the run and its proposals. consolidate_checks holds event ids, counts and outcomes only; a purge drops the
rows of the events the deleted item was in. The in-memory event views (titles, samples) are dropped on lock.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Optional

from .clients import ModelUnavailable, safe_error
from .store import StoreLocked

log = logging.getLogger("organizer.consolidate")

ITEM_CHARS = 360
SMALL_ITEMS_SHOWN = 8
SAMPLE_CHARS = 60
DETAIL_ITEMS = 4
DETAIL_CHARS = 160
CONFIRM_ITEMS = 6
CONFIRM_BOTH_MIN = 3
NAME_CHECK_MIN = 10
DIRECTORY_PERSONS = 3


def _excerpt(text: str, limit: int) -> str:
    text = (text or "").strip().replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


class Consolidator:
    def __init__(self, org: Any, *, enabled: bool = True, every_items: int = 25, max_calls: int = 40,
                 subject_max_items: int = 120, unfile_max_items: int = 9, directory_size: int = 32,
                 directory_min_items: int = 3, nearest_k: int = 4, max_checks: int = 4, detail_min_items: int = 10,
                 idle_min_items: int = 5, idle_after_s: float = 300.0):
        self.org = org
        self.enabled = enabled
        self.every_items = max(1, int(every_items))
        self.budget = {"max_calls": max(1, int(max_calls)), "subject_max_items": int(subject_max_items),
                       "unfile_max_items": int(unfile_max_items), "directory_size": int(directory_size),
                       "directory_min_items": int(directory_min_items), "nearest_k": int(nearest_k),
                       "max_checks": int(max_checks), "detail_min_items": int(detail_min_items)}
        self.jobs_since = 0
        # Idle passes: after idle_min_items new items, after idle_after_s without a new item, or straight after a
        # pass that changed something (its merges give the remaining events new neighbours). A fresh start counts
        # as the latter, so a store built before this pass existed is tidied as soon as the organizer is idle.
        self.idle_min_items = max(1, int(idle_min_items))
        self.idle_after_s = float(idle_after_s)
        self._followup = True
        self._last_job_t = time.monotonic()
        self._idle_cursor: Optional[int] = None
        self._pending: Optional[tuple[int, dict]] = None
        self._more = False
        self._view_cache: dict[str, tuple] = {}
        self._plan = org.registry.script("event-consolidate", "directory")
        self.stats = {"passes": 0, "calls": 0, "merged": 0, "unfiled": 0, "kept": 0, "stale": 0, "invalid": 0,
                      "skipped": 0}

    # ---- scheduling ---------------------------------------------------------------------

    def note_job(self) -> None:
        self.jobs_since += 1
        self._last_job_t = time.monotonic()

    def due(self) -> bool:
        """Periodic trigger: every `every_items` processed item jobs."""
        return self.enabled and self.jobs_since >= self.every_items

    def idle_due(self) -> bool:
        """Idle trigger: the queue is empty and some event is eligible. Planning is skipped while the store
        has not changed since the last empty plan, so an idle worker polling every second costs nothing."""
        if not self.enabled:
            return False
        cursor = self.org.store.cursor()
        if cursor == self._idle_cursor and not self._more:
            return False
        if not (self._followup or self._more or self.jobs_since >= self.idle_min_items
                or time.monotonic() - self._last_job_t >= self.idle_after_s):
            return False
        plan = self.plan()
        if not plan["subjects"]:
            self._idle_cursor, self._more = cursor, False
            return False
        self._pending = (cursor, plan)
        return True

    def reset(self) -> None:
        """A lock, a wipe or a new unlock session: drop what this pass holds in memory (event views quote titles
        and item openings) and plan afresh when the store is next open."""
        self._view_cache = {}
        self._pending = None
        self._idle_cursor = None
        self._more = False
        self._followup = True

    def run(self, pool=None) -> dict:
        """One pass. The model being down propagates (the worker backs off; the pass stays due), and so does the
        store being locked (the step ends; nothing of it is written); any other failure is logged by type and
        never stops item processing."""
        self.jobs_since = 0
        cursor = self.org.store.cursor()
        plan = self._pending[1] if self._pending and self._pending[0] == cursor else None
        self._pending = None
        try:
            plan = plan or self.plan()
            self._more = plan.get("waiting", 0) > 0
            stats = self._run(plan, pool)
            self._followup = bool(stats.get("merged") or stats.get("unfiled"))
            return stats
        except ModelUnavailable:
            self.jobs_since = self.every_items
            raise
        except StoreLocked:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("consolidation pass failed: %s", safe_error(exc))
            self._more = self._followup = False
            self._idle_cursor = self.org.store.cursor()
            return {}

    # ---- planning -----------------------------------------------------------------------

    def _protected(self, event_id: str, ev: dict) -> bool:
        if ev["title_user_edited"] or ev["pinned"]:
            return True
        return self.org.store.one("SELECT 1 FROM event_items WHERE event_id=? AND removed=0 AND attached_by != 'model'",
                                  (event_id,)) is not None

    def plan(self) -> dict:
        org, store = self.org, self.org.store
        sizes = {r["event_id"]: r["n"] for r in store.all(
            "SELECT ei.event_id, COUNT(*) AS n FROM event_items ei JOIN events e ON e.event_id = ei.event_id"
            " WHERE ei.removed = 0 AND e.deleted = 0 GROUP BY ei.event_id")}
        events = []
        for f in org.event_features():
            eid = f["event_id"]
            ev = store.get_event(eid)
            if not ev or ev["deleted"] or not sizes.get(eid):
                continue
            events.append({"event_id": eid, "order": f["order"], "n": sizes[eid], "centroid": f.get("centroid"),
                           "protected": self._protected(eid, ev)})
        checks = {r["event_id"]: {"n_items": r["n_items"], "near": json.loads(r["near"] or "[]"),
                                  "outcome": r["outcome"], "n_checks": r["n_checks"]}
                  for r in store.all("SELECT * FROM consolidate_checks")}
        apart = [[r["a"], r["b"]] for r in store.all("SELECT a, b FROM constraints WHERE kind='apart_events'")]
        return self._plan.plan(events, checks, apart, **self.budget)

    # ---- views ---------------------------------------------------------------------------

    def _owner_names(self) -> list[str]:
        """The user's own names (ORGANIZER_OWNER_ALIASES), so the model can tell the user's matters from other
        people's own work. Constant for the process: it sits at the start of the prompt (prefix cache)."""
        names = [a for a in getattr(self.org, "owner_aliases", ()) if a and a not in ("我", "本人", "自己")]
        return names[:8]

    def _detail_view(self, event_id: str, n_items: int = 0, reads: Optional[list] = None) -> dict:
        """A target shown with its most recent items (for a sizeable subject), or with its first two and most
        recent items when n_items is given (the confirmation call). `reads` collects the ids of the items whose
        text the view holds."""
        org, store = self.org, self.org.store
        view = dict(self._matter_view(event_id, reads))
        ids = store.matching_item_ids(event_id) or store.event_item_ids(event_id)
        shown = ids[-DETAIL_ITEMS:] if not n_items else list(dict.fromkeys(ids[:2] + ids[-(n_items - 2):]))
        view["items"] = []
        for iid in shown:
            it = store.get_item(iid)
            if it:
                view["items"].append(_excerpt(org.match_body(it), DETAIL_CHARS))
                if reads is not None:
                    reads.append(iid)
        return view

    def _matter_view(self, event_id: str, reads: Optional[list] = None) -> dict:
        """A directory entry: what the event is (brief title / anchor / status line), how big, when, who, and
        the opening of its first item. Cached per event revision (seq) and person revision. `reads` collects
        the id of the item whose opening the entry shows."""
        org, store = self.org, self.org.store
        ev = store.get_event(event_id)
        persons_v = int(store.scalar("SELECT COALESCE(MAX(seq), 0) FROM persons") or 0)
        key = (ev["seq"], persons_v)
        cached = self._view_cache.get(event_id)
        if cached and cached[0] == key:
            if reads is not None and cached[2]:
                reads.append(cached[2])
            return cached[1]
        ids = store.event_item_ids(event_id)
        matching = store.matching_item_ids(event_id) or ids
        first = store.get_item(matching[0]) if matching else None
        counts: dict[str, int] = {}
        for iid in ids:
            for p in org.other_persons(iid, for_matching=True):
                counts[p] = counts.get(p, 0) + 1
        top = sorted(counts, key=lambda p: (-counts[p], p))[:DIRECTORY_PERSONS]
        span = ""
        if ev.get("started_at") and ev.get("updated_at"):
            a, b = org._local(ev["started_at"])[5:10], org._local(ev["updated_at"])[5:10]
            span = a if a == b else f"{a}→{b}"
        view = {"event_id": store.event_handle(event_id), "title": ev["title"], "anchor": ev["anchor"] or "",
                "status_line": ev["status_line"], "item_count": len(ids), "span": span,
                "persons": [org.people.label(p) for p in top],
                "sample": _excerpt(org.match_body(first), SAMPLE_CHARS) if first else ""}
        sample_id = first["item_id"] if first else None
        if reads is not None and sample_id:
            reads.append(sample_id)
        self._view_cache[event_id] = (key, view, sample_id)
        if len(self._view_cache) > 4096:
            self._view_cache.clear()
        return view

    def _small_view(self, event_id: str) -> tuple[dict, list[str], dict, list[str]]:
        """(the view the model reads, every item id of the event, the shown texts by handle, the shown ids)."""
        org, store = self.org, self.org.store
        ev = store.get_event(event_id)
        ids = store.event_item_ids(event_id)
        shown = ids if len(ids) <= SMALL_ITEMS_SHOWN else ids[:1] + ids[-(SMALL_ITEMS_SHOWN - 1):]
        views, texts, read = [], {}, []
        for iid in shown:
            it = store.get_item(iid)
            if not it:
                continue
            v = org.item_view(it, ITEM_CHARS)
            views.append({k: v[k] for k in ("item_id", "started_at", "source_app", "persons", "text")})
            texts[v["item_id"]] = v["text"]
            read.append(iid)
        view = {"event_id": store.event_handle(event_id), "title": ev["title"], "anchor": ev["anchor"] or "",
                "item_count": len(ids), "items": views}
        return view, ids, texts, read

    # ---- one pass ------------------------------------------------------------------------

    def _context(self, subject: dict, directory: list[dict], directory_reads: list[str]) -> Optional[dict]:
        store = self.org.store
        reads = list(directory_reads)
        with store.tx():
            ev = store.get_event(subject["event_id"])
            if not ev or ev["deleted"]:
                return None
            small, snapshot, texts, small_read = self._small_view(subject["event_id"])
            extra = [self._detail_view(e, reads=reads) if subject.get("detail") else self._matter_view(e, reads)
                     for e in subject["extra"]]
            handle = {e: store.event_handle(e) for e in subject["targets"] + subject["nearest"]}
        if not small["items"]:
            return None
        targets = [handle[e] for e in subject["targets"]]
        views = {v["event_id"]: v for v in directory + extra}
        target_text = {h: " ".join(str(views[h].get(k) or "") for k in ("title", "anchor", "status_line", "sample"))
                       for h in targets if h in views}
        data = {"owner": self._owner_names(), "matters": directory, "small": small, "more_matters": extra,
                "nearest": [handle[e] for e in subject["nearest"]], "targets": targets,
                "can_unfile": subject["can_unfile"]}
        schema = json.loads(json.dumps(self.org.registry.for_job("consolidate").schema))
        props = schema["properties"]
        # Every event the model can see may be named (guided decoding must never force a name the model did not
        # mean onto an allowed one); the validator then keeps a merge to the allowed targets.
        shown = [h for h in dict.fromkeys([v["event_id"] for v in directory + extra] + targets) if h != small["event_id"]]
        for key in ("candidate", "target"):
            props[key]["enum"] = shown + [""]
            props[key].pop("pattern", None)
        if not subject["can_unfile"]:
            props["verdict"]["enum"] = ["merge", "own_matter"]
        elif not targets:
            props["verdict"]["enum"] = ["own_matter", "not_matter"]
        props["quote"]["properties"]["item_id"]["enum"] = list(texts)
        props["quote"]["properties"]["item_id"].pop("pattern", None)
        context = {"targets": targets, "can_unfile": subject["can_unfile"], "items": texts, "target_text": target_text}
        # The items whose text the call reads: the small event's shown items, the directory samples and the
        # targets' items (store.purge_item clears the run and its proposals when any of them is deleted).
        reads = list(dict.fromkeys(small_read + reads))
        return {"subject": subject, "data": data, "schema": schema, "context": context, "snapshot": snapshot,
                "handle_to_event": {h: e for e, h in handle.items()}, "small_handle": small["event_id"],
                "reads": reads, "small_reads": small_read}

    def _confirm_context(self, ctx: dict, handle: str) -> Optional[dict]:
        """The merge is asked again with only the chosen event beside it, shown with more of its items and no
        directory: it is applied only when the model still says so."""
        event_id = ctx["handle_to_event"].get(handle)
        if not event_id:
            return None
        reads = list(ctx["small_reads"])
        with self.org.store.tx():
            ev = self.org.store.get_event(event_id)
            if not ev or ev["deleted"]:
                return None
            view = self._detail_view(event_id, n_items=CONFIRM_ITEMS, reads=reads)
        data = {"owner": ctx["data"]["owner"], "matters": [], "small": ctx["data"]["small"], "more_matters": [view],
                "nearest": [handle], "targets": [handle], "can_unfile": False}
        schema = json.loads(json.dumps(ctx["schema"]))
        props = schema["properties"]
        for key in ("candidate", "target"):
            props[key]["enum"] = [handle, ""]
        props["verdict"]["enum"] = ["merge", "own_matter"]
        target_text = " ".join(str(view.get(k) or "") for k in ("title", "anchor", "status_line", "sample"))
        context = dict(ctx["context"], targets=[handle], can_unfile=False, target_text={handle: target_text})
        return dict(ctx, data=data, schema=schema, context=context, confirm_of=handle,
                    reads=list(dict.fromkeys(reads)))

    def call(self, ctx: dict):
        return self.org.harness.run("consolidate", ctx["data"], context=ctx["context"], schema=ctx["schema"],
                                    subject=ctx["subject"]["event_id"], reads=ctx.get("reads"))

    def _run(self, plan: dict, pool=None) -> dict:
        stats = {"subjects": len(plan["subjects"]), "waiting": plan.get("waiting", 0), "merged": 0, "unfiled": 0,
                 "kept": 0, "unconfirmed": 0, "stale": 0, "invalid": 0, "skipped": 0}
        if not plan["subjects"]:
            return stats
        directory_reads: list[str] = []
        with self.org.store.tx():
            directory = [self._matter_view(e, directory_reads) for e in plan["directory"]]
        ctxs = [c for c in (self._context(s, directory, directory_reads) for s in plan["subjects"]) if c is not None]
        if pool is not None and len(ctxs) > 1:
            # On the model pool, each call bound to this unlock session (a lock or wipe meanwhile: nothing written).
            call = self.org.in_session(self.call)
            futures = [pool.submit(call, c) for c in ctxs]
            results = []
            for f in futures:
                try:
                    results.append(f.result())
                except (ModelUnavailable, StoreLocked):
                    raise
                except Exception as exc:  # noqa: BLE001 - one bad call does not stop the pass
                    log.warning("event-consolidate call failed: %s", safe_error(exc))
                    results.append(None)
        else:
            results = [self.call(c) for c in ctxs]
        self._confirm(ctxs, results, pool)
        moved: set[str] = set()
        for ctx, res in zip(ctxs, results):
            outcome = self.apply(ctx, res, moved) if res is not None else "invalid"
            stats[outcome] = stats.get(outcome, 0) + 1
        self.stats["passes"] += 1
        self.stats["calls"] += len(ctxs)
        for k in ("merged", "unfiled", "kept", "unconfirmed", "stale", "invalid", "skipped"):
            self.stats[k] = self.stats.get(k, 0) + stats[k]
        self.org.store.record_proposal(None, "consolidate", "pass", stats, "applied", "consolidation pass")
        log.info("consolidation pass: %s", stats)
        return stats

    def _needs_second_look(self, ctx: dict, target_handle: str) -> bool:
        """Sizeable subjects, and merges of two events that both already hold CONFIRM_BOTH_MIN items (two
        established matters, the look-alike case: a supplier change and the new menu it serves)."""
        if ctx["subject"].get("detail"):
            return True
        event_id = ctx["handle_to_event"].get(target_handle)
        if not event_id or len(ctx["snapshot"]) < CONFIRM_BOTH_MIN:
            return False
        return len(self.org.store.event_item_ids(event_id)) >= CONFIRM_BOTH_MIN

    def _confirm(self, ctxs: list[dict], results: list, pool=None) -> None:
        """Second look (see _needs_second_look): ctx["confirmed"] = True / False."""
        todo = []
        for ctx, res in zip(ctxs, results):
            if (res is not None and res.ok and res.output["verdict"] == "merge"
                    and self._needs_second_look(ctx, res.output["target"])):
                cctx = self._confirm_context(ctx, res.output["target"])
                if cctx is None:
                    ctx["confirmed"] = False
                else:
                    todo.append((ctx, cctx))
        if not todo:
            return
        if pool is not None and len(todo) > 1:
            call = self.org.in_session(self.call)
            futures = [pool.submit(call, c) for _, c in todo]
            outs = []
            for f in futures:
                try:
                    outs.append(f.result())
                except (ModelUnavailable, StoreLocked):
                    raise
                except Exception as exc:  # noqa: BLE001
                    log.warning("event-consolidate confirmation failed: %s", safe_error(exc))
                    outs.append(None)
        else:
            outs = [self.call(c) for _, c in todo]
        for (ctx, cctx), res in zip(todo, outs):
            ctx["confirmed"] = bool(res is not None and res.ok and res.output["verdict"] == "merge"
                                    and res.output["target"] == cctx["confirm_of"])
            ctx["confirm_run_id"] = res.run_id if res is not None else None
        self.stats["confirm_calls"] = self.stats.get("confirm_calls", 0) + len(todo)

    # ---- applying ------------------------------------------------------------------------

    def _resolve(self, event_id: str) -> Optional[str]:
        """Follow merged_into to the live event (a target merged into another event in this pass)."""
        store = self.org.store
        seen = set()
        while event_id and event_id not in seen:
            seen.add(event_id)
            ev = store.get_event(event_id)
            if not ev:
                return None
            if not ev["deleted"]:
                return event_id
            event_id = ev["merged_into"]
        return None

    def apply(self, ctx: dict, res, moved: set[str]) -> str:
        store = self.org.store
        subject = ctx["subject"]
        x = subject["event_id"]
        if not res.ok:
            store.record_proposal(res.run_id, "consolidate", x, {"errors": res.errors[:6]}, "rejected",
                                  "event-consolidate output invalid twice; event left as it is")
            self._checked(x, ctx, "invalid", None, res.run_id)
            return "invalid"
        out = res.output
        payload = dict(out, targets=ctx["context"]["targets"])
        with store.tx():
            ev = store.get_event(x)
            now = store.event_item_ids(x) if ev and not ev["deleted"] else []
            grown = set(now) - set(ctx["snapshot"])
            if (not ev or ev["deleted"] or not set(ctx["snapshot"]) <= set(now) or grown - moved
                    or self._protected(x, ev)):
                store.record_proposal(res.run_id, "consolidate", x, payload, "superseded",
                                      "the event changed during the check; judged again next pass")
                if ev and not ev["deleted"]:
                    self._checked(x, ctx, "stale", None, res.run_id)
                return "stale"
            verdict = out["verdict"]
            if verdict == "merge" and ctx.get("confirmed") is False:
                store.record_proposal(res.run_id, "consolidate", x, dict(payload, confirm_run_id=ctx.get("confirm_run_id")),
                                      "rejected", "merge not confirmed by the second look: kept")
                self._checked(x, ctx, "kept", None, res.run_id)
                return "unconfirmed"
            if verdict == "merge":
                target = self._resolve(ctx["handle_to_event"].get(out["target"], ""))
                why = None
                keep, drop = (x, target)
                if target is None or target == x:
                    why = "target gone"
                else:
                    tev = store.get_event(target)
                    t_items = store.event_item_ids(target)
                    # The larger event stays (its id, handle and card); ties keep the older one.
                    if (len(t_items), -int(tev.get("handle") or 0)) > (len(now), -int(ev.get("handle") or 0)):
                        keep, drop = target, x
                    drop_items = now if drop == x else t_items
                    if store.has_constraint("apart_events", x, target):
                        why = "kept apart by the user"
                    elif min(len(now), len(t_items)) >= NAME_CHECK_MIN and not self._names_agree(ev, tev):
                        why = "two sizeable events whose names share fewer than two words stay apart"
                    elif drop != x and self._protected(drop, tev):
                        why = "the other event is protected by a user decision"
                    elif any(keep in store.forbidden_events_for(i) for i in drop_items):
                        why = "the user removed one of its items from the other event"
                if why:
                    store.record_proposal(res.run_id, "consolidate", x, payload, "rejected", f"merge skipped: {why}")
                    self._checked(x, ctx, "skipped", target, res.run_id)
                    return "skipped"
                moved.update(store.event_item_ids(drop))
                self.merge_events(keep, drop, res.run_id)
                store.record_proposal(res.run_id, "consolidate", x, dict(payload, keep=keep, drop=drop), "applied",
                                      f"merged into {keep}" if drop == x else f"absorbed {drop}")
                self._checked(x, ctx, "merged", keep, res.run_id)
                return "merged"
            if verdict == "not_matter":
                if grown or len(now) > self.budget["unfile_max_items"]:
                    store.record_proposal(res.run_id, "consolidate", x, payload, "rejected",
                                          "not_matter skipped: other events were merged into it")
                    self._checked(x, ctx, "skipped", None, res.run_id)
                    return "skipped"
                for iid in now:
                    store.detach(x, iid, "consolidate")
                    store.set_unfiled(iid, "none", res.run_id)
                store.update_event(x, deleted=1, needs_brief=0)
                store.expire_questions_touching([x])
                store.record_proposal(res.run_id, "consolidate", x, payload, "applied",
                                      f"not a matter: {len(now)} item(s) back to Unfiled")
                self._checked(x, ctx, "unfiled", None, res.run_id)
                return "unfiled"
            store.record_proposal(res.run_id, "consolidate", x, payload, "applied", "own matter: kept")
            self._checked(x, ctx, "kept", None, res.run_id)
            return "kept"

    def _names_agree(self, a: dict, b: dict) -> bool:
        """Two sizeable events are one only if their names say so: their titles and anchors share at least two
        content words, not counting the user's own name. The model alone merged look-alike workstreams of one
        project on the dev scale stores (a demo into the experiment it shows, one offer into another), while
        true twins name the same thing ("oven 3 installation" / "oven 3 exhaust installation")."""
        terms = self.org.registry.script("event-consolidate", "validate").terms
        own = set()
        for alias in getattr(self.org, "owner_aliases", ()):
            own |= terms(alias)
        words = [terms(" ".join(str(e.get(k) or "") for k in ("title", "anchor"))) - own for e in (a, b)]
        return len(words[0] & words[1]) >= 2

    def merge_events(self, keep: str, drop: str, run_id: Optional[str]) -> None:
        """Model merge: every item of `drop` moves to `keep` (a model placement on the same item revision, so a
        later revision is re-decided as usual) and `drop` is deleted with merged_into=keep."""
        store = self.org.store
        with store.tx():
            for link in store.all("SELECT * FROM event_items WHERE event_id=? AND removed=0 ORDER BY link_seq", (drop,)):
                store.detach(drop, link["item_id"], "consolidate_merge")
                store.attach(keep, link["item_id"], "model", run_id, link["item_revision"])
            store.update_event(drop, deleted=1, merged_into=keep, needs_brief=0)
            store.update_event(keep, needs_brief=1)
            store.expire_questions_touching([drop])

    def _checked(self, event_id: str, ctx: dict, outcome: str, target: Optional[str], run_id: Optional[str]) -> None:
        store = self.org.store
        subject = ctx["subject"]
        row = store.one("SELECT n_checks FROM consolidate_checks WHERE event_id=?", (event_id,))
        store.x("INSERT OR REPLACE INTO consolidate_checks(event_id, n_items, near, outcome, target, run_id, n_checks,"
                " created_at) VALUES (?,?,?,?,?,?,?,?)",
                (event_id, len(ctx["snapshot"]), json.dumps(subject["nearest"]), outcome, target, run_id,
                 (row["n_checks"] if row else 0) + 1, store.now()))
