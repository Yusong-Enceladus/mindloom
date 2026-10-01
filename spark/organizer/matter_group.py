"""The grouping pass (relations v2 "ply": ropes; MAP-CONTRACT section 2): skill matter-group twists the user's
matters into ropes (long-lived areas and bigger projects, as a tree: each matter under at most one rope, ropes
inside ropes) and gives every matter its type facet.

Schedule and budget (the organizer's scheduler calls this; no user action), like consolidation:
  * every `every_items` processed item jobs, and when the queue is empty and matters wait to be placed (after
    `idle_min_new` of them, after `idle_after_s` without a new item, on a fresh start, or while a budget-limited
    pass left some);
  * at most `max_calls` calls per pass, `batch` matters per call, one after another (a call sees the ropes the
    previous one made), biggest matters first.

Which matters: live events with at least `min_items` items that the pass has not judged; a matter it judged
without a rope is judged again (at most 3 times) when its title changes. A matter the user put on a rope (or
said has none) is never touched; a matter on a rope stays there.

User decisions win (decisions.py): confirm or reject a rope, move a matter to another rope, rename a rope. A
rejected rope's title is shown to the model as "never again" and its matters are released (and not judged again
until they change); the validator refuses a new rope with that title. A renamed rope keeps the user's title.

Privacy (docs/PRIVACY.md): the pass runs only while the store is unlocked, inside the worker's step (its writes
are bound to the unlock session); each call records the sample items it showed, so deleting one clears the run
and its proposal, and a rope whose evidence cited it loses that evidence and its reason (store.purge_graph).
group_checks holds event ids, a hash of the title and outcomes only.
"""

from __future__ import annotations

import hashlib
import logging
import time
from typing import Any, Optional

from . import jsonschema_lite
from .clients import ModelUnavailable, safe_error
from .store import StoreLocked, new_id

log = logging.getLogger("organizer.group")

SAMPLE_CHARS = 60
MAX_CHECKS = 3


def _excerpt(text: str, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def title_hash(title: str) -> str:
    return hashlib.sha256((title or "").encode()).hexdigest()[:16]


class MatterGrouper:
    def __init__(self, org: Any, *, enabled: bool = True, every_items: int = 50, max_calls: int = 3, batch: int = 30,
                 min_items: int = 2, idle_min_new: int = 3, idle_after_s: float = 600.0):
        self.org = org
        self.store = org.store
        self.enabled = enabled
        self.every_items = max(1, int(every_items))
        self.max_calls = max(1, int(max_calls))
        self.batch = max(1, int(batch))
        self.min_items = max(1, int(min_items))
        self.idle_min_new = max(1, int(idle_min_new))
        self.idle_after_s = float(idle_after_s)
        self.skill = org.registry.for_job("group")
        self._build = org.registry.script("matter-group", "build")
        self._rules = org.registry.script("matter-group", "validate")
        self.jobs_since = 0
        self._fresh = True
        self._more = False
        self._last_job_t = time.monotonic()
        self._idle_cursor: Optional[int] = None
        self.stats = {"passes": 0, "calls": 0, "judged": 0, "placed": 0, "ropes": 0, "repaired": 0, "invalid": 0}

    # ---- scheduling ---------------------------------------------------------------------

    def reset(self) -> None:
        self._idle_cursor = None
        self._fresh = True

    def note_job(self) -> None:
        self.jobs_since += 1
        self._last_job_t = time.monotonic()

    def due(self) -> bool:
        return self.enabled and self.jobs_since >= self.every_items and bool(self.plan())

    def idle_due(self) -> bool:
        if not self.enabled:
            return False
        cursor = self.store.cursor()
        if cursor == self._idle_cursor and not self._more:
            return False
        todo = self.plan()
        if not todo:
            self._idle_cursor, self._more = cursor, False
            return False
        if self._fresh or self._more or len(todo) >= self.idle_min_new or self.jobs_since >= self.every_items \
                or time.monotonic() - self._last_job_t >= self.idle_after_s:
            return True
        self._idle_cursor = cursor
        return False

    def plan(self) -> list[str]:
        """Matters to place, biggest first."""
        rows = self.store.all(
            "SELECT e.event_id, e.title, COUNT(*) AS n, g.title_hash, g.outcome, g.n_checks, m.source AS msource,"
            " m.rope_id FROM events e JOIN event_items ei ON ei.event_id = e.event_id AND ei.removed = 0"
            " LEFT JOIN group_checks g ON g.event_id = e.event_id LEFT JOIN rope_members m ON m.event_id = e.event_id"
            " WHERE e.deleted = 0 GROUP BY e.event_id HAVING COUNT(*) >= ? ORDER BY COUNT(*) DESC, e.handle",
            (self.min_items,))
        out = []
        for r in rows:
            if r["msource"] == "user":
                continue
            if r["outcome"] is None:
                out.append(r["event_id"])
            elif r["rope_id"] is None and r["outcome"] in ("none", "invalid") and r["n_checks"] < MAX_CHECKS \
                    and r["title_hash"] != title_hash(r["title"]):
                out.append(r["event_id"])
        return out

    # ---- the pass -------------------------------------------------------------------------

    def run(self, pool=None) -> dict:
        """One pass, calls one after another on the worker's thread. The model being down propagates (the worker
        backs off; the pass stays due), and so does the store being locked; other failures are logged by type."""
        self.jobs_since = 0
        self._fresh = False
        stats = {"calls": 0, "judged": 0, "placed": 0, "ropes": 0}
        try:
            todo = self.plan()
            calls = 0
            while todo and calls < self.max_calls:
                chunk, todo = todo[:self.batch], todo[self.batch:]
                res = self.call_batch(chunk)
                calls += 1
                for k in ("judged", "placed", "ropes"):
                    stats[k] += res.get(k, 0)
            stats["calls"] = calls
            self._more = bool(todo)
            self.stats["passes"] += 1
            self.stats["calls"] += calls
            for k in ("judged", "placed", "ropes"):
                self.stats[k] += stats[k]
            if calls:
                log.info("grouping pass: %s", stats)
            return stats
        except (ModelUnavailable, StoreLocked):
            self.jobs_since = self.every_items
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("grouping pass failed: %s", safe_error(exc))
            self._more = False
            self._idle_cursor = self.store.cursor()
            return stats

    def _people(self, event_id: str, k: int = 3) -> list[str]:
        counts: dict[str, int] = {}
        for iid in self.store.event_item_ids(event_id):
            for p in self.org.other_persons(iid, for_matching=True):
                counts[p] = counts.get(p, 0) + 1
        return [self.org.people.label(p) for p in sorted(counts, key=lambda p: (-counts[p], p))[:k]]

    def context(self, event_ids: list[str]) -> Optional[dict]:
        org, store = self.org, self.store
        with store.tx():
            ropes_rows = store.all("SELECT * FROM ropes WHERE state != 'rejected' ORDER BY handle")
            rh = {r["rope_id"]: f"R{r['handle']}" for r in ropes_rows}
            members: dict[str, list[str]] = {}
            placed = []
            for m in store.all("SELECT m.event_id, m.rope_id, e.handle, e.title FROM rope_members m JOIN events e"
                               " ON e.event_id = m.event_id WHERE e.deleted = 0 AND m.rope_id IS NOT NULL ORDER BY e.handle"):
                if m["rope_id"] in rh:
                    members.setdefault(m["rope_id"], []).append(f"E{m['handle']} {m['title']}")
                    placed.append({"id": f"E{m['handle']}", "title": m["title"], "rope": rh[m["rope_id"]]})
            ropes = [{"id": rh[r["rope_id"]], "title": r["title"], "kind": r["kind"],
                      "parent": rh.get(r["parent"] or "", ""), "matters": members.get(r["rope_id"], [])[:12],
                      "confirmed": r["state"] == "confirmed" or bool(r["title_user_edited"])} for r in ropes_rows]
            rejected = [r["title"] for r in store.all("SELECT title FROM ropes WHERE state='rejected' ORDER BY handle")]
            types = [r["type"] for r in store.all("SELECT type, COUNT(*) AS n FROM event_facets WHERE type IS NOT NULL"
                                                  " GROUP BY type ORDER BY n DESC, type LIMIT 30")]
            views, reads, h2e, h2i, titles = [], [], {}, {}, {}
            for eid in event_ids:
                ev = store.get_event(eid)
                if not ev or ev["deleted"]:
                    continue
                ids = store.matching_item_ids(eid) or store.event_item_ids(eid)
                first = store.get_item(ids[0]) if ids else None
                span = ""
                if ev.get("started_at") and ev.get("updated_at"):
                    a, b = org._local(ev["started_at"])[5:10], org._local(ev["updated_at"])[5:10]
                    span = a if a == b else f"{a}→{b}"
                h = store.event_handle(eid)
                view = {"id": h, "title": ev["title"], "anchor": ev["anchor"] or "", "status_line": ev["status_line"],
                        "item_count": len(store.event_item_ids(eid)), "span": span, "people": self._people(eid),
                        "sample": _excerpt(org.match_body(first), SAMPLE_CHARS) if first else "", "sample_id": ""}
                if first:
                    view["sample_id"] = store.item_handle(first["item_id"])
                    h2i[view["sample_id"]] = first["item_id"]
                    reads.append(first["item_id"])
                views.append(view)
                h2e[h] = eid
                titles[eid] = ev["title"]
            if not views:
                return None
            shown = {v["id"] for v in views}
            data = {"owner": [a for a in getattr(org, "owner_aliases", ()) if a and a not in ("我", "本人", "自己")][:8],
                    "ropes": ropes, "rejected": rejected, "types": types, "matters": views,
                    "placed": [p for p in placed if p["id"] not in shown][:self._build.PLACED_SHOWN]}
        schema = self._build.schema_for(self.skill.schema, data)
        context = self._build.context_for(data)
        return {"data": data, "schema": schema, "context": context, "h2e": h2e, "h2i": h2i,
                "h2r": {v: k for k, v in rh.items()}, "titles": titles, "reads": reads}

    def call_batch(self, event_ids: list[str]) -> dict:
        ctx = self.context(event_ids)
        if ctx is None:
            return {}
        res = self.org.harness.run("group", ctx["data"], context=ctx["context"], schema=ctx["schema"], subject="ropes",
                                   reads=ctx["reads"], no_retry=self._rules.REPAIRABLE)
        return self.apply(ctx, res)

    # ---- applying ---------------------------------------------------------------------------

    def _usable(self, res, ctx: dict) -> tuple[Optional[dict], str]:
        if res.ok:
            return res.output, "applied"
        fixed = self._rules.salvage(res.candidate, res.errors, ctx["context"])
        if fixed is not None and not jsonschema_lite.validate(fixed, ctx["schema"]):
            return fixed, "partial"
        return None, "rejected"

    def apply(self, ctx: dict, res) -> dict:
        store = self.store
        if self.org._overtaken_by_purge(res.run_id, ctx["reads"], "group", "ropes"):
            return {}
        out, status = self._usable(res, ctx)
        if out is None:
            self.stats["invalid"] += 1
            store.record_proposal(res.run_id, "group", "ropes", {"errors": res.errors[:6]}, "rejected",
                                  "matter-group output invalid twice; nothing placed")
            # judged (so an always-failing batch does not loop); judged again when the titles change
            with store.tx():
                for eid in ctx["h2e"].values():
                    self._checked(eid, ctx, "invalid", res.run_id)
            return {"judged": 0}
        if status == "partial":
            self.stats["repaired"] += 1
        placed = ropes = 0
        with store.tx():
            key_to_rope: dict[str, str] = {}
            for r in out.get("new_ropes") or []:
                rid = new_id()
                key_to_rope[r["key"]] = rid
                evidence = [ctx["h2i"][e] for e in r.get("evidence") or [] if e in ctx["h2i"]]
                store.x("INSERT INTO ropes(rope_id, handle, title, kind, parent, state, reason, evidence, run_id,"
                        " created_at, seq) VALUES (?,?,?,?,NULL,'proposed',?,?,?,?,?)",
                        (rid, store.next_rope_handle(), store.mask_text(r["title"].strip()), r["kind"],
                         store.mask_text(r["reason"].strip()), json_dumps(evidence), res.run_id, store.now(), store.bump()))
                ropes += 1

            def resolve(ref: str) -> Optional[str]:
                if not ref:
                    return None
                return key_to_rope.get(ref) or ctx["h2r"].get(ref)

            for r in out.get("new_ropes") or []:
                parent = resolve(r.get("parent") or "")
                if parent and self._live_rope(parent):
                    store.x("UPDATE ropes SET parent=? WHERE rope_id=?", (parent, key_to_rope[r["key"]]))
            for n in out.get("nest") or []:
                rid, parent = resolve(n["rope"]), resolve(n["parent"])
                # re-checked now: still a model proposal at the top level (a user decision meanwhile wins)
                if rid and parent and rid != parent and self._live_rope(parent) and store.one(
                        "SELECT 1 FROM ropes WHERE rope_id=? AND state='proposed' AND title_user_edited=0"
                        " AND parent IS NULL", (rid,)):
                    store.x("UPDATE ropes SET parent=?, seq=? WHERE rope_id=?", (parent, store.bump(), rid))
            judged = set()
            for p in out.get("placements") or []:
                eid = ctx["h2e"].get(p["matter"])
                if not eid or eid in judged:
                    continue
                judged.add(eid)
                ev = store.get_event(eid)
                if not ev or ev["deleted"]:
                    continue
                cur = store.one("SELECT * FROM rope_members WHERE event_id=?", (eid,))
                if cur and cur["source"] == "user":
                    continue  # the user's decision arrived during the call
                rid = resolve(p.get("rope") or "")
                changed = False
                if rid and self._live_rope(rid) and not (cur and cur["rope_id"]):
                    store.x("INSERT OR REPLACE INTO rope_members(event_id, rope_id, source, run_id, created_at)"
                            " VALUES (?,?,'model',?,?)", (eid, rid, res.run_id, store.now()))
                    placed += 1
                    changed = True
                facet = store.one("SELECT source, type FROM event_facets WHERE event_id=?", (eid,))
                kind = store.mask_text(p["type"])
                if (not facet or facet["source"] != "user") and (not facet or facet["type"] != kind):
                    store.x("INSERT OR REPLACE INTO event_facets(event_id, type, source, run_id, updated_at)"
                            " VALUES (?,?,'model',?,?)", (eid, kind, res.run_id, store.now()))
                    changed = True
                if changed:
                    store.touch_event(eid)  # its facets changed: the Mac pulls the event again
                self._checked(eid, ctx, "rope" if rid else "none", res.run_id)
            store.record_proposal(res.run_id, "group", "ropes",
                                  {"new_ropes": len(out.get("new_ropes") or []), "placed": placed,
                                   "judged": len(judged), "errors": res.errors[:6] if status == "partial" else []},
                                  status, "")
        self.org.graph.reset()
        return {"judged": len(judged), "placed": placed, "ropes": ropes}

    def _live_rope(self, rope_id: str) -> bool:
        return self.store.one("SELECT 1 FROM ropes WHERE rope_id=? AND state != 'rejected'", (rope_id,)) is not None

    def _checked(self, event_id: str, ctx: dict, outcome: str, run_id: Optional[str]) -> None:
        store = self.store
        row = store.one("SELECT n_checks FROM group_checks WHERE event_id=?", (event_id,))
        store.x("INSERT OR REPLACE INTO group_checks(event_id, title_hash, outcome, n_checks, run_id, created_at)"
                " VALUES (?,?,?,?,?,?)", (event_id, title_hash(ctx["titles"].get(event_id, "")), outcome,
                                          (row["n_checks"] if row else 0) + 1, run_id, store.now()))


def json_dumps(value) -> str:
    import json
    return json.dumps(value, ensure_ascii=False)
