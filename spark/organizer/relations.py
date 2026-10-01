"""Relations v2 between matters (MAP-CONTRACT section 2) and the v7 read model: crossings, blocks, ropes, facets.

Three kinds, each grounded in a different kind of evidence:
  cross   two matters share an item (segments of one item filed into both) or a parent recording (a video and a
          keyframe of it). Computed here, deterministically, with no model; the strength is the number of shared
          items. Never stored: a hidden crossing is a constraint 'hide_crossing' (the user's decision).
  ply     ropes (skill matter-group, organizer/matter_group.py): a tree of areas and projects, each matter under at
          most one rope. Stored in ropes / rope_members.
  blocks  only from an explicit statement in an item ("等 A 的数据出来再写"), proposed by matter-map
          (organizer/matter_map.py) with the item and the verbatim quote; a blocks b means b waits on a. Stored in
          relations; a rejected edge becomes a constraint 'reject_blocks' and is never proposed again.

"Same matter" is not a relation (it stays a merge, event-consolidate); "continues" and "spun off" show up as a
crossing plus time order, or as a rope.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Optional

CROSS_ITEMS_SHOWN = 10


def crossings(store) -> dict[tuple[str, str], dict]:
    """{(a, b): {"count": n, "roots": [item ids]}} for every pair of live events that share an item or a parent
    recording (a < b by handle). The roots are client-visible item ids (a segment's parent item, a keyframe's
    media item, or the item itself)."""
    rows = store.all(
        "SELECT ei.event_id, e.handle, COALESCE(seg.parent_id, json_extract(li.meta, '$.parent_item_id'), ei.item_id)"
        " AS root FROM event_items ei JOIN events e ON e.event_id = ei.event_id AND e.deleted = 0"
        " JOIN latest_items li ON li.item_id = ei.item_id LEFT JOIN item_segments seg ON seg.child_id = ei.item_id"
        " WHERE ei.removed = 0 AND li.purged = 0")
    handle = {r["event_id"]: r["handle"] or 0 for r in rows}
    # keyed case-insensitively (a keyframe may name its media item in another case), reported as the item's own id
    by_root: dict[str, set[str]] = {}
    shown: dict[str, str] = {}
    for r in rows:
        key = str(r["root"]).lower()
        by_root.setdefault(key, set()).add(r["event_id"])
        if key not in shown or r["root"] == key.upper():
            shown[key] = str(r["root"])
    out: dict[tuple[str, str], dict] = {}
    for root, evs in sorted(by_root.items()):
        if len(evs) < 2:
            continue
        ordered = sorted(evs, key=lambda e: (handle[e], e))
        for i, a in enumerate(ordered):
            for b in ordered[i + 1:]:
                entry = out.setdefault((a, b), {"count": 0, "roots": []})
                entry["count"] += 1
                entry["roots"].append(shown[root])
    hidden = {(r["a"], r["b"]) for r in store.all("SELECT a, b FROM constraints WHERE kind='hide_crossing'")}
    return {k: v for k, v in out.items() if tuple(sorted(k)) not in hidden}


def crossing_counts(cross: dict[tuple[str, str], dict], event_id: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for (a, b), v in cross.items():
        if a == event_id:
            out[b] = v["count"]
        elif b == event_id:
            out[a] = v["count"]
    return out


def public_id(store, item_id: str) -> tuple[str, Optional[str]]:
    """(the item id a client knows, the segment id when it is a segment of a split item)."""
    seg = store.segment_of(item_id)
    return (seg["parent_id"], seg["seg_id"]) if seg else (item_id, None)


def facts_digest(facts: list[dict]) -> str:
    return hashlib.sha256(json.dumps([[f.get("text"), f.get("state"), f.get("date")] for f in facts or []],
                                     ensure_ascii=False).encode()).hexdigest()[:16]


class Graph:
    """The read model of maps, relations, ropes and facets for GET /v1/state. Holds only ids in memory (the
    crossing cache, keyed by the store cursor); dropped on lock."""

    def __init__(self, org: Any):
        self.org = org
        self.store = org.store
        self._cross: Optional[tuple[int, dict]] = None

    def reset(self) -> None:
        self._cross = None

    def cross(self) -> dict[tuple[str, str], dict]:
        cursor = self.store.cursor()
        cached = self._cross
        if cached is None or cached[0] != cursor:
            cached = self._cross = (cursor, crossings(self.store))
        return cached[1]

    # ---- per event ------------------------------------------------------------------------

    def map_view(self, ev: dict, member_ids: list[str]) -> Optional[dict]:
        """events[].map: the stored map with internal ids turned into client item ids (+ segment refs), filtered
        to the event's current items (a knot left with no evidence is not shown). None: no map yet (the Mac
        shows the facts on one thread and may POST /v1/events/{id}/map)."""
        if ev.get("deleted"):
            return None
        row = self.store.map_row(ev["event_id"])
        if not row or not row["map"]:
            return None
        m, members = row["map"], set(member_ids)
        pub: dict[str, tuple[str, Optional[str]]] = {}

        def conv(ids: list[str]) -> tuple[list[str], list[dict]]:
            items, segs = [], []
            for i in ids:
                if i not in members:
                    continue
                if i not in pub:
                    pub[i] = public_id(self.store, i)
                p, s = pub[i]
                if p not in items:
                    items.append(p)
                if s:
                    segs.append({"item_id": p, "seg_id": s})
            return items, segs

        current = row["facts_digest"] == facts_digest(ev.get("status_facts") or [])
        strands = []
        for s in m.get("strands") or []:
            items, segs = conv(s.get("item_ids") or [])
            strands.append({"id": s["id"], "name": s["name"], "summary": s.get("summary") or "", "item_ids": items,
                            "segment_refs": segs, "fact_ids": list(s.get("fact_ids") or []) if current else [],
                            "state": s.get("state") or "open"})
        knots = []
        for k in m.get("knots") or []:
            items, segs = conv(k.get("evidence") or [])
            if not items or k.get("quote_item") not in members:
                continue
            q_item, q_seg = pub.get(k["quote_item"]) or public_id(self.store, k["quote_item"])
            knots.append({"id": k["id"], "strand": k.get("strand"), "kind": k["kind"], "text": k["text"],
                          "date": k.get("date"), "state": k["state"], "who": list(k.get("who") or []),
                          "evidence": items, "segment_refs": segs, "quote": k.get("quote") or "",
                          "quote_item_id": q_item, "quote_seg_id": q_seg})
        # a strand left with no item of the matter and no knot shows nothing
        on = {k["strand"] for k in knots if k.get("strand")}
        strands = [s for s in strands if s["item_ids"] or s["segment_refs"] or s["id"] in on]
        health = None
        h = m.get("health")
        if h:
            items, segs = conv(h.get("evidence") or [])
            health = {"level": h["level"], "reason": h.get("reason") or "", "evidence": items, "segment_refs": segs}
        return {"strands": strands, "knots": knots, "health": health, "skill_version": row["skill_version"],
                "updated_at": row["updated_at"], "stale": bool(row["stale"]), "facts_current": current}

    def facets(self, ev: dict, today: Optional[str], health: Optional[str]) -> dict:
        """events[].facets: type (matter-group), rope, deadline (the nearest planned fact on or after today; else
        the latest overdue one), health (the map's verdict). People are the event's person_ids."""
        eid = ev["event_id"]
        t = self.store.one("SELECT type FROM event_facets WHERE event_id=?", (eid,))
        r = self.store.one("SELECT m.rope_id FROM rope_members m JOIN ropes r ON r.rope_id = m.rope_id"
                           " WHERE m.event_id=? AND r.state != 'rejected'", (eid,))
        planned = sorted({f["date"] for f in ev.get("status_facts") or []
                          if f.get("date") and f.get("state") in ("planned", "in_progress", None)})
        deadline, overdue = None, False
        if planned:
            ahead = [d for d in planned if today is None or d >= today]
            deadline, overdue = (ahead[0], False) if ahead else (planned[-1], True)
        return {"type": t["type"] if t else None, "rope": r["rope_id"] if r else None, "deadline": deadline,
                "deadline_overdue": overdue, "health": health}

    # ---- top-level lists ------------------------------------------------------------------

    def live_events(self) -> set[str]:
        return {r["event_id"] for r in self.store.all("SELECT event_id FROM events WHERE deleted = 0")}

    def relations(self, live: Optional[set[str]] = None) -> list[dict]:
        """The complete current set: crossings (computed, proposed false) and blocks edges (proposed true) between
        live events."""
        live = live if live is not None else self.live_events()
        out = []
        for (a, b), v in sorted(self.cross().items(), key=lambda kv: (-kv[1]["count"], kv[0])):
            out.append({"kind": "cross", "a": a, "b": b, "count": v["count"], "item_ids": v["roots"][:CROSS_ITEMS_SHOWN],
                        "proposed": False})
        for r in self.store.all("SELECT * FROM relations WHERE kind='blocks' ORDER BY created_at, a, b"):
            if r["a"] not in live or r["b"] not in live or self.store.has_constraint("reject_blocks", r["a"], r["b"]):
                continue
            item, seg = public_id(self.store, r["item_id"]) if r["item_id"] else (None, None)
            entry = {"kind": "blocks", "a": r["a"], "b": r["b"], "quote": r["quote"], "item_id": item,
                     "proposed": True, "source_event": r["source_event"]}
            if seg:
                entry["seg_id"] = seg
            out.append(entry)
        return out

    def ropes(self, live: Optional[set[str]] = None) -> list[dict]:
        """The complete current set of ropes (rejected ones never): children are live events; a model-proposed rope
        with no live child and no child rope is left out."""
        live = live if live is not None else self.live_events()
        rows = self.store.all("SELECT * FROM ropes WHERE state != 'rejected' ORDER BY handle")
        children: dict[str, list[str]] = {}
        for m in self.store.all("SELECT m.event_id, m.rope_id FROM rope_members m JOIN events e ON e.event_id = m.event_id"
                                " WHERE m.rope_id IS NOT NULL ORDER BY e.handle"):
            if m["event_id"] in live:
                children.setdefault(m["rope_id"], []).append(m["event_id"])
        alive = {r["rope_id"] for r in rows}
        sub: dict[str, int] = {}
        for r in rows:
            if r["parent"] in alive:
                sub[r["parent"]] = sub.get(r["parent"], 0) + 1
        out = []
        for r in rows:
            kids = children.get(r["rope_id"], [])
            if r["state"] == "proposed" and not kids and not sub.get(r["rope_id"]):
                continue
            evidence = []
            for i in json.loads(r["evidence"] or "[]"):
                p, _ = public_id(self.store, i)
                if p not in evidence:
                    evidence.append(p)
            out.append({"id": r["rope_id"], "handle": f"R{r['handle']}", "title": r["title"], "kind": r["kind"],
                        "parent": r["parent"] if r["parent"] in alive else None, "children": kids,
                        "proposed": r["state"] == "proposed", "title_user_edited": bool(r["title_user_edited"]),
                        "reason": r["reason"], "evidence": evidence})
        return out


def today_of(org) -> Optional[str]:
    try:
        return org._local(org.clock.now())[:10]
    except RuntimeError:
        return None

