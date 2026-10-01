"""The matter map (the "线索" view; MAP-CONTRACT section 1): skill matter-map draws one matter's strands, knots,
health and the blocks edges its items state.

Trigger (the organizer's scheduler; no user action):
  * when a matter's brief is written again and it holds >= min_items items, it is queued if its map is missing
    or outdated: an item it was drawn from left the matter, or the matter grew by max(regrow_min, regrow x size)
    items since (a 150-item matter is not redrawn for every new item);
  * a matter with >= min_items items and no map at all is queued when the organizer is idle (a store built
    before maps existed);
  * the Mac asks for a matter's map (POST /v1/events/{id}/map, queued with priority): run at the next step, one
    at a time, even while items are waiting, because the user opened that matter. Any matter with at least
    demand_min_items items.
  Each pass runs at most max_calls maps (the pool runs them concurrently in pipeline mode); queued requests go
  first by priority, then by importance.

Input (skills/matter-map/scripts/build.py): the matter's card facts and its items (id, time, kind, source, speakers,
masked text or reading summary + text, up to MAX_ITEMS most recent, text shortened to fit a fixed budget), each
split item's segment as its own item with part_of, and the 8 other matters with the most crossings, then the most
similar centroid (the only matters a blocks edge may name).

Output: validated by scripts/validate.py; a contract error is retried once, then the map is dropped (event_maps
outcome 'dropped', tried again only when the items change); the repairable errors (an ungrounded date, a name
that appears nowhere, a blocks entry that states no dependency) are fixed without a retry.

Privacy (docs/PRIVACY.md): passes run only while the store is unlocked, inside the worker's step; calls on the
pool are bound to the unlock session (Organizer.in_session), so a lock or a wipe meanwhile writes nothing. Each
call records the items it read, so deleting one clears the run and its proposal; the map itself drops the item
(store.purge_graph). A result whose input held an item deleted during the call is discarded.
"""

from __future__ import annotations

import json
import logging
import math
from datetime import datetime
from typing import Any, Optional

from . import jsonschema_lite
from .clients import ModelUnavailable, safe_error
from .relations import crossing_counts, facts_digest
from .store import StoreLocked

log = logging.getLogger("organizer.map")


def _excerpt(text: str, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _cos(a, b) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return sum(x * y for x, y in zip(a, b)) / (na * nb) if na and nb else 0.0


class MatterMapper:
    def __init__(self, org: Any, *, enabled: bool = True, min_items: int = 8, max_calls: int = 4,
                 demand_min_items: int = 3, regrow: float = 0.25, regrow_min: int = 3, max_tries: int = 2):
        self.org = org
        self.store = org.store
        self.enabled = enabled
        self.min_items = max(1, int(min_items))
        self.max_calls = max(1, int(max_calls))
        self.demand_min_items = max(1, int(demand_min_items))
        self.regrow = float(regrow)
        self.regrow_min = max(1, int(regrow_min))
        self.max_tries = max(1, int(max_tries))
        self.skill = org.registry.for_job("map")
        self._build = org.registry.script("matter-map", "build")
        self._rules = org.registry.script("matter-map", "validate")
        self._idle_cursor: Optional[int] = None
        self.stats = {"passes": 0, "calls": 0, "written": 0, "repaired": 0, "salvaged": 0, "dropped": 0, "stale": 0,
                      "blocks": 0}

    # ---- scheduling ---------------------------------------------------------------------

    def reset(self) -> None:
        self._idle_cursor = None

    def outdated(self, event_id: str, ids: Optional[list[str]] = None) -> bool:
        """No map yet; an item it was drawn from left the matter; a purge pruned it; or the matter grew by
        max(regrow_min, regrow x size) items since it was drawn (or since a dropped attempt)."""
        row = self.store.map_row(event_id)
        ids = ids if ids is not None else self.store.event_item_ids(event_id)
        if row is None:
            return True
        mapped, now = set(row["item_set"]), set(ids)
        if mapped - now or (row["outcome"] == "ok" and row["stale"]):
            return True
        return len(now - mapped) >= max(self.regrow_min, int(self.regrow * len(mapped)))

    def note_brief(self, event_id: str) -> None:
        """A brief was written for the event: queue a map when it is big enough and its map is outdated."""
        if not self.enabled:
            return
        ids = self.store.event_item_ids(event_id)
        if len(ids) >= self.min_items and self.outdated(event_id, ids):
            self.store.queue_map(event_id, 1, "brief")

    def request(self, event_id: str) -> Optional[dict]:
        """POST /v1/events/{id}/map. None: unknown or deleted event."""
        ev = self.store.get_event(event_id)
        if not ev or ev["deleted"]:
            return None
        ids = self.store.event_item_ids(event_id)
        if len(ids) < self.demand_min_items:
            return {"queued": False, "reason": "too_small", "min_items": self.demand_min_items}
        row = self.store.map_row(event_id)
        if row is not None and row["outcome"] == "ok" and not self.outdated(event_id, ids):
            return {"queued": False, "reason": "current"}
        if row is not None and row["outcome"] != "ok" and row["tries"] >= self.max_tries and not self.outdated(event_id, ids):
            return {"queued": False, "reason": "failed"}
        self.store.queue_map(event_id, 2, "demand")
        position = int(self.store.scalar("SELECT COUNT(*) FROM map_queue WHERE priority >= 2") or 1)
        self.org.wake()
        return {"queued": True, "position": position}

    def demand_due(self) -> bool:
        return self.enabled and self.store.one("SELECT 1 FROM map_queue WHERE priority >= 2 LIMIT 1") is not None

    def idle_due(self) -> bool:
        if not self.enabled:
            return False
        cursor = self.store.cursor()
        if cursor == self._idle_cursor:
            return False
        if self.plan(1):
            return True
        self._idle_cursor = cursor
        return False

    def plan(self, limit: int, demand_only: bool = False) -> list[str]:
        """Events to map now: queued ones by priority then importance, then (idle only) matters with enough items
        and no map yet, largest importance first."""
        rows = self.store.all(
            "SELECT q.event_id, q.priority FROM map_queue q JOIN events e ON e.event_id = q.event_id AND e.deleted = 0"
            + (" WHERE q.priority >= 2" if demand_only else "")
            + " ORDER BY q.priority DESC, e.importance DESC, q.queued_at")
        if self.store.deadline_days:
            # v8 B6 (a shared space's store): within a priority, matters with a near deadline first
            urgent = self.store.urgent_events()
            rows.sort(key=lambda r: (-r["priority"], r["event_id"] not in urgent))
        out = [r["event_id"] for r in rows[:limit]]
        # queued rows of deleted events are dropped
        self.store.x("DELETE FROM map_queue WHERE event_id IN (SELECT event_id FROM events WHERE deleted = 1)")
        if demand_only or len(out) >= limit:
            return out
        for r in self.store.all(
                "SELECT e.event_id FROM events e JOIN event_items ei ON ei.event_id = e.event_id AND ei.removed = 0"
                " LEFT JOIN event_maps m ON m.event_id = e.event_id"
                " WHERE e.deleted = 0 AND m.event_id IS NULL GROUP BY e.event_id HAVING COUNT(*) >= ?"
                " ORDER BY e.importance DESC, e.handle LIMIT ?", (self.min_items, limit)):
            if r["event_id"] not in out and len(out) < limit:
                out.append(r["event_id"])
        return out

    # ---- one pass ---------------------------------------------------------------------------

    def run(self, pool=None, demand_only: bool = False, max_calls: Optional[int] = None) -> dict:
        """One pass. The model being down propagates (the worker backs off; the queue stays), and so does the store
        being locked; any other failure is logged by type and never stops item processing."""
        stats = {"maps": 0, "written": 0, "repaired": 0, "salvaged": 0, "dropped": 0, "stale": 0}
        todo: list[str] = []
        try:
            todo = self.plan(max_calls or self.max_calls, demand_only)
            ctxs = [c for c in (self.context(e) for e in todo) if c is not None]
            for e in todo:
                if not any(c["event_id"] == e for c in ctxs):
                    self.store.x("DELETE FROM map_queue WHERE event_id=?", (e,))
            if pool is not None and len(ctxs) > 1:
                call = self.org.in_session(self.call)
                futures = [pool.submit(call, c) for c in ctxs]
                results = []
                for f in futures:
                    try:
                        results.append(f.result())
                    except (ModelUnavailable, StoreLocked):
                        raise
                    except Exception as exc:  # noqa: BLE001 - one bad call does not stop the pass
                        log.warning("matter-map call failed: %s", safe_error(exc))
                        results.append(None)
            else:
                results = [self.call(c) for c in ctxs]
            for ctx, res in zip(ctxs, results):
                if res is None:  # the call itself failed (logged by type): tried again when idle, not in a loop
                    self._demote([ctx["event_id"]])
                    outcome = "dropped"
                else:
                    outcome = self.apply(ctx, res)
                stats["maps"] += 1
                stats[outcome] = stats.get(outcome, 0) + 1
            self.stats["passes"] += 1
            self.stats["calls"] += len(ctxs)
            for k in ("written", "repaired", "salvaged", "dropped", "stale"):
                self.stats[k] += stats.get(k, 0)
            if stats["maps"]:
                log.info("map pass: %s", stats)
            return stats
        except (ModelUnavailable, StoreLocked):
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("map pass failed: %s", safe_error(exc))
            self._demote(todo)
            self._idle_cursor = self.store.cursor()
            return stats

    def _demote(self, event_ids: list[str]) -> None:
        """A request whose pass failed for another reason than the model or the lock goes back to the idle queue
        (whose planning waits for the store to change), so a failing on-demand map never spins the worker."""
        for e in event_ids:
            self.store.x("UPDATE map_queue SET priority=MIN(priority, 1) WHERE event_id=?", (e,))

    def other_matters(self, event_id: str, k: int) -> list[str]:
        """The matters a blocks edge may name: most crossings first, then the most similar centroid."""
        cross = crossing_counts(self.org.graph.cross(), event_id)
        feats = {f["event_id"]: f for f in self.org.event_features()}
        me = feats.get(event_id) or {}
        sims = {e: _cos(me.get("centroid"), f.get("centroid")) for e, f in feats.items() if e != event_id}
        ranked = sorted(sims, key=lambda e: (-cross.get(e, 0), -sims[e], feats[e]["order"]))
        return ranked[:k]

    def context(self, event_id: str) -> Optional[dict]:
        org, store, build = self.org, self.store, self._build
        with store.tx():
            ev = store.get_event(event_id)
            if not ev or ev["deleted"]:
                return None
            ids = store.event_item_ids(event_id)
            if not ids:
                return None
            shown = ids[-build.MAX_ITEMS:]
            limit = build.text_limit(len(shown))
            items, handle_to_item, counts = [], {}, {}
            for iid in shown:
                it = store.get_item(iid)
                if not it:
                    continue
                h = store.item_handle(iid)
                text = _excerpt(org.match_body(it), limit)
                who = [org.people.label(p) for p in org.other_persons(iid)]
                for w in who:
                    counts[w] = counts.get(w, 0) + 1
                view = {"id": h, "t": org._local(it["started_at"])[:16].replace("T", " "),
                        "kind": build.KIND_LABEL.get(it["kind"], it["kind"]), "src": it["source_app"].get("name", ""),
                        "who": who, "text": text,
                        "dates": org._dates.resolve(text, it["started_at"]) + org._dates.resolve_ranges(text, it["started_at"])}
                seg = store.segment_of(iid)
                if seg:
                    view["part_of"] = store.item_handle(seg["parent_id"])
                items.append(view)
                handle_to_item[h] = iid
            facts = [{"id": f"f{n}", "text": f.get("text", ""), "state": f.get("state") or "info", "date": f.get("date") or "",
                      "items": [store.item_handle(i) for i in f.get("item_ids") or []]}
                     for n, f in enumerate(ev["status_facts"], 1)]
            others = []
            handle_to_event = {}
            for oid in self.other_matters(event_id, build.OTHER_MATTERS):
                o = store.get_event(oid)
                if o and not o["deleted"]:
                    h = store.event_handle(oid)
                    handle_to_event[h] = oid
                    others.append({"id": h, "title": o["title"], "anchor": o["anchor"] or ""})
            span = ""
            if ev.get("started_at") and ev.get("updated_at"):
                a, b = org._local(ev["started_at"])[:10], org._local(ev["updated_at"])[:10]
                span = a if a == b else f"{a}→{b}"
            ends = [(it.get("ended_at") or it["started_at"]) for it in (store.get_item(i) for i in ids[-5:]) if it]
            as_of = org._local(max(ends, key=lambda t: datetime.fromisoformat(t)) if ends else ev["updated_at"])[:10]
            data = {"matter": {"id": store.event_handle(event_id), "title": ev["title"], "anchor": ev["anchor"] or "",
                               "status_line": ev["status_line"], "item_count": len(ids), "shown": len(items),
                               "span": span, "as_of": as_of,
                               "people": sorted(counts, key=lambda w: (-counts[w], w))[:12]},
                    "facts": facts, "items": items, "other_matters": others}
            item_set = list(ids)
            digest = facts_digest(ev["status_facts"])
        schema = build.schema_for(self.skill.schema, data)
        context = build.context_for(data, owner=[a for a in getattr(org, "owner_aliases", ()) if a])
        return {"event_id": event_id, "data": data, "schema": schema, "context": context, "handle_to_item": handle_to_item,
                "handle_to_event": handle_to_event, "item_set": item_set, "facts_digest": digest,
                "reads": list(handle_to_item.values())}

    def call(self, ctx: dict):
        return self.org.harness.run("map", ctx["data"], context=ctx["context"], schema=ctx["schema"],
                                    subject=ctx["event_id"], reads=ctx["reads"], no_retry=self._rules.REPAIRABLE)

    # ---- applying ---------------------------------------------------------------------------

    def _usable(self, res, ctx: dict) -> tuple[Optional[dict], str]:
        if res.ok:
            return res.output, "written"
        # Repairable errors are fixed without a retry; after the retry, a knot whose quote is not verbatim is
        # dropped and an item listed under two strands keeps the first (validate.py SALVAGEABLE).
        fixed = self._rules.salvage(res.candidate, res.errors, ctx["context"], after_retry=res.attempts >= 2)
        if fixed is not None and not jsonschema_lite.validate(fixed, ctx["schema"]):
            return fixed, "repaired" if res.attempts < 2 else "salvaged"
        return None, "dropped"

    def _to_ids(self, finished: dict, ctx: dict, members: set[str]) -> dict:
        h2i, h2e = ctx["handle_to_item"], ctx["handle_to_event"]

        def ids(handles: list[str]) -> list[str]:
            return [h2i[h] for h in handles if h in h2i and h2i[h] in members]
        strands = [dict(s, item_ids=ids(s["item_ids"])) for s in finished["strands"]]
        knots = []
        for k in finished["knots"]:
            ev = ids(k["evidence"])
            q = h2i.get(k.get("quote_item") or "")
            if not ev or q not in members:
                continue
            knots.append(dict(k, evidence=ev, quote_item=q))
        health = finished.get("health")
        if health:
            health = dict(health, evidence=ids(health["evidence"]))
            if health["level"] != "ok" and not health["evidence"]:
                health = None
        blocks = []
        for b in finished.get("blocks") or []:
            other, item = h2e.get(b["other"]), h2i.get(b["item_id"])
            if other and item in members:
                blocks.append({"other": other, "direction": b["direction"], "item_id": item, "quote": b["quote"]})
        return {"strands": strands, "knots": knots, "health": health, "blocks": blocks}

    def apply(self, ctx: dict, res) -> str:
        org, store = self.org, self.store
        event_id = ctx["event_id"]
        if org._overtaken_by_purge(res.run_id, ctx["item_set"], "map", event_id):
            return "stale"  # the purge queued the event again
        out, outcome = self._usable(res, ctx)
        with store.tx():
            ev = store.get_event(event_id)
            if not ev or ev["deleted"]:
                store.x("DELETE FROM map_queue WHERE event_id=?", (event_id,))
                store.record_proposal(res.run_id, "map", event_id, {}, "superseded", "event deleted")
                return "stale"
            now_ids = store.event_item_ids(event_id)
            row = store.map_row(event_id)
            tries = (row["tries"] if row else 0) + 1
            store.x("DELETE FROM map_queue WHERE event_id=?", (event_id,))
            if out is None:
                cats = sorted(self._rules.categories(res.errors))
                if row is not None and row["map"] is not None and row["outcome"] != "purged":
                    # the previous map stays (it is outdated and is tried again when the matter changes); a map an
                    # item purge cut down is not kept on a failed redraw (review finding V7-M1)
                    store.x("UPDATE event_maps SET tries=?, run_id=? WHERE event_id=?", (tries, res.run_id, event_id))
                else:
                    store.x("INSERT OR REPLACE INTO event_maps(event_id, map, outcome, skill_version, run_id, item_set,"
                            " facts_digest, tries, stale, updated_at) VALUES (?,NULL,'dropped',?,?,?,?,?,0,?)",
                            (event_id, self.skill.version, res.run_id, json.dumps(ctx["item_set"]), ctx["facts_digest"],
                             tries, store.now()))
                store.record_proposal(res.run_id, "map", event_id, {"errors": res.errors[:6], "categories": cats},
                                      "rejected", "matter-map output invalid twice; map dropped")
                return "dropped"
            finished = self._build.finish(out, ctx["context"])
            stored = self._mask(self._to_ids(finished, ctx, set(now_ids)))
            store.x("INSERT OR REPLACE INTO event_maps(event_id, map, outcome, skill_version, run_id, item_set,"
                    " facts_digest, tries, stale, updated_at) VALUES (?,?,?,?,?,?,?,?,0,?)",
                    (event_id, json.dumps(stored, ensure_ascii=False, separators=(",", ":")), "ok", self.skill.version,
                     res.run_id, json.dumps(ctx["item_set"]), ctx["facts_digest"], 0, store.now()))
            self._write_blocks(event_id, stored["blocks"], res.run_id)
            store.touch_event(event_id)
            if self.outdated(event_id, now_ids):
                store.queue_map(event_id, 1, "grew")  # it changed during the call: drawn again later
            store.record_proposal(res.run_id, "map", event_id,
                                  {"strands": len(stored["strands"]), "knots": len(stored["knots"]),
                                   "health": (stored["health"] or {}).get("level"), "blocks": len(stored["blocks"]),
                                   "errors": res.errors[:6] if outcome == "repaired" else []},
                                  "applied" if outcome == "written" else "partial",
                                  {"written": "", "repaired": "repaired without retry",
                                   "salvaged": "salvaged after the retry"}[outcome])
        self.org.graph.reset()
        return outcome

    def _mask(self, m: dict) -> dict:
        """Defence in depth: the map's text fields are masked like any derived text (idempotent on the masked
        material it quotes, so a quote stays verbatim)."""
        mask = self.store.mask_text
        for s in m["strands"]:
            s["name"], s["summary"] = mask(s["name"]), mask(s["summary"])
        for k in m["knots"]:
            k["text"], k["quote"], k["who"] = mask(k["text"]), mask(k["quote"]), [mask(w) for w in k["who"]]
        if m.get("health"):
            m["health"]["reason"] = mask(m["health"]["reason"])
        for b in m["blocks"]:
            b["quote"] = mask(b["quote"])
        return m

    def _write_blocks(self, event_id: str, blocks: list[dict], run_id: Optional[str]) -> None:
        """Replace the blocks edges this matter's previous map proposed. A rejected edge is never proposed again."""
        store = self.store
        store.x("DELETE FROM relations WHERE kind='blocks' AND source_event=?", (event_id,))
        for b in blocks:
            a, w = (b["other"], event_id) if b["direction"] == "waits_on" else (event_id, b["other"])
            if a == w or store.has_constraint("reject_blocks", a, w):
                continue
            store.x("INSERT INTO relations(kind, a, b, item_id, quote, source_event, run_id, created_at)"
                    " VALUES ('blocks',?,?,?,?,?,?,?) ON CONFLICT(kind, a, b) DO NOTHING",
                    (a, w, b["item_id"], b["quote"], event_id, run_id, store.now()))
            self.stats["blocks"] += 1
