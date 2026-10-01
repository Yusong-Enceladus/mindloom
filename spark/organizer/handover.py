"""Handover packs (v8 contract B3; skill handover-pack; docs/SPACES.md "交接").

When a matter changes hands (matter.handover in a shared space, or the user handing a personal matter to someone),
a member asks for "生成交接包": where the matter stands, the open commitments (who owes what to whom, by when),
the deadlines, the key decisions with a verbatim quote, the open questions, the materials to open first and the
first next steps. Every claim cites the items it rests on; the validator (skills/handover-pack/scripts/validate.py)
holds the quotes to verbatim and the dates and names to the material.

  POST …/handover-pack {"matter_id", "from"?, "to"?}   queue one (202 {"queued", "pack_id"}); the worker runs it at
                                                        its next step, before item jobs (someone is waiting)
  GET  …/handover-pack/{pack_id}                        {"status": queued|running|ready|failed, "pack", "markdown"}

Input (skills/handover-pack/scripts/build.py): the matter's card facts, its map's knots (already checked against
the material), and its items (every item a fact or knot cites, then the most recent, up to 120; masked text or
reading summary, shortened to a fixed budget). Names in "from" / "to" are the members' display names the Mac sends,
masked like any user text.

Storage and privacy: the pack is stored in the store (SQLCipher) with the ids of the items it cites; deleting or
withdrawing any of them deletes the pack (store.purge_graph); the run records the items it read, so its output
goes too. The Markdown export is rendered here with placeholders, and the Mac puts the originals back; in a shared
space the member shares it as a snapshot item (item.share, kind "snapshot"), end-to-end encrypted to the members.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from typing import Any, Optional

from . import jsonschema_lite
from .clients import ModelUnavailable, safe_error
from .store import StoreLocked

log = logging.getLogger("organizer.handover")

MAX_QUEUED = 8


def _excerpt(text: str, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


class HandoverPacks:
    def __init__(self, org: Any):
        self.org = org
        self.skill = org.registry.for_job("handover")
        self._build = org.registry.script("handover-pack", "build")
        self._rules = org.registry.script("handover-pack", "validate")
        self._render = org.registry.script("handover-pack", "render")
        self.stats = {"requests": 0, "ready": 0, "repaired": 0, "salvaged": 0, "failed": 0}

    @property
    def store(self):
        return self.org.store

    # ---- queue ----------------------------------------------------------------------------------------

    def request(self, event_id: str, people: Optional[dict] = None) -> Optional[dict]:
        """None: unknown or deleted matter."""
        store = self.store
        ev = store.get_event(event_id)
        if not ev or ev["deleted"]:
            return None
        if not store.event_item_ids(event_id):
            return {"queued": False, "reason": "empty"}
        queued = int(store.scalar("SELECT COUNT(*) FROM handover_packs WHERE status IN ('queued','running')") or 0)
        if queued >= MAX_QUEUED:
            return {"queued": False, "reason": "busy"}
        names = {}
        for key in ("from", "to"):
            value = (people or {}).get(key)
            if isinstance(value, str) and value.strip():
                names[key] = store.mask_text(value.strip()[:40])
        pack_id = str(uuid.uuid4())
        now = store.now()
        store.x("INSERT INTO handover_packs(pack_id, event_id, status, people, created_at, updated_at)"
                " VALUES (?,?,'queued',?,?,?)", (pack_id, event_id, json.dumps(names, ensure_ascii=False), now, now))
        self.stats["requests"] += 1
        self.org.wake()
        return {"queued": True, "pack_id": pack_id}

    def due(self) -> bool:
        return self.store.one("SELECT 1 FROM handover_packs WHERE status='queued' LIMIT 1") is not None

    def _finish(self, pack_id: str, status: str, **fields: Any) -> None:
        sets = ", ".join(f"{k}=?" for k in fields)
        self.store.x(f"UPDATE handover_packs SET status=?, updated_at=?{', ' + sets if sets else ''} WHERE pack_id=?",
                     (status, self.store.now(), *fields.values(), pack_id))

    # ---- one pack --------------------------------------------------------------------------------------

    def context(self, event_id: str, people: dict) -> Optional[dict]:
        org, store, build = self.org, self.store, self._build
        with store.tx():
            ev = store.get_event(event_id)
            if not ev or ev["deleted"]:
                return None
            ids = store.event_item_ids(event_id)
            if not ids:
                return None
            mrow = store.map_row(event_id)
            knots_raw = ((mrow or {}).get("map") or {}).get("knots") or []
            cited = [i for f in ev["status_facts"] for i in f.get("item_ids") or []]
            cited += [i for k in knots_raw for i in (k.get("evidence") or [])]
            shown = build.select(ids, cited, build.MAX_ITEMS)
            limit = build.text_limit(len(shown))
            items, handle_to_item, counts, sources = [], {}, {}, {}
            for iid in shown:
                it = store.get_item(iid)
                if not it:
                    continue
                h = store.item_handle(iid)
                text = _excerpt(org.match_body(it), limit)
                who = [org.people.label(p) for p in org.other_persons(iid)]
                for w in who:
                    counts[w] = counts.get(w, 0) + 1
                t = org._local(it["started_at"])[:16].replace("T", " ")
                kind = build.KIND_LABEL.get(it["kind"], it["kind"])
                src = it["source_app"].get("name", "")
                items.append({"id": h, "t": t, "kind": kind, "src": src, "who": who, "text": text,
                              "dates": org._dates.resolve(text, it["started_at"])
                              + org._dates.resolve_ranges(text, it["started_at"])})
                handle_to_item[h] = iid
                sources[iid] = {"t": t, "kind": kind, "src": src}
            item_to_handle = {v: k for k, v in handle_to_item.items()}
            facts = [{"id": f"f{n}", "text": f.get("text", ""), "state": f.get("state") or "info",
                      "date": f.get("date") or "",
                      "items": [item_to_handle[i] for i in f.get("item_ids") or [] if i in item_to_handle]}
                     for n, f in enumerate(ev["status_facts"], 1)]
            knots = [{"kind": k.get("kind"), "text": k.get("text", ""), "date": k.get("date") or "",
                      "state": k.get("state"), "who": list(k.get("who") or []),
                      "evidence": [item_to_handle[i] for i in k.get("evidence") or [] if i in item_to_handle],
                      "quote": k.get("quote", "")} for k in knots_raw]
            knots = [k for k in knots if k["evidence"]]
            ends = [(it.get("ended_at") or it["started_at"]) for it in (store.get_item(i) for i in ids[-5:]) if it]
            as_of = org._local(max(ends, key=lambda t: datetime.fromisoformat(t)) if ends else ev["updated_at"])[:10]
            data = {"matter": {"id": store.event_handle(event_id), "title": ev["title"], "anchor": ev["anchor"] or "",
                               "status_line": ev["status_line"], "item_count": len(ids), "shown": len(items),
                               "as_of": as_of, "people": sorted(counts, key=lambda w: (-counts[w], w))[:12],
                               "from": people.get("from", ""), "to": people.get("to", "")},
                    "facts": facts, "knots": knots, "items": items}
        schema = build.schema_for(self.skill.schema, data)
        context = build.context_for(data, owner=[a for a in getattr(org, "owner_aliases", ()) if a])
        return {"event_id": event_id, "data": data, "schema": schema, "context": context,
                "handle_to_item": handle_to_item, "item_set": list(ids), "sources": sources, "as_of": as_of,
                "title": ev["title"], "reads": list(handle_to_item.values())}

    def call(self, ctx: dict):
        return self.org.harness.run("handover", ctx["data"], context=ctx["context"], schema=ctx["schema"],
                                    subject=ctx["event_id"], reads=ctx["reads"], no_retry=self._rules.REPAIRABLE)

    def _usable(self, res, ctx: dict) -> tuple[Optional[dict], str]:
        if res.ok:
            return res.output, "ready"
        fixed = self._rules.salvage(res.candidate, res.errors, ctx["context"], after_retry=res.attempts >= 2)
        if fixed is not None and not jsonschema_lite.validate(fixed, ctx["schema"]):
            return fixed, "repaired" if res.attempts < 2 else "salvaged"
        return None, "failed"

    def _to_ids(self, finished: dict, ctx: dict) -> dict:
        h2i = ctx["handle_to_item"]

        def ids(handles):
            return [h2i[h] for h in handles or [] if h in h2i]
        out = {"status": {"text": finished["status"]["text"], "evidence": ids(finished["status"]["evidence"])}}
        for key in ("commitments", "deadlines", "decisions", "open_questions", "next_steps"):
            out[key] = []
            for e in finished[key]:
                ev = ids(e["evidence"])
                if not ev:
                    continue
                entry = dict(e, evidence=ev)
                if "quote_item" in e:
                    entry["quote_item"] = h2i.get(e["quote_item"] or "")
                out[key].append(entry)
        out["links"] = [{"item": h2i[ln["item"]], "why": ln["why"]} for ln in finished["links"] if ln["item"] in h2i]
        return out

    def run_one(self) -> bool:
        """The oldest queued pack. The model being down or the store being locked propagates (the row goes back
        to the queue); anything else fails this pack only."""
        store = self.store
        row = store.one("SELECT * FROM handover_packs WHERE status='queued' ORDER BY created_at, pack_id LIMIT 1")
        if row is None:
            return False
        pack_id = row["pack_id"]
        self._finish(pack_id, "running")
        try:
            ctx = self.context(row["event_id"], json.loads(row["people"] or "{}"))
            if ctx is None:
                self._finish(pack_id, "failed", error="gone")
                return True
            res = self.call(ctx)
            if self.org._overtaken_by_purge(res.run_id, ctx["item_set"], "handover", row["event_id"]):
                self._finish(pack_id, "failed", error="item_deleted", run_id=res.run_id)
                return True
            usable, outcome = self._usable(res, ctx)
            if usable is None:
                self.stats["failed"] += 1
                self._finish(pack_id, "failed", error="invalid", run_id=res.run_id)
                return True
            finished = self._build.finish(usable, ctx["context"])
            pack = self._to_ids(finished, ctx)
            pack["title"] = ctx["title"]
            pack["sources"] = {i: ctx["sources"][i] for i in self._build.cited(pack) if i in ctx["sources"]}
            pack["provenance"] = dict(res.provenance, outcome=outcome)
            self.stats["ready"] += 1
            if outcome in ("repaired", "salvaged"):
                self.stats[outcome] += 1
            self._finish(pack_id, "ready", pack=json.dumps(pack, ensure_ascii=False), run_id=res.run_id,
                         item_set=json.dumps(ctx["item_set"]), as_of=ctx["as_of"])
            return True
        except (ModelUnavailable, StoreLocked):
            try:
                self._finish(pack_id, "queued")
            except StoreLocked:
                pass
            raise
        except Exception as exc:  # noqa: BLE001 - one bad pack never stops the worker
            log.warning("handover pack failed: %s", safe_error(exc))
            self.stats["failed"] += 1
            self._finish(pack_id, "failed", error="internal")
            return True

    # ---- reading ---------------------------------------------------------------------------------------

    def get(self, pack_id: str) -> Optional[dict]:
        row = self.store.one("SELECT * FROM handover_packs WHERE pack_id=?", (pack_id,))
        if row is None:
            return None
        out = {"pack_id": pack_id, "event_id": row["event_id"], "status": row["status"],
               "created_at": row["created_at"], "updated_at": row["updated_at"], "as_of": row["as_of"]}
        if row["status"] == "failed":
            out["error"] = row["error"]
        if row["status"] == "ready" and row["pack"]:
            pack = json.loads(row["pack"])
            people = json.loads(row["people"] or "{}")
            out["pack"] = pack
            out["people"] = people
            out["markdown"] = self._render.render(pack, pack.get("sources") or {}, pack.get("title") or "",
                                                  row["as_of"] or "", people)
        return out

    def queued_for(self, event_id: str) -> list[str]:
        return [r["pack_id"] for r in self.store.all(
            "SELECT pack_id FROM handover_packs WHERE event_id=? ORDER BY created_at", (event_id,))]
