import httpx
import pytest

from conftest import event_of, ingest, make_item
from organizer.clients import ModelUnavailable, OpenAIChatClient
from organizer.decisions import apply_decision


def test_health_rechecks_a_cached_model_after_server_stops(client, org):
    online = [True]

    def serve(request):
        if not online[0]:
            raise httpx.ConnectError("server stopped", request=request)
        return httpx.Response(200, json={"data": [{"id": "local-model"}]})

    chat = OpenAIChatClient("http://127.0.0.1:8000/v1")
    chat._http.close()
    chat._http = httpx.Client(base_url="http://127.0.0.1:8000/v1", transport=httpx.MockTransport(serve))
    org.harness.client = chat
    assert client.get("/v1/health").json()["ok"] is True
    online[0] = False
    assert client.get("/v1/health").json()["ok"] is False
    chat._http.close()


def test_removed_source_cannot_write_a_stale_summary(org, chat):
    a = make_item("咖啡馆菜单先定下来")
    b = make_item("咖啡馆老板说预算八万", minutes=5)
    ingest(org, a, b)
    org.drain()
    eid = event_of(org, a["item_id"])
    chat.before["event-brief"] = lambda _: apply_decision(
        org, {"kind": "remove_item", "event_id": eid, "item_id": b["item_id"]}
    )
    org.brief(eid)
    assert org.store.get_event(eid)["needs_brief"] == 1
    assert org.store.one("SELECT status FROM proposals WHERE kind='brief' ORDER BY proposal_id DESC")["status"] == "superseded"
    org.drain()
    assert "八万" not in org.store.get_event(eid)["status_line"]


def test_revised_source_invalidates_inflight_summary(org, chat):
    a = make_item("咖啡馆预算八万")
    ingest(org, a)
    org.drain()
    eid = event_of(org, a["item_id"])
    chat.before["event-brief"] = lambda _: ingest(org, dict(a, revision=2, text="咖啡馆预算改为六万"))
    org.brief(eid)
    assert org.store.get_event(eid)["needs_brief"] == 1
    org.drain()
    assert "六万" in org.store.get_event(eid)["status_line"]


def test_json_null_is_retried_and_audited(org, chat):
    valid = {"ranking": [{"event_id": "E1", "importance": 0.5, "reason": "近期事项"}]}
    chat.push("home-rank", "null", valid)
    result = org.harness.run("rank", {"events": []}, context={"event_ids": ["E1"]})
    assert result.ok and result.attempts == 2


def test_permanent_chat_error_is_audited(org, chat):
    def fail(*args, **kwargs):
        raise ValueError("HTTP 400: unsupported response format")

    chat.complete = fail
    with pytest.raises(ValueError):
        org.harness.run("rank", {"events": []})
    run = org.store.recent_runs(1)[0]
    assert not run["ok"] and "client_error" in run["error"]
