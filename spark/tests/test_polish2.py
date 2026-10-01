"""Regressions for the second polish round: no invented dates (ranges and date provenance), decisions
that are not completions, and the screenshot summary kept apart from the transcription.

Every name and text here is invented for the tests.
"""

import sys

from conftest import REPO, TEST_KEY, TINY_PNG_B64, chat_extraction, raw_connect, event_of, image_reader, ingest, make_item
from organizer.skills import SkillRegistry
from organizer.store import Store

REG = SkillRegistry(REPO / "skills")
BRIEF = REG.script("event-brief", "validate")
DATES = REG.script("event-brief", "dates")
READING = REG.script("image-read", "reading")

# Thursday 2026-09-24: 下周 is Monday 9/28 .. Sunday 10/4.
AT = "2026-09-24T19:28:00+08:00"


def ctx(as_of=AT, **items):
    return {"item_ids": list(items), "title_locked": False, "current_title": "", "as_of": as_of,
            "items": {h: {"text": t, "captured_at": at} for h, (t, at) in items.items()}}


def out(line, *facts, title="书房换灯"):
    return {"title": title, "status_facts": list(facts), "status_line": line, "off_anchor_item_ids": []}


def fact(text, state, ids, quote="", date=""):
    return {"text": text, "state": state, "date": date, "quote": quote, "item_ids": ids}


def cats(errors):
    return {e[1:e.index("]")] for e in errors if e.startswith("[")}


LAMP = ctx(I1=("物业群：电工老李下周过来把书房吊灯换了。", AT),
           I2=("灯具店：吊灯今天已经送到物业了。", "2026-09-23T10:00:00+08:00"))
DELIVERED = fact("吊灯已送到物业", "done", ["I2"], quote="吊灯今天已经送到物业了", date="2026-09-23")


# ---- 1. ranges and date provenance ---------------------------------------------------------------

def test_bare_span_words_resolve_to_ranges_against_the_capture_day():
    def one(text, at=AT):
        return [(r["said"], r["from"], r["to"], r.get("edge", "")) for r in DATES.resolve_ranges(text, at)]
    assert one("老李下周过来") == [("下周", "2026-09-28", "2026-10-04", "")]
    assert one("下周二过来") == []                                   # an exact day stays with resolve()
    assert one("这周末去看") == [("这周末", "2026-09-26", "2026-09-27", "")]
    assert one("下周末聚") == [("下周末", "2026-10-03", "2026-10-04", "")]
    assert one("下个月起停") == [("下个月", "2026-10-01", "2026-10-31", "start")]
    assert one("月底前交") == [("月底", "2026-09-24", "2026-09-30", "end")]
    assert one("请在7天内寄回") == [("7天内", "2026-09-24", "2026-10-01", "end")]
    assert one("1-3个工作日内到账") == [("1-3个工作日", "2026-09-24", "2026-09-29", "end")]
    assert DATES.resolve("老李下周过来", AT) == []                     # resolve() itself is unchanged


def test_a_day_picked_from_a_range_is_rejected_and_the_range_wording_is_accepted():
    errs = BRIEF.validate(out("吊灯已送到，9月29日换灯", DELIVERED), LAMP)
    assert cats(errs) == {"ungrounded_date"} and "9月28日那周" in errs[0]
    planned = fact("老李来换吊灯", "planned", ["I1"], date="2026-09-29")
    assert "ungrounded_date" in cats(BRIEF.validate(out("吊灯已送到，灯待换", DELIVERED, planned), LAMP))
    for line in ("吊灯已送到，9月28日那周换灯", "吊灯已送到，10月4日前换灯", "吊灯已送到，灯待换"):
        assert BRIEF.validate(out(line, DELIVERED), LAMP) == [], line
    ranged = fact("9月28日那周老李来换吊灯", "planned", ["I1"], date="2026-09-28")
    assert BRIEF.validate(out("吊灯已送到，灯待换", DELIVERED, ranged), LAMP) == []


def test_a_fact_date_must_come_from_the_items_it_cites():
    # 9/23 is I2's own day, not I1's: citing I1 alone does not ground it.
    wrong_cite = fact("吊灯送到物业", "info", ["I1"], date="2026-09-23")
    assert "ungrounded_date" in cats(BRIEF.validate(out("吊灯已送到", DELIVERED, wrong_cite), LAMP))
    right_cite = fact("吊灯送到物业", "info", ["I2"], date="2026-09-23")
    assert BRIEF.validate(out("吊灯已送到", DELIVERED, right_cite), LAMP) == []


def test_a_bracketed_weekday_must_be_that_dates_weekday():
    c = ctx(I1=("周会定在9月28日上午十点。", AT))
    meet = fact("周会", "planned", ["I1"], date="2026-09-28")
    assert BRIEF.validate(out("9月28日（周一）上午开周会", meet), c) == []
    errs = BRIEF.validate(out("9月28日（周二）上午开周会", meet), c)
    assert cats(errs) == {"ungrounded_date"} and "周一" in errs[0]


def test_bare_next_week_is_tolerated_only_while_it_is_still_next_week():
    assert BRIEF.validate(out("吊灯已送到，下周换灯", DELIVERED), LAMP) == []
    later = dict(LAMP, as_of="2026-09-29T09:00:00+08:00")           # as of Tuesday of that very week
    assert "relative_date" in cats(BRIEF.validate(out("吊灯已送到，下周换灯", DELIVERED), later))
    assert "relative_date" in cats(BRIEF.validate(out("吊灯已送到，下周二换灯", DELIVERED), LAMP))
    assert "relative_date" in cats(BRIEF.validate(out("吊灯已送到", DELIVERED, title="下周换灯"), LAMP))


def test_salvage_drops_an_invented_date_and_keeps_the_plan_a_plan():
    bad = out("吊灯已送到，9月29日换灯", DELIVERED,
              fact("老李9月29日（周二）上午来换吊灯", "planned", ["I1"], date="2026-09-29"))
    got = BRIEF.salvage(bad, LAMP)
    assert got["status_line"] == "吊灯已送到，待换灯"
    assert [(f["text"], f["date"]) for f in got["status_facts"]] == [
        ("吊灯已送到物业", "2026-09-23"), ("老李来换吊灯", "")]
    assert BRIEF.validate(dict(bad, **{k: v for k, v in got.items() if v is not None}), LAMP) == []
    assert BRIEF.drop_dates("热水壶9月29日修", BRIEF.card_dates("热水壶9月29日修", 2026), keep_plan=True) == "热水壶待修"
    assert BRIEF.drop_dates("定于9月29日签约", BRIEF.card_dates("定于9月29日签约", 2026), keep_plan=True) == "待签约"
    # A dropped date never turns a line into a completion claim.
    assert BRIEF.claims(got["status_line"].split("，")[1]) == []


def test_organizer_drops_an_invented_date_without_a_second_call(org, chat):
    it = make_item("物业群：电工老李下周过来把书房吊灯换了。")
    it["started_at"], it["ended_at"] = AT, "2026-09-24T19:29:00+08:00"
    first = out("9月29日换吊灯", fact("老李来换吊灯", "planned", ["I1"], date="2026-09-29"))
    second = out("9月28日那周换吊灯", fact("9月28日那周老李来换吊灯", "planned", ["I1"], date="2026-09-28"))
    chat.push("event-brief", first, second)
    ingest(org, it)
    org.drain()
    data = [d for s, d, _, _ in chat.calls if s == "event-brief"][0]
    assert {"said": "下周", "from": "2026-09-28", "to": "2026-10-04"} in data["items"][0]["dates"]
    ev = org.store.get_event(event_of(org, it["item_id"]))
    # The day picked out of 下周 is dropped deterministically (BRIEF_NO_RETRY), not retried.
    assert "29日" not in ev["status_line"] and "换吊灯" in ev["status_line"]
    assert all(f["date"] != "2026-09-29" for f in ev["status_facts"])
    run = org.store.one("SELECT attempts FROM runs WHERE job_type='brief'")
    assert run["attempts"] == 1 and chat.count("event-brief") == 1


# ---- 5. a decision is not a completion ------------------------------------------------------------

DEAL = ctx(I1=("房东：押金按一个月算，合同下周寄给你。我：行，那就这么定。", "2026-09-20T10:00:00+08:00"))


def test_a_decision_only_quote_does_not_support_signed_paid_or_shipped():
    for text in ("续租合同已签", "押金已付", "合同已寄出", "合同已发货"):
        errs = BRIEF.validate(out("押金按一个月", fact(text, "done", ["I1"], quote="行，那就这么定")), DEAL)
        assert "unsupported_completion" in cats(errs), text
    agreed = fact("已同意押金按一个月算", "done", ["I1"], quote="行，那就这么定")
    assert BRIEF.validate(out("押金按一个月，已同意", agreed), DEAL) == []
    # ... and the decision does not back a completion claim in the status line either.
    assert "unsupported_completion" in cats(BRIEF.validate(out("合同已签", agreed), DEAL))
    # A quote that says the step happened still does.
    paid = ctx(I2=("好的，押金刚转过去了。", "2026-09-21T10:00:00+08:00"))
    assert BRIEF.validate(out("押金已付", fact("押金已付", "done", ["I2"], quote="好的，押金刚转过去了")), paid) == []
    assert BRIEF.decision_only("行，那就这么定") and BRIEF.decision_only("好的，就这样吧")
    assert not BRIEF.decision_only("好的，押金刚转过去了") and not BRIEF.decision_only("海报定稿了")


# ---- 4. screenshot summary kept apart ------------------------------------------------------------

def test_compose_text_is_the_transcription_and_drops_a_time_every_message_shares():
    reading = {"summary": "对方问周六的聚餐", "text": "", "messages": [
        {"sender": "许言", "is_self": False, "time": "9月24日 19:28", "text": "周六聚餐来吗"},
        {"sender": "我", "is_self": True, "time": "9月24日 19:28", "text": "来"}]}
    assert READING.compose("chat_screenshot", reading)["text"] == "许言：周六聚餐来吗\n我：来"
    reading["messages"][1]["time"] = "19:40"
    assert READING.compose("chat_screenshot", reading)["text"] == "[9月24日 19:28] 许言：周六聚餐来吗\n[19:40] 我：来"


def test_state_reading_has_the_summary_in_its_own_field(org, chat):
    shot = make_item(kind="image", image_b64=TINY_PNG_B64, app="微信")
    ingest(org, shot)
    org.drain()
    r = org.state(0)["readings"][shot["item_id"]]
    assert r["summary"] == "张三发来咖啡馆豆子报价"
    assert "张三发来" not in r["text"] and "张三：咖啡馆豆子报价每公斤120" in r["text"]
    # Matching still reads the summary with the transcription; the brief sees it only as a labelled field.
    item = org.store.get_item(shot["item_id"])
    assert org.match_body(item).startswith("张三发来咖啡馆豆子报价\n")
    view = org.brief_item_view(item)
    assert view["reading_summary"] == "张三发来咖啡馆豆子报价" and "张三发来" not in view["text"]


def test_a_quote_taken_from_the_summary_is_not_evidence(org, chat):
    chat.handlers["image-read"] = image_reader(chat_extraction(
        [{"sender": "店家", "is_self": False, "time": "", "text": "定金多少都行，您看着办"}], "我已经把定金付了"))
    shot = make_item(kind="image", image_b64=TINY_PNG_B64, app="微信")
    ingest(org, shot)
    org.drain()
    ev = event_of(org, shot["item_id"])
    before = org.store.get_event(ev)["status_line"]
    claimed = out("定金已付", fact("定金已付", "done", ["I1"], quote="我已经把定金付了"))
    chat.push("event-brief", claimed, claimed)
    org.brief(ev)
    card = org.store.get_event(ev)
    assert card["status_line"] == before and all(f["state"] != "done" for f in card["status_facts"])


def test_readings_stored_with_the_summary_inline_are_split_and_republished(tmp_path):
    db = tmp_path / "o.db"
    store = Store(db, key=TEST_KEY)
    store.insert_item({"item_id": "A", "revision": 1, "kind": "image", "source_app": {"name": "微信"},
                       "started_at": "2026-09-20T09:00:00+08:00", "sha256": "0" * 64}, b"\x89PNG....")
    store.save_derived("A", 1, derived_text="对方问聚餐\n[10:02] 许言：周六来吗", messages=[],
                       screenshot_run_id="run-old")
    store.lock()
    conn = raw_connect(db)                       # a database written before the summary column
    conn.execute("ALTER TABLE item_derived DROP COLUMN summary")
    conn.commit()
    old_cursor = int(conn.execute("SELECT value FROM meta WHERE key='seq'").fetchone()[0])
    conn.close()
    reopened = Store(db, key=TEST_KEY)
    rows = reopened.readings_since(old_cursor)
    assert [(r["summary"], r["derived_text"]) for r in rows] == [("对方问聚餐", "[10:02] 许言：周六来吗")]
    reopened.lock()
    assert Store(db, key=TEST_KEY).readings_since(old_cursor)[0]["summary"] == "对方问聚餐"   # split once, not again


# ---- metric --------------------------------------------------------------------------------------

def test_scorer_counts_dates_the_cited_items_do_not_give():
    sys.path.insert(0, str(REPO / "eval"))
    import score

    items = {"x": {"text": "电工老李下周过来换灯", "captured_at": AT},
             "y": {"text": "周会定在9月28日上午", "captured_at": AT}}
    e = {"status_line": "9月29日换灯，9月28日周会", "facts_raw": [
        {"text": "老李来换灯", "date": "2026-09-29", "item_ids": ["x"]},
        {"text": "周会", "date": "2026-09-28", "item_ids": ["y"]},
        {"text": "9月28日那周换灯", "date": "", "item_ids": ["x"]}]}
    got = score.ungrounded_card_dates(BRIEF, e, items)
    assert got == [("status_line", "9月29日换灯，9月28日周会 [9月29日]"), ("fact_date", "老李来换灯 [date 2026-09-29]")]
