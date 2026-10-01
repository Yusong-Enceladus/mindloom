"""The consolidation pass (organizer/consolidate.py, skill event-consolidate) with a scripted model.

All data here is invented for tests.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from conftest import REPO, assign_out, default_assign, event_of, ingest, make_item, topic_of

from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.decisions import apply_decision


def _script(name: str):
    path = REPO / "skills" / "event-consolidate" / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"test_consolidate_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


directory = _script("directory")
validate = _script("validate")


@pytest.fixture(autouse=True)
def pass_after_every_item(org):
    """Most tests look at one pass right after one item; the idle trigger's own gating is tested below."""
    org.consolidator.idle_min_items = 1


def out(verdict: str, item: dict, target: str = "", *, matter: bool = True, quote: str | None = None,
        relation: str | None = None) -> dict:
    return {"small_object": "测试对象", "small_is_matter": matter, "candidate": target,
            "relation": relation or ("same" if verdict == "merge" else "none"), "reason": "测试理由", "verdict": verdict,
            "target": target, "quote": {"item_id": item["item_id"], "text": quote or item["text"][:16]}}


def by_topic(data: dict, schema: dict) -> dict:
    """Merge a small event into the target whose title names the same test topic; a pickup code is no matter;
    anything else is kept."""
    first = data["small"]["items"][0]
    topic = topic_of(first["text"])
    views = {m["event_id"]: m for m in data["matters"] + data["more_matters"]}
    if topic:
        for h in data["targets"]:
            v = views.get(h)
            if v and topic in (v["title"] + v["sample"]):
                return out("merge", first, h)
    if "取件码" in first["text"] and data["can_unfile"]:
        return out("not_matter", first, matter=False)
    return out("own_matter", first)


CAFE = ["咖啡馆开业菜单周五前定下来", "咖啡馆招牌下周二安装", "咖啡馆豆子报价出来了"]


def cafe_with_fragment(org, chat, fragment_text: str = "咖啡馆开业那天的气球已经订好"):
    """Three cafe items in one event, then a cafe item event-assign put into an event of its own."""
    items = [make_item(t, minutes=10 * i) for i, t in enumerate(CAFE)]
    ingest(org, *items)
    org.drain()
    frag = make_item(fragment_text, minutes=40)
    chat.push("event-assign", assign_out("new", obj="开业气球"))
    return items, frag


def live_events(org) -> list[dict]:
    return [e for e in org.state(0)["events"] if not e["deleted"]]


# ---- merging and unfiling ------------------------------------------------------------------

def test_fragment_is_merged_into_its_matter_like_a_user_merge(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    big = event_of(org, items[0]["item_id"])
    ingest(org, frag)
    org.drain()
    assert event_of(org, frag["item_id"]) == big
    merged = [e for e in org.state(0)["events"] if e["merged_into"] == big]
    assert len(merged) == 1 and merged[0]["deleted"]
    assert len(live_events(org)) == 1
    # the item moved as a model placement on the same revision; the matter was briefed again with it
    link = org.store.current_event_link(frag["item_id"])
    assert link["attached_by"] == "model" and link["item_revision"] == 1
    assert org.store.get_event(big)["needs_brief"] == 0
    brief_data = [d for s, d, _, _ in chat.calls if s == "event-brief"][-1]
    assert any("气球" in i["text"] for i in brief_data["items"])
    row = org.store.one("SELECT * FROM consolidate_checks WHERE event_id=?", (merged[0]["event_id"],))
    assert row["outcome"] == "merged" and row["target"] == big
    prop = org.store.one("SELECT * FROM proposals WHERE kind='consolidate' AND target_id=?", (merged[0]["event_id"],))
    assert prop["status"] == "applied"
    # the model saw the matter directory and was limited to larger events
    call = next(c for c in chat.calls if c[0] == "event-consolidate"
                and c[1]["small"]["event_id"] == org.store.event_handle(merged[0]["event_id"]))
    data, schema = call[1], call[2]
    assert data["targets"] == [org.store.event_handle(big)]
    assert schema["properties"]["target"]["enum"] == [org.store.event_handle(big), ""]
    assert schema["properties"]["candidate"]["enum"] == [org.store.event_handle(big), ""]
    assert [m["event_id"] for m in data["matters"]] == [org.store.event_handle(big)]


def test_non_matter_goes_back_to_unfiled(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, _ = cafe_with_fragment(org, chat)
    chat.queued.pop("event-assign")
    code = make_item("【驿站】您的包裹已到，取件码 8-2-4092", minutes=50)
    ingest(org, code)
    org.drain()
    assert event_of(org, code["item_id"]) is None
    unfiled = {u["item_id"]: u["reason"] for u in org.state(0)["unfiled"]}
    assert unfiled[code["item_id"]] == "none"  # the reason the Mac already knows
    gone = [e for e in org.state(0)["events"] if e["deleted"] and not e["merged_into"]]
    assert len(gone) == 1
    assert len(live_events(org)) == 1


def test_first_item_that_is_no_matter_is_judged_without_targets(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    code = make_item("【驿站】取件码 1-1-2020，请及时领取")
    ingest(org, code)
    org.drain()
    assert event_of(org, code["item_id"]) is None
    call = [c for c in chat.calls if c[0] == "event-consolidate"][-1]
    assert call[1]["targets"] == [] and call[2]["properties"]["verdict"]["enum"] == ["own_matter", "not_matter"]


def test_own_matter_is_kept_and_judged_again_only_when_it_doubles(org, chat):
    items, frag = cafe_with_fragment(org, chat, "读书会十月书目定了")
    ingest(org, frag)
    org.drain()
    small = event_of(org, frag["item_id"])
    judged = lambda: sum(1 for c in chat.calls if c[0] == "event-consolidate"  # noqa: E731
                         and c[1]["small"]["event_id"] == org.store.event_handle(small))
    assert judged() == 1
    ingest(org, make_item("咖啡馆吧台灯具验收", minutes=60))
    org.drain()
    assert judged() == 1  # nothing about it changed
    ingest(org, make_item("读书会要提前订房间", minutes=70))
    org.drain()
    assert event_of(org, frag["item_id"]) == small and judged() == 2  # 1 -> 2 items


def test_a_new_near_neighbour_triggers_a_second_look():
    events = [{"event_id": "big", "order": 1, "n": 9, "centroid": [1.0, 0.0], "protected": False},
              {"event_id": "new", "order": 3, "n": 5, "centroid": [0.0, 1.0], "protected": False},
              {"event_id": "x", "order": 2, "n": 1, "centroid": [0.1, 1.0], "protected": False}]
    checks = {"x": {"n_items": 1, "near": ["big"], "outcome": "kept", "n_checks": 1}}
    plan = directory.plan(events, checks)
    assert plan["subjects"][0]["event_id"] == "x" and plan["subjects"][0]["nearest"][0] == "new"
    checks["x"]["near"] = ["new", "big"]
    assert "x" not in [s["event_id"] for s in directory.plan(events, checks)["subjects"]]
    checks["x"] = {"n_items": 1, "near": [], "outcome": "stale", "n_checks": 4}
    assert "x" not in [s["event_id"] for s in directory.plan(events, checks)["subjects"]]  # max_checks


# ---- user decisions win --------------------------------------------------------------------

def test_user_renamed_or_placed_events_are_never_judged(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    org.consolidator.enabled = False
    ingest(org, frag)
    org.drain()
    small = event_of(org, frag["item_id"])
    ok, _ = apply_decision(org, {"kind": "rename_event", "event_id": small, "title": "气球"})
    assert ok
    placed = make_item("咖啡馆的外卖平台上线了", minutes=60)
    chat.push("event-assign", assign_out("new", obj="外卖"))
    ingest(org, placed)
    org.drain()
    other = event_of(org, placed["item_id"])
    ok, _ = apply_decision(org, {"kind": "file_item_new_event", "item_id": placed["item_id"]})
    assert ok
    other = event_of(org, placed["item_id"])
    org.consolidator.enabled = True
    org.drain()
    handles = {c[1]["small"]["event_id"] for c in chat.calls if c[0] == "event-consolidate"}
    assert org.store.event_handle(small) not in handles and org.store.event_handle(other) not in handles
    assert event_of(org, frag["item_id"]) == small


def test_events_the_user_kept_apart_are_never_a_target(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    org.consolidator.enabled = False
    ingest(org, frag)
    org.drain()
    big, small = event_of(org, items[0]["item_id"]), event_of(org, frag["item_id"])
    ok, _ = apply_decision(org, {"kind": "same_event", "a": big, "b": small, "answer": False})
    assert ok
    org.consolidator.enabled = True
    org.drain()
    assert event_of(org, frag["item_id"]) == small
    for c in chat.calls:
        if c[0] == "event-consolidate" and c[1]["small"]["event_id"] == org.store.event_handle(small):
            assert org.store.event_handle(big) not in c[1]["targets"]


def test_merge_is_skipped_when_the_user_removed_one_of_its_items_from_the_target(org, chat):
    items, frag = cafe_with_fragment(org, chat)
    big = event_of(org, items[0]["item_id"])
    org.consolidator.enabled = False
    ingest(org, frag)
    org.drain()
    # the user took the fragment's item out of the matter before: it may not go back there
    org.store.add_constraint("forbid_item_event", frag["item_id"], big, None)
    frag_event = event_of(org, frag["item_id"])
    chat.push("event-consolidate", out("merge", {"item_id": org.store.item_handle(frag["item_id"]), "text": frag["text"]},
                                       org.store.event_handle(big)))
    org.consolidator.enabled = True
    org.drain()
    assert event_of(org, frag["item_id"]) == frag_event
    row = org.store.one("SELECT outcome FROM consolidate_checks WHERE event_id=?", (frag_event,))
    assert row["outcome"] == "skipped"


def test_an_event_that_changed_during_the_call_is_left_for_the_next_pass(org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    org.consolidator.enabled = False
    ingest(org, frag)
    org.drain()
    small = event_of(org, frag["item_id"])
    late = make_item("咖啡馆开业气球的颜色选蓝色", minutes=45)
    chat.push("event-assign", assign_out("new", obj="气球颜色"))
    ingest(org, late)
    org.drain()
    late_event = event_of(org, late["item_id"])
    # while the model judges `small`, a user moves another item into it
    chat.before["event-consolidate"] = lambda data: apply_decision(
        org, {"kind": "move_item", "item_id": late["item_id"], "to_event_id": small})
    org.consolidator.enabled = True
    stats = org.consolidator.run() if org.consolidator.idle_due() else {}
    assert stats["stale"] >= 1
    assert event_of(org, frag["item_id"]) == small  # not merged on the old snapshot
    assert org.store.one("SELECT outcome FROM consolidate_checks WHERE event_id=?", (small,))["outcome"] == "stale"
    assert event_of(org, late["item_id"]) == small != late_event  # the user's move stands


def test_invalid_output_twice_changes_nothing(org, chat):
    items, frag = cafe_with_fragment(org, chat)
    big = event_of(org, items[0]["item_id"])
    ingest(org, frag)
    bad = {"small_object": "气球", "small_is_matter": True, "reason": "测试", "verdict": "merge",
           "target": "", "quote": {"item_id": org.store.item_handle(frag["item_id"]), "text": "原文里没有这句话"}}
    chat.push("event-consolidate", bad, bad)
    org.drain()
    small = event_of(org, frag["item_id"])
    assert small != big
    assert org.store.one("SELECT outcome FROM consolidate_checks WHERE event_id=?", (small,))["outcome"] == "invalid"


def test_fragments_merged_in_one_pass_follow_their_target(org, chat):
    """y -> x and x -> big in the same pass: everything ends in big (x grew only by this pass's merge)."""
    items, frag = cafe_with_fragment(org, chat)
    chat.queued.pop("event-assign")
    org.consolidator.enabled = False
    x1 = make_item("咖啡馆开业气球订了两百个", minutes=41)
    x2 = make_item("咖啡馆开业气球下午送到", minutes=42)
    y = make_item("开业气球要不要印店名", minutes=43)
    chat.push("event-assign", assign_out("new", obj="开业气球"))
    ingest(org, x1)
    org.drain()
    x = event_of(org, x1["item_id"])
    ingest(org, x2)
    org.drain()
    assert event_of(org, x2["item_id"]) == x
    chat.push("event-assign", assign_out("new", obj="气球印字"))
    ingest(org, y)
    org.drain()
    big, ye = event_of(org, items[0]["item_id"]), event_of(org, y["item_id"])
    assert len({big, x, ye}) == 3
    hx, hbig = org.store.event_handle(x), org.store.event_handle(big)

    def judge(data, schema):
        first = data["small"]["items"][0]
        if data["small"]["event_id"] == hx:
            return out("merge", first, hbig, quote="咖啡馆开业气球")
        return out("merge", first, hx, quote="开业气球")
    chat.handlers["event-consolidate"] = judge
    org.consolidator.enabled = True
    org.drain()
    assert {event_of(org, i["item_id"]) for i in (x1, x2, y)} == {big}
    assert org.store.get_event(ye)["merged_into"] == x and org.store.get_event(x)["merged_into"] == big


def test_a_larger_event_absorbs_its_smaller_twin(org, chat):
    """The organizer keeps the larger event of a merged pair, whichever one was being judged."""
    items, frag = cafe_with_fragment(org, chat)
    chat.queued.pop("event-assign")
    org.consolidator.enabled = False
    twin = make_item("咖啡馆读书角的十月书目定了", minutes=41)
    chat.push("event-assign", assign_out("new", obj="读书会"))
    ingest(org, twin)
    org.drain()
    big, small = event_of(org, items[0]["item_id"]), event_of(org, twin["item_id"])
    hbig, hsmall = org.store.event_handle(big), org.store.event_handle(small)

    def judge(data, schema):
        first = data["small"]["items"][0]
        if data["small"]["event_id"] == hbig:  # the 3-item event names the 1-item one (invented: same matter)
            return out("merge", first, hsmall, quote="咖啡馆")
        return out("own_matter", first)
    chat.handlers["event-consolidate"] = judge
    org.store.x("DELETE FROM consolidate_checks WHERE event_id=?", (big,))  # the big event is judged again now
    org.consolidator.enabled = True
    org.drain()
    assert event_of(org, twin["item_id"]) == big
    assert org.store.get_event(small)["merged_into"] == big and not org.store.get_event(big)["deleted"]
    prop = org.store.one("SELECT reason FROM proposals WHERE kind='consolidate' AND reason LIKE 'absorbed%'")
    assert prop is not None


@pytest.mark.parametrize("second_look_agrees", [True, False])
def test_merging_a_sizeable_event_needs_a_second_look(org, chat, second_look_agrees):
    org.consolidator.budget["detail_min_items"] = 1  # treat every event as sizeable here
    looks = []

    def judge(data, schema):
        looks.append(data)
        if not data["matters"]:  # the confirmation: only the chosen event, with its items, no directory
            assert len(data["more_matters"]) == 1 and data["more_matters"][0]["items"]
            assert schema["properties"]["verdict"]["enum"] == ["merge", "own_matter"]
            if not second_look_agrees:
                return out("own_matter", data["small"]["items"][0], relation="part")
        return by_topic(data, schema)
    chat.handlers["event-consolidate"] = judge
    items, frag = cafe_with_fragment(org, chat)
    big = event_of(org, items[0]["item_id"])
    ingest(org, frag)
    org.drain()
    assert any(not d["matters"] for d in looks)
    assert (event_of(org, frag["item_id"]) == big) is second_look_agrees
    if not second_look_agrees:
        assert org.store.one("SELECT 1 FROM proposals WHERE kind='consolidate' AND reason LIKE 'merge not confirmed%'")


def test_two_established_events_merge_only_after_a_second_look(org, chat):
    """Both sides already hold 3+ items (two established matters): the merge is asked again, pairwise."""
    items = [make_item(t, minutes=10 * i) for i, t in enumerate(CAFE)]
    ingest(org, *items)
    org.drain()
    others = [make_item(t, minutes=40 + i) for i, t in enumerate(["咖啡馆开业气球订了两百个", "咖啡馆开业气球下午送到",
                                                                  "咖啡馆开业气球颜色选蓝色"])]
    chat.push("event-assign", assign_out("new", obj="开业气球"))
    org.consolidator.enabled = False
    ingest(org, others[0])
    org.drain()
    balloons = event_of(org, others[0]["item_id"])
    for it in others[1:]:
        chat.push("event-assign", assign_out("attach", org.store.event_handle(balloons), obj="开业气球",
                                             judged=[{"event_id": org.store.event_handle(balloons), "match": "same_object"}]))
        ingest(org, it)
        org.drain()
    assert len(org.store.event_item_ids(balloons)) == 3
    looks = []

    def judge(data, schema):
        looks.append(bool(data["matters"]))
        if not data["matters"]:
            return out("own_matter", data["small"]["items"][0], relation="part")
        return by_topic(data, schema)
    chat.handlers["event-consolidate"] = judge
    org.consolidator.enabled = True
    org.drain()
    assert False in looks  # the second look ran
    assert event_of(org, others[0]["item_id"]) == balloons  # and it said no


def test_two_sizeable_events_need_names_that_agree(org, chat):
    names = org.consolidator._names_agree
    assert names({"title": "3号烤箱安装调试", "anchor": ""}, {"title": "3号烤箱排风安装", "anchor": ""})
    assert not names({"title": "烘焙展烤箱演示", "anchor": ""}, {"title": "3号烤箱安装调试", "anchor": ""})  # one word
    org.owner_aliases = ("许念",)
    assert not names({"title": "许念面试栖木", "anchor": ""}, {"title": "许念去留", "anchor": ""})  # the user's name


# ---- scheduling ----------------------------------------------------------------------------

def test_idle_pass_waits_for_a_few_items_unless_the_last_pass_changed_something(org, chat):
    org.consolidator.idle_min_items = 3
    chat.handlers["event-consolidate"] = by_topic
    ingest(org, *[make_item(t, minutes=i) for i, t in enumerate(CAFE)])
    org.drain()  # a fresh start tidies once
    calls = chat.count("event-consolidate")
    chat.push("event-assign", assign_out("new", obj="读书会"))
    ingest(org, make_item("读书会十月书目定了", minutes=30))
    org.drain()
    assert chat.count("event-consolidate") == calls  # one new item: not yet
    chat.push("event-assign", assign_out("new", obj="体检"), assign_out("new", obj="开业气球"))
    ingest(org, make_item("体检预约在下周一", minutes=31), make_item("咖啡馆开业气球订好了", minutes=32))
    org.drain()
    assert chat.count("event-consolidate") > calls  # three new items: a pass

def test_periodic_pass_runs_while_items_are_still_queued(org, chat):
    org.consolidator.every_items = 2
    depths = []
    chat.before["event-consolidate"] = lambda data: depths.append(org.store.queue_depth())
    items = [make_item(t, minutes=i) for i, t in enumerate(CAFE + ["读书会书目", "体检预约", "搬家公司报价"])]
    chat.push("event-assign", *[assign_out("new", obj=f"对象{i}") for i in range(len(items))])
    ingest(org, *items)
    org.drain()
    assert depths and depths[0] > 0


def test_idle_organizer_does_not_replan_when_nothing_changed(org, chat):
    ingest(org, *[make_item(t, minutes=i) for i, t in enumerate(CAFE)])
    org.drain()
    calls = chat.count("event-consolidate")
    for _ in range(5):
        assert org.step() is False
    assert chat.count("event-consolidate") == calls


def test_pipeline_mode_gives_the_same_events_as_serial(settings, tmp_path):
    from conftest import FakeChat

    results = []
    for workers in (1, 3):
        s = type(settings)()
        s.data_dir = tmp_path / f"w{workers}"
        s.skills_dir = settings.skills_dir
        s.start_worker = False
        s.embed_base_url = ""
        s.unlock_key = settings.unlock_key
        s.workers = workers
        s.consolidate_every = 3
        chat = FakeChat()
        chat.handlers["event-consolidate"] = by_topic
        org = build_organizer(s, chat=chat, embedder=HashEmbedClient())
        items = [make_item(t, minutes=i, item_id=f"00000000-0000-0000-0000-00000000000{i}")
                 for i, t in enumerate(CAFE + ["咖啡馆开业气球订好了", "取件码 3-3-3030", "读书会书目"])]
        chat.handlers["event-assign"] = lambda data, schema: (
            assign_out("new", obj="开业气球") if "气球" in data["item"]["text"] else default_assign(data, schema))
        ingest(org, *items)
        org.drain()
        results.append(sorted(sorted(e["item_ids"]) for e in org.state(0)["events"] if not e["deleted"]))
        if org.pipeline is not None:
            org.pipeline.shutdown()
    assert results[0] == results[1]


def test_health_reports_consolidation_counts(client, org, chat):
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    ingest(org, frag)
    org.drain()
    h = client.get("/v1/health").json()
    assert h["consolidation"]["merged"] == 1 and h["consolidation"]["enabled"] is True
    assert "event-consolidate" in {s["name"] for s in h["skills"]}


def test_consolidation_can_be_turned_off(settings, chat):
    settings.consolidate = False
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(org, make_item("【驿站】取件码 1-1-2020"))
    org.drain()
    assert chat.count("event-consolidate") == 0


# ---- the skill's deterministic parts -------------------------------------------------------

def test_plan_orders_subjects_smallest_first_and_respects_the_budget():
    events = [{"event_id": f"e{i}", "order": i, "n": n, "centroid": None, "protected": False}
              for i, n in enumerate([30, 12, 1, 4, 1, 50], 1)]
    events.append({"event_id": "p", "order": 9, "n": 1, "centroid": None, "protected": True})
    plan = directory.plan(events, max_calls=3, directory_size=3, directory_min_items=3)
    assert [s["event_id"] for s in plan["subjects"]] == ["e3", "e5", "e4"] and plan["waiting"] == 3
    assert plan["directory"] == ["e1", "e2", "e6"]  # the three largest, shown in creation order
    e4 = plan["subjects"][2]
    assert e4["targets"][:3] == ["e1", "e2", "e6"] and "e4" not in e4["targets"]
    assert plan["subjects"][0]["can_unfile"] is True
    big = directory.plan(events, subject_max_items=40, unfile_max_items=3)["subjects"]
    e2 = next(s for s in big if s["event_id"] == "e2")  # 12 items: only its nearest three, shown in detail
    assert e2["detail"] and len(e2["targets"]) == 3 and e2["extra"] == e2["targets"] and not e2["can_unfile"]


def test_an_established_event_only_joins_an_event_of_comparable_size():
    events = [{"event_id": "giant", "order": 1, "n": 300, "centroid": [1.0, 0.0], "protected": False},
              {"event_id": "twin", "order": 2, "n": 60, "centroid": [0.9, 0.3], "protected": False},
              {"event_id": "work", "order": 3, "n": 40, "centroid": [0.95, 0.2], "protected": False},
              {"event_id": "frag", "order": 4, "n": 12, "centroid": [0.97, 0.1], "protected": False}]
    plan = {s["event_id"]: s for s in directory.plan(events)["subjects"]}
    assert "giant" not in plan["work"]["targets"] and "twin" in plan["work"]["targets"]  # 300 > 4 x 40
    assert "giant" in plan["frag"]["targets"]  # under 20 items: a fragment may still join the big event
    small = directory.plan(events + [{"event_id": "bit", "order": 5, "n": 5, "centroid": [0.94, 0.25],
                                      "protected": False}], checks={"bit": {"n_items": 5, "near": [], "outcome": "kept",
                                                                            "n_checks": 4}})
    assert "bit" in {s["event_id"]: s for s in small["subjects"]}["work"]["targets"]  # it may absorb a fragment


def test_plan_never_targets_a_pair_kept_apart():
    events = [{"event_id": "a", "order": 1, "n": 5, "centroid": None, "protected": False},
              {"event_id": "b", "order": 2, "n": 1, "centroid": None, "protected": False}]
    plan = directory.plan(events, apart=[["b", "a"]])
    assert [(s["event_id"], s["targets"]) for s in plan["subjects"]] == [("b", []), ("a", [])]


@pytest.mark.parametrize("output,ok", [
    (dict(verdict="merge", target="E3", candidate="E3", relation="same", small_is_matter=True, small_object="市集押金",
          quote={"item_id": "I1", "text": "市集那天的帐篷押金"}), True),
    # a bare acknowledgement cannot justify a merge
    (dict(verdict="merge", target="E3", candidate="E3", relation="same", small_is_matter=True, small_object="确认",
          quote={"item_id": "I2", "text": "好的收到"}), False),
    # grounded through small_object: a word of the target that the small event's items also use
    (dict(verdict="merge", target="E3", candidate="E3", relation="same", small_is_matter=True, small_object="市集帐篷",
          quote={"item_id": "I2", "text": "好的收到"}), True),
    (dict(verdict="merge", target="E9", candidate="E9", relation="same", small_is_matter=True, small_object="市集",
          quote={"item_id": "I1", "text": "市集那天的帐篷押金"}), False),  # not an allowed target
    (dict(verdict="merge", target="E3", candidate="E3", relation="same", small_is_matter=True, small_object="市集",
          quote={"item_id": "I1", "text": "市集那天的帐篷定金"}), False),  # not verbatim
    (dict(verdict="merge", target="E3", candidate="E3", relation="same", small_is_matter=True, small_object="市集",
          quote={"item_id": "I1", "text": "市集 那天的帐篷押金300！"}), True),  # spacing / punctuation differ
    (dict(verdict="merge", target="E3", candidate="E3", relation="part", small_is_matter=True, small_object="市集",
          quote={"item_id": "I1", "text": "市集那天的帐篷押金"}), False),  # only `same` merges
    (dict(verdict="merge", target="E3", candidate="", relation="same", small_is_matter=True, small_object="市集",
          quote={"item_id": "I1", "text": "市集那天的帐篷押金"}), False),  # same needs its candidate
    (dict(verdict="own_matter", target="", candidate="E3", relation="part", small_is_matter=True,
          small_object="市集宣传片", quote={"item_id": "I1", "text": "市集那天的帐篷押金"}), True),
    (dict(verdict="not_matter", target="", candidate="", relation="none", small_is_matter=False, small_object="确认",
          quote={"item_id": "I2", "text": "好的收到"}), True),
    (dict(verdict="not_matter", target="", candidate="", relation="none", small_is_matter=True, small_object="确认",
          quote={"item_id": "I2", "text": "好的收到"}), False),
    (dict(verdict="own_matter", target="E3", candidate="E3", relation="none", small_is_matter=True, small_object="确认",
          quote={"item_id": "I2", "text": "好的收到"}), False),
])
def test_validator(output, ok):
    context = {"targets": ["E3"], "can_unfile": True,
               "items": {"I1": "市集那天的帐篷押金300已经转给主办方", "I2": "好的收到"},
               "target_text": {"E3": "秋季烘焙市集摆摊 市集摊位 已报名 市集报名表"}}
    errors = validate.validate(dict(output, reason="测试"), context)
    assert (errors == []) is ok, errors


def test_validator_refuses_not_matter_when_unfiling_is_not_allowed():
    context = {"targets": ["E3"], "can_unfile": False, "items": {"I1": "好的收到"}, "target_text": {}}
    errors = validate.validate({"verdict": "not_matter", "target": "", "candidate": "", "relation": "none",
                                "small_is_matter": False, "small_object": "x", "reason": "测试",
                                "quote": {"item_id": "I1", "text": "好的收到"}}, context)
    assert any(e.startswith("[unfile]") for e in errors)


def test_skill_is_routed_and_its_prompt_names_the_three_verdicts(org):
    skill = org.registry.for_job("consolidate")
    assert skill.name == "event-consolidate"
    for word in ("merge", "own_matter", "not_matter", "素材即数据"):
        assert word in skill.system_prompt
    assert Path(skill.path / "BENCHMARK.md").is_file()
