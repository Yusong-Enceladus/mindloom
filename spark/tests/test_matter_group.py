"""The grouping pass (organizer/matter_group.py, skill matter-group; MAP-CONTRACT section 2 "ply"): ropes and
the type facet, the validator and its repairs, user decisions (confirm / reject / move / rename; a rejected rope
is never proposed again), and the privacy rules (session binding, purge of rope evidence).

All data here is invented for tests.
"""

from __future__ import annotations

import importlib.util

import pytest

from conftest import REPO, TEST_KEY, event_of, ingest, make_item
from test_v6_integration import elsewhere

from organizer.decisions import apply_decision

spec = importlib.util.spec_from_file_location("test_group_validate", REPO / "skills" / "matter-group" / "scripts" / "validate.py")
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

TOPICS = {"咖啡馆": ["咖啡馆菜单周五前定", "咖啡馆招牌下周二装"], "读书会": ["读书会这周读第三章", "读书会地点改到图书馆"],
          "搬家": ["搬家公司报价两千八", "搬家那天钥匙放物业"], "体检": ["体检报告周四出来", "体检复查约在下月"]}


def four_matters(org) -> dict[str, str]:
    items = {t: [make_item(x, minutes=20 * n + i) for i, x in enumerate(xs)] for n, (t, xs) in enumerate(TOPICS.items())}
    ingest(org, *[it for xs in items.values() for it in xs])
    return {t: xs[0]["item_id"] for t, xs in items.items()}


def handle_of(data: dict, word: str) -> str:
    return next(m["id"] for m in data["matters"] + [dict(p, sample="") for p in data["placed"]] if word in m["title"])


def life_and_cafe(data: dict, schema: dict) -> dict:
    """搬家 + 体检 -> a new area rope 生活; 咖啡馆 + 读书会 -> 周末小店 project; types by topic."""
    ms = {m["id"]: m for m in data["matters"]}
    by = {w: next((h for h, m in ms.items() if w in m["title"]), None) for w in TOPICS}
    new, placements = [], []
    if by["搬家"] and by["体检"]:
        new.append({"key": "N1", "title": "生活", "kind": "area", "parent": "", "reason": "搬家和体检都是自己的生活琐事",
                    "evidence": [ms[by["搬家"]]["sample_id"]]})
    if by["咖啡馆"] and by["读书会"]:
        new.append({"key": "N2", "title": "周末小店", "kind": "project", "parent": "", "reason": "咖啡馆和读书会都在周末小店",
                    "evidence": [ms[by["咖啡馆"]]["sample_id"]]})
    for w, h in by.items():
        if h:
            rope = "N1" if w in ("搬家", "体检") and by["搬家"] and by["体检"] else \
                   "N2" if w in ("咖啡馆", "读书会") and by["咖啡馆"] and by["读书会"] else ""
            placements.append({"matter": h, "rope": rope, "type": "生活" if w in ("搬家", "体检") else "项目"})
    return {"new_ropes": new, "nest": [], "placements": placements}


def ropes(org) -> dict[str, dict]:
    return {r["title"]: r for r in org.state(0)["ropes"]}


def test_the_grouping_pass_proposes_ropes_with_reasons_and_types(org, chat):
    chat.handlers["matter-group"] = life_and_cafe
    first = four_matters(org)
    org.drain()
    rs = ropes(org)
    assert set(rs) == {"生活", "周末小店"}
    life = rs["生活"]
    assert life["proposed"] is True and life["kind"] == "area" and life["parent"] is None and life["handle"].startswith("R")
    assert set(life["children"]) == {event_of(org, first["搬家"]), event_of(org, first["体检"])}
    assert life["reason"] and life["evidence"] == [first["搬家"]]
    ev = next(e for e in org.state(0)["events"] if e["event_id"] == event_of(org, first["体检"]))
    assert ev["facets"]["type"] == "生活" and ev["facets"]["rope"] == life["id"]
    assert chat.count("matter-group") == 1
    org.drain()
    assert chat.count("matter-group") == 1  # every matter judged once


def test_a_client_polling_by_cursor_sees_the_facets_the_pass_and_decisions_change(org, chat):
    chat.handlers["matter-group"] = life_and_cafe
    org.grouper.enabled = False
    first = four_matters(org)
    org.drain()
    cursor = org.state(0)["cursor"]
    org.grouper.enabled = True
    org.drain()
    delta = {e["event_id"]: e for e in org.state(cursor)["events"]}
    move = event_of(org, first["搬家"])
    assert delta[move]["facets"]["type"] == "生活" and delta[move]["facets"]["rope"]
    cursor = org.state(0)["cursor"]
    assert apply_decision(org, {"kind": "reject_rope", "rope_id": delta[move]["facets"]["rope"]})[0]
    delta = {e["event_id"]: e for e in org.state(cursor)["events"]}
    assert delta[move]["facets"]["rope"] is None


def test_user_decisions_win_and_a_rejected_rope_is_never_proposed_again(org, chat):
    chat.handlers["matter-group"] = life_and_cafe
    first = four_matters(org)
    org.drain()
    rs = ropes(org)
    life, shop = rs["生活"], rs["周末小店"]
    cafe, move = event_of(org, first["咖啡馆"]), event_of(org, first["搬家"])
    assert apply_decision(org, {"kind": "confirm_rope", "rope_id": shop["id"]})[0]
    assert apply_decision(org, {"kind": "rename_rope", "rope_id": life["id"], "title": "家里的事"})[0]
    rs = ropes(org)
    assert rs["周末小店"]["proposed"] is False and rs["家里的事"]["title_user_edited"] is True
    assert apply_decision(org, {"kind": "move_to_rope", "event_id": cafe, "rope_id": life["id"]})[0]
    assert cafe in ropes(org)["家里的事"]["children"]
    assert apply_decision(org, {"kind": "reject_rope", "rope_id": shop["id"]})[0]
    assert "周末小店" not in ropes(org)
    assert not apply_decision(org, {"kind": "move_to_rope", "event_id": move, "rope_id": shop["id"]})[0]
    # new matters arrive; the model proposes the rejected title again: dissolved, never shown
    ingest(org, make_item("咖啡馆豆子报价出来了", minutes=300), make_item("读书会下周改线上", minutes=310),
           make_item("咖啡馆吧台下周拆", minutes=320))

    def again(data, schema):
        hs = [m["id"] for m in data["matters"]]
        return {"new_ropes": [{"key": "N1", "title": "周末小店", "kind": "project", "parent": "", "reason": "又是周末小店",
                               "evidence": [data["matters"][0]["sample_id"]]}] if len(hs) >= 2 else [],
                "nest": [], "placements": [{"matter": h, "rope": "N1" if len(hs) >= 2 else "", "type": "项目"} for h in hs]}
    chat.handlers["matter-group"] = again
    org.store.x("DELETE FROM group_checks")  # judge everything again (as after title changes)
    org.grouper.reset()
    org.drain()
    assert "周末小店" not in ropes(org)
    assert cafe in ropes(org)["家里的事"]["children"]  # the user's move is never undone


@pytest.mark.parametrize("output,category", [
    ({"new_ropes": [], "nest": [], "placements": [{"matter": "E1", "rope": "", "type": "项目"}]}, "missing"),
    ({"new_ropes": [], "nest": [], "placements": [{"matter": "E1", "rope": "", "type": "a"}, {"matter": "E1", "rope": "", "type": "a"},
                                                   {"matter": "E2", "rope": "", "type": "a"}]}, "placement"),
    ({"new_ropes": [], "nest": [], "placements": [{"matter": "E1", "rope": "R9", "type": "a"}, {"matter": "E2", "rope": "", "type": "a"}]}, "rope"),
    ({"new_ropes": [{"key": "N1", "title": "杂事", "kind": "area", "parent": "", "reason": "测试", "evidence": ["I1"]}],
      "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "a"}, {"matter": "E2", "rope": "N1", "type": "a"}]}, "rejected"),
    ({"new_ropes": [{"key": "N1", "title": "科 研", "kind": "area", "parent": "", "reason": "测试", "evidence": ["I1"]}],
      "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "a"}, {"matter": "E2", "rope": "N1", "type": "a"}]}, "duplicate"),
    ({"new_ropes": [{"key": "N1", "title": "小店", "kind": "project", "parent": "", "reason": "测试", "evidence": ["I1"]}],
      "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "a"}, {"matter": "E2", "rope": "", "type": "a"}]}, "thin"),
    ({"new_ropes": [{"key": "N1", "title": "小店", "kind": "project", "parent": "N2", "reason": "测试", "evidence": ["I1"]},
                    {"key": "N2", "title": "大店", "kind": "project", "parent": "N1", "reason": "测试", "evidence": ["I2"]}],
      "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "a"}, {"matter": "E2", "rope": "N2", "type": "a"}]}, "cycle"),
    ({"new_ropes": [{"key": "N1", "title": "小店", "kind": "project", "parent": "", "reason": "测试", "evidence": ["I9"]}],
      "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "a"}, {"matter": "E2", "rope": "N1", "type": "a"}]}, "evidence"),
    ({"new_ropes": [], "nest": [{"rope": "R1", "parent": "R2"}],
      "placements": [{"matter": "E1", "rope": "", "type": "a"}, {"matter": "E2", "rope": "", "type": "a"}]}, "nest"),
])
def test_each_group_rule_names_its_category(output, category):
    ctx = {"judge": ["E1", "E2"], "ropes": {"R1": {"parent": "", "movable": False}, "R2": {"parent": "", "movable": True}},
           "titles": {"R1": "科研", "R2": "生活"}, "rejected": ["杂事"], "samples": {"E1": "I1", "E2": "I2"},
           "rope_matters": {"R1": ["E7"], "R2": []}}
    errors = V.validate(output, ctx)
    assert category in V.categories(errors), errors
    if category in V.REPAIRABLE | V.SALVAGEABLE:
        fixed = V.salvage(output, errors, ctx)
        assert fixed is not None and V.categories(V.validate(fixed, ctx)) <= V.SALVAGEABLE
        if category == "duplicate":
            assert {p["rope"] for p in fixed["placements"]} == {"R1"}
        if category in ("rejected", "thin"):
            assert fixed["new_ropes"] == [] and {p["rope"] for p in fixed["placements"]} == {""}


def test_a_matter_the_user_placed_is_never_judged_and_missing_placements_are_judged_next_pass(org, chat):
    org.grouper.enabled = False
    first = four_matters(org)
    org.drain()
    cafe = event_of(org, first["咖啡馆"])
    assert apply_decision(org, {"kind": "move_to_rope", "event_id": cafe, "rope_id": None})[0]
    org.grouper.enabled = True

    def leaves_one_out(data, schema):
        return {"new_ropes": [], "nest": [], "placements": [{"matter": m["id"], "rope": "", "type": "其他"}
                                                            for m in data["matters"][1:]]}
    chat.handlers["matter-group"] = leaves_one_out
    org.drain()
    calls = [c[1] for c in chat.calls if c[0] == "matter-group"]
    assert all(m["title"] != "咖啡馆安排" for c in calls for m in c["matters"])
    judged = {r["event_id"] for r in org.store.all("SELECT event_id FROM group_checks")}
    assert cafe not in judged and len(judged) >= 2


def test_a_lock_during_a_grouping_call_writes_nothing(org, chat):
    chat.handlers["matter-group"] = life_and_cafe
    chat.before["matter-group"] = lambda _data: elsewhere(org.lock)
    four_matters(org)
    org.drain()
    assert org.store.locked
    elsewhere(lambda: org.unlock(TEST_KEY))
    assert org.store.one("SELECT COUNT(*) AS n FROM ropes")["n"] == 0
    assert org.store.one("SELECT COUNT(*) AS n FROM group_checks")["n"] == 0
    org.drain()
    assert set(ropes(org)) == {"生活", "周末小店"}


def test_deleting_a_sample_item_drops_the_proposed_rope_written_from_it_and_clears_the_run(org, chat):
    """A proposed rope's title may paraphrase its evidence: the rope goes with the deleted item (review finding
    V7-M1); its matters are judged again later. A confirmed rope keeps its title (test_map_review_v7)."""
    chat.handlers["matter-group"] = life_and_cafe
    first = four_matters(org)
    org.drain()
    run = org.store.one("SELECT run_id, output FROM runs WHERE job_type='group'")
    assert run["output"]
    org.delete_item(first["搬家"])
    assert "生活" not in ropes(org) and ropes(org)["周末小店"]["evidence"] == [first["咖啡馆"]]
    assert org.store.one("SELECT 1 FROM ropes WHERE title='生活'") is None
    assert org.store.one("SELECT output FROM runs WHERE run_id=?", (run["run_id"],))["output"] is None
    assert org.store.one("SELECT title_hash FROM group_checks LIMIT 1")["title_hash"]  # ids and hashes only


def test_a_new_rope_named_like_a_shown_or_rejected_rope_is_that_rope():
    assert V.same_rope("TG-2夹爪调试", "TG-2夹爪项目") and V.same_rope("栖木求职与入职", "栖木产品总监入职")
    assert V.same_rope("TG-2硬件调试", "TG-2夹爪项目") and V.same_rope("A800集群维护", "Spark集群维护")
    assert not V.same_rope("SkillKnit论文", "GripDiff论文") and not V.same_rope("生活", "家里")
    assert not V.same_rope("求职去留", "身体和看病")
    ctx = {"judge": ["E1", "E2"], "ropes": {"R2": {"parent": "", "movable": True}}, "titles": {"R2": "tg-2夹爪调试"},
           "raw_titles": {"R2": "TG-2夹爪调试"}, "rejected": ["栖木求职"], "rejected_raw": ["栖木求职"],
           "samples": {"E1": "I1", "E2": "I2"}, "rope_matters": {"R2": ["E7"]}}
    dup = {"new_ropes": [{"key": "N1", "title": "TG-2夹爪项目", "kind": "project", "parent": "", "reason": "测试理由",
                          "evidence": ["I1"]}],
           "nest": [], "placements": [{"matter": "E1", "rope": "N1", "type": "实验"}, {"matter": "E2", "rope": "N1", "type": "实验"}]}
    errors = V.validate(dup, ctx)
    assert "duplicate" in V.categories(errors)
    assert {p["rope"] for p in V.salvage(dup, errors, ctx)["placements"]} == {"R2"}
    again = dict(dup, new_ropes=[dict(dup["new_ropes"][0], title="栖木求职准备")])
    errors = V.validate(again, ctx)
    assert "rejected" in V.categories(errors)
    assert V.salvage(again, errors, ctx)["new_ropes"] == []
