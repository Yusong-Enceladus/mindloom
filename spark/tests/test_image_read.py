"""image-read: type step, per-type extraction, validator/sanitize, the reading in /v1/state, per-type routing.

All data here is invented for tests.
"""

from __future__ import annotations

import json

import pytest

from conftest import REPO, TINY_PNG_B64, FakeChat, chat_extraction, image_reader, ingest, is_detect_step, make_item
from organizer.api import build_organizer
from organizer.config import Settings
from organizer.image_read import read_image
from organizer.skills import SkillRegistry
from organizer import jsonschema_lite

REG = SkillRegistry(REPO / "skills")
READING = REG.script("image-read", "reading")
VALIDATE = REG.script("image-read", "validate")

RECEIPT = {
    "doc_kind": "receipt", "merchant": "青松面包坊", "buyer": "", "date": "2026-03-07", "date_text": "2026-03-07 08:12",
    "time": "08:12", "doc_no": "NO.000731", "currency": "CNY",
    "items": [{"name": "全麦吐司", "qty": "1", "unit": "", "unit_price": "12.00", "amount": "12.00"},
              {"name": "豆浆", "qty": "2", "unit": "", "unit_price": "3.50", "amount": "7.00"}],
    "subtotal": "19.00", "discount": "", "tax": "", "total": "19.00", "payment_method": "支付宝", "total_in_words": "",
    "lines": ["青松面包坊", "单号 NO.000731", "2026-03-07 08:12", "全麦吐司 1 12.00 12.00", "豆浆 2 3.50 7.00",
              "小计 19.00", "合计 ¥19.00", "支付宝"],
    "gist": "青松面包坊早餐小票，合计 19.00 元，支付宝付款。",
}
LABEL = {
    "label_kind": "shipping_label",
    "fields": [{"key": "recipient", "label": "收件人", "value": "钱多多"},
               {"key": "recipient_phone", "label": "", "value": "139****0021"},
               {"key": "tracking_no", "label": "运单号", "value": "SF1234567890"}],
    "lines": ["运单号 SF1234567890", "收件人 钱多多 139****0021", "滨江区江南大道88号"],
    "gist": "寄给钱多多的快递，运单号 SF1234567890。",
}


def test_every_type_has_a_schema_the_detect_step_can_name():
    assert READING.TYPES == list(READING.TYPE_SCHEMAS)
    assert len(READING.TYPES) == 8 and READING.TYPES[-1] == "other"
    for schema in READING.TYPE_SCHEMAS.values():
        assert schema["additionalProperties"] is False and "gist" in schema["required"]
        assert schema["properties"]["gist"]["maxLength"] == 80


def test_the_skill_keeps_one_system_prompt_for_every_step():
    skill = REG.skills["image-read"]
    assert not skill.schema_in_prompt and "# OUTPUT JSON SCHEMA" not in skill.system_prompt
    assert skill.schema == READING.DETECT_SCHEMA


def test_a_clean_receipt_passes_and_composes_fields_numbers_and_text():
    assert jsonschema_lite.validate(RECEIPT, READING.schema_for("receipt_invoice")) == []
    assert VALIDATE.validate(RECEIPT, {"stage": "extract", "type": "receipt_invoice"}) == []
    r = READING.compose("receipt_invoice", RECEIPT)
    assert r["type"] == "receipt_invoice" and r["messages"] == []
    assert r["text"].splitlines()[0] == "青松面包坊" and r["gist"].startswith("青松面包坊")
    fields = {f["key"]: f["value"] for f in r["fields"]}
    assert fields["merchant"] == "青松面包坊" and fields["total"] == "19.00" and fields["date_iso"] == "2026-03-07"
    assert "buyer" not in fields and "tax" not in fields  # empty = not on the image, not published
    assert {"label": "合计", "value": "19.00"} in r["numbers"] and {"label": "豆浆", "value": "7.00"} in r["numbers"]


def test_receipt_values_missing_from_its_own_lines_are_rejected_and_sanitized():
    bad = json.loads(json.dumps(RECEIPT))
    bad["tax"] = "1.14"                        # not printed anywhere
    bad["payment_method"] = "现金"               # the lines say 支付宝
    bad["items"][1]["name"] = "豆浆大杯"
    bad["gist"] = "早餐 5 样，合计 19.00 元"      # 5 is not on the image
    errs = VALIDATE.validate(bad, {"stage": "extract", "type": "receipt_invoice"})
    assert any("tax" in e for e in errs) and any("payment_method" in e for e in errs)
    assert any("items[1]" in e for e in errs) and any("gist" in e and "5" in e for e in errs)
    clean, dropped = VALIDATE.sanitize("receipt_invoice", bad)
    # only the emptied gist is left: a gist with a made-up number is dropped, not rewritten
    assert VALIDATE.validate(clean, {"stage": "extract", "type": "receipt_invoice"}) == ["gist 为空：用一句话说这张图在讲什么事"]
    assert clean["tax"] == "" and clean["payment_method"] == "" and clean["gist"] == ""
    assert [i["name"] for i in clean["items"]] == ["全麦吐司"] and dropped == 4


def test_a_normalized_date_must_come_from_the_printed_one():
    ctx = {"stage": "extract", "type": "receipt_invoice"}
    assert any("date" in e for e in VALIDATE.validate(dict(RECEIPT, date="2026-03-08"), ctx))
    assert VALIDATE.validate(dict(RECEIPT, date_text="2026年3月7日", lines=RECEIPT["lines"] + ["2026年3月7日"]), ctx) == []
    no_year = dict(RECEIPT, date_text="03-07 08:12", lines=[x.replace("2026-", "") for x in RECEIPT["lines"]])
    assert any("date" in e for e in VALIDATE.validate(no_year, ctx))            # no year printed: date must be ""
    assert VALIDATE.validate(dict(no_year, date=""), ctx) == []


def test_label_fields_the_image_does_not_show_are_rejected():
    assert VALIDATE.validate(LABEL, {"stage": "extract", "type": "form_label_sign"}) == []
    bad = json.loads(json.dumps(LABEL))
    bad["fields"].append({"key": "sender_phone", "label": "寄件人电话", "value": "未知"})
    errs = VALIDATE.validate(bad, {"stage": "extract", "type": "form_label_sign"})
    assert any("占位词" in e for e in errs) and any("fields[3]" in e for e in errs)
    clean, _ = VALIDATE.sanitize("form_label_sign", bad)
    assert [f["key"] for f in clean["fields"]] == ["recipient", "recipient_phone", "tracking_no"]


def test_chat_rules_and_the_member_count_is_not_part_of_the_title():
    out = chat_extraction([{"sender": "孙工", "is_self": False, "time": "周三 14:10", "text": "阀门型号 DN25"},
                           {"sender": "孙工", "is_self": True, "time": "", "text": "收到"}], "孙工说阀门型号 DN25", "工地群(12)")
    errs = VALIDATE.validate(out, {"stage": "extract", "type": "chat_screenshot"})
    assert errs == ['messages[1] is_self=true 时 sender 写"我"（英文界面写"Me"）']
    clean, _ = VALIDATE.sanitize("chat_screenshot", out)
    r = READING.compose("chat_screenshot", clean)
    assert r["messages"][1]["sender"] == "我" and r["fields"] == [{"key": "chat_title", "label": "会话", "value": "工地群"}]
    assert r["text"] == "孙工：阀门型号 DN25\n我：收到"   # one time label for the whole chat: kept in messages only
    assert r["messages"][0]["time"] == "周三 14:10"


def test_struck_and_checked_lines_are_marked_in_the_text():
    out = {"surface": "whiteboard", "gist": "周会待办",
           "lines": [{"text": "周会待办", "struck": False, "checked": False, "is_title": True},
                     {"text": "更新报价单", "struck": False, "checked": True, "is_title": False},
                     {"text": "约供应商周二", "struck": True, "checked": False, "is_title": False}]}
    r = READING.compose("whiteboard_handwriting", out)
    assert r["lines"] == ["周会待办", "[✓] 更新报价单", "（已划掉）约供应商周二"]
    assert r["fields"] == [{"key": "title", "label": "标题", "value": "周会待办"}]


def test_chart_points_become_numbers_and_text():
    out = {"chart_type": "bar", "title": "门店月客流", "x_label": "", "y_label": "人次", "unit": "", "kpis": [],
           "series": [{"name": "", "trend": "rise_then_fall",
                       "points": [{"category": "1月", "value": "820"}, {"category": "2月", "value": "1,040"}]}],
           "gist": "门店月客流，2月最高 1,040 人次。"}
    assert VALIDATE.validate(out, {"stage": "extract", "type": "chart_dashboard"}) == []
    r = READING.compose("chart_dashboard", out)
    assert r["numbers"] == [{"label": "1月", "value": "820"}, {"label": "2月", "value": "1,040"}]
    assert "1月 820，2月 1,040" in r["text"]


def test_read_image_asks_the_type_then_extracts_with_that_types_schema(org, chat):
    chat.handlers["image-read"] = image_reader(RECEIPT, "receipt_invoice")
    res = read_image(org.harness, b"\x89PNG....", {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"})
    assert res.ok and res.detected and res.image_type == "receipt_invoice" and res.sanitized == 0
    detect, extract = [c for c in chat.calls if c[0] == "image-read"]
    assert is_detect_step(detect[2]) and extract[2] == READING.schema_for("receipt_invoice")
    assert extract[1]["type"] == "receipt_invoice"
    # same system prompt and the image first in both steps (a prefix cache reuses the image prefill)
    assert detect[3][0] == extract[3][0] and detect[3][1]["content"][0] == extract[3][1]["content"][0]
    assert "第二步" in extract[3][1]["content"][-1]["text"] and "第一步" in detect[3][1]["content"][-1]["text"]


def test_a_failed_type_step_reads_the_image_as_other(org, chat):
    other = {"lines": ["营业中"], "gist": "一块写着营业中的牌子"}
    chat.handlers["image-read"] = lambda d, s: {"type": "poster"} if is_detect_step(s) else other
    res = read_image(org.harness, b"\x89PNG....", {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"})
    assert res.image_type == "other" and not res.detected and res.reading["text"] == "营业中"


def test_an_extraction_that_fails_twice_is_kept_only_sanitized(org, chat):
    bad = dict(RECEIPT, tax="1.14")
    chat.handlers["image-read"] = image_reader(bad, "receipt_invoice")
    res = read_image(org.harness, b"\x89PNG....", {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"})
    assert res.ok and res.sanitized == 1 and res.output["tax"] == ""
    assert res.runs[-1].attempts == 2 and not res.runs[-1].ok


def test_state_reading_adds_type_fields_and_numbers_and_keeps_the_old_keys(org, chat):
    chat.handlers["image-read"] = image_reader(RECEIPT, "receipt_invoice")
    shot = make_item(kind="image", image_b64=TINY_PNG_B64, app="相册")
    ingest(org, shot)
    org.drain()
    r = org.state(0)["readings"][shot["item_id"]]
    assert set(r) == {"revision", "source", "type", "text", "summary", "messages", "fields", "numbers", "run_id"}
    assert r["source"] == "image-read" and r["type"] == "receipt_invoice" and r["messages"] == []
    assert r["summary"] == RECEIPT["gist"] and r["text"].startswith("青松面包坊\n单号")
    assert {"key": "total", "label": "合计", "value": "19.00"} in r["fields"]
    for f in r["fields"]:
        if f["key"] not in ("date_iso", "currency"):
            assert f["value"].replace(" ", "") in r["text"].replace(" ", "")
    item = org.store.get_item(shot["item_id"])
    assert org.match_body(item).startswith(RECEIPT["gist"] + "\n")   # gist + transcription, as before


def test_a_reading_stored_by_screenshot_read_is_published_with_a_type(org):
    org.store.insert_item({"item_id": "OLD", "revision": 1, "kind": "image", "source_app": {"name": "微信"},
                           "started_at": "2026-03-07T09:00:00+08:00", "sha256": "0" * 64}, b"\x89PNG....")
    org.store.save_derived("OLD", 1, derived_text="许言：周六来吗", summary="许言问周六",
                           messages=[{"sender": "许言", "is_self": False, "time": "", "text": "周六来吗"}],
                           screenshot_run_id="run-old")
    r = org.state(0)["readings"]["OLD"]
    assert r["source"] == "screenshot-read" and r["type"] == "chat_screenshot" and r["fields"] == []


def test_image_routes_send_a_type_to_its_own_endpoint(tmp_path, monkeypatch):
    import organizer.api as api

    made = []

    class Recording(FakeChat):
        def __init__(self, url="", model="auto", timeout=0.0):
            super().__init__()
            self.url = url
            made.append(self)

    monkeypatch.setattr(api, "OpenAIChatClient", Recording)
    routes = {"form_label_sign": {"url": "http://127.0.0.1:30000/v1", "model": "qwen-q8"}}
    settings = Settings(data_dir=tmp_path, start_worker=False, image_routes=json.dumps(routes))
    org = build_organizer(settings, embedder=None)
    label_client = org.image_clients["form_label_sign"]
    assert label_client.url == "http://127.0.0.1:30000/v1" and set(org.image_clients) == {"form_label_sign"}
    main = org.harness.client
    main.handlers["image-read"] = lambda d, s: {"type": "form_label_sign"}
    label_client.handlers["image-read"] = lambda d, s: LABEL
    res = read_image(org.harness, b"\x89PNG....", {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"},
                     clients=org.image_clients)
    assert res.ok and main.count("image-read") == 1 and label_client.count("image-read") == 1


@pytest.mark.parametrize("routes", [{"poster": {"url": "http://127.0.0.1:1/v1"}},
                                    {"slide": {"url": "http://10.0.0.5:8000/v1"}}])
def test_image_routes_reject_unknown_types_and_remote_urls(tmp_path, routes):
    with pytest.raises(ValueError):
        build_organizer(Settings(data_dir=tmp_path, start_worker=False, image_routes=json.dumps(routes)),
                        chat=FakeChat(), embedder=None)


def test_a_chart_trend_must_match_its_printed_points():
    series = {"name": "", "trend": "fall_then_rise",
              "points": [{"category": "Q1", "value": "30"}, {"category": "Q2", "value": "42"},
                         {"category": "Q3", "value": "30"}, {"category": "Q4", "value": "14"}]}
    out = {"chart_type": "line", "title": "t", "x_label": "", "y_label": "", "unit": "", "kpis": [],
           "series": [series], "gist": "季度走势"}
    ctx = {"stage": "extract", "type": "chart_dashboard"}
    assert any("rise_then_fall" in e for e in VALIDATE.validate(out, ctx))
    clean, dropped = VALIDATE.sanitize("chart_dashboard", out)
    assert clean["series"][0]["trend"] == "rise_then_fall" and dropped == 1
    series["trend"] = "none"                       # an unordered axis is never second-guessed
    assert VALIDATE.validate(out, ctx) == []


def test_an_english_month_counts_as_its_number():
    receipt = dict(RECEIPT, date="2026-03-07", date_text="Mar 7, 2026",
                   lines=RECEIPT["lines"] + ["Date: Mar 7, 2026"], gist="3 月 7 日在青松面包坊的早餐，合计 19.00 元。")
    assert VALIDATE.validate(receipt, {"stage": "extract", "type": "receipt_invoice"}) == []


def test_a_retried_run_keeps_the_first_attempts_errors(org, chat):
    chat.push("image-read", {"type": "receipt_invoice"}, dict(RECEIPT, tax="1.14"), RECEIPT)
    res = read_image(org.harness, b"\x89PNG....", {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"})
    assert res.ok and res.sanitized == 0 and res.runs[-1].attempts == 2
    assert any("tax" in e for e in res.runs[-1].attempt_errors[0])
