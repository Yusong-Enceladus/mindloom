"""Brief evidence and date errors are repaired, not retried (from claude/scale-quality). Fake model,
invented data."""

from __future__ import annotations

from conftest import event_of, ingest, make_item


def _brief_with_unquoted_done(data: dict, schema: dict) -> dict:
    last = data["items"][-1]
    return {"title": "咖啡馆菜单", "status_line": "菜单待定",
            "status_facts": [{"text": "菜单试吃反馈不错", "state": "done", "date": "", "quote": "菜单周五前定",
                              "item_ids": [last["item_id"]]},
                             {"text": "菜单已印好", "state": "done", "date": "", "quote": "菜单周五前定",
                              "item_ids": [last["item_id"]]}],
            "off_anchor_item_ids": []}


def test_brief_with_only_evidence_errors_makes_one_call_and_repairs(org, chat):
    chat.handlers["event-brief"] = _brief_with_unquoted_done
    ingest(org, make_item("咖啡馆菜单周五前定"))
    org.drain()
    assert chat.count("event-brief") == 1
    ev = org.store.get_event(event_of(org, org.store.x("SELECT item_id FROM items").fetchone()[0]))
    # the unsupported done fact without a completion claim is kept as info; "已印好" is dropped
    assert [(f["text"], f["state"]) for f in ev["status_facts"]] == [("菜单试吃反馈不错", "info")]
    assert ev["status_line"] == "菜单待定"
    row = org.store.x("SELECT status, reason FROM proposals WHERE kind='brief' ORDER BY rowid DESC").fetchone()
    assert row[0] == "partial" and "repaired without retry" in row[1]


def test_brief_format_error_is_still_retried(org, chat):
    bad = {"title": "咖啡馆菜单", "status_line": "菜单待定", "status_facts": [], "off_anchor_item_ids": []}
    chat.push("event-brief", bad)
    ingest(org, make_item("咖啡馆菜单周五前定"))
    org.drain()
    assert chat.count("event-brief") == 2


def test_brief_is_retried_when_the_repair_would_leave_the_card_empty(org, chat):
    # every fact claims an unsupported completion and the line too: the repair keeps nothing, so ask again
    bad = {"title": "咖啡馆菜单", "status_line": "菜单已印好", "off_anchor_item_ids": [],
           "status_facts": [{"text": "菜单已印好", "state": "done", "date": "", "quote": "菜单周五前定",
                             "item_ids": ["I1"]}]}
    chat.push("event-brief", bad)
    it = make_item("咖啡馆菜单周五前定")
    ingest(org, it)
    org.drain()
    assert chat.count("event-brief") == 2
    ev = org.store.get_event(event_of(org, it["item_id"]))
    assert ev["status_facts"] and ev["status_line"]
