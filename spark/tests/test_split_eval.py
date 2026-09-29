"""Scorer: optional segment-level truth (segment Link F1), and the eval driver's stream/workers mode."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from conftest import FakeChat, REPO

sys.path.insert(0, str(REPO / "eval"))
sys.path.insert(0, str(REPO / "eval" / "tools"))

import score as scorer  # noqa: E402

TEXT = "关于咖啡馆：吧台下周二拆。另外搬家公司周六上午九点准时到楼下。"
SCEN = {
    "scenario_id": "seg-mini", "synthetic": True, "owner_person_id": "p_o",
    "people": [{"person_id": "p_o", "display_name": "某人", "is_owner": True}],
    "events": [{"event_id": "ev_a", "kind": "main"}, {"event_id": "ev_b", "kind": "main"}],
    "items": [
        {"item_id": "11111111-1111-4111-8111-111111111111", "t": "2026-08-01T09:00:00+08:00", "kind": "text",
         "source_app": "微信", "persons": [], "events": ["ev_a", "ev_b"], "text": TEXT,
         "segments": [{"event_id": "ev_a", "quote": "关于咖啡馆：吧台下周二拆。"},
                      {"event_id": "ev_b", "quote": "另外搬家公司周六上午九点准时到楼下。"}]},
        {"item_id": "22222222-2222-4222-8222-222222222222", "t": "2026-08-01T10:00:00+08:00", "kind": "text",
         "source_app": "微信", "persons": [], "events": ["ev_a"], "text": "咖啡馆预算三万"},
    ],
    "facts": [], "checkpoints": [{"checkpoint_id": "cp", "after_item_id": "22222222-2222-4222-8222-222222222222",
                                  "expected": {}}],
}
I1, I2 = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
CUT = TEXT.index("另外")


def _score(events):
    return scorer.score(SCEN, {"cp": {"events": events}})["summary"]


def test_scenario_with_gold_segments_validates():
    assert scorer.validate_scenario(SCEN)[0] == []
    bad = json.loads(json.dumps(SCEN))
    bad["items"][0]["segments"][0]["quote"] = "不在原文里"
    assert any("quote not found" in e for e in scorer.validate_scenario(bad)[0])


def test_segment_link_f1_rewards_the_right_cut():
    split = [{"event_id": "A", "item_ids": [I1, I2], "segments": [{"item_id": I1, "seg_id": "s1", "start": 0, "end": CUT}]},
             {"event_id": "B", "item_ids": [I1], "segments": [{"item_id": I1, "seg_id": "s2", "start": CUT,
                                                              "end": len(TEXT)}]}]
    s = _score(split)
    assert s["segment_link_f1"] == 1.0 and s["split_items_pred"] == 1 and s["split_items_gold"] == 1
    whole = [{"event_id": "A", "item_ids": [I1, I2], "segments": []}]
    s = _score(whole)  # the whole item filed into A is half about B: that unit is wrong
    assert s["segment_link_precision"] == 0.5 and s["segment_link_recall"] == 2 / 3
    pieces = [{"event_id": "A", "item_ids": [I1, I2], "segments": [
                  {"item_id": I1, "seg_id": "s1", "start": 0, "end": 6},
                  {"item_id": I1, "seg_id": "s2", "start": 6, "end": CUT}]},
              {"event_id": "B", "item_ids": [I1], "segments": [{"item_id": I1, "seg_id": "s3", "start": CUT,
                                                               "end": len(TEXT)}]}]
    assert _score(pieces)["segment_link_f1"] == 1.0  # a part cut in two, both pieces in the right event
    wrong_cut = [{"event_id": "A", "item_ids": [I1, I2], "segments": [{"item_id": I1, "seg_id": "s1", "start": 0,
                                                                     "end": len(TEXT) - 2}]},
                 {"event_id": "B", "item_ids": [I1], "segments": [{"item_id": I1, "seg_id": "s2",
                                                                  "start": len(TEXT) - 2, "end": len(TEXT)}]}]
    s = _score(wrong_cut)
    assert s["segment_link_f1"] < 1.0 and s["segment_link_recall"] == 2 / 3
    # item-level metrics are unchanged by segments
    assert _score(split)["link_f1"] == 1.0


def test_scenarios_without_segment_truth_report_none():
    dev = json.loads((REPO / "eval" / "scenarios" / "dev-week-v1" / "scenario.json").read_text(encoding="utf-8"))
    assert scorer.Gold(dev).item_segments == {}


def test_run_eval_stream_mode_with_workers_on_split_dev(tmp_path, monkeypatch):
    import run_eval

    monkeypatch.setattr(run_eval, "OpenAIChatClient", lambda *a, **k: FakeChat())
    out = tmp_path / "run"
    scen = REPO / "eval" / "scenarios" / "split-dev" / "scenario.json"
    assert run_eval.main(["--scenario", str(scen), "--condition", "skills", "--embed", "hash", "--out", str(out),
                          "--stream", "--workers", "3", "--owner-aliases", "scenario"]) == 0
    stats = json.loads((out / "stats.json").read_text(encoding="utf-8"))
    assert stats["workers"] == 3 and stats["stream"] and stats["items_per_min"] > 0
    assert stats["split"]["calls"] >= 30  # the pre-filter sends the long multi-matter items to item-split
    meta = json.loads((out / "meta.json").read_text(encoding="utf-8"))
    assert "沈棠" in meta["owner_aliases"]
    summary = json.loads((out / "score.json").read_text(encoding="utf-8"))["summary"]
    assert summary["segment_link_f1"] is not None and summary["split_items_gold"] >= 35
    snap = json.loads((out / "snapshots" / "cp-w2.json").read_text(encoding="utf-8"))
    assert not any(p["display_name"] == "沈棠" for p in snap["persons"])  # the owner is never a person
