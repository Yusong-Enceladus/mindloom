"""FastAPI app for the organizer contract v1 (bind to 127.0.0.1 only; reach it over SSH)."""

from __future__ import annotations

import json
import logging
import threading
from contextlib import asynccontextmanager
from typing import Optional
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from . import __version__, fileparse
from .auth import bearer_matches, ensure_link_token
from .clients import ChatClient, EmbedClient, ModelUnavailable, OpenAIChatClient, OpenAIEmbedClient
from .clients import Step3LlamaNativeClient
from .clock import Clock, from_setting
from .config import Settings
from .decisions import answer_question, apply_decision
from .organizer import Organizer
import base64

from .schemas import AnswerIn, DecisionsIn, DecisionsOut, InboxIn, ItemsIn, ItemsOut, Rejected
from .skills import Harness, SkillRegistry
from .store import Store

log = logging.getLogger("organizer.api")

# Content bytes per GET /v1/inbox page (the Mac's request times out after 45 s over the SSH forward).
INBOX_PAGE_BYTES = 6 * 1024 * 1024


def chat_clients() -> dict:
    # Looked up at call time (tests and eval drivers substitute the client classes).
    return {"openai": OpenAIChatClient, "step3-llama-native": Step3LlamaNativeClient}


def image_route_clients(settings: Settings, registry: SkillRegistry) -> dict[str, ChatClient]:
    """ORGANIZER_IMAGE_ROUTES -> {image type or "detect": client}. Loopback endpoints only."""
    if not settings.image_routes.strip():
        return {}
    routes = json.loads(settings.image_routes)
    known = set(registry.script("image-read", "reading").TYPES) | {"detect"}
    clients: dict[str, ChatClient] = {}
    for key, spec in routes.items():
        if key not in known:
            raise ValueError(f"ORGANIZER_IMAGE_ROUTES: unknown image type {key!r}")
        host = urlsplit(spec["url"]).hostname
        if host not in ("127.0.0.1", "::1", "localhost"):
            raise ValueError(f"ORGANIZER_IMAGE_ROUTES: {key} must use a loopback URL")
        backend = spec.get("backend", "openai")
        if backend not in chat_clients():
            raise ValueError(f"ORGANIZER_IMAGE_ROUTES: unsupported backend {backend!r}")
        clients[key] = chat_clients()[backend](spec["url"], spec.get("model", "auto"), settings.llm_timeout_s)
    return clients


def build_organizer(settings: Settings, chat: Optional[ChatClient] = None,
                    embedder: Optional[EmbedClient] = None, store: Optional[Store] = None,
                    clock: Optional[Clock] = None) -> Organizer:
    clock = clock or (store.clock if store is not None else from_setting(settings.clock))
    store = store or Store(settings.db_path, clock)
    registry = SkillRegistry(settings.skills_dir)
    if chat is None:
        if settings.chat_backend not in chat_clients():
            raise ValueError(f"unsupported ORGANIZER_CHAT_BACKEND: {settings.chat_backend}")
        chat = chat_clients()[settings.chat_backend](settings.llm_base_url, settings.llm_model, settings.llm_timeout_s)
    image_clients = image_route_clients(settings, registry)
    if embedder is None and settings.embed_base_url:
        embedder = OpenAIEmbedClient(settings.embed_base_url, settings.embed_model)
    harness = Harness(registry, chat, store, record_inputs=settings.record_inputs)
    return Organizer(store, registry, harness, embedder,
                     max_open_questions=settings.max_open_questions, candidates_k=settings.candidates_k,
                     rank_max_events=settings.rank_max_events, rank_every_n_items=settings.rank_every_n_items,
                     job_max_attempts=settings.job_max_attempts, clock=clock,
                     ask_per_day=settings.ask_per_day, ask_per_event_per_day=settings.ask_per_event_per_day,
                     question_ttl_h=settings.question_ttl_h, owner_ids=settings.owner_person_ids,
                     owner_aliases=settings.owner_aliases, workers=settings.workers,
                     pipeline_lag=settings.pipeline_lag, image_clients=image_clients)


def create_app(settings: Optional[Settings] = None, organizer: Optional[Organizer] = None) -> FastAPI:
    settings = settings or Settings()
    org = organizer or build_organizer(settings)
    stop = threading.Event()
    # Created on first start and kept; while it exists (and ORGANIZER_REQUIRE_TOKEN != "0") every
    # request needs "Authorization: Bearer <token>". Held in memory only; never logged.
    token = ensure_link_token(settings.token_path)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        worker = None
        if settings.start_worker:
            worker = threading.Thread(target=org.run_worker, args=(stop,), name="organizer-worker", daemon=True)
            worker.start()
        yield
        stop.set()
        org.wake()
        if worker:
            worker.join(timeout=10)
        if org.pipeline is not None:
            org.pipeline.shutdown()

    app = FastAPI(title="organizer", version=__version__, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.organizer = org
    app.state.link_token = token

    if settings.require_token:
        @app.middleware("http")
        async def require_link_token(request: Request, call_next):
            # Every path, not only /v1/*: nothing is served without the token.
            if not bearer_matches(request.headers.get("authorization"), token):
                return JSONResponse({"detail": "missing or invalid link token"}, status_code=401,
                                    headers={"WWW-Authenticate": "Bearer"})
            return await call_next(request)

    @app.get("/v1/health")
    def health() -> dict:
        model: Optional[str]
        try:
            chat = org.harness.client
            model = chat.check_available() if hasattr(chat, "check_available") else chat.model_id
        except ModelUnavailable:
            model = None
        embed_model: Optional[str] = None
        if org.embedder is not None:
            try:
                embedder = org.embedder
                embed_model = embedder.check_available() if hasattr(embedder, "check_available") else embedder.model_id
            except ModelUnavailable:
                embed_model = None
        required_skills = {"event-assign", "event-brief", "home-rank", "image-read", "item-split", "file-read"}
        available_skills = {skill["name"] for skill in org.registry.summary()}
        return {
            "ok": model is not None and required_skills <= available_skills,
            "model": model,
            "skills": org.registry.summary(),
            "items": org.store.count_items(),
            "events": org.store.count_events(),
            "queue": org.store.queue_depth(),
            "embed_model": embed_model,
            "retrieval_mode": "embedding" if embed_model else "time_person_source_only",
            "version": __version__,
            "last_error": org.last_error,
            # Set when a wall-clock organizer processes items captured long before now (a backfill):
            # historical streams must run with ORGANIZER_CLOCK=replay (docs/DEPLOY_DEMO.md).
            "clock_warning": getattr(org, "clock_warning", None),
            "store_id": org.store.store_id,
            "clock": org.clock.mode,
            "inbox_pending": org.store.inbox_pending(),
            "workers": getattr(org, "workers", 1),
            # kind=file: None when every parser library is installed, else the missing module.
            "file_parsers_missing": fileparse.available(),
        }

    @app.post("/v1/items", response_model=ItemsOut)
    def post_items(body: ItemsIn) -> ItemsOut:
        items, images = [], []
        for it in body.items:
            d = it.model_dump(mode="json", exclude={"image_b64", "bytes_b64"})
            d["started_at"] = it.started_at.isoformat()
            d["ended_at"] = it.ended_at.isoformat() if it.ended_at else None
            d["captured_at"] = it.captured_at.isoformat() if it.captured_at else None
            items.append(d)
            images.append(it.blob())
        accepted, duplicates = org.ingest(items, images)
        return ItemsOut(accepted=accepted, duplicates=duplicates)

    @app.post("/v1/decisions", response_model=DecisionsOut)
    def post_decisions(body: DecisionsIn) -> DecisionsOut:
        applied, rejected = 0, []
        for i, d in enumerate(body.decisions):
            ok, note = apply_decision(org, d.model_dump(), origin="user")
            if ok:
                applied += 1
            else:
                rejected.append(Rejected(index=i, reason=note))
        return DecisionsOut(applied=applied, rejected=rejected)

    @app.get("/v1/state")
    def get_state(since: int = Query(default=0, ge=0)) -> dict:
        # store_id changes only when the database is recreated; the Mac then resets its projection.
        return {**org.state(since), "store_id": org.store.store_id}

    @app.post("/v1/questions/{question_id}/answer")
    def post_answer(question_id: str, body: AnswerIn) -> dict:
        status, note = answer_question(org, question_id, body.answer)
        if status != 200:
            raise HTTPException(status_code=status, detail=note)
        # 200 means the answer's decision is applied (also on a replay); "applied" says so explicitly.
        return {"ok": True, "applied": True, "note": note}

    # ---- phone inbox (contract C): held here only until the Mac acks it ----------------------

    @app.post("/v1/inbox")
    def post_inbox(body: InboxIn) -> dict:
        entry = body.model_dump(mode="json", exclude={"image_b64"})
        entry["received_at"] = body.received_at.isoformat()
        inbox_id, created = org.store.inbox_add(entry, body.image_bytes())
        return {"ok": True, "inbox_id": inbox_id, "duplicate": not created}

    @app.get("/v1/inbox")
    def get_inbox(since: int = Query(default=0, ge=0), limit: int = Query(default=20, ge=1, le=100)) -> dict:
        rows = org.store.inbox_since(since, limit)
        # A page stops once it holds INBOX_PAGE_BYTES of content (always at least one entry), so a run of
        # large screenshots arrives over several pulls instead of one response the client times out on.
        page, size = [], 0
        for r in rows:
            n = len(r["image"] or b"") + len((r["text"] or "").encode())
            if page and size + n > INBOX_PAGE_BYTES:
                break
            page.append(r)
            size += n
        items = [{"inbox_id": r["inbox_id"], "source": r["source"], "kind": r["kind"], "text": r["text"],
                  "image_b64": base64.b64encode(r["image"]).decode() if r["image"] else None,
                  "received_at": r["received_at"], "seq": r["seq"]} for r in page]
        cursor = page[-1]["seq"] if page else since
        return {"cursor": cursor, "items": items, "pending": org.store.inbox_pending(),
                "more": len(page) < len(rows) or len(rows) == limit}

    @app.post("/v1/inbox/{inbox_id}/ack")
    def ack_inbox(inbox_id: str) -> dict:
        status = org.store.inbox_ack(inbox_id)
        if status is None:
            raise HTTPException(status_code=404, detail="unknown inbox id")
        return {"ok": True, "acked": True, "already": not status}

    @app.get("/v1/debug/runs")
    def debug_runs(limit: int = Query(default=50, ge=1, le=500)) -> dict:
        return {"runs": org.store.recent_runs(limit)}

    @app.get("/v1/debug/jobs")
    def debug_jobs() -> dict:
        return {"jobs": org.store.all(
            "SELECT item_id, revision, state, attempts, reason, error_category, enqueued_at, run_started, run_ended"
            " FROM jobs ORDER BY started_ts")}

    return app
