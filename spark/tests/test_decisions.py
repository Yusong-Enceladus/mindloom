from organizer.decisions import apply_decision

from conftest import event_of, ingest, make_item


def _two_cafe_items(org):
    a = make_item("咖啡馆菜单周五前定", minutes=0)
    b = make_item("咖啡馆招牌下周二装", minutes=5)
    ingest(org, a, b)
    org.drain()
    return a, b


def test_rename_wins_over_later_briefs(org, chat):
    a, b = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    ok, _ = apply_decision(org, {"kind": "rename_event", "event_id": ev, "title": "开店"})
    assert ok
    ingest(org, make_item("咖啡馆灯具验收", minutes=10))
    org.drain()
    e = org.store.get_event(ev)
    assert e["title"] == "开店" and e["title_user_edited"]
    assert e["provenance"]["title"]["source"] == "user"
    assert "灯具" in e["status_line"]  # status line still refreshed
    brief_data = [c[1] for c in chat.calls if c[0] == "event-brief"][-1]
    assert brief_data["event"]["title_locked"] is True


def test_rename_during_model_call_still_wins(org, chat):
    a, b = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    chat.before["event-brief"] = lambda data: apply_decision(
        org, {"kind": "rename_event", "event_id": ev, "title": "我的标题"})
    ingest(org, make_item("咖啡馆灯具验收", minutes=10))
    org.drain()
    assert org.store.get_event(ev)["title"] == "我的标题"


def test_removed_item_is_never_reattached_to_that_event(org, chat):
    a, b = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    ok, note = apply_decision(org, {"kind": "remove_item", "event_id": ev, "item_id": b["item_id"]})
    assert ok and "re-queued" in note
    n_calls = len(chat.calls)
    org.drain()
    # "doesn't belong here" never turns into a one-item event: with no other matching event the item
    # waits in the Unfiled tray
    assert event_of(org, b["item_id"]) is None
    assert [u["item_id"] for u in org.state(0)["unfiled"]] == [b["item_id"]]
    assert org.state(0)["unfiled"][0]["reason"] == "removed_by_user"
    # the model never even sees the forbidden event as a candidate
    ev_handle = org.store.event_handle(ev)
    for skill, data, _, _ in chat.calls[n_calls:]:
        if skill == "event-assign":
            assert ev_handle not in [c["event_id"] for c in data["candidates"]]
    # a later revision of the item does not bring it back either
    ingest(org, dict(b, revision=2, text="咖啡馆招牌下周二装，师傅确认了"))
    org.drain()
    assert event_of(org, b["item_id"]) != ev
    ev_state = next(e for e in org.state(0)["events"] if e["event_id"] == ev)
    assert b["item_id"] not in ev_state["item_ids"]


def test_model_proposal_to_forbidden_event_is_rejected(org, chat):
    a, b = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    c = make_item("咖啡馆吧台验收", minutes=20)
    ingest(org, c)
    # the user forbids the pair while the model is deciding; the model still proposes attach
    chat.before["event-assign"] = lambda data: apply_decision(
        org, {"kind": "remove_item", "event_id": ev, "item_id": c["item_id"]})
    org.drain()
    assert event_of(org, c["item_id"]) != ev
    prop = org.store.one("SELECT * FROM proposals WHERE kind='assign' AND target_id=? ORDER BY proposal_id DESC",
                         (c["item_id"],))
    assert prop["status"] == "rejected" and '"attach"' in prop["payload"]


def test_move_item_is_final(org, chat):
    a = make_item("咖啡馆菜单", minutes=0)
    r = make_item("读书会书目", minutes=5)
    ingest(org, a, r)
    org.drain()
    cafe, club = event_of(org, a["item_id"]), event_of(org, r["item_id"])
    ok, _ = apply_decision(org, {"kind": "move_item", "item_id": r["item_id"], "to_event_id": cafe})
    assert ok
    org.drain()
    assert event_of(org, r["item_id"]) == cafe
    assert org.store.get_event(club)["deleted"]  # emptied event disappears
    ingest(org, dict(r, revision=2, text="读书会书目改了"))
    org.drain()
    assert event_of(org, r["item_id"]) == cafe


def test_same_event_merges_two_events(org):
    a = make_item("咖啡馆菜单", minutes=0)
    r = make_item("读书会书目", minutes=5)
    ingest(org, a, r)
    org.drain()
    cafe, club = event_of(org, a["item_id"]), event_of(org, r["item_id"])
    ok, note = apply_decision(org, {"kind": "same_event", "a": cafe, "b": club, "answer": True})
    assert ok and "merged" in note
    org.drain()
    assert event_of(org, r["item_id"]) == cafe
    merged = org.store.get_event(club)
    assert merged["deleted"] and merged["merged_into"] == cafe


def test_delete_event_removes_it_from_candidates(org, chat):
    a, b = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    apply_decision(org, {"kind": "delete_event", "event_id": ev})
    c = make_item("咖啡馆灯具", minutes=20)
    ingest(org, c)
    org.drain()
    assert event_of(org, c["item_id"]) != ev
    state = org.state(0)
    assert next(e for e in state["events"] if e["event_id"] == ev)["deleted"] is True


def test_pin_and_feature_less(org, chat):
    a, _ = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    apply_decision(org, {"kind": "pin_event", "event_id": ev, "pinned": True})
    apply_decision(org, {"kind": "feature_less", "event_id": ev})
    org._rank_dirty = True
    org.drain()
    e = org.store.get_event(ev)
    assert e["pinned"] and e["feature_less"] and e["importance"] <= 0.2
    rank_ctx = [c for c in chat.calls if c[0] == "home-rank"][-1][1]
    assert rank_ctx["events"][0]["feature_less"] is True


def test_name_person_links_earlier_chat_sender(org, chat):
    meeting = make_item("咖啡馆例会", kind="meeting_offline", persons=[{"person_id": "voice-9"}])
    ingest(org, meeting)
    org.drain()
    chat_pid = org.people.upsert_chat("王五")
    assert org.people.canonical(chat_pid) == chat_pid
    ok, _ = apply_decision(org, {"kind": "name_person", "person_id": "voice-9", "display_name": "王五"})
    assert ok and org.people.canonical(chat_pid) == "voice-9"
    persons = {p["person_id"]: p for p in org.state(0)["persons"]}
    assert persons["voice-9"]["display_name"] == "王五"
    assert persons[chat_pid]["merged_into"] == "voice-9"


def test_same_person_no_prevents_auto_link(org):
    ingest(org, make_item("咖啡馆", kind="meeting_offline", persons=[{"person_id": "voice-1", "display_name": "李四"}]))
    org.drain()
    chat_pid = org.people.upsert_chat("李四")
    apply_decision(org, {"kind": "same_person", "a": chat_pid, "b": "voice-1", "answer": False})
    assert org.people.link_chat_person(chat_pid) == "none"
    assert org.people.canonical(chat_pid) == chat_pid


def test_unknown_ids_are_rejected_and_audited(org):
    ok, note = apply_decision(org, {"kind": "rename_event", "event_id": "nope", "title": "x"})
    assert not ok and "unknown" in note
    row = org.store.one("SELECT * FROM decisions ORDER BY decision_id DESC LIMIT 1")
    assert row["applied"] == 0 and row["kind"] == "rename_event"


def test_retry_of_same_decision_is_idempotent_and_conflict_is_rejected(org):
    a, _ = _two_cafe_items(org)
    ev = event_of(org, a["item_id"])
    decision = {"decision_id": "00000000-0000-4000-8000-000000000001",
                "kind": "rename_event", "event_id": ev, "title": "我的咖啡馆"}
    assert apply_decision(org, decision)[0]
    first_cursor = org.store.cursor()
    first_count = org.store.scalar("SELECT COUNT(*) FROM decisions")
    assert apply_decision(org, decision)[0]
    assert org.store.cursor() == first_cursor
    assert org.store.scalar("SELECT COUNT(*) FROM decisions") == first_count
    changed = dict(decision, title="错误标题")
    ok, note = apply_decision(org, changed)
    assert not ok and "reused" in note
    assert org.store.get_event(ev)["title"] == "我的咖啡馆"
