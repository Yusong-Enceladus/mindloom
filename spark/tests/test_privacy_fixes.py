"""Regression tests for the v6 privacy review fixes that tests/test_privacy_review.py does not already prove:
the unlock lease and the access proof (F1), process hardening (F10), run read sets (F5), the sweep of bytes of
replaced revisions in an older store (F7), a Mac-redacted file whose pictures are read (F3), and wipe emptying
the service log with errors logged by type only (F15). Invented content only."""

from __future__ import annotations

import base64
import json
import logging
import os
import subprocess
import sys
import time

import pytest
from fastapi.testclient import TestClient

import filefixtures as F
from conftest import REPO, TEST_KEY, make_item, raw_connect
from organizer import keys
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient, ModelUnavailable, safe_error

SENTINEL = "哨兵MWJK字样"


@pytest.fixture
def served(settings, chat):
    """The deployed service: locked at start, opened by POST /v1/unlock (no access header yet)."""
    settings.unlock_key = None
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org)
    with TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"}) as c:
        c.org = org
        yield c


def unlock(c, key: bytes = TEST_KEY):
    r = c.post("/v1/unlock", json={"key": key.hex()})
    assert r.status_code == 200, r.text
    return r


# ---- F1: the link token alone does not read an unlocked store; the store locks itself ----------------------


def test_after_the_macs_unlock_data_routes_need_the_key_derived_access_proof(served):
    unlock(served)
    # Someone on the Spark account can read the link token file: with it alone nothing is read or written.
    for method, path in (("GET", "/v1/state"), ("GET", "/v1/stats"), ("GET", "/v1/debug/runs"),
                         ("GET", "/v1/inbox"), ("DELETE", "/v1/items/" + make_item("x")["item_id"])):
        r = served.request(method, path)
        assert r.status_code == 403 and r.json() == {"error": "access"}, (method, path)
    r = served.post("/v1/items", json={"items": [make_item(SENTINEL)]})
    assert r.status_code == 403
    wrong = keys.access_proof(bytes([0x55]) * 32)
    assert served.get("/v1/state", headers={"X-Mindloom-Access": wrong}).status_code == 403
    # With the proof (what the Mac sends) everything works; health and the phone's add never need it.
    proof = {"X-Mindloom-Access": keys.access_proof(TEST_KEY)}
    assert served.get("/v1/state", headers=proof).status_code == 200
    assert served.get("/v1/health").status_code == 200
    assert served.post("/v1/inbox", json={"inbox_id": "1b4e28ba-2fa1-11d2-883f-0016d3cca427", "source": "sealed",
                                          "kind": "sealed", "blob": "mlseal1." + "A" * 96,
                                          "received_at": "2026-09-30T10:00:00+08:00"}).status_code == 200
    # Locked again, the proof is dropped with the keys: after a relock nothing passes until the next unlock.
    assert served.post("/v1/lock").json() == {"locked": True}
    assert served.get("/v1/state", headers=proof).status_code == 423


def test_the_synthetic_key_needs_no_proof_because_anyone_can_derive_it(served):
    served.post("/v1/unlock", json={"key": keys.synthetic_library_key().hex()})
    assert served.get("/v1/state").status_code == 200


def test_a_store_the_mac_unlocked_locks_itself_when_the_mac_stops_asking(served):
    org = served.org
    org.unlock_lease_s = 600
    unlock(served)
    proof = {"X-Mindloom-Access": keys.access_proof(TEST_KEY)}
    assert served.get("/v1/state", headers=proof).status_code == 200  # a data request renews the lease
    assert not org.expire_lease(time.monotonic() + 599)
    assert not org.store.locked
    # The Mac quit, slept, crashed or lost the network: no request for longer than the lease.
    assert org.expire_lease(time.monotonic() + 601)
    assert org.store.locked and served.get("/v1/health").json()["locked"] is True
    assert served.get("/v1/state", headers=proof).status_code == 423
    # The Mac's next connect unlocks again (its runtime does this on 423).
    unlock(served)
    assert served.get("/v1/state", headers=proof).status_code == 200


def test_the_worker_loop_applies_the_lease(served):
    org = served.org
    org.unlock_lease_s = 0.05
    unlock(served)
    import threading
    stop = threading.Event()
    t = threading.Thread(target=org.run_worker, args=(stop,), daemon=True)
    t.start()
    try:
        deadline = time.time() + 5
        while time.time() < deadline and not org.store.locked:
            time.sleep(0.02)
        assert org.store.locked
    finally:
        stop.set()
        org.wake()
        t.join(timeout=5)


def test_harness_stores_have_no_lease_and_no_proof(org, client):
    assert org.unlock_lease_s > 0  # the default from settings
    assert not org.expire_lease(time.monotonic() + 10 ** 6)  # opened with settings.unlock_key: no lease
    assert client.get("/v1/state").status_code == 200


# ---- F10: no core dumps, not dumpable -------------------------------------------------------------------


def test_process_hardening_sets_a_hard_zero_core_limit_and_turns_dumping_off():
    code = ("import json, resource, sys; sys.path.insert(0, %r); from organizer.hardening import harden_process;"
            " a = harden_process(); print(json.dumps([a, resource.getrlimit(resource.RLIMIT_CORE)]))"
            % str(REPO / "spark"))
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout
    applied, limit = json.loads(out)
    assert applied["core_limit"] and limit == [0, 0]
    if sys.platform.startswith("linux"):
        assert applied["dumpable_off"]


def test_the_service_entry_point_hardens_the_process_first():
    src = (REPO / "spark" / "organizer" / "__main__.py").read_text(encoding="utf-8")
    main = src[src.index("def main()"):]
    assert main.index("harden_process()") < main.index("create_app(")


# ---- F5: runs are cleared by the items they read, also when the read was in flight -------------------------


def test_a_deleted_candidate_item_clears_other_items_assign_runs_by_read_set(org, client, chat):
    short = make_item("咖啡馆招牌", minutes=0)  # shorter than the 8 characters the text-prefix scrub needs
    later = make_item("咖啡馆菜单周五定下来", minutes=5)
    client.post("/v1/items", json={"items": [short]})
    org.drain()
    seen = []

    def quoting_assign(data, schema):
        from conftest import default_assign
        out = default_assign(data, schema)
        seen.append(data)
        out["evidence"][0]["reason"] = "候选里写着咖啡馆招牌"  # the model quotes the candidate
        return out

    chat.handlers["event-assign"] = quoting_assign
    client.post("/v1/items", json={"items": [later]})
    org.drain()
    assert any("咖啡馆招牌" in json.dumps(d, ensure_ascii=False) for d in seen)
    run = org.store.one("SELECT run_id, read_items FROM runs WHERE subject=? AND job_type='assign'",
                        (later["item_id"],))
    assert short["item_id"] in json.loads(run["read_items"])
    assert client.delete(f"/v1/items/{short['item_id']}").json() == {"deleted": True}
    row = org.store.one("SELECT output FROM runs WHERE run_id=?", (run["run_id"],))
    assert row["output"] is None
    assert all(p["payload"] == "{}" for p in org.store.all("SELECT payload FROM proposals WHERE run_id=?",
                                                          (run["run_id"],)))


def test_an_assign_that_read_an_item_deleted_while_it_ran_keeps_no_content(org, client, chat):
    first = make_item("咖啡馆招牌下周装", minutes=0)
    client.post("/v1/items", json={"items": [first]})
    org.drain()
    second = make_item("咖啡馆菜单周五定下来", minutes=5)
    client.post("/v1/items", json={"items": [second]})
    chat.before["event-assign"] = lambda _data: client.delete(f"/v1/items/{first['item_id']}")
    org.drain()
    run = org.store.one("SELECT output, read_items FROM runs WHERE subject=? AND job_type='assign'",
                        (second["item_id"],))
    assert first["item_id"] in json.loads(run["read_items"]) and run["output"] is None


# ---- F7: an older store's bytes of replaced revisions are swept on open ------------------------------------


def test_opening_a_store_sweeps_bytes_of_revisions_a_later_revision_replaced(settings, chat):
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    shot = make_item(kind="image", image_b64=base64.b64encode(F.png(64, 64)).decode())
    from conftest import ingest
    ingest(org, shot)
    ingest(org, dict(shot, revision=2, image_b64=base64.b64encode(F.png(65, 65)).decode()))
    path = org.store.path
    org.store.lock()
    # What a store written before the fix held: the replaced revision's bytes, never read.
    conn = raw_connect(path)
    conn.execute("INSERT INTO item_blobs(item_id, revision, mime, data) VALUES (?,?,?,?)",
                 (shot["item_id"], 1, "image/png", F.png(64, 64)))
    conn.commit()
    conn.close()
    org.store.unlock(TEST_KEY)
    assert org.store.all("SELECT revision FROM item_blobs WHERE item_id=?", (shot["item_id"],)) == [{"revision": 2}]


# ---- F3: pictures in a file the Mac redacted are read; in any other file they are not -------------------


def test_pictures_in_a_file_the_mac_redacted_are_read_and_others_are_skipped(org, client, chat):
    def file_item(flag):
        data = F.docx(["报销说明，截图见下"], image=F.png(400, 300, "发票"))
        it = make_item(kind="file")
        it.update(filename="报销说明.docx", bytes_b64=base64.b64encode(data).decode(),
                  sha256=__import__("hashlib").sha256(data).hexdigest())
        if flag is not None:
            it["pictures_redacted"] = flag
        return it

    plain, redacted = file_item(None), file_item(True)
    client.post("/v1/items", json={"items": [plain, redacted]})
    org.drain()
    readings = client.get("/v1/state").json()["readings"]
    assert readings[plain["item_id"]]["counts"].get("pictures_skipped") == 1
    assert "1 张图片未读取（未经 Mac 遮盖）" in readings[plain["item_id"]]["text"]
    assert readings[redacted["item_id"]]["counts"].get("images_read") == 1
    assert chat.count("image-read") >= 1


# ---- F15: wipe empties the service's own log; errors are logged by type -------------------------------------


def test_wipe_empties_the_configured_log_file_and_the_process_log(settings, chat, tmp_path):
    log_file = tmp_path / "logs" / "organizer.log"
    log_file.parent.mkdir()
    log_file.write_text("2026-09-30 ids and counts\n", encoding="utf-8")
    settings.log_file = log_file
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    # Run wipe in a child whose stdout is a regular file (how ctl.sh starts the service).
    out_file = tmp_path / "stdout.log"
    code = (
        "import sys; sys.path.insert(0, %r); sys.path.insert(0, %r)\n"
        "from organizer.api import build_organizer\nfrom organizer.config import Settings\n"
        "from organizer.clients import HashEmbedClient\nfrom conftest import FakeChat, TEST_KEY\n"
        "from organizer import keys\nfrom pathlib import Path\n"
        "s = Settings(); s.data_dir = Path(%r); s.skills_dir = Path(%r); s.embed_base_url = ''; s.unlock_key = TEST_KEY\n"
        "org = build_organizer(s, chat=FakeChat(), embedder=HashEmbedClient())\n"
        "print('a line the process wrote before the wipe', flush=True)\n"
        "org.wipe(keys.derive_keys(TEST_KEY)[0])\n"
    ) % (str(REPO / "spark"), str(REPO / "spark" / "tests"), str(tmp_path / "child-data"), str(REPO / "skills"))
    with open(out_file, "ab") as fh:
        subprocess.run([sys.executable, "-c", code], stdout=fh, stderr=fh, check=True)
    assert out_file.read_bytes() == b""
    org.wipe(org.store.disk_key_id())
    assert log_file.read_text(encoding="utf-8") == ""


def test_errors_reach_logs_and_health_by_type_only(served, chat, caplog):
    assert safe_error(ValueError(f"HTTP 400: prompt echo {SENTINEL}")) == "ValueError: HTTP 400"
    assert safe_error(ModelUnavailable(f"connection refused while sending {SENTINEL}")) == "ModelUnavailable"
    unlock(served)
    proof = {"X-Mindloom-Access": keys.access_proof(TEST_KEY)}
    org = served.org

    def failing(data, schema):
        raise RuntimeError(f"parser choked on {SENTINEL}")

    chat.handlers["event-assign"] = failing
    served.post("/v1/items", json={"items": [make_item("咖啡馆菜单周五定下来")]}, headers=proof)
    org.job_max_attempts = 1
    with caplog.at_level(logging.INFO):
        org.drain()
    assert SENTINEL not in caplog.text and "RuntimeError" in caplog.text
    org.last_error = safe_error(RuntimeError(SENTINEL))  # what the worker loop records
    assert served.get("/v1/health").json()["last_error"] == "RuntimeError"
    served.post("/v1/lock")
    assert served.get("/v1/health").json()["last_error"] is None  # nothing while locked
