"""Regression tests for the v7 review of the matter map (findings V7-M1-M3): deleting an item leaves nothing the map
wrote from it, a matter that is gone keeps no map, and a quote must be long enough to be evidence. Invented data.
"""

from __future__ import annotations

import importlib.util

from conftest import REPO, event_of, ingest, make_item
from test_matter_group import four_matters, life_and_cafe, ropes

from organizer.decisions import apply_decision

spec = importlib.util.spec_from_file_location("review_fix_map_validate",
                                              REPO / "skills" / "matter-map" / "scripts" / "validate.py")
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

SECRET = "哨兵VX诊断"


def _items():
    items = [make_item(f"咖啡馆第{i}步：把第{i}件准备做完", minutes=10 * i) for i in range(8)]
    items.append(make_item(f"咖啡馆第8步：{SECRET}，周五前别告诉别人", minutes=80))
    return items


def _paraphrasing_map(data, schema):
    """A valid map whose knot cites two items (the quote from the kept one, the text paraphrasing the other) and a
    strand named after the other."""
    items = data["items"]
    keep, gone = items[-2], items[-1]
    return {"strands": [{"id": "s1", "name": "前七步", "summary": "测试", "item_ids": [i["id"] for i in items[:-1]],
                         "fact_ids": [], "state": "open"},
                        {"id": "s2", "name": SECRET, "summary": "测试", "item_ids": [gone["id"]],
                         "fact_ids": [], "state": "open"}],
            "knots": [{"id": "k1", "strand": "s1", "kind": "progress", "text": f"{SECRET}已经定了",
                       "date": keep["t"][:10], "state": "done", "who": [], "evidence": [keep["id"], gone["id"]],
                       "quote": keep["text"].replace("…", "")[:8]},
                      {"id": "k2", "strand": "s2", "kind": "progress", "text": "第七步做完", "date": keep["t"][:10],
                       "state": "done", "who": [], "evidence": [keep["id"]],
                       "quote": keep["text"].replace("…", "")[:8]}],
            "health": {"level": "ok", "reason": "正常", "evidence": []}, "blocks": []}


def _mapped(org, chat):
    chat.handlers["matter-map"] = _paraphrasing_map
    items = _items()
    ingest(org, *items)
    org.drain()
    eid = event_of(org, items[0]["item_id"])
    assert SECRET in org.store.one("SELECT map FROM event_maps WHERE event_id=?", (eid,))["map"]
    return items, eid


def test_m1_deleting_an_item_leaves_nothing_the_map_wrote_from_it(org, chat):
    items, eid = _mapped(org, chat)
    org.delete_item(items[-1]["item_id"])
    row = org.store.one("SELECT map, outcome FROM event_maps WHERE event_id=?", (eid,))
    assert SECRET not in (row["map"] or "")
    assert row["outcome"] == "purged"
    m = next(e for e in org.state(0)["events"] if e["event_id"] == eid)["map"]
    # the knot that cited it (with other evidence) went, the strand named from it went, the other knot stays on
    # the main thread
    assert [k["id"] for k in m["knots"]] == ["k2"] and m["knots"][0]["strand"] is None
    assert [s["id"] for s in m["strands"]] == ["s1"]


def test_m1_a_failed_redraw_after_a_purge_drops_the_map(org, chat):
    items, eid = _mapped(org, chat)
    org.delete_item(items[-1]["item_id"])
    chat.handlers["matter-map"] = lambda data, schema: {"strands": "not a list"}  # invalid twice
    org.drain()
    row = org.store.one("SELECT map, outcome FROM event_maps WHERE event_id=?", (eid,))
    assert row["map"] is None and row["outcome"] == "dropped"


def test_m1_a_proposed_rope_written_from_a_deleted_item_goes(org, chat):
    chat.handlers["matter-group"] = life_and_cafe
    first = four_matters(org)
    org.drain()
    rs = ropes(org)
    assert rs["生活"]["evidence"] == [first["搬家"]] and rs["周末小店"]["evidence"] == [first["咖啡馆"]]
    # the user confirms one of the two; the other stays a proposal
    assert apply_decision(org, {"kind": "confirm_rope", "rope_id": rs["周末小店"]["id"]})[0]
    chat.handlers["matter-group"] = lambda data, schema: {"new_ropes": [], "nest": [], "placements": []}
    org.delete_item(first["搬家"])
    org.delete_item(first["咖啡馆"])
    titles = [r["title"] for r in org.store.all("SELECT title FROM ropes")]
    assert "生活" not in titles  # proposed from the item: gone, title and all
    kept = org.store.one("SELECT * FROM ropes WHERE title='周末小店'")
    assert kept is not None and kept["evidence"] == "[]" and kept["reason"] == ""  # the user's decision stays
    assert org.store.one("SELECT 1 FROM rope_members WHERE event_id=?", (event_of(org, first["体检"]),)) is None


def test_m2_a_matter_that_is_gone_keeps_no_map_and_no_queue_row(org, chat):
    items, eid = _mapped(org, chat)
    org.store.queue_map(eid, 2, "demand")
    for it in items:
        org.delete_item(it["item_id"])
    assert org.store.one("SELECT 1 FROM event_maps WHERE event_id=?", (eid,)) is None
    assert org.store.one("SELECT 1 FROM map_queue WHERE event_id=?", (eid,)) is None


def test_m2_a_matter_the_user_deletes_keeps_no_map(org, chat):
    items, eid = _mapped(org, chat)
    ok, _ = apply_decision(org, {"kind": "delete_event", "event_id": eid})
    assert ok
    assert org.store.one("SELECT 1 FROM event_maps WHERE event_id=?", (eid,)) is None
    assert org.store.one("SELECT 1 FROM map_queue WHERE event_id=?", (eid,)) is None


def test_m3_a_quote_too_short_to_show_anything_is_not_evidence():
    text = "我们下周把咖啡馆的招牌装好，供应商周五送豆子"
    assert not V.verbatim("我们", text)
    assert not V.verbatim("咖啡馆", text)
    assert V.verbatim("咖啡馆的招牌", text)
    assert V.MIN_QUOTE_CHARS == 4
