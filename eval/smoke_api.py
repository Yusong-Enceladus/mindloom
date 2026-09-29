#!/usr/bin/env python3
"""Exercise a NEW demo API with fictional text, replay, and user correction."""
import argparse
import hashlib
import json
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse

import httpx


def main():
    p = argparse.ArgumentParser(description=__doc__)
    where = p.add_mutually_exclusive_group(required=True)
    where.add_argument("--uds", help="the instance's Unix socket (<data_dir>/organizer.sock) on the "
                       "Spark itself; the organizer serves no TCP port by default")
    where.add_argument("--url", help="a loopback URL, e.g. the Mac end of an SSH forward to the socket")
    p.add_argument("--out", required=True)
    p.add_argument("--token-file", help="the instance's link_token (e.g. <data_dir>/link_token); "
                   "omit only for an instance started with ORGANIZER_REQUIRE_TOKEN=0")
    a = p.parse_args()
    if a.url and urlparse(a.url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        p.error("use a loopback URL or an SSH tunnel")
    headers = {}
    if a.token_file:
        headers["Authorization"] = "Bearer " + Path(a.token_file).read_text(encoding="ascii").strip()
    transport = httpx.HTTPTransport(uds=a.uds) if a.uds else None
    base_url = "http://organizer" if a.uds else a.url
    with httpx.Client(base_url=base_url, transport=transport, timeout=15, trust_env=False,
                      headers=headers) as c:
        health = c.get("/v1/health").raise_for_status().json()
        if not health["ok"] or health["items"]:
            raise RuntimeError("requires a ready, empty demo instance; refusing existing data")
        started = time.monotonic()
        texts = [
            "林姐委托我做火锅店扫码点单小程序，计划9月30日上线，预算八千元。",
            "和林姐确认了火锅店扫码点单小程序的首页和菜单样式，支付功能周一联调。",
            "读书会改到10月3日晚上七点，地点是图书馆二楼，小周负责订房间。",
            "林姐确认火锅店扫码点单小程序预算改为六千元，9月30日先上线点单，支付推迟到第二期。",
        ]
        items = [{"item_id": str(uuid.uuid4()), "revision": 0, "kind": "text",
                  "source_app": {"name": "虚构演示"}, "started_at": f"2026-09-26T10:{i:02d}:00+08:00",
                  "text": text, "sha256": hashlib.sha256(text.encode()).hexdigest()}
                 for i, text in enumerate(texts)]
        accepted = c.post("/v1/items", json={"items": items}).raise_for_status().json()
        replay = c.post("/v1/items", json={"items": items}).raise_for_status().json()
        assert accepted == {"accepted": 4, "duplicates": 0}
        assert replay == {"accepted": 0, "duplicates": 4}
        deadline = time.monotonic() + 180
        previous, stable = None, 0
        while time.monotonic() < deadline:
            state = c.get("/v1/state").raise_for_status().json()
            jobs = c.get("/v1/debug/jobs").raise_for_status().json()["jobs"]
            if any(j["state"] == "failed" for j in jobs):
                raise RuntimeError(jobs)
            if len(jobs) == 4 and all(j["state"] == "done" for j in jobs) and state["events"]:
                stable = stable + 1 if state["cursor"] == previous else 0
                if stable >= 3:
                    break
            previous = state["cursor"]
            time.sleep(1)
        else:
            raise TimeoutError("demo did not settle")
        live = [e for e in state["events"] if not e["deleted"]]
        business = next(e for e in live if items[0]["item_id"] in e["item_ids"])
        assert all(items[i]["item_id"] in business["item_ids"] for i in (1, 3))
        assert items[2]["item_id"] not in business["item_ids"]
        assert "六千" in business["status_line"] or "6000" in business["status_line"]
        decision = {"kind": "rename_event", "decision_id": str(uuid.uuid4()),
                    "event_id": business["event_id"], "title": "国庆前上线（演示）"}
        responses = [c.post("/v1/decisions", json={"decisions": [decision]}).raise_for_status().json()
                     for _ in range(2)]
        assert all(r == {"applied": 1, "rejected": []} for r in responses)
        final = c.get("/v1/state").raise_for_status().json()
        assert next(e for e in final["events"] if e["event_id"] == business["event_id"])["title"] == decision["title"]
        result = {"seconds": time.monotonic() - started, "health": health, "accepted": accepted,
                  "replay": replay, "decisions": responses, "state_before_rename": state,
                  "state": final, "runs": c.get("/v1/debug/runs?limit=100").json()["runs"],
                  "synthetic_data_only": True}
        Path(a.out).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"passed": True, "seconds": result["seconds"], "events": len(live),
                          "status_line": business["status_line"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
