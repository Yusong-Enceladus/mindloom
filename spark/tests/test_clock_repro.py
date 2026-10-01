"""Regressions for replay clock, short handles, deterministic ordering and auditable runs. Fake model."""

import json
import re
from pathlib import Path

from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.clock import FixedClock, ReplayClock, from_setting
from organizer.store import Store

from conftest import REPO, TEST_KEY, FakeChat, assign_out, event_of, ingest, make_item, raw_connect

ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:[+-]\d{2}:\d{2})?")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-")


def replay_org(settings, chat):
    settings.clock = "replay"
    return build_organizer(settings, chat=chat, embedder=HashEmbedClient())


def dated(text, iso, **kw):
    it = make_item(text, **kw)
    it["started_at"] = iso
    it.pop("ended_at")
    return it


def test_replay_brief_and_rank_see_item_time_never_the_wall_clock(settings, chat):
    org = replay_org(settings, chat)
    a = dated("咖啡馆菜单周五前定", "2026-09-14T08:52:00+08:00")
    b = dated("咖啡馆招牌下周二装", "2026-09-15T09:10:00+08:00")
    ingest(org, a, b)
    org.drain()
    org.rank()
    rank = [d for s, d, _, _ in chat.calls if s == "home-rank"][-1]
    assert rank["now"] == "2026-09-15T09:10:00+08:00"
    capture_times = {a["started_at"], b["started_at"]}
    for skill, data, _, _ in chat.calls:
        for t in ISO.findall(json.dumps(data, ensure_ascii=False)):
            assert any(t.startswith(c[:16]) for c in capture_times), f"{skill} saw a non-evidence time {t}"
    assert org.store.get_event(event_of(org, a["item_id"]))["created_at"].startswith("2026-09-14")


def _run_once(tmp_path, name):
    from organizer.config import Settings

    s = Settings()
    s.data_dir = tmp_path / name
    s.skills_dir = REPO / "skills"
    s.start_worker = False
    s.embed_base_url = ""
    s.clock = "replay"
    s.unlock_key = TEST_KEY
    chat = FakeChat()
    org = build_organizer(s, chat=chat, embedder=HashEmbedClient())
    ids = ["0A000000-0000-4000-8000-00000000000%d" % i for i in range(6)]
    texts = ["咖啡馆菜单初稿", "读书会书目", "咖啡馆招牌下周二装", "今天好热", "读书会订房间", "咖啡馆灯具验收"]
    for i, (iid, text) in enumerate(zip(ids, texts)):
        it = dated(text, f"2026-09-2{i}T09:00:00+08:00", item_id=iid)
        it["sha256"] = "%064x" % i
        ingest(org, it)
        org.drain()
    org.rank()
    users = [m[1]["content"] for _, _, _, m in chat.calls]
    digests = [r["input_digest"] for r in org.store.all("SELECT input_digest FROM runs ORDER BY rowid")]
    return users, digests


def test_prompts_are_byte_identical_across_replays(tmp_path):
    u1, d1 = _run_once(tmp_path, "a")
    u2, d2 = _run_once(tmp_path, "b")
    assert u1 == u2 and d1 == d2
    assert not any(UUID.search(u) for u in u1), "no UUIDs (event or item) in any prompt"


def test_unknown_handle_takes_the_rejected_path(org, chat):
    a = make_item("咖啡馆菜单")
    ingest(org, a)
    org.drain()
    b = make_item("咖啡馆招牌", minutes=1)
    ingest(org, b)
    item = org.store.get_item(b["item_id"])
    out = assign_out("attach", "E99", obj="咖啡馆招牌", judged=[{"event_id": "E99", "match": "same_object"}])
    placed = org._apply_assign(item, out, {"E1": event_of(org, a["item_id"])}, [], "run-x")
    assert placed and placed != event_of(org, a["item_id"])
    prop = org.store.one("SELECT status, reason FROM proposals WHERE target_id=? ORDER BY proposal_id DESC",
                         (b["item_id"],))
    assert prop["status"] == "rejected" and "unknown" in prop["reason"]


def test_candidate_ties_break_by_creation_order_not_by_uuid(org):
    cand = org.registry.script("event-assign", "candidates")
    item = {"embedding": None, "ts": 0.0, "person_ids": [], "source": ""}
    events = [{"event_id": "ffff", "order": 1, "centroid": None, "first_ts": 0, "last_ts": 0},
              {"event_id": "0000", "order": 2, "centroid": None, "first_ts": 0, "last_ts": 0}]
    ranked = cand.rank_candidates(item, events)
    assert [c["event_id"] for c in ranked] == ["ffff", "0000"]
    assert ranked[0]["margin"] == 0.0


def test_current_link_follows_sequence_not_timestamps(settings, chat):
    from organizer.decisions import apply_decision

    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient(), clock=FixedClock("2026-09-20T09:00:00+08:00"))
    a, r = make_item("咖啡馆菜单"), make_item("读书会书目", minutes=1)
    ingest(org, a, r)
    org.drain()
    cafe, club = event_of(org, a["item_id"]), event_of(org, r["item_id"])
    for target in (cafe, club, cafe):  # all within the same clock second
        assert apply_decision(org, {"kind": "move_item", "item_id": r["item_id"], "to_event_id": target})[0]
    assert event_of(org, r["item_id"]) == cafe


def test_clock_settings_and_health(client, org):
    assert client.get("/v1/health").json()["clock"] == "wall"
    assert isinstance(from_setting("replay"), ReplayClock)
    assert from_setting("fixed:2026-09-20T09:00:00+08:00").now_iso() == "2026-09-20T09:00:00+08:00"
    try:
        ReplayClock().now()
        raise AssertionError("a replay clock must not fall back to the wall clock")
    except RuntimeError:
        pass


def test_eval_drivers_do_not_monkeypatch_the_organizer_clock():
    for name in ("run_eval.py", "run_eval_overnight.py"):
        src = (REPO / "eval" / name).read_text(encoding="utf-8")
        assert "now_iso =" not in src and "organizer_module" not in src, name
        assert "clock" in src


def test_record_inputs_is_eval_only_and_never_served(settings, chat):
    settings.record_inputs = True
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    ingest(org, make_item("咖啡馆菜单"))
    org.drain()
    assert org.store.one("SELECT input_text FROM runs WHERE job_type='assign'")["input_text"].startswith("<data>")
    assert all("input_text" not in r for r in org.store.recent_runs(10))


def test_old_database_gets_handles_in_creation_order(tmp_path):
    path = tmp_path / "old.db"
    store = Store(path, key=TEST_KEY)
    for n in range(3):
        store.x("INSERT INTO events(event_id, created_at, seq, handle) VALUES (?,?,?,NULL)", (f"ev{n}", "x", 10 - n))
    store.conn.execute("DROP INDEX events_handle")
    store.lock()
    # simulate a pre-handle database: drop the column by rebuilding the table without it
    conn = raw_connect(path)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(events)") if r[1] not in ("handle", "anchor", "anchor_source")]
    conn.execute(f"CREATE TABLE ev2 AS SELECT {','.join(cols)} FROM events")
    conn.execute("DROP TABLE events")
    conn.execute("ALTER TABLE ev2 RENAME TO events")
    conn.commit()
    conn.close()
    store = Store(path, key=TEST_KEY)
    handles = {r["event_id"]: r["handle"] for r in store.all("SELECT event_id, handle FROM events")}
    assert handles == {"ev2": 1, "ev1": 2, "ev0": 3}  # by seq
    assert store.event_handle("ev2") == "E1"
