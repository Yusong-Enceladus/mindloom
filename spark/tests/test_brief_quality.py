"""Regressions for event-brief: plans written as done, relative dates, the wall clock in prompts.

Validator cases R1-R6, resolver R7, organizer R8. Texts are invented paraphrases of the failure
patterns, not scenario items.
"""

import pytest

from conftest import REPO, event_of, ingest, make_item
from organizer.skills import SkillRegistry

REG = SkillRegistry(REPO / "skills")
VALIDATE = REG.skills["event-brief"].validator
DATES = REG.script("event-brief", "dates")


def ctx(**items):
    """items: handle -> (text, captured_at)."""
    return {"item_ids": list(items), "title_locked": False, "current_title": "",
            "items": {h: {"text": t, "captured_at": at} for h, (t, at) in items.items()}}


def out(line, *facts, title="屋顶防水"):
    return {"title": title, "status_facts": list(facts), "status_line": line, "off_anchor_item_ids": []}


def fact(text, state, ids, quote="", date=""):
    return {"text": text, "state": state, "date": date, "quote": quote, "item_ids": ids}


def cats(errors):
    return {e[1:e.index("]")] for e in errors if e.startswith("[")}


LEAK = ctx(I1=("周师傅：阿姨家看完了，防水层老化，得全部重做，2800包工包料，下周二开工，一天半完事。",
               "2026-09-19T12:30:00+08:00"))


def test_r1_plan_written_as_done_is_rejected():
    planned = fact("定于9月22日开工，约一天半", "planned", ["I1"], date="2026-09-22")
    errs = VALIDATE(out("防水重做工程已于9月22日按计划完成。", planned), LEAK)
    assert "unsupported_completion" in cats(errs)
    # "一天半完事" is a plan, and 9/22 is after the evidence was captured
    errs = VALIDATE(out("防水已重做完。", fact("防水重做已完成", "done", ["I1"], quote="一天半完事")), LEAK)
    assert "unsupported_completion" in cats(errs)
    ok = VALIDATE(out("周师傅已看完，9月22日开工重做。",
                      fact("师傅已上门查看，防水需重做", "done", ["I1"], quote="阿姨家看完了", date="2026-09-19"),
                      planned), LEAK)
    assert ok == []


def test_r2_signing_appointment_is_not_a_signing():
    c = ctx(I2=("陈柏舟：签三年的话月租1.2万可以，押金不变。25号上午来签合同吧。", "2026-09-17T08:20:00+08:00"))
    assert "unsupported_completion" in cats(VALIDATE(out("租约续签谈妥。", fact("25号已签合同", "done", ["I2"],
                                                                         quote="25号上午来签合同吧")), c))
    info = fact("续签三年月租1.2万", "info", ["I2"])
    assert "unsupported_completion" in cats(VALIDATE(out("租约已续签，月租1.2万。", info), c))
    assert VALIDATE(out("续签三年月租1.2万谈妥，定于9月25日上午签合同。", info,
                        fact("定于9月25日上午签合同", "planned", ["I2"], date="2026-09-25")), c) == []


def test_r3_conditional_plan_then_confirmation():
    c = ctx(I3=("周建国：许老板，水电今天下午验收，没问题的话明天开始贴砖。", "2026-09-18T12:05:00+08:00"),
            I4=("小满，店里今天开始贴砖了，你周一下午过来看看吧台高度。", "2026-09-19T14:00:00+08:00"))
    plan = fact("水电9月18日下午验收，通过后9月19日贴砖", "planned", ["I3"], date="2026-09-19")
    errs = VALIDATE(out("水电已验收，明日贴砖。", plan), c)
    assert {"unsupported_completion", "relative_date"} <= cats(errs)
    assert VALIDATE(out("水电定于9月18日下午验收，通过后9月19日开始贴砖。", plan), c) == []
    started = fact("9月19日开始贴砖", "in_progress", ["I4"], quote="店里今天开始贴砖了", date="2026-09-19")
    assert VALIDATE(out("9月19日已开始贴砖，吧台高度待看。", started), c) == []


@pytest.mark.parametrize("text,at,quote,fact_text", [
    ("磨豆机的钱退回来了，459块，下次买个好点的。", "2026-09-20T14:00:00+08:00", "钱退回来了", "459元已退回"),
    ("任务完成：新增 6 个单元测试，全部通过。", "2026-09-16T16:30:00+08:00", "全部通过", "单元测试已完成"),
    ("付款方式：定金30%已付，余款完工后结清。", "2026-09-17T10:00:00+08:00", "定金30%已付", "定金30%已付"),
    ("苏苏，海报定稿了！时间写下午一点到六点。", "2026-09-18T11:20:00+08:00", "海报定稿了", "市集海报已定稿"),
    ("门头招牌已经下单制作了，29号上午送到店里。", "2026-09-19T17:00:00+08:00", "门头招牌已经下单制作了", "招牌已下单"),
])
def test_r4_positive_controls_are_not_rejected(text, at, quote, fact_text):
    c = ctx(I5=(text, at))
    assert VALIDATE(out(f"{fact_text}。", fact(fact_text, "done", ["I5"], quote=quote)), c) == []


def test_r4_printed_today_delivered_tomorrow_splits_done_and_planned():
    c = ctx(I6=("市集海报30张A3今天印好了，明天送到店里。", "2026-09-20T21:00:00+08:00"))
    done = fact("30张A3海报已印好", "done", ["I6"], quote="今天印好了", date="2026-09-20")
    planned = fact("定于9月21日送到店里", "planned", ["I6"], date="2026-09-21")
    assert VALIDATE(out("30张A3海报已印好，定于9月21日送到店里。", done, planned), c) == []


def test_r5_mixed_state_in_one_fact_is_rejected():
    c = ctx(I7=("门头招牌已经下单制作了，29号上午送到店里，周师傅那边能配合安装吗？", "2026-09-19T17:00:00+08:00"))
    mixed = fact("招牌已下单并于29日上午送达安装", "done", ["I7"], quote="门头招牌已经下单制作了")
    assert "unsupported_completion" in cats(VALIDATE(out("招牌已下单。", mixed), c))
    split = [fact("招牌已下单", "done", ["I7"], quote="门头招牌已经下单制作了"),
             fact("定于9月29日上午送到店里", "planned", ["I7"], date="2026-09-29")]
    assert VALIDATE(out("招牌已下单，定于9月29日上午送到店里。", *split), c) == []


def test_planned_completion_dates_and_decisions_are_not_false_rejects():
    c = ctx(I9=("周建国：拆除、水电、墙面加吧台一共3.8万，工期12天，9月26号完工。", "2026-09-14T09:30:00+08:00"),
            I10=("高远：没问题，先签一个月试用合同。许：行，那就这么定。", "2026-09-17T16:00:00+08:00"))
    facts = [fact("报价3.8万，工期12天，9月26日完工", "info", ["I9"]),
             fact("定于9月26日完工", "planned", ["I9"], date="2026-09-26"),
             fact("同意先试用一个月", "done", ["I10"], quote="行，那就这么定")]
    assert VALIDATE(out("已同意3.8万报价并约定9月26日完工，先试用一个月。", *facts), c) == []
    # a request is not a completion
    req = fact("合同已发", "done", ["I10"], quote="先签一个月试用合同")
    assert "unsupported_completion" in cats(VALIDATE(out("试用合同已签。", req), c))


def test_r6_relative_words_must_become_absolute_dates():
    c = ctx(I8=("妈妈：念念，周师傅说明天上午十点来，我在家等他。", "2026-09-18T19:30:00+08:00"))
    f = fact("周师傅上门查看漏水", "planned", ["I8"], date="2026-09-19")
    assert "relative_date" in cats(VALIDATE(out("周师傅今天上午十点上门查看漏水情况。", f), c))
    assert "relative_date" in cats(VALIDATE(out("周师傅周六上午上门查看。", f), c))
    assert VALIDATE(out("周师傅9月19日（周六）上午十点上门查看。", f), c) == []


def test_r7_dates_resolve_against_the_items_own_capture_time():
    def one(text, at):
        return [d["date"] for d in DATES.resolve(text, at)]
    assert one("下周二开工，一天半完事", "2026-09-19T12:30:00+08:00") == ["2026-09-22"]
    assert one("明天开始贴砖", "2026-09-18T12:05:00+08:00") == ["2026-09-19"]
    assert one("周六上午我过去看看", "2026-09-15T09:10:00+08:00") == ["2026-09-19"]
    assert one("25号上午来签合同吧", "2026-09-17T08:20:00+08:00") == ["2026-09-25"]
    assert one("明天上午十点来", "2026-09-18T19:30:00+08:00") == ["2026-09-19"]
    assert one("市集就定9月27号周日下午，地址梧桐里17号", "2026-09-16T17:45:00+08:00") == ["2026-09-27"]
    assert one("两周年快到了，每周三例会", "2026-09-16T17:45:00+08:00") == []
    assert DATES.format_captured("2026-09-19T12:30:00+08:00") == "2026-09-19 周六 12:30"


def test_r8_brief_sees_item_time_not_the_wall_clock_and_retries_unsupported_completion(org, chat):
    it = make_item("周师傅：阿姨家看完了，防水层老化，得全部重做，2800包工包料，下周二开工，一天半完事。")
    it["started_at"] = "2026-09-19T12:30:00+08:00"
    it["ended_at"] = "2026-09-19T12:31:00+08:00"
    first = {"title": "妈妈家防水", "status_line": "防水重做工程已于9月22日按计划完成。", "off_anchor_item_ids": [],
             "status_facts": [{"text": "定于9月22日开工", "state": "planned", "date": "2026-09-22", "quote": "",
                               "item_ids": ["I1"]}]}
    second = dict(first, status_line="师傅已看完，9月22日开工重做。",
                  status_facts=first["status_facts"] + [
                      {"text": "师傅已上门查看", "state": "done", "date": "2026-09-19", "quote": "阿姨家看完了",
                       "item_ids": ["I1"]}])
    chat.push("event-brief", first, second)
    ingest(org, it)
    org.drain()
    data = [d for s, d, _, _ in chat.calls if s == "event-brief"][0]
    assert "now" not in data and "event_id" not in data["event"]
    assert data["as_of"] == "2026-09-19T12:31:00+08:00"
    assert data["items"][0]["captured_at"] == "2026-09-19 周六 12:30"
    assert {"said": "下周二", "date": "2026-09-22"} in data["items"][0]["dates"]
    ev = org.store.get_event(event_of(org, it["item_id"]))
    assert ev["status_line"].startswith("师傅已看完")
    assert ev["status_facts"][0]["item_ids"] == [it["item_id"]]  # handles map back to real ids
    run = org.store.one("SELECT attempts, as_of FROM runs WHERE job_type='brief'")
    assert run["attempts"] == 2 and run["as_of"] == "2026-09-19T12:31:00+08:00"


def test_r8_two_invalid_briefs_keep_the_bad_line_out_but_salvage_valid_parts(org, chat):
    it = make_item("25号上午来签合同吧")
    ingest(org, it)
    org.drain()
    ev = event_of(org, it["item_id"])
    before = org.store.get_event(ev)["status_line"]
    bad = {"title": "续签租约", "status_line": "租约已签。", "off_anchor_item_ids": [],
           "status_facts": [{"text": "约定签合同", "state": "planned", "date": "", "quote": "", "item_ids": ["I1"]},
                            {"text": "合同已签", "state": "done", "date": "", "quote": "来签合同吧", "item_ids": ["I1"]}]}
    chat.push("event-brief", bad, bad)
    org.brief(ev)
    card = org.store.get_event(ev)
    assert card["status_line"] == before                  # the unsupported "已签" line is never applied
    assert card["title"] == "续签租约"
    assert [f["text"] for f in card["status_facts"]] == ["约定签合同"]  # the uncited "done" fact is dropped
    prop = org.store.one("SELECT status, reason FROM proposals WHERE kind='brief' ORDER BY proposal_id DESC")
    assert prop["status"] == "partial" and "unsupported_completion" in prop["reason"]


def test_r8_unusable_output_twice_keeps_the_previous_card(org, chat):
    it = make_item("25号上午来签合同吧")
    ingest(org, it)
    org.drain()
    ev = event_of(org, it["item_id"])
    before = org.store.get_event(ev)
    chat.push("event-brief", "not json", {"title": "x" * 30})
    org.brief(ev)
    after = org.store.get_event(ev)
    assert (after["status_line"], after["title"]) == (before["status_line"], before["title"])
    prop = org.store.one("SELECT status FROM proposals WHERE kind='brief' ORDER BY proposal_id DESC")
    assert prop["status"] == "rejected"
