"""Privacy contract v6, Spark side (docs/PRIVACY.md): keys and lock states, 423 / 410, wipe, the user's delete,
read-then-delete, no plaintext at rest, masking (shared vectors) and embedded media. Invented content only."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import threading
import time
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import filefixtures as F
from conftest import (REPO, TEST_KEY, TINY_PNG_B64, FakeChat, chat_extraction, event_of, image_reader, make_item,
                      raw_connect)
from organizer import db, fileparse, keys, masking
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.file_read import read_file
from organizer.store import Store

# The shared vectors file must stay byte-identical with the Mac's copy (privacy/mask_vectors.json in both
# repositories); this constant changes only together with the file, in both.
VECTORS_SHA256 = "b256b5a57ad2bc92e963de5427f247c5255397270ed038bf751f0b18ae9fe71f"
VECTORS = REPO / "privacy" / "mask_vectors.json"
SENTINEL = "哨兵ZQXV字样"
# A sealed-shaped phone entry (phone contract section 5): the Spark never opens one. Its wire string is the
# needle for "gone from disk" checks, since a sealed entry has no plaintext to look for.
PHONE_ID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
PHONE_WIRE = "mlseal1." + base64.urlsafe_b64encode(b"\x5aQXZVSENTINEL" * 8).decode().rstrip("=")


def phone_entry(entry_id: str = PHONE_ID, wire: str = PHONE_WIRE) -> dict:
    return {"inbox_id": entry_id, "source": "sealed", "kind": "sealed", "blob": wire,
            "received_at": "2026-09-30T08:00:00+08:00"}
OTHER_KEY = bytes([0x77]) * 32


# ---- fixtures ------------------------------------------------------------------------------------------


@pytest.fixture
def locked(settings, chat):
    """The service as deployed: the store starts locked and is opened only by POST /v1/unlock."""
    settings.unlock_key = None
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org)
    with TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"}) as c:
        yield c


def unlock(c, key: bytes = TEST_KEY):
    r = c.post("/v1/unlock", json={"key": key.hex()})
    if r.status_code == 200:
        c.headers["X-Mindloom-Access"] = keys.access_proof(key)  # what the Mac sends on every data request
    return r


def files_under(root: Path) -> list[Path]:
    return [p for p in root.rglob("*") if p.is_file()]


def assert_absent(root: Path, *needles: bytes) -> None:
    for p in files_under(root):
        data = p.read_bytes()
        for n in needles:
            assert n not in data, f"{n!r} found in {p.name}"


def decrypted_dump(path) -> str:
    """Every row of every table, read with the test key (what someone holding the key could see)."""
    conn = raw_connect(path)
    try:
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        out = []
        for t in tables:
            for row in conn.execute(f'SELECT * FROM "{t}"'):
                out.append(repr([v.decode("utf-8", "replace") if isinstance(v, bytes) else v for v in row]))
        return "\n".join(out)
    finally:
        conn.close()


def post(c, *items):
    return c.post("/v1/items", json={"items": list(items)})


# ---- masking (contract section 3) ---------------------------------------------------------------------


def test_mask_vectors_are_the_shared_file_and_all_pass():
    raw = VECTORS.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == VECTORS_SHA256
    doc = json.loads(raw)
    key = bytes.fromhex(doc["mask_key_hex"])
    assert key == bytes([0x11]) * 32 and doc["order"] == list(masking.ORDER) and doc["labels"] == masking.LABELS
    assert len(doc["vectors"]) >= 100
    for v in doc["vectors"]:
        masked, _ = masking.mask(v["input"], key)
        assert masked == v["expected"], v["input"]
        assert masking.mask(masked, key)[0] == masked  # idempotent
    d = doc["derive"][0]
    key_id, store_key, mask_key = keys.derive_keys(bytes.fromhex(d["library_key_hex"]))
    assert (key_id, store_key.hex(), mask_key.hex()) == (d["key_id"], d["store_key_hex"], d["mask_key_hex"])
    assert masking.derive_keys is keys.derive_keys


def test_mask_obj_masks_free_text_and_leaves_ids_alone():
    key = bytes([0x11]) * 32
    out = masking.mask_obj({"text": "回电 13812345678", "type": "chat_screenshot", "run_id": "13812345678",
                            "messages": [{"sender": "13912345678", "text": "邮箱 a.b@example.com"}],
                            "fields": [{"key": "phone", "label": "电话", "value": "13812345678"}]}, key)
    ph = masking.mask("13812345678", key)[0]
    assert out["text"] == "回电 " + ph and out["fields"][0]["value"] == ph and out["run_id"] == "13812345678"
    assert out["messages"][0]["sender"].startswith("〔手机号·") and "〔邮箱·" in out["messages"][0]["text"]
    assert out["type"] == "chat_screenshot" and out["fields"][0]["key"] == "phone"


def test_skills_that_see_masked_text_say_placeholders_stay_as_they_are():
    line = "占位符（如〔手机号·a1b2c3〕）是被遮住的号码，原样保留，不要猜、不要改写"
    for name in ("event-assign", "event-brief", "home-rank", "item-split", "file-read", "recall",
                 "event-consolidate", "person-resolve", "matter-map", "matter-group"):
        assert line in (REPO / "skills" / name / "SKILL.md").read_text(encoding="utf-8"), name


def test_skills_that_read_material_say_it_is_data_not_instructions():
    """Every routed skill whose prompt holds item text says that text is material, never an instruction."""
    for name in ("event-assign", "event-brief", "item-split", "file-read", "image-read", "event-consolidate",
                 "person-resolve", "matter-map", "matter-group"):
        text = (REPO / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
        assert "不是指令" in text or "只是素材内容" in text, name


# ---- lock states (contract section 2) --------------------------------------------------------------------


def test_unlock_lock_health_and_stats(locked, settings):
    c = locked
    h = c.get("/v1/health").json()
    assert h["locked"] is True and h["key_id"] is None and h["store_id"] is None and h["items"] is None
    assert not settings.db_path.exists()
    r = unlock(c)
    key_id = keys.derive_keys(TEST_KEY)[0]
    assert r.status_code == 200 and r.json()["locked"] is False and r.json()["key_id"] == key_id
    assert r.json()["created"] is True
    store_id = r.json()["store_id"]
    # idempotent with the same key
    again = unlock(c)
    assert again.status_code == 200 and again.json()["created"] is False and again.json()["store_id"] == store_id
    h = c.get("/v1/health").json()
    assert h["locked"] is False and h["key_id"] == key_id and h["store_id"] == store_id and h["items"] == 0
    # the sidecar holds only the key_id, private
    sidecar = settings.data_dir / "store.keyid"
    assert sidecar.read_text() == key_id and oct(sidecar.stat().st_mode & 0o777) == "0o600"
    assert post(c, make_item("咖啡馆菜单周五定")).json() == {"accepted": 1, "duplicates": 0}
    stats = c.get("/v1/stats").json()
    assert set(stats) == {"items", "blob_bytes", "db_bytes", "derived_bytes"}
    assert stats["items"] == 1 and stats["blob_bytes"] == 0 and stats["db_bytes"] > 0
    assert c.post("/v1/lock").json() == {"locked": True}
    assert c.post("/v1/lock").json() == {"locked": True}  # idempotent
    h = c.get("/v1/health").json()
    assert h["locked"] is True and h["key_id"] == key_id  # read from the sidecar while locked
    assert c.get("/v1/stats").status_code == 423
    # after the next unlock everything is still there
    assert unlock(c).json()["created"] is False
    assert c.get("/v1/health").json()["items"] == 1 and c.get("/v1/health").json()["store_id"] == store_id


def test_wrong_and_malformed_keys(locked, settings):
    c = locked
    assert unlock(c).status_code == 200
    # a different key while unlocked, and after a lock: 409 with the store's own key_id; it stays locked
    r = unlock(c, OTHER_KEY)
    assert r.status_code == 409 and r.json() == {"error": "wrong_key", "key_id": keys.derive_keys(TEST_KEY)[0]}
    c.post("/v1/lock")
    r = unlock(c, OTHER_KEY)
    assert r.status_code == 409 and r.json()["key_id"] == keys.derive_keys(TEST_KEY)[0]
    assert c.get("/v1/health").json()["locked"] is True
    for body in ({"key": "ab" * 31}, {"key": "zz" * 32}, {"key": 5}, {}, [], "x"):
        r = c.post("/v1/unlock", json=body)
        assert r.status_code == 400 and r.json() == {"error": "bad_key"}
        assert "zz" not in r.text
    assert c.post("/v1/unlock", content=b"not json", headers={"content-type": "application/json"}).status_code == 400
    # an encrypted store whose sidecar is gone: a wrong key is still refused (key_id unknown)
    (settings.data_dir / "store.keyid").unlink()
    r = unlock(c, OTHER_KEY)
    assert r.status_code == 409 and r.json()["key_id"] is None
    assert unlock(c).status_code == 200 and (settings.data_dir / "store.keyid").exists()


def test_every_data_route_is_423_while_locked_but_health_and_phone_add_work(locked):
    c = locked
    routes = [("get", "/v1/state"), ("post", "/v1/items"), ("post", "/v1/decisions"),
              ("post", "/v1/questions/x/answer"), ("get", "/v1/inbox"), ("post", "/v1/inbox/x/ack"),
              ("get", "/v1/debug/runs"), ("get", "/v1/debug/jobs"), ("get", "/v1/stats"),
              ("delete", "/v1/items/6F1C1B6E-0D5E-4D8C-9B0A-3A7E2F7C9D11")]
    for method, path in routes:
        kwargs = {"json": {}} if method == "post" else {}
        r = getattr(c, method)(path, **kwargs)
        assert r.status_code == 423 and r.json() == {"error": "locked"}, path
    assert c.get("/v1/health").status_code == 200
    r = c.post("/v1/inbox", json=phone_entry())
    assert r.status_code == 200 and c.get("/v1/health").json()["inbox_pending"] == 1
    # the token is still checked first: an anonymous caller does not learn the lock state
    with TestClient(c.app) as anon:
        assert anon.get("/v1/state").status_code == 401 and anon.post("/v1/unlock", json={}).status_code == 401
    unlock(c)
    got = c.get("/v1/inbox").json()["items"]
    assert [i["blob"] for i in got] == [PHONE_WIRE]


def test_phone_inbox_add_and_status_while_locked_and_content_gone_after_ack(locked, settings, capsys):
    from organizer import inbox_cli
    c = locked
    # the retired plaintext path is refused: a plaintext share never reaches the disk
    assert inbox_cli.main(["add", "--source", "iPhone"], stdin=f"手机分享{SENTINEL}".encode(), client=c) == 1
    assert inbox_cli.main(["add", "--sealed", "--id", PHONE_ID], stdin=PHONE_WIRE.encode(), client=c) == 0
    assert inbox_cli.main(["status"], client=c) == 0
    assert "1 条" in capsys.readouterr().out
    assert_absent(settings.data_dir, SENTINEL.encode())
    unlock(c)
    entry = c.get("/v1/inbox").json()["items"][0]
    assert entry["blob"] == PHONE_WIRE and entry["seq"] > 10 ** 12  # ms-based: above any older in-store cursor
    assert c.post(f"/v1/inbox/{entry['inbox_id']}/ack").json()["acked"] is True
    # acked content is overwritten in inbox.db (secure_delete, no WAL): nothing of it stays in the data dir
    assert_absent(settings.data_dir, PHONE_WIRE.encode(), SENTINEL.encode())


def test_worker_pauses_while_locked_and_resumes_after_unlock(settings, chat):
    settings.unlock_key = TEST_KEY
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    from conftest import ingest
    ingest(org, make_item("咖啡馆菜单周五定"), make_item("咖啡馆招牌下周装", minutes=3))
    org.lock()
    stop = threading.Event()
    worker = threading.Thread(target=org.run_worker, args=(stop,), daemon=True)
    worker.start()
    try:
        time.sleep(0.3)
        assert chat.calls == [] and org.last_error is None
        org.unlock(TEST_KEY)
        deadline = time.time() + 10
        while time.time() < deadline and (org.store.queue_depth() or not org.store.live_events()
                                          or not all(e["title"] for e in org.store.live_events())):
            time.sleep(0.05)
        assert len(org.store.live_events()) == 1 and org.store.queue_depth() == 0
    finally:
        stop.set()
        org.wake()
        worker.join(timeout=10)


# ---- no plaintext at rest ---------------------------------------------------------------------------------


def test_no_plaintext_and_no_key_on_disk(locked, settings, chat):
    c = locked
    unlock(c)
    org = c.app.state.organizer
    chat.handlers["image-read"] = image_reader(chat_extraction(
        [{"sender": "张三", "is_self": False, "time": "10:02", "text": f"咖啡馆 {SENTINEL} 报价"}], f"截图里有{SENTINEL}"))
    text = make_item(f"咖啡馆菜单 {SENTINEL} 周五定")
    shot = make_item(kind="image", minutes=2, image_b64=TINY_PNG_B64)
    doc = F.docx([f"咖啡馆合同 {SENTINEL} 第三条"])
    file_item = make_item(kind="file", minutes=4)
    file_item.update(filename="合同.docx", bytes_b64=base64.b64encode(doc).decode(), sha256=hashlib.sha256(doc).hexdigest())
    assert post(c, text, shot, file_item).json()["accepted"] == 3
    org.drain()
    state = c.get("/v1/state").json()
    assert SENTINEL in json.dumps(state, ensure_ascii=False)  # the content is there, readable through the API
    ev = state["events"][0]["event_id"]
    assert c.post("/v1/decisions", json={"decisions": [{"kind": "rename_event", "event_id": ev,
                                                        "title": f"标题{SENTINEL}"}]}).json()["applied"] == 1
    library_hex = TEST_KEY.hex().encode()
    _, store_key, mask_key = keys.derive_keys(TEST_KEY)
    needles = (SENTINEL.encode(), library_hex, TEST_KEY, store_key, store_key.hex().encode(), mask_key,
               mask_key.hex().encode(), "咖啡馆".encode())
    # every file of the data directory, while unlocked (WAL included) and after the lock
    assert_absent(settings.data_dir, *needles)
    assert not db.is_plaintext(settings.db_path)
    c.post("/v1/lock")
    assert_absent(settings.data_dir, *needles)
    # without the key the file reads as nothing at all
    with pytest.raises(db.DatabaseError):
        db.connect(settings.db_path, None).execute("SELECT * FROM items")
    with pytest.raises(db.DatabaseError):
        db.connect(settings.db_path, keys.derive_keys(OTHER_KEY)[1])


def test_legacy_plaintext_store_is_encrypted_on_first_unlock(settings, chat):
    import sqlite3 as stdlib_sqlite3
    settings.data_dir.mkdir(parents=True)
    conn = stdlib_sqlite3.connect(settings.db_path)
    conn.executescript("""
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta VALUES ('seq', '7'), ('schema_version', '1'), ('store_id', 'legacy-store-id');
        CREATE TABLE items(item_id TEXT NOT NULL, revision INTEGER NOT NULL, kind TEXT NOT NULL,
          source_app TEXT NOT NULL, started_at TEXT NOT NULL, started_ts REAL NOT NULL, ended_at TEXT, ended_ts REAL,
          text TEXT, segments TEXT, persons TEXT, sha256 TEXT NOT NULL, has_image INTEGER NOT NULL DEFAULT 0,
          received_at TEXT NOT NULL, PRIMARY KEY (item_id, revision));
        CREATE TRIGGER items_no_update BEFORE UPDATE ON items BEGIN SELECT RAISE(ABORT, 'items are append-only'); END;
        CREATE TRIGGER items_no_delete BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'items are append-only'); END;
        CREATE VIEW latest_items AS SELECT i.* FROM items i
          WHERE i.revision = (SELECT MAX(r.revision) FROM items r WHERE r.item_id = i.item_id);
        CREATE TABLE inbox(inbox_id TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, text TEXT, image BLOB,
          received_at TEXT NOT NULL, created_at TEXT NOT NULL, acked INTEGER NOT NULL DEFAULT 0, acked_at TEXT,
          seq INTEGER NOT NULL);
    """)
    conn.execute("INSERT INTO items VALUES ('AAAAAAAA-0000-4000-8000-000000000001', 1, 'dictation', '{\"name\":\"备忘录\"}',"
                 " '2026-09-20T09:00:00+08:00', 1790000000, NULL, NULL, ?, NULL, NULL, 'x', 0, 'now')",
                 (f"旧素材{SENTINEL}",))
    conn.execute("INSERT INTO inbox VALUES ('1b4e28ba-2fa1-11d2-883f-0016d3cca427', 'iPhone', 'text', ?, NULL,"
                 " '2026-09-21T08:15:00+08:00', 'now', 0, NULL, 6)", (f"手机{SENTINEL}",))
    conn.commit()
    conn.close()
    settings.unlock_key = None
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org)
    with TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"}) as c:
        assert c.get("/v1/health").json()["key_id"] is None  # no key-bound store yet
        r = unlock(c)
        assert r.status_code == 200 and r.json()["created"] is False and r.json()["store_id"] == "legacy-store-id"
        assert not db.is_plaintext(settings.db_path)
        assert org.store.get_item("AAAAAAAA-0000-4000-8000-000000000001")["text"] == f"旧素材{SENTINEL}"
        # the new integrity rule replaced the append-only triggers; the old inbox moved to inbox.db
        assert org.store.one("SELECT 1 FROM sqlite_master WHERE name='items_no_update'") is None
        assert org.store.one("SELECT 1 FROM sqlite_master WHERE name='inbox'") is None
        assert [i["text"] for i in c.get("/v1/inbox").json()["items"]] == [f"手机{SENTINEL}"]
        c.post("/v1/inbox/1b4e28ba-2fa1-11d2-883f-0016d3cca427/ack")
        assert c.delete("/v1/items/AAAAAAAA-0000-4000-8000-000000000001").status_code == 200
    # plaintext file and its side files are gone (their freed disk blocks may linger: docs/PRIVACY.md)
    assert not Path(str(settings.db_path) + ".enc-tmp").exists()
    assert_absent(settings.data_dir, SENTINEL.encode())
    assert not db.is_plaintext(settings.db_path)


# ---- wipe -------------------------------------------------------------------------------------------------


def test_wipe_needs_the_matching_key_id_and_forgets_everything(locked, settings):
    c = locked
    assert c.post("/v1/wipe", json={"key_id": "0" * 16}).json() == {"wiped": True}  # no store yet: fine
    unlock(c)
    post(c, make_item(f"咖啡馆{SENTINEL}"))
    assert c.post("/v1/inbox", json=phone_entry()).status_code == 200
    (settings.data_dir / "organizer.log").write_text(f"a log line {SENTINEL}")
    key_id = keys.derive_keys(TEST_KEY)[0]
    r = c.post("/v1/wipe", json={"key_id": "0123456789abcdef"})
    assert r.status_code == 409 and r.json() == {"error": "wrong_key", "key_id": key_id}
    assert c.post("/v1/wipe", json={"key_id": "not-hex"}).status_code == 400
    assert c.get("/v1/health").json()["locked"] is False  # a refused wipe changes nothing
    c.post("/v1/lock")
    assert c.post("/v1/wipe", json={"key_id": key_id}).json() == {"wiped": True}  # works while locked
    names = {p.name for p in settings.data_dir.iterdir()}
    assert not names & {"organizer.db", "organizer.db-wal", "organizer.db-shm", "store.keyid"}
    assert (settings.data_dir / "organizer.log").stat().st_size == 0  # emptied, not unlinked
    assert_absent(settings.data_dir, SENTINEL.encode(), PHONE_WIRE.encode())
    h = c.get("/v1/health").json()
    assert h["locked"] is True and h["key_id"] is None and h["inbox_pending"] == 0
    # the next enable brings a new key and a new, empty store
    r = unlock(c, OTHER_KEY)
    assert r.status_code == 200 and r.json()["created"] is True and r.json()["key_id"] == keys.derive_keys(OTHER_KEY)[0]
    assert c.get("/v1/health").json()["items"] == 0


# ---- the user's delete ------------------------------------------------------------------------------------


def test_delete_purges_every_revision_child_and_derived_row(org, client, chat):
    keep = make_item("咖啡馆菜单周五定", minutes=0)
    gone = make_item(f"咖啡馆招牌下周装，{SENTINEL}，师傅说要先量好门头的尺寸。咖啡馆的灯具也要一起验收，电工周四来。"
                     f"读书会订房间的事要问图书馆，{SENTINEL}，最好是二楼的小会议室。读书会十月的书目还没定，大家再投一次票。",
                     minutes=5)
    assert post(client, keep, gone).json()["accepted"] == 2
    org.drain()
    rev2 = gone["text"].replace("下周装", "改到周三装")
    assert post(client, dict(gone, revision=2, text=rev2)).json() == {"accepted": 1, "duplicates": 0}
    org.drain()
    iid = gone["item_id"]
    children = [r["child_id"] for r in org.store.all("SELECT child_id FROM item_segments WHERE parent_id=?", (iid,))]
    assert children  # split into a 咖啡馆 part and a 读书会 part
    events = {e["event_id"] for e in client.get("/v1/state").json()["events"] if iid in e["item_ids"]}
    assert events
    r = client.delete(f"/v1/items/{iid}")
    assert r.status_code == 200 and r.json() == {"deleted": True}
    ids = [iid, *children]
    marks = ",".join("?" * len(ids))
    rows = org.store.all(f"SELECT text, segments, persons, sha256, meta, purged FROM items WHERE item_id IN ({marks})", ids)
    assert len(rows) >= 3 and all(r == {"text": None, "segments": None, "persons": None, "sha256": None, "meta": None,
                                        "purged": 1} for r in rows)
    for table in ("item_blobs", "item_derived", "item_persons"):
        assert org.store.scalar(f"SELECT COUNT(*) FROM {table} WHERE item_id IN ({marks})", ids) == 0
    assert org.store.scalar("SELECT COUNT(*) FROM item_segments WHERE parent_id=?", (iid,)) == 0
    links = org.store.all(f"SELECT removed, removed_by FROM event_items WHERE item_id IN ({marks})", ids)
    assert links and all(link == {"removed": 1, "removed_by": "user-delete"} for link in links)
    assert org.store.scalar(f"SELECT COUNT(*) FROM runs WHERE subject IN ({marks}) AND output IS NOT NULL", ids) == 0
    assert org.store.one("SELECT item_id FROM item_tombstones WHERE item_id=?", (iid.lower(),))
    # the events are briefed again without it; one left empty is deleted and blanked
    org.drain()
    state = client.get("/v1/state").json()
    assert all(iid not in e["item_ids"] for e in state["events"])
    assert event_of(org, keep["item_id"]) and not any(iid in json.dumps(u) for u in state["unfiled"])
    assert org.store.count_items() == 1
    # nothing of it stays on the Spark, even for someone holding the key
    dump = decrypted_dump(org.store.path)
    assert SENTINEL not in dump
    # 410 afterwards, for any revision; a repeated or unknown delete is fine
    assert post(client, dict(gone, revision=9)).status_code == 410
    assert post(client, dict(gone, revision=9)).json() == {"error": "deleted", "item_ids": [iid]}
    assert client.delete(f"/v1/items/{iid}").json() == {"deleted": True}
    assert client.delete("/v1/items/00000000-0000-4000-8000-00000000abcd").json() == {"deleted": True}
    assert post(client, make_item("读书会订房间", item_id="00000000-0000-4000-8000-00000000ABCD")).status_code == 410
    # decisions about it are refused, not applied
    ev = next(iter(events))
    res = client.post("/v1/decisions", json={"decisions": [{"kind": "move_item", "item_id": iid, "to_event_id": ev}]})
    assert res.json()["applied"] == 0


def test_delete_while_the_model_is_reading_writes_nothing_back(org, client, chat):
    shot = make_item(kind="image", image_b64=TINY_PNG_B64)
    post(client, shot)

    def delete_during_the_call(_data):
        client.delete(f"/v1/items/{shot['item_id']}")

    chat.before["image-read"] = delete_during_the_call
    org.drain()
    assert org.store.one("SELECT 1 FROM item_derived WHERE item_id=?", (shot["item_id"],)) is None
    assert org.store.live_events() == [] and org.store.stats()["blob_bytes"] == 0


# ---- read-then-delete -------------------------------------------------------------------------------------


def test_read_then_delete_leaves_no_blob_bytes(org, client, chat):
    shot = make_item(kind="image", image_b64=TINY_PNG_B64)
    doc = F.docx(["咖啡馆合同第三条：押金两万"])
    f = make_item(kind="file", minutes=3)
    f.update(filename="合同.docx", bytes_b64=base64.b64encode(doc).decode(), sha256=hashlib.sha256(doc).hexdigest())
    post(client, shot, f)
    assert client.get("/v1/stats").json()["blob_bytes"] == len(base64.b64decode(TINY_PNG_B64)) + len(doc)
    org.drain()
    stats = client.get("/v1/stats").json()
    assert stats["blob_bytes"] == 0 and stats["derived_bytes"] > 0
    readings = client.get("/v1/state").json()["readings"]
    assert "押金两万" in readings[f["item_id"]]["text"] and readings[shot["item_id"]]["text"]
    assert org.store.get_item(shot["item_id"])["has_image"] == 1  # the row still says it had an image


def test_a_read_that_fails_for_good_deletes_the_bytes_and_marks_the_item_unreadable(org, client, chat):
    def boom(data, schema):
        raise RuntimeError("summary step crashed")

    chat.handlers["file-read"] = boom
    doc = F.docx(["咖啡馆合同第三条：押金两万"])
    f = make_item(kind="file")
    f.update(filename="合同.docx", bytes_b64=base64.b64encode(doc).decode(), sha256=hashlib.sha256(doc).hexdigest())
    post(client, f)
    for _ in range(org.job_max_attempts):
        org.store.x("UPDATE jobs SET not_before=0")
        org.drain()
    job = org.store.one("SELECT state FROM jobs WHERE item_id=?", (f["item_id"],))
    assert job["state"] == "failed" and client.get("/v1/stats").json()["blob_bytes"] == 0
    reading = client.get("/v1/state").json()["readings"][f["item_id"]]
    assert reading["error"] == "unreadable" and reading["text"] == ""


# ---- Spark-side masking ----------------------------------------------------------------------------------


def test_text_read_from_bytes_and_incoming_text_are_masked_before_storage_and_prompts(org, client, chat):
    mask_key = keys.derive_keys(TEST_KEY)[2]
    ph = masking.mask("13812345678", mask_key)[0]
    email = masking.mask("li.mu@example.com", mask_key)[0]
    chat.handlers["image-read"] = image_reader(chat_extraction(
        [{"sender": "李木", "is_self": False, "time": "10:02", "text": "我电话 13812345678，合同发 li.mu@example.com"}],
        "李木留了电话 13812345678"))
    shot = make_item(kind="image", image_b64=TINY_PNG_B64)
    doc = F.docx(["咖啡馆合同，联系人电话 138 1234 5678，邮箱 li.mu@example.com"])
    f = make_item(kind="file", minutes=3)
    f.update(filename="合同.docx", bytes_b64=base64.b64encode(doc).decode(), sha256=hashlib.sha256(doc).hexdigest())
    typed = make_item("咖啡馆的事回电 +86 138-1234-5678，验证码 482913", minutes=6)
    post(client, shot, f, typed)
    org.drain()
    readings = client.get("/v1/state").json()["readings"]
    assert ph in readings[shot["item_id"]]["text"] and ph in readings[shot["item_id"]]["summary"]
    assert readings[shot["item_id"]]["messages"][0]["text"] == f"我电话 {ph}，合同发 {email}"
    assert ph in readings[f["item_id"]]["text"] and email in readings[f["item_id"]]["text"]
    stored = org.store.get_item(typed["item_id"])["text"]
    assert ph in stored and "482913" not in stored and "〔验证码·" in stored  # one number, one placeholder
    # no prompt and no stored row carries the raw numbers
    prompts = json.dumps([c[1] for c in chat.calls], ensure_ascii=False)
    assert "13812345678" not in prompts and "5678" not in prompts and "li.mu@" not in prompts
    dump = decrypted_dump(org.store.path)
    assert "13812345678" not in dump and "1234 5678" not in dump and "li.mu@" not in dump and "482913" not in dump


def test_masking_is_idempotent_on_what_the_mac_already_masked(org, client):
    mask_key = keys.derive_keys(TEST_KEY)[2]
    text = masking.mask("周五前回电 13812345678", mask_key)[0]
    it = make_item(text)
    post(client, it)
    assert org.store.get_item(it["item_id"])["text"] == text


# ---- embedded media (contract section 2, read-then-delete) ------------------------------------------------


def _add_members(zip_bytes: bytes, members: dict) -> bytes:
    buf = io.BytesIO(zip_bytes)
    with zipfile.ZipFile(buf, "a") as zf:
        for name, data in members.items():
            zf.writestr(name, data)
    return buf.getvalue()


def test_embedded_audio_and_video_are_skipped_and_only_counted():
    deck = _add_members(F.pptx([{"title": "发布会", "bullets": ["议程"]}]),
                        {"ppt/media/media1.mp4": b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64,
                         "ppt/media/media2.m4a": b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 64})
    out = fileparse.parse_file(deck, "发布会.pptx")
    assert out["type"] == "slides" and out["media_skipped"] == 2 and "发布会" in out["text"]
    archive = F.zip_of({"说明.txt": "资料说明".encode(), "录音.m4a": b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 64,
                        "clip.avi": b"RIFF\x00\x00\x00\x00AVI LIST", "未知": b"\x00\x00\x00\x18ftypisom" + b"\x00" * 40})
    out = fileparse.parse_file(archive, "资料.zip")
    names = [a["filename"] for a in out["attachments"]]
    assert out["media_skipped"] == 3 and names == ["说明.txt"] and "资料说明" in out["text"]
    mail = F.eml("周报", "见附件", [("voice.mp3", "audio/mpeg", b"ID3\x03fake")])
    out = fileparse.parse_file(mail, "周报.eml")
    assert out["media_skipped"] == 1 and "voice.mp3" not in json.dumps(out, ensure_ascii=False)
    # the reading records only the count
    res = read_file(_Harness(), archive, {"filename": "资料.zip"})
    assert "3 个媒体附件未读取（只在 Mac 上）" in res.text and res.counts["media_skipped"] == 3
    assert "录音.m4a" not in json.dumps(res.reading(), ensure_ascii=False) and "clip.avi" not in res.text


class _Harness:
    """read_file with no model: the summary step is refused (the plain summary is used)."""

    class registry:
        @staticmethod
        def script(skill, name):
            import importlib.util
            spec = importlib.util.spec_from_file_location("fr_validate", REPO / "skills" / "file-read" / "scripts"
                                                          / "validate.py")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod

    def run(self, *a, **k):
        raise ValueError("no model in this test")


def test_every_store_connection_goes_through_one_helper():
    """One place opens connections (organizer/db.py, SQLCipher); nothing else imports sqlite3 for a store."""
    spark = REPO / "spark" / "organizer"
    offenders = []
    for p in spark.rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        if p.name == "db.py":
            assert "from sqlcipher3 import dbapi2 as sqlite3" in src
            continue
        if "sqlite3.connect(" in src and p.name != "textish.py":  # textish: an uploaded .sqlite, in memory
            offenders.append(p.name)
    assert offenders == []
    assert Store(":memory:").masking is False  # never on disk: no key, no masking (eval helpers only)


def test_the_e2e_check_tool_finds_plaintext_and_decrypted_sentinels(org, client, settings, capsys):
    import sys
    sys.path.insert(0, str(REPO / "eval" / "tools"))
    import privacy_check
    it = make_item(f"咖啡馆 {SENTINEL}")
    post(client, it)
    args = ["--data-dir", str(settings.data_dir), "--needle", SENTINEL, "--needle", "没有这句"]
    assert privacy_check.main(args) == 0  # nothing in plaintext on disk
    out = json.loads(capsys.readouterr().out)
    assert out["plaintext_hits"] == {} and out["store_plaintext_header"] is False
    import io as _io
    sys.stdin = _io.StringIO(TEST_KEY.hex() + "\n")
    try:
        assert privacy_check.main(args + ["--key-stdin"]) == 1  # present for the key holder
        out = json.loads(capsys.readouterr().out)
        assert out["decrypted_hits"]["0"]["items"] == 1 and "1" not in out["decrypted_hits"]
        assert SENTINEL not in json.dumps(out, ensure_ascii=False)  # counts and table names only, no content
        client.delete(f"/v1/items/{it['item_id']}")
        sys.stdin = _io.StringIO(TEST_KEY.hex() + "\n")
        assert privacy_check.main(args + ["--key-stdin"]) == 0  # gone after the delete
    finally:
        sys.stdin = sys.__stdin__
