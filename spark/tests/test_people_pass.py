"""The people pass (organizer/people_pass.py, skill person-resolve) and the speaker rules it re-applies.

All data here is invented for tests.
"""

from __future__ import annotations

import importlib.util

import pytest

from conftest import REPO, event_of, ingest, make_item

from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.people_pass import RULES
from organizer.persons import canonical_form, chat_person_id, looks_like_person_name, speakers_in_text


def _script(name: str):
    path = REPO / "skills" / "person-resolve" / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"test_people_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


candidates = _script("candidates")
validate = _script("validate")


def verdict(kind: str = "person", same_as: str = "", common: bool = False) -> dict:
    return {"kind": kind, "same_as": same_as, "common_word": common, "reason": "测试理由"}


def chat_text(*lines: str) -> str:
    return "\n".join(f"[09-20 10:{n:02d}] {line}" for n, line in enumerate(lines))


def names_of(org, item_id: str, roles_out: tuple = ()) -> set[str]:
    return {org.people.label(p) for p in org.people.item_person_ids(item_id, exclude_roles=roles_out)}


# ---- speaker rules ------------------------------------------------------------------------------

def test_exported_chat_lines_with_a_timestamp_name_their_speakers():
    text = chat_text("郝一川：吧台尺寸你再量一次", "我：好，下午去", "纪明舒：海报我来")
    assert speakers_in_text(text) == ["郝一川", "我", "纪明舒"]
    assert speakers_in_text("[2026-09-20 10:01:05] 谭悦：收到\n[2026-09-20 10:02:00] 庞序：好") == ["谭悦", "庞序"]


def test_labels_code_keys_phrases_and_name_lists_are_not_speakers():
    assert speakers_in_text("终稿：10月8日\n报名须知：每组4人") == []                   # a heading ending / a label
    assert speakers_in_text("顺便说一句：周三改线上") == []                              # a phrase
    assert speakers_in_text("timeout: 30\nfontSize: 14\nretry_count: 3") == []           # code keys
    assert speakers_in_text("KeyError: 'id'\nTypeError: None") == []                    # exception types
    assert speakers_in_text("Fax: 010-1234\nEmail: a@b.example") == []                   # English field words
    assert speakers_in_text("抄送：谭悦；庞序\n郝一川：好的") == ["郝一川"]              # a list of names is not speech
    assert speakers_in_text("另：记得带伞") == []                                        # one character


def test_a_single_speaker_line_needs_a_name_shaped_speaker():
    assert speakers_in_text("郝工：明天九点到") == ["郝工"]                   # family name + title
    assert speakers_in_text("二姨：周末来吃饭") == []                        # not name-shaped on its own ...
    assert speakers_in_text("二姨：周末来吃饭\n我：好") == ["二姨", "我"]     # ... but a chat of two lines is a chat
    assert speakers_in_text("Mila: see you") == []                          # a lone Latin "name" is usually a label
    assert speakers_in_text("Mila: see you\nTom: ok") == ["Mila", "Tom"]
    assert looks_like_person_name("上官岚") and looks_like_person_name("老谭") and not looks_like_person_name("终稿")


def test_a_bilingual_transcript_name_is_kept_under_its_chinese_name(org):
    assert canonical_form("谭悦 Yue TAN") == "谭悦"
    assert canonical_form("Codex 助手") == "Codex 助手"          # not a name: kept as written
    assert canonical_form("王老师-数学") == "王老师-数学"        # a remark may tell two people apart
    pid = org.people.upsert_chat("谭悦 Yue TAN", "transcript")
    assert pid == chat_person_id("谭悦") and org.people.name(pid) == "谭悦"
    assert "谭悦 Yue TAN" in org.people.aliases(pid)
    assert org.people.upsert_chat("谭悦", "text") == pid


# ---- candidates.py ------------------------------------------------------------------------------

def test_name_relations_and_the_merge_guard():
    assert candidates.relation("谭悦", "谭悦 Yue TAN") == "bilingual"
    assert candidates.relation("Yue TAN", "谭悦") == "pinyin"
    assert candidates.relation("明舒", "纪明舒") == "nickname"
    assert candidates.relation("老纪", "纪明舒") == "nickname"
    assert candidates.relation("庞序（青禾）", "庞序") == "remark"
    assert candidates.relation("Leo", "梁嘉树") is None
    assert candidates.merge_allowed("周总", "周启航", ["周启航", "周嘉"]) == (False, "family_name_ambiguous")
    assert candidates.merge_allowed("周总", "周启航", ["周启航"])[0]
    assert candidates.merge_allowed("纪明舒", "纪同学", ["纪同学"]) == (True, "nickname")
    assert candidates.merge_allowed("谭悦", "谭悦明", []) == (False, "two_full_names")
    assert candidates.merge_allowed("Yue TAN", "谭悦", ["谭悦", "谭明"]) == (False, "pinyin_ambiguous")
    assert candidates.keep_rank("纪明舒") > candidates.keep_rank("纪同学") > candidates.keep_rank("Jimmy")
    assert candidates.relation("谭老师", "谭悦明") == candidates.relation("谭悦明", "谭老师") == "nickname"
    assert candidates.merge_allowed("谭老师", "谭悦明", ["谭总", "老谭"]) == (True, "nickname")    # other short forms: fine
    assert candidates.merge_allowed("老谭", "谭老师", ["谭悦明"]) == (False, "two_short_forms")
    assert candidates.full_name("悦悦") == "" and candidates.relation("悦悦", "谭悦") is None


def test_validator_only_accepts_an_offered_candidate():
    assert validate.validate(verdict(same_as="P2"), {"candidates": ["P2"]}) == []
    assert validate.validate(verdict(same_as="P3"), {"candidates": ["P2"]})
    assert validate.validate(verdict(kind="role", same_as="P2"), {"candidates": ["P2"]})


# ---- the pass -----------------------------------------------------------------------------------

def test_a_label_the_model_calls_not_a_person_loses_its_links_and_is_never_linked_again(org, chat):
    chat.handlers["person-resolve"] = lambda data, schema: verdict(
        "not_person" if data["person"]["name"] == "终稿" else "person", common=data["person"]["name"] == "终稿")
    text = chat_text("终稿：已清空", "郝一川：明天刷墙")
    item = make_item(text, kind="text", app="微信")
    ingest(org, item)
    org.drain()
    assert names_of(org, item["item_id"]) == {"郝一川"}
    pid = chat_person_id("终稿")
    assert org.people.status(pid) == "not_person"
    st = {p["person_id"]: p for p in org.state(0)["persons"]}
    assert st[pid]["status"] == "not_person"
    again = make_item(chat_text("终稿：再清一次", "郝一川：好"), kind="text", app="微信", minutes=5)
    ingest(org, again)
    org.drain()
    assert "终稿" not in names_of(org, again["item_id"])


def test_a_role_is_kept_but_never_searched_for(org, chat):
    chat.handlers["person-resolve"] = lambda data, schema: verdict(
        "role" if data["person"]["name"] == "前台" else "person", common=data["person"]["name"] == "前台")
    ingest(org, make_item(chat_text("前台：明天停水", "郝一川：收到"), kind="text", app="微信"))
    org.drain()
    later = make_item("记得问前台停水到几点", minutes=10)
    ingest(org, later)
    org.drain()
    assert org.people.status(chat_person_id("前台")) == "role"
    assert "前台" not in names_of(org, later["item_id"])


def test_a_pinyin_name_joins_its_chinese_name_and_the_chinese_name_is_kept(org, chat):
    def judge(data, schema):
        if data["person"]["name"] == "Yue TAN":
            match = [c["handle"] for c in data["candidates"] if c["name"] == "谭悦"]
            return verdict(same_as=match[0] if match else "")
        return verdict()
    chat.handlers["person-resolve"] = judge
    ingest(org, make_item(chat_text("谭悦：报价我改好了", "我：好"), kind="text", app="微信"))
    ingest(org, make_item(chat_text("Yue TAN: sent the quote", "Mila: thanks"), kind="text", app="Slack", minutes=5))
    org.drain()
    keep = chat_person_id("谭悦")
    assert org.people.canonical(chat_person_id("Yue TAN")) == keep
    assert org.people.name(keep) == "谭悦" and "Yue TAN" in org.people.aliases(keep)
    check = org.store.one("SELECT outcome FROM person_checks WHERE person_id=?", (chat_person_id("Yue TAN"),))
    assert check["outcome"] == "merged_pinyin"


def test_a_short_form_that_fits_two_people_is_not_merged(org, chat):
    def judge(data, schema):
        if data["person"]["name"] == "周总":
            return verdict(same_as=data["candidates"][0]["handle"])  # the model guesses anyway
        return verdict()
    chat.handlers["person-resolve"] = judge
    ingest(org, make_item(chat_text("周启航：合同看过了", "我：好"), kind="text", app="微信"))
    ingest(org, make_item(chat_text("周嘉：样品明天寄", "我：好"), kind="text", app="微信", minutes=2))
    ingest(org, make_item(chat_text("周总：方案发我", "我：好"), kind="text", app="微信", minutes=4))
    org.drain()
    zong = chat_person_id("周总")
    assert org.people.canonical(zong) == zong
    check = org.store.one("SELECT outcome FROM person_checks WHERE person_id=?", (zong,))
    assert check["outcome"].endswith("family_name_ambiguous")


def test_two_people_speaking_in_one_item_are_never_merged(org, chat):
    def judge(data, schema):
        if data["person"]["name"] == "明舒":
            return verdict(same_as=data["candidates"][0]["handle"] if data["candidates"] else "")
        return verdict()
    chat.handlers["person-resolve"] = judge
    ingest(org, make_item(chat_text("纪明舒：嘉宾名单好了", "明舒：我再核一遍"), kind="text", app="微信"))
    org.drain()
    assert org.people.canonical(chat_person_id("明舒")) == chat_person_id("明舒")


def test_a_voice_person_gets_a_question_not_a_silent_merge(org, chat):
    def judge(data, schema):
        if data["person"]["name"] == "老纪":
            return verdict(same_as=data["candidates"][0]["handle"] if data["candidates"] else "")
        return verdict()
    chat.handlers["person-resolve"] = judge
    voice = {"person_id": "VOICE-JI", "display_name": "纪明舒"}
    ingest(org, make_item("海报定稿了", persons=[voice], segments=[{"start_ms": 0, "end_ms": 900, "person_id": "VOICE-JI", "text": "海报定稿了"}]))
    ingest(org, make_item(chat_text("老纪：海报发群里了", "我：好"), kind="text", app="微信", minutes=3))
    org.drain()
    assert org.people.canonical(chat_person_id("老纪")) == chat_person_id("老纪")
    assert any(q["kind"] == "same_person" for q in org.state(0)["questions"])


def test_people_named_in_a_text_are_linked_as_mentions_but_never_used_for_matching(org, chat):
    chat.handlers["person-resolve"] = lambda data, schema: verdict(common=data["person"]["name"] == "向阳")
    ingest(org, make_item(chat_text("郝一川：吧台尺寸量好了", "向阳：遮阳棚借到了", "我：好"), kind="text", app="微信"))
    org.drain()
    note = make_item("咖啡馆的吧台让郝一川周四来装，向阳说押金另付", minutes=20)
    ingest(org, note)
    org.drain()
    hao = chat_person_id("郝一川")
    assert org.people.item_person_ids(note["item_id"]) == [hao]           # 向阳 is also an ordinary word: not searched
    row = org.store.one("SELECT role FROM item_persons WHERE item_id=? AND person_id=?", (note["item_id"], hao))
    assert row["role"] == "mention"
    assert org.other_persons(note["item_id"]) == [] and org.other_persons(note["item_id"], for_matching=True) == []
    ev = event_of(org, note["item_id"])
    event = next(e for e in org.state(0)["events"] if e["event_id"] == ev)
    assert hao in event["person_ids"]


def test_the_owner_is_never_a_mention(settings, chat):
    settings.owner_aliases = ("我", "许念")
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(org, make_item(chat_text("许念：我来订场地", "郝一川：好"), kind="text", app="微信"))
    org.drain()
    note = make_item("许念和郝一川周四去看场地", minutes=5)
    ingest(org, note)
    org.drain()
    assert names_of(org, note["item_id"]) == {"郝一川"}


def test_a_store_read_with_older_rules_is_cleaned_on_the_next_pass(org, chat):
    item = make_item(chat_text("郝一川：明天刷墙", "我：好"), kind="text", app="微信")
    ingest(org, item)
    org.drain()
    # Simulate an older organizer: a code key read as a speaker, and every item read with older rules.
    pid = org.people.upsert_chat("timeout", "text")
    org.people.add_item_person(item["item_id"], pid, "text_speaker")
    org.store.x("UPDATE person_scan SET rules='speakers-1'")
    assert "timeout" in names_of(org, item["item_id"])
    before = org.state(0)["cursor"]
    org.drain()
    assert names_of(org, item["item_id"]) == {"郝一川"}
    assert org.people.status(pid) == "not_person"
    assert org.store.one("SELECT outcome FROM person_checks WHERE person_id=?", (pid,))["outcome"] == "rule_unread"
    assert org.store.one("SELECT COUNT(*) AS n FROM person_scan WHERE rules != ?", (RULES,))["n"] == 0
    assert [e for e in org.state(before)["events"] if e["event_id"] == event_of(org, item["item_id"])]


def test_the_pass_reports_counts_and_can_be_turned_off(settings, chat, client):
    h = client.get("/v1/health").json()
    assert h["people"]["enabled"] is True and "not_person" in h["people"]
    settings.people_pass = False
    off = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(off, make_item(chat_text("郝一川：明天刷墙", "我：好"), kind="text", app="微信"))
    off.drain()
    assert chat.count("person-resolve") == 0 and not off.people_pass.enabled


def test_the_model_sees_where_else_the_name_appears(org, chat):
    seen = {}
    def judge(data, schema):
        seen[data["person"]["name"]] = data["person"].get("elsewhere")
        return verdict(common=data["person"]["name"] == "江山")
    chat.handlers["person-resolve"] = judge
    ingest(org, make_item("纪录片讲的是一个人守了三十年的江山", minutes=1))
    ingest(org, make_item(chat_text("江山：遮阳棚借到了", "郝一川：好"), kind="text", app="微信", minutes=5))
    org.drain()
    assert seen["江山"] == ["纪录片讲的是一个人守了三十年的江山"] and seen["郝一川"] == []
    later = make_item("江山说押金另付", minutes=9)
    ingest(org, later)
    org.drain()
    assert org.people.item_person_ids(later["item_id"]) == []   # judged an ordinary word: never searched


def test_an_events_people_are_listed_most_involved_first(org, chat):
    ingest(org, make_item(chat_text("郝一川：咖啡馆吧台量好了", "我：好"), kind="text", app="微信"))
    ingest(org, make_item(chat_text("纪明舒：咖啡馆海报发群里了", "我：好"), kind="text", app="微信", minutes=2))
    org.drain()
    ingest(org, make_item(chat_text("郝一川：咖啡馆电工周四进场", "我：收到"), kind="text", app="微信", minutes=4))
    ingest(org, make_item("咖啡馆的事纪明舒和郝一川都知道了", minutes=6))
    org.drain()
    ev = event_of(org, [i for i in org.store.all("SELECT item_id FROM items")][0]["item_id"])
    event = next(e for e in org.state(0)["events"] if e["event_id"] == ev)
    assert event["person_ids"][:2] == [chat_person_id("郝一川"), chat_person_id("纪明舒")]


def test_an_item_still_waiting_for_its_job_is_left_to_it(org, chat):
    done = make_item(chat_text("郝一川：明天刷墙", "我：好"), kind="text", app="微信")
    ingest(org, done)
    org.drain()
    waiting = make_item(chat_text("纪明舒：海报发群里了", "我：好"), kind="text", app="微信", minutes=5)
    ingest(org, waiting)                         # queued, not processed yet
    org.store.x("UPDATE person_scan SET rules='speakers-1'")
    org.people_pass.run()
    assert org.store.one("SELECT 1 FROM person_scan WHERE item_id=?", (waiting["item_id"],)) is None
    assert org.people.item_person_ids(waiting["item_id"]) == []
    assert org.store.one("SELECT rules FROM person_scan WHERE item_id=?", (done["item_id"],))["rules"] == RULES
    org.drain()
    assert names_of(org, waiting["item_id"]) == {"纪明舒"}
