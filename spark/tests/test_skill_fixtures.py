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
