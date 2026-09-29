"""Contract D (concurrent model calls, deterministic outcome) and E (scale): fake model, invented data."""

from __future__ import annotations

import json
import random
import re
import threading
import time
import tracemalloc
from datetime import timedelta
from typing import Optional

import pytest

from conftest import (BASE, TINY_PNG_B64, FakeChat, assign_out, candidate_items, default_brief, ingest, make_item)
from organizer.api import build_organizer
from organizer.clients import HashEmbedClient

# ---- a fake model with per-skill latency (thread-safe) ---------------------------------------------


class SlowChat(FakeChat):
    def __init__(self, latency: Optional[dict] = None, jitter: float = 0.0, seed: int = 0):
        super().__init__()
        self.latency = latency or {}
        self.jitter = jitter
        self._rng = random.Random(seed)
        self._lock = threading.Lock()
        self.active = 0
        self.max_active = 0

    def complete(self, messages, schema, schema_name, max_tokens):
        with self._lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            delay = self.latency.get(re.search(r"# SKILL: ([a-z-]+) v", messages[0]["content"]).group(1), 0.0)
            if self.jitter:
                delay += self._rng.random() * self.jitter
        try:
            if delay:
                time.sleep(delay)
            with self._lock:
                return super().complete(messages, schema, schema_name, max_tokens)
        finally:
            with self._lock:
                self.active -= 1


TOPIC_WORDS = ["咖啡馆", "读书会", "搬家", "体检"]
MULTI = ("韩青禾(00:00:03):\n大家好，先等一下人。\n\n杜远舟(00:00:40):\n先说{a}，{a}那边下周二开始，预算控制在三万以内，"
         "具体的人手我来排。\n\n韩青禾(00:02:10):\n{a}的事记得拍照给我。\n\n杜远舟(00:03:30):\n第二件事是{b}，{b}这边报了"
         "两千八，周六上午九点到，钥匙放物业。\n\n韩青禾(00:04:50):\n{b}那天我不在，你帮我盯一下。\n\n杜远舟(00:06:05):\n好的，"
         "今天就到这。\n")


def stream(n: int, seed: int = 1) -> list[dict]:
    """Invented items over the four test topics: dictations, pasted chats, screenshots and multi-matter
    meeting transcripts (which item-split cuts)."""
    rng = random.Random(seed)
    items = []
    for i in range(n):
        a, b = rng.sample(TOPIC_WORDS, 2)
        r = rng.random()
        if r < 0.1:
            items.append(make_item(text=MULTI.format(a=a, b=b), minutes=i * 7, kind="text", app="腾讯会议"))
        elif r < 0.18:
            items.append(make_item(minutes=i * 7, kind="image", app="微信", image_b64=TINY_PNG_B64))
        elif r < 0.3:
            items.append(make_item(text=f"周经理：{a}的尾款下周结\n我：好的", minutes=i * 7, kind="text", app="微信"))
        else:
            items.append(make_item(text=f"关于{a}：第{i}次记录，明天继续跟进。", minutes=i * 7, kind="dictation"))
    return items


def fingerprint(org) -> dict:
    """Event ids are random UUIDs: compare the partition of (item, segment) units plus each card."""
    st = org.state(0)
    events = []
    for e in st["events"]:
        if e["deleted"]:
            continue
        units = sorted([f"{s['item_id']}#{s['seg_id']}" for s in e["segments"]]
                       + [i for i in e["item_ids"] if not any(s["item_id"] == i for s in e["segments"])])
        events.append((tuple(units), e["title"], e["status_line"], json.dumps(e["status_facts"], ensure_ascii=False,
                                                                            sort_keys=True)))
    return {"events": sorted(events),
            "unfiled": sorted(json.dumps({k: v for k, v in u.items() if k != "since"}, sort_keys=True)
                              for u in st["unfiled"]),
            "questions": sorted(q["prompt_zh"] for q in st["questions"]),
            "persons": sorted(p["display_name"] or "" for p in st["persons"])}


def make_org(settings, chat, workers: int, lag: int = 2):
    settings.workers = workers
    settings.pipeline_lag = lag
    settings.clock = "replay"
    return build_organizer(settings, chat=chat, embedder=HashEmbedClient())


def run(org, items) -> float:
    ingest(org, *items)
    t0 = time.perf_counter()
    org.drain()
    return time.perf_counter() - t0


# ---- D: determinism and throughput ----------------------------------------------------------------


def test_pipeline_outcome_does_not_depend_on_pool_size_or_timing(settings, tmp_path):
    items = stream(80)
    prints = []
    for workers, seed in ((2, 1), (6, 2), (6, 3)):
        settings.data_dir = tmp_path / f"d{workers}-{seed}"
        org = make_org(settings, SlowChat(jitter=0.004, seed=seed), workers)
        run(org, items)
        prints.append(fingerprint(org))
        assert org.pipeline.pending == deque_empty() and not org.pipeline.inflight
        assert org.store.one("SELECT 1 FROM events WHERE needs_brief=1 AND deleted=0") is None
        assert org.store.queue_depth() == 0
    assert prints[0] == prints[1] == prints[2]
    assert any("#s" in u for e in prints[0]["events"] for u in e[0])  # meetings were split


def deque_empty():
    from collections import deque
    return deque()


def test_pipeline_matches_serial_when_briefs_do_not_feed_back(settings, tmp_path):
    """With a model whose event-assign ignores titles and status lines, the lag changes nothing: the
    pipeline files every item exactly as the serial organizer does."""
    items = stream(50, seed=4)
    prints = []
    for workers in (1, 4):
        settings.data_dir = tmp_path / f"w{workers}"
        org = make_org(settings, SlowChat(jitter=0.002, seed=workers), workers)
        run(org, items)
        prints.append(fingerprint(org)["events"])
    assert [e[0] for e in prints[0]] == [e[0] for e in prints[1]]


def test_pipeline_is_at_least_twice_as_fast_as_serial(settings, tmp_path):
    latency = {"event-assign": 0.02, "event-brief": 0.04, "item-split": 0.03, "image-read": 0.02,
               "home-rank": 0.03}
    items = stream(40, seed=5)
    times = {}
    for workers in (1, 4):
        settings.data_dir = tmp_path / f"t{workers}"
        chat = SlowChat(latency)
        org = make_org(settings, chat, workers)
        times[workers] = run(org, items)
        if workers > 1:
            assert chat.max_active >= 2
    assert times[1] / times[4] >= 2.0, times


def test_user_decision_during_a_pipelined_brief_wins(settings, tmp_path):
    from organizer.decisions import apply_decision

    settings.data_dir = tmp_path / "dec"
    chat = SlowChat({"event-brief": 0.05})
    org = make_org(settings, chat, 3)
    a = make_item(text="咖啡馆吧台下周二拆", minutes=0)
    b = make_item(text="咖啡馆吧台的预算三万", minutes=5)
    ingest(org, a, b)
    org.step()  # item a assigned; its brief is launched, not applied
    org.step()  # item b
    ev = org.store.current_event_link(b["item_id"])["event_id"]
    assert apply_decision(org, {"kind": "remove_item", "event_id": ev, "item_id": b["item_id"]})[0]
    org.drain()
    st = org.state(0)
    live = [e for e in st["events"] if not e["deleted"]]
    card = next(e for e in live if a["item_id"] in e["item_ids"])
    assert b["item_id"] not in card["item_ids"]
    assert all(b["item_id"] not in f["item_ids"] for f in card["status_facts"])


# ---- E: a long stream --------------------------------------------------------------------------------


def scale_stream(n: int, topics: int, seed: int = 7) -> list[dict]:
    rng = random.Random(seed)
    syll = "青柳松石云溪竹月星河山海风林泉岚舟桥晴雪霜春秋夏冬梅兰菊桂"
    names = []
    while len(names) < topics:
        w = "".join(rng.sample(syll, 3))
        if w not in names:
            names.append(w)
    filler = ["明天", "确认", "报价", "时间", "对一下", "发给我", "下午", "安排", "已经", "还要", "看看", "资料"]
    items = []
    for i in range(n):
        t = names[(i * 7919 + rng.randrange(3)) % topics] if rng.random() < 0.8 else names[i % topics]
        words = " ".join(rng.sample(filler, 4))
        items.append(make_item(text=f"「{t}计划」{words}，编号{t}。", minutes=i * 11, kind="dictation"))
    return items


def scale_assign(data: dict, schema: dict) -> dict:
    m = re.search(r"「(.+?)计划」", data["item"]["text"])
    code = m.group(1) if m else None
    for cand in data["candidates"]:
        for it in candidate_items(cand):
            if code and f"「{code}计划」" in it["text"]:
                return assign_out("attach", cand["event_id"], obj=code,
                                  judged=[{"event_id": cand["event_id"], "match": "same_object"}],
                                  reason="同一个计划", item_ids=[it["item_id"]])
    return assign_out("new", obj=code or "杂事", reason="没有同一个计划")


def scale_brief(data: dict, schema: dict) -> dict:
    out = default_brief(data, schema)
    m = re.search(r"「(.+?)计划」", data["items"][0]["text"])
    out["title"] = f"{m.group(1) if m else '杂事'}计划"
    return out


@pytest.mark.parametrize("workers", [1, 4])
def test_thousand_item_stream(settings, tmp_path, workers):
    settings.data_dir = tmp_path / f"scale{workers}"
    settings.rank_max_events = 30
    chat = FakeChat() if workers == 1 else SlowChat()
    chat.handlers["event-assign"] = scale_assign
    chat.handlers["event-brief"] = scale_brief
    org = make_org(settings, chat, workers)
    items = scale_stream(1000, topics=240)
    trace = workers > 1  # tracemalloc slows everything down; one variant is enough for the memory bound
    if trace:
        tracemalloc.start()
    ingest(org, *items)
    step_times = []
    while True:
        t0 = time.perf_counter()
        if not org.step():
            break
        step_times.append(time.perf_counter() - t0)
    peak = tracemalloc.get_traced_memory()[1] if trace else 0
    if trace:
        tracemalloc.stop()
    assert org.store.queue_depth() == 0 and org.store.count_items() == 1000
    st = org.state(0)
    live = [e for e in st["events"] if not e["deleted"]]
    # retrieval stays top-k over hundreds of events and still finds the right one
    by_code: dict[str, set] = {}
    for e in live:
        by_code.setdefault(e["title"], set()).add(e["event_id"])
    assert 200 <= len(live) <= 260, len(live)
    assert sum(len(v) - 1 for v in by_code.values()) <= 0.1 * len(live)  # duplicated events (hash embedder)
    # home-rank: the model ranked a shortlist only; the rest are ordered by recency (<= 0.3)
    rank_calls = [c for c in chat.calls if c[0] == "home-rank"]
    assert rank_calls and max(len(c[1]["events"]) for c in rank_calls) == 30
    assert sum(1 for e in live if e["importance"] <= 0.3) >= len(live) - 30
    # questions budget unchanged at scale
    assert sum(1 for q in st["questions"] if q["kind"] == "same_event") <= settings.max_open_questions
    # memory and per-item time stay bounded
    assert peak < 200 * 1024 * 1024, peak
    early = sum(step_times[:150]) / 150
    late = sum(step_times[-150:]) / 150
    assert late < 5 * early + 0.01, (early, late)
