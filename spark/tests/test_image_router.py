"""Image router: chat screenshots to StepFun Step3-VL, every other kind to the organizer's own model.

The type step (one short request to the organizer's model) is the classifier; the preset
ORGANIZER_IMAGE_ROUTER=stepfun-chat maps chat_screenshot to Step3-VL. A routed endpoint that is down or rejects a
request, or whose extraction fails the validator twice, is read again by the organizer's model. Counts only.

All data here is invented for tests.
"""

from __future__ import annotations

import json
import logging

import pytest

from conftest import REPO, TEST_KEY, FakeChat, chat_extraction, image_reader, is_detect_step
from organizer import image_router
from organizer.api import build_organizer
from organizer.clients import ChatResult, ModelUnavailable
from organizer.config import Settings
from organizer.image_read import read_image
from organizer.image_router import FallbackClient, RouteStats, preset_routes
from organizer.skills import SkillRegistry

READING = SkillRegistry(REPO / "skills").script("image-read", "reading")
CTX = {"source_app": "", "captured_at": "2026-03-07T09:00:00+08:00"}
PNG = b"\x89PNG...."

CHAT = chat_extraction(
    [{"sender": "许言", "is_self": False, "time": "10:02", "text": "周六来吗"},
     {"sender": "我", "is_self": True, "time": "10:05", "text": "来，带上相机"}], "许言约周六见面", "许言")
CHART = {"chart_type": "bar", "title": "季度销量", "x_label": "季度", "y_label": "件", "unit": "件", "kpis": [],
         "series": [{"name": "", "trend": "up", "points": [{"category": "Q1", "value": "10"},
                                                            {"category": "Q2", "value": "20"}]}],
         "gist": "两个季度的销量在上升"}


class Qwen(FakeChat):
    model_id = "qwen3.6-test"


class Step3(FakeChat):
    """Stands in for Step3LlamaNativeClient."""
    model_id = "step3-vl-test"
    down = False
    reject = False

    def __init__(self, url: str = "", model: str = "auto", timeout: float = 0.0):
        super().__init__()
        self.url = url

    def complete(self, messages, schema, schema_name, max_tokens) -> ChatResult:
        if self.down:
            raise ModelUnavailable("refused")
        if self.reject:
            raise ValueError("HTTP 400: bad image")
        return super().complete(messages, schema, schema_name, max_tokens)


@pytest.fixture
def rig(tmp_path, monkeypatch):
    import organizer.api as api

    made: list[Step3] = []

    class Made(Step3):
        def __init__(self, *a, **kw):
            super().__init__(*a, **kw)
            made.append(self)

    monkeypatch.setattr(api, "Step3LlamaNativeClient", Made)
    main = Qwen()
    settings = Settings(data_dir=tmp_path, start_worker=False, image_router="stepfun-chat", unlock_key=TEST_KEY)
    org = build_organizer(settings, chat=main, embedder=None)
    step3 = made[0]
    # The type step answers by the image: PNG bytes carry the kind in the test through the handler below.
    kind = {"now": "chat_screenshot"}
    main.handlers["image-read"] = lambda d, s: {"type": kind["now"]} if is_detect_step(s) else CHART
    step3.handlers["image-read"] = lambda d, s: CHAT
    return org, main, step3, kind


def read(org, **kw):
    return read_image(org.harness, PNG, CTX, clients=org.image_clients, stats=org.image_route_stats, **kw)


def test_the_preset_is_chat_only_and_unknown_presets_are_refused():
    assert preset_routes("") == {}
    routes = preset_routes("stepfun-chat", "http://127.0.0.1:30001")
    assert list(routes) == ["chat_screenshot"] and routes["chat_screenshot"]["backend"] == "step3-llama-native"
    assert set(routes) <= set(READING.TYPES)
    with pytest.raises(ValueError):
        preset_routes("everything-to-step3")


def test_the_preset_routes_only_chat_screenshots_and_keeps_a_fallback(rig):
    org, main, step3, _ = rig
    assert set(org.image_clients) == {"chat_screenshot"}
    routed = org.image_clients["chat_screenshot"]
    assert isinstance(routed, FallbackClient) and routed.primary is step3 and routed.fallback is main
    assert step3.url == "http://127.0.0.1:30001"


def test_a_chat_screenshot_is_read_by_step3_and_a_chart_by_the_organizers_model(rig):
    org, main, step3, kind = rig
    res = read(org)
    assert res.ok and res.image_type == "chat_screenshot" and not res.rerouted
    assert res.detect_model == "qwen3.6-test" and res.extract_model == "step3-vl-test"
    assert [m["sender"] for m in res.reading["messages"]] == ["许言", "我"]
    assert step3.count("image-read") == 1 and main.count("image-read") == 1      # the type step only

    kind["now"] = "chart_dashboard"
    res = read(org)
    assert res.ok and res.image_type == "chart_dashboard" and res.extract_model == "qwen3.6-test"
    assert step3.count("image-read") == 1 and main.count("image-read") == 3      # type, then type + chart

    assert org.image_route_stats.snapshot() == {
        "reads": {"chart_dashboard": {"qwen3.6-test": 1}, "chat_screenshot": {"step3-vl-test": 1}},
        "rerouted": {}, "fallbacks": {}}


@pytest.mark.parametrize("failure,reason", [("down", "unavailable"), ("reject", "rejected")])
def test_a_routed_endpoint_that_is_down_or_rejects_falls_back_to_the_organizers_model(rig, failure, reason):
    org, main, step3, _ = rig
    setattr(step3, failure, True)
    main.handlers["image-read"] = image_reader(CHAT)
    res = read(org)
    assert res.ok and res.extract_model == "qwen3.6-test" and not res.rerouted
    snap = org.image_route_stats.snapshot()
    assert snap["reads"] == {"chat_screenshot": {"qwen3.6-test": 1}}
    (only,) = snap["fallbacks"]["chat_screenshot"].items()
    assert only[0].startswith(reason) and only[1] == 1


def test_an_extraction_that_fails_validation_twice_is_read_again_by_the_organizers_model(rig):
    org, main, step3, _ = rig
    step3.handlers["image-read"] = lambda d, s: {"chat_title": "只有标题"}    # not a valid chat extraction
    main.handlers["image-read"] = image_reader(CHAT)
    res = read(org)
    assert res.ok and res.rerouted and res.extract_model == "qwen3.6-test" and res.sanitized == 0
    assert [r.ok for r in res.runs] == [True, False, True]                    # type, step3 (2 attempts), qwen
    assert step3.count("image-read") == 2                                      # the validator's one retry
    assert org.image_route_stats.snapshot()["rerouted"] == {"chat_screenshot": 1}


def test_without_a_preset_nothing_is_routed_and_the_counts_still_name_the_model(tmp_path):
    main = Qwen()
    main.handlers["image-read"] = image_reader(CHAT)
    org = build_organizer(Settings(data_dir=tmp_path, start_worker=False, unlock_key=TEST_KEY), chat=main, embedder=None)
    assert org.image_clients == {}
    assert read(org).extract_model == "qwen3.6-test"
    assert org.image_route_stats.snapshot()["reads"] == {"chat_screenshot": {"qwen3.6-test": 1}}


def test_explicit_routes_win_over_the_preset_and_stay_loopback_only(tmp_path, monkeypatch):
    import organizer.api as api

    class Rec(Step3):
        pass

    monkeypatch.setattr(api, "Step3LlamaNativeClient", Rec)
    routes = {"chat_screenshot": {"url": "http://127.0.0.1:31111", "backend": "step3-llama-native"}}
    s = Settings(data_dir=tmp_path, start_worker=False, image_router="stepfun-chat", image_routes=json.dumps(routes),
                 unlock_key=TEST_KEY)
    org = build_organizer(s, chat=Qwen(), embedder=None)
    assert org.image_clients["chat_screenshot"].primary.url == "http://127.0.0.1:31111"
    with pytest.raises(ValueError):
        build_organizer(Settings(data_dir=tmp_path, start_worker=False, image_router="stepfun-chat",
                                 step3_url="http://10.0.0.5:30001", unlock_key=TEST_KEY), chat=Qwen(), embedder=None)


def test_fallback_can_be_turned_off_and_the_env_flag_is_read(tmp_path, monkeypatch):
    monkeypatch.setenv("ORGANIZER_IMAGE_ROUTE_FALLBACK", "0")
    assert Settings().image_route_fallback is False
    monkeypatch.setenv("ORGANIZER_IMAGE_ROUTE_FALLBACK", "1")
    assert Settings().image_route_fallback is True
    monkeypatch.delenv("ORGANIZER_IMAGE_ROUTE_FALLBACK")
    assert Settings().image_route_fallback is None
    s = Settings(data_dir=tmp_path, start_worker=False, image_router="stepfun-chat", image_route_fallback=False,
                 unlock_key=TEST_KEY)
    org = build_organizer(s, chat=Qwen(), embedder=None)
    assert not isinstance(org.image_clients["chat_screenshot"], FallbackClient)


def test_counts_and_log_lines_carry_no_content(rig, caplog):
    org, main, step3, _ = rig
    secret = "哨兵ZX-ROUTER-5521"
    step3.handlers["image-read"] = lambda d, s: chat_extraction(
        [{"sender": "许言", "is_self": False, "time": "10:02", "text": secret}], "含哨兵的聊天", "许言")
    with caplog.at_level(logging.INFO, logger="organizer.image_router"):
        assert read(org).ok
    text = json.dumps(org.image_route_stats.snapshot(), ensure_ascii=False) + "\n".join(r.getMessage() for r in caplog.records)
    assert "kind=chat_screenshot" in text and "model=step3-vl-test" in text
    assert "哨兵" not in text and "许言" not in text


def test_route_stats_are_thread_safe_counters():
    import threading

    stats = RouteStats()
    threads = [threading.Thread(target=lambda: [stats.record_read("slide", "m") for _ in range(200)]) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert stats.snapshot()["reads"] == {"slide": {"m": 1600}}


def test_the_infra_health_reports_the_counts(rig, tmp_path, monkeypatch):
    from types import SimpleNamespace

    from organizer.infra import InfraProbe
    from organizer.spaces import Spaces
    from spacekit import Clock

    org, *_ = rig
    read(org)
    probe = InfraProbe(Settings(data_dir=tmp_path), org, Spaces(tmp_path / "s", now=Clock()),
                       SimpleNamespace(_orgs={}, unlocked_count=lambda: 0),
                       SimpleNamespace(stats=lambda: {}), run=lambda *a, **k: None, http=lambda url: (200, {"data": []}),
                       meminfo=lambda: {"MemTotal": 1, "MemAvailable": 1})
    assert probe.organizer()["image_reads"]["reads"] == {"chat_screenshot": {"step3-vl-test": 1}}
