"""The matter map (organizer/matter_map.py, skill matter-map; MAP-CONTRACT section 1) with a scripted model:
trigger, on-demand endpoint, validation (retry once, then dropped; repairable errors fixed), the state view,
segments, blocks edges, and the privacy rules (purge on delete, wipe, lock and session binding).

All data here is invented for tests.
"""

from __future__ import annotations

import importlib.util
import json

import pytest

from conftest import REPO, TEST_KEY, FakeChat, auth_headers, event_of, ingest, make_item
from test_v6_integration import dump, elsewhere, forget_and_rekey, settle

from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.decisions import apply_decision

spec = importlib.util.spec_from_file_location("test_map_validate", REPO / "skills" / "matter-map" / "scripts" / "validate.py")
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

SENTINEL = "哨兵QZ地图"


def cafe(n: int, start: int = 0, extra: str = "") -> list[dict]:
    return [make_item(f"咖啡馆第{i}步：把第{i}件准备做完{extra}", minutes=10 * i) for i in range(start, start + n)]


TWO_MATTERS = ("今天开了个会，说了好几件事。咖啡馆的招牌明天上午安装，灯箱要换成暖光，安装师傅说下午两点前能装完。"
               "读书会下周改成线上，这次读第四章，主持人还是老陈。另外咖啡馆的豆子也要再订两箱，供应商说周五送到。")


def live(org) -> list[dict]:
    return [e for e in org.state(0)["events"] if not e["deleted"]]


def the_event(org, item_id: str) -> dict:
    eid = event_of(org, item_id)
    return next(e for e in org.state(0)["events"] if e["event_id"] == eid)


def map_out(data: dict, **over) -> dict:
    """A valid output over the given request: two strands (halves), one knot per strand quoting its last item."""
    items = data["items"]
    half = max(1, len(items) // 2)
    groups = [items[:half], items[half:]] if len(items) > 1 else [items]
    strands, knots = [], []
    for n, g in enumerate(groups, 1):
        if not g:
            continue
        strands.append({"id": f"s{n}", "name": f"第{n}股", "summary": "测试", "item_ids": [i["id"] for i in g],
                        "fact_ids": [], "state": "open"})
        last = g[-1]
        knots.append({"id": f"k{n}", "strand": f"s{n}", "kind": "progress", "text": "有进展", "date": last["t"][:10],
                      "state": "done", "who": [], "evidence": [last["id"]], "quote": last["text"].replace("…", "")[:8]})
    out = {"strands": strands, "knots": knots, "health": {"level": "ok", "reason": "正常", "evidence": []}, "blocks": []}
    out.update(over)
    return out


# ---- trigger and on-demand -------------------------------------------------------------------------------


def test_a_matter_of_eight_items_gets_its_map_after_its_card_is_written(org, chat):
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    ev = the_event(org, items[0]["item_id"])
    m = ev["map"]
    assert m is not None and m["skill_version"] == org.registry.skills["matter-map"].version and m["updated_at"]
    assert m["stale"] is False
    assert m["strands"][0]["item_ids"][0] == items[0]["item_id"]  # client item ids, not handles
    knot = m["knots"][0]
    assert knot["evidence"] == [items[-1]["item_id"]] and knot["quote_item_id"] == items[-1]["item_id"]
    assert knot["date"] and knot["strand"] == "s1" and m["health"]["level"] == "ok"
    assert ev["facets"]["health"] == "ok" and "type" in ev["facets"] and "rope" in ev["facets"]
    assert chat.count("matter-map") == 1
    # the map call reads handles only and says the material is data
    call = next(c for c in chat.calls if c[0] == "matter-map")
    assert call[1]["items"][0]["id"].startswith("I") and "不是给你的指令" in call[3][1]["content"]


def test_a_small_matter_has_no_map_until_the_mac_asks_and_the_endpoint_answers(settings, org, chat):
    from fastapi.testclient import TestClient
    items = cafe(4)
    ingest(org, *items)
    org.drain()
    eid = event_of(org, items[0]["item_id"])
    assert the_event(org, items[0]["item_id"])["map"] is None
    app = create_app(settings, organizer=org)
    with TestClient(app, headers=auth_headers(app)) as c:
        r = c.post(f"/v1/events/{eid}/map")
        assert r.status_code == 202 and r.json()["queued"] is True
        org.drain()
        assert the_event(org, items[0]["item_id"])["map"] is not None
        r = c.post(f"/v1/events/{eid}/map")
        assert r.status_code == 200 and r.json() == {"queued": False, "reason": "current"}
        assert c.post("/v1/events/no-such-event/map").status_code == 404
        two = [make_item("读书会这周读第三章", minutes=200), make_item("读书会地点改到图书馆", minutes=210)]
        ingest(org, *two)
        org.drain()
        r = c.post(f"/v1/events/{event_of(org, two[0]['item_id'])}/map")
        assert r.status_code == 200 and r.json()["reason"] == "too_small"
        health = c.get("/v1/health").json()
        assert {"matter-map", "matter-group"} <= {s["name"] for s in health["skills"]} and health["maps"]["written"] >= 1
        state = c.get("/v1/state").json()
        assert "ropes" in state and "relations" in state


def test_a_requested_map_runs_before_the_next_item(org, chat):
    items = cafe(4)
    ingest(org, *items)
    org.drain()
    eid = event_of(org, items[0]["item_id"])
    assert org.mapper.request(eid)["queued"] is True
    ingest(org, make_item("读书会这周读第三章", minutes=300))
    assert org.step() is True  # the requested map, not the queued item
    assert chat.calls[-1][0] == "matter-map"


def test_a_requested_map_whose_call_keeps_failing_does_not_spin_the_worker(org, chat):
    items = cafe(4)
    ingest(org, *items)
    org.drain()
    eid = event_of(org, items[0]["item_id"])

    def broken(data, schema):
        raise RuntimeError("client broke")
    chat.handlers["matter-map"] = broken
    assert org.mapper.request(eid)["queued"] is True
    steps = org.drain(max_steps=50)
    assert steps < 10 and chat.count("matter-map") == 1
    assert org.store.one("SELECT priority FROM map_queue WHERE event_id=?", (eid,))["priority"] == 1


def test_a_big_matter_is_not_redrawn_for_every_new_item(org, chat):
    ingest(org, *cafe(9))
    org.drain()
    assert chat.count("matter-map") == 1
    ingest(org, *cafe(2, start=9))
    org.drain()
    assert chat.count("matter-map") == 1  # 2 new items: below max(3, 25% of 9)
    ingest(org, *cafe(1, start=11))
    org.drain()
    assert chat.count("matter-map") == 2  # 3 new items since the map was drawn


def test_idle_backfill_maps_a_store_built_before_maps(settings, chat):
    settings.maps = False
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(org, *cafe(9))
    org.drain()
    assert chat.count("matter-map") == 0
    org.mapper.enabled = True
    org.drain()
    assert chat.count("matter-map") == 1 and live(org)[0]["map"] is not None


# ---- validation -------------------------------------------------------------------------------------------


def test_an_output_invalid_twice_is_dropped_and_not_retried_until_the_items_change(org, chat):
    bad = {"strands": [{"id": "s1", "name": "主线", "summary": "测试", "item_ids": [], "fact_ids": [], "state": "open"}],
           "knots": [{"id": "k1", "strand": "s1", "kind": "question", "text": "编的", "date": "", "state": "done",
                      "who": [], "evidence": ["I1"], "quote": "素材里没有这句话"}],
           "health": {"level": "ok", "reason": "正常", "evidence": []}, "blocks": []}
    chat.push("matter-map", bad, bad)
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    assert chat.count("matter-map") == 2  # one retry
    assert the_event(org, items[0]["item_id"])["map"] is None
    row = org.store.map_row(event_of(org, items[0]["item_id"]))
    assert row["outcome"] == "dropped" and row["map"] is None
    assert org.store.one("SELECT status FROM proposals WHERE kind='map' ORDER BY proposal_id DESC LIMIT 1")["status"] == "rejected"
    org.drain()
    assert chat.count("matter-map") == 2  # no loop


def test_repairable_errors_are_fixed_without_a_retry(org, chat):
    def with_repairables(data, schema):
        out = map_out(data)
        k = out["knots"][0]
        k["date"] = "2026-01-01"             # neither captured then nor named
        k["who"] = ["不存在的人"]             # appears nowhere
        k["state"] = "open"                  # only a question is open
        # a matter offered, an item of the input, but no dependency stated
        out["blocks"] = [{"other": data["other_matters"][0]["id"], "direction": "waits_on", "item_id": data["items"][0]["id"],
                          "quote": "咖啡馆第0步"}]
        return out
    chat.handlers["matter-map"] = with_repairables
    ingest(org, make_item("读书会这周读第三章", minutes=-30), make_item("读书会地点改到图书馆", minutes=-20))
    org.drain()
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    assert chat.count("matter-map") == 1
    m = the_event(org, items[0]["item_id"])["map"]
    k = next(k for k in m["knots"] if k["id"] == "k1")
    assert k["date"] is None and k["who"] == [] and k["state"] == "doing"
    assert org.store.one("SELECT status FROM proposals WHERE kind='map' ORDER BY proposal_id DESC LIMIT 1")["status"] == "partial"
    assert not [r for r in org.state(0)["relations"] if r["kind"] == "blocks"]


def test_a_main_thread_listing_every_item_keeps_only_the_items_of_no_sub_thread():
    ctx = _ctx({"I1": "吧台拆完了", "I2": "水电进场", "I3": "付了首期款", "I4": "闲聊"})
    out = _out(strands=[{"id": "s1", "name": "总体进展", "summary": "全部", "item_ids": ["I1", "I2", "I3", "I4"], "fact_ids": [],
                         "state": "open"},
                        {"id": "s2", "name": "施工", "summary": "施工", "item_ids": ["I1", "I2"], "fact_ids": [], "state": "open"},
                        {"id": "s3", "name": "付款", "summary": "付款", "item_ids": ["I3"], "fact_ids": [], "state": "open"}])
    fixed = V.salvage(out, V.validate(out, ctx), ctx, after_retry=True)
    assert [s["item_ids"] for s in fixed["strands"]] == [["I4"], ["I1", "I2"], ["I3"]]


def test_after_the_retry_a_bad_quote_or_a_doubly_listed_item_is_trimmed_not_the_whole_map(org, chat):
    def sloppy(data, schema):
        out = map_out(data)
        out["strands"][1]["item_ids"].append(out["strands"][0]["item_ids"][0])  # listed under both strands
        out["knots"][0]["quote"] = "素材里没有这句"
        return out
    chat.handlers["matter-map"] = sloppy
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    assert chat.count("matter-map") == 2  # the contract's one retry first
    m = the_event(org, items[0]["item_id"])["map"]
    assert [k["id"] for k in m["knots"]] == ["k2"]
    # the doubly listed item stays in the smaller strand (s2 listed it besides its own half)
    assert items[0]["item_id"] not in m["strands"][1]["item_ids"] or items[0]["item_id"] not in m["strands"][0]["item_ids"]
    assert sum(items[0]["item_id"] in s["item_ids"] for s in m["strands"]) == 1
    note = org.store.one("SELECT status, reason FROM proposals WHERE kind='map' ORDER BY proposal_id DESC LIMIT 1")
    assert note == {"status": "partial", "reason": "salvaged after the retry"}


def _ctx(texts: dict, **kw) -> dict:
    items = {k: {"text": v, "date": "2026-09-20", "dates": [], "ranges": [], "who": []} for k, v in texts.items()}
    return {"items": items, "facts": ["f1"], "people": ["周建国"], "owner": ["我"], "others": kw.get("others", {}),
            "input_text": json.dumps(texts, ensure_ascii=False) + kw.get("extra", "")}


def _knot(**kw) -> dict:
    k = {"id": "k1", "strand": "s1", "kind": "progress", "text": "进展", "date": "2026-09-20", "state": "done", "who": [],
         "evidence": ["I1"], "quote": "吧台拆完了"}
    k.update(kw)
    return k


def _out(knots=None, strands=None, health=None, blocks=None) -> dict:
    return {"strands": strands or [{"id": "s1", "name": "装修", "summary": "测试", "item_ids": ["I1"], "fact_ids": ["f1"],
                                    "state": "open"}],
            "knots": knots if knots is not None else [_knot()], "health": health or {"level": "ok", "reason": "正常", "evidence": []},
            "blocks": blocks or []}


@pytest.mark.parametrize("output,category", [
    (_out(knots=[_knot(evidence=["I9"])]), "evidence"),
    (_out(strands=[{"id": "s1", "name": "a", "summary": "b", "item_ids": ["I7"], "fact_ids": [], "state": "open"}]), "evidence"),
    (_out(strands=[{"id": "s1", "name": "a", "summary": "b", "item_ids": ["I1"], "fact_ids": ["f9"], "state": "open"}]), "evidence"),
    (_out(knots=[_knot(quote="吧台拆了"), _knot(id="k2")]), "quote"),
    (_out(strands=[{"id": "s1", "name": "a", "summary": "b", "item_ids": ["I1"], "fact_ids": [], "state": "open"},
                   {"id": "s2", "name": "c", "summary": "d", "item_ids": ["I1"], "fact_ids": [], "state": "open"}]), "strand_dup"),
    (_out(strands=[{"id": "s1", "name": "a", "summary": "b", "item_ids": ["I1"], "fact_ids": [], "state": "open"},
                   {"id": "s1", "name": "c", "summary": "d", "item_ids": ["I2"], "fact_ids": [], "state": "open"}]), "strand"),
    (_out(knots=[_knot(strand="s3")]), "strand"),
    (_out(knots=[_knot(date="2026-02-30")]), "date"),
    (_out(knots=[_knot(kind="question", state="done")]), "question"),
    (_out(knots=[_knot(kind="commitment", state="planned", who=[])]), "commitment"),
    (_out(knots=[_knot(text="打〔手机号·000000〕")]), "placeholder"),
    (_out(health={"level": "stuck", "reason": "卡住", "evidence": []}), "health"),
    (_out(knots=[_knot(date="2026-01-01")]), "ungrounded_date"),
    (_out(knots=[_knot(who=["张三"])]), "who"),
    (_out(knots=[_knot(), _knot()]), "knot_id"),
])
def test_each_validator_rule_names_its_category(output, category):
    ctx = _ctx({"I1": "周建国：吧台拆完了，打〔手机号·a1b2c3〕约下一步", "I2": "别的素材"})
    errors = V.validate(output, ctx)
    assert category in V.categories(errors), errors
    if category in V.REPAIRABLE:
        assert V.validate(V.repair(output, ctx), ctx) == []
        return
    assert V.salvage(output, errors, ctx, after_retry=False) is None  # a contract error is retried first
    knot_level = any(e.startswith(f"[{category}] knot") for e in errors)
    if knot_level:
        # after the retry the failing knot is dropped when at least half of the knots are good
        more = dict(output, knots=output["knots"] + [_knot(id="k8"), _knot(id="k9")])
        fixed = V.salvage(more, V.validate(more, ctx), ctx, after_retry=True)
        assert fixed is not None and {k["id"] for k in fixed["knots"]} >= {"k8", "k9"}
        assert V.salvage(output, errors, ctx, after_retry=True) is None or len(output["knots"]) > 1
    elif category == "strand_dup":
        assert V.salvage(output, errors, ctx, after_retry=True) is not None
    else:
        assert V.salvage(output, errors, ctx, after_retry=True) is None  # dropped


def test_a_valid_output_passes_and_placeholders_and_known_names_are_kept():
    ctx = _ctx({"I1": "周建国：吧台拆完了，打〔手机号·a1b2c3〕约下一步"})
    out = _out(knots=[_knot(kind="commitment", state="planned", who=["周建国", "我"], quote="打〔手机号·a1b2c3〕约下一步",
                            text="约〔手机号·a1b2c3〕下一步")])
    assert V.validate(out, ctx) == []


def test_blocks_need_an_explicit_dependency_that_names_the_other_matter():
    others = {"E7": "双臂整理真机实验 双臂整理真机实验"}
    ctx = _ctx({"I1": "结果表先空着，等双臂整理实验的数据出来再写结果表。", "I2": "双臂整理实验这周也在跑"}, others=others)
    ok = {"other": "E7", "direction": "waits_on", "item_id": "I1", "quote": "等双臂整理实验的数据出来再写结果表"}
    assert V.block_errors(ok, ctx) == []
    no_cue = {"other": "E7", "direction": "waits_on", "item_id": "I2", "quote": "双臂整理实验这周也在跑"}
    assert V.block_errors(no_cue, ctx) and "states no dependency" in V.block_errors(no_cue, ctx)[0]
    unnamed = {"other": "E7", "direction": "waits_on", "item_id": "I1", "quote": "数据出来再写结果表"}
    assert "does not name" in V.block_errors(unnamed, ctx)[0]
    assert V.block_errors(dict(ok, other="E8"), ctx)


# ---- relations: blocks and crossings ------------------------------------------------------------------------


def _paper_and_experiment(org, chat):
    exp = [make_item(f"读书会第{i}次：讨论第{i}章", minutes=5 * i) for i in range(2)]
    ingest(org, *exp)
    org.drain()
    items = cafe(8) + [make_item("咖啡馆开业海报先空着，等读书会讨论出来再定标语", minutes=95)]

    def with_block(data, schema):
        waits = next(i for i in data["items"] if "等读书会" in i["text"])
        other = next(o["id"] for o in data["other_matters"] if "读书会" in o["title"])
        return map_out(data, blocks=[{"other": other, "direction": "waits_on", "item_id": waits["id"],
                                      "quote": "等读书会讨论出来再定标语"}])
    chat.handlers["matter-map"] = with_block
    ingest(org, *items)
    org.drain()
    return exp, items


def test_a_stated_dependency_becomes_a_blocks_edge_and_a_rejected_edge_is_never_proposed_again(org, chat):
    exp, items = _paper_and_experiment(org, chat)
    a, b = event_of(org, exp[0]["item_id"]), event_of(org, items[0]["item_id"])
    rel = [r for r in org.state(0)["relations"] if r["kind"] == "blocks"]
    assert rel == [{"kind": "blocks", "a": a, "b": b, "quote": "等读书会讨论出来再定标语", "item_id": items[-1]["item_id"],
                    "proposed": True, "source_event": b}]
    ok, _ = apply_decision(org, {"kind": "reject_relation", "relation": "blocks", "a": a, "b": b})
    assert ok and not [r for r in org.state(0)["relations"] if r["kind"] == "blocks"]
    ingest(org, *cafe(3, start=20))  # the map is drawn again and states the same edge
    org.drain()
    assert chat.count("matter-map") == 2
    assert not [r for r in org.state(0)["relations"] if r["kind"] == "blocks"]


def test_crossings_come_from_segments_of_one_item_filed_into_two_matters_and_can_be_hidden(org, chat):
    ingest(org, make_item("咖啡馆菜单周五定", minutes=0), make_item("读书会地点改到图书馆", minutes=5))
    org.drain()
    both = make_item(TWO_MATTERS, minutes=30, kind="dictation")
    ingest(org, both)
    org.drain()
    cross = [r for r in org.state(0)["relations"] if r["kind"] == "cross"]
    assert len(cross) == 1 and cross[0]["count"] == 1 and cross[0]["item_ids"] == [both["item_id"]] \
        and cross[0]["proposed"] is False
    ok, _ = apply_decision(org, {"kind": "hide_crossing", "a": cross[0]["b"], "b": cross[0]["a"]})
    assert ok and not [r for r in org.state(0)["relations"] if r["kind"] == "cross"]


def test_a_split_items_segments_are_mapped_by_segment(org, chat):
    ingest(org, *cafe(7))
    org.drain()
    both = make_item(TWO_MATTERS, minutes=100, kind="dictation")
    ingest(org, both)
    org.drain()
    ev = next(e for e in live(org) if len(e["item_ids"]) >= 8)
    m = ev["map"]
    refs = [r for s in m["strands"] for r in s["segment_refs"]]
    assert m is not None and refs and refs[0]["item_id"] == both["item_id"] and both["item_id"] in m["strands"][-1]["item_ids"]
    call = [c for c in chat.calls if c[0] == "matter-map"][-1][1]
    assert any("part_of" in i for i in call["items"])


def test_the_view_leaves_out_items_that_left_the_matter(org, chat):
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    eid = event_of(org, items[-1]["item_id"])
    ok, _ = apply_decision(org, {"kind": "unfile_item", "item_id": items[-1]["item_id"]})
    assert ok
    m = next(e for e in org.state(0)["events"] if e["event_id"] == eid)["map"]
    assert items[-1]["item_id"] not in m["strands"][0]["item_ids"]
    assert m["knots"] == []  # its only knot quoted the item that left


# ---- privacy -------------------------------------------------------------------------------------------------


def test_deleting_an_item_prunes_maps_blocks_and_their_runs(settings, org, chat):
    exp, items = _paper_and_experiment(org, chat)
    gone = items[-1]  # quoted by the blocks edge and by the last knot
    eid = event_of(org, gone["item_id"])
    assert org.store.one("SELECT 1 FROM runs WHERE job_type='map' AND read_items LIKE ?", (f"%{gone['item_id']}%",))
    org.delete_item(gone["item_id"])
    m = next(e for e in org.state(0)["events"] if e["event_id"] == eid)["map"]
    assert gone["item_id"] not in json.dumps(m) and m["stale"] is True
    assert not [r for r in org.state(0)["relations"] if r["kind"] == "blocks"]
    raw = org.store.one("SELECT map FROM event_maps WHERE event_id=?", (eid,))["map"]
    assert gone["item_id"] not in raw and "等读书会" not in raw
    assert org.store.one("SELECT output FROM runs WHERE job_type='map' AND read_items LIKE ?",
                         (f"%{gone['item_id']}%",))["output"] is None
    assert org.store.one("SELECT 1 FROM map_queue WHERE event_id=?", (eid,))  # drawn again without it
    chat.handlers["matter-map"] = lambda data, schema: map_out(data)
    org.drain()
    assert org.store.map_row(eid)["stale"] == 0


def test_every_knot_that_cites_the_deleted_item_goes_even_with_other_evidence(org, chat):
    """v6 rule, applied to the map (review finding V7-M1): a knot written partly from a deleted item goes, whether
    its quote is that item's text or the other item's."""
    def two_evidence(data, schema):
        out = map_out(data)
        a, b = data["items"][-2], data["items"][-1]
        out["knots"] = [{"id": "k1", "strand": "s2", "kind": "progress", "text": "两条合起来", "date": b["t"][:10],
                         "state": "done", "who": [], "evidence": [a["id"], b["id"]], "quote": b["text"][:8]},
                        {"id": "k2", "strand": "s2", "kind": "progress", "text": "另一条", "date": a["t"][:10],
                         "state": "done", "who": [], "evidence": [a["id"], b["id"]], "quote": a["text"][:8]}]
        return out
    chat.handlers["matter-map"] = two_evidence
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    org.delete_item(items[-1]["item_id"])
    m = the_event(org, items[0]["item_id"])["map"]
    assert m["knots"] == []


def test_wipe_forgets_maps_and_relations(settings, org, chat):
    _paper_and_experiment(org, chat)
    assert org.store.one("SELECT COUNT(*) AS n FROM event_maps")["n"] >= 1
    forget_and_rekey(org)
    rows = dump(settings)
    assert "等读书会" not in rows and "咖啡馆" not in rows
    assert org.store.one("SELECT COUNT(*) AS n FROM event_maps")["n"] == 0
    assert org.store.one("SELECT COUNT(*) AS n FROM relations")["n"] == 0


def test_a_lock_during_a_map_call_writes_nothing_and_the_map_is_drawn_after_the_next_unlock(org, chat):
    chat.before["matter-map"] = lambda _data: elsewhere(org.lock)
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    assert org.store.locked
    elsewhere(lambda: org.unlock(TEST_KEY))
    assert org.store.one("SELECT COUNT(*) AS n FROM event_maps")["n"] == 0
    org.drain()
    assert the_event(org, items[0]["item_id"])["map"] is not None


@pytest.mark.parametrize("workers", [1, 3])
def test_a_map_call_in_flight_during_forget_writes_nothing_into_the_next_store(settings, workers):
    chat = FakeChat()
    settings.workers = workers
    settings.record_inputs = True
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    chat.before["matter-map"] = lambda _data: forget_and_rekey(org)
    ingest(org, *cafe(9, extra=SENTINEL))
    org.drain()
    settle(org)
    assert chat.count("matter-map") >= 1
    rows = dump(settings)
    assert SENTINEL not in rows and "matter_map" not in rows and "matter-map" not in rows
    if org.pipeline is not None:
        org.pipeline.shutdown()


def test_pipeline_mode_draws_the_same_maps(settings):
    chat = FakeChat()
    settings.workers = 3
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    items = cafe(9)
    ingest(org, *items)
    org.drain()
    assert the_event(org, items[0]["item_id"])["map"] is not None
    org.pipeline.shutdown()

