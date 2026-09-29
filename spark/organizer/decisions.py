"""Explicit user decisions. They are recorded permanently and always win over model output.

same_event / same_person accept ids of either kind:
  same_event(a, b): two events -> merge b into a (yes) or keep apart (no);
                    an item and an event -> move the item there (yes) or never put it there (no);
                    two items -> put b with a's event (yes) or keep b out of a's event (no).
  same_person(a, b): merge (yes; a voice person stays canonical) or never link (no).
unfile_item(item_id): take the item out of its event (never put back there) and keep it in the
  Unfiled tray; the organizer does not re-file it on its own. move_item files it into an existing
  event; file_item_new_event(item_id[, new_event_id]) files it as a new event of its own.
Segments (item-split): remove_item, move_item, unfile_item and file_item_new_event take an optional
seg_id and then act on that segment only. Without seg_id, a decision on an item filed by segments acts on
all its active segments (remove_item: those in the named event; file_item_new_event: one new event for
all of them). same_event / same_person answers from questions carry internal ids and apply directly.
rename_event locks the title; the user's title is compared with new items next to the event's fixed
anchor (and becomes the anchor if the event had none).
"""

from __future__ import annotations

import hashlib
import json
from typing import Callable

from .organizer import Organizer

Handler = Callable[[Organizer, dict, int], tuple[bool, str]]


def apply_decision(org: Organizer, decision: dict, origin: str = "user") -> tuple[bool, str]:
    store = org.store
    handler = HANDLERS[decision["kind"]]
    external_id = decision.get("decision_id")
    # seg_id is newer than the receipts: leave an absent one out so a retry from before the upgrade
    # still matches its stored digest.
    digest_of = {k: v for k, v in decision.items() if not (k == "seg_id" and v is None)}
    digest = hashlib.sha256(json.dumps(digest_of, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    with store.tx():
        if external_id:
            receipt = store.one("SELECT * FROM decision_receipts WHERE external_id=?", (external_id,))
            if receipt:
                if receipt["payload_digest"] != digest:
                    return False, "decision_id reused with different content"
                return bool(receipt["applied"]), receipt["note"]
        decision_id = store.record_decision(decision["kind"], decision, origin, False)
        ok, note = handler(org, decision, decision_id)
        store.x("UPDATE decisions SET applied=?, note=? WHERE decision_id=?", (int(ok), note, decision_id))
        if external_id:
            store.x("INSERT INTO decision_receipts(external_id, payload_digest, applied, note)"
                    " VALUES (?,?,?,?)", (external_id, digest, int(ok), note))
        if not ok:
            # Keep the audit row but make the rejection visible; nothing else changed.
            pass
    if ok and decision.get("item_id") and decision["kind"] in ("move_item", "remove_item", "unfile_item",
                                                               "file_item_new_event"):
        org.requeue_frames(decision["item_id"])  # a video's keyframes follow the video
    org.wake()
    return ok, note


def _event(org: Organizer, event_id: str):
    ev = org.store.get_event(event_id)
    return ev if ev and not ev["deleted"] else None


def _item_exists(org: Organizer, item_id: str) -> bool:
    return org.store.latest_revision(item_id) is not None


def _move_item(org: Organizer, item_id: str, to_event: str, decision_id: int, how: str) -> None:
    store = org.store
    link = store.current_event_link(item_id)
    if link and link["event_id"] != to_event:
        store.detach(link["event_id"], item_id, how)
    store.x("DELETE FROM constraints WHERE kind='forbid_item_event' AND a=? AND b=?", (item_id, to_event))
    store.attach(to_event, item_id, "user", None)
    store.add_constraint("lock_item", item_id, to_event, decision_id)
    store.expire_questions_touching([item_id])


def _forbid(org: Organizer, item_id: str, event_id: str, decision_id: int) -> str:
    store = org.store
    store.add_constraint("forbid_item_event", item_id, event_id, decision_id)
    link = store.current_event_link(item_id)
    store.expire_questions_touching([item_id])
    if link and link["event_id"] == event_id:
        store.detach(event_id, item_id, "user")
        store.requeue_latest(item_id, "removed_by_user")
        return "removed; item re-queued for assignment elsewhere"
    return "constraint recorded"


def rename_event(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    ev = _event(org, d["event_id"])
    if not ev:
        return False, "unknown or deleted event"
    prov = dict(ev["provenance"])
    prov["title"] = {"source": "user", "decision_id": did}
    title = d["title"].strip()
    fields = {"title": title, "title_user_edited": 1, "provenance": prov}
    if not ev.get("anchor"):
        fields.update(anchor=title, anchor_source="user")
    org.store.update_event(d["event_id"], **fields)
    return True, ""


def _targets(org: Organizer, item_id: str, seg_id=None, event_id=None) -> tuple[list[str], str]:
    """Internal item ids a decision about (item_id[, seg_id]) acts on, or ([], reason)."""
    store = org.store
    if seg_id:
        child = store.child_for(item_id, seg_id)
        if child is None:
            # The Mac may spell the id in another case than it was stored.
            row = store.one("SELECT child_id FROM item_segments WHERE lower(parent_id)=lower(?) AND seg_id=?"
                            " AND active=1", (item_id, seg_id))
            child = row["child_id"] if row else None
        return ([child], "") if child else ([], "unknown segment")
    if not _item_exists(org, item_id):
        return [], "unknown item"
    children = [s["child_id"] for s in store.segments_of(item_id)]
    if not children:
        return [item_id], ""
    if event_id is not None:
        children = [c for c in children if (store.current_event_link(c) or {}).get("event_id") == event_id]
        if not children:
            return [], "no segment of this item is in that event"
    return children, ""


def remove_item(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    if not org.store.get_event(d["event_id"]):
        return False, "unknown event"
    ids, why = _targets(org, d["item_id"], d.get("seg_id"), d["event_id"])
    if not ids:
        return False, why
    notes = [_forbid(org, i, d["event_id"], did) for i in ids]
    return True, notes[0] if len(notes) == 1 else f"{len(notes)} segments: {notes[0]}"


def move_item(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    if not _event(org, d["to_event_id"]):
        return False, "unknown or deleted target event"
    ids, why = _targets(org, d["item_id"], d.get("seg_id"))
    if not ids:
        return False, why
    for i in ids:
        _move_item(org, i, d["to_event_id"], did, "user_move")
    return True, "" if len(ids) == 1 else f"moved {len(ids)} segments"


def same_event(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    store = org.store
    a, b, yes = d["a"], d["b"], d["answer"]
    ea, eb = store.get_event(a), store.get_event(b)
    ia, ib = _item_exists(org, a), _item_exists(org, b)
    store.expire_questions_touching([a, b])
    if ea and eb:
        if not yes:
            store.add_constraint("apart_events", a, b, did)
            return True, "events kept apart"
        if ea["deleted"] or eb["deleted"]:
            return False, "cannot merge a deleted event"
        for item_id in store.event_item_ids(b):
            store.detach(b, item_id, "user_merge")
            store.attach(a, item_id, "user_merge", None)
        store.update_event(b, deleted=1, merged_into=a, needs_brief=0)
        return True, f"merged {b} into {a}"
    if (ia and eb) or (ib and ea):
        item_id, event_id = (a, b) if ia and eb else (b, a)
        ids = _targets(org, item_id)[0]  # an item filed by segments: all its segments
        if yes:
            if not _event(org, event_id):
                return False, "event deleted"
            for i in ids:
                _move_item(org, i, event_id, did, "user_same_event")
            return True, "item moved"
        notes = [_forbid(org, i, event_id, did) for i in ids]
        return True, notes[0]
    if ia and ib:
        la = next((link for i in _targets(org, a)[0] if (link := store.current_event_link(i))), None)
        if not la:
            return False, "first item has no event"
        ids = _targets(org, b)[0]
        if yes:
            for i in ids:
                _move_item(org, i, la["event_id"], did, "user_same_event")
            return True, "item moved"
        notes = [_forbid(org, i, la["event_id"], did) for i in ids]
        return True, notes[0]
    return False, "unknown ids"


def same_person(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    people = org.people
    if not people.get(d["a"]) or not people.get(d["b"]):
        return False, "unknown person"
    org.store.expire_questions_touching([d["a"], d["b"]])
    if d["answer"]:
        keep = people.merge(d["a"], d["b"], "user")
        return True, f"merged into {keep}"
    people.mark_different(d["a"], d["b"], "user")
    return True, "kept apart"


def name_person(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    org.people.set_name(d["person_id"], d["display_name"].strip())
    org.people.link_all_chat_persons()
    return True, ""


def pin_event(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    if not _event(org, d["event_id"]):
        return False, "unknown or deleted event"
    org.store.update_event(d["event_id"], pinned=int(d["pinned"]))
    return True, ""


def feature_less(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    ev = _event(org, d["event_id"])
    if not ev:
        return False, "unknown or deleted event"
    org.store.update_event(d["event_id"], feature_less=1, importance=min(ev["importance"], 0.2))
    return True, ""


def unfile_item(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    store = org.store
    ids, why = _targets(org, d["item_id"], d.get("seg_id"))
    if not ids:
        return False, why
    for item_id in ids:
        link = store.current_event_link(item_id)
        if link:
            store.add_constraint("forbid_item_event", item_id, link["event_id"], did)
            store.detach(link["event_id"], item_id, "user")
        store.set_unfiled(item_id, "user", None)
        store.expire_questions_touching([item_id])
    return True, "unfiled"


def file_item_new_event(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    store = org.store
    ids, why = _targets(org, d["item_id"], d.get("seg_id"))
    if not ids:
        return False, why
    item = store.get_item(ids[0])
    if not item:
        return False, "unknown item"
    new_id = (d.get("new_event_id") or "").lower() or None
    if new_id and store.get_event(new_id):
        if all((store.current_event_link(i) or {}).get("event_id") == new_id for i in ids):
            return True, f"already filed as {new_id}"
        return False, "new_event_id already exists"
    event_id = store.create_event(item, "", new_id)
    for item_id in ids:
        link = store.current_event_link(item_id)
        if link:
            store.detach(link["event_id"], item_id, "user_move")
        store.attach(event_id, item_id, "user", None)
        store.add_constraint("lock_item", item_id, event_id, did)
        store.expire_questions_touching([item_id])
    return True, f"filed as new event {event_id}"


def delete_event(org: Organizer, d: dict, did: int) -> tuple[bool, str]:
    if not org.store.get_event(d["event_id"]):
        return False, "unknown event"
    org.store.update_event(d["event_id"], deleted=1, needs_brief=0)
    org.store.expire_questions_touching([d["event_id"]])
    return True, ""


HANDLERS: dict[str, Handler] = {
    "rename_event": rename_event,
    "remove_item": remove_item,
    "move_item": move_item,
    "same_event": same_event,
    "same_person": same_person,
    "name_person": name_person,
    "pin_event": pin_event,
    "feature_less": feature_less,
    "delete_event": delete_event,
    "unfile_item": unfile_item,
    "file_item_new_event": file_item_new_event,
}


def answer_question(org: Organizer, question_id: str, answer: bool) -> tuple[int, str]:
    """Returns (http_status, note).

    The answer is applied as the equivalent decision in the same transaction. When that decision
    cannot be applied (for example the event was deleted meanwhile), the question is marked
    'failed' with the reason instead of 'answered', so it is never reported as done. A replay with
    the same answer returns the stored outcome: 200 only if it was applied, else 409 with the reason.
    """
    store = org.store
    with store.tx():
        q = store.one("SELECT * FROM questions WHERE question_id=?", (question_id,))
        if not q:
            return 404, "unknown question"
        if q["status"] in ("answered", "failed"):
            if bool(q["answer"]) != answer:
                return 409, "answered differently"
            if q["status"] == "answered":
                return 200, "already answered"
            return 409, q.get("apply_note") or "not applied"
        if q["status"] != "open":
            return 409, f"question is {q['status']}"
        ok, note = apply_decision(org, {"kind": q["kind"], "a": q["a"], "b": q["b"], "answer": answer},
                                  origin=f"question:{question_id}")
        store.x("UPDATE questions SET status=?, answer=?, answered_at=datetime('now'), apply_note=?"
                " WHERE question_id=?", ("answered" if ok else "failed", int(answer), note, question_id))
        store.bump()
    return (200 if ok else 409), note
