"""Placeholders a model breaks are repaired on the Spark before its output is validated or stored.

The masking evaluation (2026-09-30) saw item-split write the gist "邮箱验证码3feb18" for a segment that held
〔验证码·3feb18〕: the brackets and the dot were gone, so the Mac could not restore the code and would show a
code-like string. Every skill output now goes through masking.repair_placeholders against that call's input.
All data here is invented.
"""

from __future__ import annotations

import re

from conftest import default_split, make_item, ingest
from organizer import masking

KEY = bytes([0x11]) * 32
CODE = masking.placeholder(KEY, "otp", "482913")          # 〔验证码·xxxxxx〕
PHONE = masking.placeholder(KEY, "phone", "13812345678")  # 〔手机号·xxxxxx〕
TAG = CODE[-7:-1]
PTAG = PHONE[-7:-1]
REFERENCE = f"订阅确认：验证码 {CODE}；新号 {PHONE}"


def fix(text: str, reference: str = REFERENCE) -> str:
    return masking.repair_placeholders({"gist": text}, reference)[0]["gist"]


def test_the_broken_forms_seen_and_their_neighbours_are_rewritten_to_the_input_placeholder():
    assert fix(f"邮箱验证码{TAG}") == f"邮箱{CODE}"                   # the case the evaluation found
    assert fix(f"验证码：{TAG}") == CODE
    assert fix(f"验证码·{TAG}〕") == CODE
    assert fix(f"〔{TAG}〕") == CODE
    assert fix(f"〔·{TAG}〕") == CODE
    assert fix(f"订阅码是 {TAG.upper()}") == f"订阅码是 {CODE}"      # upper-cased tag; the text around it stays
    assert fix(f"号码是:{TAG}") == f"号码是:{CODE}"                  # a colon that is not part of the placeholder
    assert fix(f"（验证码·{TAG}）") == f"（{CODE}）"                 # other brackets are kept
    assert fix(f"新手机号{PTAG}，旧号停机") == f"新{PHONE}，旧号停机"
    assert fix(f"〔手机号·{TAG}〕") == CODE                          # the right tag under a wrong label
    assert masking.repair_placeholders({"a": f"验证码{TAG}", "b": [f"{PTAG} 和 {TAG}"]}, REFERENCE) == (
        {"a": CODE, "b": [f"{PHONE} 和 {CODE}"]}, 3)


def test_nothing_else_is_touched():
    for text in (f"{CODE} 原样回来", f"新号{PHONE}", "〔验证码〕", "一段没有占位符的话", f"x{TAG}y", f"{TAG}c2",
                 "ab12cd 不是输入里的编号", "〔验证码·ab12cd〕 编号不认识也不改"):
        assert fix(text) == text, text
    # ids and other structural fields stay as they are
    out, n = masking.repair_placeholders({"item_id": TAG, "event_id": TAG, "gist": "ok"}, REFERENCE)
    assert out == {"item_id": TAG, "event_id": TAG, "gist": "ok"} and n == 0
    # nothing is repaired when the input held no placeholder: a tag is never invented
    assert masking.repair_placeholders({"gist": f"验证码{TAG}"}, "没有占位符的输入")[0] == {"gist": f"验证码{TAG}"}


def test_a_tag_two_input_placeholders_share_is_repaired_only_when_its_label_says_which():
    other = f"〔手机号·{TAG}〕"  # a 24-bit tag collision between two values of different types
    reference = f"{CODE} {other}"
    assert fix(f"验证码{TAG}", reference) == CODE
    assert fix(f"手机号{TAG}", reference) == other
    assert fix(f"编号 {TAG}", reference) == f"编号 {TAG}"


def test_the_organizer_stores_the_repaired_gist(org, chat):
    """item-split breaks the placeholder in a gist: the stored segment (what /v1/state serves) has it whole."""
    def split_breaking_the_code(data, schema):
        out = default_split(data, schema)
        tag = re.search(r"〔验证码·([0-9a-f]{6})〕", "".join(u["text"] for u in data["units"])).group(1)
        for seg in out["segments"]:
            if out["matters"][seg["matter"] - 1] == "搬家":
                seg["gist"] = f"搬家公司验证码{tag}"
        return out

    chat.handlers["item-split"] = split_breaking_the_code
    text = ("咖啡馆的事情：" + "咖啡馆吧台下周二开始拆，预算三万以内。" * 8
            + "搬家那边：搬家公司发来的验证码是 482913，周六上午九点到。" + "搬家要提前把书打包好。" * 6)
    item = make_item(text=text, kind="dictation")
    ingest(org, item)
    org.drain()
    assert chat.count("item-split") == 1  # accepted at once: nothing to retry
    code = org.store.mask_text("验证码 482913").split(" ", 1)[1]
    gists = [s["gist"] for s in org.store.all("SELECT gist FROM item_segments WHERE active = 1")]
    assert f"搬家公司{code}" in gists
    served = [seg["gist"] for e in org.state(0)["events"] for seg in e.get("segments") or []]
    assert f"搬家公司{code}" in served and not any(re.search(r"验证码[0-9a-f]{6}", g) for g in served)
    run = org.store.one("SELECT output FROM runs WHERE job_type='split' ORDER BY started_at DESC LIMIT 1")
    assert f"搬家公司{code}" in run["output"]
