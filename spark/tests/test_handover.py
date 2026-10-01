"""v8 B3: handover packs (skill handover-pack, organizer/handover.py), the matter.handover op that names the pack's
snapshot item, and snapshot items. Synthetic content; the model is the scripted FakeChat."""

from __future__ import annotations

import json
import sys

import pytest

from conftest import REPO, ingest, make_item
from organizer import space_member as sm
from organizer.skills import SkillRegistry
from spacekit import new_id, payload
from test_spaces import scan, spark, team  # noqa: F401 (fixture)

sys.path.insert(0, str(REPO / "eval"))
import run_skill_evals  # noqa: E402

REG = SkillRegistry(REPO / "skills")
RULES = REG.script("handover-pack", "validate")
BUILD = REG.script("handover-pack", "build")
RENDER = REG.script("handover-pack", "render")
CASES = run_skill_evals.cases(["handover-pack"])


def case(case_id: str) -> dict:
    return next(c for _, c in CASES if c["id"] == case_id)


def good_001() -> dict:
    """A correct answer for handover-001 (what the skill should write)."""
    return {"status": {"text": "两组跑完，第三组等新夹爪，表2 真机结果要在 rebuttal 前补上。", "evidence": ["I8", "I2"]},
            "commitments": [
                {"who": "小林", "to": "", "what": "把真机数据传到组盘", "due": "2026-09-22", "state": "done",
                 "evidence": ["I4", "I5"], "quote": "数据已经传到组盘了"},
                {"who": "王老师", "to": "", "what": "批额外的 GPU 机时", "due": "2026-09-26", "state": "done",
                 "evidence": ["I6", "I9"], "quote": "额外的GPU机时我周五前批下来"},
                {"who": "小周", "to": "", "what": "下周开始跑仿真对照", "due": "", "state": "open",
                 "evidence": ["I6"], "quote": "那我下周开始跑仿真对照"}],
            "deadlines": [{"what": "CoRL rebuttal 截止", "date": "2026-10-08", "evidence": ["I2"],
                           "quote": "rebuttal 十月八号截止"}],
            "decisions": [{"what": "每个设置跑 30 次", "date": "2026-09-15", "who": ["王老师"], "evidence": ["I1"],
                           "quote": "每个设置就跑30次"}],
            "open_questions": [{"what": "第二只机械臂要不要上", "evidence": ["I7"], "quote": "第二只机械臂要不要也上"}],
            "links": [{"item": "I3", "why": "实验流程文档"}],
            "next_steps": [{"what": "跟进新夹爪十月一号发货", "evidence": ["I8"]}]}


def request_001():
    job, data, schema, context = run_skill_evals.build_request(REG, "handover-pack", case("handover-001"))
    return data, schema, context


def test_the_fixtures_build_and_a_correct_answer_validates_and_passes_its_check():
    assert len(CASES) == 6
    for _, c in CASES:
        job, data, schema, context = run_skill_evals.build_request(REG, "handover-pack", c)
        assert job == "handover" and schema["properties"]["links"]["items"]["properties"]["item"]["enum"]
    data, schema, context = request_001()
    from organizer import jsonschema_lite
    out = good_001()
    assert jsonschema_lite.validate(out, schema) == []
    assert RULES.validate(out, context) == []
    ok, note = run_skill_evals.check_handover(case("handover-001"), out)
    assert ok, note
    # the same answer with the GPU promise still open fails the check (I9 says it was done)
    bad = good_001()
    bad["commitments"] = [c for c in bad["commitments"] if c["who"] != "小林"]
    assert run_skill_evals.check_handover(case("handover-001"), bad)[0] is False


def test_a_quote_must_speak_to_its_claim():
    """Review finding V8R-16: a verbatim run of any evidence item is not enough; the quote shares a word with the
    entry's what (or names the promiser of a commitment)."""
    data, schema, context = request_001()
    out = good_001()
    assert RULES.validate(out, context) == []
    out["decisions"][0]["what"] = "改用石英石台面"                 # the quote (每个设置就跑30次) does not support it
    errors = RULES.validate(out, context)
    assert any(e.startswith("[quote] decisions[0]") and "speak" in e for e in errors), errors
    assert RULES.about("周五前我把机时批下来", {"what": "批机时", "who": "王老师"})
    assert RULES.about("王老师说没问题", {"what": "批准", "who": "王老师"})
    assert not RULES.about("数据已经传到组盘了", {"what": "买新夹爪", "who": "小林"})


def test_the_validator_holds_quotes_evidence_dates_names_and_placeholders():
    data, schema, context = request_001()
    out = good_001()
    out["decisions"][0]["quote"] = "每个设置跑30次"            # paraphrased, not verbatim
    out["deadlines"][0]["evidence"] = ["I99"]
    out["commitments"][2]["due"] = "2026-10-20"              # a day no evidence names
    out["commitments"].append({"who": "赵六", "to": "", "what": "买夹爪", "due": "", "state": "open",
                               "evidence": ["I7"], "quote": "夹爪得再买一副"})
    out["open_questions"].append(dict(out["open_questions"][0]))
    out["status"]["text"] = "联系〔手机号·ffffff〕"
    errors = RULES.validate(out, context)
    cats = RULES.categories(errors)
    assert {"quote", "evidence", "ungrounded_date", "who", "duplicate", "placeholder"} <= cats, errors
    # before the retry only repairable errors are fixed: here there are others, so no salvage
    assert RULES.salvage(out, errors, context, after_retry=False) is None
    # after the retry, the broken entries go and the rest is kept (status still has an invented placeholder: none)
    assert RULES.salvage(out, errors, context, after_retry=True) is None
    out["status"]["text"] = "第三组等新夹爪"
    fixed = RULES.salvage(out, RULES.validate(out, context), context, after_retry=True)
    assert fixed is not None and RULES.validate(fixed, context) == []
    assert [c["who"] for c in fixed["commitments"]] == ["小林", "王老师", "小周"]
    assert fixed["commitments"][2]["due"] == "" and len(fixed["open_questions"]) == 1
    assert fixed["decisions"] == [] and fixed["deadlines"] == []


def test_render_cites_every_claim_and_lists_its_sources():
    data, schema, context = request_001()
    finished = BUILD.finish(good_001(), context)
    sources = {h: {"t": context["items"][h]["t"], "kind": context["items"][h]["kind"], "src": context["items"][h]["src"]}
               for h in BUILD.cited(finished)}
    md = RENDER.render(finished, sources, "B203 双臂叠衣真机实验", "2026-09-26", {"from": "小林", "to": "小周"})
    assert md.startswith("# 交接包：B203 双臂叠衣真机实验")
    assert "## 谁还欠着什么" in md and "**小周**" in md and "## 已经兑现的承诺" in md
    assert "——“每个设置就跑30次”" in md and "## 出处" in md and "（素材 `I3`）" in md
    claims = [ln for ln in md.splitlines() if ln.startswith("- ")]
    assert claims and all(any(ch in ln for ch in RENDER.CIRCLED) for ln in claims)
    # open commitments first, deadlines by date
    assert finished["commitments"][0]["state"] == "open"


def test_a_personal_pack_end_to_end_and_purged_with_its_items(org, client, chat):
    items = [make_item(f"咖啡馆 开业筹备 第{i}条 周建国说吧台就按L形做", minutes=i) for i in range(4)]
    ingest(org, *items)
    org.drain()
    ev = org.store.live_events()[0]["event_id"]
    r = client.post(f"/v1/events/{ev}/handover-pack", json={"from": "我", "to": "阿May"})
    assert r.status_code == 202, r.text
    pack_id = r.json()["pack_id"]
    assert client.get(f"/v1/handover-packs/{pack_id}").json()["status"] == "queued"
    org.drain()
    got = client.get(f"/v1/handover-packs/{pack_id}").json()
    assert got["status"] == "ready", got
    assert got["markdown"].startswith("# 交接包：") and got["people"] == {"from": "我", "to": "阿May"}
    cited = BUILD.cited(got["pack"])
    assert cited and set(cited) <= {it["item_id"] for it in items}
    assert chat.count("handover-pack") == 1
    # the run read the matter's items; deleting one that the pack cites deletes the pack
    client.delete(f"/v1/items/{cited[0]}")
    assert client.get(f"/v1/handover-packs/{pack_id}").status_code == 404
    assert client.post("/v1/events/nope/handover-pack").status_code == 404


def test_an_invalid_answer_twice_fails_the_pack_only(org, client, chat):
    ingest(org, make_item("读书会 十月场地", minutes=1), make_item("读书会 书目", minutes=2))
    org.drain()
    ev = org.store.live_events()[0]["event_id"]
    bad = {"status": {"text": "x", "evidence": ["I1"]}, "commitments": [], "deadlines": [],
           "decisions": [{"what": "编的决定", "date": "", "who": [], "evidence": ["I1"], "quote": "素材里没有这句"}],
           "open_questions": [], "links": [], "next_steps": []}
    bad["status"]["evidence"] = []
    chat.push("handover-pack", bad, bad)
    pack_id = client.post(f"/v1/events/{ev}/handover-pack").json()["pack_id"]
    org.drain()
    got = client.get(f"/v1/handover-packs/{pack_id}").json()
    assert got["status"] == "failed" and got["error"] == "invalid" and "pack" not in got


def test_a_shared_matter_pack_snapshot_and_handover(spark):  # noqa: F811
    sid, a, (w, r) = team(spark, owner="person", roles=("write", "read"))
    ids = [w.share(sid, f"合成：咖啡馆 开业 第{i}条")["item_id"] for i in range(3)]
    assert a.lease(sid).status_code == 200
    assert w.organize(sid, [payload(i, f"咖啡馆 开业 周建国说吧台按L形 {n}", minutes=n)
                            for n, i in enumerate(ids)]).status_code == 200
    org = spark.orgs.get(sid)
    org.drain()
    matter = org.store.live_events()[0]["event_id"]
    # a reader cannot ask for a pack (it costs a model call); a contributor can
    assert r.post_json(f"/v1/spaces/{sid}/organizer/handover-pack", {"matter_id": matter}).status_code == 403
    res = w.post_json(f"/v1/spaces/{sid}/organizer/handover-pack", {"matter_id": matter, "from": "小王", "to": "小李"})
    assert res.status_code == 202, res.text
    pack_id = res.json()["pack_id"]
    org.drain()
    got = r.get(f"/v1/spaces/{sid}/organizer/handover-pack/{pack_id}").json()
    assert got["status"] == "ready" and "交接包" in got["markdown"]
    # the member shares the (unmasked) Markdown as a snapshot item, then hands the matter over citing it
    snap = w.share(sid, got["markdown"], kind="snapshot", extra={"snapshot": {"matter_id": matter, "pack_id": pack_id}})
    assert snap["result"]["ok"], snap
    assert w.share(sid, "x", kind="snapshot", extra={"snapshot": {"matter_id": matter, "note": "明文"}})["result"]["ok"] \
        is False
    assert w.share(sid, "x", kind="text", extra={"snapshot": {"matter_id": matter}})["result"]["ok"] is False
    res = w.op(sid, "matter.handover", {"matter_id": matter, "to_member_id": a.member_id,
                                        "pack_item_id": snap["item_id"]})
    assert res["ok"] is False and res["error"] == "forbidden"     # the contributor is not the lead (nor maintainer)
    res = a.op(sid, "matter.handover", {"matter_id": matter, "to_member_id": w.member_id,
                                        "pack_item_id": snap["item_id"]})
    assert res["ok"] and res["effects"]["pack_item_id"] == snap["item_id"], res
    res = a.op(sid, "matter.handover", {"matter_id": matter, "to_member_id": w.member_id, "pack_item_id": ids[0]})
    assert res["ok"] is False and res["error"] == "bad_field"      # not a snapshot item
    assert w.read_items(sid)[snap["item_id"]]["text"].startswith("# 交接包")
    # withdrawing a cited item deletes the pack on the Spark
    assert w.ok(sid, "item.withdraw", {"item_id": ids[0]})
    assert r.get(f"/v1/spaces/{sid}/organizer/handover-pack/{pack_id}").json()["error"] == "unknown_pack"
    assert scan(spark.data, ["周建国说吧台按L形"]) == []
