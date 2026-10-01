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
