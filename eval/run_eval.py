#!/usr/bin/env python3
"""Feed a synthetic scenario through the organizer and write /v1/state snapshots at its checkpoints.

The organizer runs in-process behind its real FastAPI app (POST /v1/items, GET /v1/state via
TestClient); the background worker is replaced by an explicit drain after every item, so items are
organized one at a time in time order, the way the Mac would send them live.

Conditions (--condition):
  skills    the organizer as shipped: SKILL.md + references + global rules + schema-guided JSON
            decoding + scripts/validate.py with one retry.
  without-skills
            ablation: same model, pipeline, retrieval, input data, schemas (guided decoding),
            scripts/validate.py, retry and output budgets as skills; only each SKILL.md body and its
            references/ text are replaced by a one-line task name (eval_common.strip_skill_text, the same
            function as run_eval_overnight.py --mode without-skills). Global rules and schema stay.
  bare      ablation: same model, same pipeline, same retrieval (candidates.py) and the same input
            data, but every model job gets only a bare task description naming the output fields.
            No SKILL.md, no global rules, no schema (no guided decoding), no validate.py, no retry.
            Output that is not parseable JSON with the fields the pipeline reads counts as a failure.
  baseline  no LLM. event-assign = attach to the top retrieval candidate when its candidates.py
            score >= --threshold, else start a new event. No titles or status lines, no screenshot
            text, no ranking. --threshold accepts a comma list; each value gets its own sub-run.

--oracle-assign (with skills, without-skills or bare) places items by their gold event instead of calling
event-assign, so status-line fact recall measures event-brief alone.

Time: the organizer runs with its replay clock (--clock replay, the default): semantic time is the
capture time of the latest processed item; event-brief sees only the event's own latest item time
(as_of); home-rank's "now" is the replay clock. --clock wall reproduces the old wall-clock condition.
home-rank runs once per checkpoint (not after every item, not on day changes) to keep runs affordable;
it does not feed back into assignment or briefs. Snapshots add eval-only fields to /v1/state (see
eval_common.snapshot): item_persons, every question with status/day_key/provisional/b_items_at_ask,
questions_asked_total and assign_log. runs.jsonl carries each call's as_of and exact user message
(synthetic data only).

--answer-questions gold answers open same_event questions from gold labels after each item (report
it next to the default unanswered run). --replay-cache DIR records/replays model calls by exact
request. --rank-gold also scores home-rank on gold events at each checkpoint (independent of
clustering) and writes stats.json rank_gold.

--workers N runs the organizer in pipeline mode (concurrent model calls, deterministic lag; see
spark/organizer/pipeline.py). --stream posts every item up to a checkpoint at once and lets the
organizer drain the queue (a burst / import); stats.json then reports items_per_min for throughput.
--owner-aliases scenario passes the owner's name and aliases as ORGANIZER_OWNER_ALIASES (transcript
speakers who are the owner are not people).

Usage (on a Spark; needs fastapi, httpx, pydantic, pyyaml):
  python3 eval/run_eval.py --scenario eval/scenarios/dev-week-v1/scenario.json --condition skills \
      --llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8012/v1 --out eval/runs/dev-skills
Writes <out>/snapshots/<checkpoint_id>.json, runs.jsonl, stats.json, meta.json, score.json, score.md.
Refuses scenarios that are not marked synthetic.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(HERE / "tools"))
sys.path.insert(0, str(HERE))

from fastapi.testclient import TestClient  # noqa: E402

import eval_common  # noqa: E402
import score as scorer  # noqa: E402
import to_items  # noqa: E402
from organizer.api import build_organizer, create_app  # noqa: E402
from organizer.clients import ChatResult, HashEmbedClient, ModelUnavailable, OpenAIChatClient, image_data_uri  # noqa: E402
from organizer.config import Settings  # noqa: E402
from organizer.keys import synthetic_library_key  # noqa: E402
from organizer.skills import Harness, RunResult  # noqa: E402
from organizer.store import new_id  # noqa: E402

log = logging.getLogger("run_eval")

# ------------------------------------------------------------------------------------------
# Ablation: bare prompts (same task and output field names as the skills, nothing else)
# ------------------------------------------------------------------------------------------

BARE_TASKS = {
    "image_detect": "这张图片是哪一类？输出一个 JSON 对象：type（chat_screenshot/chart_dashboard/slide/"
                    "whiteboard_handwriting/receipt_invoice/scanned_document/form_label_sign/other）。",
    "image_read": "读这张图片（类型见输入的 type）。输出一个 JSON 对象，字段：{fields}；gist 是一句话摘要。",
    "assign": "下面是一条新素材（item）和几个已有的候选事件（candidates）。判断这条素材属于哪个候选事件，还是一件新的事，"
              "不属于任何事件，或者需要问用户。输出一个 JSON 对象：decision（attach/new/none/ask）、event_id（所选候选的 "
              "event_id；new/none 时为空字符串）、evidence（列表，每条含 reason 和 item_ids）。",
    "brief": "下面是一个事件和它按时间排列的素材（items）。为这个事件写一个短标题、一句“现在到哪一步”，以及几条带出处的事实。"
             "输出一个 JSON 对象：title、status_line、status_facts（列表，每条含 text 和 item_ids）。",
    "rank": "下面是用户的事件列表（events）。给每个事件打一个现在对用户有多重要的分数（0–1），附一句理由。"
            "输出一个 JSON 对象：ranking（列表，每条含 event_id、importance、reason）。",
}


def extract_json(text: str) -> Any:
    text = (text or "").strip()
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object")
    return json.loads(text[start:end + 1])


def coerce_to_schema(value: Any, schema: Optional[dict]) -> Any:
    """Keep what fits the schema's shape, default the rest ("" / [] / False / first enum value)."""
    if not schema:
        return value
    t = schema.get("type")
    if t == "object":
        value = value if isinstance(value, dict) else {}
        return {k: coerce_to_schema(value.get(k), sub) for k, sub in schema.get("properties", {}).items()}
    if t == "array":
        return [coerce_to_schema(v, schema.get("items")) for v in value] if isinstance(value, list) else []
    if "enum" in schema:
        return value if value in schema["enum"] else ("other" if "other" in schema["enum"] else schema["enum"][0])
    if t == "boolean":
        return bool(value)
    if t == "integer":
        return value if isinstance(value, int) and not isinstance(value, bool) else 0
    return value if isinstance(value, str) else ("" if value is None else str(value))


def coerce_bare(job: str, out: Any, schema: Optional[dict] = None) -> tuple[Optional[dict], Optional[str]]:
    """Keep only what the pipeline reads; anything structurally unusable is a failed run."""
    if not isinstance(out, dict):
        return None, "not a JSON object"
    if job == "assign":
        if out.get("decision") not in ("attach", "new", "none", "ask"):
            return None, f"bad decision {out.get('decision')!r}"
        out["event_id"] = str(out.get("event_id") or "")
        out.pop("judged", None)  # the bare condition is taken at its word (no facets, no derivation)
        return out, None
    if job == "brief":
        if not isinstance(out.get("title"), str) or not isinstance(out.get("status_line"), str):
            return None, "missing title/status_line"
        facts = out.get("status_facts") if isinstance(out.get("status_facts"), list) else []
        out["status_facts"] = [{"text": str(f.get("text", "")), "item_ids": [str(i) for i in f.get("item_ids") or []]}
                               for f in facts if isinstance(f, dict) and isinstance(f.get("item_ids", []), list)]
        out["off_anchor_item_ids"] = []
        return out, None
    if job == "rank":
        rows = out.get("ranking")
        if not isinstance(rows, list):
            return None, "missing ranking"
        good = []
        for r in rows:
            try:
                good.append({"event_id": str(r["event_id"]), "importance": float(r["importance"]),
                             "reason": str(r.get("reason", ""))})
            except (KeyError, TypeError, ValueError):
                continue
        out["ranking"] = good
        return out, None
    if job in ("image_detect", "image_read"):
        return coerce_to_schema(out, schema), None
    return None, f"unknown job {job}"


class BareHarness(Harness):
    # The output budget in SKILL.md metadata is itself skill guidance; without the schema's limits a bare
    # prompt writes much longer evidence lists and gets cut off, so the ablation gets a generous budget
    # (--bare-max-tokens). Pass --bare-max-tokens 0 to use each skill's own budget instead.
    max_tokens = 4096

    def run(self, job_type, data, *, context=None, images=None, schema=None, subject=None, as_of=None,
            **_step) -> RunResult:
        skill = self.registry.for_job(job_type)
        system = BARE_TASKS[job_type]
        if job_type == "image_read":  # same field names as the type's schema, nothing else
            system = system.format(fields="、".join((schema or {}).get("properties", {})))
        user_text = "输入：\n" + json.dumps(data, ensure_ascii=False, indent=1) + "\n\n只输出一个 JSON 对象。"
        content: Any = user_text
        if images:
            content = [{"type": "image_url", "image_url": {"url": image_data_uri(img)}} for img in images]
            content.append({"type": "text", "text": user_text})
        messages = [{"role": "system", "content": system}, {"role": "user", "content": content}]
        run_id, started = new_id(), time.time()
        prompt_hash = hashlib.sha256(system.encode()).hexdigest()[:16]
        try:
            result = self.client.complete(messages, None, job_type, self.max_tokens or skill.max_tokens)
        except ModelUnavailable as exc:
            self._record_bare(run_id, job_type, None, prompt_hash, None, f"model_unavailable: {exc}", started,
                              False, 0, 0, subject)
            raise
        try:
            parsed = extract_json(result.text)
            out, err = coerce_bare(job_type, parsed, schema)
        except ValueError as exc:
            out, err = None, f"not valid JSON: {exc}"
        ok = out is not None
        self._record_bare(run_id, job_type, result.model, prompt_hash, out if ok else result.text, err, started, ok,
                          result.prompt_tokens or 0, result.completion_tokens or 0, subject)
        prov = {"skill": f"bare:{job_type}", "version": "bare", "model": result.model, "prompt_hash": prompt_hash,
                "run_id": run_id}
        return RunResult(ok, out, run_id, [err] if err else [], prov, time.time() - started, 1)

    def _record_bare(self, run_id, job_type, model, prompt_hash, output, error, started, ok, pin, pout, subject):
        self.store.record_run({"run_id": run_id, "job_type": job_type, "skill": f"bare:{job_type}", "version": "bare",
                               "model": model, "prompt_hash": prompt_hash, "input_digest": "-", "output": output,
                               "error": error, "attempts": 1, "started_at": started, "ended_at": time.time(),
                               "ok": int(ok), "prompt_tokens": pin, "completion_tokens": pout, "subject": subject})


class BaselineHarness(Harness):
    """No model: threshold the deterministic retrieval score; every other job is skipped."""

    def __init__(self, registry, store, threshold: float):
        super().__init__(registry, NoChat(), store)
        self.threshold = threshold

    def run(self, job_type, data, *, context=None, images=None, schema=None, subject=None, as_of=None,
            **_step) -> RunResult:
        run_id = new_id()
        prov = {"skill": "baseline", "version": "baseline", "model": None, "prompt_hash": "-", "run_id": run_id}
        if job_type != "assign":
            return RunResult(False, None, run_id, ["baseline has no model"], prov, 0.0, 0)
        if not data["candidates"]:
            out = {"decision": "new", "event_id": "", "evidence": [{"reason": "no candidates", "item_ids": []}]}
            return RunResult(True, out, run_id, [], prov, 0.0, 0)
        top = data["candidates"][0]
        evidence = [{"reason": f"retrieval score {top['retrieval']['score']}", "item_ids": []}]
        if top["retrieval"]["score"] >= self.threshold:
            out = {"decision": "attach", "event_id": top["event_id"], "confidence": 1.0, "evidence": evidence}
        else:
            out = {"decision": "new", "event_id": "", "confidence": 1.0, "evidence": evidence}
        return RunResult(True, out, run_id, [], prov, 0.0, 0)


class OracleAssignHarness:
    """Places every item by its gold label (first non-noise event; noise -> none, i.e. unfiled) without a
    model call, and delegates all other jobs to the wrapped harness. Isolates event-brief quality from
    assignment errors. Multi-label items go to their first gold event only."""

    def __init__(self, inner, gold_first: dict, placed: dict, noise_items: set):
        self.inner, self.gold_first, self.placed, self.noise_items = inner, gold_first, placed, noise_items
        self.registry, self.client, self.store = inner.registry, inner.client, inner.store

    def run(self, job_type, data, **kw) -> RunResult:
        if job_type != "assign":
            return self.inner.run(job_type, data, **kw)
        run_id = new_id()
        item_id = self.store.one("SELECT item_id FROM item_handles WHERE n=?",
                                 (int(data["item"]["item_id"][1:]),))["item_id"]
        target = self.placed.get(self.gold_first.get(item_id.lower()))
        ev = [{"reason": "gold", "item_ids": []}]
        if target:
            h = self.store.event_handle(target)
            out = {"item_object": "gold", "item_is_matter": True, "judged": [{"event_id": h, "match": "same_object"}],
                   "decision": "attach", "event_id": h, "evidence": ev}
        elif item_id.lower() in self.noise_items:
            out = {"item_object": "noise", "item_is_matter": False, "judged": [], "decision": "none", "event_id": "",
                   "evidence": ev}
        else:
            out = {"item_object": "gold", "item_is_matter": True, "judged": [], "decision": "new", "event_id": "",
                   "evidence": ev}
        prov = {"skill": "oracle", "version": "oracle", "model": None, "prompt_hash": "-", "run_id": run_id}
        return RunResult(True, out, run_id, [], prov, 0.0, 0)


class RoutingChat:
    """Requests that carry an image go to a vision model, everything else to the main model.
    Used when the main model is text-only (DeepSeek-V4-Flash rejects images with HTTP 400)."""

    def __init__(self, text, vision):
        self.text, self.vision = text, vision

    @property
    def model_id(self) -> str:
        return self.text.model_id

    def complete(self, messages, schema, schema_name, max_tokens) -> ChatResult:
        has_image = any(isinstance(m["content"], list) and any(c.get("type") == "image_url" for c in m["content"])
                        for m in messages)
        return (self.vision if has_image else self.text).complete(messages, schema, schema_name, max_tokens)


class NoChat:
    model_id = "none"

    def complete(self, *a, **k) -> ChatResult:
        raise RuntimeError("baseline must not call a model")


class CachedEmbedder:
    """Wraps an embedder, memoizes by text (baseline sweeps re-embed the same items) and retries.

    The organizer silently drops an item's embedding when the embedding call fails and never
    retries it; in an eval that would quietly change retrieval, so transient failures are retried
    here and counted (stats.json: embed_failures)."""

    def __init__(self, inner, attempts: int = 5, wait_s: float = 5.0):
        self.inner = inner
        self.model_id = inner.model_id
        self.cache: dict[str, list[float]] = {}
        self.attempts, self.wait_s = attempts, wait_s
        self.failures = 0

    def embed(self, texts: list[str]) -> list[list[float]]:
        todo = [t for t in texts if t not in self.cache]
        if todo:
            for attempt in range(self.attempts):
                try:
                    vecs = self.inner.embed(todo)
                    break
                except ModelUnavailable as exc:
                    self.failures += 1
                    log.warning("embedding failed (attempt %d): %s", attempt + 1, exc)
                    if attempt + 1 == self.attempts:
                        raise
                    time.sleep(self.wait_s)
            for t, v in zip(todo, vecs):
                self.cache[t] = v
        return [self.cache[t] for t in texts]


# ------------------------------------------------------------------------------------------
# Driving the organizer
# ------------------------------------------------------------------------------------------

def drain(org, max_errors: int = 20) -> None:
    """Run the worker loop until the queue is empty (no rank; rank runs at checkpoints)."""
    errors = 0
    while True:
        org._rank_dirty = False
        try:
            did = org.step()
        except ModelUnavailable as exc:
            log.warning("model unavailable, waiting: %s", exc)
            time.sleep(5)
            continue
        except Exception:  # the real worker logs and continues; cap it here so a run cannot spin forever
            errors += 1
            log.exception("worker step failed (%d)", errors)
            if errors >= max_errors:
                raise
            time.sleep(1)
            continue
        if did:
            continue
        if org.store.queue_depth() == 0 and not org.store.one(
                "SELECT 1 FROM events WHERE needs_brief=1 AND deleted=0"):
            return
        time.sleep(1)  # a job is waiting for its retry delay


def snapshot(client: TestClient, org, item_ids: list[str]) -> dict:
    return eval_common.snapshot(org, item_ids, client.get("/v1/state").json())


def _pct(values: list[float], q: float) -> Optional[float]:
    if not values:
        return None
    values = sorted(values)
    k = max(0, min(len(values) - 1, int(round(q * (len(values) - 1)))))
    return round(values[k], 3)


def run_stats(org, final_state: dict) -> dict:
    rows = org.store.all("SELECT job_type, attempts, ok, started_at, ended_at, prompt_tokens, completion_tokens,"
                         " error FROM runs")
    per: dict[str, dict] = {}
    for job in sorted({r["job_type"] for r in rows}):
        rs = [r for r in rows if r["job_type"] == job]
        lat = [r["ended_at"] - r["started_at"] for r in rs]
        per[job] = {
            "calls": len(rs), "ok": sum(r["ok"] for r in rs),
            "ok_first_attempt": sum(1 for r in rs if r["ok"] and r["attempts"] == 1),
            "retried": sum(1 for r in rs if r["attempts"] > 1),
            "latency_median_s": _pct(lat, 0.5), "latency_p95_s": _pct(lat, 0.95),
            "latency_total_s": round(sum(lat), 1),
            "prompt_tokens_mean": round(statistics.mean([r["prompt_tokens"] or 0 for r in rs]), 1) if rs else None,
            "completion_tokens_mean": round(statistics.mean([r["completion_tokens"] or 0 for r in rs]), 1) if rs else None,
            "prompt_tokens_total": sum(r["prompt_tokens"] or 0 for r in rs),
            "completion_tokens_total": sum(r["completion_tokens"] or 0 for r in rs),
            "errors_sample": [r["error"][:200] for r in rs if r["error"]][:3],
        }
    decisions: dict[str, int] = {}
    actions: dict[str, int] = {}
    for p in org.store.all("SELECT payload, status, reason FROM proposals WHERE kind='assign'"):
        payload = json.loads(p["payload"])
        key = payload.get("decision") or payload.get("rule") or ("fallback" if p["status"] == "fallback" else "?")
        decisions[key] = decisions.get(key, 0) + 1
        act = (payload.get("derived") or {}).get("action") or key
        if (p["reason"] or "").startswith("ask_budget"):
            act = "ask_suppressed"
        actions[act] = actions.get(act, 0) + 1
    live = [e for e in final_state.get("events", []) if not e.get("deleted") and not e.get("merged_into")]
    lines = [len(e["status_line"]) for e in live if e.get("status_line")]
    titles = [len(e["title"]) for e in live if e.get("title")]
    return {"per_job": per, "assign_decisions": decisions, "assign_actions": actions,
            "final_live_events": len(live),
            "status_line_chars_mean": round(statistics.mean(lines), 1) if lines else None,
            "title_chars_mean": round(statistics.mean(titles), 1) if titles else None}


def score_rank_gold(org, scenario: dict, cp: dict) -> dict:
    """Call home-rank once on the gold events at this checkpoint and score it against the home grades."""
    views, handles, now = eval_common.gold_rank_views(scenario, cp)
    skill = org.registry.for_job("rank")
    schema = json.loads(json.dumps(skill.schema))
    ids = list(handles)
    schema["properties"]["ranking"]["minItems"] = schema["properties"]["ranking"]["maxItems"] = len(ids)
    schema["properties"]["ranking"]["items"]["properties"]["event_id"]["enum"] = ids
    schema["properties"]["ranking"]["items"]["properties"]["event_id"].pop("pattern", None)
    res = org.harness.run("rank", {"now": now, "events": views}, context={"event_ids": ids, "feature_less": []},
                          schema=schema, subject="rank-gold", as_of=now)
    if not res.ok:
        return {"ok": False, "errors": res.errors}
    imp = {handles[r["event_id"]]: r["importance"] for r in res.output["ranking"] if r["event_id"] in handles}
    gold = scorer.Gold(scenario)
    at = gold.item_order(cp["after_item_id"])
    universe = gold.universe(at)
    state = {"events": [{"event_id": g, "title": g, "status_line": "", "status_facts": [], "facts_raw": [],
                         "item_ids": [i for i in universe if g in gold.item_events[i]], "person_ids": [],
                         "importance": imp.get(g, 0.5), "importance_reason": "gold", "pinned": False,
                         "feature_less": False, "updated_at": ""} for g in imp]}
    home = scorer.home_metrics(gold, cp, state, universe, {g: g for g in imp})
    return {"ok": True, **{k: home[k] for k in ("ndcg5", "top3_precision", "g3_recall3", "gross_inversions")},
            "importance": imp}


def git_rev() -> str:
    if os.environ.get("EVAL_GIT_REV"):  # set when the tree was rsynced without .git
        return os.environ["EVAL_GIT_REV"]
    try:
        rev = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"], capture_output=True, text=True,
                               timeout=5).stdout.strip()
        return rev + ("+dirty" if dirty else "")
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def run_one(args, scenario_path: Path, scenario: dict, items: list[dict], out: Path, condition: str,
            embedder, threshold: Optional[float] = None) -> dict:
    if out.exists():
        if not args.force:
            raise SystemExit(f"{out} exists (use --force)")
        shutil.rmtree(out)
    (out / "snapshots").mkdir(parents=True)
    settings = Settings()
    settings.data_dir = out / "data"
    settings.skills_dir = ROOT / "skills"
    settings.start_worker = False
    settings.rank_every_n_items = 10 ** 9
    settings.embed_base_url = ""
    settings.clock = args.clock
    settings.record_inputs = True  # synthetic data only: runs.jsonl keeps each call's exact user message
    settings.workers = args.workers
    settings.pipeline_lag = args.pipeline_lag
    if args.owner_aliases == "scenario":
        owner = next(p for p in scenario["people"] if p.get("is_owner"))
        settings.owner_aliases = tuple(dict.fromkeys(["我", owner["display_name"], *owner.get("aliases", [])]))
    chat = NoChat() if condition == "baseline" else OpenAIChatClient(args.llm_url, args.llm_model, args.llm_timeout)
    vision = None
    if args.vision_llm_url and condition != "baseline":
        vision = OpenAIChatClient(args.vision_llm_url, "auto", args.llm_timeout)
        chat = RoutingChat(chat, vision)
    if args.replay_cache and condition != "baseline":
        chat = eval_common.CachedChat(chat, args.replay_cache)
    org = build_organizer(settings, chat=chat, embedder=embedder)
    org.rank_on_day_change = False  # home-rank runs at checkpoints only
    answerer = eval_common.GoldAnswerer(scenario) if args.answer_questions == "gold" else None
    if condition == "without-skills":
        eval_common.strip_skill_text(org)
    elif condition == "bare":
        org.harness = BareHarness(org.registry, chat, org.store)
        org.harness.max_tokens = args.bare_max_tokens
    elif condition == "baseline":
        org.harness = BaselineHarness(org.registry, org.store, threshold)
    gold_first: dict[str, str] = {}
    placed: dict[str, str] = {}
    if args.oracle_assign:
        noise = {e["event_id"] for e in scenario["events"] if e.get("kind") == "noise"}
        noise_items = set()
        for it in scenario["items"]:
            labels = [e for e in it.get("events", []) if e not in noise]
            if labels:
                gold_first[it["item_id"].lower()] = labels[0]
            else:
                noise_items.add(it["item_id"].lower())
        org.harness = OracleAssignHarness(org.harness, gold_first, placed, noise_items)
        # Every live event is a candidate, so the gold event is always reachable (no model sees this list).
        org.candidates_k = 10 ** 6
    app = create_app(settings, organizer=org)
    # Same path as the Mac: every request carries the link token created in this run's data dir, and the first
    # data call unlocks the (encrypted) store, here with the fixed synthetic key (synthetic data only).
    client = TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"})
    client.post("/v1/unlock", json={"key": synthetic_library_key().hex()}).raise_for_status()
    checkpoints = {cp["after_item_id"].lower(): cp for cp in scenario["checkpoints"]}
    seen: list[str] = []
    snaps: dict[str, dict] = {}
    t0 = time.time()
    rank_gold: dict[str, dict] = {}
    if args.stream:
        # Stream mode (throughput): every item up to the next checkpoint is posted at once and the
        # organizer drains its queue on its own, as after a burst or an import. No gold answering.
        batch: list[dict] = []
        for n, api_item in enumerate(items, 1):
            batch.append(api_item)
            seen.append(api_item["item_id"])
            cp = checkpoints.get(api_item["item_id"].lower())
            if not cp and n < len(items):
                continue
            for i in range(0, len(batch), 500):
                client.post("/v1/items", json={"items": batch[i:i + 500]}).raise_for_status()
            batch = []
            drain(org)
            if cp:
                if condition != "baseline" and not args.no_rank:
                    org.rank()
                snaps[cp["checkpoint_id"]] = snap = snapshot(client, org, seen)
                (out / "snapshots" / f"{cp['checkpoint_id']}.json").write_text(
                    json.dumps(snap, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"[{out.name}] {n}/{len(items)} items, {time.time() - t0:.0f}s"
                  + (f", snapshot {cp['checkpoint_id']}" if cp else ""), flush=True)
        items_loop: list = []
    else:
        items_loop = list(enumerate(items, 1))
    for n, api_item in items_loop:
        resp = client.post("/v1/items", json={"items": [api_item]})
        resp.raise_for_status()
        seen.append(api_item["item_id"])
        drain(org)
        if answerer and answerer.answer_open(org):
            drain(org)
        gold = gold_first.get(api_item["item_id"].lower())
        if gold and gold not in placed:
            link = org.store.current_event_link(api_item["item_id"])
            if link:
                placed[gold] = link["event_id"]
        cp = checkpoints.get(api_item["item_id"].lower())
        if cp:
            if condition != "baseline" and not args.no_rank:
                org.rank()
            if args.rank_gold and condition != "baseline" and cp.get("home"):
                rank_gold[cp["checkpoint_id"]] = score_rank_gold(org, scenario, cp)
            snaps[cp["checkpoint_id"]] = snap = snapshot(client, org, seen)
            (out / "snapshots" / f"{cp['checkpoint_id']}.json").write_text(
                json.dumps(snap, ensure_ascii=False, indent=1), encoding="utf-8")
        if n % 10 == 0 or cp:
            print(f"[{out.name}] {n}/{len(items)} items, {time.time() - t0:.0f}s"
                  + (f", snapshot {cp['checkpoint_id']}" if cp else ""), flush=True)
    wall = time.time() - t0
    runs = org.store.all("SELECT * FROM runs ORDER BY started_at")
    with open(out / "runs.jsonl", "w", encoding="utf-8") as fh:
        for r in runs:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    last = scenario["checkpoints"][-1]["checkpoint_id"]
    stats = run_stats(org, snaps.get(last, {}))
    stats["wall_s"] = round(wall, 1)
    stats["items_per_min"] = round(len(items) / wall * 60, 2) if wall else None
    stats["workers"] = args.workers
    stats["pipeline_lag"] = args.pipeline_lag if args.workers > 1 else None
    stats["stream"] = bool(args.stream)
    split_rows = org.store.all("SELECT payload, status FROM proposals WHERE kind='split'")
    stats["split"] = {"calls": len(split_rows),
                      "split_items": sum(1 for r in split_rows if json.loads(r["payload"]).get("segments")),
                      "segments": sum(len(json.loads(r["payload"]).get("segments") or []) for r in split_rows),
                      "rejected": sum(1 for r in split_rows if r["status"] == "rejected")}
    stats["questions_answered_by_gold"] = answerer.answered if answerer else None
    if rank_gold:
        stats["rank_gold"] = rank_gold
    if isinstance(chat, eval_common.CachedChat):
        stats["replay_cache"] = {"hits": chat.hits, "misses": chat.misses}
    stats["embed_failures"] = getattr(embedder, "failures", 0)
    stats["items_without_embedding"] = None if embedder is None else sum(
        1 for iid in seen if not (org.store.get_derived(iid, 0) or {}).get("embedding"))
    model_id = None if condition == "baseline" else chat.model_id
    meta = {"scenario": scenario.get("scenario_id"), "split": scenario.get("split"), "condition": condition,
            "threshold": threshold, "llm_url": None if condition == "baseline" else args.llm_url, "model": model_id,
            "vision_model": vision.model_id if vision else None, "vision_llm_url": args.vision_llm_url if vision else None,
            "embed_model": getattr(embedder, "model_id", None), "embed_url": args.embed_url,
            "skills": org.registry.summary(),
            "prompt_hashes": {s.name: s.prompt_hash for s in org.registry.skills.values()}
            if condition in ("skills", "without-skills") else None,
            "git": git_rev(), "date": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "argv": sys.argv, "no_rank": args.no_rank, "oracle_assign": args.oracle_assign,
            "workers": args.workers, "pipeline_lag": args.pipeline_lag, "stream": bool(args.stream),
            "owner_aliases": list(settings.owner_aliases),
            "clock": args.clock, "answer_questions": args.answer_questions, "replay_cache": args.replay_cache,
            "handles": {org.store.event_handle(e["event_id"]): e["event_id"] for e in org.store.all(
                "SELECT event_id FROM events ORDER BY handle")},
            "bare_max_tokens": args.bare_max_tokens if condition == "bare" else None}
    result = scorer.score(scenario, snaps)
    (out / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=1), encoding="utf-8")
    (out / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    (out / "score.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    md = scorer.markdown_report(result, title=f"{scenario.get('scenario_id')} · {condition}"
                                + (" · oracle assign" if args.oracle_assign else "")
                                + (f" τ={threshold}" if threshold is not None else "") + f" · {model_id or 'no LLM'}")
    (out / "score.md").write_text(md, encoding="utf-8")
    print(md, flush=True)
    print(json.dumps(stats, ensure_ascii=False), flush=True)
    client.close()
    org.store.conn.close()
    if not args.keep_db:
        shutil.rmtree(out / "data", ignore_errors=True)
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--condition", choices=["skills", "without-skills", "bare", "baseline"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--llm-model", default="auto")
    ap.add_argument("--llm-timeout", type=float, default=300.0)
    ap.add_argument("--vision-llm-url", help="send image requests (image-read) to this model instead")
    ap.add_argument("--embed-url", help="OpenAI-compatible /v1 for embeddings")
    ap.add_argument("--embed", choices=["url", "hash", "none"], default="url",
                    help="url = --embed-url; hash = char-bigram hashing (lexical); none = no similarity")
    ap.add_argument("--threshold", default="0.5", help="baseline attach threshold(s), comma separated")
    ap.add_argument("--bare-max-tokens", type=int, default=4096,
                    help="output budget for the bare ablation (0 = each skill's own max_output_tokens)")
    ap.add_argument("--no-rank", action="store_true", help="skip home-rank at checkpoints")
    ap.add_argument("--oracle-assign", action="store_true",
                    help="place items by gold labels (no event-assign model call) to score event-brief alone")
    ap.add_argument("--clock", choices=["replay", "wall"], default="replay",
                    help="organizer clock: replay = latest captured item time (default); wall = the old condition")
    ap.add_argument("--answer-questions", choices=["none", "gold"], default="none",
                    help="gold = answer open same_event questions from gold labels after each item")
    ap.add_argument("--replay-cache", help="directory: record model calls by exact request and replay hits")
    ap.add_argument("--rank-gold", action="store_true",
                    help="also score home-rank on gold events at each graded checkpoint (stats.json rank_gold)")
    ap.add_argument("--workers", type=int, default=1,
                    help="organizer pool size (ORGANIZER_WORKERS); >1 = pipeline mode (organizer/pipeline.py)")
    ap.add_argument("--pipeline-lag", type=int, default=2, help="ORGANIZER_PIPELINE_LAG for --workers > 1")
    ap.add_argument("--stream", action="store_true",
                    help="post all items up to each checkpoint at once, then drain (throughput runs)")
    ap.add_argument("--owner-aliases", choices=["default", "scenario"], default="default",
                    help="scenario: the owner's display name and aliases are ORGANIZER_OWNER_ALIASES")
    ap.add_argument("--keep-db", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    scenario_path = Path(args.scenario)
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    if scenario.get("synthetic") is not True:
        raise SystemExit("refusing: scenario is not marked synthetic: true")
    items = to_items.build_items(str(scenario_path), render_missing=False)
    if args.embed == "url":
        if not args.embed_url:
            raise SystemExit("--embed url needs --embed-url")
        from organizer.clients import OpenAIEmbedClient
        embedder = CachedEmbedder(OpenAIEmbedClient(args.embed_url, timeout_s=60.0))
    elif args.embed == "hash":
        embedder = HashEmbedClient()
    else:
        embedder = None
    out = Path(args.out)
    if args.condition == "baseline":
        summary = {}
        for t in [float(x) for x in args.threshold.split(",")]:
            res = run_one(args, scenario_path, scenario, items, out / f"t{t:.2f}", "baseline", embedder, t)
            summary[f"{t:.2f}"] = res["summary"]
        (out / "sweep.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
        print("threshold  B3-F1  link-F1  hard-leak  easy-leak  events", flush=True)
        for t, s in summary.items():
            print(t, *(scorer.fmt(s[k]) for k in ("bcubed_f1", "link_f1", "hard_decoy_leakage", "easy_decoy_leakage",
                                                   "pred_event_count")), flush=True)
    else:
        run_one(args, scenario_path, scenario, items, out, args.condition, embedder)
    return 0


if __name__ == "__main__":
    sys.exit(main())
