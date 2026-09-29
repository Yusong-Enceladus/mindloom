import base64

from conftest import TINY_PNG_B64, auth_headers, make_item


def test_health_reports_model_skills_and_counts(client):
    body = client.get("/v1/health").json()
    assert body["ok"] is True and body["model"] == "fake-model"
    names = {s["name"] for s in body["skills"]}
    assert {"event-assign", "event-brief", "home-rank", "image-read"} <= names
    assert body["items"] == 0 and body["events"] == 0


def test_health_is_not_ready_when_chat_model_is_unavailable(settings):
    from fastapi.testclient import TestClient
    from organizer.api import build_organizer, create_app
    from organizer.clients import ModelUnavailable

    class DownChat:
        @property
        def model_id(self):
            raise ModelUnavailable("connection refused")

    org = build_organizer(settings, chat=DownChat())
    app = create_app(settings, organizer=org)
    with TestClient(app, headers=auth_headers(app)) as client:
        body = client.get("/v1/health").json()
    assert body["ok"] is False and body["model"] is None


def test_items_endpoint_is_idempotent(client):
    it = make_item("咖啡馆菜单")
    assert client.post("/v1/items", json={"items": [it]}).json() == {"accepted": 1, "duplicates": 0}
    assert client.post("/v1/items", json={"items": [it, it]}).json() == {"accepted": 0, "duplicates": 2}


def test_items_endpoint_validates_input(client):
    bad_id = make_item("x", item_id="not-a-uuid")
    assert client.post("/v1/items", json={"items": [bad_id]}).status_code == 422
    naive = make_item("x")
    naive["started_at"] = "2026-09-20T09:00:00"
    assert client.post("/v1/items", json={"items": [naive]}).status_code == 422
    gif = make_item(kind="image", image_b64=base64.b64encode(b"GIF89a....").decode())
    assert client.post("/v1/items", json={"items": [gif]}).status_code == 422
    empty = make_item(None)
    assert client.post("/v1/items", json={"items": [empty]}).status_code == 422
    ok_img = make_item(kind="image", image_b64=TINY_PNG_B64)
    assert client.post("/v1/items", json={"items": [ok_img]}).status_code == 200


def test_state_cursor_decisions_and_questions_flow(client, org):
    a = make_item("咖啡馆菜单", minutes=0)
    b = make_item("读书会书目", minutes=5)
    client.post("/v1/items", json={"items": [a, b]})
    org.drain()
    s1 = client.get("/v1/state").json()
    assert {"cursor", "events", "questions", "persons"} <= set(s1)
    assert len(s1["events"]) == 2
    ev = s1["events"][0]
    for key in ("event_id", "title", "title_user_edited", "status_line", "status_facts", "importance",
                "started_at", "updated_at", "item_ids", "person_ids", "pinned", "deleted"):
        assert key in ev
    s2 = client.get(f"/v1/state?since={s1['cursor']}").json()
    assert s2["events"] == []
    r = client.post("/v1/decisions", json={"decisions": [
        {"kind": "rename_event", "event_id": ev["event_id"], "title": "我的标题"},
        {"kind": "pin_event", "event_id": "missing", "pinned": True},
    ]}).json()
    assert r["applied"] == 1 and r["rejected"][0]["index"] == 1
    s3 = client.get(f"/v1/state?since={s1['cursor']}").json()
    assert [e["event_id"] for e in s3["events"]] == [ev["event_id"]]
    assert s3["events"][0]["title"] == "我的标题" and s3["events"][0]["title_user_edited"] is True
    assert client.post("/v1/decisions", json={"decisions": [{"kind": "nope"}]}).status_code == 422
    assert client.post("/v1/questions/unknown/answer", json={"answer": True}).status_code == 404


def test_debug_runs_lists_skill_runs(client, org):
    client.post("/v1/items", json={"items": [make_item("咖啡馆菜单")]})
    org.drain()
    runs = client.get("/v1/debug/runs").json()["runs"]
    assert runs and all(r["skill"] and r["prompt_hash"] and r["model"] == "fake-model" for r in runs)


def test_background_worker_processes_items(settings, org):
    import time

    from fastapi.testclient import TestClient

    from organizer.api import create_app

    settings.start_worker = True
    app = create_app(settings, organizer=org)
    with TestClient(app, headers=auth_headers(app)) as c:
        c.post("/v1/items", json={"items": [make_item("咖啡馆菜单"), make_item("咖啡馆招牌", minutes=3)]})
        deadline = time.time() + 10
        while time.time() < deadline:
            state = c.get("/v1/state").json()
            if state["events"] and all(e["title"] for e in state["events"]) and c.get("/v1/health").json()["queue"] == 0:
                break
            time.sleep(0.05)
        assert len(state["events"]) == 1 and state["events"][0]["title"] == "咖啡馆安排"
