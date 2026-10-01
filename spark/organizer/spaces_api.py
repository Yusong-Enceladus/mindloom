"""HTTP routes for shared spaces: /v1/spaces/... and /v1/orgs/... (docs/SPACES.md).

Every route still needs the link token (the transport: the member's own SSH tunnel to this Spark). On top of it,
space routes do not use the personal store's unlock or access proof: a member is identified by a signature of
one of its device keys, per op (the op log) or per request (reads, uploads, the organizer). The personal store
may be locked while a shared space is in use, and the other way round.

Signed request headers (organizer/space_crypto.py request_message):
  X-Mindloom-Device: <device_id>   X-Mindloom-Date: <unix seconds>   X-Mindloom-Nonce: <16-64 base64url chars>
  X-Mindloom-Signature: <base64url Ed25519 signature>
Errors are JSON {"error": "<code>", "detail"?: ..., ...} with the HTTP status; request bodies are never echoed.
"""

from __future__ import annotations

import json
from typing import Any, Callable, Optional

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, Response

from .space_organizer import SpaceOrganizers
from .spaces import ROLES, SpaceError, Spaces

MAX_BODY = 40 * 1024 * 1024


def _headers(request: Request) -> dict:
    h = request.headers
    return {"device": h.get("x-mindloom-device"), "date": h.get("x-mindloom-date"),
            "nonce": h.get("x-mindloom-nonce"), "signature": h.get("x-mindloom-signature")}


def _target(request: Request) -> str:
    raw = request.scope.get("raw_path") or request.url.path.encode()
    target = raw.decode("latin-1")
    query = request.scope.get("query_string") or b""
    return target + ("?" + query.decode("latin-1") if query else "")


async def _read(request: Request, limit: int = MAX_BODY) -> bytes:
    body = await request.body()
    if len(body) > limit:
        raise SpaceError(413, "too_large")
    return body


def _json(raw: bytes) -> Any:
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise SpaceError(400, "bad_json", "the body is not UTF-8 JSON") from None


def _int(request: Request, name: str, default: int, lo: int, hi: int) -> int:
    value = request.query_params.get(name)
    if value is None:
        return default
    try:
        n = int(value)
    except ValueError:
        raise SpaceError(400, "bad_query", f"{name} is an integer") from None
    if not lo <= n <= hi:
        raise SpaceError(400, "bad_query", f"{name} is {lo}-{hi}")
    return n


def _status(request: Request, allowed: set[str]) -> Optional[str]:
    value = request.query_params.get("status")
    if value is not None and value not in allowed:
        raise SpaceError(400, "bad_query", "status is " + "/".join(sorted(allowed)))
    return value


def register(app: FastAPI, spaces: Spaces, organizers: SpaceOrganizers) -> None:
    @app.exception_handler(SpaceError)
    async def on_space_error(request: Request, exc: SpaceError):
        return JSONResponse(exc.body(), status_code=exc.status)

    async def signed(request: Request, space_id: str, fn: Callable, *, min_role: int = ROLES["read"],
                     max_body: int = 1024 * 1024):
        """Authenticate the member device that signed the request, then run fn(actor, body) in the pool."""
        body = await request.body()
        if len(body) > max_body:
            raise SpaceError(413, "too_large")
        headers, target, method = _headers(request), _target(request), request.method

        def run():
            actor = spaces.authenticate(space_id, method, target, headers, body, min_role)
            return fn(actor, body)
        return await run_in_threadpool(run)

    # ---- this Spark ----------------------------------------------------------------------------------

    @app.get("/v1/spaces/host-keys")
    def host_keys() -> dict:
        """The Spark's SSH host public keys, for an invite that pins the host key."""
        return {"host_keys": spaces._host_keys()}

    # ---- organizations -----------------------------------------------------------------------------

    @app.post("/v1/orgs")
    async def post_org(request: Request):
        wire = _json(await _read(request, 1024 * 1024))
        return await run_in_threadpool(spaces.create_org, wire)

    @app.get("/v1/orgs/{org_id}")
    async def get_org(org_id: str, request: Request):
        body, headers, target = await request.body(), _headers(request), _target(request)

        def run():
            spaces.authenticate_org(org_id, "GET", target, headers, body)
            return spaces.org_summary(org_id)
        return await run_in_threadpool(run)

    @app.post("/v1/orgs/{org_id}/ops")
    async def post_org_ops(org_id: str, request: Request):
        data = _json(await _read(request))
        ops = data.get("ops") if isinstance(data, dict) else None
        return await run_in_threadpool(spaces.apply_org_ops, org_id, ops)

    @app.get("/v1/orgs/{org_id}/audit")
    async def get_org_audit(org_id: str, request: Request):
        body, headers, target = await request.body(), _headers(request), _target(request)
        since = _int(request, "since", 0, 0, 1 << 62)
        limit = _int(request, "limit", 200, 1, 1000)

        def run():
            spaces.authenticate_org(org_id, "GET", target, headers, body)
            return spaces.audit_log(org_id=org_id, since=since, limit=limit)
        return await run_in_threadpool(run)

    # ---- spaces ------------------------------------------------------------------------------------

    @app.get("/v1/spaces")
    async def list_spaces(request: Request):
        body, headers, target = await request.body(), _headers(request), _target(request)

        def run():
            device_id = spaces.authenticate_device("GET", target, headers, body)
            mine, orgs, pending = spaces.list_for_device(device_id)
            return {"device_id": device_id, "spaces": mine, "orgs": orgs, "pending_joins": pending}
        return await run_in_threadpool(run)

    @app.post("/v1/spaces")
    async def post_space(request: Request):
        wire = _json(await _read(request, 1024 * 1024))
        return await run_in_threadpool(spaces.create_space, wire)

    @app.get("/v1/spaces/{space_id}")
    async def get_space(space_id: str, request: Request):
        def fn(actor, body):
            spaces.sweep(space_id)
            out = spaces.summary(actor)
            organizers.expire(space_id)
            out["organizer"] = organizers.status(space_id)
            return out
        return await signed(request, space_id, fn)

    @app.post("/v1/spaces/{space_id}/ops")
    async def post_ops(space_id: str, request: Request):
        data = _json(await _read(request))
        ops = data.get("ops") if isinstance(data, dict) else None
        return await run_in_threadpool(spaces.apply_ops, space_id, ops)

    @app.get("/v1/spaces/{space_id}/ops")
    async def get_ops(space_id: str, request: Request):
        since = _int(request, "since", 0, 0, 1 << 62)
        limit = _int(request, "limit", 200, 1, 1000)
        return await signed(request, space_id, lambda actor, body: spaces.ops_since(actor, since, limit))

    @app.get("/v1/spaces/{space_id}/keys")
    async def get_keys(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: spaces.keys_for(actor))

    @app.get("/v1/spaces/{space_id}/item-keys")
    async def get_item_keys(space_id: str, request: Request):
        stale = request.query_params.get("stale") in ("1", "true")
        ids = request.query_params.getlist("item_id")
        limit = _int(request, "limit", 200, 1, 1000)
        return await signed(request, space_id, lambda actor, body: spaces.item_keys(actor, ids, stale, limit))

    @app.put("/v1/spaces/{space_id}/item-keys")
    async def put_item_keys(space_id: str, request: Request):
        def fn(actor, body):
            data = _json(body)
            return spaces.rewrap(actor, data.get("rewraps") if isinstance(data, dict) else None)
        return await signed(request, space_id, fn, min_role=ROLES["write"])

    @app.put("/v1/spaces/{space_id}/blobs/{blob_id}")
    async def put_blob(space_id: str, blob_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: spaces.put_blob(actor, blob_id, body),
                            min_role=ROLES["write"], max_body=MAX_BODY)

    @app.get("/v1/spaces/{space_id}/blobs/{blob_id}")
    async def get_blob(space_id: str, blob_id: str, request: Request):
        data = await signed(request, space_id, lambda actor, body: spaces.get_blob(actor, blob_id))
        return Response(content=data, media_type="application/octet-stream")

    @app.post("/v1/spaces/{space_id}/join")
    async def post_join(space_id: str, request: Request):
        wire = _json(await _read(request, 64 * 1024))
        return await run_in_threadpool(spaces.join, space_id, wire)

    @app.get("/v1/spaces/{space_id}/join/{request_id}")
    async def get_join(space_id: str, request_id: str, request: Request):
        body, headers, target = await request.body(), _headers(request), _target(request)
        return await run_in_threadpool(spaces.join_status, space_id, request_id, "GET", target, headers, body)

    @app.get("/v1/spaces/{space_id}/join-requests")
    async def get_join_requests(space_id: str, request: Request):
        status = _status(request, {"pending", "approved", "rejected"})
        return await signed(request, space_id,
                            lambda actor, body: {"requests": spaces.join_requests(actor, status)})

    @app.get("/v1/spaces/{space_id}/invites")
    async def get_invites(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: {"invites": spaces.invites(actor)})

    @app.get("/v1/spaces/{space_id}/takedowns")
    async def get_takedowns(space_id: str, request: Request):
        status = _status(request, {"open", "done", "rejected", "withdrawn"})

        def fn(actor, body):
            spaces.sweep(space_id)
            return {"takedowns": spaces.takedowns(actor, status)}
        return await signed(request, space_id, fn)

    @app.get("/v1/spaces/{space_id}/proposals")
    async def get_proposals(space_id: str, request: Request):
        status = _status(request, {"open", "accepted", "rejected", "withdrawn"})

        def fn(actor, body):
            organizer = [{"proposal_id": f"q:{q['question_id']}", "author": "organizer", "kind": q["kind"],
                          "question": q} for q in organizers.questions(space_id)] if status in (None, "open") else []
            return {"proposals": spaces.proposals(actor, status), "organizer": organizer}
        return await signed(request, space_id, fn)

    @app.get("/v1/spaces/{space_id}/audit")
    async def get_audit(space_id: str, request: Request):
        since = _int(request, "since", 0, 0, 1 << 62)
        limit = _int(request, "limit", 200, 1, 1000)
        return await signed(request, space_id, lambda actor, body: spaces.audit_log(space_id=space_id, since=since,
                                                                                     limit=limit),
                            min_role=ROLES["admin"])

    # ---- the space's organizer ----------------------------------------------------------------------

    @app.post("/v1/spaces/{space_id}/organizer/lease")
    async def post_lease(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: organizers.lease(actor, _json(body)),
                            max_body=4096)

    @app.post("/v1/spaces/{space_id}/organizer/lock")
    async def post_space_lock(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: organizers.lock(actor))

    @app.get("/v1/spaces/{space_id}/organizer/pending")
    async def get_pending(space_id: str, request: Request):
        limit = _int(request, "limit", 200, 1, 1000)
        return await signed(request, space_id, lambda actor, body: organizers.pending(actor, limit),
                            min_role=ROLES["write"])

    @app.post("/v1/spaces/{space_id}/organizer/items")
    async def post_space_items(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: organizers.ingest(actor, _json(body)),
                            min_role=ROLES["write"], max_body=MAX_BODY)

    @app.get("/v1/spaces/{space_id}/organizer/state")
    async def get_space_state(space_id: str, request: Request):
        since = _int(request, "since", 0, 0, 1 << 62)
        return await signed(request, space_id, lambda actor, body: organizers.state(actor, since))

    @app.post("/v1/spaces/{space_id}/organizer/decisions")
    async def post_space_decisions(space_id: str, request: Request):
        return await signed(request, space_id, lambda actor, body: organizers.decisions(actor, _json(body)),
                            min_role=ROLES["maintain"])

    @app.post("/v1/spaces/{space_id}/organizer/questions/{question_id}/answer")
    async def post_space_answer(space_id: str, question_id: str, request: Request):
        return await signed(request, space_id,
                            lambda actor, body: organizers.answer(actor, question_id, _json(body)),
                            min_role=ROLES["maintain"])
