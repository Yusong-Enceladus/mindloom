"""The Mac <-> Spark link contract: link token, store identity and item revisions."""

import os
import sqlite3
import stat

import pytest
from fastapi.testclient import TestClient

from conftest import TEST_KEY, auth_headers, event_of, ingest, make_item
from organizer.api import build_organizer, create_app
from organizer.auth import LinkTokenError, ensure_link_token
from organizer.clients import HashEmbedClient
from organizer.config import Settings
from organizer.store import Store

# ---- 1. link token ----------------------------------------------------------------


def _app(settings, chat):
    return create_app(settings, organizer=build_organizer(settings, chat=chat, embedder=HashEmbedClient()))


def test_every_route_needs_the_bearer_token(settings, chat):
    app = _app(settings, chat)
    token = app.state.link_token
    routes = [("get", "/v1/health"), ("get", "/v1/state"), ("get", "/v1/debug/runs"), ("get", "/v1/debug/jobs"),
              ("post", "/v1/items"), ("post", "/v1/decisions"), ("post", "/v1/questions/x/answer"),
              ("get", "/docs"), ("get", "/nothing-here")]
    bad = [None, "Bearer", f"Bearer {'0' * 64}", f"Bearer {token[:-1]}", f"Bearer {token}x", f"Basic {token}", token]
    with TestClient(app) as c:
        for method, path in routes:
            for header in bad:
                headers = {"Authorization": header} if header else {}
                r = getattr(c, method)(path, headers=headers, **({"json": {}} if method == "post" else {}))
                assert r.status_code == 401, (path, header)
                assert r.headers["www-authenticate"] == "Bearer"
                assert token not in r.text
        ok = c.get("/v1/health", headers={"Authorization": f"Bearer {token}"})
        assert ok.status_code == 200
        assert c.get("/v1/state", headers={"Authorization": f"bearer  {token} "}).status_code == 200
        assert c.get("/v1/debug/jobs", headers={"Authorization": f"Bearer {token}"}).status_code == 200


def test_token_file_is_private_hex_and_survives_restarts(settings, chat):
    path = settings.token_path
    assert not path.exists()
    first = _app(settings, chat).state.link_token
    assert len(first) == 64 and int(first, 16) >= 0 and first == first.lower()
    assert path.read_text() == first  # exactly the token, no newline
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert _app(settings, chat).state.link_token == first
    # a loosened mode is tightened again on the next start
    os.chmod(path, 0o644)
    assert _app(settings, chat).state.link_token == first
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    # a fresh data dir gets a different token
    other = Settings()
    other.data_dir = settings.data_dir.parent / "other"
    other.skills_dir, other.start_worker, other.embed_base_url = settings.skills_dir, False, ""
    assert _app(other, chat).state.link_token != first


def test_corrupt_token_file_fails_closed(settings, chat):
    settings.data_dir.mkdir(parents=True)
    settings.token_path.write_text("not-a-token")
    with pytest.raises(LinkTokenError):
        _app(settings, chat)
    settings.token_path.unlink()
    settings.token_path.symlink_to(settings.data_dir / "elsewhere")
    with pytest.raises((LinkTokenError, FileNotFoundError)):
        ensure_link_token(settings.token_path)


def test_require_token_zero_turns_the_check_off(tmp_path, monkeypatch, chat):
    monkeypatch.setenv("ORGANIZER_REQUIRE_TOKEN", "0")
    s = Settings()
    s.data_dir, s.start_worker, s.embed_base_url = tmp_path / "d", False, ""
    s.skills_dir = Settings().skills_dir
    assert s.require_token is False
    with TestClient(_app(s, chat)) as c:
        assert c.get("/v1/health").status_code == 200
    assert s.token_path.exists()  # still created, so turning the check back on needs no new step
    monkeypatch.setenv("ORGANIZER_REQUIRE_TOKEN", "1")
    assert Settings().require_token is True
    monkeypatch.delenv("ORGANIZER_REQUIRE_TOKEN")
    assert Settings().require_token is True


# ---- 2. store identity ------------------------------------------------------------


def test_store_id_is_stable_across_restarts_and_new_for_a_fresh_db(settings, chat, tmp_path):
    app = _app(settings, chat)
    with TestClient(app, headers=auth_headers(app)) as c:
        health_id = c.get("/v1/health").json()["store_id"]
        state = c.get("/v1/state").json()
        assert state["store_id"] == health_id
        assert c.get(f"/v1/state?since={state['cursor']}").json()["store_id"] == health_id
    import uuid
    uuid.UUID(health_id)
    app.state.organizer.store.lock()
    assert Store(settings.db_path, key=TEST_KEY).store_id == health_id
    app2 = _app(settings, chat)
    with TestClient(app2, headers=auth_headers(app2)) as c:
        assert c.get("/v1/health").json()["store_id"] == health_id
    app2.state.organizer.store.lock()
    # the Spark was reset: a new database file means a new store_id
    for suffix in ("", "-wal", "-shm"):
        p = settings.data_dir / f"organizer.db{suffix}"
        if p.exists():
            p.unlink()
    assert Store(settings.db_path, key=TEST_KEY).store_id != health_id
    assert Store(tmp_path / "another.db", key=TEST_KEY).store_id != health_id


def test_old_database_gains_link_revisions(tmp_path):
    path = tmp_path / "old.db"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE event_items(event_id TEXT NOT NULL, item_id TEXT NOT NULL, attached_by TEXT NOT NULL,"
                 " run_id TEXT, created_at TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, removed_by TEXT,"
                 " PRIMARY KEY (event_id, item_id))")
    conn.execute("INSERT INTO event_items VALUES ('e', 'i', 'model', NULL, 'now', 0, NULL)")
    conn.commit()
    conn.close()
    store = Store(path, key=TEST_KEY)  # a plaintext store from before encryption: encrypted on unlock
    assert store.one("SELECT item_revision FROM event_items WHERE item_id='i'") == {"item_revision": None}
    assert store.store_id


# ---- 3. item revisions ------------------------------------------------------------


def test_revision_upsert_over_the_api(client, org):
    it = make_item("咖啡馆菜单初稿", revision=1)
    post = lambda *items: client.post("/v1/items", json={"items": list(items)}).json()  # noqa: E731
    assert post(it) == {"accepted": 1, "duplicates": 0}
    # same id + same revision: duplicate no-op, even with different content
    assert post(dict(it, text="别的内容")) == {"accepted": 0, "duplicates": 1}
    assert org.store.get_item(it["item_id"])["text"] == "咖啡馆菜单初稿"
    # higher revision replaces the content; retries of it are duplicates
    rev3 = dict(it, revision=3, text="咖啡馆菜单定稿")
    assert post(rev3, rev3) == {"accepted": 1, "duplicates": 1}
    assert post(rev3) == {"accepted": 0, "duplicates": 1}
    assert org.store.get_item(it["item_id"])["text"] == "咖啡馆菜单定稿"
    # lower revision: stale, ignored, counted as a duplicate
    assert post(dict(it, revision=2, text="咖啡馆菜单旧稿")) == {"accepted": 0, "duplicates": 1}
    assert org.store.get_item(it["item_id"])["revision"] == 3
    assert [r["revision"] for r in org.store.all("SELECT revision FROM items WHERE item_id=? ORDER BY revision",
                                                 (it["item_id"],))] == [1, 3]
    jobs = client.get("/v1/debug/jobs").json()["jobs"]
    assert [(j["revision"], j["state"], j["reason"]) for j in jobs] == [(1, "superseded", "ingest"),
                                                                        (3, "queued", "revision")]
    org.drain()
    ev = client.get("/v1/state").json()["events"][0]
    assert ev["item_ids"] == [it["item_id"]] and "定稿" in ev["status_line"]


def test_id_is_accepted_as_an_alias_for_item_id(client, org):
    it = make_item("读书会书目")
    it["id"] = it.pop("item_id")
    assert client.post("/v1/items", json={"items": [it]}).json() == {"accepted": 1, "duplicates": 0}
    assert org.store.get_item(it["id"])["text"] == "读书会书目"


def _three(org):
    a = make_item("咖啡馆菜单", minutes=0)
    b = make_item("读书会书目", minutes=5)
    c = make_item("咖啡馆招牌", minutes=10)
    ingest(org, a, b, c)
    org.drain()
    cafe, club = event_of(org, a["item_id"]), event_of(org, b["item_id"])
    assert cafe != club and event_of(org, c["item_id"]) == cafe
    return a, b, c, cafe, club


def test_higher_revision_reassigns_a_model_placement_and_rebriefs_both_events(org, chat):
    a, b, c, cafe, club = _three(org)
    assigns = chat.count("event-assign")
    ingest(org, dict(c, revision=2, text="读书会改到图书馆二楼"))
    org.drain()
    assert chat.count("event-assign") == assigns + 1
    # the model never sees the item itself as evidence for its own old event
    data = [d for s, d, _, _ in chat.calls if s == "event-assign"][-1]
    assert all(c["item_id"] != it["item_id"] for cand in data["candidates"] for it in cand["recent_items"])
    assert event_of(org, c["item_id"]) == club
    state = {e["event_id"]: e for e in org.state(0)["events"]}
    assert state[cafe]["item_ids"] == [a["item_id"]] and not state[cafe]["deleted"]
    assert c["item_id"] in state[club]["item_ids"] and "图书馆" in state[club]["status_line"]
    assert "招牌" not in state[cafe]["status_line"]
    link = org.store.current_event_link(c["item_id"])
    assert link["item_revision"] == 2 and link["attached_by"] == "model"


def test_revision_that_empties_an_event_retires_it(org, chat):
    a = make_item("咖啡馆菜单", minutes=0)
    b = make_item("读书会书目", minutes=5)
    ingest(org, a)
    org.drain()
    ingest(org, b)
    org.drain()
    club_alone = event_of(org, b["item_id"])
    c = make_item("体检预约", minutes=8)
    ingest(org, c)
    org.drain()
    lone = event_of(org, c["item_id"])
    # a singleton that still stands alone keeps its event id
    ingest(org, dict(c, revision=2, text="体检改到周二"))
    org.drain()
    assert event_of(org, c["item_id"]) == lone
    # a singleton whose new content belongs elsewhere moves, and its empty event is retired
    ingest(org, dict(c, revision=3, text="读书会茶点"))
    org.drain()
    assert event_of(org, c["item_id"]) == club_alone
    assert org.store.get_event(lone)["deleted"]


def test_revision_reorganizing_is_idempotent_under_retries(org, chat):
    a, b, c, cafe, club = _three(org)
    assigns = chat.count("event-assign")

    def fail(_):
        raise RuntimeError("brief crashed")

    chat.before["event-brief"] = fail
    ingest(org, dict(c, revision=2, text="读书会改到图书馆二楼"))
    org.drain()
    job = org.store.one("SELECT * FROM jobs WHERE item_id=? AND revision=2", (c["item_id"],))
    assert job["state"] == "queued" and job["error_category"] == "internal"
    org.store.x("UPDATE jobs SET not_before=0")
    org.drain()
    assert org.store.one("SELECT state FROM jobs WHERE item_id=? AND revision=2", (c["item_id"],))["state"] == "done"
    assert chat.count("event-assign") == assigns + 1  # the retry did not decide again
    assert event_of(org, c["item_id"]) == club
    assert org.store.scalar("SELECT COUNT(*) FROM events WHERE deleted=0") == 2
    # replaying the same revision afterwards changes nothing
    assert ingest(org, dict(c, revision=2, text="读书会改到图书馆二楼")) == (0, 1)
    assert org.drain() == 0


def test_user_placement_survives_a_higher_revision(org, chat):
    from organizer.decisions import apply_decision

    a, b, c, cafe, club = _three(org)
    assert apply_decision(org, {"kind": "move_item", "item_id": b["item_id"], "to_event_id": cafe})[0]
    org.drain()
    assigns = chat.count("event-assign")
    ingest(org, dict(b, revision=2, text="读书会书目又改了"))
    org.drain()
    assert chat.count("event-assign") == assigns
    assert event_of(org, b["item_id"]) == cafe


def test_higher_revision_replaces_persons(org):
    it = make_item(kind="meeting_offline", persons=[{"person_id": "voice-1", "display_name": "张三"}],
                   segments=[{"start_ms": 0, "end_ms": 1000, "person_id": "voice-1", "text": "咖啡馆豆子"}])
    ingest(org, it)
    org.drain()
    assert org.people.item_person_ids(it["item_id"]) == ["voice-1"]
    ingest(org, dict(it, revision=2, persons=[{"person_id": "voice-2", "display_name": "李四"}],
                     segments=[{"start_ms": 0, "end_ms": 1000, "person_id": "voice-2", "text": "咖啡馆豆子"}]))
    org.drain()
    assert org.people.item_person_ids(it["item_id"]) == ["voice-2"]
    ev = next(e for e in org.state(0)["events"] if it["item_id"] in e["item_ids"])
    assert ev["person_ids"] == ["voice-2"]


# ---- review follow-ups --------------------------------------------------------------


def test_old_database_backfills_link_revisions_from_items(tmp_path):
    import re

    from organizer import store as store_module
    path = tmp_path / "old-with-items.db"
    conn = sqlite3.connect(path)
    items_ddl = re.search(r"CREATE TABLE IF NOT EXISTS items\(.*?\);", store_module.SCHEMA, re.S).group(0)
    conn.execute(items_ddl)
    for revision in (1, 2):
        conn.execute("INSERT INTO items(item_id, revision, kind, source_app, started_at, started_ts, sha256,"
                     " received_at) VALUES ('i', ?, 'dictation', '{}', 'now', 0, 'x', 'now')", (revision,))
    conn.execute("CREATE TABLE event_items(event_id TEXT NOT NULL, item_id TEXT NOT NULL, attached_by TEXT NOT NULL,"
                 " run_id TEXT, created_at TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, removed_by TEXT,"
                 " PRIMARY KEY (event_id, item_id))")
    conn.execute("INSERT INTO event_items VALUES ('e', 'i', 'model', NULL, 'now', 0, NULL)")
    conn.commit()
    conn.close()
    store = Store(path, key=TEST_KEY)  # a plaintext store from before encryption: encrypted on unlock
    # Links made before revision tracking count as placed at the item's latest revision.
    assert store.one("SELECT item_revision FROM event_items WHERE item_id='i'") == {"item_revision": 2}


def test_failed_question_answer_is_not_reported_as_applied_on_replay(org, chat):
    from organizer.decisions import answer_question

    from test_questions import _ask_always
    first = make_item("咖啡馆菜单", minutes=0)
    ingest(org, first)
    org.drain()
    chat.handlers["event-assign"] = _ask_always
    second = make_item("周五要确认的事", minutes=5)
    ingest(org, second)
    org.drain()
    q = org.store.open_questions()[0]
    # The target event disappears after the question was asked (without expiring the question).
    org.store.update_event(q["b"], deleted=1)
    before = event_of(org, second["item_id"])
    assert answer_question(org, q["question_id"], True) == (409, "event deleted")
    row = org.store.one("SELECT status, apply_note FROM questions WHERE question_id=?", (q["question_id"],))
    assert row == {"status": "failed", "apply_note": "event deleted"}
    # A replay (lost response, retry) returns the stored outcome, never "already answered".
    assert answer_question(org, q["question_id"], True) == (409, "event deleted")
    assert event_of(org, second["item_id"]) == before


def test_mac_shaped_item_payload_validates_at_the_name_limits(client):
    """The Mac clamps person and source names to 128/256 Unicode scalars; the server must accept them."""
    from organizer.schemas import Item
    payload = {
        "item_id": "6F1C1B6E-0D5E-4D8C-9B0A-3A7E2F7C9D11", "revision": 3, "kind": "meeting_offline",
        "source_app": {"bundle_id": "b" * 256, "name": "線" * 256},
        "started_at": "2026-09-26T09:00:00.000Z", "text": "虚构的会议逐字稿",
        "segments": [{"start_ms": 0, "end_ms": 900, "person_id": "voice-person-1", "text": "虚构的会议逐字稿"}],
        "persons": [{"person_id": "voice-person-1", "display_name": "A" * 128},
                    {"person_id": "voice-person-2", "display_name": "𠀀" * 128}],
        "sha256": "0" * 64,
    }
    Item.model_validate(payload)
    assert client.post("/v1/items", json={"items": [payload]}).json() == {"accepted": 1, "duplicates": 0}
    too_long = dict(payload, persons=[{"person_id": "voice-person-1", "display_name": "A" * 129}], revision=4)
    assert client.post("/v1/items", json={"items": [too_long]}).status_code == 422


def test_unix_socket_serves_the_same_app_only_from_a_private_directory(settings, chat, tmp_path):
    import asyncio
    import socket
    import threading
    import time

    import httpx

    from organizer.__main__ import UnsafeSocketPath, build_servers, check_private_socket_dir, run_servers

    open_dir = tmp_path / "open"
    open_dir.mkdir(mode=0o755)
    os.chmod(open_dir, 0o755)
    with pytest.raises(UnsafeSocketPath):
        check_private_socket_dir(open_dir / "organizer.sock")
    with pytest.raises(UnsafeSocketPath):
        check_private_socket_dir(__import__("pathlib").Path("relative.sock"))
    import tempfile
    from pathlib import Path
    # Unix socket paths are limited to ~104 bytes, so use a short directory.
    private = Path(tempfile.mkdtemp(prefix="org-", dir="/tmp"))
    os.chmod(private, 0o700)
    uds = private / "organizer.sock"
    check_private_socket_dir(uds)

    app = _app(settings, chat)
    token = app.state.link_token
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    # The default is the socket alone; TCP is an explicit opt-in.
    default = build_servers(app, uds)
    assert len(default) == 1 and default[0].config.uds == str(uds)
    servers = build_servers(app, uds, ("127.0.0.1", port))
    thread = threading.Thread(target=lambda: asyncio.run(run_servers(servers, uds)), daemon=True)
    thread.start()
    try:
        deadline = time.time() + 10
        while not (uds.exists() and all(s.started for s in servers)):
            assert time.time() < deadline, "servers did not start"
            time.sleep(0.05)
        with httpx.Client(transport=httpx.HTTPTransport(uds=str(uds)), trust_env=False) as c:
            assert c.get("http://organizer/v1/health").status_code == 401
            ok = c.get("http://organizer/v1/health", headers={"Authorization": f"Bearer {token}"})
            assert ok.status_code == 200 and ok.json()["store_id"] == app.state.organizer.store.store_id
        tcp = httpx.get(f"http://127.0.0.1:{port}/v1/health", headers={"Authorization": f"Bearer {token}"},
                        trust_env=False)
        assert tcp.status_code == 200
        # The recall skill reads the state over the socket with the stdlib only.
        import importlib.util
        recall_path = Path(__file__).resolve().parents[2] / "skills" / "recall" / "scripts" / "recall.py"
        spec = importlib.util.spec_from_file_location("recall_under_test", recall_path)
        recall = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(recall)
        state = recall.fetch_state(None, str(uds), token)
        assert "events" in state
        with pytest.raises(RuntimeError):
            recall.fetch_state(None, str(uds), "wrong-token")
    finally:
        servers[0].should_exit = True
        thread.join(timeout=10)
    assert not thread.is_alive()
    assert not uds.exists()
    app.state.organizer.store.lock()
    os.rmdir(private)


def test_tcp_is_off_unless_explicitly_enabled(monkeypatch, tmp_path):
    from organizer.config import Settings

    monkeypatch.delenv("ORGANIZER_TCP", raising=False)
    monkeypatch.delenv("ORGANIZER_UDS", raising=False)
    monkeypatch.setenv("ORGANIZER_DATA_DIR", str(tmp_path))
    settings = Settings()
    assert settings.tcp is False
    assert settings.socket_path == tmp_path / "organizer.sock"
    monkeypatch.setenv("ORGANIZER_TCP", "1")
    assert Settings().tcp is True


def test_local_tools_never_send_the_token_over_tcp():
    """ctl.sh, the demo control script, the smoke test, and recall talk to the socket; none of them
    targets a fixed loopback TCP port with the token."""
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    ctl = (root / "spark" / "ctl.sh").read_text()
    assert "--unix-socket" in ctl and "http://127.0.0.1:$PORT" not in ctl
    demo = (root / "ops" / "spark_demo.sh").read_text()
    assert "HTTPTransport(uds=" in demo and "127.0.0.1:8766" not in demo
    # Neutral, overridable unit names that name no person or other project.
    assert "ORG=${MEMORY_DEMO_ORG_UNIT:-memory-demo-organizer.service}" in demo
    assert "EMBED=${MEMORY_DEMO_EMBED_UNIT:-memory-demo-embed.service}" in demo
    recall = (root / "skills" / "recall" / "scripts" / "recall.py").read_text()
    assert "AF_UNIX" in recall
    smoke = (root / "eval" / "smoke_api.py").read_text()
    assert 'default="http://127.0.0.1' not in smoke
