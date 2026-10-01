"""Test fixtures: a fake chat model (no GPU), a hashing embedder and a synthetic item factory.

All data here is invented for tests.
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

import pytest

from organizer.api import build_organizer, create_app
from organizer.clients import ChatResult, HashEmbedClient
from organizer.config import Settings

REPO = Path(__file__).resolve().parents[2]
TZ = timezone(timedelta(hours=8))
BASE = datetime(2026, 9, 20, 9, 0, tzinfo=TZ)
TOPICS = ["咖啡馆", "读书会", "搬家", "体检"]


def parse_data(messages: list[dict]) -> dict:
    user = messages[1]["content"]
    if isinstance(user, list):
        user = user[-1]["text"]
    m = re.search(r"<data>\n(.*)\n</data>", user, re.S)
    assert m, "user message must wrap material in <data>"
    return json.loads(m.group(1))


def skill_of(messages: list[dict]) -> str:
    return re.search(r"# SKILL: ([a-z-]+) v", messages[0]["content"]).group(1)


def topic_of(text: str) -> Optional[str]:
    return next((t for t in TOPICS if t in text), None)


def candidate_items(cand: dict) -> list[dict]:
    return ([cand["first_item"]] if cand.get("first_item") else []) + list(cand.get("recent_items") or [])


def assign_out(decision: str, event_id: str = "", *, obj: str = "杂事", matter: bool = True,
               judged: Optional[list] = None, reason: str = "测试理由", item_ids: Optional[list] = None) -> dict:
    """A schema-v2 event-assign output (short handles E1/I1 as the model sees them)."""
    return {"item_object": obj, "item_is_matter": matter, "judged": judged or [], "decision": decision,
            "event_id": event_id, "evidence": [{"reason": reason, "item_ids": item_ids or []}]}


def default_assign(data: dict, schema: dict) -> dict:
    topic = topic_of(data["item"]["text"])
    for cand in data["candidates"]:
        for it in candidate_items(cand):
            if topic and topic in it["text"]:
                return assign_out("attach", cand["event_id"], obj=topic,
                                  judged=[{"event_id": cand["event_id"], "match": "same_object"}],
                                  reason=f"都在说{topic}", item_ids=[it["item_id"]])
    return assign_out("new", obj=topic or "杂事", reason="没有候选是同一件事")


_RELATIVE = re.compile(r"今天|今日|明天|明日|后天|昨天|前天|本周|这周|下周|上周|周末|(?:周|星期)[一二三四五六日天]")


def default_brief(data: dict, schema: dict) -> dict:
    items = data["items"]
    topic = next((topic_of(i["text"]) for i in items if topic_of(i["text"])), None)
    last = items[-1]
    snippet = _RELATIVE.sub("", re.sub(r"[。！？!?；;，,\s]", "", last["text"]))[:20] or "有新进展"
    return {"title": f"{topic or '杂事'}安排",
            "status_facts": [{"text": snippet, "state": "info", "date": "", "quote": "", "item_ids": [last["item_id"]]}],
            "status_line": f"最新进展是{snippet}。", "off_anchor_item_ids": []}


def default_rank(data: dict, schema: dict) -> dict:
    return {"ranking": [{"event_id": e["event_id"], "importance": 0.5 + 0.01 * min(e["item_count"], 9),
                         "reason": "测试排序"} for e in data["events"]]}


def default_consolidate(data: dict, schema: dict) -> dict:
    """event-consolidate: keep every small event as it is (tests that need a merge or an unfile push outputs)."""
    first = data["small"]["items"][0]
    text = first["text"].replace("…", "")[:20] or "素材"
    return {"small_object": "测试事件", "small_is_matter": True, "candidate": "", "relation": "none", "reason": "测试保留",
            "verdict": "own_matter", "target": "", "quote": {"item_id": first["item_id"], "text": text}}


def default_person(data: dict, schema: dict) -> dict:
    """person-resolve: every record is a person with an ordinary name, the same as nobody (tests that need
    another verdict push outputs)."""
    return {"kind": "person", "same_as": "", "common_word": False, "reason": "测试：是人"}


def is_detect_step(schema: dict) -> bool:
    """image-read's first step asks only for the image type."""
    return set(schema.get("properties", {})) == {"type"}


def image_reader(extraction: dict, image_type: str = "chat_screenshot") -> Callable[[dict, dict], dict]:
    """An image-read handler: the type for step 1, `extraction` for step 2."""
    return lambda data, schema: {"type": image_type} if is_detect_step(schema) else extraction


def chat_extraction(messages: list[dict], gist: str, title: str = "") -> dict:
    return {"chat_title": title, "is_group": False, "gist": gist,
            "messages": [{"kind": "text", **m} for m in messages]}


default_image = image_reader(chat_extraction(
    [{"sender": "张三", "is_self": False, "time": "10:02", "text": "咖啡馆豆子报价每公斤120"},
     {"sender": "我", "is_self": True, "time": "10:05", "text": "好的"}], "张三发来咖啡馆豆子报价", "张三"))


def default_split(data: dict, schema: dict) -> dict:
    """One segment per run of units about the same test topic; units with no topic are skipped."""
    matters: list[str] = []
    segments: list[dict] = []
    for unit in data["units"]:
        topic = topic_of(unit["text"])
        if topic is None:
            continue
        if topic not in matters:
            matters.append(topic)
        m = matters.index(topic) + 1
        if segments and segments[-1]["matter"] == m and segments[-1]["_last"] == data["units"].index(unit) - 1:
            segments[-1]["to"] = unit["u"]
            segments[-1]["_last"] += 1
            continue
        segments.append({"from": unit["u"], "to": unit["u"], "matter": m, "gist": f"{topic}的安排",
                         "_last": data["units"].index(unit)})
    for seg in segments:
        seg.pop("_last")
    return {"matters": matters, "segments": segments}


def default_file_read(data: dict, schema: dict) -> dict:
    """file-read: the first line of the file's text as its summary (its numbers are in the text)."""
    first = next((ln for ln in data["text"].splitlines() if re.sub(r"[#|>*\-\s]", "", ln)), "")
    return {"summary": re.sub(r"[#|>*]", "", first).strip()[:40] or "文件", "doc_kind": "other", "fields": []}


class FakeChat:
    """Scripted stand-in for the vLLM endpoint. Records every call."""

    model_id = "fake-model"

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict, dict, list]] = []
        self.queued: dict[str, list] = {}
        self.handlers: dict[str, Callable[[dict, dict], dict]] = {
            "event-assign": default_assign,
            "event-brief": default_brief,
            "home-rank": default_rank,
            "image-read": default_image,
            "item-split": default_split,
            "file-read": default_file_read,
            "event-consolidate": default_consolidate,
            "person-resolve": default_person,
        }
        self.before: dict[str, Callable[[dict], None]] = {}

    def push(self, skill: str, *outputs) -> None:
        self.queued.setdefault(skill, []).extend(outputs)

    def complete(self, messages, schema, schema_name, max_tokens) -> ChatResult:
        skill = skill_of(messages)
        data = parse_data(messages)
        self.calls.append((skill, data, schema, messages))
        if skill in self.before:
            self.before.pop(skill)(data)
        if self.queued.get(skill):
            out = self.queued[skill].pop(0)
        else:
            out = self.handlers[skill](data, schema)
        text = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
        return ChatResult(text=text, model=self.model_id, prompt_tokens=10, completion_tokens=5)

    def count(self, skill: str) -> int:
        return sum(1 for c in self.calls if c[0] == skill)


_counter = {"n": 0}


def make_item(text: Optional[str] = None, *, minutes: int = 0, kind: str = "dictation", app: str = "备忘录",
              bundle: Optional[str] = "com.apple.Notes", persons: Optional[list[dict]] = None,
              segments: Optional[list[dict]] = None, item_id: Optional[str] = None, revision: int = 1,
              image_b64: Optional[str] = None) -> dict:
    _counter["n"] += 1
    started = BASE + timedelta(minutes=minutes)
    item = {
        "item_id": item_id or str(uuid.uuid4()).upper(),
        "revision": revision,
        "kind": kind,
        "source_app": {"bundle_id": bundle, "name": app},
        "started_at": started.isoformat(),
        "ended_at": (started + timedelta(minutes=1)).isoformat(),
        "sha256": f"{_counter['n']:064x}",
    }
    if text is not None:
        item["text"] = text
    if persons is not None:
        item["persons"] = persons
    if segments is not None:
        item["segments"] = segments
    if image_b64 is not None:
        item["image_b64"] = image_b64
    return item


TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


# The library key of every test store (synthetic data): the store is encrypted with it and unlocked at start.
TEST_KEY = bytes([0x42]) * 32


def raw_connect(path):
    """A connection straight to a test store's encrypted file (to simulate a database written by an older
    version); opened with the test key's store key, through the one connection helper."""
    from organizer import db, keys
    return db.connect(path, keys.derive_keys(TEST_KEY)[1], isolation_level="")


@pytest.fixture
def settings(tmp_path) -> Settings:
    s = Settings()
    s.data_dir = tmp_path / "data"
    s.skills_dir = REPO / "skills"
    s.start_worker = False
    s.embed_base_url = ""
    s.unlock_key = TEST_KEY
    return s


@pytest.fixture
def chat() -> FakeChat:
    return FakeChat()


@pytest.fixture
def org(settings, chat):
    return build_organizer(settings, chat=chat, embedder=HashEmbedClient())


@pytest.fixture
def client(settings, org):
    from fastapi.testclient import TestClient

    app = create_app(settings, organizer=org)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield c


def auth_headers(app) -> dict:
    return {"Authorization": f"Bearer {app.state.link_token}"}


def ingest(org, *items: dict) -> tuple[int, int]:
    from organizer.schemas import Item

    parsed = [Item.model_validate(i) for i in items]
    dicts, images = [], []
    for it in parsed:
        d = it.model_dump(mode="json", exclude={"image_b64", "bytes_b64"})
        d["started_at"] = it.started_at.isoformat()
        d["ended_at"] = it.ended_at.isoformat() if it.ended_at else None
        d["captured_at"] = it.captured_at.isoformat() if it.captured_at else None
        dicts.append(d)
        images.append(it.blob())
    return org.ingest(dicts, images)


def event_of(org, item_id: str) -> Optional[str]:
    link = org.store.current_event_link(item_id)
    return link["event_id"] if link else None
