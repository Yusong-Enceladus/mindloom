"""A shared space's organizer (SPACES-CONTRACT section 3, "Organizing a shared space").

Each space has its own organizer store, <data_dir>/spaces/<space_id>/organizer.db: the same SQLCipher store and
the same skills as the personal organizer (image-read, file-read, item-split, event-assign, event-brief,
event-consolidate, person-resolve, home-rank), assembling shared matters from all members' shared items.

  1. A member Mac takes the lease: POST .../organizer/lease with the space's store key and mask key, both derived
     from the space key on the Mac (organizer/space_member.py). The Spark keeps them in memory only, like the v6
     library key; it never receives the space key itself, so it cannot open item keys, fields or blobs. The store
     locks itself after the lease runs out (no request from a member for ORGANIZER_UNLOCK_LEASE_S), on
     POST .../organizer/lock, and on a restart. After a key rotation the Mac sends the previous epoch's store key
     too and the store is re-keyed on the spot.
  2. A contributor's Mac with the lease sends the organizing payload of shared items (masked text with the space's
     mask key, shrunk images: the v6 item format). The Spark masks it again (defence in depth); people are kept by
     name only (voice-derived person ids are replaced by ids made from the name, so nothing from a voiceprint
     reaches a shared store). Only items that are shared and active in the space's log, at the shared revision,
     are accepted.
  3. Members pull the derived state (events = shared matters, with "same_as": the "同一件事" links from each
     shared matter back to the members' personal matters, by the origin matter id each payload carried).
  4. A member who shares "这件事" has already filed those items together on their Mac: the package (the items
     carrying the same origin matter id from one member) is the sharer's own filing, the user layer the contract
     passes as a hint. When the worker is idle, an item whose package mostly sits in one shared matter (more
     than half of three or more placed items) but which has no part there is moved to it (package_cohesion
     below); an item the model split into several matters is left as it is. A moved item stays a model
     placement, so consolidation can still merge that matter with another member's version; a maintainer's
     decision always wins, and each item is moved at most once.

If no member is online, organizing waits; capture is never affected. A withdrawn or removed item is purged from
the store at once when it is open, otherwise at the next lease, before anything else.
"""

from __future__ import annotations

import dataclasses
import hashlib
import logging
import threading
from pathlib import Path
from typing import Any, Optional

from . import keys
from . import space_crypto as sc
from .clock import from_setting
from .config import Settings
from .decisions import answer_question, apply_decision
from .schemas import DecisionsIn, Item
from .spaces import ROLES, Actor, SpaceError, Spaces, _item_id
from .store import Store, StoreLocked, WrongKey

log = logging.getLogger("organizer.spaces")

ORIGINS_DDL = ("CREATE TABLE IF NOT EXISTS space_item_origins(item_id TEXT PRIMARY KEY, member_id TEXT NOT NULL,"
               " matter_id TEXT)")
# Items the package step moved (ids only): never moved a second time.
PACKAGE_MOVES_DDL = ("CREATE TABLE IF NOT EXISTS space_package_moves(item_id TEXT PRIMARY KEY,"
                     " event_id TEXT NOT NULL)")
PACKAGE_MIN_ITEMS = 3


def _key(value: object, name: str) -> bytes:
    if not isinstance(value, str) or keys.KEY_HEX_RE.fullmatch(value) is None:
        raise SpaceError(400, "bad_key", f"{name} is 64 hex characters")
    return bytes.fromhex(value)


def _read_sidecar(path: Path) -> Optional[str]:
    try:
        value = path.read_text(encoding="ascii", errors="replace").strip()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return value or None


def _write_sidecar(path: Path, value: str) -> None:
    import os
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(fd, value.encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def name_person_id(space_id: str, name: str) -> str:
    """A person in a shared space is a name: the same name is the same person id for every member's items."""
    return "sp-" + hashlib.sha256(f"{space_id}|{name.strip()}".encode("utf-8")).hexdigest()[:16]


class SpaceOrganizers:
    def __init__(self, spaces: Spaces, settings: Settings, chat: Any, embedder: Any, *,
                 start_worker: Optional[bool] = None):
        self.spaces = spaces
        self.settings = settings
        self.chat = chat
        self.embedder = embedder
        self.start_worker = settings.start_worker if start_worker is None else start_worker
        self.lease_s = float(settings.unlock_lease_s or 0)
        self._orgs: dict[str, Any] = {}
        self._holders: dict[str, dict] = {}
        self._threads: dict[str, threading.Thread] = {}
        self._stop = threading.Event()
        self._lock = threading.RLock()
        spaces.on_purge = self.purge
        spaces.on_rotate = self.rotated

    # ---- instances ---------------------------------------------------------------------------------

    def get(self, space_id: str):
        with self._lock:
            org = self._orgs.get(space_id)
            if org is not None:
                return org
            from .api import build_organizer  # late: api imports this module
            store = Store(self.spaces.space_dir(space_id) / "organizer.db", from_setting(self.settings.clock))
            # In a shared space "我" is whoever contributed the item: the Spark owner's own names and person ids
            # (ORGANIZER_OWNER_ALIASES / _IDS) are not the members' owner, so only the generic self-words apply.
            space_settings = dataclasses.replace(self.settings, owner_aliases=("我", "本人", "自己"),
                                                 owner_person_ids=())
            org = build_organizer(space_settings, chat=self.chat, embedder=self.embedder, store=store,
                                  with_inbox=False)
            org.unlock_lease_s = self.lease_s
            org.idle_hooks.append(PackageCohesion(org))
            # v8 B6: members take turns in the job queue; matters with a near deadline are organized first.
            store.fair_members = True
            store.deadline_days = max(0, int(getattr(self.settings, "deadline_days", 7)))
            store.today = org._today
            self._orgs[space_id] = org
            if self.start_worker:
                t = threading.Thread(target=org.run_worker, args=(self._stop,), name=f"space-worker-{space_id[:8]}",
                                     daemon=True)
                t.start()
                self._threads[space_id] = t
            return org

    def expire(self, space_id: Optional[str] = None) -> None:
        with self._lock:
            items = [(space_id, self._orgs.get(space_id))] if space_id else list(self._orgs.items())
        for sid, org in items:
            if org is not None and org.expire_lease():
                self.spaces.audit("organizer.lease_expired", {}, space_id=sid)
                self._holders.pop(sid, None)

    def shutdown(self) -> None:
        self._stop.set()
        with self._lock:
            orgs = list(self._orgs.values())
        for org in orgs:
            org.wake()
        for t in list(self._threads.values()):
            t.join(timeout=10)
        for org in orgs:
            if org.pipeline is not None:
                org.pipeline.shutdown()

    def unlocked_count(self) -> int:
        with self._lock:
            return sum(1 for o in self._orgs.values() if not o.store.locked)

    def status(self, space_id: str) -> dict:
        d = self.spaces.space_dir(space_id)
        org = self._orgs.get(space_id)
        locked = org is None or org.store.locked
        holder = self._holders.get(space_id) if not locked else None
        epoch = _read_sidecar(d / "store.epoch")
        return {"locked": locked, "key_id": keys.read_key_id(d / "store.keyid"),
                "epoch": int(epoch) if epoch and epoch.isdigit() else None,
                "lease_holder": holder["device_id"] if holder else None, "lease_s": self.lease_s}

    def _open_org(self, space_id: str):
        self.expire(space_id)
        org = self.get(space_id)
        if org.store.locked:
            raise SpaceError(423, "locked", "no member Mac holds the lease; organizing waits")
        return org

    # ---- lease -------------------------------------------------------------------------------------

    def lease(self, actor: Actor, body: object) -> dict:
        if not isinstance(body, dict):
            raise SpaceError(400, "bad_request", "the lease is an object")
        space = self.spaces.space(actor.space_id)
        store_key = _key(body.get("store_key"), "store_key")
        mask_key = _key(body.get("mask_key"), "mask_key")
        if body.get("epoch") != space["epoch"]:
            raise SpaceError(409, "stale_epoch", "lease with the current epoch's store key", epoch=space["epoch"])
        previous = None
        prev = body.get("previous")
        if prev is not None:
            if not isinstance(prev, dict) or not isinstance(prev.get("epoch"), int) or prev["epoch"] >= space["epoch"]:
                raise SpaceError(400, "bad_request", "previous is {epoch < current, store_key}")
            pk = _key(prev.get("store_key"), "previous.store_key")
            previous = (sc.store_key_id(pk), pk)
        d = self.spaces.space_dir(actor.space_id)
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        mask_id = sc.mask_key_id(mask_key)
        on_disk_mask = _read_sidecar(d / "store.maskid")
        if on_disk_mask is not None and on_disk_mask != mask_id:
            raise SpaceError(409, "wrong_mask_key", "the space's mask key comes from its first epoch")
        org = self.get(actor.space_id)
        key_id = sc.store_key_id(store_key)
        try:
            res = org.unlock_leased(key_id, store_key, mask_key, previous)
        except WrongKey as exc:
            epoch = _read_sidecar(d / "store.epoch")
            raise SpaceError(409, "wrong_key", key_id=exc.key_id,
                             epoch=int(epoch) if epoch and epoch.isdigit() else None) from None
        finally:
            del store_key, mask_key
        if on_disk_mask is None:
            _write_sidecar(d / "store.maskid", mask_id)
        _write_sidecar(d / "store.epoch", str(space["epoch"]))
        org.store.x(ORIGINS_DDL)
        purged = self._apply_queued_purges(actor.space_id, org)
        self._holders[actor.space_id] = {"device_id": actor.device_id, "member_id": actor.member_id}
        self.spaces.audit("organizer.lease", {"epoch": space["epoch"], "previous": previous is not None,
                                              "purged": purged},
                          space_id=actor.space_id, member_id=actor.member_id, device_id=actor.device_id)
        return {"locked": False, "key_id": res["key_id"], "created": res["created"], "store_id": res["store_id"],
                "epoch": space["epoch"], "lease_s": self.lease_s, "purged": purged}

    def lock(self, actor: Actor) -> dict:
        org = self._orgs.get(actor.space_id)
        if org is not None:
            org.lock()
        self._holders.pop(actor.space_id, None)
        self.spaces.audit("organizer.lock", {}, space_id=actor.space_id, member_id=actor.member_id,
                          device_id=actor.device_id)
        return {"locked": True}

    def rotated(self, space_id: str) -> None:
        """The space key rotated: close the store (its key came from the old epoch)."""
        org = self._orgs.get(space_id)
        if org is not None and not org.store.locked:
            org.lock()
            self.spaces.audit("organizer.lock", {"reason": "rotation"}, space_id=space_id)
        self._holders.pop(space_id, None)

    def renew(self, space_id: str) -> None:
        org = self._orgs.get(space_id)
        if org is not None and not org.store.locked:
            org.renew_lease()

    # ---- purge -----------------------------------------------------------------------------------

    def _apply_queued_purges(self, space_id: str, org) -> int:
        n = 0
        for item_id in self.spaces.queued_purges(space_id):
            self._purge_open(org, item_id)
            self.spaces.purge_done(space_id, item_id)
            n += 1
        return n

    @staticmethod
    def _purge_open(org, item_id: str) -> None:
        org.delete_item(item_id)
        org.store.x(ORIGINS_DDL)
        org.store.x("DELETE FROM space_item_origins WHERE item_id=?", (item_id,))
        org.store.x(PACKAGE_MOVES_DDL)
        org.store.x("DELETE FROM space_package_moves WHERE item_id=?", (item_id,))

    def purge(self, space_id: str, item_id: str) -> None:
        """Called after an item is withdrawn or removed: purged now if the store is open, else at the next lease
        (the queue row in spaces.db holds only the id)."""
        org = self._orgs.get(space_id)
        if org is None or org.store.locked:
            return
        try:
            self._purge_open(org, item_id)
        except StoreLocked:
            return
        self.spaces.purge_done(space_id, item_id)

    # ---- organizing ------------------------------------------------------------------------------

    def pending(self, actor: Actor, limit: int = 200) -> dict:
        """Shared items whose organizing payload the space's store does not have yet (at their shared revision)."""
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        out = []
        for it in self.spaces.active_items(actor.space_id):
            have = org.store.latest_revision(it["item_id"])
            if have is None or have < it["revision"]:
                out.append({"item_id": it["item_id"], "revision": it["revision"], "contributor": it["contributor"],
                            "kind": it["kind"]})
                if len(out) >= limit:
                    break
        return {"items": out}

    def ingest(self, actor: Actor, body: object) -> dict:
        if actor.role < ROLES["write"]:
            raise SpaceError(403, "forbidden", "organizing payloads come from contributors (role write)")
        if not isinstance(body, dict) or not isinstance(body.get("items"), list) or not 0 < len(body["items"]) <= 100:
            raise SpaceError(400, "bad_request", "items is a list of 1-100")
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        dicts, images, origins = [], [], []
        for raw in body["items"]:
            if not isinstance(raw, dict):
                raise SpaceError(400, "bad_request", "an item is an object")
            item_id = _item_id(raw.get("item_id") or raw.get("id"))
            shared = self.spaces.item(actor.space_id, item_id)
            if shared is None:
                raise SpaceError(404, "unknown_item", item_id=item_id)
            if shared["status"] != "active":
                raise SpaceError(410, "item_gone", item_id=item_id)
            if raw.get("revision") != shared["revision"]:
                raise SpaceError(409, "revision_mismatch", "send the shared revision", item_id=item_id,
                                 revision=shared["revision"])
            if (raw.get("bytes_b64") is not None or raw.get("image_b64") is not None) and \
                    self.spaces.has_audio(actor.space_id, item_id, shared["kind"]):
                # v8 C1: a meeting part's audio goes to the members only, encrypted; the organizer reads its masked
                # transcript, never sound or a file of it
                raise SpaceError(422, "audio_not_for_organizer", "send the part's masked transcript only",
                                 item_id=item_id)
            matter = raw.get("origin_matter_id")
            if matter is not None and not (isinstance(matter, str) and 0 < len(matter) <= 64):
                raise SpaceError(400, "bad_request", "origin_matter_id is an id")
            raw = {k: v for k, v in raw.items() if k not in ("origin_matter_id", "id")}
            raw["item_id"] = item_id
            if raw.get("parent_item_id"):
                raw["parent_item_id"] = str(raw["parent_item_id"]).lower()
            try:
                it = Item.model_validate(raw)
            except Exception as exc:  # pydantic's message may quote the payload: only its type goes back
                raise SpaceError(422, "bad_item", type(exc).__name__, item_id=item_id) from None
            d = it.model_dump(mode="json", exclude={"image_b64", "bytes_b64"})
            d["started_at"] = it.started_at.isoformat()
            d["ended_at"] = it.ended_at.isoformat() if it.ended_at else None
            d["captured_at"] = it.captured_at.isoformat() if it.captured_at else None
            _names_only(actor.space_id, d)
            dicts.append(d)
            images.append(it.blob())
            origins.append((item_id, shared["contributor"], matter))
        if org.store.tombstoned([d["item_id"] for d in dicts]):
            raise SpaceError(410, "item_gone")
        with org.store.tx():
            org.store.x(ORIGINS_DDL)
            for item_id, member_id, matter in origins:
                org.store.x("INSERT INTO space_item_origins(item_id, member_id, matter_id) VALUES (?,?,?)"
                            " ON CONFLICT(item_id) DO UPDATE SET member_id=excluded.member_id,"
                            " matter_id=COALESCE(excluded.matter_id, space_item_origins.matter_id)",
                            (item_id, member_id, matter))
        accepted, duplicates = org.ingest(dicts, images)
        return {"accepted": accepted, "duplicates": duplicates}

    def state(self, actor: Actor, since: int) -> dict:
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        out = org.state(since)
        out["store_id"] = org.store.store_id
        out["same_as"] = self._same_as(org)
        # organizing still to do (items queued or running, matters waiting for their brief): "正在整理…"
        out["busy"] = {"queue": org.store.queue_depth(),
                       "briefs": org.store.scalar("SELECT COUNT(*) FROM events WHERE needs_brief=1 AND deleted=0")}
        return out

    @staticmethod
    def _same_as(org) -> list[dict]:
        """"同一件事": each shared matter, per member, the member's personal matters its items came from."""
        store = org.store
        store.x(ORIGINS_DDL)
        origins = {r["item_id"]: r for r in store.all("SELECT * FROM space_item_origins")}
        links: dict[tuple, int] = {}
        for ev in store.live_events():
            seen = set()
            for iid in store.event_item_ids(ev["event_id"]):
                seg = store.segment_of(iid)
                parent = seg["parent_id"] if seg else iid
                if parent in seen:
                    continue
                seen.add(parent)
                o = origins.get(parent)
                if o and o["matter_id"]:
                    key = (ev["event_id"], o["member_id"], o["matter_id"])
                    links[key] = links.get(key, 0) + 1
        return [{"event_id": e, "member_id": m, "matter_id": t, "items": n} for (e, m, t), n in sorted(links.items())]

    def handover_request(self, actor: Actor, body: object) -> dict:
        """v8 B3: queue a handover pack of a shared matter (contributors; the member about to hand it over)."""
        if not isinstance(body, dict) or not isinstance(body.get("matter_id"), str) or not 0 < len(body["matter_id"]) <= 64:
            raise SpaceError(400, "bad_request", "matter_id is the shared matter's id")
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        res = org.handover.request(body["matter_id"], {k: body.get(k) for k in ("from", "to")})
        if res is None:
            raise SpaceError(404, "unknown_matter")
        self.spaces.audit("organizer.handover_pack", {"matter_id": body["matter_id"], "queued": res["queued"]},
                          space_id=actor.space_id, member_id=actor.member_id, device_id=actor.device_id)
        return res

    def handover_get(self, actor: Actor, pack_id: str) -> dict:
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        out = org.handover.get(pack_id) if isinstance(pack_id, str) and len(pack_id) <= 64 else None
        if out is None:
            raise SpaceError(404, "unknown_pack")
        return out

    def questions(self, space_id: str) -> list[dict]:
        """The space organizer's open questions (AI merge / same-person proposals) for the maintainers' queue,
        when the store is open."""
        org = self._orgs.get(space_id)
        if org is None or org.store.locked:
            return []
        try:
            return org.state(10 ** 12)["questions"]
        except StoreLocked:
            return []

    def decisions(self, actor: Actor, body: object) -> dict:
        """Maintainers edit shared matters directly (contributors propose instead)."""
        if actor.role < ROLES["maintain"]:
            raise SpaceError(403, "forbidden", "maintainers edit directly; contributors send a proposal")
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        try:
            parsed = DecisionsIn.model_validate(body)
        except Exception as exc:
            raise SpaceError(422, "bad_decisions", type(exc).__name__) from None
        applied, rejected = 0, []
        for i, d in enumerate(parsed.decisions):
            decision = d.model_dump()
            for key in ("title", "display_name"):
                if decision.get(key):
                    decision[key] = org.store.mask_text(decision[key])
            ok, note = apply_decision(org, decision, origin="user")
            if ok:
                applied += 1
            else:
                rejected.append({"index": i, "reason": note})
        self.spaces.audit("organizer.decisions", {"applied": applied, "rejected": len(rejected)},
                          space_id=actor.space_id, member_id=actor.member_id, device_id=actor.device_id)
        return {"applied": applied, "rejected": rejected}

    def answer(self, actor: Actor, question_id: str, body: object) -> dict:
        if actor.role < ROLES["maintain"]:
            raise SpaceError(403, "forbidden", "maintainers answer the organizer's proposals")
        org = self._open_org(actor.space_id)
        self.renew(actor.space_id)
        answer = body.get("answer") if isinstance(body, dict) else None
        if not isinstance(answer, str):
            raise SpaceError(400, "bad_request", "answer is a string")
        status, note = answer_question(org, question_id, answer)
        if status != 200:
            raise SpaceError(status, "answer_refused", note)
        self.spaces.audit("organizer.answer", {"question_id": question_id}, space_id=actor.space_id,
                          member_id=actor.member_id, device_id=actor.device_id)
        return {"ok": True, "applied": True, "note": note}


class PackageCohesion:
    """The organizer's idle hook for a space store: runs package_cohesion when the store changed since the last
    run (an idle worker polls every second)."""

    def __init__(self, org):
        self.org = org
        self._cursor: Optional[int] = None
        self.moved = 0

    def __call__(self) -> bool:
        cursor = self.org.store.cursor()
        if cursor == self._cursor:
            return False
        n = package_cohesion(self.org)
        self._cursor = self.org.store.cursor()
        self.moved += n
        if n:
            log.info("package step: %d item(s) moved to their package's shared matter", n)
        return n > 0


def _placement(store, item_id: str) -> tuple[list[str], list[dict]]:
    """The ids an item is filed by (its active segments, or itself) and their live event links."""
    parts = [s["child_id"] for s in store.segments_of(item_id)] or [item_id]
    links = []
    for part in parts:
        link = store.current_event_link(part)
        if link and not link["deleted"]:
            links.append(link)
    return parts, links


def package_cohesion(org) -> int:
    """Keep each shared package together (module docstring, step 4). Returns the number of items moved."""
    store = org.store
    store.x(ORIGINS_DDL)
    store.x(PACKAGE_MOVES_DDL)
    groups: dict[tuple, list[str]] = {}
    for r in store.all("SELECT item_id, member_id, matter_id FROM space_item_origins WHERE matter_id IS NOT NULL"
                       " ORDER BY item_id"):
        groups.setdefault((r["member_id"], r["matter_id"]), []).append(r["item_id"])
    moved_before = {r["item_id"] for r in store.all("SELECT item_id FROM space_package_moves")}
    moved = 0
    for ids in groups.values():
        placed = {}
        for item_id in ids:
            if store.latest_revision(item_id) is None or store.is_tombstoned(item_id):
                continue
            placed[item_id] = _placement(store, item_id)
        if len(placed) < PACKAGE_MIN_ITEMS:
            continue
        tally: dict[str, int] = {}
        for _, links in placed.values():
            for event_id in {link["event_id"] for link in links}:
                tally[event_id] = tally.get(event_id, 0) + 1
        if not tally:
            continue
        main = max(sorted(tally), key=lambda e: tally[e])
        if tally[main] * 2 <= len(placed):
            continue  # no clear home: the model's grouping stands
        for item_id, (parts, links) in placed.items():
            if item_id in moved_before or any(link["event_id"] == main for link in links):
                continue
            if len(parts) > 1:
                continue  # split by the model into several matters: that judgement stands
            # A maintainer's decision wins: an item kept out of that matter, or placed or unfiled by hand.
            if any(link["attached_by"] != "model" for link in links):
                continue
            if any(store.has_constraint("forbid_item_event", p, main)
                   or store.one("SELECT 1 FROM constraints WHERE kind='lock_item' AND a=?", (p,))
                   or store.one("SELECT 1 FROM unfiled WHERE item_id=? AND reason='user'", (p,))
                   for p in parts):
                continue
            with store.tx():
                for link in links:
                    store.detach(link["event_id"], link["item_id"], "package")
                for part in parts:
                    store.attach(main, part, "model", None)
                store.x("INSERT OR REPLACE INTO space_package_moves(item_id, event_id) VALUES (?,?)",
                        (item_id, main))
            moved += 1
    return moved


def _names_only(space_id: str, item: dict) -> None:
    """People in a shared space are names: a person id from the Mac (a voice cluster) is replaced by an id made
    from the display name; a person without a name is dropped, and a segment's speaker keeps only a mapped id."""
    mapping: dict[str, str] = {}
    persons = []
    for p in item.get("persons") or []:
        name = (p.get("display_name") or "").strip()
        if not name:
            continue
        pid = name_person_id(space_id, name)
        mapping[p["person_id"]] = pid
        if all(x["person_id"] != pid for x in persons):
            persons.append({"person_id": pid, "display_name": name})
    if item.get("persons") is not None:
        item["persons"] = persons
    if item.get("segments"):
        item["segments"] = [dict(s, person_id=mapping.get(s.get("person_id"))) for s in item["segments"]]
