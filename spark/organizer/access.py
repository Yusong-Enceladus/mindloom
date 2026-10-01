"""Per-member access to this Spark (v8 contract B1; docs/INFRA.md).

Teammates no longer use the Spark owner's SSH account the way the owner does. Each member's Mac has its own SSH
key, installed in the owner's authorized_keys with a forced command to the gate (organizer/gate.py), and its own
access credential; the owner's link token is never given to anyone.

  * An **access ticket** lets one new Mac in once. The inviting admin's Mac makes an ephemeral ed25519 key pair and
    a 32-byte secret, registers the public key and SHA-256("mindloom-access-ticket-v1\\n" ‖ secret) here
    (POST /v1/access/tickets) and puts the private key and the secret into the invite (QR / code) next to the space
    invite. The ticket's line runs only `zhiji-inbox enroll <ticket id>`; it expires within 7 days and is removed
    then. Kinds: "member" (a new person; created by the owner, an org admin or a space admin) and "device" (a
    member's second Mac; created by that member's existing Mac, bound to its member id).
  * **Enrollment** (the invitee's Mac, through the ticket's key): it sends its own new SSH public key, its member id
    and device keys, signed by the device's Ed25519 key, plus the ticket secret. The ticket's line is replaced in
    place by the member line (forced command `zhiji-inbox bridge <access id>`), and the Mac receives its access
    credential once: "mlacc1.<access id>.<base64url 32 bytes>". Only its SHA-256 is kept here.
  * **Every member request** comes through the bridge, which adds a gate stamp (an HMAC under <data>/gate_key, a
    file only the Spark owner's account can read): the organizer accepts a member credential only together with the
    stamp of the same access id, so a credential is useless without that member's SSH key, and the key is useless
    without the credential. Member requests reach only member routes (spaces, organizations, access, infra health)
    and space routes still check the signed membership; a space request must be signed by the device this access
    was enrolled with.
  * **Unpairing** (revoke) removes the member's line; authorized_keys is then byte-identical to before the invite
    (organizer/access_keys.py). The credential's hash is deleted at once, so even a bridge session still open is
    refused from its next request.

<data>/access.db is plain SQLite (it must work while the owner's store is locked): ids, public keys, hashes,
times and states. No names, no content. The audit table records who did what to which id.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

from . import access_keys as ak
from . import db
from . import space_crypto as sc
from .auth import ensure_link_token
from .phone_keys import Refused, default_gate_path, fingerprint, parse_pubkey

TICKET_DOMAIN = b"mindloom-access-ticket-v1\n"
ENROLL_DOMAIN = b"mindloom-access-enroll-v1\n"
GATE_DOMAIN = "mindloom-gate-v1"
CREDENTIAL_PREFIX = "mlacc1."
TICKET_MAX_S = 7 * 86400
TICKET_MAX_FAILURES = 10
MAX_OPEN_TICKETS = 20            # per creator
MAX_DEVICES_PER_MEMBER = 4
LAST_SEEN_EVERY_S = 60.0
ENROLL_MAX_BYTES = 64 * 1024
_CRED = re.compile(r"mlacc1\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})\Z")
_STAMP = re.compile(r"(member|enroll):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([0-9a-f]{64})\Z")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tickets(ticket_id TEXT PRIMARY KEY, kind TEXT NOT NULL, member_id TEXT,
  secret_hash TEXT NOT NULL, key_b64 TEXT NOT NULL, created_by TEXT NOT NULL, created_ts REAL NOT NULL,
  expires_ts REAL NOT NULL, status TEXT NOT NULL, used_by TEXT, eof_fix TEXT, failures INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS access(access_id TEXT PRIMARY KEY, member_id TEXT NOT NULL, device_id TEXT NOT NULL,
  sign_pub TEXT NOT NULL, seal_pub TEXT NOT NULL, key_b64 TEXT NOT NULL, credential_hash TEXT, status TEXT NOT NULL,
  created_ts REAL NOT NULL, ended_ts REAL, last_seen_ts REAL, ticket_id TEXT, invited_by TEXT, eof_fix TEXT);
CREATE INDEX IF NOT EXISTS access_member ON access(member_id);
CREATE INDEX IF NOT EXISTS access_device ON access(device_id);
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT,
  action TEXT NOT NULL, target TEXT NOT NULL);
"""


class AccessError(Exception):
    """A refused access request: HTTP status, a short code, an optional detail (never a secret or content)."""

    def __init__(self, status: int, code: str, detail: str = "", **extra: Any):
        super().__init__(code)
        self.status = status
        self.code = code
        self.detail = detail
        self.extra = extra

    def body(self) -> dict:
        out = {"error": self.code}
        if self.detail:
            out["detail"] = self.detail
        out.update(self.extra)
        return out


def iso(ts: Optional[float]) -> Optional[str]:
    return None if ts is None else datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds")


def _parse_ts(value: object) -> Optional[float]:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt.timestamp() if dt.tzinfo is not None else None


def ticket_hash(secret: bytes) -> str:
    return hashlib.sha256(TICKET_DOMAIN + secret).hexdigest()


def credential_hash(secret: str) -> str:
    return hashlib.sha256(("mindloom-access-credential-v1\n" + secret).encode("ascii")).hexdigest()


def gate_stamp(gate_key: str, kind: str, ident: str) -> str:
    mac = hmac.new(bytes.fromhex(gate_key), f"{GATE_DOMAIN}|{kind}|{ident}".encode("ascii"), hashlib.sha256)
    return f"{kind}:{ident}:{mac.hexdigest()}"


def read_gate_key(data_dir: Path) -> str:
    """The gate's HMAC key (64 hex, 0600, created on first use; the same file for the organizer and the gate)."""
    return ensure_link_token(Path(data_dir) / "gate_key")


def enroll_request(device, ticket_id: str, secret: bytes, ssh_key: str, member_id: str,
                   created_at: Optional[str] = None) -> dict:
    """What an invitee's Mac sends on the ticket key's stdin (reference for the Swift side; tests use it).
    `device` is anything with .public() and .sign(bytes) (organizer/space_member.Device)."""
    payload = {"v": 1, "ticket_id": ticket_id, "secret": sc.b64u(secret), "ssh_key": ssh_key,
               "member_id": member_id, "device": device.public(),
               "created_at": created_at or datetime.now(timezone.utc).isoformat(timespec="seconds")}
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return {"request": sc.b64u(raw), "sig": device.sign(ENROLL_DOMAIN + raw)}


class Access:
    def __init__(self, data_dir: str | Path, *, authorized_keys: Optional[Path] = None,
                 gate_path: Optional[str] = None, now: Callable[[], float] = time.time):
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.path = self.data_dir / "access.db"
        self.authorized_keys = Path(authorized_keys) if authorized_keys else None
        self._gate_path = gate_path
        self.now = now
        self._lock = threading.RLock()
        self.conn = db.connect(self.path, None, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = db.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA secure_delete=ON")
        self.conn.executescript(SCHEMA)
        os.chmod(self.path, 0o600)
        self.gate_key = read_gate_key(self.data_dir)
        self._seen: dict[str, float] = {}

    # ---- db helpers --------------------------------------------------------------------------------

    def one(self, sql: str, args: tuple | list = ()) -> Optional[dict]:
        with self._lock:
            row = self.conn.execute(sql, args).fetchone()
        return dict(row) if row else None

    def all(self, sql: str, args: tuple | list = ()) -> list[dict]:
        with self._lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def x(self, sql: str, args: tuple | list = ()) -> None:
        with self._lock:
            self.conn.execute(sql, args)

    def close(self) -> None:
        with self._lock:
            self.conn.close()

    @property
    def gate_path(self) -> str:
        return self._gate_path or default_gate_path()

    def _eof_fixes(self) -> set[str]:
        """Every final newline an add ever had to put after foreign content (see access_keys.remove)."""
        return {r["f"] for r in self.all("SELECT eof_fix AS f FROM tickets WHERE eof_fix IS NOT NULL UNION"
                                         " SELECT eof_fix AS f FROM access WHERE eof_fix IS NOT NULL")}

    def audit(self, action: str, target: dict, actor: Optional[str]) -> None:
        self.x("INSERT INTO audit(at, actor, action, target) VALUES (?,?,?,?)",
               (iso(self.now()), actor, action, json.dumps(target, ensure_ascii=False, sort_keys=True)))

    def stamp(self, kind: str, ident: str) -> str:
        return gate_stamp(self.gate_key, kind, ident)

    def check_stamp(self, value: Optional[str], kind: str) -> Optional[str]:
        """The id in a gate stamp of this kind, if the stamp is genuine (made with this Spark's gate key)."""
        m = _STAMP.match(value or "")
        if m is None or m.group(1) != kind:
            return None
        want = self.stamp(kind, m.group(2))
        return m.group(2) if hmac.compare_digest(want, value) else None

    # ---- tickets -----------------------------------------------------------------------------------

    def create_ticket(self, body: object, *, created_by: str, member_id: Optional[str] = None,
                      allow_member: bool = True) -> dict:
        """POST /v1/access/tickets. created_by is "owner" or the creator's access id; member_id binds a "device"
        ticket to the creator's member (a second Mac)."""
        if not isinstance(body, dict):
            raise AccessError(400, "bad_request", "the ticket is an object")
        ticket_id = body.get("ticket_id")
        if not sc.is_uuid(ticket_id):
            raise AccessError(422, "bad_field", "ticket_id is a lowercase UUID")
        kind = body.get("kind", "member")
        if kind not in ("member", "device"):
            raise AccessError(422, "bad_field", "kind is member or device")
        if kind == "member" and not allow_member:
            raise AccessError(403, "forbidden", "only the owner, org admins and space admins invite new members")
        if kind == "device" and member_id is None:
            raise AccessError(422, "bad_field", "a device ticket is made by the member's own Mac")
        secret_hash = body.get("secret_hash")
        if not isinstance(secret_hash, str) or sc.HEX64_RE.match(secret_hash) is None:
            raise AccessError(422, "bad_field", "secret_hash is 64 lowercase hex")
        expires = _parse_ts(body.get("expires_at"))
        now = self.now()
        if expires is None or not now < expires <= now + TICKET_MAX_S + 60:
            raise AccessError(422, "bad_field", "expires_at is an ISO time with an offset, within 7 days")
        try:
            _, b64 = parse_pubkey(body.get("ssh_key"))
        except Refused as exc:
            raise AccessError(422, exc.code, str(exc)) from None
        self.sweep()
        with self._lock:
            if self.one("SELECT 1 FROM tickets WHERE ticket_id=?", (ticket_id,)):
                raise AccessError(409, "ticket_exists")
            n = self.one("SELECT COUNT(*) AS n FROM tickets WHERE created_by=? AND status='open'", (created_by,))["n"]
            if n >= MAX_OPEN_TICKETS:
                raise AccessError(409, "too_many_tickets", f"at most {MAX_OPEN_TICKETS} open tickets")
            if kind == "device":
                active = self.one("SELECT COUNT(*) AS n FROM access WHERE member_id=? AND status='active'",
                                  (member_id,))["n"]
                if active >= MAX_DEVICES_PER_MEMBER:
                    raise AccessError(409, "too_many_devices", f"at most {MAX_DEVICES_PER_MEMBER} Macs per member")
            try:
                res = ak.add(ak.ENROLL, ticket_id, f"ssh-ed25519 {b64}", self.gate_path, path=self.authorized_keys)
            except Refused as exc:
                raise AccessError(409 if exc.code == "key_in_use" else 422, exc.code, str(exc)) from None
            self.x("INSERT INTO tickets(ticket_id, kind, member_id, secret_hash, key_b64, created_by, created_ts,"
                   " expires_ts, status, eof_fix) VALUES (?,?,?,?,?,?,?,?,'open',?)",
                   (ticket_id, kind, member_id if kind == "device" else None, secret_hash, b64, created_by, now,
                    expires, res["eof_fix"]))
            self.audit("access.ticket", {"ticket_id": ticket_id, "kind": kind}, created_by)
        return {"ok": True, "ticket_id": ticket_id, "kind": kind, "expires_at": iso(expires),
                "fingerprint": res["fingerprint"], "command": "enroll"}

    def revoke_ticket(self, ticket_id: str, *, by: str, owner: bool = False) -> dict:
        with self._lock:
            t = self.one("SELECT * FROM tickets WHERE ticket_id=?", (ticket_id,)) if sc.is_uuid(ticket_id) else None
            if t is None:
                raise AccessError(404, "unknown_ticket")
            if not owner and t["created_by"] != by:
                raise AccessError(403, "forbidden", "the ticket's creator or the owner revokes it")
            removed = 0
            if t["status"] == "open":
                removed = ak.remove(ak.ENROLL, ticket_id, eof_fix=self._eof_fixes(), path=self.authorized_keys)["removed"]
                self.x("UPDATE tickets SET status='revoked' WHERE ticket_id=?", (ticket_id,))
                self.audit("access.ticket_revoke", {"ticket_id": ticket_id}, by)
        return {"ok": True, "ticket_id": ticket_id, "removed": removed}

    def sweep(self) -> int:
        """Expired open tickets: their lines go (byte-exact) and they are marked expired."""
        now = self.now()
        n = 0
        with self._lock:
            for t in self.all("SELECT * FROM tickets WHERE status='open' AND expires_ts <= ?", (now,)):
                try:
                    ak.remove(ak.ENROLL, t["ticket_id"], eof_fix=self._eof_fixes(), path=self.authorized_keys)
                except (OSError, Refused):
                    continue
                self.x("UPDATE tickets SET status='expired' WHERE ticket_id=?", (t["ticket_id"],))
                self.audit("access.ticket_expired", {"ticket_id": t["ticket_id"]}, None)
                n += 1
        return n

    # ---- enrollment (the gate's `enroll`, relayed with its stamp) ------------------------------------

    def enroll(self, ticket_id: str, wire: object, *,
               known_sign_pub: Callable[[str], Optional[str]] = lambda device_id: None,
               known_member: Callable[[str], Optional[str]] = lambda device_id: None,
               member_id_keys: Callable[[str], Optional[set]] = lambda member_id: None) -> dict:
        """`member_id_keys(member_id)`: None when this Spark does not know the member id yet, else the signing keys it
        is bound to here (its devices in spaces and organizations, its paired Macs)."""
        if not isinstance(wire, dict) or not isinstance(wire.get("request"), str) or not isinstance(wire.get("sig"), str):
            raise AccessError(400, "bad_request", "enroll takes {request, sig}")
        raw = sc.b64u_decode(wire["request"])
        if raw is None or len(raw) > ENROLL_MAX_BYTES:
            raise AccessError(400, "bad_request", "request is base64url JSON")
        try:
            req = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise AccessError(400, "bad_request", "request is base64url JSON") from None
        if not isinstance(req, dict) or req.get("v") != 1 or req.get("ticket_id") != ticket_id:
            raise AccessError(400, "bad_request", "the request names another ticket")
        self.sweep()
        with self._lock:
            t = self.one("SELECT * FROM tickets WHERE ticket_id=?", (ticket_id,))
            if t is None:
                raise AccessError(404, "unknown_ticket")
            if t["status"] != "open":
                raise AccessError(410, "ticket_used" if t["status"] == "used" else "ticket_closed",
                                  ticket_status=t["status"])
            if t["failures"] >= TICKET_MAX_FAILURES:
                raise AccessError(429, "ticket_locked")
            secret = sc.b64u_decode(req.get("secret"))
            if secret is None or not hmac.compare_digest(ticket_hash(secret), t["secret_hash"]):
                self.x("UPDATE tickets SET failures=failures+1 WHERE ticket_id=?", (ticket_id,))
                raise AccessError(403, "bad_secret")
            device = req.get("device")
            if not isinstance(device, dict) or not sc.is_uuid(device.get("device_id")) or \
                    sc.public_key(device.get("sign_pub")) is None or sc.public_key(device.get("seal_pub")) is None:
                raise AccessError(422, "bad_field", "device is {device_id, sign_pub, seal_pub}")
            sign_pub = sc.b64u(sc.public_key(device["sign_pub"]))
            seal_pub = sc.b64u(sc.public_key(device["seal_pub"]))
            if not sc.verify(sc.public_key(sign_pub), ENROLL_DOMAIN + raw, wire["sig"]):
                raise AccessError(401, "bad_signature")
            member_id = req.get("member_id")
            if not sc.is_uuid(member_id):
                raise AccessError(422, "bad_field", "member_id is a lowercase UUID")
            if t["kind"] == "device" and member_id != t["member_id"]:
                raise AccessError(403, "wrong_member", "a device ticket adds a Mac of the member who made it")
            if t["kind"] == "member" and self.one("SELECT 1 FROM access WHERE member_id=? AND status='active'",
                                                  (member_id,)):
                raise AccessError(409, "member_exists", "add a second Mac from your first one (a device ticket)")
            if t["kind"] == "member":
                # V8R-08: a member ticket brings a new person; a member id this Spark already knows (in a roster, an
                # organization, the access records) is taken only by a Mac whose key it is bound to here.
                keys = member_id_keys(member_id)
                if self.one("SELECT 1 FROM access WHERE member_id=? LIMIT 1", (member_id,)) is not None:
                    keys = keys if keys is not None else set()
                if keys is not None and sign_pub not in keys:
                    raise AccessError(409, "member_id_taken",
                                      "this member id is someone's here; a Mac of theirs adds another (a device ticket)")
            if self.one("SELECT 1 FROM access WHERE device_id=? AND status='active'", (device["device_id"],)):
                raise AccessError(409, "device_exists")
            if self.one("SELECT 1 FROM access WHERE device_id=? AND status!='active'", (device["device_id"],)):
                # V8R-07: an unpaired Mac does not come back under its old device keys (it is still in its spaces'
                # rosters until someone retires it there); it pairs again with new device keys and is let into
                # each space again by that space.
                raise AccessError(409, "device_revoked", "this Mac was unpaired here; it pairs again with new device keys")
            known = known_sign_pub(device["device_id"])
            if known is not None and known != sign_pub:
                raise AccessError(409, "device_key_conflict", "this device id is registered with another key")
            # v8: a device id belongs to one member on this Spark (its spaces, organizations and earlier access)
            prior = self.one("SELECT member_id FROM access WHERE device_id=? LIMIT 1", (device["device_id"],))
            owner = known_member(device["device_id"]) or (prior["member_id"] if prior else None)
            if owner is not None and owner != member_id:
                raise AccessError(409, "device_member_conflict", "this device belongs to another member here")
            try:
                _, b64 = parse_pubkey(req.get("ssh_key"))
            except Refused as exc:
                raise AccessError(422, exc.code, str(exc)) from None
            if b64 == t["key_b64"]:
                raise AccessError(422, "bad_pubkey", "the member key must be the Mac's own key, not the ticket's")
            access_id = str(uuid.uuid4())
            try:
                res = ak.swap((ak.ENROLL, ticket_id), ak.MEMBER, access_id, f"ssh-ed25519 {b64}", self.gate_path,
                              path=self.authorized_keys)
            except Refused as exc:
                raise AccessError(409, exc.code, str(exc)) from None
            secret_c = sc.b64u(secrets.token_bytes(32))
            now = self.now()
            self.x("INSERT INTO access(access_id, member_id, device_id, sign_pub, seal_pub, key_b64, credential_hash,"
                   " status, created_ts, ticket_id, invited_by, eof_fix) VALUES (?,?,?,?,?,?,?,'active',?,?,?,?)",
                   (access_id, member_id, device["device_id"], sign_pub, seal_pub, b64, credential_hash(secret_c), now,
                    ticket_id, t["created_by"], t["eof_fix"]))
            self.x("UPDATE tickets SET status='used', used_by=? WHERE ticket_id=?", (access_id, ticket_id))
            self.audit("access.enroll", {"access_id": access_id, "member_id": member_id, "ticket_id": ticket_id,
                                         "kind": t["kind"]}, t["created_by"])
        return {"ok": True, "access_id": access_id, "member_id": member_id, "device_id": device["device_id"],
                "credential": f"{CREDENTIAL_PREFIX}{access_id}.{secret_c}", "fingerprint": res["fingerprint"],
                "command": "bridge"}

    # ---- members -----------------------------------------------------------------------------------

    def authenticate(self, authorization: Optional[str], stamp: Optional[str]) -> Optional[dict]:
        """None when the header is not a member credential at all; the active access record when the credential
        and the gate stamp of the same access id are both right; AccessError(401) otherwise."""
        scheme, _, value = (authorization or "").strip().partition(" ")
        value = value.strip()
        if scheme.lower() != "bearer" or not value.startswith(CREDENTIAL_PREFIX):
            return None
        m = _CRED.match(value)
        if m is None:
            raise AccessError(401, "bad_credential")
        access_id = m.group(1)
        if self.check_stamp(stamp, "member") != access_id:
            # A credential without its own key's gate stamp: not through that member's SSH key.
            raise AccessError(401, "not_through_gate")
        rec = self.one("SELECT * FROM access WHERE access_id=?", (access_id,))
        if rec is None or rec["status"] != "active" or not rec["credential_hash"] or \
                not hmac.compare_digest(credential_hash(m.group(2)), rec["credential_hash"]):
            raise AccessError(401, "bad_credential")
        now = self.now()
        if now - self._seen.get(access_id, 0.0) >= LAST_SEEN_EVERY_S:
            self._seen[access_id] = now
            self.x("UPDATE access SET last_seen_ts=? WHERE access_id=?", (now, access_id))
        return rec

    # ---- the spaces' view of the access records (v8: one device id, one member, one key; organizer/spaces.py) ----

    def device_record(self, device_id: str) -> Optional[dict]:
        """The newest access record of a device id (any state)."""
        return self.one("SELECT * FROM access WHERE device_id=? ORDER BY created_ts DESC, access_id LIMIT 1",
                        (device_id,)) if sc.is_uuid(device_id) else None

    def member_keys(self, member_id: str) -> set[str]:
        """The device signing keys of a member's Macs that are paired with this Spark now."""
        return {r["sign_pub"] for r in self.all("SELECT sign_pub FROM access WHERE member_id=? AND status='active'",
                                                (member_id,))}

    def member_known(self, member_id: str) -> bool:
        return self.one("SELECT 1 FROM access WHERE member_id=? LIMIT 1", (member_id,)) is not None

    def records_of(self, member_id: str) -> list[dict]:
        return self.all("SELECT * FROM access WHERE member_id=? ORDER BY created_ts, access_id", (member_id,))

    def record(self, access_id: str) -> Optional[dict]:
        return self.one("SELECT * FROM access WHERE access_id=?", (access_id,)) if sc.is_uuid(access_id) else None

    @staticmethod
    def public(rec: dict, with_key: bool = False) -> dict:
        """An access record as the admin console shows it: ids, key fingerprint, times, state. No secrets.
        `with_key` (the Spark owner's view): the Mac's SSH public key too, for its relay line (review V8R-12)."""
        out = {"access_id": rec["access_id"], "member_id": rec["member_id"], "device_id": rec["device_id"],
               "sign_pub": rec["sign_pub"], "fingerprint": fingerprint(rec["key_b64"]), "status": rec["status"],
               "created_at": iso(rec["created_ts"]), "ended_at": iso(rec["ended_ts"]),
               "last_seen_at": iso(rec["last_seen_ts"]), "invited_by": rec["invited_by"]}
        if with_key:
            out["ssh_key"] = f"ssh-ed25519 {rec['key_b64']}"
        return out

    def members(self, member_ids: Optional[set[str]] = None, invited_by: Optional[str] = None,
                with_keys: bool = False) -> list[dict]:
        rows = self.all("SELECT * FROM access ORDER BY created_ts, access_id")
        if member_ids is not None:
            rows = [r for r in rows if r["member_id"] in member_ids or (invited_by and r["invited_by"] == invited_by)]
        return [self.public(r, with_keys) for r in rows]

    def tickets(self, created_by: Optional[str] = None, with_keys: bool = False) -> list[dict]:
        self.sweep()
        rows = self.all("SELECT * FROM tickets ORDER BY created_ts, ticket_id") if created_by is None else \
            self.all("SELECT * FROM tickets WHERE created_by=? ORDER BY created_ts, ticket_id", (created_by,))
        return [{"ticket_id": t["ticket_id"], "kind": t["kind"], "member_id": t["member_id"], "status": t["status"],
                 "created_by": t["created_by"], "created_at": iso(t["created_ts"]), "expires_at": iso(t["expires_ts"]),
                 "used_by": t["used_by"], "fingerprint": fingerprint(t["key_b64"]),
                 **({"ssh_key": f"ssh-ed25519 {t['key_b64']}"} if with_keys else {})} for t in rows]

    def revoke(self, access_id: str, *, by: str) -> dict:
        """Unpair one Mac: its line goes (authorized_keys byte-identical to before its invite when nothing else
        changed), its credential hash is deleted."""
        with self._lock:
            rec = self.record(access_id)
            if rec is None:
                raise AccessError(404, "unknown_access")
            removed = ak.remove(ak.MEMBER, access_id, eof_fix=self._eof_fixes(), path=self.authorized_keys)["removed"]
            if rec["status"] == "active":
                self.x("UPDATE access SET status='revoked', credential_hash=NULL, ended_ts=? WHERE access_id=?",
                       (self.now(), access_id))
                self.audit("access.revoke", {"access_id": access_id, "member_id": rec["member_id"]}, by)
        return {"ok": True, "access_id": access_id, "removed": removed}

    def audit_log(self, since: int = 0, limit: int = 200, member_ids: Optional[set[str]] = None) -> dict:
        rows = self.all("SELECT * FROM audit WHERE id > ? ORDER BY id LIMIT ?", (since, limit))
        out = []
        for r in rows:
            target = json.loads(r["target"])
            if member_ids is not None:
                mid = target.get("member_id")
                if mid is None and target.get("access_id"):
                    rec = self.record(target["access_id"])
                    mid = rec["member_id"] if rec else None
                if mid not in member_ids:
                    continue
            out.append({"id": r["id"], "at": r["at"], "actor": r["actor"], "action": r["action"], "target": target})
        return {"entries": out, "cursor": rows[-1]["id"] if rows else since}

    def stats(self) -> dict:
        return {"members_active": self.one("SELECT COUNT(DISTINCT member_id) AS n FROM access WHERE status='active'")["n"],
                "devices_active": self.one("SELECT COUNT(*) AS n FROM access WHERE status='active'")["n"],
                "tickets_open": self.one("SELECT COUNT(*) AS n FROM tickets WHERE status='open'")["n"]}


def b64_pub(raw: bytes) -> str:
    """ssh-ed25519 public key text of a raw 32-byte key (tests and the reference client)."""
    import struct
    name = b"ssh-ed25519"
    blob = struct.pack(">I", len(name)) + name + struct.pack(">I", 32) + raw
    return "ssh-ed25519 " + base64.b64encode(blob).decode()
