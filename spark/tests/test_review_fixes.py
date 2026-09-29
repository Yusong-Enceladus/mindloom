"""Regressions for the quality-branch review findings. Fake model; all data invented.

  - UTC ("Z") capture times are read in the organizer's zone, not as UTC wall clock
  - a user's unfile made while the model is thinking wins over the model's placement
  - an item the user removed never becomes a one-item event, even after a recheck
  - file_item_new_event files an item as its own event (and over HTTP with unfile_item)
  - an assign output invalid twice is still derived (a non-matter stays unfiled)
  - the replay clock resumes after a restart
  - an idle organizer expires stale questions
  - a salvaged (invalid) brief sets no off-anchor flags; a later valid brief clears old ones
"""

import uuid
from datetime import datetime, timezone

from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.clock import FixedClock
from organizer.decisions import apply_decision

from conftest import assign_out, event_of, ingest, make_item


def _utc_item(text: str, local: str) -> dict:
    """An item as a Mac using ISO8601DateFormatter's default (UTC, 'Z') would send it."""
    it = make_item(text)
    it["started_at"] = datetime.fromisoformat(local).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    it["ended_at"] = None
    return it


# ---- time zone -------------------------------------------------------------------------------------

def test_utc_stamp_is_read_in_organizer_tz(org, monkeypatch):
    monkeypatch.setenv("ORGANIZER_TZ", "Asia/Shanghai")
    dates = org.registry.script("event-brief", "dates")
    # Tue 22 Sep 07:30 at UTC+8 is Mon 21 Sep 23:30Z
    assert dates.format_captured("2026-09-21T23:30:00Z") == "2026-09-22 周二 07:30"
    assert dates.resolve("明天上午来量尺寸", "2026-09-21T23:30:00Z") == [{"said": "明天", "date": "2026-09-23"}]
    # an explicit non-UTC offset is the device's wall clock and is kept
    assert dates.local_iso("2026-09-22T07:30:00+09:00") == "2026-09-22T07:30:00+09:00"


def test_utc_items_get_local_day_and_captured_at(org, chat, monkeypatch):
    monkeypatch.setenv("ORGANIZER_TZ", "Asia/Shanghai")
    it = _utc_item("明天上午十点师傅来量阳台尺寸", "2026-09-22T07:30:00+08:00")
    assert it["started_at"] == "2026-09-21T23:30:00Z"
    ingest(org, it)
    org.drain()
    assign = [d for s, d, _, _ in chat.calls if s == "event-assign"][-1]
    assert assign["item"]["started_at"] == "2026-09-22T07:30:00+08:00"
    brief = [d for s, d, _, _ in chat.calls if s == "event-brief"][-1]
    view = brief["items"][0]
    assert view["captured_at"] == "2026-09-22 周二 07:30"
    assert view["dates"] == [{"said": "明天", "date": "2026-09-23"}]
    assert brief["as_of"].startswith("2026-09-22T07:30")
    assert org._day_key(org.store.get_item(it["item_id"])) == "2026-09-22"


def test_brief_validator_uses_local_capture_day(org, monkeypatch):
    monkeypatch.setenv("ORGANIZER_TZ", "Asia/Shanghai")
    rules = org.registry.script("event-brief", "validate")
    fact = {"text": "阳台门已修好", "state": "done", "date": "2026-09-22", "quote": "阳台门修好了", "item_ids": ["I1"]}
    items = {"I1": {"text": "阳台门修好了", "captured_at": "2026-09-21T23:30:00Z"}}
    assert not [e for e in rules.check_fact_evidence(fact, items) if "晚于" in e or "later" in e]


# ---- user decisions win over in-flight assignment -------------------------------------------------

def test_user_unfile_during_assignment_wins(org, chat):
    it = make_item("周末去看看新出的露营帐篷")

    def user_unfiles(data):
        ok, _ = apply_decision(org, {"kind": "unfile_item", "item_id": it["item_id"]})
        assert ok

    chat.before["event-assign"] = user_unfiles
    ingest(org, it)
    org.drain()
    assert event_of(org, it["item_id"]) is None
    row = org.store.one("SELECT reason FROM unfiled WHERE item_id=?", (it["item_id"],))
    assert row and row["reason"] == "user"
    prop = org.store.one("SELECT status FROM proposals WHERE kind='assign' AND target_id=? ORDER BY rowid DESC",
                         (it["item_id"],))
    assert prop["status"] == "superseded"


def test_removed_item_never_becomes_its_own_event_after_recheck(org, chat):
    a = make_item("咖啡馆菜单周五前定")
    b = make_item("咖啡馆吧台灯换暖光", minutes=5)
    ingest(org, a, b)
    org.drain()
    ev = event_of(org, a["item_id"])
    assert event_of(org, b["item_id"]) == ev
    ok, _ = apply_decision(org, {"kind": "remove_item", "event_id": ev, "item_id": b["item_id"]})
    assert ok
    org.drain()
    assert event_of(org, b["item_id"]) is None
    assert org.store.one("SELECT reason FROM unfiled WHERE item_id=?", (b["item_id"],))["reason"] == "removed_by_user"
    # a recheck (a matching event appeared) where the model now says "new"
    chat.push("event-assign", assign_out("new", obj="吧台灯"))
    org.store.requeue_latest(b["item_id"], "unfiled_recheck")
    org.drain()
    assert event_of(org, b["item_id"]) is None
    assert org.store.one("SELECT reason FROM unfiled WHERE item_id=?", (b["item_id"],))["reason"] == "removed_by_user"


def test_file_item_new_event_decision(org, chat):
    it = make_item("今天好热")
    chat.push("event-assign", assign_out("none", obj="天气", matter=False))
    ingest(org, it)
    org.drain()
    assert org.store.is_unfiled(it["item_id"])
    new_id = str(uuid.uuid4())
    ok, note = apply_decision(org, {"kind": "file_item_new_event", "item_id": it["item_id"], "new_event_id": new_id})
    assert ok, note
    assert event_of(org, it["item_id"]) == new_id
    assert not org.store.is_unfiled(it["item_id"])
    link = org.store.current_event_link(it["item_id"])
    assert link["attached_by"] == "user"
    # replay of the same decision is harmless; an id that belongs to another event is rejected
    ok, _ = apply_decision(org, {"kind": "file_item_new_event", "item_id": it["item_id"], "new_event_id": new_id})
    assert ok
    other = make_item("咖啡馆菜单周五前定", minutes=5)
    ingest(org, other)
    org.drain()
    ok, note = apply_decision(org, {"kind": "file_item_new_event", "item_id": other["item_id"], "new_event_id": new_id})
    assert not ok and "exists" in note
    # a new revision does not move a user placement
    rev = dict(it, revision=2, text="今天好热，想买个风扇", sha256="f" * 64)
    ingest(org, rev)
    org.drain()
    assert event_of(org, it["item_id"]) == new_id


def test_unfile_and_file_new_event_over_http(client, org, chat):
    it = make_item("咖啡馆菜单周五前定")
    assert client.post("/v1/items", json={"items": [it]}).status_code == 200
    org.drain()
    state = client.get("/v1/state").json()
    ev = next(e for e in state["events"] if it["item_id"] in e["item_ids"])
    assert ev["handle"].startswith("E") and "anchor" in ev
    assert state["unfiled"] == []
    r = client.post("/v1/decisions", json={"decisions": [
        {"kind": "unfile_item", "item_id": it["item_id"], "decision_id": "d-1"}]})
    assert r.json() == {"applied": 1, "rejected": []}
    r = client.post("/v1/decisions", json={"decisions": [
        {"kind": "unfile_item", "item_id": it["item_id"], "decision_id": "d-1"}]})
    assert r.json()["applied"] == 1  # idempotent replay
    state = client.get("/v1/state").json()
    assert [(u["item_id"], u["reason"]) for u in state["unfiled"]] == [(it["item_id"], "user")]
    new_id = str(uuid.uuid4())
    r = client.post("/v1/decisions", json={"decisions": [
        {"kind": "file_item_new_event", "item_id": it["item_id"], "new_event_id": new_id, "decision_id": "d-2"}]})
    assert r.json() == {"applied": 1, "rejected": []}
    org.drain()
    state = client.get("/v1/state").json()
    assert state["unfiled"] == []
    assert any(e["event_id"] == new_id and e["item_ids"] == [it["item_id"]] for e in state["events"])


# ---- assign fallback -------------------------------------------------------------------------------

def test_assign_invalid_twice_still_derives_none_for_a_non_matter(org, chat):
    bad = assign_out("new", obj="天气", matter=False)  # schema-valid, but contradicts item_is_matter
    chat.push("event-assign", bad, bad)
    it = make_item("今天好热想去游泳")
    ingest(org, it)
    org.drain()
    assert event_of(org, it["item_id"]) is None and org.store.is_unfiled(it["item_id"])
    prop = org.store.one("SELECT status, reason FROM proposals WHERE kind='assign' AND target_id=?", (it["item_id"],))
    assert prop["status"] == "fallback" and "derived" in prop["reason"]


# ---- clock and question expiry ---------------------------------------------------------------------

def test_replay_clock_resumes_after_restart(settings, chat):
    settings.clock = "replay"
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    it = make_item("咖啡馆菜单周五前定")
    ingest(org, it)
    org.drain()
    ev = event_of(org, it["item_id"])
    org2 = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    assert org2.clock.now_iso().startswith("2026-09-20T09:01")
    ok, _ = apply_decision(org2, {"kind": "pin_event", "event_id": ev, "pinned": True})
    assert ok


def test_decision_on_empty_replay_store_does_not_fail(settings, chat):
    settings.clock = "replay"
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ok, note = apply_decision(org, {"kind": "pin_event", "event_id": "nope", "pinned": True})
    assert not ok and "unknown" in note


def test_idle_organizer_expires_stale_questions(settings, chat):
    clock = FixedClock("2026-09-20T09:00:00+08:00")
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient(), clock=clock)
    qid = org.store.create_question("same_event", "a", "b", "是同一件事吗？", 2)
    assert qid
    clock.set("2026-09-23T09:30:00+08:00")  # 72.5 h later, no new item
    assert org.step() is False
    assert org.store.one("SELECT status FROM questions WHERE question_id=?", (qid,))["status"] == "expired"


# ---- off-anchor flags ------------------------------------------------------------------------------

def _brief(off, line="咖啡馆菜单在定。"):
    def handler(data, schema):
        last = data["items"][-1]["item_id"]
        return {"title": "咖啡馆菜单", "status_facts": [{"text": "菜单在定", "state": "info", "date": "", "quote": "",
                                                         "item_ids": [last]}],
                "status_line": line, "off_anchor_item_ids": off(data)}
    return handler


def test_salvaged_brief_sets_no_off_anchor_flags_and_valid_brief_clears(org, chat):
    a = make_item("咖啡馆菜单周五前定")
    b = make_item("咖啡馆隔壁花店在打折", minutes=5)
    second = lambda data: [data["items"][1]["item_id"]]  # noqa: E731
    # invalid twice (relative date in the status line) but salvageable, and it lists b as off-anchor
    chat.handlers["event-brief"] = _brief(second, line="咖啡馆菜单明天定。")
    ingest(org, a, b)
    org.drain()
    ev = event_of(org, a["item_id"])
    assert event_of(org, b["item_id"]) == ev
    flags = lambda: {r["item_id"] for r in org.store.all(  # noqa: E731
        "SELECT item_id FROM event_items WHERE event_id=? AND off_anchor=1 AND removed=0", (ev,))}
    assert flags() == set()
    # a valid brief flags b ...
    chat.handlers["event-brief"] = _brief(second)
    org.store.update_event(ev, needs_brief=1)
    org.drain()
    assert flags() == {b["item_id"]}
    # ... and a later valid brief that no longer lists it clears the flag
    chat.handlers["event-brief"] = _brief(lambda data: [])
    org.store.update_event(ev, needs_brief=1)
    org.drain()
    assert flags() == set()
