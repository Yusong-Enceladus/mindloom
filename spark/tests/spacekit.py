"""Test kit for shared spaces: a member Mac played in Python (its own synthetic data root, device keys and the
space keys it unwrapped) against one Spark app (FastAPI TestClient). All content is invented.

The Mac side follows organizer/space_member.py, the reference the Swift app follows.
"""

from __future__ import annotations

import json
import os
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from organizer import space_crypto as sc
from organizer import space_member as sm

HOST_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISyntheticHostKeyForTestsOnly00000000000"
TZ = timezone(timedelta(hours=8))


class Clock:
    """The Spark's clock in tests (withdraw windows, invite expiry, takedown deadlines, request dates)."""

    def __init__(self, t: float = 1_790_000_000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, hours: float = 0, seconds: float = 0) -> None:
        self.t += hours * 3600 + seconds


def new_id() -> str:
    return str(uuid.uuid4())


class Mac:
    """One member's Mac: a device, a member id, and what it holds locally (space keys per epoch, the data keys
    and originals of the items it shared or opened)."""

    def __init__(self, client, clock: Clock, name: str = "mac"):
        self.c = client
        self.clock = clock
        self.name = name
        self.device = sm.Device()
        self.member_id = new_id()
        self.space_keys: dict[str, dict[int, bytes]] = {}
        self.data_keys: dict[tuple[str, str], bytes] = {}
        self.invite_secrets: dict[str, bytes] = {}   # invites this Mac sent (the secret never leaves the two Macs)

    # ---- transport -----------------------------------------------------------------------------------

    def signed(self, method: str, path: str, *, body: bytes = b"", params: Optional[dict] = None,
               content_type: str = "application/json", device: Optional[sm.Device] = None):
        from urllib.parse import urlencode
        query = urlencode(params or {}, doseq=True)
        target = path + ("?" + query if query else "")
        dev = device or self.device
        headers = dev.request_headers(method, target, body, date=int(self.clock()))
        if body:
            headers["Content-Type"] = content_type
        return self.c.request(method, target, content=body if body else None, headers=headers)

    def get(self, path: str, **params):
        return self.signed("GET", path, params=params)

    def post_json(self, path: str, obj: Any):
        return self.signed("POST", path, body=json.dumps(obj).encode())

    def op(self, space_id: str, type_: str, body: dict, **kw) -> dict:
        wire = self.device.op(space_id, self.member_id, type_, body, **kw)
        r = self.c.post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]})
        assert r.status_code == 200, r.text
        return r.json()["results"][0]

    def ok(self, space_id: str, type_: str, body: dict, **kw) -> dict:
        res = self.op(space_id, type_, body, **kw)
        assert res["ok"], res
        return res

    # ---- keys --------------------------------------------------------------------------------------

    def key(self, space_id: str, epoch: Optional[int] = None) -> bytes:
        keys = self.space_keys[space_id]
        return keys[epoch if epoch is not None else max(keys)]

    def epoch(self, space_id: str) -> int:
        return max(self.space_keys[space_id])

    def sync_keys(self, space_id: str) -> dict:
        r = self.get(f"/v1/spaces/{space_id}/keys")
        assert r.status_code == 200, r.text
        data = r.json()
        keys = self.space_keys.setdefault(space_id, {})
        for w in data["wraps"]:
            keys[w["epoch"]] = sm.unwrap_space_key(w["wrap"], self.device.seal_priv, space_id, w["epoch"],
                                                   self.device.device_id)
        # walk the epoch links back to the first epoch (history, and the mask key)
        links = {l["epoch"]: l["prev_wrap"] for l in data["epoch_links"]}
        e = max(keys) if keys else None
        while e is not None and e in links and (e - 1) not in keys:
            keys[e - 1] = sm.open_epoch_link(links[e], keys[e], space_id, e)
            e -= 1
        return data

    def lease_keys(self, space_id: str, epoch: Optional[int] = None) -> dict:
        e = epoch or self.epoch(space_id)
        return {"epoch": e, "store_key": sm.store_key(self.key(space_id, e)).hex(),
                "mask_key": sm.mask_key(self.key(space_id, 1)).hex()}

    # ---- flows -------------------------------------------------------------------------------------

    def create_org(self) -> str:
        org_id = new_id()
        wire = self.device.org_op(org_id, self.member_id, "org.create",
                                  {"device": self.device.public(), "policy": {"recovery_admins": 1}})
        r = self.c.post("/v1/orgs", json=wire)
        assert r.status_code == 200 and r.json()["ok"], r.text
        return org_id

    def create_space(self, owner: str = "person", org_id: Optional[str] = None,
                     policy: Optional[dict] = None, name: str = "测试空间") -> str:
        space_id = new_id()
        k1 = os.urandom(32)
        self.space_keys[space_id] = {1: k1}
        op_id = new_id()
        body = {"owner": {"kind": owner, **({"org_id": org_id} if org_id else {})}, "device": self.device.public(),
                "wraps": sm.wraps_for(k1, [self.device.public()], space_id, 1)}
        if policy:
            body["policy"] = policy
        wire = self.device.op(space_id, self.member_id, "space.create", body, epoch=1, op_id=op_id,
                              enc=sm.enc_op(k1, {"name": name}, space_id, op_id))
        r = self.c.post("/v1/spaces", json=wire)
        assert r.status_code == 200 and r.json()["ok"], r.text
        return space_id

    def invite(self, space_id: str, role: str = "write", hours: float = 24 * 7, outside: bool = False,
               host_key: Optional[str] = HOST_KEY) -> dict:
        secret = os.urandom(32)
        invite_id = new_id()
        expires = datetime.fromtimestamp(self.clock() + hours * 3600, timezone.utc).isoformat()
        body = {"invite_id": invite_id, "secret_hash": sc.invite_gate_hash(sm.invite_gate(secret)),
                "expires_at": expires, "role": role, "outside": outside}
        self.invite_secrets[invite_id] = secret
        if host_key:
            body["host_key"] = host_key
        res = self.op(space_id, "invite.create", body)
        return {"invite_id": invite_id, "secret": secret, "result": res,
                "inviter_seal_pub": self.device.seal_pub}

    def request_join(self, space_id: str, invite: dict, name: str = "新成员", member_id: Optional[str] = None,
                     secret: Optional[bytes] = None):
        request_id = new_id()
        profile = sm.seal_profile({"display_name": name}, invite["inviter_seal_pub"], space_id, request_id)
        wire = self.device.join(space_id, invite["invite_id"], secret or invite["secret"],
                                member_id or self.member_id, request_id=request_id, profile=profile)
        return self.c.post(f"/v1/spaces/{space_id}/join", json=wire)

    def join_request(self, space_id: str, request_id: str) -> dict:
        r = self.get(f"/v1/spaces/{space_id}/join-requests", status="pending")
        assert r.status_code == 200, r.text
        return next(x for x in r.json()["requests"] if x["request_id"] == request_id)

    def approve(self, space_id: str, request_id: str, role: Optional[str] = None) -> dict:
        """同意: checks the request (signed by its device; the HMAC binding only an invite holder can make, when
        this Mac sent the invite), then signs the joiner's member id and both public keys with the wrap."""
        req = self.join_request(space_id, request_id)
        problem = sm.check_join_request(req, self.invite_secrets.get(req["invite_id"]))
        assert problem in (None, "unverifiable"), problem
        e = self.epoch(space_id)
        body = {"request_id": request_id, "member_id": req["member_id"], "device": req["device"],
                "wraps": sm.wraps_for(self.key(space_id, e), [req["device"]], space_id, e)}
        if role:
            body["role"] = role
        return self.op(space_id, "join.approve", body)

    def roster(self, space_id: str) -> tuple[dict, list[dict], list[dict]]:
        """Members and devices as the signed log admits them (space_member.replay), never the Spark's list."""
        r = self.get(f"/v1/spaces/{space_id}/ops", since=0, limit=1000)
        assert r.status_code == 200, r.text
        return sm.replay(r.json()["ops"], space_id)

    def active_devices(self, space_id: str, exclude_member: Optional[str] = None) -> list[dict]:
        return sm.active_devices(self.roster(space_id)[0], exclude_member)

    def rotation_body(self, space_id: str, exclude_member: Optional[str] = None) -> tuple[dict, bytes]:
        roster = self.roster(space_id)[0]
        # The epoch in use is the newest of the keys held and the log's own rotations (never the Spark's word).
        e = max(self.epoch(space_id), roster["epoch"]) + 1
        new_key = os.urandom(32)
        devices = sm.active_devices(roster, exclude_member)
        body = {"epoch": e, "wraps": sm.wraps_for(new_key, devices, space_id, e),
                "epoch_link": sm.epoch_link(new_key, self.key(space_id), space_id, e)}
        return body, new_key

    def remove_member(self, space_id: str, member_id: str) -> dict:
        body, new_key = self.rotation_body(space_id, exclude_member=member_id)
        body["member_id"] = member_id
        res = self.op(space_id, "member.remove", body)
        if res["ok"]:
            self.space_keys[space_id][body["epoch"]] = new_key
        return res

    def rotate(self, space_id: str) -> dict:
        body, new_key = self.rotation_body(space_id)
        res = self.op(space_id, "epoch.rotate", body)
        if res["ok"]:
            self.space_keys[space_id][body["epoch"]] = new_key
        return res

    def upload(self, space_id: str, item_id: str, data: bytes, data_key: bytes) -> str:
        blob_id = new_id()
        blob = sm.seal_blob(data_key, data, space_id, item_id, blob_id)
        r = self.signed("PUT", f"/v1/spaces/{space_id}/blobs/{blob_id}", body=blob,
                        content_type="application/octet-stream")
        assert r.status_code == 200, r.text
        return blob_id

    def share(self, space_id: str, text: str, *, kind: str = "text", item_id: Optional[str] = None,
              revision: int = 1, original: Optional[bytes] = None, blob_role: str = "original",
              segment: Optional[dict] = None, extra: Optional[dict] = None) -> dict:
        item_id = item_id or new_id()
        dk = os.urandom(32)
        e = self.epoch(space_id)
        blobs = []
        if original is not None:
            blobs.append({"blob_id": self.upload(space_id, item_id, original, dk), "role": blob_role})
        body = {"item_id": item_id, "revision": revision, "kind": kind, "blobs": blobs}
        if segment:
            body["segment"] = segment
        if extra:
            body.update(extra)
        res = self.op(space_id, "item.share", body, epoch=e,
                      enc=sm.enc_item(dk, {"text": text, "title": text[:12]}, space_id, item_id, revision),
                      wrapped_dk=sm.wrap_item_key(self.key(space_id, e), dk, space_id, e, item_id))
        if res["ok"]:
            self.data_keys[(space_id, item_id)] = dk
        return {"item_id": item_id, "result": res, "blobs": blobs, "data_key": dk}

    def read_items(self, space_id: str) -> dict[str, dict]:
        """Every shared item this Mac can open from the Spark: op log + current item keys + space keys."""
        r = self.get(f"/v1/spaces/{space_id}/ops", since=0, limit=1000)
        assert r.status_code == 200, r.text
        out = {}
        for entry in r.json()["ops"]:
            if entry["type"] != "item.share" or not entry.get("item_key") or not entry.get("enc"):
                continue
            op = json.loads(sc.b64u_decode(entry["op"]))
            item_id, rev = op["body"]["item_id"].lower(), op["body"]["revision"]
            k = entry["item_key"]
            dk = sm.unwrap_item_key(k["wrapped_dk"], self.key(space_id, k["epoch"]), space_id, k["epoch"], item_id)
            out[item_id] = sm.dec_item(entry["enc"], dk, space_id, item_id, rev)
        return out

    def lease(self, space_id: str, previous_epoch: Optional[int] = None):
        body = self.lease_keys(space_id)
        if previous_epoch is not None:
            body["previous"] = {"epoch": previous_epoch,
                                "store_key": sm.store_key(self.key(space_id, previous_epoch)).hex()}
        return self.post_json(f"/v1/spaces/{space_id}/organizer/lease", body)

    def organize(self, space_id: str, items: list[dict]):
        return self.post_json(f"/v1/spaces/{space_id}/organizer/items", {"items": items})


def payload(item_id: str, text: str, *, minutes: int = 0, revision: int = 1, origin: Optional[str] = None,
            persons: Optional[list] = None, kind: str = "dictation") -> dict:
    """An organizing payload (the v6 item format) for a shared item."""
    started = datetime(2026, 9, 20, 9, 0, tzinfo=TZ) + timedelta(minutes=minutes)
    p = {"item_id": item_id, "revision": revision, "kind": kind,
         "source_app": {"bundle_id": "com.apple.Notes", "name": "备忘录"},
         "started_at": started.isoformat(), "ended_at": (started + timedelta(minutes=1)).isoformat(),
         "text": text, "sha256": secrets.token_hex(32)}
    if origin:
        p["origin_matter_id"] = origin
    if persons is not None:
        p["persons"] = persons
    return p
