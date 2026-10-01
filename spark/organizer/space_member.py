"""Reference member device for shared spaces (SPACES-CONTRACT section 3): what a member's Mac does.

The Spark service never imports this module (tests/test_spaces_crypto.py checks that): it holds space keys and
opens ciphertext, which the Spark must never do. It exists for three uses, all on synthetic data:
  * the shared vectors privacy/space_vectors.json (privacy/make_space_vectors.py), which the Mac's Swift code
    (CryptoKit) reproduces byte for byte;
  * the tests, which play two or more member Macs against one Spark;
  * the E2E harness (eval/tools/spaces_e2e.py) against a deployed test instance.

Keys (per device, in the Mac's Keychain): an Ed25519 signing key and an X25519 seal key.
Space key K_e: 32 random bytes per epoch e, made by the creator's Mac (e = 1) and by an admin's Mac at each
rotation. Derived:
  store_key(e)  = HMAC-SHA256(K_e, "mindloom-space-store-v1")    SQLCipher key of the space organizer store
  mask_key      = HMAC-SHA256(K_1, "mindloom-space-mask-v1")     placeholder tags; from the FIRST epoch's key,
                  so a number keeps its placeholder across rotations (every member reaches K_1 through the
                  epoch links)
  item data key = 32 random bytes per shared item revision, wrapped by K_e
All AEAD is ChaCha20-Poly1305 (CryptoKit ChaChaPoly) with a 12-byte random nonce; HKDF is HKDF-SHA256.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import space_crypto as sc

WRAP_INFO = b"mindloom-space-wrap-v1"
ELINK_INFO = b"mindloom-space-epoch-link-v1"
IKEY_INFO = b"mindloom-space-item-key-v1"
ITEM_ENC_INFO = b"mindloom-space-item-enc-v1"
OP_ENC_INFO = b"mindloom-space-op-enc-v1"
BLOB_INFO = b"mindloom-space-blob-v1"
PROFILE_INFO = b"mindloom-space-join-profile-v1"

_RAW = serialization.Encoding.Raw
_RAWPUB = serialization.PublicFormat.Raw
_RAWPRIV = serialization.PrivateFormat.Raw
_NOENC = serialization.NoEncryption()


def hkdf(ikm: bytes, info: bytes, salt: bytes = b"", length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt or None, info=info).derive(ikm)


def _aead(key: bytes, nonce: bytes, data: bytes, aad: bytes) -> bytes:
    return ChaCha20Poly1305(key).encrypt(nonce, data, aad)


def _open(key: bytes, nonce: bytes, data: bytes, aad: bytes) -> bytes:
    return ChaCha20Poly1305(key).decrypt(nonce, data, aad)


def _nonce(nonce: Optional[bytes]) -> bytes:
    return nonce if nonce is not None else os.urandom(12)


# ---- derived keys ------------------------------------------------------------------------------------------


def store_key(space_key: bytes) -> bytes:
    return hmac.new(space_key, b"mindloom-space-store-v1", hashlib.sha256).digest()


def mask_key(first_epoch_key: bytes) -> bytes:
    return hmac.new(first_epoch_key, b"mindloom-space-mask-v1", hashlib.sha256).digest()


# ---- space-key wraps (sealed to one device) -----------------------------------------------------------------


def wrap_aad(space_id: str, epoch: int, device_id: str) -> bytes:
    return f"mindloom-space-wrap-v1|{space_id}|{epoch}|{device_id}".encode()


def wrap_space_key(space_key: bytes, seal_pub: bytes, space_id: str, epoch: int, device_id: str,
                   eph_priv: Optional[bytes] = None, nonce: Optional[bytes] = None) -> str:
    eph = X25519PrivateKey.from_private_bytes(eph_priv) if eph_priv else X25519PrivateKey.generate()
    eph_pub = eph.public_key().public_bytes(_RAW, _RAWPUB)
    shared = eph.exchange(X25519PublicKey.from_public_bytes(seal_pub))
    key = hkdf(shared, WRAP_INFO, salt=eph_pub + seal_pub)
    n = _nonce(nonce)
    return sc.WRAP_PREFIX + sc.b64u(eph_pub + n + _aead(key, n, space_key, wrap_aad(space_id, epoch, device_id)))


def unwrap_space_key(wrap: str, seal_priv: bytes, space_id: str, epoch: int, device_id: str) -> bytes:
    raw = sc.b64u_decode(wrap[len(sc.WRAP_PREFIX):])
    eph_pub, n, body = raw[:32], raw[32:44], raw[44:]
    priv = X25519PrivateKey.from_private_bytes(seal_priv)
    my_pub = priv.public_key().public_bytes(_RAW, _RAWPUB)
    key = hkdf(priv.exchange(X25519PublicKey.from_public_bytes(eph_pub)), WRAP_INFO, salt=eph_pub + my_pub)
    return _open(key, n, body, wrap_aad(space_id, epoch, device_id))


# ---- epoch links: K_{e-1} under K_e, so any holder of the newest key reaches the history -----------------------


def epoch_link(new_key: bytes, prev_key: bytes, space_id: str, epoch: int, nonce: Optional[bytes] = None) -> str:
    n = _nonce(nonce)
    aad = f"mindloom-space-epoch-link-v1|{space_id}|{epoch}".encode()
    return sc.ELINK_PREFIX + sc.b64u(n + _aead(hkdf(new_key, ELINK_INFO), n, prev_key, aad))


def open_epoch_link(link: str, new_key: bytes, space_id: str, epoch: int) -> bytes:
    raw = sc.b64u_decode(link[len(sc.ELINK_PREFIX):])
    aad = f"mindloom-space-epoch-link-v1|{space_id}|{epoch}".encode()
    return _open(hkdf(new_key, ELINK_INFO), raw[:12], raw[12:], aad)


# ---- item data keys, item fields, op fields, blobs -------------------------------------------------------------


def wrap_item_key(space_key: bytes, data_key: bytes, space_id: str, epoch: int, item_id: str,
                  nonce: Optional[bytes] = None) -> str:
    n = _nonce(nonce)
    aad = f"mindloom-space-item-key-v1|{space_id}|{epoch}|{item_id}".encode()
    return sc.IKEY_PREFIX + sc.b64u(n + _aead(hkdf(space_key, IKEY_INFO), n, data_key, aad))


def unwrap_item_key(wrapped: str, space_key: bytes, space_id: str, epoch: int, item_id: str) -> bytes:
    raw = sc.b64u_decode(wrapped[len(sc.IKEY_PREFIX):])
    aad = f"mindloom-space-item-key-v1|{space_id}|{epoch}|{item_id}".encode()
    return _open(hkdf(space_key, IKEY_INFO), raw[:12], raw[12:], aad)


def _json(obj: Any) -> bytes:
    """UTF-8 JSON of obj; bytes pass through as they are (the vectors fix the exact plaintext bytes)."""
    if isinstance(obj, (bytes, bytearray)):
        return bytes(obj)
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def enc_item(data_key: bytes, obj: Any, space_id: str, item_id: str, revision: int,
             nonce: Optional[bytes] = None) -> str:
    """An item's member-visible fields (title, original text with numbers as-is, source, times, names …)."""
    n = _nonce(nonce)
    aad = f"mindloom-space-item-enc-v1|{space_id}|{item_id}|{revision}".encode()
    return sc.ENC_PREFIX + sc.b64u(n + _aead(hkdf(data_key, ITEM_ENC_INFO), n, _json(obj), aad))


def dec_item(enc: str, data_key: bytes, space_id: str, item_id: str, revision: int) -> Any:
    raw = sc.b64u_decode(enc[len(sc.ENC_PREFIX):])
    aad = f"mindloom-space-item-enc-v1|{space_id}|{item_id}|{revision}".encode()
    return json.loads(_open(hkdf(data_key, ITEM_ENC_INFO), raw[:12], raw[12:], aad))


def enc_op(space_key: bytes, obj: Any, space_id: str, op_id: str, nonce: Optional[bytes] = None) -> str:
    """Any other op's content (space name, a member's display name, proposal details, a takedown reason)."""
    n = _nonce(nonce)
    aad = f"mindloom-space-op-enc-v1|{space_id}|{op_id}".encode()
    return sc.ENC_PREFIX + sc.b64u(n + _aead(hkdf(space_key, OP_ENC_INFO), n, _json(obj), aad))


def dec_op(enc: str, space_key: bytes, space_id: str, op_id: str) -> Any:
    raw = sc.b64u_decode(enc[len(sc.ENC_PREFIX):])
    aad = f"mindloom-space-op-enc-v1|{space_id}|{op_id}".encode()
    return json.loads(_open(hkdf(space_key, OP_ENC_INFO), raw[:12], raw[12:], aad))


def seal_blob(data_key: bytes, data: bytes, space_id: str, item_id: str, blob_id: str,
              nonce: Optional[bytes] = None) -> bytes:
    n = _nonce(nonce)
    aad = f"mindloom-space-blob-v1|{space_id}|{item_id}|{blob_id}".encode()
    return sc.BLOB_MAGIC + n + _aead(hkdf(data_key, BLOB_INFO), n, data, aad)


def open_blob(blob: bytes, data_key: bytes, space_id: str, item_id: str, blob_id: str) -> bytes:
    aad = f"mindloom-space-blob-v1|{space_id}|{item_id}|{blob_id}".encode()
    return _open(hkdf(data_key, BLOB_INFO), blob[4:16], blob[16:], aad)


def seal_profile(obj: Any, seal_pub: bytes, space_id: str, request_id: str,
                 eph_priv: Optional[bytes] = None, nonce: Optional[bytes] = None) -> str:
    """A joiner's display name, sealed to the inviting admin's device (its seal key is in the invite code)."""
    eph = X25519PrivateKey.from_private_bytes(eph_priv) if eph_priv else X25519PrivateKey.generate()
    eph_pub = eph.public_key().public_bytes(_RAW, _RAWPUB)
    key = hkdf(eph.exchange(X25519PublicKey.from_public_bytes(seal_pub)), PROFILE_INFO, salt=eph_pub + seal_pub)
    n = _nonce(nonce)
    aad = f"mindloom-space-join-profile-v1|{space_id}|{request_id}".encode()
    return sc.PROFILE_PREFIX + sc.b64u(eph_pub + n + _aead(key, n, _json(obj), aad))


def open_profile(value: str, seal_priv: bytes, space_id: str, request_id: str) -> Any:
    raw = sc.b64u_decode(value[len(sc.PROFILE_PREFIX):])
    eph_pub, n, body = raw[:32], raw[32:44], raw[44:]
    priv = X25519PrivateKey.from_private_bytes(seal_priv)
    my_pub = priv.public_key().public_bytes(_RAW, _RAWPUB)
    key = hkdf(priv.exchange(X25519PublicKey.from_public_bytes(eph_pub)), PROFILE_INFO, salt=eph_pub + my_pub)
    aad = f"mindloom-space-join-profile-v1|{space_id}|{request_id}".encode()
    return json.loads(_open(key, n, body, aad))


# ---- invites: the secret stays between the two Macs -------------------------------------------------------------


def invite_gate(secret: bytes) -> bytes:
    """The token a joiner shows the Spark in place of the invite secret (the Spark keeps only its hash,
    space_crypto.invite_gate_hash, sent as invite.create's secret_hash)."""
    return hashlib.sha256(b"mindloom-space-invite-gate-v1" + bytes(secret)).digest()


def invite_bind_key(secret: bytes) -> bytes:
    return hmac.new(bytes(secret), b"mindloom-space-join-bind-key-v1", hashlib.sha256).digest()


def invite_binding(secret: bytes, request_bytes: bytes) -> str:
    """HMAC-SHA256 of the exact signed join request bytes (space, invite, request and member ids, the device's
    two public keys) under a key derived from the invite secret: only someone holding the invite code can make it,
    and the inviting admin's Mac checks it before approving."""
    return hmac.new(invite_bind_key(secret), b"mindloom-space-join-bind-v2\n" + bytes(request_bytes),
                    hashlib.sha256).hexdigest()


def check_join_request(record: dict, secret: Optional[bytes]) -> Optional[str]:
    """What the inviting admin's Mac checks on a pending join request before 同意 (None = fine): the request is
    signed by the device it names, names this record's member and device, and (when this Mac holds the invite's
    secret) carries the HMAC binding only an invite holder can make. "unverifiable" when the secret is elsewhere
    (another admin sent the invite)."""
    raw = sc.b64u_decode(record.get("request"))
    if raw is None:
        return "malformed"
    try:
        req = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return "malformed"
    dev = record.get("device") or {}
    if req.get("member_id") != record.get("member_id") or req.get("request_id") != record.get("request_id") \
            or not isinstance(req.get("device"), dict) or _norm(req["device"]) != _norm(dev):
        return "mismatch"
    if not sc.verify(sc.b64u_decode(dev.get("sign_pub")) or b"", sc.JOIN_DOMAIN + raw, record.get("sig")):
        return "bad_signature"
    if secret is None:
        return "unverifiable"
    binding = record.get("binding")
    if not isinstance(binding, str) or not hmac.compare_digest(binding, invite_binding(secret, raw)):
        return "bad_binding"
    return None


# ---- the roster: members and devices from the signed log alone -------------------------------------------------


def new_roster() -> dict:
    return {"members": {}, "epoch": 0, "rotation_pending": False, "genesis": False}


def _op_payload(entry: dict) -> Optional[dict]:
    raw = sc.b64u_decode(entry.get("op"))
    if raw is None:
        return None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def roster_device(roster: dict, member_id: Optional[str], device_id: Optional[str]) -> Optional[dict]:
    """The device record a member's op must be signed by, if the log admitted that device and it is active."""
    m = roster["members"].get(member_id or "")
    if m is None or m["status"] != "active":
        return None
    d = m["devices"].get(device_id or "")
    return d if d is not None and d["status"] == "active" else None


def org_roster(org_ops: list[dict], org_id: str) -> dict:
    """The organization's admins and their devices from its signed log alone (GET /v1/orgs/{id} "ops", in seq
    order): org.create (signed by the device it names), then org.admin_add / org.admin_remove signed by an active
    admin's device, and v8 org.device_add (an admin's own further Mac, signed by one of that admin's devices) /
    org.device_remove (any admin retires one device, never the one that signs). Used to accept space.recover (v8 B5)
    and to know where a new key is escrowed."""
    admins: dict[str, dict] = {}
    for entry in org_ops:
        raw = sc.b64u_decode(entry.get("op"))
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, ValueError):
            payload = None
        if not isinstance(payload, dict) or payload.get("org_id") != org_id or payload.get("type") != entry.get("type"):
            continue
        body = payload.get("body") if isinstance(payload.get("body"), dict) else {}
        if payload["type"] == "org.create" and not admins:
            dev = body.get("device") or {}
            key = sc.public_key(dev.get("sign_pub"))
            if key is not None and dev.get("device_id") == payload.get("device_id") and \
                    sc.verify(key, sc.OP_DOMAIN + raw, entry.get("sig")):
                admins[payload["member_id"]] = {"status": "active",
                                                "devices": {dev["device_id"]: {**_pub(dev), "status": "active"}}}
            continue
        signer = admins.get(payload.get("member_id") or "")
        dev = (signer or {}).get("devices", {}).get(payload.get("device_id") or "") if signer else None
        if signer is None or signer["status"] != "active" or dev is None or dev["status"] != "active" or \
                not sc.verify(sc.b64u_decode(dev["sign_pub"]) or b"", sc.OP_DOMAIN + raw, entry.get("sig")):
            continue
        if payload["type"] == "org.admin_add":
            d = body.get("device") or {}
            mid = body.get("member_id")
            if sc.is_uuid(mid) and sc.is_uuid(d.get("device_id")) and sc.public_key(d.get("sign_pub")) and \
                    sc.public_key(d.get("seal_pub")):
                a = admins.setdefault(mid, {"status": "active", "devices": {}})
                a["status"] = "active"
                a["devices"][d["device_id"]] = {**_pub(d), "status": "active"}
        elif payload["type"] == "org.device_add":
            d = body.get("device") or {}
            if sc.is_uuid(d.get("device_id")) and sc.public_key(d.get("sign_pub")) and sc.public_key(d.get("seal_pub")):
                signer["devices"][d["device_id"]] = {**_pub(d), "status": "active"}
        elif payload["type"] == "org.device_remove":
            target = body.get("device_id")
            if target != payload.get("device_id"):
                for a in admins.values():
                    if target in a["devices"]:
                        a["devices"][target]["status"] = "removed"
        elif payload["type"] == "org.admin_remove":
            a = admins.get(body.get("member_id") or "")
            if a is not None:
                a["status"] = "removed"
                for d in a["devices"].values():
                    d["status"] = "removed"
    return {"org_id": org_id, "admins": admins}


def escrow_devices(org: dict) -> list[dict]:
    """Every active device of every active admin of the organization (where an org space's key is escrowed)."""
    return [_pub(d) for a in org["admins"].values() if a["status"] == "active"
            for d in a["devices"].values() if d["status"] == "active"]


def replay(entries: list[dict], space_id: str, roster: Optional[dict] = None,
           org: Optional[dict] = None) -> tuple[dict, list[dict], list[dict]]:
    """Verifies op log entries (GET /v1/spaces/{id}/ops) in order and rebuilds the member and device set from them
    alone: the genesis op's device, then join.approve (which commits to the joiner's member id and both public
    keys), device.add, device.remove, member.remove and member.leave. The Spark's member list
    (GET /v1/spaces/{id}) is never used for keys or devices: a device row someone added to spaces.db is in no
    signed op, so it can neither sign for a member nor receive a rotation's wrap (review finding V7-S1). The epoch
    in use is the newest one a signed rotation made (V7-S10).

    Returns (roster, accepted entries with their decoded payload under "payload", rejected entries)."""
    roster = roster or new_roster()
    accepted: list[dict] = []
    rejected: list[dict] = []
    for entry in entries:
        payload = _op_payload(entry)
        raw = sc.b64u_decode(entry.get("op"))
        if payload is None or raw is None or payload.get("space_id") != space_id or \
                payload.get("type") != entry.get("type"):
            rejected.append(entry)
            continue
        type_ = payload["type"]
        body = payload.get("body") if isinstance(payload.get("body"), dict) else {}
        if entry.get("sig") is None:
            # Only the Spark's own removal record is unsigned, and a member accepts it only when it removes.
            (accepted if type_ == "system.remove" else rejected).append({**entry, "payload": payload})
            continue
        if type_ == "space.create" and not roster["genesis"]:
            dev = body.get("device") or {}
            key = sc.public_key(dev.get("sign_pub"))
            if key is None or dev.get("device_id") != payload.get("device_id") or \
                    not sc.verify(key, sc.OP_DOMAIN + raw, entry.get("sig")):
                rejected.append(entry)
                continue
            roster["genesis"] = True
            roster["epoch"] = 1
            roster["members"][payload["member_id"]] = {
                "status": "active", "devices": {dev["device_id"]: {**_pub(dev), "status": "active"}}}
            accepted.append({**entry, "payload": payload})
            continue
        if type_ == "space.recover":
            # v8 B5: an org admin takes the space over with the escrowed key: signed by an active admin device of
            # the organization as its own signed log admits it (org_roster), naming that device's own keys.
            a = (org or {}).get("admins", {}).get(payload.get("member_id") or "")
            od = a["devices"].get(payload.get("device_id") or "") if a and a["status"] == "active" else None
            named = body.get("device") if isinstance(body.get("device"), dict) else {}
            if od is None or od["status"] != "active" or _norm(named) != _norm(od) or \
                    not sc.verify(sc.b64u_decode(od["sign_pub"]) or b"", sc.OP_DOMAIN + raw, entry.get("sig")):
                rejected.append(entry)
                continue
            m = roster["members"].setdefault(payload["member_id"], {"status": "active", "devices": {}})
            m["status"] = "active"
            m["devices"][od["device_id"]] = {**_pub(od), "status": "active"}
            accepted.append({**entry, "payload": payload})
            continue
        dev = roster_device(roster, payload.get("member_id"), payload.get("device_id"))
        if dev is None or not sc.verify(sc.b64u_decode(dev["sign_pub"]) or b"", sc.OP_DOMAIN + raw, entry.get("sig")):
            rejected.append(entry)
            continue
        if entry.get("enc") is not None and payload.get("enc_sha256") != sc.detached_hash(entry["enc"]):
            rejected.append(entry)
            continue
        _apply_roster(roster, payload, body)
        accepted.append({**entry, "payload": payload})
    return roster, accepted, rejected


def _pub(dev: dict) -> dict:
    return {"device_id": dev.get("device_id"), "sign_pub": dev.get("sign_pub"), "seal_pub": dev.get("seal_pub")}


def _norm(dev: dict) -> tuple:
    """A device record compared by its id and the bytes of its two keys (base64url padding does not matter)."""
    return (dev.get("device_id"), sc.public_key(dev.get("sign_pub")), sc.public_key(dev.get("seal_pub")))


def _apply_roster(roster: dict, payload: dict, body: dict) -> None:
    type_ = payload["type"]
    members = roster["members"]
    if type_ == "join.approve":
        dev, member_id = body.get("device"), body.get("member_id")
        # An approval that does not name the joiner's keys admits nobody on this Mac.
        if isinstance(dev, dict) and sc.is_uuid(member_id) and sc.public_key(dev.get("sign_pub")) and \
                sc.public_key(dev.get("seal_pub")) and sc.is_uuid(dev.get("device_id")):
            m = members.setdefault(member_id, {"status": "active", "devices": {}})
            if m["status"] == "removed":
                return
            m["status"] = "active"
            m["devices"][dev["device_id"]] = {**_pub(dev), "status": "active"}
    elif type_ == "device.add":
        dev = body.get("device")
        m = members.get(payload["member_id"])
        if isinstance(dev, dict) and m is not None and sc.public_key(dev.get("sign_pub")) and \
                sc.public_key(dev.get("seal_pub")) and sc.is_uuid(dev.get("device_id")):
            m["devices"][dev["device_id"]] = {**_pub(dev), "status": "active"}
    elif type_ == "device.remove":
        for m in members.values():
            if body.get("device_id") in m["devices"]:
                m["devices"][body["device_id"]]["status"] = "removed"
        _rotated(roster, body)
    elif type_ == "member.remove":
        m = members.get(body.get("member_id") or "")
        if m is not None:
            m["status"] = "removed"
            for d in m["devices"].values():
                d["status"] = "removed"
        _rotated(roster, body)
    elif type_ == "member.leave":
        m = members.get(payload["member_id"])
        if m is not None:
            m["status"] = "left"
            for d in m["devices"].values():
                d["status"] = "left"
        roster["rotation_pending"] = True
    elif type_ == "epoch.rotate":
        _rotated(roster, body)


def _rotated(roster: dict, body: dict) -> None:
    if isinstance(body.get("epoch"), int) and body["epoch"] > roster["epoch"]:
        roster["epoch"] = body["epoch"]
        roster["rotation_pending"] = False


def active_devices(roster: dict, exclude_member: Optional[str] = None) -> list[dict]:
    """Every active device of every active member, as the signed log admitted them (rotation wraps go here)."""
    out = []
    for member_id, m in roster["members"].items():
        if m["status"] != "active" or member_id == exclude_member:
            continue
        out += [_pub(d) for d in m["devices"].values() if d["status"] == "active"]
    return out


# ---- a device: signing ops, joins and requests --------------------------------------------------------------


def new_id() -> str:
    return str(uuid.uuid4())


@dataclass
class Device:
    """One member device (a Mac): its id and its two key pairs."""

    device_id: str = field(default_factory=new_id)
    sign_priv: bytes = field(default_factory=lambda: os.urandom(32))
    seal_priv: bytes = field(default_factory=lambda: os.urandom(32))

    @property
    def sign_pub(self) -> bytes:
        return Ed25519PrivateKey.from_private_bytes(self.sign_priv).public_key().public_bytes(_RAW, _RAWPUB)

    @property
    def seal_pub(self) -> bytes:
        return X25519PrivateKey.from_private_bytes(self.seal_priv).public_key().public_bytes(_RAW, _RAWPUB)

    def public(self) -> dict:
        return {"device_id": self.device_id, "sign_pub": sc.b64u(self.sign_pub), "seal_pub": sc.b64u(self.seal_pub)}

    def sign(self, message: bytes) -> str:
        return sc.b64u(Ed25519PrivateKey.from_private_bytes(self.sign_priv).sign(message))

    def op(self, space_id: str, member_id: str, type_: str, body: dict, *, epoch: Optional[int] = None,
           enc: Optional[str] = None, wrapped_dk: Optional[str] = None, op_id: Optional[str] = None,
           created_at: Optional[str] = None) -> dict:
        """A signed op on the wire: {"op": b64u(JSON), "sig", and the detached fields}. The JSON commits to each
        detached field by its SHA-256, so the Spark can purge them (crypto-shredding) without breaking the
        signature."""
        payload: dict[str, Any] = {"v": 1, "space_id": space_id, "op_id": op_id or new_id(), "type": type_,
                                   "member_id": member_id, "device_id": self.device_id,
                                   "created_at": created_at or time.strftime("%Y-%m-%dT%H:%M:%S+00:00",
                                                                             time.gmtime()),
                                   "body": body}
        if epoch is not None:
            payload["epoch"] = epoch
        detached = {}
        if enc is not None:
            payload["enc_sha256"] = sc.detached_hash(enc)
            detached["enc"] = enc
        if wrapped_dk is not None:
            payload["wrapped_dk_sha256"] = sc.detached_hash(wrapped_dk)
            detached["wrapped_dk"] = wrapped_dk
        raw = _json(payload)
        return {"op": sc.b64u(raw), "sig": self.sign(sc.OP_DOMAIN + raw), **detached}

    def org_op(self, org_id: str, member_id: str, type_: str, body: dict, *, enc: Optional[str] = None,
               op_id: Optional[str] = None) -> dict:
        """An organization op: the same envelope with "org_id" in place of "space_id"."""
        payload: dict[str, Any] = {"v": 1, "org_id": org_id, "op_id": op_id or new_id(), "type": type_,
                                   "member_id": member_id, "device_id": self.device_id,
                                   "created_at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
                                   "body": body}
        detached = {}
        if enc is not None:
            payload["enc_sha256"] = sc.detached_hash(enc)
            detached["enc"] = enc
        raw = _json(payload)
        return {"op": sc.b64u(raw), "sig": self.sign(sc.OP_DOMAIN + raw), **detached}

    def join(self, space_id: str, invite_id: str, secret: bytes, member_id: str, *,
             request_id: Optional[str] = None, profile: Optional[str] = None) -> dict:
        """A join request. The invite's secret never leaves this Mac: beside the signed request go the gate token
        (the Spark checks it against the invite's stored hash and uses the invite up) and an HMAC of the exact
        request bytes under a key only invite holders can derive, which the inviting admin's Mac checks before it
        approves (so the Spark cannot bind a device of its own to the invite)."""
        request_id = request_id or new_id()
        payload = {"v": 1, "space_id": space_id, "invite_id": invite_id, "request_id": request_id,
                   "member_id": member_id, "device": self.public(),
                   "created_at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())}
        raw = _json(payload)
        out = {"request": sc.b64u(raw), "sig": self.sign(sc.JOIN_DOMAIN + raw),
               "invite_gate": sc.b64u(invite_gate(secret)), "invite_binding": invite_binding(secret, raw)}
        if profile is not None:
            out["profile"] = profile
        return out

    def request_headers(self, method: str, target: str, body: bytes = b"", *, date: Optional[int] = None,
                        nonce: Optional[str] = None) -> dict:
        date_s = str(int(date if date is not None else time.time()))
        nonce = nonce or secrets.token_urlsafe(18)
        sig = self.sign(sc.request_message(method, target, date_s, nonce, body))
        return {"X-Mindloom-Device": self.device_id, "X-Mindloom-Date": date_s, "X-Mindloom-Nonce": nonce,
                "X-Mindloom-Signature": sig}


def backup_key(space_key: bytes, backup_id: str) -> bytes:
    """v8 B4: the key an admin's Mac lends the Spark for one encrypted backup of a space (organizer/backup.py), and
    derives again to restore it: HKDF-SHA256(ikm = the backup's epoch key, salt = the backup id's 16 bytes,
    info = "mindloom-space-backup-v1")."""
    return hkdf(space_key, b"mindloom-space-backup-v1", salt=uuid.UUID(backup_id).bytes)


# ---- v8 contract C: audio parts, snapshots, the share outbox --------------------------------------------------

AUDIO_TOLERANCE_MS = 2000


def audio_part_ok(duration_ms: int, segment: dict, tolerance_ms: int = AUDIO_TOLERANCE_MS) -> bool:
    """What a member Mac checks after it opened an audio part, before it plays it (the Spark cannot look inside):
    the sound is as long as the part the signed op declares (within a tolerance), and that part is a part of the
    recording (at most 4/5 of it), at most 15 minutes. Anything else is not played and is reported to the space's
    maintainers."""
    try:
        length = int(segment["end_ms"]) - int(segment["start_ms"])
        whole = int(segment["recording_ms"])
    except (KeyError, TypeError, ValueError):
        return False
    # a part, never (nearly) the whole recording: at most 4/5 of it (review finding V8R-15)
    return 0 < length <= 15 * 60 * 1000 and length * 5 <= whole * 4 and abs(int(duration_ms) - length) <= tolerance_ms


def snapshot_body(item_id: str, revision: int, *, matter_id: Optional[str] = None, pack_id: Optional[str] = None,
                  as_of: Optional[str] = None, cites: Optional[list[str]] = None,
                  share_key: Optional[str] = None) -> dict:
    """The plain body of a snapshot share (item.share, kind "snapshot"; v8 C2): ids only. `cites`: the items of the
    space the summary quotes or draws on; when one of them is withdrawn or removed, the Spark removes the snapshot
    too. The frozen text itself goes in enc, under the snapshot's own data key, like any item."""
    snap: dict = {}
    if matter_id is not None:
        snap["matter_id"] = matter_id
    if pack_id is not None:
        snap["pack_id"] = pack_id
    if as_of is not None:
        snap["as_of"] = as_of
    if cites:
        snap["cites"] = sorted({c.lower() for c in cites})
    body = {"item_id": item_id, "revision": revision, "kind": "snapshot", "blobs": [], "snapshot": snap}
    if share_key is not None:
        body["share_key"] = share_key
    return body


def outbox_action(result: dict) -> str:
    """What a Mac's share outbox does with one op result (v8 C3): "done" (accepted now or before: drop the entry),
    "remake" (sync the space keys, make a new op for the same entry with the same share_key), "later" (send the
    very same op again later), "drop" (refused for good: drop the entry and tell the user)."""
    if result.get("ok"):
        return "done"
    return {"remake": "remake", "later": "later"}.get(result.get("retry") or "never", "drop")


def wraps_for(space_key: bytes, devices: list[dict], space_id: str, epoch: int) -> list[dict]:
    """Wrap a space key to each public device record ({"device_id","seal_pub"} as the Spark lists them)."""
    return [{"device_id": d["device_id"], "epoch": epoch,
             "wrap": wrap_space_key(space_key, sc.b64u_decode(d["seal_pub"]), space_id, epoch, d["device_id"])}
            for d in devices]
