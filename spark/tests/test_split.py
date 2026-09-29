"""Contract A (transcripts) and B (item-split): invented names and topics only."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import event_of, ingest, make_item
from organizer import transcripts
from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.decisions import apply_decision
from organizer.organizer import segment_child_id

FIXTURES = Path(__file__).parent / "fixtures" / "transcript_formats.json"

MEETING = (
    "韩青禾(00:00:03):\n大家能听到吗？我先等一下。\n\n"
    "杜远舟 Yuanzhou DU(00:00:40):\n先说咖啡馆那边，咖啡馆的吧台下周二开始拆，预算控制在三万以内。\n\n"
    "韩青禾(00:02:10):\n好，咖啡馆吧台拆完以后记得拍照给我，我要看水电走线。\n\n"
    "杜远舟 Yuanzhou DU(00:03:30):\n第二件事是搬家，搬家公司报了两千八，周六上午九点到。\n\n"
    "韩青禾(00:04:50):\n搬家那天我不在，钥匙放物业，你帮我盯一下。\n\n"
    "杜远舟 Yuanzhou DU(00:06:05):\n最后是体检，体检中心说报告周四出来，出来我转给你。\n\n"
    "韩青禾(00:07:20):\n好的，谢谢大家，今天就到这。\n"
)


def _state(org):
    return org.state(0)


def _live(org):
    return [e for e in _state(org)["events"] if not e["deleted"]]


# ---- A: transcript formats ------------------------------------------------------------------------


@pytest.mark.parametrize("case", json.loads(FIXTURES.read_text(encoding="utf-8"))["cases"], ids=lambda c: c["name"])
def test_transcript_formats_shared_fixture(case):
    parsed = transcripts.parse(case["text"])
    if case["format"] is None:
        assert parsed is None
        return
    assert parsed["format"] == case["format"]
    # Exactly the Mac's turns, offsets included (MemoryTranscriptTextTests reads the same cases).
    assert parsed["turns"] == case["turns"]
    for turn in parsed["turns"]:
        span = case["text"][turn["start"]:turn["end"]]
        assert turn["text"].split("\n")[0] in span
        if case["format"] in ("tencent", "feishu"):
            assert span.startswith(turn["speaker"])  # turn-aligned: the span starts at the speaker line
        assert span == span.strip()


def test_transcript_speakers_become_people_and_owner_aliases_are_excluded(settings, chat):
    settings.owner_aliases = ("我", "韩青禾")
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    voice = {"person_id": "VOICE-DU", "display_name": "杜远舟"}
    ingest(org, make_item(text="杜远舟说咖啡馆的事", persons=[voice], kind="dictation"))
    text = "韩青禾(00:00:03):\n咖啡馆的事我们下周再说。\n\n杜远舟 Yuanzhou DU(00:00:40):\n好，咖啡馆我来跟。\n"
    ingest(org, make_item(text=text, minutes=5, kind="text", app="腾讯会议"))
    org.drain()
    people = {p["display_name"]: p for p in _state(org)["persons"]}
    assert "韩青禾" not in people  # the owner (an alias) never becomes a person
    assert people["杜远舟 Yuanzhou DU"]["origin"] == "transcript"
    qs = [q for q in _state(org)["questions"] if q["kind"] == "same_person"]
    assert qs and "会议记录里的「杜远舟 Yuanzhou DU」" in qs[0]["prompt_zh"]
    assert "声音里的「杜远舟」" in qs[0]["prompt_zh"]


def test_owner_alias_matches_either_part_of_a_bilingual_name(org):
    org.people.owner_norms |= {"barbaralin"}
    assert org.people.is_owner_name("石砚秋 Barbara LIN")
    assert not org.people.is_owner_name("石砚秋")


# ---- B: item-split ---------------------------------------------------------------------------------


def test_meeting_is_split_by_matter_and_each_segment_filed(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    ingest(org, item)
    org.drain()
    assert chat.count("item-split") == 1
    live = _live(org)
    assert len(live) == 3  # 咖啡馆, 搬家, 体检 — the greeting and the goodbye are in no segment
    for ev in live:
        assert ev["item_ids"] == [item["item_id"]]
        assert len(ev["segments"]) == 1
        seg = ev["segments"][0]
        assert seg["item_id"] == item["item_id"] and seg["seg_id"].startswith("s") and seg["gist"]
        span = MEETING[seg["start"]:seg["end"]]
        assert span.startswith("杜远舟 Yuanzhou DU(") or span.startswith("韩青禾(")  # turn-aligned
    spans = sorted((e["segments"][0]["start"], e["segments"][0]["end"]) for e in live)
    assert all(a[1] <= b[0] for a, b in zip(spans, spans[1:]))
    assert "大家能听到吗" not in "".join(MEETING[a:b] for a, b in spans)
    st = _state(org)
    assert st["unfiled"] == []  # the parent itself is neither filed nor unfiled
    assert org.store.count_items() == 1
    # no internal child id ever leaves the Spark
    children = {s["child_id"] for s in org.store.all("SELECT child_id FROM item_segments")}
    assert not children & set(json.dumps(st, ensure_ascii=False).split('"'))
    # the brief sees the segment text, not the whole meeting
    briefs = [c for c in chat.calls if c[0] == "event-brief"]
    assert all("体检" not in i["text"] for c in briefs for i in c[1]["items"] if "咖啡馆" in i["text"])


def test_short_items_skip_the_split_call(org, chat):
    ingest(org, make_item(text="咖啡馆吧台下周二开始拆。", kind="dictation"))
    org.drain()
    assert chat.count("item-split") == 0
    assert len(_live(org)) == 1


def test_single_matter_stays_whole(org, chat):
    text = "咖啡馆的事情：" + "咖啡馆吧台下周二开始拆，预算三万以内。" * 14
    item = make_item(text=text, kind="dictation")
    ingest(org, item)
    org.drain()
    assert chat.count("item-split") == 1
    live = _live(org)
    assert len(live) == 1 and live[0]["segments"] == [] and live[0]["item_ids"] == [item["item_id"]]
    assert event_of(org, item["item_id"]) == live[0]["event_id"]


def test_retry_of_the_same_revision_is_idempotent(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    ingest(org, item)
    org.drain()
    before = org.store.all("SELECT * FROM item_segments ORDER BY child_id")
    org.store.requeue_latest(item["item_id"], "retry")
    org.drain()
    assert chat.count("item-split") == 1  # the split is stored per revision
    assert org.store.all("SELECT * FROM item_segments ORDER BY child_id") == before
    assert len(_live(org)) == 3


def test_new_revision_resplits_and_refiles(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议", revision=1)
    ingest(org, item)
    org.drain()
    s3 = segment_child_id(item["item_id"], "s3")
    assert event_of(org, s3) is not None
    # revision 2 drops the 体检 part
    rev2 = dict(item, revision=2, text=MEETING.split("杜远舟 Yuanzhou DU(00:06:05)")[0], sha256="f" * 64)
    ingest(org, rev2)
    org.drain()
    assert chat.count("item-split") == 2
    assert not org.store.segment_of(s3)["active"] and event_of(org, s3) is None
    live = _live(org)
    assert sorted(len(e["segments"]) for e in live) == [1, 1]  # the 体检 event had only s3: retired
    assert all(e["segments"][0]["seg_id"] in ("s1", "s2") for e in live)
    # revision 3 is about one matter: the item is filed whole and its segments retired
    rev3 = dict(item, revision=3, text="咖啡馆吧台下周二开始拆，预算三万以内。" * 14, sha256="e" * 64)
    ingest(org, rev3)
    org.drain()
    assert org.store.segments_of(item["item_id"]) == []
    live = _live(org)
    assert [e["segments"] for e in live] == [[]]
    assert live[0]["item_ids"] == [item["item_id"]]


def test_user_placed_item_is_never_split(org, chat):
    other = make_item(text="咖啡馆的事", kind="dictation")
    ingest(org, other)
    org.drain()
    target = event_of(org, other["item_id"])
    item = make_item(text="咖啡馆吧台下周二开始拆，预算三万以内。" * 14, kind="dictation", minutes=10, revision=1)
    ingest(org, item)
    org.drain()
    assert apply_decision(org, {"kind": "move_item", "item_id": item["item_id"], "to_event_id": target})[0]
    ingest(org, dict(item, revision=2, text=MEETING, sha256="d" * 64))
    org.drain()
    assert org.store.segments_of(item["item_id"]) == []
    assert event_of(org, item["item_id"]) == target


def test_decisions_accept_seg_id(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    iid = item["item_id"]
    ingest(org, item)
    org.drain()
    s1, s2, s3 = (segment_child_id(iid, f"s{n}") for n in (1, 2, 3))
    e1, e2 = event_of(org, s1), event_of(org, s2)
    # move one segment into another event
    ok, _ = apply_decision(org, {"kind": "move_item", "item_id": iid, "seg_id": "s3", "to_event_id": e1})
    assert ok and event_of(org, s3) == e1
    ev1 = next(e for e in _state(org)["events"] if e["event_id"] == e1)
    assert ev1["item_ids"] == [iid] and [s["seg_id"] for s in ev1["segments"]] == ["s1", "s3"]
    # remove one segment from its event: the other segment stays
    ok, _ = apply_decision(org, {"kind": "remove_item", "event_id": e1, "item_id": iid, "seg_id": "s1"})
    assert ok and event_of(org, s1) != e1 and event_of(org, s3) == e1
    # unfile a segment: it shows up in the tray under the parent id with its seg_id
    ok, _ = apply_decision(org, {"kind": "unfile_item", "item_id": iid, "seg_id": "s2"})
    assert ok and event_of(org, s2) is None
    org.drain()
    tray = _state(org)["unfiled"]
    assert {"item_id": iid, "seg_id": "s2"}.items() <= next(u for u in tray if u.get("seg_id") == "s2").items()
    # an unknown segment is rejected, not applied to the whole item
    ok, why = apply_decision(org, {"kind": "unfile_item", "item_id": iid, "seg_id": "s9"})
    assert not ok and why == "unknown segment"
    # without seg_id, a decision on a split item acts on all its segments
    ok, _ = apply_decision(org, {"kind": "move_item", "item_id": iid, "to_event_id": e1})
    assert ok and {event_of(org, c) for c in (s1, s2, s3)} == {e1}
    # a segment filed as its own new event
    ok, _ = apply_decision(org, {"kind": "file_item_new_event", "item_id": iid, "seg_id": "s1"})
    assert ok and event_of(org, s1) not in (e1, e2)


def test_decision_digest_without_seg_id_is_unchanged(org):
    """A decision retried after the upgrade (no seg_id) matches the receipt it got before."""
    from organizer.schemas import DecisionsIn

    item = make_item(text="咖啡馆的事", kind="dictation")
    ingest(org, item)
    org.drain()
    raw = {"kind": "unfile_item", "item_id": item["item_id"], "decision_id": "d-1"}
    parsed = DecisionsIn.model_validate({"decisions": [raw]}).decisions[0].model_dump()
    assert parsed["seg_id"] is None
    assert apply_decision(org, parsed)[0]
    assert apply_decision(org, {k: v for k, v in parsed.items() if k != "seg_id"})[0]


def test_questions_about_a_segment_carry_the_parent_id_and_seg_id(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    ingest(org, item)
    org.drain()
    s2 = segment_child_id(item["item_id"], "s2")
    e1 = event_of(org, segment_child_id(item["item_id"], "s1"))
    org.store.create_question("same_event", s2, e1, "这段和那件事是同一件事吗？", 2, item_id=s2)
    q = _state(org)["questions"][0]
    assert q["a"] == item["item_id"] and q["a_seg_id"] == "s2" and q["b"] == e1


def test_split_output_that_stays_invalid_leaves_the_item_whole(org, chat):
    bad = {"matters": ["咖啡馆", "搬家"], "segments": [{"from": "U3", "to": "U2", "matter": 1, "gist": "x"}]}
    chat.push("item-split", bad, bad)
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    ingest(org, item)
    org.drain()
    assert org.store.segments_of(item["item_id"]) == []
    assert event_of(org, item["item_id"]) is not None


def test_split_units_and_validator():
    from organizer.skills import SkillRegistry
    from conftest import REPO

    reg = SkillRegistry(REPO / "skills")
    units_mod = reg.script("item-split", "units")
    validate = reg.skills["item-split"].validator
    tx = transcripts.parse(MEETING)
    units = units_mod.build_units(MEETING, tx["turns"])
    assert [u["u"] for u in units] == [f"U{n}" for n in range(1, 8)]
    ctx = {"unit_ids": [u["u"] for u in units]}
    good = {"matters": ["咖啡馆", "搬家"], "segments": [
        {"from": "U2", "to": "U3", "matter": 1, "gist": "吧台下周二拆"},
        {"from": "U4", "to": "U5", "matter": 2, "gist": "搬家周六九点"}]}
    assert validate(good, ctx) == []
    segs = units_mod.segments_from_output(good, units)
    assert [s["seg_id"] for s in segs] == ["s1", "s2"]
    assert MEETING[segs[0]["start"]:segs[0]["end"]].startswith("杜远舟")
    overlap = {"matters": ["a", "b"], "segments": [{"from": "U2", "to": "U4", "matter": 1, "gist": "x"},
                                                   {"from": "U4", "to": "U5", "matter": 2, "gist": "y"}]}
    assert any("overlaps" in e for e in validate(overlap, ctx))
    wide = {"matters": ["a"], "segments": [{"from": "U2", "to": "U4", "matter": 1, "gist": "字" * 21}]}
    assert any("wider" in e for e in validate(wide, ctx))
    # one matter (even as two adjacent ranges) -> not split
    one = {"matters": ["a"], "segments": [{"from": "U2", "to": "U3", "matter": 1, "gist": "x"},
                                          {"from": "U4", "to": "U5", "matter": 1, "gist": "y"}]}
    assert units_mod.segments_from_output(one, units) == []
    # a prose dictation is cut into sentences
    prose = "第一件事是咖啡馆。第二件事是搬家！第三件事，体检报告周四出来？好。"
    su = units_mod.build_units(prose)
    assert [prose[u["start"]:u["end"]] for u in su][:2] == ["第一件事是咖啡馆。", "第二件事是搬家！"]
    assert units_mod.prefilter(prose, len(su), "dictation") is False  # too short


def test_same_event_on_a_split_item_acts_on_its_segments(org, chat):
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    iid = item["item_id"]
    other = make_item(text="咖啡馆的事", kind="dictation", minutes=30)
    ingest(org, item, other)
    org.drain()
    target = event_of(org, other["item_id"])
    ok, _ = apply_decision(org, {"kind": "same_event", "a": iid, "b": target, "answer": True})
    assert ok
    assert {event_of(org, segment_child_id(iid, f"s{n}")) for n in (1, 2, 3)} == {target}
    assert event_of(org, iid) is None  # the parent itself is never filed while split


def test_over_long_gists_are_clipped_instead_of_losing_the_split(org, chat):
    long_gist = "咖啡馆吧台下周二开始拆，预算控制在三万以内，拍照给我看水电"
    out = {"matters": ["咖啡馆", "搬家"], "segments": [
        {"from": "U2", "to": "U3", "matter": 1, "gist": long_gist},
        {"from": "U4", "to": "U5", "matter": 2, "gist": "搬家周六九点"}]}
    chat.push("item-split", out, out)
    item = make_item(text=MEETING, kind="text", app="腾讯会议")
    ingest(org, item)
    org.drain()
    segs = org.store.segments_of(item["item_id"])
    assert [s["seg_id"] for s in segs] == ["s1", "s2"]
    assert segs[0]["gist"] == "咖啡馆吧台下周二开始拆"
