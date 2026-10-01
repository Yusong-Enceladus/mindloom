"""Regressions for the e2e polish round: derived readings in /v1/state, people named in pasted chat
text, the Home-card status line and fact dates, and the follow-up floor on the home ranking.

Every name and text here is invented for the tests.
"""

import sys

import pytest

from conftest import REPO, TEST_KEY, TINY_PNG_B64, auth_headers, raw_connect, chat_extraction, event_of, image_reader, ingest, make_item
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.clock import FixedClock
from organizer.persons import chat_person_id, speakers_in_text
from organizer.skills import SkillRegistry
from organizer.store import Store

REG = SkillRegistry(REPO / "skills")
BRIEF = REG.script("event-brief", "validate")
FLOOR = REG.script("home-rank", "floor")


# ---- 1. derived readings ---------------------------------------------------------------------

def test_state_carries_the_screenshot_reading_for_the_items_current_revision(org, chat):
    shot = make_item(kind="image", image_b64=TINY_PNG_B64, app="微信")
    note = make_item("读书会下周换场地", minutes=5)
    ingest(org, shot, note)
    org.drain()
    state = org.state(0)
    assert set(state) >= {"cursor", "events", "questions", "persons", "unfiled", "readings"}
    r = state["readings"][shot["item_id"]]
    assert r["revision"] == 1 and r["source"] == "image-read" and r["type"] == "chat_screenshot"
    assert "张三：咖啡馆豆子报价每公斤120" in r["text"]
    assert r["messages"][0] == {"sender": "张三", "is_self": False, "time": "10:02", "text": "咖啡馆豆子报价每公斤120"}
    assert r["run_id"]
    assert note["item_id"] not in state["readings"]           # text items: the Mac already has the text
    # A delta like events: nothing new after the cursor ...
    assert org.state(state["cursor"])["readings"] == {}
    # ... and a new revision publishes its own reading, keyed by the same item id.
    chat.handlers["image-read"] = image_reader(chat_extraction([{"sender": "张三", "is_self": False, "time": "11:00", "text": "改成每公斤118"}], "张三改了报价"))
    ingest(org, make_item(kind="image", image_b64=TINY_PNG_B64, item_id=shot["item_id"], revision=2, minutes=1))
    org.drain()
    later = org.state(state["cursor"])["readings"]
    assert list(later) == [shot["item_id"]] and later[shot["item_id"]]["revision"] == 2
    assert "118" in later[shot["item_id"]]["text"]
    # A later embedding write on the same row does not republish the reading.
    cur = org.state(0)["cursor"]
    org.store.save_derived(shot["item_id"], 2, embedding=[0.1, 0.2], embed_model="m")
    assert org.state(cur)["readings"] == {}


def test_state_endpoint_keeps_old_fields_and_adds_readings(settings, org):
    from fastapi.testclient import TestClient

    app = create_app(settings, organizer=org)
    ingest(org, make_item(kind="image", image_b64=TINY_PNG_B64))
    org.drain()
    with TestClient(app, headers=auth_headers(app)) as c:
        body = c.get("/v1/state").json()
    assert {"cursor", "events", "questions", "persons", "unfiled", "store_id"} <= set(body)
    assert len(body["readings"]) == 1


def test_readings_stored_before_the_upgrade_reach_clients_with_an_old_cursor(tmp_path):
    db = tmp_path / "o.db"
    store = Store(db, key=TEST_KEY)
    store.insert_item({"item_id": "A", "revision": 1, "kind": "image", "source_app": {"name": "微信"},
                       "started_at": "2026-09-20T09:00:00+08:00", "sha256": "0" * 64}, b"\x89PNG....")
    store.save_derived("A", 1, derived_text="旧读图", messages=[], screenshot_run_id="run-old")
    store.lock()
    # Simulate a database written by the previous version (no reading_seq column).
    conn = raw_connect(db)
    conn.execute("ALTER TABLE item_derived DROP COLUMN reading_seq")
    conn.commit()
    old_cursor = int(conn.execute("SELECT value FROM meta WHERE key='seq'").fetchone()[0])
    conn.close()
    reopened = Store(db, key=TEST_KEY)
    rows = reopened.readings_since(old_cursor)
    assert [(r["item_id"], r["revision"], r["derived_text"]) for r in rows] == [("A", 1, "旧读图")]


# ---- 2. people from pasted chat text ---------------------------------------------------------

def test_speakers_in_text_reads_speaker_lines_and_bylines_but_not_labels():
    chat = "顾一舟：周四前把样稿发我\n我：好的\n韩老师: 我这边也看一下\n"
    assert speakers_in_text(chat) == ["顾一舟", "我", "韩老师"]
    assert speakers_in_text("Lena 10:05\n样品到了\n梅姐 2026/9/24 10:07\n收到") == ["Lena", "梅姐"]
    labels = ("时间：9月3日下午\n地点：三楼会议室\n备注：带伞\n付款方式：现金\n报价人：王五\n"
              "注意事项：别迟到\nQ: 几点开始\nA: 两点\nhttps://example.invalid/x")
    assert speakers_in_text(labels) == []
    assert speakers_in_text("整理要点：\n1. 先定预算\n2. 再约场地") == []     # a heading, content on the next lines
    assert speakers_in_text("一、核心指标（环比+4%）；\n二、下一步") == []
    assert speakers_in_text("岚-印刷厂：纸样寄出了") == ["岚-印刷厂"]


def test_text_speakers_become_persons_through_the_screenshot_sender_path(org, chat):
    chat.handlers["image-read"] = image_reader(chat_extraction([{"sender": "顾一舟", "is_self": False, "time": "", "text": "读书会几点"}], "顾一舟问读书会"))
    pasted = make_item("顾一舟：读书会这周换到图书馆\n我：好，我通知大家\n小蒋：我带投影仪", kind="text", app="微信")
    shot = make_item(kind="image", image_b64=TINY_PNG_B64, minutes=3)
    dictated = make_item("顾一舟：这不是聊天，是口述里的一句", minutes=6)
    ingest(org, pasted, shot, dictated)
    org.drain()
    ids = org.people.item_person_ids(pasted["item_id"])
    names = {org.people.label(p) for p in ids}
    assert names == {"顾一舟", "小蒋"}                           # the owner (我) is never a person
    assert org.people.get(chat_person_id("顾一舟"))["name_source"] == "text"
    # the screenshot sender with the same name is the same person, not a duplicate
    assert org.people.item_person_ids(shot["item_id"]) == [chat_person_id("顾一舟")]
    # only kind=text is parsed for speakers; the dictation only *names* 顾一舟 (a mention, people_pass.py)
    assert org.people.item_person_ids(dictated["item_id"], exclude_roles=("mention",)) == []
    assert org.people.item_person_ids(dictated["item_id"]) == [chat_person_id("顾一舟")]
    persons = {p["display_name"] for p in org.state(0)["persons"]}
    assert {"顾一舟", "小蒋"} <= persons and "我" not in persons
    ev = event_of(org, pasted["item_id"])
    assert chat_person_id("小蒋") in org.state(0)["events"][[e["event_id"] for e in org.state(0)["events"]].index(ev)]["person_ids"]


def test_owner_aliases_are_configurable(settings, chat):
    settings.owner_aliases = ("我", "苏言", "小苏")
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(org, make_item("苏言：场地我来订\n小苏: 明早确认\n韩老师：好的", kind="text", app="企业微信"))
    org.drain()
    assert {p["display_name"] for p in org.state(0)["persons"]} == {"韩老师"}


def test_near_names_in_text_are_asked_not_merged(org):
    meeting = make_item("读书会例会", kind="meeting_offline", persons=[{"person_id": "voice-9", "display_name": "蒋师傅"}])
    first = make_item("小蒋：投影仪修好了", kind="text", app="微信", minutes=5)
    ingest(org, meeting, first)
    org.drain()
    qs = [q for q in org.state(0)["questions"] if q["kind"] == "same_person"]
    assert len(qs) == 1 and "小蒋" in qs[0]["prompt_zh"] and "蒋师傅" in qs[0]["prompt_zh"]
    assert org.people.canonical(chat_person_id("小蒋")) == chat_person_id("小蒋")   # not merged
    # chat vs chat near names (a nickname and a full name) are asked too, within the budget
    ingest(org, make_item("韩老师：书单发群里了", kind="text", app="微信", minutes=9),
           make_item("韩立：书单我看了", kind="text", app="微信", minutes=12))
    org.drain()
    prompts = [q["prompt_zh"] for q in org.state(0)["questions"] if q["kind"] == "same_person"]
    assert any("韩立" in p and "韩老师" in p for p in prompts)
    assert org.people.canonical(chat_person_id("韩立")) != org.people.canonical(chat_person_id("韩老师"))


# ---- 3. status line fits the Home card; facts do not repeat their date -------------------------

def _ctx():
    return {"item_ids": ["I1"], "title_locked": False, "current_title": "",
            "items": {"I1": {"text": "班长：大巴押金刚转过去了，3月12日出发，当天回", "captured_at": "2026-03-05T09:00:00+08:00"}}}


def _brief(line, *facts):
    return {"title": "春季研学", "status_line": line, "off_anchor_item_ids": [],
            "status_facts": list(facts) or [{"text": "包车两辆", "state": "info", "date": "", "quote": "", "item_ids": ["I1"]}]}


def test_status_line_width_is_capped_and_salvage_keeps_the_leading_clauses():
    assert BRIEF.line_width("3月12日出发") == 5.5 and BRIEF.STATUS_MAX_WIDTH == 24
    assert BRIEF.validate(_brief("押金已交，3月12日出发"), _ctx()) == []
    long = "3月12日全班出发，包车两辆共2400元，家长回执还没有收齐，班主任在催"
    errs = BRIEF.validate(_brief(long), _ctx())
    assert any(e.startswith("[length]") for e in errs)
    kept = BRIEF.salvage(_brief(long), _ctx())
    assert kept["status_line"] == "3月12日全班出发，包车两辆共2400元"
    assert BRIEF.line_width(kept["status_line"]) <= 24
    # nothing fits: the line is not applied (the previous one stays)
    assert BRIEF.salvage(_brief("三月十二日全班同学一起乘坐两辆大巴前往湿地公园开展研学活动"), _ctx())["status_line"] is None


def test_fact_text_drops_the_date_its_date_field_already_carries():
    f = lambda text, d: {"text": text, "state": "planned", "date": d, "quote": "", "item_ids": ["I1"]}  # noqa: E731
    out = BRIEF.tidy(_brief("3月12日出发", f("定于3月12日（周四）出发，当天往返", "2026-03-12"),
                            f("3月10日前交回执", "2026-03-10"), f("出发日从3月12日改到3月19日", "2026-03-19"),
                            f("大巴押金", "")))
    assert [x["text"] for x in out["status_facts"]] == ["出发，当天往返", "3月10日前交回执",
                                                         "出发日从3月12日改到3月19日", "大巴押金"]


def test_organizer_stores_tidied_facts(org, chat):
    it = make_item("班长：3月12日出发，当天回")
    chat.push("event-brief", {"title": "春季研学", "status_line": "3月12日出发", "off_anchor_item_ids": [],
                              "status_facts": [{"text": "3月12日（周四）出发", "state": "planned", "date": "2026-03-12",
                                                "quote": "", "item_ids": ["I1"]}]})
    ingest(org, it)
    org.drain()
    ev = org.store.get_event(event_of(org, it["item_id"]))
    assert ev["status_facts"][0]["text"] == "出发" and ev["status_facts"][0]["date"] == "2026-03-12"


def test_scorer_reports_home_width_and_repeated_dates_as_added_metrics():
    sys.path.insert(0, str(REPO / "eval"))
    import score

    state = {"events": [
        {"title": "a", "status_line": "押金已交，3月12日出发", "item_ids": ["x"], "facts_raw": [
            {"text": "3月12日出发", "date": "2026-03-12"}, {"text": "出发", "date": "2026-03-12"}]},
        {"title": "b", "status_line": "三月十二日全班同学一起乘坐两辆大巴前往湿地公园开展研学", "item_ids": ["y"], "facts_raw": []}]}
    fit = score.ui_fit(state)
    assert fit["status_over"] == 0 and fit["status_over_width"] == 1       # the frozen 54-char rule is unchanged
    assert fit["fact_date_repeated"] == 1 and fit["status_widths"][0] == 10.5


# ---- 4. home-rank follow-up floor --------------------------------------------------------------

def _facts(*spec):
    return [{"text": t, "state": s, "date": d, "quote": "", "item_ids": ["x"]} for t, s, d in spec]


def test_floor_lifts_an_open_follow_up_within_a_week_above_events_with_nothing_open():
    ranking = [{"event_id": "E1", "importance": 0.2, "reason": "主事已办完"},
               {"event_id": "E2", "importance": 0.5, "reason": "只有信息"},
               {"event_id": "E3", "importance": 0.1, "reason": "下月的事"},
               {"event_id": "E4", "importance": 0.15, "reason": "少展示"},
               {"event_id": "E5", "importance": 0.3, "reason": "计划已过"}]
    events = {"E1": {"status_facts": _facts(("合同已签", "done", "2026-09-26"), ("找人修门锁", "planned", "2026-09-30"))},
              "E2": {"status_facts": _facts(("报价每份35元", "info", ""))},
              "E3": {"status_facts": _facts(("交年检材料", "planned", "2026-10-20"))},
              "E4": {"status_facts": _facts(("取快递", "planned", "2026-09-28")), "feature_less": True},
              "E5": {"status_facts": _facts(("彩排", "planned", "2026-09-20"))}}
    out, lifted = FLOOR.apply_floor(ranking, events, "2026-09-27")
    imp = {r["event_id"]: r["importance"] for r in out}
    assert lifted == ["E1"]
    assert imp["E1"] > imp["E2"] and imp["E1"] > imp["E5"]
    assert "9月30日" in next(r["reason"] for r in out if r["event_id"] == "E1")
    assert imp["E3"] == 0.1 and imp["E4"] == 0.15                   # beyond 7 days / feature-less: untouched
    # an event whose items still mention an upcoming date is not "only info / past", whatever its card says
    events_b = dict(events, E2=dict(events["E2"], upcoming=["2026-10-02"]), E5=dict(events["E5"], upcoming=["2026-09-28"]))
    out_b, lifted_b = FLOOR.apply_floor(ranking, events_b, "2026-09-27")
    assert lifted_b == [] and out_b == ranking
    # already above every closed event: unchanged
    same, none = FLOOR.apply_floor([dict(ranking[0], importance=0.9), ranking[1]], events, "2026-09-27")
    assert none == [] and same[0]["importance"] == 0.9


def test_organizer_rank_applies_the_floor(settings, chat):
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient(), clock=FixedClock("2026-09-27T12:00:00+08:00"))
    a, b = make_item("咖啡馆门锁"), make_item("读书会书目", minutes=5)
    ingest(org, a, b)
    org.drain()
    ea, eb = event_of(org, a["item_id"]), event_of(org, b["item_id"])
    org.store.update_event(ea, status_facts=_facts(("找人修门锁", "planned", "2026-09-29")))
    org.store.update_event(eb, status_facts=_facts(("书目定了", "info", "")))
    ha, hb = org.store.event_handle(ea), org.store.event_handle(eb)
    chat.push("home-rank", {"ranking": [{"event_id": ha, "importance": 0.2, "reason": "已结束"},
                                        {"event_id": hb, "importance": 0.6, "reason": "有进展"}]})
    org.rank()
    assert org.store.get_event(ea)["importance"] > org.store.get_event(eb)["importance"] == 0.6
    prop = org.store.one("SELECT payload, reason FROM proposals WHERE kind='rank' ORDER BY proposal_id DESC LIMIT 1")
    assert ha in prop["reason"] and '"importance":0.2' in prop["payload"]   # the model's own score is kept


@pytest.mark.parametrize("today", ["2026-09-27"])
def test_floor_cli_contract(today, tmp_path):
    import json
    import subprocess

    p = tmp_path / "in.json"
    p.write_text(json.dumps({"ranking": [{"event_id": "E1", "importance": 0.1, "reason": "r"},
                                         {"event_id": "E2", "importance": 0.4, "reason": "r"}],
                             "events": {"E1": {"status_facts": _facts(("交表", "in_progress", "2026-09-28"))},
                                        "E2": {"status_facts": []}}, "today": today}), encoding="utf-8")
    res = subprocess.run([sys.executable, str(REPO / "skills/home-rank/scripts/floor.py"), str(p)],
                         capture_output=True, text=True, check=True)
    assert json.loads(res.stdout)["lifted"] == ["E1"]


def test_text_speakers_are_people_but_not_matching_evidence(org, chat):
    """A shared name in pasted text says who talked, not which matter: the same helper on two jobs."""
    a = make_item("顾一舟：读书会场地定在图书馆", kind="text", app="微信")
    b = make_item("顾一舟：我家水管也漏了，你认识师傅吗", kind="text", app="微信", minutes=4)
    ingest(org, a, b)
    org.drain()
    gu = chat_person_id("顾一舟")
    assert org.other_persons(a["item_id"]) == [gu]                      # people pages, briefs, state
    assert org.other_persons(a["item_id"], for_matching=True) == []     # retrieval and event-assign
    assign_inputs = [d for s, d, _, _ in chat.calls if s == "event-assign"]
    assert all(d["item"]["persons"] == [] for d in assign_inputs)
    assert all(c["retrieval"]["shared_persons"] == [] for d in assign_inputs for c in d["candidates"])
    brief_inputs = [d for s, d, _, _ in chat.calls if s == "event-brief"]
    assert any("顾一舟" in d["event"]["persons"] for d in brief_inputs)
