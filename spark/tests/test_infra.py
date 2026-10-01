"""v8 B2: GET /v1/infra/health for the admin console (organizer/infra.py): organizer, model servers, GPU memory,
disk; numbers and states only, never content. Synthetic data; nvidia-smi and the model servers are faked."""

from __future__ import annotations

import json
import subprocess
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from conftest import ingest, make_item
from organizer import infra
from organizer.api import create_app
from organizer.infra import InfraProbe
from organizer.spaces import Spaces
from spacekit import Clock, Mac
from test_access import MemberClient, gate_program, join_member, rig  # noqa: F401 (fixtures)

SENTINEL = "哨兵ZX-INFRA-7781 合成会议纪要"


def fake_run(unified: bool):
    def run(argv, **kw):
        if "--query-compute-apps=used_memory" in argv:
            return subprocess.CompletedProcess(argv, 0, "26809\n64556\n6206\n", "")
        mem = "[N/A], [N/A]" if unified else "1200, 81920"
        return subprocess.CompletedProcess(argv, 0, f"NVIDIA GB10, 3, 50, 12.36, {mem}\n", "")
    return run


def probe(settings, org, tmp_path, *, unified=True, chat_up=True, embed_up=False):
    spaces = Spaces(tmp_path / "s", now=Clock())
    space_orgs = SimpleNamespace(_orgs={}, unlocked_count=lambda: 0)
    access = SimpleNamespace(stats=lambda: {"members_active": 2, "devices_active": 3, "tickets_open": 1})

    def http(url):
        if ":8000" in url:
            return (200, {"data": [{"id": "qwen-test"}]}) if chat_up else (503, {})
        if embed_up:
            return 200, {"data": [{"id": "embed-test"}]}
        raise infra.httpx.ConnectError("refused")
    settings.llm_base_url = "http://127.0.0.1:8000/v1"
    settings.embed_base_url = "http://127.0.0.1:8013/v1"
    return InfraProbe(settings, org, spaces, space_orgs, access, run=fake_run(unified), http=http,
                      meminfo=lambda: {"MemTotal": 124610, "MemAvailable": 1530})


def test_health_reports_unified_gpu_memory_models_and_disk(settings, org, tmp_path, monkeypatch):
    monkeypatch.setattr(infra.shutil, "which", lambda name: "/usr/bin/nvidia-smi")
    h = probe(settings, org, tmp_path).health()
    assert h["models"][0] == {"role": "chat", "port": 8000, "up": True, "model": "qwen-test",
                              "latency_ms": h["models"][0]["latency_ms"]}
    assert h["models"][1]["role"] == "embed" and h["models"][1]["up"] is False
    gpu = h["gpu"]
    assert gpu["gpus"][0]["name"] == "NVIDIA GB10" and gpu["gpus"][0]["memory_total_mib"] is None
    assert gpu["unified_memory"] == {"total_mib": 124610, "available_mib": 1530, "gpu_processes_mib": 97571}
    assert set(h["warnings"]) == {"embed_down", "memory_low"} and h["ok"] is True
    assert h["disk"]["free_gb"] is not None and h["disk"]["data_bytes"] >= 0
    assert h["organizer"]["access"]["members_active"] == 2 and h["organizer"]["personal_store"]["locked"] is False


def test_a_discrete_gpu_and_a_down_chat_model(settings, org, tmp_path, monkeypatch):
    monkeypatch.setattr(infra.shutil, "which", lambda name: "/usr/bin/nvidia-smi")
    h = probe(settings, org, tmp_path, unified=False, chat_up=False, embed_up=True).health()
    assert h["gpu"]["gpus"][0]["memory_total_mib"] == 81920 and "unified_memory" not in h["gpu"]
    assert h["warnings"] == ["chat_down"] and h["ok"] is False
    monkeypatch.setattr(infra.shutil, "which", lambda name: None)
    p = probe(settings, org, tmp_path)
    assert p.health()["gpu"] is None


def test_health_is_cached_and_carries_no_content(settings, org, tmp_path, monkeypatch):
    monkeypatch.setattr(infra.shutil, "which", lambda name: "/usr/bin/nvidia-smi")
    ingest(org, make_item(SENTINEL + " 咖啡馆", minutes=1))
    org.drain()
    calls = []
    p = probe(settings, org, tmp_path)
    run = p.run
    p.run = lambda argv, **kw: calls.append(argv) or run(argv, **kw)
    h1 = p.health()
    h2 = p.health()
    assert h1 is h2 and len(calls) == 2          # one query-gpu and one compute-apps call, then the cache
    text = json.dumps(h1, ensure_ascii=False)
    assert "哨兵" not in text and "咖啡馆" not in text and "ZX-INFRA" not in text
    assert "pid" not in text


def test_the_route_is_for_the_owner_and_admins(rig):  # noqa: F811 (fixture from test_access)
    owner = rig["owner"]
    r = owner.get("/v1/infra/health")
    assert r.status_code == 200 and {"organizer", "models", "gpu", "disk", "warnings"} <= set(r.json())
    device, member_id, out, mc = join_member(rig)
    r = mc.get("/v1/infra/health")
    assert r.status_code == 403
    mac = Mac(mc, rig["clock"])
    mac.device, mac.member_id = device, member_id
    mac.create_org()                       # now an org admin with this Mac
    r = mc.get("/v1/infra/health")
    assert r.status_code == 200          # (the answer is the cached one: 15 s)
    rig["app"].state.infra._cached = None
    assert mc.get("/v1/infra/health").json()["organizer"]["access"]["devices_active"] == 1
