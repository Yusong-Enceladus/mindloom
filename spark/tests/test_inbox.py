"""Contract C: the phone inbox (POST/GET/ack) and the zhiji-inbox CLI. Invented content only."""

from __future__ import annotations

import base64

from conftest import TINY_PNG_B64, auth_headers
from organizer import inbox_cli

WHEN = "2026-09-21T08:15:00+08:00"


def test_inbox_add_list_ack(client):
    r = client.post("/v1/inbox", json={"source": "iPhone", "kind": "text", "text": "周五前把展位图纸发给场馆",
                                       "received_at": WHEN})
    assert r.status_code == 200 and not r.json()["duplicate"]
    first = r.json()["inbox_id"]
    r = client.post("/v1/inbox", json={"source": "iPhone", "kind": "image", "image_b64": TINY_PNG_B64,
                                       "received_at": WHEN})
    second = r.json()["inbox_id"]
    got = client.get("/v1/inbox", params={"since": 0}).json()
    assert [i["inbox_id"] for i in got["items"]] == [first, second]
    assert got["items"][0]["text"] == "周五前把展位图纸发给场馆" and got["items"][0]["received_at"] == WHEN
    assert got["items"][1]["image_b64"] == TINY_PNG_B64 and got["items"][1]["kind"] == "image"
    assert got["pending"] == 2 and client.get("/v1/health").json()["inbox_pending"] == 2
    # cursor: nothing newer than the last seen entry
    assert client.get("/v1/inbox", params={"since": got["cursor"]}).json()["items"] == []
    # ack drops the content; a repeated ack is fine; an unknown id is 404
    assert client.post(f"/v1/inbox/{first}/ack").json() == {"ok": True, "acked": True, "already": False}
    assert client.post(f"/v1/inbox/{first}/ack").json()["already"] is True
    assert client.post("/v1/inbox/00000000-0000-0000-0000-000000000000/ack").status_code == 404
    row = client.app.state.organizer.store.one("SELECT text, image, acked FROM inbox WHERE inbox_id=?", (first,))
    assert row == {"text": None, "image": None, "acked": 1}
    left = client.get("/v1/inbox", params={"since": 0}).json()
    assert [i["inbox_id"] for i in left["items"]] == [second] and left["pending"] == 1
    # inbox entries are not items: nothing is organized on the Spark until the Mac sends it back as an item
    assert client.get("/v1/health").json()["items"] == 0


def test_inbox_pages_stop_at_a_byte_budget(client, monkeypatch):
    from organizer import api
    monkeypatch.setattr(api, "INBOX_PAGE_BYTES", 150)
    png = base64.b64decode(TINY_PNG_B64)
    big = base64.b64encode(png + b"\0" * 100).decode()  # 170 bytes: over the budget on its own
    ids = [client.post("/v1/inbox", json={"source": "iPhone", "kind": "image", "image_b64": big,
                                          "received_at": WHEN}).json()["inbox_id"] for _ in range(2)]
    ids.append(client.post("/v1/inbox", json={"source": "iPhone", "kind": "text", "text": "短的一条",
                                              "received_at": WHEN}).json()["inbox_id"])
    seen, since = [], 0
    for _ in range(5):
        page = client.get("/v1/inbox", params={"since": since}).json()
        if not page["items"]:
            break
        assert len(page["items"]) == 1 or sum(len(base64.b64decode(i["image_b64"] or "")) for i in page["items"]) <= 150
        seen += [i["inbox_id"] for i in page["items"]]
        since = page["cursor"]
    assert seen == ids  # every entry arrives once, in order, one oversized image per page


def test_inbox_retry_with_the_same_id_is_a_duplicate(client):
    body = {"inbox_id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", "source": "iPhone", "kind": "text",
            "text": "买两卷封箱胶带", "received_at": WHEN}
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is False
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is True
    client.post("/v1/inbox/1b4e28ba-2fa1-11d2-883f-0016d3cca427/ack")
    assert client.post("/v1/inbox", json=body).json()["duplicate"] is True  # also after the ack


def test_inbox_rejects_bad_input(client):
    assert client.post("/v1/inbox", json={"source": "iPhone", "kind": "text", "text": "  ",
                                          "received_at": WHEN}).status_code == 422
    assert client.post("/v1/inbox", json={"source": "iPhone", "kind": "image",
                                          "image_b64": base64.b64encode(b"GIF89a....").decode(),
                                          "received_at": WHEN}).status_code == 422
    assert client.post("/v1/inbox", json={"source": "iPhone", "kind": "text", "text": "x",
                                          "received_at": "2026-09-21T08:15:00"}).status_code == 422


def test_inbox_needs_the_token(client):
    from fastapi.testclient import TestClient

    with TestClient(client.app) as anon:
        assert anon.get("/v1/inbox").status_code == 401
        assert anon.post("/v1/inbox", json={}).status_code == 401


def test_cli_add_text_and_image(client, capsys):
    assert inbox_cli.main(["add", "--source", "iPhone"], stdin="场馆说展位电费另算\n".encode(), client=client) == 0
    assert "已收进织机" in capsys.readouterr().out
    b64_stdin = base64.b64encode(base64.b64decode(TINY_PNG_B64)) + b"\n"
    assert inbox_cli.main(["add", "--source", "iPad", "--image", "-", "--json"], stdin=b64_stdin, client=client) == 0
    assert '"duplicate": false' in capsys.readouterr().out
    items = client.get("/v1/inbox").json()["items"]
    assert [(i["source"], i["kind"]) for i in items] == [("iPhone", "text"), ("iPad", "image")]
    assert items[0]["text"] == "场馆说展位电费另算\n"
    assert inbox_cli.main(["add"], stdin=b"   ", client=client) == 1
    assert inbox_cli.main(["status"], client=client) == 0
    assert "2 条" in capsys.readouterr().out


def test_cli_without_a_running_organizer(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ORGANIZER_DATA_DIR", str(tmp_path))
    monkeypatch.delenv("ORGANIZER_UDS", raising=False)
    assert inbox_cli.main(["add"], stdin=b"hello") == 2
    assert "socket not found" in capsys.readouterr().err


def test_gate_only_allows_add_and_status():
    ok = inbox_cli.gate_argv
    assert ok("zhiji-inbox add --source iPhone") == ["add", "--source", "iPhone"]
    assert ok("/home/u/spark/zhiji-inbox add --source iPhone --image - --json")[-1] == "--json"
    assert ok("zhiji-inbox status") == ["status"]
    for bad in ("", "rm -rf ~", "zhiji-inbox add --image /etc/passwd", "zhiji-inbox add --source",
                "zhiji-inbox add; cat ~/.ssh/id_rsa", "zhiji-inbox add --text hi", "bash -c 'zhiji-inbox status'",
                "zhiji-inbox add --source 'a\"b"):
        assert ok(bad) is None, bad


def test_gate_runs_the_allowed_command(client, monkeypatch, capsys):
    monkeypatch.setenv("SSH_ORIGINAL_COMMAND", "zhiji-inbox add --source iPhone")
    assert inbox_cli.main(["gate"], stdin="从手机分享的一段话".encode(), client=client) == 0
    assert client.get("/v1/inbox").json()["items"][0]["text"] == "从手机分享的一段话"
    monkeypatch.setenv("SSH_ORIGINAL_COMMAND", "cat /etc/passwd")
    assert inbox_cli.main(["gate"], stdin=b"", client=client) == 1
