"""Shared by eval/run_eval.py and eval/run_eval_overnight.py (synthetic scenarios only).

- snapshot(org, item_ids): /v1/state plus eval-only fields, identical for both drivers: item_persons,
  every question ever asked (with status, day_key, provisional placement and the target's members at
  ask time), questions_asked_total, and assign_log (what the organizer did with each assign output).
- GoldAnswerer: answers open same_event questions from gold labels right after each item, so an ask can
  be scored as answered. Always report the unanswered run next to it: real users answer late or never.
- CachedChat: record/replay of model calls keyed by the exact request, to re-score deterministically or
  bisect a divergence without the shared vLLM server's batch nondeterminism. Never use it to report a
  new model's quality.
- gold_rank_views: home-rank input built from gold events at a checkpoint (--rank-gold), to measure
  ranking independently of clustering.
- strip_skill_text: the without-skills ablation shared by both drivers (run_eval.py --condition
  without-skills, run_eval_overnight.py --mode without-skills).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Optional

from organizer.clients import ChatResult


def snapshot(org, item_ids: list[str], state: Optional[dict] = None) -> dict:
    state = dict(state if state is not None else org.state(0))
    state["store_id"] = org.store.store_id
    state["item_persons"] = [{"item_id": iid, "person_id": pid}
                             for iid in item_ids for pid in org.people.item_person_ids(iid)]
    qs = org.store.all("SELECT question_id, kind, a, b, status, prompt_zh, created_at, day_key, provisional,"
                       " b_items_at_ask, answer FROM questions ORDER BY q_seq, question_id")
    for q in qs:
        for key in ("provisional", "b_items_at_ask"):
            if q.get(key):
                q[key] = json.loads(q[key])
    state["questions"] = qs
    state["questions_asked_total"] = len(qs)
    log = []
    for p in org.store.all("SELECT target_id, payload, status, reason FROM proposals WHERE kind='assign'"
                           " ORDER BY proposal_id"):
        payload = json.loads(p["payload"])
        derived = payload.get("derived") or {}
        log.append({"item_id": p["target_id"], "action": derived.get("action") or payload.get("decision")
                    or payload.get("rule"), "provisional": derived.get("provisional", ""),
                    "status": p["status"], "reason": p["reason"] or ""})
    state["assign_log"] = log
    return state


def strip_skill_text(org) -> None:
    """Without-skills ablation: same model, data, schemas (guided decoding), retrieval, validators, retry
    and output budgets; every skill's SKILL.md body and references/ text are replaced by a one-line task
    name. The global rules and the output schema stay in the system prompt."""
    from organizer.skills import GLOBAL_RULES

    for skill in org.registry.skills.values():
        skill.system_prompt = (GLOBAL_RULES + "\nTask: " + skill.name +
                               "\nReturn the requested JSON using only the input data.\n" +
                               json.dumps(skill.schema, ensure_ascii=False))
        skill.prompt_hash = hashlib.sha256(skill.system_prompt.encode()).hexdigest()[:16]


class GoldAnswerer:
    """Answers open same_event questions (item, event) from gold labels: yes iff the item's gold events
    intersect the majority gold event of the target's members at ask time."""

    def __init__(self, scenario: dict):
        noise = {e["event_id"] for e in scenario["events"] if e.get("kind") == "noise"}
        self.labels = {it["item_id"].lower(): set(it.get("events", [])) - noise for it in scenario["items"]}
        self.answered = 0

    def _majority(self, item_ids: list[str]) -> Optional[str]:
        counts: dict[str, int] = {}
        for i in item_ids:
            for g in self.labels.get(i.lower(), ()):
                counts[g] = counts.get(g, 0) + 1
        return max(sorted(counts), key=lambda g: counts[g]) if counts else None

    def answer_open(self, org) -> int:
        from organizer.decisions import answer_question

        n = 0
        for q in org.store.open_questions():
            if q["kind"] != "same_event":
                continue
            members = json.loads(q["b_items_at_ask"]) if q.get("b_items_at_ask") else org.store.event_item_ids(q["b"])
            maj = self._majority([m for m in members if m != q["a"]])
            if maj is None:
                continue
            if q["a"].lower() in self.labels:           # item vs event
                truth = maj in self.labels[q["a"].lower()]
            elif org.store.get_event(q["a"]):             # event vs event (merge proposal)
                truth = self._majority(org.store.event_item_ids(q["a"])) == maj
            else:
                continue
            answer_question(org, q["question_id"], truth)
            n += 1
        self.answered += n
        return n


class CachedChat:
    """Wraps a chat client. Replays a recorded output for an identical request, records misses."""

    def __init__(self, inner, cache_dir: str | Path):
        self.inner = inner
        self.dir = Path(cache_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.hits = self.misses = 0

    @property
    def model_id(self) -> str:
        return self.inner.model_id

    def key(self, messages, schema, schema_name, max_tokens) -> str:
        blob = json.dumps([self.inner.model_id, messages, schema, schema_name, max_tokens], ensure_ascii=False,
                          sort_keys=True)
        return hashlib.sha256(blob.encode()).hexdigest()

    def complete(self, messages, schema, schema_name, max_tokens) -> ChatResult:
        path = self.dir / f"{self.key(messages, schema, schema_name, max_tokens)}.json"
        if path.exists():
            self.hits += 1
            return ChatResult(**json.loads(path.read_text(encoding="utf-8")))
        self.misses += 1
        res = self.inner.complete(messages, schema, schema_name, max_tokens)
        path.write_text(json.dumps({"text": res.text, "model": res.model, "prompt_tokens": res.prompt_tokens,
                                    "completion_tokens": res.completion_tokens}, ensure_ascii=False),
                        encoding="utf-8")
        return res

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)


def gold_rank_views(scenario: dict, cp: dict) -> tuple[list[dict], dict[str, str], str]:
    """home-rank input for the gold events present at a checkpoint: title from the scenario, status line
    and dated facts from the checkpoint's expected facts, times from the gold items. Returns
    (views, handle -> gold event id, now)."""
    items = sorted(scenario["items"], key=lambda it: it["t"])
    upto = next(i for i, it in enumerate(items) if it["item_id"].lower() == cp["after_item_id"].lower())
    seen = items[: upto + 1]
    now = seen[-1]["t"]
    facts = {f["fact_id"]: f for f in scenario.get("facts", [])}
    ev_meta = {e["event_id"]: e for e in scenario["events"] if e.get("kind") != "noise"}
    views, handles = [], {}
    for n, (eid, ev) in enumerate(ev_meta.items(), 1):
        mine = [it for it in seen if eid in it.get("events", [])]
        if not mine:
            continue
        exp = [facts[f] for f in cp.get("expected", {}).get(eid, [])]
        h = f"E{n}"
        handles[h] = eid
        dates = sorted({f["date"] for f in exp if f.get("date")})
        views.append({
            "event_id": h, "title": ev.get("title", eid),
            "status_line": "，".join(f["text"] for f in exp)[:54] or ev.get("summary", "")[:54],
            "status_facts": [{"text": f["text"], "state": f.get("state", "info"), "date": f.get("date", "")} for f in exp],
            "dates": {"upcoming": [d for d in dates if d >= now[:10]], "past": [d for d in dates if d < now[:10]]},
            "started_at": mine[0]["t"], "updated_at": mine[-1]["t"], "item_count": len(mine),
            "kinds": {}, "person_count": len({p for it in mine for p in it.get("persons", [])} - {scenario["owner_person_id"]}),
            "pinned": False, "feature_less": False, "user_touches": 0,
        })
    return views, handles, now
