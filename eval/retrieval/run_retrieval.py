#!/usr/bin/env python3
"""Recall@k of the organizer's candidate retrieval, replayed with ground-truth events.

What is measured: for every item whose true event already exists when the item arrives, is that event
among the top-k candidates that event-assign would be shown? The organizer ships k = 5
(Settings.candidates_k), so recall@5 is the ceiling on correct attachment: an event that is not
retrieved cannot be chosen.

How: the real organizer runs in-process behind its FastAPI app (POST /v1/items, the same path as
eval/run_eval.py). Each item goes through the shipped pipeline (image-read for images, persons,
the item text the organizer embeds, event_features(), skills/event-assign/scripts/candidates.py). Only
the placement is replaced: an oracle attaches the item to its gold event (the first of its labels that
already exists), starts a new event for the first mention of a gold event, and leaves unlabelled noise
unfiled. So the pool of events, their centroids, time spans, persons and sources at every step are what
a perfect event-assign would have produced. event-brief and home-rank are not run (no model); retrieval
does not read titles or status lines. The only brief effect that retrieval reads, off-anchor flags, is
therefore absent.

Every live event is scored (candidates_k is raised to 10**6 for the replay; the shipped k=5 is the head
of that same sorted list, because rank_candidates sorts before it truncates), and the full ranking is
logged per item. Two rankings are reported: the fused score as shipped (0.55 similarity + 0.20 time +
0.15 persons + 0.10 source) and similarity alone (the embedding's own contribution).

Screenshot readings come from the vision model through eval_common.CachedChat, recorded on the first
run and replayed on every other run, so all embedders see the same screenshot text.

Embedders (--embedder):
  url    an OpenAI-compatible /v1/embeddings endpoint (--embed-url), e.g. Qwen3-Embedding-0.6B or -4B
  hash   organizer.clients.HashEmbedClient: character-bigram hashing, 256 dims, no model (the lexical
         baseline used in the eval baselines)
  none   no embedding: the organizer's degraded mode (time + persons + source only)

Synthetic scenarios only (refuses a scenario without "synthetic": true). Nothing is sent anywhere but
the given loopback endpoints.

  python3 eval/retrieval/run_retrieval.py --scenario eval/scenarios/dev-week-v1/scenario.json \
      --embedder url --embed-url http://127.0.0.1:8013/v1 --vision-url http://127.0.0.1:8000/v1 \
      --reading-cache /tmp/readings --out /tmp/retr-dev-0.6b
Writes <out>/items.jsonl (one row per item: gold, pool, ranking), <out>/summary.json.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import shutil
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

HERE = Path(__file__).resolve().parent
EVAL = HERE.parent
ROOT = EVAL.parent
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(EVAL / "tools"))
sys.path.insert(0, str(EVAL))

os.environ.setdefault("ORGANIZER_REQUIRE_TOKEN", "1")

from fastapi.testclient import TestClient  # noqa: E402

import eval_common  # noqa: E402
import to_items  # noqa: E402
from organizer.api import build_organizer, create_app  # noqa: E402
from organizer.clients import HashEmbedClient, ModelUnavailable, OpenAIChatClient, OpenAIEmbedClient  # noqa: E402
from organizer.config import Settings  # noqa: E402
from organizer.skills import RunResult  # noqa: E402
from organizer.store import new_id  # noqa: E402

log = logging.getLogger("run_retrieval")
KS = (1, 3, 5)


class TimedEmbedder:
    """Times every embed call the organizer makes (one item text per call, as in production) and retries
    transient failures so a dropped embedding cannot silently change retrieval."""

    def __init__(self, inner, attempts: int = 5, wait_s: float = 3.0):
        self.inner = inner
        self.model_id = inner.model_id
        self.calls: list[dict] = []
        self.failures = 0
        self.attempts, self.wait_s = attempts, wait_s

    def embed(self, texts: list[str]) -> list[list[float]]:
        for attempt in range(self.attempts):
            t0 = time.perf_counter()
            try:
                vecs = self.inner.embed(texts)
            except ModelUnavailable as exc:
                self.failures += 1
                log.warning("embedding failed (attempt %d): %s", attempt + 1, exc)
                if attempt + 1 == self.attempts:
                    raise
                time.sleep(self.wait_s)
                continue
            ms = (time.perf_counter() - t0) * 1000.0
            self.calls.append({"n": len(texts), "chars": sum(len(t) for t in texts), "ms": round(ms, 3),
                               "dim": len(vecs[0]) if vecs else 0})
            return vecs
        raise AssertionError("unreachable")


class RetrievalOracle:
    """Harness stand-in: image-read's two steps go to the real harness (vision model, cached); assign places
    the item by its gold labels; brief/rank are not run."""

    def __init__(self, inner, labels: dict[str, list[str]], placed: dict[str, str], ctx: dict):
        self.inner, self.labels, self.placed, self.ctx = inner, labels, placed, ctx
        self.registry, self.client, self.store = inner.registry, inner.client, inner.store

    def run(self, job_type, data, **kw) -> RunResult:
        run_id = new_id()
        prov = {"skill": "retrieval-oracle", "version": "oracle", "model": None, "prompt_hash": "-", "run_id": run_id}
        if job_type in ("image_detect", "image_read"):
            return self.inner.run(job_type, data, **kw)
        if job_type != "assign":
            return RunResult(False, None, run_id, ["retrieval eval: no model for " + job_type], prov, 0.0, 0)
        labels = self.labels.get(self.ctx["item_id"].lower(), [])
        existing = [lab for lab in labels if lab in self.placed]
        ev = [{"reason": "gold", "item_ids": []}]
        if existing:
            h = self.store.event_handle(self.placed[existing[0]])
            out = {"item_object": "gold", "item_is_matter": True, "judged": [{"event_id": h, "match": "same_object"}],
                   "decision": "attach", "event_id": h, "evidence": ev}
        elif labels:
            out = {"item_object": "gold", "item_is_matter": True, "judged": [], "decision": "new", "event_id": "",
                   "evidence": ev}
        else:
            out = {"item_object": "noise", "item_is_matter": False, "judged": [], "decision": "none", "event_id": "",
                   "evidence": ev}
        return RunResult(True, out, run_id, [], prov, 0.0, 0)


class RecordingCandidates:
    """Wraps skills/event-assign/scripts/candidates.py and logs the full ranking of each item's first
    retrieval (a recheck of an unfiled item is a later, different question and is not scored)."""

    def __init__(self, module, ctx: dict, sink: list):
        self.module, self.ctx, self.sink = module, ctx, sink
        self.seen: set[str] = set()

    def rank_candidates(self, item, events, forbidden=(), k=5, *a, **kw):
        events = list(events)
        full = self.module.rank_candidates(item, events, forbidden, 10 ** 6, *a, **kw)
        iid = self.ctx["item_id"]
        if iid not in self.seen:
            self.seen.add(iid)
            self.sink.append({"item_id": iid, "has_embedding": bool(item.get("embedding")),
                              "persons": len(item.get("person_ids") or []), "ranking": full})
        return full[:k]

    def __getattr__(self, name):
        return getattr(self.module, name)


def _hit_rank(order: list[str], gold: set[str]) -> Optional[int]:
    for i, lab in enumerate(order):
        if lab in gold:
            return i
    return None


def _random_recall(n: int, g: int, k: int) -> float:
    """P(at least one of g gold events in the top k of a uniformly random order of n events)."""
    if g <= 0 or n <= 0:
        return 0.0
    if k >= n:
        return 1.0
    return 1.0 - math.comb(n - g, k) / math.comb(n, k)


def summarize(rows: list[dict]) -> dict:
    scored = [r for r in rows if r["status"] == "scored"]
    out = {"items_total": len(rows), "items_scored": len(scored),
           "items_first_mention": sum(1 for r in rows if r["status"] == "first_mention"),
           "items_noise": sum(1 for r in rows if r["status"] == "noise"),
           "mean_pool_size": round(statistics.mean(r["pool_size"] for r in scored), 2) if scored else None}
    for name, key in (("fused", "rank_fused"), ("similarity_only", "rank_sim")):
        block = {}
        for k in KS:
            block[f"recall@{k}"] = round(sum(1 for r in scored if r[key] is not None and r[key] < k) / len(scored), 4) \
                if scored else None
        block["mrr"] = round(statistics.mean(1.0 / (r[key] + 1) if r[key] is not None else 0.0 for r in scored), 4) \
            if scored else None
        block["hits@5"] = sum(1 for r in scored if r[key] is not None and r[key] < 5)
        out[name] = block
    out["random"] = {f"recall@{k}": round(statistics.mean(_random_recall(r["pool_size"], r["gold_in_pool"], k)
                                                          for r in scored), 4) if scored else None for k in KS}
    by_kind: dict[str, dict] = {}
    for r in scored:
        b = by_kind.setdefault(r["kind"], {"n": 0, "hit@1": 0, "hit@3": 0, "hit@5": 0})
        b["n"] += 1
        for k in KS:
            b[f"hit@{k}"] += int(r["rank_fused"] is not None and r["rank_fused"] < k)
    out["fused_by_kind"] = by_kind
    out["misses@5"] = [{"ref": r["ref"], "kind": r["kind"], "gold": r["gold_in_pool_labels"], "top5": r["top_fused"][:5]}
                       for r in scored if r["rank_fused"] is None or r["rank_fused"] >= 5]
    return out


def _pct(values: list[float], q: float) -> Optional[float]:
    if not values:
        return None
    s = sorted(values)
    idx = min(len(s) - 1, max(0, math.ceil(q * len(s)) - 1))
    return round(s[idx], 2)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--embedder", choices=("url", "hash", "none"), required=True)
    ap.add_argument("--embed-url", default="")
    ap.add_argument("--embed-model", default="auto")
    ap.add_argument("--vision-url", default="http://127.0.0.1:8000/v1",
                    help="vision chat endpoint for image-read (only called on a reading-cache miss)")
    ap.add_argument("--vision-model", default="auto",
                    help="explicit id lets a node without the vision model replay the reading cache")
    ap.add_argument("--reading-cache", required=True, help="CachedChat dir shared by all runs of a scenario")
    ap.add_argument("--label", default="", help="name of this condition in the summary")
    ap.add_argument("--out", required=True)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")

    scenario_path = Path(args.scenario)
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    if scenario.get("synthetic") is not True:
        raise SystemExit("refusing a scenario that is not marked synthetic")
    out = Path(args.out)
    if out.exists():
        if not args.force:
            raise SystemExit(f"{out} exists (use --force)")
        shutil.rmtree(out)
    out.mkdir(parents=True)

    if args.embedder == "url":
        embedder = TimedEmbedder(OpenAIEmbedClient(args.embed_url, args.embed_model))
    elif args.embedder == "hash":
        embedder = TimedEmbedder(HashEmbedClient())
    else:
        embedder = None

    settings = Settings()
    settings.data_dir = out / "data"
    settings.skills_dir = ROOT / "skills"
    settings.start_worker = False
    settings.rank_every_n_items = 10 ** 9
    settings.embed_base_url = ""
    settings.clock = "replay"
    chat = eval_common.CachedChat(OpenAIChatClient(args.vision_url, args.vision_model, 300.0), args.reading_cache)
    org = build_organizer(settings, chat=chat, embedder=embedder)
    org.rank_on_day_change = False
    org.candidates_k = 10 ** 6

    labels = {it["item_id"].lower(): list(it.get("events") or []) for it in scenario["items"]}
    placed: dict[str, str] = {}
    ctx: dict = {"item_id": ""}
    sink: list[dict] = []
    org.harness = RetrievalOracle(org.harness, labels, placed, ctx)
    org._candidates = RecordingCandidates(org._candidates, ctx, sink)
    orig_assign = org.assign

    def assign(item, body, embedding, current=None, reason=None):
        ctx["item_id"] = item["item_id"]
        return orig_assign(item, body, embedding, current=current, reason=reason)

    org.assign = assign

    app = create_app(settings, organizer=org)
    client = TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"})
    items = to_items.build_items(str(scenario_path), render_missing=False)
    by_id = {it["item_id"].lower(): it for it in scenario["items"]}
    rows: list[dict] = []
    t0 = time.time()
    for api_item in items:
        iid = api_item["item_id"]
        gold = labels.get(iid.lower(), [])
        existing_before = [lab for lab in gold if lab in placed]
        pool_before = dict(placed)
        n_sink = len(sink)
        client.post("/v1/items", json={"items": [api_item]}).raise_for_status()
        # Drain: the worker loop minus brief/rank (their harness calls fail fast and clear needs_brief).
        for _ in range(10_000):
            org._rank_dirty = False
            if not org.step():
                break
        rec = next((s for s in sink[n_sink:] if s["item_id"] == iid), None)
        link = org.store.current_event_link(iid)
        if gold and link and not existing_before:
            placed[gold[0]] = link["event_id"]  # first mention: the oracle started this gold event
        rev = {ev: lab for lab, ev in pool_before.items()}
        src = by_id[iid.lower()]
        row = {"ref": src.get("ref"), "item_id": iid, "kind": src["kind"], "t": src["t"], "gold": gold,
               "gold_in_pool_labels": existing_before, "gold_in_pool": len(existing_before),
               "pool_size": 0, "rank_fused": None, "rank_sim": None, "top_fused": [], "top_sim": [],
               "has_embedding": None, "persons_for_matching": None}
        if rec is not None:
            ranking = rec["ranking"]
            fused = [rev.get(c["event_id"], "?" + c["event_id"][:8]) for c in ranking]
            by_sim = sorted(ranking, key=lambda c: (-c["similarity"], c["order"], c["event_id"]))
            sim = [rev.get(c["event_id"], "?" + c["event_id"][:8]) for c in by_sim]
            row.update(pool_size=len(ranking), top_fused=fused, top_sim=sim,
                       scores=[{"event": rev.get(c["event_id"]), "score": c["score"], "similarity": c["similarity"],
                                "time": c["time"], "shared_persons": len(c["shared_persons"]),
                                "same_source": c["same_source"]} for c in ranking],
                       has_embedding=rec["has_embedding"], persons_for_matching=rec["persons"])
            gset = set(existing_before)
            row["rank_fused"] = _hit_rank(fused, gset)
            row["rank_sim"] = _hit_rank(sim, gset)
        if not gold:
            row["status"] = "noise"
        elif not existing_before:
            row["status"] = "first_mention"
        elif rec is None:
            row["status"] = "not_retrieved"  # should not happen: every labelled item goes through assign
        else:
            row["status"] = "scored"
        # Replay check: a labelled item must end in one of its gold events.
        row["placed_ok"] = (link is not None and {ev: lab for lab, ev in placed.items()}.get(link["event_id"]) in gold) \
            if gold else link is None
        rows.append(row)
    wall = time.time() - t0

    with open(out / "items.jsonl", "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    summary = summarize(rows)
    readings = []
    for api_item in items:
        if api_item["kind"] == "image":
            d = org.store.get_derived(api_item["item_id"], 0)
            readings.append({"ref": by_id[api_item["item_id"].lower()].get("ref"),
                             "text_chars": len(d.get("derived_text") or ""), "summary_chars": len(d.get("summary") or ""),
                             "messages": len(d.get("messages") or [])})
    calls = embedder.calls if embedder else []
    ms = [c["ms"] for c in calls]
    summary.update({
        "label": args.label or (embedder.model_id if embedder else "no-embedding"),
        "scenario": scenario.get("scenario_id"), "split": scenario.get("split"),
        "embedder": args.embedder, "embed_model": embedder.model_id if embedder else None,
        "embed_url": args.embed_url or None,
        "embed_dim": calls[0]["dim"] if calls else None,
        "embed_calls": len(calls), "embed_failures": embedder.failures if embedder else 0,
        "embed_latency_ms": {"p50": _pct(ms, 0.5), "p95": _pct(ms, 0.95), "max": _pct(ms, 1.0),
                             "mean": round(statistics.mean(ms), 2) if ms else None},
        "embed_chars": {"p50": _pct([c["chars"] for c in calls], 0.5), "max": _pct([c["chars"] for c in calls], 1.0)},
        "vision_model": chat.model_id, "reading_cache": {"hits": chat.hits, "misses": chat.misses},
        "screenshot_readings": readings,
        "replay_placement_errors": sum(1 for r in rows if not r["placed_ok"]),
        "items_not_retrieved": sum(1 for r in rows if r["status"] == "not_retrieved"),
        "wall_s": round(wall, 1),
        "date": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "argv": sys.argv,
    })
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ("label", "scenario", "items_scored", "fused", "similarity_only",
                                              "random", "embed_latency_ms", "replay_placement_errors")},
                     ensure_ascii=False), flush=True)
    client.close()
    org.store.conn.close()
    shutil.rmtree(out / "data", ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
