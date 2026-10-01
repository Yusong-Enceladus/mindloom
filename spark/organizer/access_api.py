"""HTTP routes for per-member access (/v1/access/…; organizer/access.py, docs/INFRA.md).

Callers (decided by the auth middleware in api.py):
  owner   the link token (the Spark owner's Mac, over its own SSH tunnel): everything here;
  member  a member credential with its gate stamp (through `zhiji-inbox bridge`): its own records and Macs; an org
          admin also invites new people, sees the Spark's health and sees / unpairs the Macs of the people of its
          organizations (their org spaces' members and admins) and of the people it invited. Administering a space
          gives none of this (review finding V8R-06: any teammate may make a space); with
          ORGANIZER_SPACE_ADMINS_INVITE=1 the owner lets space admins invite new people too;
  enroll  only POST /v1/access/enroll/{ticket} with the ticket's gate stamp (the invite key's forced command).
"""

from __future__ import annotations

from typing import Optional

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse

from . import space_crypto as sc
from .access import Access, AccessError
from .spaces import Spaces


def caller(request: Request) -> str:
    return getattr(request.state, "caller", "owner")


def member_record(request: Request) -> Optional[dict]:
    return getattr(request.state, "access", None) if caller(request) == "member" else None


def device_view(access: Access, spaces: Spaces, member_id: str) -> dict:
    """GET /v1/access/devices: ids, public keys, states and the spaces / organizations each Mac is in. No content."""
    where = spaces.member_devices(member_id)
    records: dict[str, dict] = {}
    for r in access.records_of(member_id):  # the newest record of each device id wins
        records[r["device_id"]] = r
    out = []
    for device_id in list(dict.fromkeys([*records, *where["devices"]])):
        w = where["devices"].get(device_id) or {"spaces": [], "orgs": []}
        r = records.get(device_id)
        entry = {"device_id": device_id, "sign_pub": w.get("sign_pub") or r["sign_pub"],
                 "seal_pub": w.get("seal_pub") or r["seal_pub"], "access": Access.public(r) if r else None,
                 "spaces": w["spaces"], "orgs": w["orgs"]}
        active_spaces = sorted(x["space_id"] for x in w["spaces"] if x["status"] == "active")
        active_orgs = sorted(x["org_id"] for x in w["orgs"] if x["status"] == "active")
        if r is not None and r["status"] == "active":
            # a device once retired from a space is not added there again (device_exists)
            listed = {x["space_id"] for x in w["spaces"]}
            entry["to_add"] = {"spaces": [s for s in where["spaces"] if s not in listed],
                               "orgs": [o for o in where["orgs"] if o not in active_orgs]}
        elif r is not None:
            entry["to_remove"] = {"spaces": active_spaces, "orgs": active_orgs}
        out.append(entry)
    return {"member_id": member_id, "spaces": where["spaces"], "orgs": where["orgs"], "devices": out}


def register(app: FastAPI, access: Access, spaces: Spaces, *, space_admins_invite: bool = False) -> None:
    @app.exception_handler(AccessError)
    async def on_access_error(request: Request, exc: AccessError):
        return JSONResponse(exc.body(), status_code=exc.status)

    def scope_of(rec: dict) -> dict:
        scope = spaces.admin_scope(rec["member_id"], rec["device_id"])
        scope["may_invite"] = bool(scope["orgs"]) or (space_admins_invite and bool(scope["spaces"]))
        return scope

    def invited(rec: dict, member_id: str) -> bool:
        return any(r["invited_by"] == rec["access_id"] for r in access.records_of(member_id))

    def need_owner_or_member(request: Request) -> Optional[dict]:
        who = caller(request)
        if who == "enroll":
            raise AccessError(403, "forbidden")
        return member_record(request)

    async def body_json(request: Request) -> object:
        raw = await request.body()
        if len(raw) > 64 * 1024:
            raise AccessError(413, "too_large")
        if not raw:
            return None
        import json
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise AccessError(400, "bad_json") from None

    @app.get("/v1/access/me")
    def me(request: Request) -> dict:
        rec = need_owner_or_member(request)
        if rec is None:
            return {"caller": "owner", **access.stats()}
        scope = scope_of(rec)
        return {"caller": "member", "access": Access.public(rec), "org_admin_of": scope["orgs"],
                "space_admin_of": scope["spaces"], "may_invite": scope["may_invite"]}

    @app.post("/v1/access/tickets")
    async def post_ticket(request: Request):
        rec = need_owner_or_member(request)
        body = await body_json(request)
        if rec is None:
            member_id = body.get("member_id") if isinstance(body, dict) and body.get("kind") == "device" else None
            return await run_in_threadpool(access.create_ticket, body, created_by="owner", member_id=member_id)
        scope = scope_of(rec)
        return await run_in_threadpool(access.create_ticket, body, created_by=rec["access_id"],
                                       member_id=rec["member_id"], allow_member=scope["may_invite"])

    @app.get("/v1/access/tickets")
    def get_tickets(request: Request) -> dict:
        rec = need_owner_or_member(request)
        return {"tickets": access.tickets(None if rec is None else rec["access_id"], with_keys=rec is None)}

    @app.delete("/v1/access/tickets/{ticket_id}")
    def delete_ticket(ticket_id: str, request: Request) -> dict:
        rec = need_owner_or_member(request)
        return access.revoke_ticket(ticket_id, by="owner" if rec is None else rec["access_id"], owner=rec is None)

    @app.post("/v1/access/enroll/{ticket_id}")
    async def post_enroll(ticket_id: str, request: Request):
        if caller(request) != "enroll":
            raise AccessError(403, "forbidden", "enrollment comes through the ticket's own key")
        wire = await body_json(request)
        return await run_in_threadpool(
            access.enroll, ticket_id, wire, known_sign_pub=spaces._known_sign_pub,
            known_member=spaces._space_device_member,
            # V8R-08: a member id this Spark already knows is enrolled only with one of the keys it is bound to
            member_id_keys=lambda m: spaces._member_id_keys(m) if (spaces._member_id_known(m) or
                                                                   spaces._member_id_keys(m)) else None)

    @app.get("/v1/access/members")
    def get_members(request: Request) -> dict:
        rec = need_owner_or_member(request)
        if rec is None:
            # the owner's Mac keeps the relay's team lines in step with these keys (review finding V8R-12)
            return {"members": access.members(with_keys=True)}
        scope = scope_of(rec)
        return {"members": access.members(scope["org_members"] | {rec["member_id"]}, invited_by=rec["access_id"])}

    @app.get("/v1/access/devices")
    def get_devices(request: Request, member_id: Optional[str] = None) -> dict:
        """v8 (one member, several Macs): a member's Macs, each with its access state and where it is in this Spark's
        spaces and organizations, plus the work list a Mac of that member (or an admin) signs: `to_add` for a paired
        Mac (device.add in those spaces, org.device_add in those organizations), `to_remove` for an unpaired one that
        is still in some (device.remove there, which rotates the key; org.device_remove). A member asks about itself;
        an org or space admin about a member in its scope or one it invited; the owner about anyone (member_id
        required)."""
        rec = need_owner_or_member(request)
        if rec is None:
            if not sc.is_uuid(member_id):
                raise AccessError(422, "bad_field", "member_id is a lowercase UUID")
        elif member_id is None or member_id == rec["member_id"]:
            member_id = rec["member_id"]
        else:
            scope = scope_of(rec)
            if not sc.is_uuid(member_id) or not (invited(rec, member_id) or member_id in scope["org_members"]):
                raise AccessError(403, "forbidden",
                                  "you see your own Macs, or as an org admin those of your organization's people")
        return device_view(access, spaces, member_id)

    @app.delete("/v1/access/members/{access_id}")
    def delete_member(access_id: str, request: Request) -> dict:
        rec = need_owner_or_member(request)
        target = access.record(access_id)
        if target is None:
            raise AccessError(404, "unknown_access")
        if rec is not None:
            # V8R-06: one's own Macs; an org admin those of its organizations' people and of the people it invited.
            # A space admin unpairs nobody else from the whole Spark (it removes them from its space instead).
            scope = scope_of(rec)
            allowed = target["member_id"] == rec["member_id"] or \
                (bool(scope["orgs"]) and (target["member_id"] in scope["org_members"] or
                                          target["invited_by"] == rec["access_id"]))
            if not allowed:
                raise AccessError(403, "forbidden",
                                  "you unpair your own Macs, or as an org admin those of your organization's people")
        return access.revoke(access_id, by="owner" if rec is None else rec["access_id"])

    @app.get("/v1/infra/health")
    def infra_health(request: Request) -> dict:
        """The admin console's Spark health (organizer/infra.py): the owner, or an org / space admin's Mac."""
        rec = need_owner_or_member(request)
        if rec is None:
            return app.state.infra.health()
        if not scope_of(rec)["orgs"]:
            raise AccessError(403, "forbidden", "the Spark's health is for the owner and the org admins")
        # V8R-14: the owner's personal store (locked or not, its queue, its last error) is the owner's alone
        out = dict(app.state.infra.health())
        organizer = {k: v for k, v in (out.get("organizer") or {}).items() if k != "personal_store"}
        out["organizer"] = organizer
        return out

    @app.get("/v1/access/audit")
    def get_audit(request: Request, since: int = 0, limit: int = 200) -> dict:
        rec = need_owner_or_member(request)
        since, limit = max(0, since), max(1, min(limit, 1000))
        if rec is None:
            return access.audit_log(since, limit)
        scope = scope_of(rec)
        return access.audit_log(since, limit, member_ids=scope["org_members"] | {rec["member_id"]})
