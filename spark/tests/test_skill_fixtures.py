"""The executable skill-eval fixtures stay runnable: requests build like the organizer's, and checks
refer to ids that exist in the fixture (no model)."""

import sys

import pytest

from conftest import REPO
from organizer import jsonschema_lite
from organizer.skills import SkillRegistry, build_user_message

sys.path.insert(0, str(REPO / "eval"))
import run_skill_evals  # noqa: E402

REG = SkillRegistry(REPO / "skills")
CASES = run_skill_evals.cases(["event-assign", "event-brief", "home-rank"])


def test_there_are_fixtures_for_every_failure_class():
    ids = {c["id"] for _, c in CASES}
    assert {"assign-hd1", "assign-hd3", "assign-hd4", "assign-r1-none", "assign-r3-injection",
            "brief-006", "brief-009", "brief-010", "rank-m1-stakes", "rank-m5-injection"} <= ids
    assert all("holdout" not in c.get("source", "").split("(")[0] for _, c in CASES)


@pytest.mark.parametrize("skill,case", CASES, ids=[c["id"] for _, c in CASES])
def test_fixture_builds_a_request_and_its_checks_refer_to_real_ids(skill, case):
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert "<data>" in build_user_message(data)
    chk = case["check"]
    if skill == "event-assign":
        handles = {c["event_id"] for c in data["candidates"]}
        assert set(chk.get("not_attach", [])) <= handles and chk.get("event_id", next(iter(handles), "")) in handles | {""}
        assert set(chk["decision_in"]) <= {"attach", "new", "none", "ask"}
    elif skill == "event-brief":
        assert set(context["items"]) == {i["item_id"] for i in data["items"]}
        if chk.get("off_anchor_includes"):
            assert chk["off_anchor_includes"] in context["items"]
    else:
        ids = {e["event_id"] for e in data["events"]}
        for con in chk["constraints"]:
            assert set(con.get("above", [])) | set(con.get("max", {})) | set(con.get("min", {})) <= ids
    assert jsonschema_lite.validate({}, schema)  # a real schema, not a stub


CONSOLIDATE = run_skill_evals.cases(["event-consolidate"])


@pytest.mark.parametrize("skill,case", CONSOLIDATE, ids=[c["id"] for _, c in CONSOLIDATE])
def test_consolidate_fixture_builds_like_the_organizer_and_its_expected_answer_validates(skill, case):
    """An answer that meets the case's check passes the schema (with the per-call enums) and validate.py, so a
    failing run is the model's answer, never an impossible case."""
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert job == "consolidate" and case["source"].startswith("invented")
    chk = case["check"]
    item = data["small"]["items"][0]
    verdict = chk["verdict_in"][0]
    target = chk.get("target", "") if verdict == "merge" else ""
    answer = {"small_object": "测试", "small_is_matter": verdict != "not_matter", "candidate": target,
              "relation": "same" if verdict == "merge" else "none", "reason": "测试理由", "verdict": verdict,
              "target": target, "quote": {"item_id": item["item_id"], "text": item["text"][:12]}}
    if verdict == "merge":  # quote the item line that names the target's object
        words = REG.script("event-consolidate", "validate").terms(context["target_text"][target])
        line = next(i for i in data["small"]["items"]
                    if REG.script("event-consolidate", "validate").terms(i["text"]) & words)
        answer["quote"] = {"item_id": line["item_id"], "text": line["text"][:30]}
    assert jsonschema_lite.validate(answer, schema) == []
    assert REG.for_job("consolidate").validator(answer, context) == [], case["id"]


PERSON = run_skill_evals.cases(["person-resolve"])


@pytest.mark.parametrize("skill,case", PERSON, ids=[c["id"] for _, c in PERSON])
def test_person_fixture_builds_like_the_people_pass_and_its_expected_answer_validates(skill, case):
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert job == "person" and case["source"].startswith("invented")
    chk = case["check"]
    kind = chk["kind_in"][0]
    answer = {"kind": kind, "same_as": chk.get("same_as", "") if kind == "person" else "",
              "common_word": chk.get("common_word", kind != "person"), "reason": "测试理由"}
    assert jsonschema_lite.validate(answer, schema) == []
    assert REG.for_job("person").validator(answer, context) == [], case["id"]
    ok, _ = run_skill_evals.check(REG, skill, case, answer)
    assert ok, case["id"]


SPLIT_KNOWN = [c for c in run_skill_evals.cases(["item-split"]) if c[1]["fixture"].get("known")]


@pytest.mark.parametrize("skill,case", SPLIT_KNOWN, ids=[c["id"] for _, c in SPLIT_KNOWN])
def test_split_fixture_with_known_matters_builds_like_the_organizer(skill, case):
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert [k["id"] for k in data["known_matters"]] == context["known"]
    assert schema["properties"]["known"]["items"]["enum"] == [""] + context["known"]
    one = {"matters": ["测试"], "known": [context["known"][0]],
           "segments": [{"from": context["unit_ids"][0], "to": context["unit_ids"][-1], "matter": 1, "gist": "测试"}]}
    assert jsonschema_lite.validate(one, schema) == [] and REG.for_job("split").validator(one, context) == []
    bad = dict(one, known=["E99"])
    assert REG.for_job("split").validator(bad, context)


MAP = run_skill_evals.cases(["matter-map"])


def _map_answer(data: dict, chk: dict) -> dict:
    """An answer that meets the case's check: strands from the together / apart pairs, the required knot kinds and
    blocks, each quoting its item verbatim."""
    import re
    items = {i["id"]: i for i in data["items"]}
    groups: list[set] = []
    for a, b in chk.get("together", []):
        g = next((g for g in groups if a in g or b in g), None)
        if g is None:
            groups.append({a, b})
        else:
            g |= {a, b}
    for a, b in chk.get("apart", []):
        for x in (a, b):
            if not any(x in g for g in groups):
                groups.append({x})
    rest = [i for i in items if not any(i in g for g in groups)]
    while len(groups) < chk.get("n_strands", [1, 6])[0] and rest:
        groups.append({rest.pop(0)})
    strands = [{"id": f"s{n}", "name": f"线{n}", "summary": "测试", "item_ids": sorted(g), "fact_ids": [], "state": "open"}
               for n, g in enumerate(groups, 1)]
    first = data["items"][0]
    knots = []
    for n, kind in enumerate(chk.get("kinds_include", []) or ["progress"], 1):
        it = data["items"][n % len(data["items"])]
        knots.append({"id": f"k{n}", "strand": "", "kind": kind, "text": "测试的结", "date": it["t"][:10],
                      "state": "open" if kind == "question" else "planned" if kind in ("commitment", "deadline") else "done",
                      "who": (it["who"][:1] or ["我"]) if kind == "commitment" else [], "evidence": [it["id"]],
                      "quote": it["text"].replace("…", "")[:6]})
    blocks = []
    for want in chk.get("blocks", []):
        it = next(i for i in data["items"] if re.search(r"等[^，。]+", i["text"]))
        blocks.append({"other": want["other"], "direction": want["direction"], "item_id": it["id"],
                       "quote": re.search(r"等[^，。]+", it["text"]).group(0)})
    level = (chk.get("health_in") or ["ok"])[0]
    return {"strands": strands, "knots": knots, "blocks": blocks,
            "health": {"level": level, "reason": "测试理由", "evidence": [] if level == "ok" else [first["id"]]}}


@pytest.mark.parametrize("skill,case", MAP, ids=[c["id"] for _, c in MAP])
def test_map_fixture_builds_like_the_organizer_and_an_answer_meeting_its_check_validates(skill, case):
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert job == "map" and case["source"].startswith("invented")
    ids = {i["id"] for i in data["items"]}
    assert set(context["items"]) == ids and len(data["items"]) >= 8
    chk = case["check"]
    for a, b in chk.get("apart", []) + chk.get("together", []):
        assert {a, b} <= ids
    assert {b["other"] for b in chk.get("blocks", [])} <= {o["id"] for o in data["other_matters"]}
    answer = _map_answer(data, chk)
    assert jsonschema_lite.validate(answer, schema) == [], case["id"]
    assert REG.for_job("map").validator(answer, context) == [], case["id"]
    assert run_skill_evals.check(REG, skill, case, answer)[0], case["id"]


GROUP = run_skill_evals.cases(["matter-group"])


def _group_answer(data: dict, chk: dict) -> dict:
    samples = {m["id"]: m["sample_id"] for m in data["matters"]}
    placements = {m["id"]: "" for m in data["matters"]}
    new = []
    for e, r in chk.get("rope_of", {}).items():
        placements[e] = r
    for a, b in chk.get("together", []):
        key = placements.get(a) or placements.get(b)
        if not key:
            key = f"N{len(new) + 1}"
            parent = chk.get("under", {}).get(a, "")
            new.append({"key": key, "title": f"绳{len(new) + 1}", "kind": "project", "parent": parent, "reason": "测试理由",
                        "evidence": [samples[a]]})
        placements[a] = placements[b] = key
    for e, r in chk.get("under", {}).items():
        if not placements.get(e):
            placements[e] = r
    types = {e: allowed[0] for e, allowed in chk.get("type_in", {}).items()}
    return {"new_ropes": new, "nest": [], "placements": [{"matter": e, "rope": r, "type": types.get(e, "其他")}
                                                         for e, r in placements.items()]}


@pytest.mark.parametrize("skill,case", GROUP, ids=[c["id"] for _, c in GROUP])
def test_group_fixture_builds_like_the_organizer_and_an_answer_meeting_its_check_validates(skill, case):
    job, data, schema, context = run_skill_evals.build_request(REG, skill, case)
    assert job == "group" and case["source"].startswith("invented")
    answer = _group_answer(data, case["check"])
    assert jsonschema_lite.validate(answer, schema) == [], case["id"]
    assert REG.for_job("group").validator(answer, context) == [], case["id"]
    assert run_skill_evals.check(REG, skill, case, answer)[0], case["id"]
