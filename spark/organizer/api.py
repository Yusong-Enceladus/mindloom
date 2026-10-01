"""FastAPI app for the organizer contract v1 (bind to 127.0.0.1 only; reach it over SSH).

Privacy contract v6 (docs/PRIVACY.md): the store starts locked. POST /v1/unlock {"key"} opens it with the Mac's
library key (kept in memory only), POST /v1/lock closes it, POST /v1/wipe {"key_id"} deletes it. While it is
locked every data route answers 423 {"error":"locked"}; only /v1/health, unlock / lock / wipe and the phone's
inbox add keep working. DELETE /v1/items/{item_id} purges an item (a later POST of the id is 410), and
GET /v1/stats reports sizes.
"""

from __future__ import annotations

import json
import logging
import threading
from contextlib import asynccontextmanager
from typing import Optional
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import __version__, fileparse, keys
from .auth import bearer_matches, ensure_link_token
from .clients import ChatClient, EmbedClient, ModelUnavailable, OpenAIChatClient, OpenAIEmbedClient
from .clients import Step3LlamaNativeClient
from .clock import Clock, from_setting
from .config import Settings
from .decisions import answer_question, apply_decision
from .inbox import InboxStore
from .organizer import Organizer
import base64

from .schemas import AnswerIn, DecisionsIn, DecisionsOut, InboxIn, ItemsIn, ItemsOut, Rejected
from .skills import Harness, SkillRegistry
from .store import Store, StoreLocked, WrongKey

log = logging.getLogger("organizer.api")

# Content bytes per GET /v1/inbox page (the Mac's request times out after 45 s over the SSH forward).
INBOX_PAGE_BYTES = 6 * 1024 * 1024

# What answers while the store is locked (everything else under /v1/ is 423): health, the key routes, and
# the phone's inbox add (its status comes from /v1/health).
# The key-derived access proof (keys.access_proof) of every data request after the Mac's unlock.
ACCESS_HEADER = "x-mindloom-access"

OPEN_WHILE_LOCKED = {("GET", "/v1/health"), ("POST", "/v1/unlock"), ("POST", "/v1/lock"), ("POST", "/v1/wipe"),
                     ("POST", "/v1/inbox")}


def locked_response() -> JSONResponse:
    return JSONResponse({"error": "locked"}, status_code=423)


def inbox_entry_out(r: dict) -> dict:
    """One GET /v1/inbox entry. A sealed entry is only its id, kind, blob (the phone's mlseal1 string, as
    received) and times; the Mac opens it with its seal key and the id (phone contract section 5)."""
    if r["kind"] == "sealed":
        return {"inbox_id": r["inbox_id"], "kind": "sealed", "blob": r["blob"], "received_at": r["received_at"],
                "seq": r["seq"]}
    # A plaintext row can only be one handed over from an organizer.db written before inbox.db (InboxStore.import_legacy).
    return {"inbox_id": r["inbox_id"], "source": r["source"], "kind": r["kind"], "text": r["text"],
            "image_b64": base64.b64encode(r["image"]).decode() if r["image"] else None,
            "received_at": r["received_at"], "seq": r["seq"]}


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
    # Locked until the Mac unlocks it, unless a harness on synthetic data passes its key (settings.unlock_key).
    store = store or Store(settings.db_path, clock, key=settings.unlock_key)
    inbox = InboxStore(":memory:" if store.memory else settings.inbox_path)
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
                     pipeline_lag=settings.pipeline_lag, image_clients=image_clients, inbox=inbox,
                     unlock_lease_s=settings.unlock_lease_s, log_file=settings.log_file,
                     consolidate={"enabled": settings.consolidate, "every_items": settings.consolidate_every,
                                  "max_calls": settings.consolidate_max_calls,
                                  "idle_min_items": settings.consolidate_idle_items,
                                  "subject_max_items": settings.consolidate_subject_max,
                                  "unfile_max_items": settings.consolidate_unfile_max,
                                  "directory_size": settings.consolidate_directory_size,
                                  "directory_min_items": settings.consolidate_directory_min},
                     people={"enabled": settings.people_pass, "every_items": settings.people_every,
                             "max_calls": settings.people_max_calls})


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
    if org.inbox is None:
        org.inbox = InboxStore(settings.inbox_path)

    # Registered before the token check, so it runs inside it: an unauthenticated caller never learns
    # whether the store is locked.
    @app.middleware("http")
    async def locked_gate(request: Request, call_next):
        path = request.url.path.rstrip("/") or "/"
        org.expire_lease()  # the Mac stopped asking: the store locks before anything is read
        if path.startswith("/v1/") and (request.method, path) not in OPEN_WHILE_LOCKED:
            if org.store.locked:
                return locked_response()
            # Privacy review F1: after the Mac's unlock, the link token (a file anyone on the Spark account can
            # read) is not enough to read the store; the request must carry the key-derived access proof.
            if not org.check_access(request.headers.get(ACCESS_HEADER)):
                return JSONResponse({"error": "access"}, status_code=403)
            org.renew_lease()
        return await call_next(request)

    @app.exception_handler(StoreLocked)
    async def on_locked(request: Request, exc: StoreLocked):
        return locked_response()  # locked while the request ran

    @app.exception_handler(RequestValidationError)
    async def on_invalid(request: Request, exc: RequestValidationError):
        # A refused phone entry is answered without echoing it: no plaintext share in an error body, and no
        # 48 MB sealed blob sent back. Other routes keep FastAPI's usual answer.
        if (request.url.path.rstrip("/") or "/") == "/v1/inbox":
            detail = [{"type": e.get("type"), "loc": list(e.get("loc", ())), "msg": str(e.get("msg", ""))[:200]}
                      for e in exc.errors()]
            return JSONResponse({"detail": detail}, status_code=422)
        return await request_validation_exception_handler(request, exc)

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
        required_skills = {"event-assign", "event-brief", "home-rank", "image-read", "item-split", "file-read",
                           "event-consolidate", "person-resolve"}
        available_skills = {skill["name"] for skill in org.registry.summary()}
        store = org.store
        locked = store.locked
        try:
            counts = (None, None, None) if locked else (store.count_items(), store.count_events(), store.queue_depth())
            store_id = None if locked else store.store_id
        except StoreLocked:
            locked, counts, store_id = True, (None, None, None), None
        return {
            "ok": model is not None and required_skills <= available_skills,
            # Contract v6: whether the store is locked, and the key_id of the store on disk (null: none yet).
            "locked": locked,
            "key_id": store.disk_key_id(),
            "model": model,
            "skills": org.registry.summary(),
            "items": counts[0],
            "events": counts[1],
            "queue": counts[2],
            "embed_model": embed_model,
            "retrieval_mode": "embedding" if embed_model else "time_person_source_only",
            "version": __version__,
            # Error types only, and nothing while locked (review F15).
            "last_error": None if locked else org.last_error,
            # Set when a wall-clock organizer processes items captured long before now (a backfill):
            # historical streams must run with ORGANIZER_CLOCK=replay (docs/DEPLOY_DEMO.md).
            "clock_warning": getattr(org, "clock_warning", None),
            "store_id": store_id,
            "clock": org.clock.mode,
            "inbox_pending": org.inbox.pending(),
            "workers": getattr(org, "workers", 1),
            # The consolidation pass since this process started (counts only, no content).
            "consolidation": dict(org.consolidator.stats, enabled=org.consolidator.enabled),
            # The people pass since this process started (counts only, no names).
            "people": dict(org.people_pass.stats, enabled=org.people_pass.enabled),
            # kind=file: None when every parser library is installed, else the missing module.
            "file_parsers_missing": fileparse.available(),
        }

    # ---- keys (privacy contract section 2) ----------------------------------------------------

    @app.post("/v1/unlock")
    async def post_unlock(request: Request):
        # The body is read by hand: a validation error must never echo the key back.
        try:
            body = await request.json()
        except ValueError:
            body = None
        key = keys.parse_key_hex(body.get("key") if isinstance(body, dict) else None)
        if key is None:
            return JSONResponse({"error": "bad_key"}, status_code=400)
        try:
            res = await run_in_threadpool(lambda: org.unlock(key, via_link=True))
        except WrongKey as exc:
            return JSONResponse({"error": "wrong_key", "key_id": exc.key_id}, status_code=409)
        finally:
            del key
        return res

    @app.post("/v1/lock")
    def post_lock() -> dict:
        return org.lock()

    @app.post("/v1/wipe")
    async def post_wipe(request: Request):
        try:
            body = await request.json()
        except ValueError:
            body = None
        key_id = body.get("key_id") if isinstance(body, dict) else None
        if key_id is not None and not (isinstance(key_id, str) and keys.KEY_ID_RE.fullmatch(key_id)):
            return JSONResponse({"error": "bad_key_id"}, status_code=400)
        try:
            return await run_in_threadpool(org.wipe, key_id)
        except WrongKey as exc:
            return JSONResponse({"error": "wrong_key", "key_id": exc.key_id}, status_code=409)

    @app.get("/v1/stats")
    def get_stats() -> dict:
        return org.store.stats()

    @app.delete("/v1/items/{item_id}")
    def delete_item(item_id: str) -> dict:
        if not item_id or len(item_id) > 128:
            raise HTTPException(status_code=400, detail="bad item id")
        org.delete_item(item_id)
        return {"deleted": True}

    @app.post("/v1/items", response_model=ItemsOut)
    def post_items(body: ItemsIn):
        gone = org.store.tombstoned([it.item_id for it in body.items])
        if gone:
            # Deleted by the user on the Mac: never stored again under that id.
            return JSONResponse({"error": "deleted", "item_ids": gone}, status_code=410)
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
            decision = d.model_dump()
            for key in ("title", "display_name"):  # user-typed text: masked again like any incoming text
                if decision.get(key):
                    decision[key] = org.store.mask_text(decision[key])
            ok, note = apply_decision(org, decision, origin="user")
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
        # Sealed entries only (schemas.InboxIn): the Spark stores the phone's mlseal1 string and cannot open it.
        entry = body.model_dump(mode="json")
        entry["received_at"] = body.received_at.isoformat()
        inbox_id, created = org.inbox.add(entry, None)
        # "id" is what the phone app reads (phone contract section 5); "inbox_id" is the older name.
        return {"ok": True, "id": inbox_id, "inbox_id": inbox_id, "duplicate": not created}

    @app.get("/v1/inbox")
    def get_inbox(since: int = Query(default=0, ge=0), limit: int = Query(default=20, ge=1, le=100)) -> dict:
        # A page stops once it holds INBOX_PAGE_BYTES of content (always at least one entry), so a run of
        # large screenshots or sealed documents arrives over several pulls instead of one response the client
        # times out on; only the entries on the page are read from disk.
        page, more = org.inbox.page(since, limit, INBOX_PAGE_BYTES)
        items = [inbox_entry_out(r) for r in page]
        cursor = page[-1]["seq"] if page else since
        return {"cursor": cursor, "items": items, "pending": org.inbox.pending(), "more": more}

    @app.post("/v1/inbox/{inbox_id}/ack")
    def ack_inbox(inbox_id: str) -> dict:
        status = org.inbox.ack(inbox_id)
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
