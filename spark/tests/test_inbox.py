"""Contract C: the phone inbox (POST/GET/ack) and the zhiji-inbox CLI. Invented content only.

Only sealed entries are accepted (phone contract section 5; the plaintext iOS Shortcut path is retired because
it cannot seal). The wire strings here are sealed-shaped only: the Spark never opens one, so it cannot tell.
"""

from __future__ import annotations

import base64

from conftest import TINY_PNG_B64
from organizer import inbox_cli, sealed

WHEN = "2026-09-21T08:15:00+08:00"
ID_A = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
ID_B = "6fa459ea-ee8a-3ca4-894e-db77e160355e"
ID_C = "0f8fad5b-d9cb-469f-a165-70867728950e"


def wire(n_bytes: int, fill: bytes = b"\x5a") -> str:
    return sealed.PREFIX + base64.urlsafe_b64encode(fill * n_bytes).decode().rstrip("=")


def entry(entry_id: str, blob: str, **over) -> dict:
    body = {"inbox_id": entry_id, "source": "sealed", "kind": "sealed", "blob": blob, "received_at": WHEN}
    body.update(over)
    return body


def test_inbox_add_list_ack(client):
    w1, w2 = wire(64, b"\x01"), wire(96, b"\x02")
    r = client.post("/v1/inbox", json=entry(ID_A, w1))
    assert r.status_code == 200 and r.json() == {"ok": True, "id": ID_A, "inbox_id": ID_A, "duplicate": False}
    client.post("/v1/inbox", json=entry(ID_B, w2))
    got = client.get("/v1/inbox", params={"since": 0}).json()
    assert [i["inbox_id"] for i in got["items"]] == [ID_A, ID_B]
    assert got["items"][0] == {"inbox_id": ID_A, "kind": "sealed", "blob": w1, "received_at": WHEN,
                               "seq": got["items"][0]["seq"]}
    assert got["pending"] == 2 and client.get("/v1/health").json()["inbox_pending"] == 2
    # cursor: nothing newer than the last seen entry
    assert client.get("/v1/inbox", params={"since": got["cursor"]}).json()["items"] == []
    # ack drops the content; a repeated ack is fine; an unknown id is 404
    assert client.post(f"/v1/inbox/{ID_A}/ack").json() == {"ok": True, "acked": True, "already": False}
    assert client.post(f"/v1/inbox/{ID_A}/ack").json()["already"] is True
    assert client.post("/v1/inbox/00000000-0000-0000-0000-000000000000/ack").status_code == 404
    row = client.app.state.organizer.inbox.one(ID_A)
    assert (row["text"], row["image"], row["blob"], row["acked"]) == (None, None, None, 1)
    left = client.get("/v1/inbox", params={"since": 0}).json()
    assert [i["inbox_id"] for i in left["items"]] == [ID_B] and left["pending"] == 1
    # inbox entries are not items: nothing is organized on the Spark until the Mac sends it back as an item
    assert client.get("/v1/health").json()["items"] == 0


def test_inbox_pages_stop_at_a_byte_budget(client, monkeypatch):
    from organizer import api
    monkeypatch.setattr(api, "INBOX_PAGE_BYTES", 150)
    big = wire(128)  # 179 characters: over the budget on its own
    ids = [ID_A, ID_B, ID_C]
    for n, eid in enumerate(ids):
        assert client.post("/v1/inbox", json=entry(eid, big if n < 2 else wire(64))).status_code == 200
    seen, since = [], 0
    for _ in range(5):
        page = client.get("/v1/inbox", params={"since": since}).json()
        if not page["items"]:
            break
        assert len(page["items"]) == 1 or sum(len(i["blob"]) for i in page["items"]) <= 150
        seen += [i["inbox_id"] for i in page["items"]]
        since = page["cursor"]
    assert seen == ids  # every entry arrives once, in order, one oversized entry per page


def test_inbox_retry_with_the_same_id_is_a_duplicate(client):
    body = entry(ID_A, wire(64))
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is False
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is True
    client.post(f"/v1/inbox/{ID_A}/ack")
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is True  # also after the ack


def test_inbox_refuses_plaintext_and_bad_input(client):
    """Plaintext shares (the retired Shortcut kinds) are refused and never echoed; so is a malformed entry."""
    for body in ({"source": "iPhone", "kind": "text", "text": "周五前把展位图纸发给场馆", "received_at": WHEN},
                 {"source": "iPhone", "kind": "image", "image_b64": TINY_PNG_B64, "received_at": WHEN},
                 entry(ID_A, wire(64), text="周五前把展位图纸发给场馆"),
                 entry(ID_A, wire(64), received_at="2026-09-21T08:15:00"),
                 entry(ID_A.upper(), wire(64)), entry(ID_A, "plain text, not sealed")):
        r = client.post("/v1/inbox", json=body)
        assert r.status_code == 422 and "展位图纸" not in r.text and TINY_PNG_B64 not in r.text, body
    assert client.get("/v1/inbox").json()["items"] == []


def test_inbox_needs_the_token(client):
    from fastapi.testclient import TestClient

    with TestClient(client.app) as anon:
        assert anon.get("/v1/inbox").status_code == 401
        assert anon.post("/v1/inbox", json={}).status_code == 401


def test_cli_adds_only_sealed_entries(client, capsys):
    w = wire(64)
    assert inbox_cli.main(["add", "--sealed", "--id", ID_A], stdin=(w + "\n").encode(), client=client) == 0
    assert "已收进织机" in capsys.readouterr().out
    assert [i["blob"] for i in client.get("/v1/inbox").json()["items"]] == [w]
    # the retired plaintext path: refused before anything is sent
    assert inbox_cli.main(["add", "--source", "iPhone"], stdin="场馆说展位电费另算\n".encode(), client=client) == 1
    assert capsys.readouterr().out == ""  # no --json: the refusal goes to stderr only
    assert inbox_cli.main(["add", "--image", "-", "--json"], stdin=TINY_PNG_B64.encode(), client=client) == 1
    assert '"not_sealed"' in capsys.readouterr().out
    assert len(client.get("/v1/inbox").json()["items"]) == 1
    assert inbox_cli.main(["status"], client=client) == 0
    assert "1 条" in capsys.readouterr().out


def test_cli_without_a_running_organizer(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ORGANIZER_DATA_DIR", str(tmp_path))
    monkeypatch.delenv("ORGANIZER_UDS", raising=False)
    assert inbox_cli.main(["add", "--sealed", "--id", ID_A], stdin=wire(64).encode()) == 2
    assert "socket not found" in capsys.readouterr().err


def test_gate_only_allows_sealed_add_and_status():
    ok = inbox_cli.gate_argv
    assert ok(f"zhiji-inbox add --sealed --id {ID_A}") == ["add", "--sealed", "--id", ID_A]
    assert ok(f"/home/u/spark/zhiji-inbox add --sealed --id {ID_A} --json")[-1] == "--json"
    assert ok("zhiji-inbox status") == ["status"]
    for bad in ("", "rm -rf ~", "zhiji-inbox add --image /etc/passwd", "zhiji-inbox add --source",
                "zhiji-inbox add; cat ~/.ssh/id_rsa", "zhiji-inbox add --text hi", "bash -c 'zhiji-inbox status'",
                "zhiji-inbox add --source 'a\"b", "zhiji-inbox add --source iPhone", "zhiji-inbox add --image - --json",
                f"zhiji-inbox add --id {ID_A}", "zhiji-inbox add --sealed"):
        assert ok(bad) is None, bad


def test_gate_runs_the_allowed_command(client, monkeypatch, capsys):
    w = wire(64)
    monkeypatch.setenv("SSH_ORIGINAL_COMMAND", f"zhiji-inbox add --sealed --id {ID_A}")
    assert inbox_cli.main(["gate"], stdin=w.encode(), client=client) == 0
    assert client.get("/v1/inbox").json()["items"][0]["blob"] == w
    for cmd in ("cat /etc/passwd", "zhiji-inbox add --source iPhone"):
        monkeypatch.setenv("SSH_ORIGINAL_COMMAND", cmd)
        assert inbox_cli.main(["gate"], stdin="从手机分享的一段话".encode(), client=client) == 1
    assert len(client.get("/v1/inbox").json()["items"]) == 1
