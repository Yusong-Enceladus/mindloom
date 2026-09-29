"""Both eval drivers on a 3-item synthetic mini scenario with the fake model (R9, S3, S4, snapshot parity)."""

import json
import sys
from argparse import Namespace

import pytest

from conftest import REPO, FakeChat

sys.path.insert(0, str(REPO / "eval"))
sys.path.insert(0, str(REPO / "eval" / "tools"))

OWNER_VOICE = "11111111-1111-4111-8111-111111111111"
MINI = {
    "scenario_id": "mini-v1", "version": 1, "split": "fixture", "synthetic": True, "owner_person_id": "p_owner",
    "people": [{"person_id": "p_owner", "display_name": "测试者", "is_owner": True,
                "voice": {"mac_person_id": OWNER_VOICE, "user_label": "我"}},
               {"person_id": "p_li", "display_name": "李木", "voice": None}],
    "events": [{"event_id": "ev_cafe", "kind": "main", "title": "咖啡馆菜单"},
               {"event_id": "ev_noise", "kind": "noise"}],
    "items": [
        {"item_id": "AAAAAAAA-0000-4000-8000-000000000001", "ref": "m-1", "t": "2026-08-01T09:00:00+08:00",
         "kind": "dictation", "source_app": "微信", "persons": ["p_owner"], "events": ["ev_cafe"],
         "text": "咖啡馆菜单下周二定稿"},
        {"item_id": "AAAAAAAA-0000-4000-8000-000000000002", "ref": "m-2", "t": "2026-08-01T10:00:00+08:00",
         "kind": "text", "source_app": "微信", "persons": ["p_li"], "events": ["ev_cafe"],
         "text": "李木：咖啡馆菜单初稿发你了"},
        {"item_id": "AAAAAAAA-0000-4000-8000-000000000003", "ref": "m-3", "t": "2026-08-01T11:00:00+08:00",
         "kind": "text", "source_app": "微信", "persons": [], "events": [], "text": "今天好热"},
    ],
    "facts": [{"fact_id": "f_menu", "event_id": "ev_cafe", "text": "菜单8月4日定稿", "keys": ["定稿"],
               "valid_from": "AAAAAAAA-0000-4000-8000-000000000001", "state": "planned", "date": "2026-08-04"}],
    "checkpoints": [{"checkpoint_id": "cp-final", "after_item_id": "AAAAAAAA-0000-4000-8000-000000000003",
                     "expected": {"ev_cafe": ["f_menu"]}, "home": {"grades": {"ev_cafe": 2}}}],
}


@pytest.fixture
def mini(tmp_path):
    path = tmp_path / "scenario.json"
    path.write_text(json.dumps(MINI, ensure_ascii=False), encoding="utf-8")
    return path


def _times(chats):
    brief = [d for c in chats for s, d, _, _ in c.calls if s == "event-brief"]
    rank = [d for c in chats for s, d, _, _ in c.calls if s == "home-rank"]
    return brief, rank


def test_run_eval_replays_scenario_time_and_writes_audit_fields(mini, tmp_path, monkeypatch):
    import run_eval

    chats = []
    monkeypatch.setattr(run_eval, "OpenAIChatClient", lambda *a, **k: chats.append(FakeChat()) or chats[-1])
    out = tmp_path / "run"
    assert run_eval.main(["--scenario", str(mini), "--condition", "skills", "--embed", "none", "--out", str(out),
                          "--rank-gold"]) == 0
    brief, rank = _times(chats)
    assert brief and all(d["as_of"].startswith("2026-08-01") and "now" not in d for d in brief)
    assert rank and all(d["now"].startswith("2026-08-01") for d in rank)
    meta = json.loads((out / "meta.json").read_text(encoding="utf-8"))
    assert meta["clock"] == "replay" and meta["handles"]
    rows = [json.loads(line) for line in (out / "runs.jsonl").read_text(encoding="utf-8").splitlines()]
    assert all(r["input_text"] for r in rows)
    assert all((r["as_of"] or "").startswith("2026-08-01") for r in rows if r["job_type"] in ("brief", "rank"))
    snap = json.loads((out / "snapshots" / "cp-final.json").read_text(encoding="utf-8"))
    assert {"item_persons", "questions", "questions_asked_total", "assign_log", "unfiled"} <= set(snap)
    stats = json.loads((out / "stats.json").read_text(encoding="utf-8"))
    assert stats["rank_gold"]["cp-final"]["ok"]
    score = json.loads((out / "score.json").read_text(encoding="utf-8"))
    assert score["summary"]["home_rank_ran"] == "1/1"


def test_without_skills_keeps_schema_validator_and_budget(mini, tmp_path, monkeypatch):
    """The ablation removes SKILL.md and references/ text only: same schema, validator path and budget."""
    import re

    import run_eval
    from organizer.skills import load_skill

    budgets = {d.name: load_skill(d).max_tokens for d in (REPO / "skills").iterdir() if (d / "SKILL.md").exists()}
    seen = []

    class TaskChat(FakeChat):
        def complete(self, messages, schema, schema_name, max_tokens):
            system = messages[0]["content"]
            name = re.search(r"\nTask: ([a-z-]+)\n", system).group(1)
            assert "# SKILL:" not in system and "# REFERENCE:" not in system
            seen.append((name, schema is not None, max_tokens))
            messages = [dict(messages[0], content=f"# SKILL: {name} v0\n")] + messages[1:]
            return super().complete(messages, schema, schema_name, max_tokens)

    monkeypatch.setattr(run_eval, "OpenAIChatClient", lambda *a, **k: TaskChat())
    out = tmp_path / "noskill"
    assert run_eval.main(["--scenario", str(mini), "--condition", "without-skills", "--embed", "none",
                          "--out", str(out)]) == 0
    assert {n for n, _, _ in seen} >= {"event-assign", "event-brief", "home-rank"}
    assert all(has_schema and budget == budgets[n] for n, has_schema, budget in seen)
    meta = json.loads((out / "meta.json").read_text(encoding="utf-8"))
    assert meta["condition"] == "without-skills" and meta["prompt_hashes"]["event-assign"]


def test_oracle_assign_ranks_and_leaves_noise_unfiled(mini, tmp_path, monkeypatch):
    import run_eval

    monkeypatch.setattr(run_eval, "OpenAIChatClient", lambda *a, **k: FakeChat())
    out = tmp_path / "oracle"
    run_eval.main(["--scenario", str(mini), "--condition", "skills", "--embed", "none", "--out", str(out),
                   "--oracle-assign"])
    snap = json.loads((out / "snapshots" / "cp-final.json").read_text(encoding="utf-8"))
    assert [u["item_id"] for u in snap["unfiled"]] == ["AAAAAAAA-0000-4000-8000-000000000003"]
    score = json.loads((out / "score.json").read_text(encoding="utf-8"))
    assert score["summary"]["noise_unfiled_rate"] == 1.0 and score["summary"]["home_rank_ran"] == "1/1"


def test_overnight_driver_uses_the_replay_clock_and_full_snapshots(mini, tmp_path, monkeypatch):
    import organizer.api as api
    import run_eval_overnight

    chats = []
    monkeypatch.setattr(api, "OpenAIChatClient", lambda *a, **k: chats.append(FakeChat()) or chats[-1])
    out = tmp_path / "night"
    run_eval_overnight.run(Namespace(scenario=str(mini), out=str(out), llm_url="http://127.0.0.1:9/v1", model="auto",
                                     timeout=5, embed_url="", mode="with-skills", clock="replay", rank="item",
                                     answer_questions="none"))
    brief, rank = _times(chats)
    assert brief and rank and all(d["now"].startswith("2026-08-01") for d in rank)
    config = json.loads((out / "config.json").read_text(encoding="utf-8"))
    assert config["clock"] == "replay" and config["rank"] == "item"
    final = json.loads((out / "final_state.json").read_text(encoding="utf-8"))
    assert {"item_persons", "questions", "questions_asked_total"} <= set(final)
    runs = json.loads((out / "runs.json").read_text(encoding="utf-8"))
    assert all(r["input_text"] for r in runs)


def test_cached_chat_replays_identical_requests(tmp_path):
    import eval_common

    inner = FakeChat()
    cached = eval_common.CachedChat(inner, tmp_path / "cache")
    msgs = [{"role": "system", "content": "# SKILL: home-rank v1"},
            {"role": "user", "content": '<data>\n{"now": "x", "events": [{"event_id": "E1", "item_count": 1}]}\n</data>'}]
    a = cached.complete(msgs, None, "home_rank", 100)
    b = cached.complete(msgs, None, "home_rank", 100)
    assert a.text == b.text and cached.hits == 1 and cached.misses == 1 and len(inner.calls) == 1
