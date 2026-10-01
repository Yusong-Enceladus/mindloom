"""Shared spaces on the Spark (SPACES-CONTRACT): per-space op logs, rights, invites, keys and ciphertext.

A personal space is a vault with one member; a shared space is a vault with N members. The keys live only on
the members' devices. What this module keeps, per space, in <data_dir>/spaces/spaces.db (plain SQLite: it
must work while no member is online, so it holds no plaintext content, only ids, roles, times and ciphertext)
and <data_dir>/spaces/<space_id>/blobs/:

  * an op log: every member action is an op signed by the member's device (Ed25519, space_crypto.py), ordered
    by the Spark (seq), idempotent by op_id. The Spark verifies each signature against the device keys it has
    on record and applies the op only if the member's role allows it. Content inside an op (item metadata and
    text, names, hints, reasons) is ciphertext made on a member's Mac, in *detached* fields the signed JSON
    commits to by hash, so a withdraw or removal can delete it (crypto-shredding) and the signature still
    verifies;
  * key wraps per epoch (the space key sealed to each member device), epoch links (the previous epoch's key
    under the new one), and one wrapped data key per shared item (by the space key of an epoch);
  * a ciphertext blob store for shared originals (files, screenshots, a meeting segment's audio);
  * invites (one-time, expiring, the pinned host key) and join requests;
  * roles and rights (GitHub model: personal-owned group spaces vs organization spaces, read / write /
    maintain / admin, outside collaborators), the withdraw window, takedown requests (a privacy takedown not
    handled within the policy's window is carried out by the Spark itself), the proposals queue, maintainers'
    removal (tombstone + purge), forks, matter handover, archive;
  * an audit log: records only (who, when, which action on which ids), never content;
  * v8: org key escrow (each epoch's key also wrapped to the organization's admin devices, by the org's
    recovery_admins policy) and space.recover; a storage quota per member per space (B5, B6; docs/INFRA.md);
  * v8 contract C: a meeting segment's audio as a members-only ciphertext blob (one audio part per recording and
    member, shorter than the recording and at most 15 minutes, its size bounded by its length; purged with the
    item), snapshots (a frozen summary shared as a new item; removed with any space item it cites), durable
    acceptance of retried shares (share_key, idempotent withdraw, retry hints, synchronous commits), and one
    member's several devices (one device id belongs to one member on this Spark; org.device_add / remove).

The space's organizer store (the same skills assembling shared matters from all members' shared items) is
organizer/space_organizer.py; it is encrypted and opened only by a member Mac's lease.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from . import db
from . import space_crypto as sc

log = logging.getLogger("organizer.spaces")

ROLES = {"read": 1, "write": 2, "maintain": 3, "admin": 4}
ROLE_NAMES = {v: k for k, v in ROLES.items()}

# Item kinds a space accepts. A whole recording is never shared (only a segment of it), and what belongs to the
# body and habits never leaves the Mac (SPACES-CONTRACT section 0, rule 3).
ITEM_KINDS = {"dictation", "meeting_online", "meeting_offline", "imported_media", "text", "link", "image",
              "document", "file", "audio_segment", "snapshot"}
NEVER_SHARED = {"recording", "voiceprint", "speaker_embedding", "dictionary", "personal_model", "vocabulary",
                "recognition_profile"}
BLOB_ROLES = {"original", "image", "file", "audio", "preview"}
AUDIO_KINDS = {"meeting_online", "meeting_offline", "imported_media", "audio_segment"}
MAX_SEGMENT_MS = 15 * 60 * 1000          # one shared audio segment: at most 15 minutes of a recording
AUDIO_PART_NUM, AUDIO_PART_DEN = 4, 5    # V8R-15: an audio part is at most 4/5 of its recording
MAX_OP_BYTES = 256 * 1024
MAX_OPS_PER_POST = 50
INVITE_MAX_S = 7 * 86400
INVITE_MAX_FAILURES = 10
REQUEST_SKEW_S = 300
NONCE_TTL_S = 900
PENDING_BLOB_TTL_S = 86400
PROPOSAL_KINDS = {"rename", "split", "merge", "move_to_rope", "relation", "other"}
TAKEDOWN_KINDS = {"privacy", "other"}
MAX_OPEN_PRIVACY_TAKEDOWNS = 3          # open privacy takedowns one member keeps on items others shared
RECOVERY_ADMINS = (1, 2, 3)             # org policy: how many admins' devices every org space key is wrapped to
# v8 C1: a meeting segment's audio (blob role "audio"). The Spark cannot open it, so it bounds what it stores by
# what the signed op declares: at most 256 kbit/s of the part's length (room for 16 kHz 16-bit mono PCM; the Mac
# sends AAC) plus a container header, one audio blob per item, one audio part per recording per member and space.
AUDIO_BYTES_PER_S = 32_000
AUDIO_OVERHEAD_BYTES = 64 * 1024
MAX_SNAPSHOT_CITES = 500                # v8 C2: space items one snapshot names as its sources
# v8 C3: what a member Mac's outbox does with a refused op: "remake" (sync the keys, then make a new op for the same
# outbox entry, same share_key), "later" (send the very same op again later, e.g. after re-uploading its blob or
# freeing quota), "never" (drop the entry and tell the user). Codes not listed here are "never".
RETRY = {"rotation_pending": "remake", "stale_epoch": "remake", "bad_epoch": "remake", "escrow_required": "remake",
         "unknown_blob": "later", "quota_exceeded": "later", "unavailable": "later", "busy": "later"}

# What a member Mac checks before it sends (GET /v1/spaces/{id} "limits"; the same numbers the handlers enforce).
LIMITS = {"segment_ms": MAX_SEGMENT_MS, "audio_bytes_per_s": AUDIO_BYTES_PER_S,
          "audio_overhead_bytes": AUDIO_OVERHEAD_BYTES, "blob_bytes": sc.MAX_BLOB_BYTES, "blobs_per_item": 20,
          "ops_per_post": MAX_OPS_PER_POST, "snapshot_cites": MAX_SNAPSHOT_CITES}

DEFAULT_POLICY = {
    "org": {"withdraw_window_h": 24, "takedown_window_h": 72, "forks_allowed": False, "originals": "members",
            "on_leave": "keep", "segment_audio": True},
    "person": {"withdraw_window_h": None, "takedown_window_h": 72, "forks_allowed": True, "originals": "members",
               "on_leave": "contributor_choice", "segment_audio": True},
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS orgs(org_id TEXT PRIMARY KEY, policy TEXT NOT NULL, created_ts REAL NOT NULL,
  head INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS org_admins(org_id TEXT NOT NULL, member_id TEXT NOT NULL, status TEXT NOT NULL,
  since_ts REAL NOT NULL, PRIMARY KEY(org_id, member_id));
CREATE TABLE IF NOT EXISTS org_devices(org_id TEXT NOT NULL, device_id TEXT NOT NULL, member_id TEXT NOT NULL,
  sign_pub TEXT NOT NULL, seal_pub TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(org_id, device_id));
CREATE TABLE IF NOT EXISTS org_ops(org_id TEXT NOT NULL, seq INTEGER NOT NULL, op_id TEXT NOT NULL,
  type TEXT NOT NULL, member_id TEXT, device_id TEXT, op BLOB NOT NULL, sig TEXT, enc TEXT,
  applied_ts REAL NOT NULL, result TEXT, PRIMARY KEY(org_id, seq), UNIQUE(org_id, op_id));
CREATE TABLE IF NOT EXISTS spaces(space_id TEXT PRIMARY KEY, owner_kind TEXT NOT NULL, owner_member TEXT,
  org_id TEXT, policy TEXT NOT NULL, epoch INTEGER NOT NULL, rotation_pending INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0, created_ts REAL NOT NULL, head INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS members(space_id TEXT NOT NULL, member_id TEXT NOT NULL, role TEXT NOT NULL,
  outside INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, joined_ts REAL NOT NULL, ended_ts REAL,
  PRIMARY KEY(space_id, member_id));
CREATE TABLE IF NOT EXISTS devices(space_id TEXT NOT NULL, device_id TEXT NOT NULL, member_id TEXT NOT NULL,
  sign_pub TEXT NOT NULL, seal_pub TEXT NOT NULL, status TEXT NOT NULL, added_seq INTEGER NOT NULL,
  PRIMARY KEY(space_id, device_id));
CREATE TABLE IF NOT EXISTS ops(space_id TEXT NOT NULL, seq INTEGER NOT NULL, op_id TEXT NOT NULL,
  type TEXT NOT NULL, member_id TEXT, device_id TEXT, op BLOB NOT NULL, sig TEXT, enc TEXT,
  applied_ts REAL NOT NULL, purged INTEGER NOT NULL DEFAULT 0, subject TEXT, result TEXT,
  PRIMARY KEY(space_id, seq), UNIQUE(space_id, op_id));
CREATE INDEX IF NOT EXISTS ops_subject ON ops(space_id, subject);
CREATE TABLE IF NOT EXISTS key_wraps(space_id TEXT NOT NULL, epoch INTEGER NOT NULL, device_id TEXT NOT NULL,
  wrap TEXT NOT NULL, PRIMARY KEY(space_id, epoch, device_id));
CREATE TABLE IF NOT EXISTS epoch_links(space_id TEXT NOT NULL, epoch INTEGER NOT NULL, prev_wrap TEXT NOT NULL,
  PRIMARY KEY(space_id, epoch));
CREATE TABLE IF NOT EXISTS items(space_id TEXT NOT NULL, item_id TEXT NOT NULL, contributor TEXT NOT NULL,
  device_id TEXT NOT NULL, kind TEXT NOT NULL, revision INTEGER NOT NULL, status TEXT NOT NULL,
  share_seq INTEGER NOT NULL, first_ts REAL NOT NULL, updated_seq INTEGER NOT NULL, ended_seq INTEGER,
  ended_by TEXT, ended_reason TEXT, PRIMARY KEY(space_id, item_id));
CREATE TABLE IF NOT EXISTS item_keys(space_id TEXT NOT NULL, item_id TEXT NOT NULL, epoch INTEGER NOT NULL,
  wrapped_dk TEXT NOT NULL, PRIMARY KEY(space_id, item_id));
CREATE TABLE IF NOT EXISTS blobs(space_id TEXT NOT NULL, blob_id TEXT NOT NULL, device_id TEXT NOT NULL,
  item_id TEXT, size INTEGER NOT NULL, sha256 TEXT NOT NULL, status TEXT NOT NULL, created_ts REAL NOT NULL,
  PRIMARY KEY(space_id, blob_id));
CREATE TABLE IF NOT EXISTS invites(space_id TEXT NOT NULL, invite_id TEXT NOT NULL, secret_hash TEXT NOT NULL,
  role TEXT NOT NULL, outside INTEGER NOT NULL, host_key TEXT, expires_ts REAL NOT NULL, status TEXT NOT NULL,
  created_by TEXT NOT NULL, created_seq INTEGER NOT NULL, request_id TEXT, failures INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(space_id, invite_id));
CREATE TABLE IF NOT EXISTS join_requests(space_id TEXT NOT NULL, request_id TEXT NOT NULL, invite_id TEXT NOT NULL,
  member_id TEXT NOT NULL, device_id TEXT NOT NULL, sign_pub TEXT NOT NULL, seal_pub TEXT NOT NULL,
  profile TEXT, request BLOB NOT NULL, sig TEXT NOT NULL, status TEXT NOT NULL, created_ts REAL NOT NULL,
  resolved_seq INTEGER, PRIMARY KEY(space_id, request_id));
CREATE TABLE IF NOT EXISTS takedowns(space_id TEXT NOT NULL, takedown_id TEXT NOT NULL, item_id TEXT NOT NULL,
  kind TEXT NOT NULL, requester TEXT NOT NULL, status TEXT NOT NULL, created_ts REAL NOT NULL,
  due_ts REAL, op_seq INTEGER NOT NULL, resolved_seq INTEGER, PRIMARY KEY(space_id, takedown_id));
CREATE TABLE IF NOT EXISTS proposals(space_id TEXT NOT NULL, proposal_id TEXT NOT NULL, author TEXT NOT NULL,
  kind TEXT NOT NULL, targets TEXT NOT NULL, status TEXT NOT NULL, op_seq INTEGER NOT NULL,
  resolved_seq INTEGER, resolved_by TEXT, PRIMARY KEY(space_id, proposal_id));
CREATE TABLE IF NOT EXISTS hidden(space_id TEXT NOT NULL, member_id TEXT NOT NULL, item_id TEXT NOT NULL,
  PRIMARY KEY(space_id, member_id, item_id));
CREATE TABLE IF NOT EXISTS forks(space_id TEXT NOT NULL, member_id TEXT NOT NULL, item_id TEXT NOT NULL,
  seq INTEGER NOT NULL, PRIMARY KEY(space_id, member_id, item_id));
CREATE TABLE IF NOT EXISTS packages(space_id TEXT NOT NULL, package_id TEXT NOT NULL, member_id TEXT NOT NULL,
  auto TEXT NOT NULL, item_count INTEGER NOT NULL, status TEXT NOT NULL, seq INTEGER NOT NULL,
  PRIMARY KEY(space_id, package_id));
CREATE TABLE IF NOT EXISTS matter_leads(space_id TEXT NOT NULL, matter_id TEXT NOT NULL, member_id TEXT NOT NULL,
  seq INTEGER NOT NULL, PRIMARY KEY(space_id, matter_id));
CREATE TABLE IF NOT EXISTS organizer_purges(space_id TEXT NOT NULL, item_id TEXT NOT NULL, queued_ts REAL NOT NULL,
  PRIMARY KEY(space_id, item_id));
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, space_id TEXT, org_id TEXT, seq INTEGER,
  at TEXT NOT NULL, actor_member TEXT, actor_device TEXT, action TEXT NOT NULL, target TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS audit_space ON audit(space_id, id);
CREATE INDEX IF NOT EXISTS audit_org ON audit(org_id, id);
CREATE TABLE IF NOT EXISTS nonces(device_id TEXT NOT NULL, nonce TEXT NOT NULL, ts REAL NOT NULL,
  PRIMARY KEY(device_id, nonce));
CREATE TABLE IF NOT EXISTS segments(space_id TEXT NOT NULL, item_id TEXT NOT NULL, contributor TEXT NOT NULL,
  parent_item_id TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, PRIMARY KEY(space_id, item_id));
CREATE INDEX IF NOT EXISTS segments_parent ON segments(space_id, contributor, parent_item_id);
CREATE TABLE IF NOT EXISTS escrow_wraps(space_id TEXT NOT NULL, epoch INTEGER NOT NULL, device_id TEXT NOT NULL,
  member_id TEXT NOT NULL, wrap TEXT NOT NULL, PRIMARY KEY(space_id, epoch, device_id));
CREATE TABLE IF NOT EXISTS snapshot_cites(space_id TEXT NOT NULL, snapshot_id TEXT NOT NULL, item_id TEXT NOT NULL,
  PRIMARY KEY(space_id, snapshot_id, item_id));
CREATE INDEX IF NOT EXISTS snapshot_cites_item ON snapshot_cites(space_id, item_id);
"""

# Columns added after the first deployment (an existing spaces.db gets them on open).
MIGRATIONS = [("join_requests", "binding", "TEXT"),
              ("items", "share_key", "TEXT"),                          # v8 C3: the Mac outbox entry of the share
              ("blobs", "role", "TEXT"),                               # v8 C1: original / image / file / audio / preview
              ("segments", "audio", "INTEGER NOT NULL DEFAULT 0"),     # v8 C1: this part carries the audio
              ("segments", "recording_ms", "INTEGER")]                 # v8 C1: the whole recording's length


class SpaceError(Exception):
    """A refused request: HTTP status, a short code the Mac branches on, and an optional detail (never content)."""

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
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds")


def parse_ts(value: object) -> Optional[float]:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return None
    return dt.timestamp()


def _dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _need(cond: bool, code: str, detail: str = "", status: int = 422) -> None:
    if not cond:
        raise SpaceError(status, code, detail)


def _uuid_field(obj: dict, key: str, required: bool = True) -> Optional[str]:
    value = obj.get(key)
    if value is None and not required:
        return None
    _need(sc.is_uuid(value), "bad_field", f"{key} must be a lowercase UUID")
    return value


def _item_id(value: object) -> str:
    """Item ids are the Mac's item UUIDs; spaces compare and return them in lower case."""
    _need(isinstance(value, str) and sc.is_uuid(value.lower()), "bad_field", "item_id must be a UUID")
    return value.lower()


def _device_record(value: object) -> dict:
    _need(isinstance(value, dict), "bad_field", "device must be an object")
    _uuid_field(value, "device_id")
    _need(sc.public_key(value.get("sign_pub")) is not None, "bad_field", "sign_pub must be 32 bytes base64url")
    _need(sc.public_key(value.get("seal_pub")) is not None, "bad_field", "seal_pub must be 32 bytes base64url")
    return {"device_id": value["device_id"], "sign_pub": sc.b64u(sc.public_key(value["sign_pub"])),
            "seal_pub": sc.b64u(sc.public_key(value["seal_pub"]))}


def parse_wire(wire: object, scope_key: str = "space_id") -> tuple[dict, bytes, dict]:
    """(payload, raw op bytes, detached fields) of a signed op on the wire; the signature is checked by the
    caller against the device it names."""
    _need(isinstance(wire, dict), "bad_op", "an op is an object", 400)
    raw = sc.b64u_decode(wire.get("op"))
    _need(raw is not None and 0 < len(raw) <= MAX_OP_BYTES, "bad_op", "op must be base64url JSON", 400)
    _need(isinstance(wire.get("sig"), str), "bad_op", "sig missing", 400)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise SpaceError(400, "bad_op", "op is not UTF-8 JSON") from None
    _need(isinstance(payload, dict) and payload.get("v") == 1, "bad_op", "op v must be 1", 400)
    for key in (scope_key, "op_id", "member_id", "device_id"):
        _need(sc.is_uuid(payload.get(key)), "bad_op", f"{key} must be a lowercase UUID", 400)
    _need(isinstance(payload.get("type"), str) and len(payload["type"]) <= 40, "bad_op", "type missing", 400)
    _need(isinstance(payload.get("body"), dict), "bad_op", "body must be an object", 400)
    detached: dict[str, str] = {}
    for name in ("enc", "wrapped_dk"):
        committed = payload.get(f"{name}_sha256")
        value = wire.get(name)
        if committed is None:
            _need(value is None, "bad_op", f"{name} is not committed to by the signed op", 400)
            continue
        _need(isinstance(value, str) and sc.HEX64_RE.match(str(committed)) is not None
              and sc.detached_hash(value) == committed, "bad_op", f"{name} does not match its hash", 400)
        problem = sc.enc_problem(value) if name == "enc" else sc.ikey_problem(value)
        _need(problem is None, "not_ciphertext", f"{name}: {problem}")
        detached[name] = value
    return payload, raw, detached


class Actor:
    """The member device behind a signed request."""

    def __init__(self, space_id: str, member: dict, device: dict, role: int):
        self.space_id = space_id
        self.member_id = member["member_id"]
        self.device_id = device["device_id"]
        self.role = role
        self.member = member
        self.device = device


class Spaces:
    def __init__(self, data_dir: str | Path, *, now: Callable[[], float] = time.time,
                 host_keys: Optional[Callable[[], list[str]]] = None, member_quota_mb: int = 2048,
                 member_total_mb: int = 8192, max_spaces_per_member: int = 30):
        self.root = Path(data_dir) / "spaces"
        # v8 B6: a member's storage in one space (ciphertext blobs + encrypted fields). The Spark owner's ceiling:
        # a space's policy may only lower it (review finding V8R-09); 0 = no ceiling.
        self.member_quota_mb = int(member_quota_mb)
        # V8R-09: one member's storage across all the spaces here (0 = no limit) and the spaces one member id creates
        self.member_total_mb = int(member_total_mb)
        self.max_spaces_per_member = int(max_spaces_per_member)
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.now = now
        self._host_keys = host_keys or read_host_keys
        self._lock = threading.RLock()
        self._depth = 0
        self.conn = db.connect(self.root / "spaces.db", None, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = db.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        # v8 C3: an op the Spark answered "ok" survives a power cut too (WAL synced at every commit): a member Mac's
        # outbox drops an entry once it is accepted, so an accepted share must not roll back afterwards.
        self.conn.execute("PRAGMA synchronous=FULL")
        self.conn.execute("PRAGMA secure_delete=ON")
        self.conn.executescript(SCHEMA)
        for table, column, kind in MIGRATIONS:
            have = {r[1] for r in self.conn.execute(f"PRAGMA table_info({table})").fetchall()}
            if column not in have:
                self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
        os.chmod(self.root / "spaces.db", 0o600)
        # set by the space organizers: called with (space_id, item_id) after an item is withdrawn or removed, and
        # with (space_id) after the space key rotated (the organizer store locks until a lease re-keys it)
        self.on_purge: Optional[Callable[[str, str], None]] = None
        self.on_rotate: Optional[Callable[[str], None]] = None
        # v8: the per-member access records (organizer/access.py), when this Spark has them: a Mac enrolled there is
        # bound to its member id and keys like a device of a space (one device id, one member, one key).
        self.directory: Optional[Any] = None

    # ---- db helpers ---------------------------------------------------------------------------------

    @contextmanager
    def tx(self) -> Iterator["Spaces"]:
        with self._lock:
            outer = self._depth == 0
            if outer:
                self.conn.execute("BEGIN IMMEDIATE")
            self._depth += 1
            try:
                yield self
            except BaseException:
                self._depth -= 1
                if outer:
                    self.conn.execute("ROLLBACK")
                raise
            else:
                self._depth -= 1
                if outer:
                    self.conn.execute("COMMIT")

    def x(self, sql: str, args: tuple | list = ()) -> db.Cursor:
        with self._lock:
            return self.conn.execute(sql, args)

    def one(self, sql: str, args: tuple | list = ()) -> Optional[dict]:
        with self._lock:
            row = self.conn.execute(sql, args).fetchone()
        return dict(row) if row else None

    def all(self, sql: str, args: tuple | list = ()) -> list[dict]:
        with self._lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def close(self) -> None:
        with self._lock:
            self.conn.close()

    # ---- lookups ------------------------------------------------------------------------------------

    def space(self, space_id: str) -> dict:
        row = self.one("SELECT * FROM spaces WHERE space_id=?", (space_id,)) if sc.is_uuid(space_id) else None
        if row is None:
            raise SpaceError(404, "unknown_space")
        row["policy"] = json.loads(row["policy"])
        return row

    def space_dir(self, space_id: str) -> Path:
        return self.root / space_id

    def blob_path(self, space_id: str, blob_id: str) -> Path:
        return self.space_dir(space_id) / "blobs" / blob_id

    def member(self, space_id: str, member_id: str) -> Optional[dict]:
        return self.one("SELECT * FROM members WHERE space_id=? AND member_id=?", (space_id, member_id))

    def is_org_admin(self, org_id: Optional[str], member_id: str) -> bool:
        if not org_id:
            return False
        return self.one("SELECT 1 FROM org_admins WHERE org_id=? AND member_id=? AND status='active'",
                        (org_id, member_id)) is not None

    def org_admin_here(self, space: dict, member_id: str, device: Optional[dict] = None) -> bool:
        """An org admin acting in an org space: the member id is an active org admin's AND the device (the one
        that signed, or when none is given any of the member's active devices here) is that admin's own org
        device with the same key. A member id alone proves nothing: it is visible to every member of every org
        space, and an invite holder could otherwise claim it (review finding V7-S2)."""
        if space["owner_kind"] != "org" or not self.is_org_admin(space["org_id"], member_id):
            return False
        devices = [device] if device is not None else self.all(
            "SELECT device_id, sign_pub FROM devices WHERE space_id=? AND member_id=? AND status='active'",
            (space["space_id"], member_id))
        for d in devices:
            od = self.one("SELECT sign_pub FROM org_devices WHERE org_id=? AND device_id=? AND member_id=? AND"
                          " status='active'", (space["org_id"], d["device_id"], member_id))
            if od is not None and od["sign_pub"] == d["sign_pub"]:
                return True
        return False

    def effective_role(self, space: dict, member: dict, device: Optional[dict] = None) -> int:
        if member["status"] != "active":
            return 0
        role = ROLES[member["role"]]
        if space["owner_kind"] == "person" and member["member_id"] == space["owner_member"]:
            return ROLES["admin"]
        if self.org_admin_here(space, member["member_id"], device):
            return ROLES["admin"]
        return role

    def _member_id_keys(self, member_id: str, space_id: Optional[str] = None) -> set[str]:
        """Every signing key a member id is already bound to anywhere on this Spark (devices of any space, the
        organizations' admin devices, join requests still pending or approved in other spaces, and v8 the Macs
        enrolled for it in the access records, i.e. a second Mac its first one invited)."""
        keys: set[str] = set()
        for sql, args in (("SELECT sign_pub FROM devices WHERE member_id=?", (member_id,)),
                          ("SELECT sign_pub FROM org_devices WHERE member_id=?", (member_id,)),
                          ("SELECT sign_pub FROM join_requests WHERE member_id=? AND status IN ('pending','approved')"
                           " AND (? IS NULL OR space_id!=?)", (member_id, space_id, space_id))):
            keys |= {r["sign_pub"] for r in self.all(sql, args)}
        if self.directory is not None:
            keys |= self.directory.member_keys(member_id)
        return keys

    def _member_id_known(self, member_id: str) -> bool:
        if any(self.one(sql, (member_id,)) for sql in (
                "SELECT 1 FROM members WHERE member_id=? LIMIT 1", "SELECT 1 FROM org_admins WHERE member_id=? LIMIT 1")):
            return True
        return self.directory is not None and self.directory.member_known(member_id)

    def _known_sign_pub(self, device_id: str) -> Optional[str]:
        """The signing key a device id is bound to anywhere on this Spark (one device id, one key)."""
        for sql in ("SELECT sign_pub FROM devices WHERE device_id=? LIMIT 1",
                    "SELECT sign_pub FROM org_devices WHERE device_id=? LIMIT 1",
                    "SELECT sign_pub FROM join_requests WHERE device_id=? AND status IN ('pending','approved') LIMIT 1"):
            row = self.one(sql, (device_id,))
            if row:
                return row["sign_pub"]
        rec = self.directory.device_record(device_id) if self.directory is not None else None
        return rec["sign_pub"] if rec else None

    def _space_device_member(self, device_id: str) -> Optional[str]:
        """The member a device id belongs to in the spaces and organizations of this Spark (not the access records)."""
        for sql in ("SELECT member_id FROM devices WHERE device_id=? LIMIT 1",
                    "SELECT member_id FROM org_devices WHERE device_id=? LIMIT 1",
                    "SELECT member_id FROM join_requests WHERE device_id=? AND status IN ('pending','approved') LIMIT 1"):
            row = self.one(sql, (device_id,))
            if row:
                return row["member_id"]
        return None

    def _device_member(self, device_id: str) -> Optional[str]:
        """v8: one device id belongs to one member on this Spark (spaces, organizations and access records)."""
        owner = self._space_device_member(device_id)
        if owner is None and self.directory is not None:
            rec = self.directory.device_record(device_id)
            owner = rec["member_id"] if rec else None
        return owner

    def _check_device_binding(self, device: dict, member_id: Optional[str] = None, added: bool = False) -> None:
        """One device id, one key and (v8) one member across the whole Spark. `added`: someone else adds this device
        (device.add, org.admin_add, org.device_add): a Mac whose access was unpaired here is not added back."""
        known = self._known_sign_pub(device["device_id"])
        if known is not None and known != device["sign_pub"]:
            raise SpaceError(409, "device_key_conflict", "this device id is registered with another key")
        if member_id is None:
            return
        owner = self._device_member(device["device_id"])
        if owner is not None and owner != member_id:
            raise SpaceError(409, "device_member_conflict", "this device belongs to another member on this Spark")
        if added and self.directory is not None:
            rec = self.directory.device_record(device["device_id"])
            if rec is not None and rec["status"] != "active":
                raise SpaceError(409, "device_revoked", "this Mac was unpaired from the Spark; pair it again first")

    # ---- signed requests ----------------------------------------------------------------------------

    def _check_request(self, device_id: object, sign_pub: str, method: str, target: str,
                       headers: dict, body: bytes) -> None:
        date, nonce, sig = headers.get("date"), headers.get("nonce"), headers.get("signature")
        try:
            date_i = int(str(date))
        except (TypeError, ValueError):
            raise SpaceError(401, "bad_signature", "X-Mindloom-Date must be unix seconds") from None
        if abs(self.now() - date_i) > REQUEST_SKEW_S:
            raise SpaceError(401, "stale_request", "the request's date is more than 5 minutes off")
        if not isinstance(nonce, str) or sc.NONCE_RE.match(nonce) is None:
            raise SpaceError(401, "bad_signature", "X-Mindloom-Nonce must be 16-64 base64url characters")
        message = sc.request_message(method, target, str(date), nonce, body)
        if not sc.verify(sc.b64u_decode(sign_pub), message, sig):
            raise SpaceError(401, "bad_signature")
        now = self.now()
        # The nonces seen in the last 15 minutes are kept in spaces.db, so a restart does not reopen the window
        # for replaying a captured signed request (review finding V7-S18).
        with self._lock:
            self.x("DELETE FROM nonces WHERE ts < ?", (now - NONCE_TTL_S,))
            if self.one("SELECT 1 FROM nonces WHERE device_id=? AND nonce=?", (str(device_id), nonce)):
                raise SpaceError(401, "replayed")
            self.x("INSERT INTO nonces(device_id, nonce, ts) VALUES (?,?,?)", (str(device_id), nonce, now))

    def authenticate(self, space_id: str, method: str, target: str, headers: dict, body: bytes,
                     min_role: int = ROLES["read"]) -> Actor:
        """The active member device that signed this request (headers: device, date, nonce, signature)."""
        space = self.space(space_id)
        device_id = headers.get("device")
        if not sc.is_uuid(device_id):
            raise SpaceError(401, "unknown_device")
        dev = self.one("SELECT * FROM devices WHERE space_id=? AND device_id=?", (space_id, device_id))
        if dev is None:
            raise SpaceError(401, "unknown_device")
        self._check_request(device_id, dev["sign_pub"], method, target, headers, body)
        self._refuse_unpaired(device_id)
        member = self.member(space_id, dev["member_id"])
        if dev["status"] != "active" or member is None or member["status"] != "active":
            # A device whose access ended learns it on its next sync, with the forks it must delete
            # (honest limit: a device that never syncs again cannot be made to).
            forks = [r["item_id"] for r in self.all("SELECT item_id FROM forks WHERE space_id=? AND member_id=?",
                                                    (space_id, dev["member_id"]))]
            status = (member or {}).get("status", "removed")
            raise SpaceError(403, "not_member", member_status="device_removed" if status == "active" else status,
                             purge_forks=forks, removal=self._removal_entry(space_id, dev))
        role = self.effective_role(space, member, dev)
        if role < min_role:
            raise SpaceError(403, "forbidden", f"needs role {ROLE_NAMES[min_role]}")
        return Actor(space_id, member, dev, role)

    def _removal_entry(self, space_id: str, dev: dict) -> Optional[dict]:
        """The signed op that ended this device's access (member.remove of its member, device.remove of it, or its
        member's own leave), as an op-log entry: a member Mac deletes its copy of the space only after it verifies
        this against the members its own signed log admitted (review finding V7-S16)."""
        rows = self.all("SELECT * FROM ops WHERE space_id=? AND type IN ('member.remove','device.remove','member.leave')"
                        " ORDER BY seq DESC", (space_id,))
        for r in rows:
            try:
                op = json.loads(bytes(r["op"]).decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                continue
            body = op.get("body") or {}
            if (r["type"] == "member.remove" and body.get("member_id") == dev["member_id"]) or \
                    (r["type"] == "device.remove" and body.get("device_id") == dev["device_id"]) or \
                    (r["type"] == "member.leave" and r["member_id"] == dev["member_id"]):
                return {"seq": r["seq"], "type": r["type"], "applied_at": iso(r["applied_ts"]), "op": sc.b64u(r["op"]),
                        "sig": r["sig"], "enc": None, "purged": bool(r["purged"])}
        return None

    def authenticate_device(self, method: str, target: str, headers: dict, body: bytes) -> str:
        """A device known to this Spark (any space or organization), for GET /v1/spaces."""
        device_id = headers.get("device")
        if not sc.is_uuid(device_id):
            raise SpaceError(401, "unknown_device")
        sign_pub = self._known_sign_pub(device_id)
        if sign_pub is None:
            raise SpaceError(401, "unknown_device")
        self._check_request(device_id, sign_pub, method, target, headers, body)
        self._refuse_unpaired(device_id)
        return device_id

    def _refuse_unpaired(self, device_id: str) -> None:
        """A Mac whose access to this Spark was unpaired reads and writes nothing here any more, whatever channel
        it comes through (review finding V8R-07; it may not enroll again either, access.enroll)."""
        rec = self.directory.device_record(device_id) if self.directory is not None else None
        if rec is not None and rec["status"] != "active":
            raise SpaceError(403, "device_revoked", "this Mac was unpaired from the Spark")

    # ---- audit ----------------------------------------------------------------------------------------

    def audit(self, action: str, target: dict, *, space_id: Optional[str] = None, org_id: Optional[str] = None,
              seq: Optional[int] = None, member_id: Optional[str] = None, device_id: Optional[str] = None) -> None:
        """One record: ids, counts and codes only (never names, text or ciphertext)."""
        if space_id and org_id is None:
            row = self.one("SELECT org_id FROM spaces WHERE space_id=?", (space_id,))
            org_id = row["org_id"] if row else None
        self.x("INSERT INTO audit(space_id, org_id, seq, at, actor_member, actor_device, action, target)"
               " VALUES (?,?,?,?,?,?,?,?)",
               (space_id, org_id, seq, iso(self.now()), member_id, device_id, action, _dumps(target)))

    # ---- organizations --------------------------------------------------------------------------------

    def create_org(self, wire: object) -> dict:
        payload, raw, det = parse_wire(wire, "org_id")
        _need(payload["type"] == "org.create", "bad_op", "POST /v1/orgs takes an org.create op", 400)
        body = payload["body"]
        device = _device_record(body.get("device"))
        _need(device["device_id"] == payload["device_id"], "bad_field", "device.device_id must sign the op")
        if not sc.verify(sc.b64u_decode(device["sign_pub"]), sc.OP_DOMAIN + raw, wire.get("sig")):
            raise SpaceError(401, "bad_signature")
        policy = body.get("policy") or {}
        _need(isinstance(policy, dict), "bad_field", "policy must be an object")
        recovery = policy.get("recovery_admins", 1)
        _need(recovery in RECOVERY_ADMINS, "bad_field", "recovery_admins is 1, 2 or 3")
        org_id = payload["org_id"]
        with self.tx():
            existing = self.one("SELECT * FROM org_ops WHERE org_id=? AND op_id=?", (org_id, payload["op_id"]))
            if existing:
                return self._duplicate(existing, raw)
            if self.one("SELECT 1 FROM orgs WHERE org_id=?", (org_id,)):
                raise SpaceError(409, "org_exists")
            self._check_device_binding(device, payload["member_id"])
            now = self.now()
            self.x("INSERT INTO orgs(org_id, policy, created_ts, head) VALUES (?,?,?,1)",
                   (org_id, _dumps({"recovery_admins": recovery}), now))
            self.x("INSERT INTO org_admins(org_id, member_id, status, since_ts) VALUES (?,?,'active',?)",
                   (org_id, payload["member_id"], now))
            self.x("INSERT INTO org_devices VALUES (?,?,?,?,?,'active')",
                   (org_id, device["device_id"], payload["member_id"], device["sign_pub"], device["seal_pub"]))
            result = {"org_id": org_id, "seq": 1}
            self.x("INSERT INTO org_ops VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                   (org_id, 1, payload["op_id"], "org.create", payload["member_id"], payload["device_id"], raw,
                    wire["sig"], det.get("enc"), now, _dumps(result)))
            self.audit("org.create", {"org_id": org_id}, org_id=org_id, seq=1, member_id=payload["member_id"],
                       device_id=payload["device_id"])
        return {"ok": True, "duplicate": False, **result}

    def org(self, org_id: str) -> dict:
        row = self.one("SELECT * FROM orgs WHERE org_id=?", (org_id,)) if sc.is_uuid(org_id) else None
        if row is None:
            raise SpaceError(404, "unknown_org")
        row["policy"] = json.loads(row["policy"])
        return row

    def authenticate_org(self, org_id: str, method: str, target: str, headers: dict, body: bytes) -> dict:
        """An org admin's device that signed this request."""
        self.org(org_id)
        device_id = headers.get("device")
        dev = self.one("SELECT * FROM org_devices WHERE org_id=? AND device_id=?", (org_id, device_id)) \
            if sc.is_uuid(device_id) else None
        if dev is None:
            raise SpaceError(401, "unknown_device")
        self._check_request(device_id, dev["sign_pub"], method, target, headers, body)
        self._refuse_unpaired(device_id)
        if dev["status"] != "active" or not self.is_org_admin(org_id, dev["member_id"]):
            raise SpaceError(403, "forbidden", "org admins only")
        return dev

    def apply_org_ops(self, org_id: str, wires: object) -> dict:
        _need(isinstance(wires, list) and 0 < len(wires) <= MAX_OPS_PER_POST, "bad_ops",
              f"ops is a list of 1-{MAX_OPS_PER_POST}", 400)
        self.org(org_id)
        results = []
        for wire in wires:
            try:
                results.append(self._apply_org_op(org_id, wire))
            except SpaceError as exc:
                results.append({"ok": False, "status": exc.status, **exc.body(), "op_id": _op_id_of(wire)})
        return {"results": results}

    def _apply_org_op(self, org_id: str, wire: object) -> dict:
        payload, raw, det = parse_wire(wire, "org_id")
        _need(payload["org_id"] == org_id, "wrong_org", "the op names another organization", 400)
        with self.tx():
            existing = self.one("SELECT * FROM org_ops WHERE org_id=? AND op_id=?", (org_id, payload["op_id"]))
            if existing:
                return self._duplicate(existing, raw)
            dev = self.one("SELECT * FROM org_devices WHERE org_id=? AND device_id=?", (org_id, payload["device_id"]))
            if dev is None or dev["member_id"] != payload["member_id"]:
                raise SpaceError(403, "unknown_device")
            if not sc.verify(sc.b64u_decode(dev["sign_pub"]), sc.OP_DOMAIN + raw, wire.get("sig")):
                raise SpaceError(401, "bad_signature")
            self._refuse_unpaired(dev["device_id"])
            if dev["status"] != "active" or not self.is_org_admin(org_id, payload["member_id"]):
                raise SpaceError(403, "forbidden", "org admins only")
            body, now = payload["body"], self.now()
            effects: dict = {}
            if payload["type"] == "org.admin_add":
                member_id = _uuid_field(body, "member_id")
                device = _device_record(body.get("device"))
                # v8: the named device is that member's own: not another member's (one device id, one member), and
                # for a member this Spark already knows, one of the keys it is bound to (a Mac of theirs in a space,
                # or one enrolled for them in the access records). A member's other Macs come with org.device_add,
                # signed by one of theirs.
                self._check_device_binding(device, member_id, added=True)
                if self._member_id_known(member_id) or self._member_id_keys(member_id):
                    _need(device["sign_pub"] in self._member_id_keys(member_id), "unknown_member_device",
                          "name a Mac this member already uses here; their other Macs add themselves (org.device_add)",
                          409)
                self.x("INSERT INTO org_admins(org_id, member_id, status, since_ts) VALUES (?,?,'active',?)"
                       " ON CONFLICT(org_id, member_id) DO UPDATE SET status='active'", (org_id, member_id, now))
                self.x("INSERT OR REPLACE INTO org_devices VALUES (?,?,?,?,?,'active')",
                       (org_id, device["device_id"], member_id, device["sign_pub"], device["seal_pub"]))
                target = {"member_id": member_id}
                effects = {"member_id": member_id, "device_id": device["device_id"]}
            elif payload["type"] == "org.device_add":
                # v8: an admin's own further Mac (a second Mac), signed by one of that admin's org devices
                device = _device_record(body.get("device"))
                self._check_device_binding(device, payload["member_id"], added=True)
                self.x("INSERT OR REPLACE INTO org_devices VALUES (?,?,?,?,?,'active')",
                       (org_id, device["device_id"], payload["member_id"], device["sign_pub"], device["seal_pub"]))
                target = {"member_id": payload["member_id"], "device_id": device["device_id"]}
                effects = dict(target)
            elif payload["type"] == "org.device_remove":
                target, effects = self._org_device_remove(org_id, payload, body)
            elif payload["type"] == "org.admin_remove":
                member_id = _uuid_field(body, "member_id")
                n = self.one("SELECT COUNT(*) AS n FROM org_admins WHERE org_id=? AND status='active'", (org_id,))["n"]
                _need(n > 1 or not self.is_org_admin(org_id, member_id), "last_admin",
                      "an organization keeps at least one admin", 409)
                self.x("UPDATE org_admins SET status='removed' WHERE org_id=? AND member_id=?", (org_id, member_id))
                self.x("UPDATE org_devices SET status='removed' WHERE org_id=? AND member_id=?", (org_id, member_id))
                demoted, alone = self._end_org_admin_rights(org_id, member_id)
                rekey = self._end_escrow(org_id, member_id)
                target = {"member_id": member_id, "demoted": len(demoted), "sole_admin": len(alone),
                          "rotation_pending": len(rekey)}
                effects = {"member_id": member_id, "demoted": demoted, "sole_admin": alone, "rotation_pending": rekey}
            elif payload["type"] == "org.policy":
                recovery = body.get("recovery_admins")
                _need(recovery in RECOVERY_ADMINS, "bad_field", "recovery_admins is 1, 2 or 3")
                self.x("UPDATE orgs SET policy=? WHERE org_id=?", (_dumps({"recovery_admins": recovery}), org_id))
                target = {"recovery_admins": recovery}
                effects = dict(target)
            else:
                raise SpaceError(400, "unknown_type", payload["type"])
            seq = self.one("SELECT head FROM orgs WHERE org_id=?", (org_id,))["head"] + 1
            result = {"org_id": org_id, "seq": seq, "effects": effects}
            self.x("UPDATE orgs SET head=? WHERE org_id=?", (seq, org_id))
            self.x("INSERT INTO org_ops VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                   (org_id, seq, payload["op_id"], payload["type"], payload["member_id"], payload["device_id"], raw,
                    wire["sig"], det.get("enc"), now, _dumps(result)))
            self.audit(payload["type"], target, org_id=org_id, seq=seq, member_id=payload["member_id"],
                       device_id=payload["device_id"])
        return {"ok": True, "op_id": payload["op_id"], "duplicate": False, **result}

    def _org_device_remove(self, org_id: str, payload: dict, body: dict) -> tuple[dict, dict]:
        """org.device_remove (v8): an admin retires one org device (a lost or retired Mac: theirs from another of
        their devices, or anyone's as an admin). The device gets no more escrow and no admin rights in the org's
        spaces. It knew the current key of every org space it held an escrow wrap for: those spaces wait for a new key
        (rotation_pending). Where it is still a member device of a space, a member signs device.remove there (that op
        rotates the key itself); the effects list those spaces."""
        device_id = _uuid_field(body, "device_id")
        dev = self.one("SELECT * FROM org_devices WHERE org_id=? AND device_id=?", (org_id, device_id))
        if dev is None or dev["status"] != "active":
            raise SpaceError(404, "unknown_device")
        # (the signing device stays, so the organization always keeps an active admin device)
        _need(device_id != payload["device_id"], "bad_field", "retire a device from another one")
        self.x("UPDATE org_devices SET status='removed' WHERE org_id=? AND device_id=?", (org_id, device_id))
        rekey = []
        for sp in self.all("SELECT space_id, epoch FROM spaces WHERE org_id=? ORDER BY created_ts", (org_id,)):
            if self.one("SELECT 1 FROM escrow_wraps WHERE space_id=? AND epoch=? AND device_id=?",
                        (sp["space_id"], sp["epoch"], device_id)):
                self.x("UPDATE spaces SET rotation_pending=1 WHERE space_id=?", (sp["space_id"],))
                rekey.append(sp["space_id"])
        self.x("DELETE FROM escrow_wraps WHERE device_id=? AND space_id IN (SELECT space_id FROM spaces WHERE org_id=?)",
               (device_id, org_id))
        member_of = [r["space_id"] for r in self.all(
            "SELECT d.space_id FROM devices d JOIN spaces s ON s.space_id=d.space_id WHERE d.device_id=? AND"
            " d.status='active' ORDER BY d.space_id", (device_id,))]
        target = {"member_id": dev["member_id"], "device_id": device_id, "rotation_pending": len(rekey)}
        return target, {"member_id": dev["member_id"], "device_id": device_id, "rotation_pending": rekey,
                        "still_member_in": member_of}

    def _end_org_admin_rights(self, org_id: str, member_id: str) -> tuple[list[str], list[str]]:
        """An admin removed from the organization keeps no admin rights in its spaces (review finding V7-S7):
        where another admin remains they become a contributor (write). Where they are the space's only admin they
        stay until an org admin who holds the space key takes over (the Spark holds no key and cannot rotate);
        the org summary lists those spaces under former_admins."""
        demoted, alone = [], []
        for sp in self.all("SELECT space_id FROM spaces WHERE org_id=?", (org_id,)):
            space = self.space(sp["space_id"])
            m = self.member(space["space_id"], member_id)
            if m is None or m["status"] != "active" or m["role"] != "admin":
                continue
            others = [x for x in self.all("SELECT * FROM members WHERE space_id=? AND status='active' AND member_id!=?",
                                          (space["space_id"], member_id))
                      if self.effective_role(space, x) == ROLES["admin"]]
            if others:
                self.x("UPDATE members SET role='write' WHERE space_id=? AND member_id=?", (space["space_id"], member_id))
                self.audit("member.role", {"member_id": member_id, "role": "write", "reason": "org_admin_removed"},
                           space_id=space["space_id"], org_id=org_id)
                demoted.append(space["space_id"])
            else:
                alone.append(space["space_id"])
        return demoted, alone

    def _end_escrow(self, org_id: str, member_id: str) -> list[str]:
        """A removed org admin's escrow wraps go. Where that admin held the current key only through escrow (not as
        an active member), the space waits for a new key before anything new is shared (like after a leave)."""
        rekey = []
        for sp in self.all("SELECT space_id, epoch FROM spaces WHERE org_id=?", (org_id,)):
            held = self.one("SELECT 1 FROM escrow_wraps WHERE space_id=? AND epoch=? AND member_id=?",
                            (sp["space_id"], sp["epoch"], member_id))
            m = self.member(sp["space_id"], member_id)
            if held and (m is None or m["status"] != "active"):
                self.x("UPDATE spaces SET rotation_pending=1 WHERE space_id=?", (sp["space_id"],))
                rekey.append(sp["space_id"])
        self.x("DELETE FROM escrow_wraps WHERE member_id=? AND space_id IN (SELECT space_id FROM spaces WHERE org_id=?)",
               (member_id, org_id))
        return rekey

    # ---- org key escrow (v8 B5) -------------------------------------------------------------------------

    def escrow_devices(self, org_id: str) -> list[dict]:
        """The org admins' active org devices: where an org space's key is escrowed."""
        return self.all("SELECT od.device_id, od.member_id, od.sign_pub, od.seal_pub FROM org_devices od JOIN org_admins"
                        " oa ON oa.org_id=od.org_id AND oa.member_id=od.member_id WHERE od.org_id=? AND"
                        " od.status='active' AND oa.status='active' ORDER BY od.member_id, od.device_id", (org_id,))

    def escrow_holders(self, space: dict, epoch: int) -> set[str]:
        """Org admins whose own org device can open this epoch's key: an escrow wrap, or a member wrap of that very
        device (same id and signing key) in the space."""
        holders = set()
        for d in self.escrow_devices(space["org_id"]):
            if self.one("SELECT 1 FROM escrow_wraps WHERE space_id=? AND epoch=? AND device_id=?",
                        (space["space_id"], epoch, d["device_id"])):
                holders.add(d["member_id"])
                continue
            dev = self.one("SELECT sign_pub, status FROM devices WHERE space_id=? AND device_id=?",
                           (space["space_id"], d["device_id"]))
            if dev and dev["status"] == "active" and dev["sign_pub"] == d["sign_pub"] and self.one(
                    "SELECT 1 FROM key_wraps WHERE space_id=? AND epoch=? AND device_id=?",
                    (space["space_id"], epoch, d["device_id"])):
                holders.add(d["member_id"])
        return holders

    def escrow_status(self, space: dict) -> Optional[dict]:
        """For an org space: how many admins must be able to open the current key (the org's recovery_admins, at
        most the admins there are), who can, and which admin devices still lack a wrap (an admin's Mac adds them
        with escrow.wrap)."""
        if space["owner_kind"] != "org":
            return None
        org = self.org(space["org_id"])
        devices = self.escrow_devices(space["org_id"])
        admins = {d["member_id"] for d in devices}
        required = min(int(org["policy"].get("recovery_admins", 1)), len(admins))
        holders = self.escrow_holders(space, space["epoch"])
        member_devices = {r["device_id"] for r in self.all(
            "SELECT device_id FROM key_wraps WHERE space_id=? AND epoch=?", (space["space_id"], space["epoch"]))}
        escrowed = {r["device_id"] for r in self.all(
            "SELECT device_id FROM escrow_wraps WHERE space_id=? AND epoch=?", (space["space_id"], space["epoch"]))}
        missing = [{"device_id": d["device_id"], "member_id": d["member_id"], "seal_pub": d["seal_pub"]}
                   for d in devices if d["device_id"] not in member_devices | escrowed]
        return {"policy": int(org["policy"].get("recovery_admins", 1)), "required": required,
                "holders": sorted(holders), "missing": missing, "ok": len(holders) >= required}

    def store_escrow(self, space: dict, epoch: int, wraps: object) -> int:
        """Escrow wraps for `epoch`: each for an active admin device of the space's organization (not one that
        gets a member wrap), shaped like a sealed wrap."""
        if wraps is None:
            return 0
        _need(space["owner_kind"] == "org", "bad_field", "escrow is for organization spaces")
        _need(isinstance(wraps, list) and len(wraps) <= 64, "bad_field", "escrow_wraps is a list")
        devices = {d["device_id"]: d for d in self.escrow_devices(space["org_id"])}
        n = 0
        seen = set()
        for w in wraps:
            _need(isinstance(w, dict) and w.get("epoch") == epoch, "bad_wraps", f"every escrow wrap is for epoch {epoch}")
            dev = devices.get(w.get("device_id"))
            if dev is None:
                raise SpaceError(422, "bad_wraps", "escrow wraps go to the organization's admin devices",
                                 device_id=w.get("device_id") if sc.is_uuid(w.get("device_id")) else None)
            _need(w["device_id"] not in seen, "bad_wraps", "one escrow wrap per device")
            seen.add(w["device_id"])
            problem = sc.wrap_problem(w.get("wrap"))
            _need(problem is None, "not_ciphertext", f"escrow wrap: {problem}")
            self.x("INSERT OR REPLACE INTO escrow_wraps VALUES (?,?,?,?,?)",
                   (space["space_id"], epoch, w["device_id"], dev["member_id"], w["wrap"]))
            n += 1
        return n

    def check_escrow(self, space: dict, epoch: int) -> None:
        """A new key of an org space must be openable by the org's recovery_admins admins (V7-S7)."""
        if space["owner_kind"] != "org":
            return
        status = self.escrow_status({**space, "epoch": epoch})
        if not status["ok"]:
            raise SpaceError(409, "escrow_required", f"wrap the key to {status['required']} admins' devices",
                             required=status["required"], holders=status["holders"],
                             missing=[m["device_id"] for m in status["missing"]])

    def escrow_for(self, org_id: str, device_id: str) -> dict:
        """GET /v1/orgs/{org}/escrow: this admin device's escrow wraps of each org space's current key."""
        out = []
        for sp in self.all("SELECT space_id, epoch, rotation_pending FROM spaces WHERE org_id=? ORDER BY created_ts",
                           (org_id,)):
            w = self.one("SELECT wrap FROM escrow_wraps WHERE space_id=? AND epoch=? AND device_id=?",
                         (sp["space_id"], sp["epoch"], device_id))
            out.append({"space_id": sp["space_id"], "epoch": sp["epoch"], "wrap": w["wrap"] if w else None,
                        "rotation_pending": bool(sp["rotation_pending"])})
        return {"device_id": device_id, "spaces": out}

    def _recover(self, space_id: str, wire: dict, payload: dict, raw: bytes, det: dict) -> dict:
        """space.recover (v8 B5): an org admin whose own org device holds the escrow wrap of the current key takes
        the space over as an admin, without any space member: the escrow wrap becomes the device's member wrap. The
        op is signed by that org device; members verify it against the organization's signed log
        (space_member.replay with the org roster). From there the usual ops apply (member.remove / device.remove with
        a new key for a lost admin, member.role)."""
        space = self.space(space_id)
        _need(space["owner_kind"] == "org", "bad_op", "space.recover is for organization spaces", 400)
        od = self.one("SELECT * FROM org_devices WHERE org_id=? AND device_id=?", (space["org_id"], payload["device_id"]))
        if od is None or od["member_id"] != payload["member_id"]:
            raise SpaceError(403, "unknown_device")
        if not sc.verify(sc.b64u_decode(od["sign_pub"]), sc.OP_DOMAIN + raw, wire.get("sig")):
            raise SpaceError(401, "bad_signature")
        self._refuse_unpaired(od["device_id"])
        if od["status"] != "active" or not self.is_org_admin(space["org_id"], od["member_id"]):
            raise SpaceError(403, "forbidden", "org admins only")
        dev = _device_record(payload["body"].get("device"))
        _need(dev == {"device_id": od["device_id"], "sign_pub": od["sign_pub"], "seal_pub": od["seal_pub"]},
              "bad_field", "space.recover names the signing org device's own keys")
        esc = self.one("SELECT wrap FROM escrow_wraps WHERE space_id=? AND epoch=? AND device_id=?",
                       (space_id, space["epoch"], od["device_id"]))
        _need(esc is not None, "no_escrow", "this device holds no escrow wrap of the current key", 409)
        _need(not det, "bad_op", "space.recover carries no detached fields", 400)
        with self.tx():
            existing = self.one("SELECT * FROM ops WHERE space_id=? AND op_id=?", (space_id, payload["op_id"]))
            if existing:
                return self._duplicate(existing, raw)
            seq = self.one("SELECT head FROM spaces WHERE space_id=?", (space_id,))["head"] + 1
            member_id, now = od["member_id"], self.now()
            m = self.member(space_id, member_id)
            if m is None:
                self.x("INSERT INTO members(space_id, member_id, role, outside, status, joined_ts)"
                       " VALUES (?,?,'admin',0,'active',?)", (space_id, member_id, now))
            else:
                self.x("UPDATE members SET role='admin', status='active', ended_ts=NULL WHERE space_id=? AND member_id=?",
                       (space_id, member_id))
            if self.one("SELECT 1 FROM devices WHERE space_id=? AND device_id=?", (space_id, od["device_id"])):
                self.x("UPDATE devices SET status='active', member_id=? WHERE space_id=? AND device_id=?",
                       (member_id, space_id, od["device_id"]))
            else:
                self.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',?)",
                       (space_id, od["device_id"], member_id, od["sign_pub"], od["seal_pub"], seq))
            self.x("INSERT OR REPLACE INTO key_wraps VALUES (?,?,?,?)", (space_id, space["epoch"], od["device_id"],
                                                                         esc["wrap"]))
            result = self._log(space_id, payload, raw, wire["sig"], det, None,
                               {"member_id": member_id, "device_id": od["device_id"], "epoch": space["epoch"]})
            self.audit("space.recover", {"member_id": member_id, "epoch": space["epoch"]}, space_id=space_id,
                       org_id=space["org_id"], seq=result["seq"], member_id=member_id, device_id=od["device_id"])
        return result

    # ---- storage quota (v8 B6) ------------------------------------------------------------------------------

    def quota_bytes(self, space: dict) -> Optional[int]:
        """The per-member quota of one space: the policy's value, never above the Spark owner's ceiling
        (ORGANIZER_MEMBER_QUOTA_MB); a policy of 0 or none means the ceiling (review finding V8R-09)."""
        ceiling = int(self.member_quota_mb or 0)
        mb = space["policy"].get("member_quota_mb")
        mb = ceiling if not mb else (min(int(mb), ceiling) if ceiling else int(mb))
        return None if not mb else int(mb) * 1024 * 1024

    def total_usage(self, member_id: str) -> int:
        """What one member stores across every space of this Spark (V8R-09)."""
        blobs = self.one("SELECT COALESCE(SUM(b.size),0) AS n FROM blobs b JOIN devices d ON d.space_id=b.space_id AND"
                         " d.device_id=b.device_id WHERE d.member_id=? AND b.status!='deleted'", (member_id,))["n"]
        enc = self.one("SELECT COALESCE(SUM(LENGTH(enc)),0) AS n FROM ops WHERE member_id=? AND enc IS NOT NULL",
                       (member_id,))["n"]
        return int(blobs) + int(enc)

    def usage(self, space_id: str, member_id: str) -> int:
        """What one member stores in one space: their originals' ciphertext (pending and attached) and the
        encrypted fields of their ops that are still there."""
        blobs = self.one("SELECT COALESCE(SUM(b.size),0) AS n FROM blobs b JOIN devices d ON d.space_id=b.space_id AND"
                         " d.device_id=b.device_id WHERE b.space_id=? AND d.member_id=? AND b.status!='deleted'",
                         (space_id, member_id))["n"]
        enc = self.one("SELECT COALESCE(SUM(LENGTH(enc)),0) AS n FROM ops WHERE space_id=? AND member_id=? AND"
                       " enc IS NOT NULL", (space_id, member_id))["n"]
        return int(blobs) + int(enc)

    def check_quota(self, space: dict, member_id: str, adding: int) -> None:
        quota = self.quota_bytes(space)
        if quota is not None:
            used = self.usage(space["space_id"], member_id)
            if used + adding > quota:
                raise SpaceError(413, "quota_exceeded", "this member's storage in the space is full",
                                 used_bytes=used, quota_bytes=quota, adding_bytes=adding)
        if self.member_total_mb and adding > 0:
            total, limit = self.total_usage(member_id), int(self.member_total_mb) * 1024 * 1024
            if total + adding > limit:
                raise SpaceError(413, "quota_exceeded", "this member's storage on this Spark is full",
                                 used_bytes=total, quota_bytes=limit, adding_bytes=adding, scope="spark")

    def org_summary(self, org_id: str) -> dict:
        org = self.org(org_id)
        admins = self.all("SELECT member_id, status, since_ts FROM org_admins WHERE org_id=? ORDER BY since_ts",
                          (org_id,))
        devices = self.all("SELECT device_id, member_id, sign_pub, seal_pub, status FROM org_devices WHERE org_id=?",
                           (org_id,))
        spaces = [r["space_id"] for r in self.all("SELECT space_id FROM spaces WHERE org_id=? ORDER BY created_ts",
                                                   (org_id,))]
        former = self.all(
            "SELECT m.space_id, m.member_id FROM members m JOIN spaces s ON s.space_id=m.space_id JOIN org_admins oa"
            " ON oa.org_id=s.org_id AND oa.member_id=m.member_id WHERE s.org_id=? AND oa.status='removed' AND"
            " m.status='active' AND m.role='admin' ORDER BY m.space_id", (org_id,))
        return {"org_id": org_id, "policy": org["policy"], "head": org["head"],
                "admins": [{"member_id": a["member_id"], "status": a["status"], "since": iso(a["since_ts"])}
                           for a in admins],
                "devices": devices, "spaces": spaces, "former_admins": former,
                "escrow": {sid: self.escrow_status(self.space(sid)) for sid in spaces},
                "ops": [{"seq": r["seq"], "type": r["type"], "op": sc.b64u(r["op"]), "sig": r["sig"], "enc": r["enc"]}
                        for r in self.all("SELECT * FROM org_ops WHERE org_id=? ORDER BY seq", (org_id,))]}

    def admin_scope(self, member_id: str, device_id: str) -> dict:
        """What a member's Mac administers on this Spark (v8 access routes, admin console): the organizations where
        this member is an active admin with this device as an active org device, the spaces where this device is an
        active admin device, and every member id of those organizations' spaces, admins and of those spaces."""
        orgs = [r["org_id"] for r in self.all(
            "SELECT oa.org_id FROM org_admins oa JOIN org_devices od ON od.org_id=oa.org_id AND od.member_id=oa.member_id"
            " WHERE oa.member_id=? AND oa.status='active' AND od.device_id=? AND od.status='active' ORDER BY oa.org_id",
            (member_id, device_id))]
        spaces = []
        for r in self.all("SELECT d.space_id FROM devices d JOIN members m ON m.space_id=d.space_id AND"
                          " m.member_id=d.member_id WHERE d.member_id=? AND d.device_id=? AND d.status='active' AND"
                          " m.status='active' ORDER BY d.space_id", (member_id, device_id)):
            space = self.space(r["space_id"])
            dev = self.one("SELECT * FROM devices WHERE space_id=? AND device_id=?", (r["space_id"], device_id))
            if self.effective_role(space, self.member(r["space_id"], member_id), dev) == ROLES["admin"]:
                spaces.append(r["space_id"])
        members: set[str] = set()
        for org_id in orgs:
            members |= {x["member_id"] for x in self.all("SELECT member_id FROM org_admins WHERE org_id=?", (org_id,))}
            members |= {x["member_id"] for x in self.all(
                "SELECT m.member_id FROM members m JOIN spaces s ON s.space_id=m.space_id WHERE s.org_id=?", (org_id,))}
        org_members = set(members)
        for space_id in spaces:
            members |= {x["member_id"] for x in self.all("SELECT member_id FROM members WHERE space_id=?", (space_id,))}
        # V8R-06: what reaches across the whole Spark (unpairing someone's Mac, their access records and audit, new
        # people, the Spark's health) is for org admins over their organizations' people; administering a space
        # one made oneself gives none of it (any teammate may make a space).
        return {"orgs": orgs, "spaces": spaces, "members": members, "org_members": org_members,
                "may_invite": bool(orgs)}

    def member_devices(self, member_id: str) -> dict:
        """v8 (one member, several Macs; the admin console): every device of a member in this Spark's spaces and
        organizations with its state there, the spaces the member is in and the organizations it administers."""
        devices: dict[str, dict] = {}

        def entry(r: dict) -> dict:
            return devices.setdefault(r["device_id"], {"device_id": r["device_id"], "sign_pub": r["sign_pub"],
                                                       "seal_pub": r["seal_pub"], "spaces": [], "orgs": []})
        for r in self.all("SELECT space_id, device_id, sign_pub, seal_pub, status FROM devices WHERE member_id=?"
                          " ORDER BY space_id", (member_id,)):
            entry(r)["spaces"].append({"space_id": r["space_id"], "status": r["status"]})
        for r in self.all("SELECT org_id, device_id, sign_pub, seal_pub, status FROM org_devices WHERE member_id=?"
                          " ORDER BY org_id", (member_id,)):
            entry(r)["orgs"].append({"org_id": r["org_id"], "status": r["status"]})
        spaces = [r["space_id"] for r in self.all("SELECT space_id FROM members WHERE member_id=? AND status='active'"
                                                  " ORDER BY space_id", (member_id,))]
        orgs = [r["org_id"] for r in self.all("SELECT org_id FROM org_admins WHERE member_id=? AND status='active'"
                                              " ORDER BY org_id", (member_id,))]
        return {"devices": devices, "spaces": spaces, "orgs": orgs}

    # ---- spaces: genesis ---------------------------------------------------------------------------

    def create_space(self, wire: object) -> dict:
        """space.create: the creator's device signs with the key the op itself registers (the log's root)."""
        payload, raw, det = parse_wire(wire)
        _need(payload["type"] == "space.create", "bad_op", "POST /v1/spaces takes a space.create op", 400)
        body = payload["body"]
        device = _device_record(body.get("device"))
        _need(device["device_id"] == payload["device_id"], "bad_field", "device.device_id must sign the op")
        if not sc.verify(sc.b64u_decode(device["sign_pub"]), sc.OP_DOMAIN + raw, wire.get("sig")):
            raise SpaceError(401, "bad_signature")
        space_id, member_id = payload["space_id"], payload["member_id"]
        owner = body.get("owner")
        _need(isinstance(owner, dict) and owner.get("kind") in ("person", "org"), "bad_field",
              "owner.kind is person or org")
        _need(payload.get("epoch") == 1, "bad_field", "a space starts at epoch 1")
        with self.tx():
            existing = self.one("SELECT * FROM ops WHERE space_id=? AND op_id=?", (space_id, payload["op_id"]))
            if existing:
                return self._duplicate(existing, raw)
            if self.one("SELECT 1 FROM spaces WHERE space_id=?", (space_id,)):
                raise SpaceError(409, "space_exists")
            # V8R-09: one member id makes at most so many spaces here (each is storage on the owner's disk)
            made = self.one("SELECT COUNT(*) AS n FROM ops WHERE seq=1 AND type='space.create' AND member_id=?",
                            (member_id,))["n"]
            if self.max_spaces_per_member and made >= self.max_spaces_per_member:
                raise SpaceError(409, "too_many_spaces", f"at most {self.max_spaces_per_member} spaces per member here")
            org_id = None
            if owner["kind"] == "org":
                org_id = _uuid_field(owner, "org_id")
                self.org(org_id)
                od = self.one("SELECT * FROM org_devices WHERE org_id=? AND device_id=? AND status='active'",
                              (org_id, device["device_id"]))
                if not self.is_org_admin(org_id, member_id) or od is None or od["sign_pub"] != device["sign_pub"]:
                    raise SpaceError(403, "forbidden", "only an org admin's device creates an org space")
            self._check_device_binding(device, member_id)
            policy = self._policy(owner["kind"], body.get("policy") or {}, None)
            wraps = self._wraps(body.get("wraps"), space_id, 1, [device["device_id"]])
            now = self.now()
            self.x("INSERT INTO spaces(space_id, owner_kind, owner_member, org_id, policy, epoch, created_ts, head)"
                   " VALUES (?,?,?,?,?,1,?,0)",
                   (space_id, owner["kind"], member_id if owner["kind"] == "person" else None, org_id,
                    _dumps(policy), now))
            self.x("INSERT INTO members(space_id, member_id, role, outside, status, joined_ts)"
                   " VALUES (?,?,'admin',0,'active',?)", (space_id, member_id, now))
            self.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',1)",
                   (space_id, device["device_id"], member_id, device["sign_pub"], device["seal_pub"]))
            for w in wraps:
                self.x("INSERT INTO key_wraps VALUES (?,?,?,?)", (space_id, 1, w["device_id"], w["wrap"]))
            if owner["kind"] == "org":
                created = self.space(space_id)
                self.store_escrow(created, 1, _escrow_list(body.get("escrow_wraps"), {device["device_id"]}))
                self.check_escrow(created, 1)
            self.space_dir(space_id).mkdir(mode=0o700, exist_ok=True)
            result = self._log(space_id, payload, raw, wire["sig"], det, subject=None,
                               effects={"space_id": space_id, "epoch": 1})
            self.audit("space.create", {"owner_kind": owner["kind"], "org_id": org_id}, space_id=space_id,
                       org_id=org_id, seq=result["seq"], member_id=member_id, device_id=device["device_id"])
        return result

    def _policy(self, owner_kind: str, given: dict, current: Optional[dict]) -> dict:
        _need(isinstance(given, dict), "bad_field", "policy must be an object")
        policy = dict(current or DEFAULT_POLICY[owner_kind])
        for key, value in given.items():
            if key == "withdraw_window_h":
                _need(value is None or (isinstance(value, int) and 1 <= value <= 720), "bad_field",
                      "withdraw_window_h is 1-720 hours or null")
                _need(value is not None or owner_kind == "person", "bad_field",
                      "an org space has a withdraw window (contributions are org assets)")
            elif key == "takedown_window_h":
                _need(isinstance(value, int) and 1 <= value <= 720, "bad_field", "takedown_window_h is 1-720")
            elif key == "forks_allowed":
                _need(isinstance(value, bool), "bad_field", "forks_allowed is a boolean")
            elif key == "originals":
                _need(value in ("members", "text_only"), "bad_field", "originals is members or text_only")
            elif key == "segment_audio":
                _need(isinstance(value, bool), "bad_field", "segment_audio is a boolean (meeting audio parts allowed)")
            elif key == "member_quota_mb":
                _need(value is None or (isinstance(value, int) and 0 <= value <= 1_000_000), "bad_field",
                      "member_quota_mb is 0-1000000 (0 or null: the Spark's ceiling; a value above it counts as it)")
            elif key == "on_leave":
                _need(value in ("keep", "contributor_choice"), "bad_field", "on_leave is keep or contributor_choice")
                _need(value == "keep" or owner_kind == "person", "bad_field", "org spaces keep contributions")
            else:
                raise SpaceError(422, "bad_field", f"unknown policy field {key}")
            policy[key] = value
        return policy

    def _wraps(self, wraps: object, space_id: str, epoch: int, device_ids: list[str]) -> list[dict]:
        """Exactly one wrap per listed device at `epoch` (no more, no fewer), each shaped like a sealed wrap."""
        _need(isinstance(wraps, list), "bad_field", "wraps must be a list")
        seen: dict[str, str] = {}
        for w in wraps:
            _need(isinstance(w, dict) and w.get("epoch") == epoch, "bad_wraps", f"every wrap is for epoch {epoch}")
            _need(sc.is_uuid(w.get("device_id")), "bad_wraps", "wrap device_id must be a lowercase UUID")
            problem = sc.wrap_problem(w.get("wrap"))
            _need(problem is None, "not_ciphertext", f"wrap: {problem}")
            _need(w["device_id"] not in seen, "bad_wraps", "one wrap per device")
            seen[w["device_id"]] = w["wrap"]
        missing = sorted(set(device_ids) - set(seen))
        extra = sorted(set(seen) - set(device_ids))
        if missing or extra:
            raise SpaceError(422, "bad_wraps", "wraps must cover exactly the space's active devices",
                             missing=missing, unexpected=extra)
        return [{"device_id": d, "wrap": seen[d]} for d in device_ids]

    # ---- the op log ---------------------------------------------------------------------------------

    def _duplicate(self, existing: dict, raw: bytes) -> dict:
        if bytes(existing["op"]) != raw:
            raise SpaceError(409, "op_id_conflict", "this op_id was used for another op")
        result = json.loads(existing["result"]) if existing.get("result") else {}
        return {"ok": True, "op_id": existing["op_id"], "duplicate": True, "seq": existing["seq"], **result}

    def _log(self, space_id: str, payload: dict, raw: bytes, sig: Optional[str], det: dict,
             subject: Optional[str], effects: dict) -> dict:
        seq = self.one("SELECT head FROM spaces WHERE space_id=?", (space_id,))["head"] + 1
        self.x("UPDATE spaces SET head=? WHERE space_id=?", (seq, space_id))
        result = {"effects": effects}
        self.x("INSERT INTO ops(space_id, seq, op_id, type, member_id, device_id, op, sig, enc, applied_ts, subject,"
               " result) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
               (space_id, seq, payload["op_id"], payload["type"], payload.get("member_id"), payload.get("device_id"),
                raw, sig, det.get("enc"), self.now(), subject, _dumps(result)))
        return {"ok": True, "op_id": payload["op_id"], "duplicate": False, "seq": seq, **result}

    def _system_record(self, space_id: str, type_: str, body: dict, subject: Optional[str]) -> int:
        """A record the Spark itself writes (an overdue privacy takedown carried out). Unsigned: members accept
        system records only when they remove something, never when they add."""
        op_id = str(uuid.uuid4())
        payload = {"v": 1, "space_id": space_id, "op_id": op_id, "type": type_, "member_id": None,
                   "device_id": None, "created_at": iso(self.now()), "body": body}
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        return self._log(space_id, payload, raw, None, {}, subject, {})["seq"]

    def apply_ops(self, space_id: str, wires: object) -> dict:
        _need(isinstance(wires, list) and 0 < len(wires) <= MAX_OPS_PER_POST, "bad_ops",
              f"ops is a list of 1-{MAX_OPS_PER_POST}", 400)
        self.space(space_id)
        self.sweep(space_id)
        results = []
        for wire in wires:
            try:
                results.append(self._apply(space_id, wire))
            except SpaceError as exc:
                # v8 C3: what the Mac's outbox does with it (RETRY)
                results.append({"ok": False, "status": exc.status, **exc.body(), "op_id": _op_id_of(wire),
                                "retry": RETRY.get(exc.code, "never")})
        return {"results": results, "head": self.one("SELECT head FROM spaces WHERE space_id=?", (space_id,))["head"]}

    def _apply(self, space_id: str, wire: object) -> dict:
        payload, raw, det = parse_wire(wire)
        _need(payload["space_id"] == space_id, "wrong_space", "the op names another space", 400)
        if payload["type"] == "space.recover":
            return self._recover(space_id, wire, payload, raw, det)
        handler = HANDLERS.get(payload["type"])
        if handler is None:
            raise SpaceError(400, "unknown_type", payload["type"])
        purges: list[str] = []
        with self.tx():
            existing = self.one("SELECT * FROM ops WHERE space_id=? AND op_id=?", (space_id, payload["op_id"]))
            if existing:
                return self._duplicate(existing, raw)
            dev = self.one("SELECT * FROM devices WHERE space_id=? AND device_id=?", (space_id, payload["device_id"]))
            if dev is None or dev["member_id"] != payload["member_id"]:
                raise SpaceError(403, "unknown_device")
            if not sc.verify(sc.b64u_decode(dev["sign_pub"]), sc.OP_DOMAIN + raw, wire.get("sig")):
                raise SpaceError(401, "bad_signature")
            self._refuse_unpaired(dev["device_id"])
            space = self.space(space_id)
            member = self.member(space_id, payload["member_id"])
            if dev["status"] != "active" or member is None or member["status"] != "active":
                raise SpaceError(403, "not_member")
            ctx = OpContext(self, space, member, dev, payload, det, self.effective_role(space, member, dev), purges)
            if space["archived"] and payload["type"] in ARCHIVE_BLOCKED:
                raise SpaceError(403, "archived", "the space is archived (read-only)")
            out = handler(ctx)
            if isinstance(out, _Already):
                result = {"op_id": payload["op_id"], **out.result}
            else:
                subject, effects, target = out
                result = self._log(space_id, payload, raw, wire["sig"], det, subject, effects)
                self.audit(payload["type"], target, space_id=space_id, org_id=space["org_id"], seq=result["seq"],
                           member_id=member["member_id"], device_id=dev["device_id"])
                # v8 C2: snapshots that cite what this op withdrew or removed go too (each a system record)
                self.cascade_snapshots(space_id, purges)
        for blob_id in ctx.dead_blobs:  # a replaced revision's blobs, after the commit
            _unlink(self.blob_path(space_id, blob_id))
        if ctx.rotated and self.on_rotate is not None:
            # The old epoch's key is known to whoever left: the organizer store closes now, and the next lease
            # (with the new epoch's store key and the previous one) re-keys it.
            self.on_rotate(space_id)
        self._run_purges(space_id, purges)
        return result

    def checkpoint(self) -> None:
        """Copy the WAL into the database and truncate it: with secure_delete, a purged row's old bytes are then
        gone from both files (the file system may still keep freed blocks; they hold ciphertext only)."""
        with self._lock:
            try:
                self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            except db.DatabaseError:
                pass

    def _run_purges(self, space_id: str, item_ids: list[str]) -> None:
        """After the transaction: blob files go, and the space organizer purges the items (queued while locked)."""
        if item_ids:
            self.checkpoint()
        for item_id in item_ids:
            for b in self.all("SELECT blob_id FROM blobs WHERE space_id=? AND item_id=? AND status='deleted'",
                              (space_id, item_id)):
                _unlink(self.blob_path(space_id, b["blob_id"]))
            if self.on_purge is not None:
                try:
                    self.on_purge(space_id, item_id)
                except Exception as exc:  # the queue row stays; the next lease applies it
                    log.warning("organizer purge deferred: %s", type(exc).__name__)

    # ---- tombstone + purge -------------------------------------------------------------------------

    def purge_item(self, space_id: str, item_id: str, status: str, by: Optional[str], reason: str, seq: int,
                   purges: list[str]) -> None:
        """Withdraw or remove: the item's wrapped data key goes (every copy of its ciphertext is dead), its blobs
        and every encrypted field of its share ops are deleted, and a content-free tombstone stays (contributor,
        kind, times) so attribution survives. The organizer purge runs after the transaction."""
        self.x("UPDATE items SET status=?, ended_seq=?, ended_by=?, ended_reason=? WHERE space_id=? AND item_id=?",
               (status, seq, by, reason, space_id, item_id))
        self.x("DELETE FROM item_keys WHERE space_id=? AND item_id=?", (space_id, item_id))
        self.x("UPDATE ops SET enc=NULL, purged=1 WHERE space_id=? AND subject=? AND type='item.share'",
               (space_id, item_id))
        self.x("UPDATE blobs SET status='deleted' WHERE space_id=? AND item_id=?", (space_id, item_id))
        self.x("DELETE FROM snapshot_cites WHERE space_id=? AND snapshot_id=?", (space_id, item_id))
        self.x("UPDATE takedowns SET status=CASE WHEN status='open' THEN 'done' ELSE status END, resolved_seq="
               "COALESCE(resolved_seq, ?) WHERE space_id=? AND item_id=?", (seq, space_id, item_id))
        self.x("INSERT OR REPLACE INTO organizer_purges(space_id, item_id, queued_ts) VALUES (?,?,?)",
               (space_id, item_id, self.now()))
        purges.append(item_id)

    def cascade_snapshots(self, space_id: str, purges: list[str]) -> int:
        """v8 C2: a snapshot that cites an item of this space which was just withdrawn or removed is removed too, by
        a system record (reason cited_item_gone): a withdraw also takes back the quotes of it in others' frozen
        summaries, as it does for the handover packs. Runs inside the caller's transaction, after its own op is
        logged; `purges` grows with the snapshots (and snapshots of snapshots)."""
        n, i = 0, 0
        while i < len(purges):
            gone = purges[i]
            i += 1
            for r in self.all("SELECT c.snapshot_id FROM snapshot_cites c JOIN items s ON s.space_id=c.space_id AND"
                              " s.item_id=c.snapshot_id WHERE c.space_id=? AND c.item_id=? AND s.status='active'"
                              " ORDER BY c.snapshot_id", (space_id, gone)):
                body = {"item_id": r["snapshot_id"], "reason": "cited_item_gone", "cited_item_id": gone}
                seq = self._system_record(space_id, "system.remove", body, r["snapshot_id"])
                self.purge_item(space_id, r["snapshot_id"], "removed", None, "cited_item_gone", seq, purges)
                self.audit("system.remove", body, space_id=space_id, seq=seq)
                n += 1
        return n

    # ---- sweep: overdue privacy takedowns, stale uploads ---------------------------------------------

    def sweep(self, space_id: Optional[str] = None) -> dict:
        """A privacy takedown not handled within the policy's window is carried out by the Spark (system
        record + tombstone + purge); uploaded blobs never attached to an item within a day are deleted."""
        now = self.now()
        done = {"takedowns": 0, "blobs": 0}
        where, args = ("AND space_id=?", (space_id,)) if space_id else ("", ())
        due = self.all("SELECT * FROM takedowns WHERE status='open' AND kind='privacy' AND due_ts <= ? " + where,
                       (now, *args))
        for t in due:
            purges: list[str] = []
            with self.tx():
                row = self.one("SELECT status FROM takedowns WHERE space_id=? AND takedown_id=?",
                               (t["space_id"], t["takedown_id"]))
                item = self.one("SELECT status FROM items WHERE space_id=? AND item_id=?", (t["space_id"], t["item_id"]))
                if row is None or row["status"] != "open":
                    continue
                if item is None or item["status"] != "active":
                    self.x("UPDATE takedowns SET status='done' WHERE space_id=? AND takedown_id=?",
                           (t["space_id"], t["takedown_id"]))
                    continue
                seq = self._system_record(t["space_id"], "system.remove",
                                          {"item_id": t["item_id"], "reason": "takedown_overdue",
                                           "takedown_id": t["takedown_id"]}, t["item_id"])
                self.purge_item(t["space_id"], t["item_id"], "removed", None, "takedown_overdue", seq, purges)
                self.x("UPDATE takedowns SET status='done', resolved_seq=? WHERE space_id=? AND takedown_id=?",
                       (seq, t["space_id"], t["takedown_id"]))
                self.audit("system.remove", {"item_id": t["item_id"], "takedown_id": t["takedown_id"],
                                             "reason": "takedown_overdue"}, space_id=t["space_id"], seq=seq)
                self.cascade_snapshots(t["space_id"], purges)
            self._run_purges(t["space_id"], purges)
            done["takedowns"] += 1
        stale = self.all("SELECT space_id, blob_id FROM blobs WHERE status='pending' AND created_ts < ? " + where,
                         (now - PENDING_BLOB_TTL_S, *args))
        for b in stale:
            with self.tx():
                self.x("UPDATE blobs SET status='deleted' WHERE space_id=? AND blob_id=? AND status='pending'",
                       (b["space_id"], b["blob_id"]))
            _unlink(self.blob_path(b["space_id"], b["blob_id"]))
            done["blobs"] += 1
        return done

    # ---- joining ---------------------------------------------------------------------------------------

    def join(self, space_id: str, wire: object) -> dict:
        """A join request from a device holding an invite code: signed by the device key it registers. The
        invite's one-time secret never reaches the Spark (review finding V7-S9): beside the signed request come
        the gate token derived from it (checked against the invite's stored hash; the invite is used up) and an
        HMAC of the request bytes under another key derived from the secret, which the Spark stores and the
        inviting admin's Mac checks before it approves. The Spark cannot make that HMAC, so it cannot bind a device
        of its own to the invite."""
        _need(isinstance(wire, dict), "bad_request", "a join request is an object", 400)
        raw = sc.b64u_decode(wire.get("request"))
        _need(raw is not None and 0 < len(raw) <= 16 * 1024, "bad_request", "request must be base64url JSON", 400)
        try:
            req = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise SpaceError(400, "bad_request", "request is not UTF-8 JSON") from None
        _need(isinstance(req, dict) and req.get("v") == 1, "bad_request", "request v must be 1", 400)
        for key in ("space_id", "invite_id", "request_id", "member_id"):
            _need(sc.is_uuid(req.get(key)), "bad_request", f"{key} must be a lowercase UUID", 400)
        _need(req["space_id"] == space_id, "wrong_space", "the request names another space", 400)
        device = _device_record(req.get("device"))
        if not sc.verify(sc.b64u_decode(device["sign_pub"]), sc.JOIN_DOMAIN + raw, wire.get("sig")):
            raise SpaceError(401, "bad_signature")
        profile = wire.get("profile")
        if profile is not None:
            problem = sc.profile_problem(profile)
            _need(problem is None, "not_ciphertext", f"profile: {problem}")
        _need("invite_secret" not in wire, "bad_request", "send the invite gate, never the invite secret", 400)
        gate = sc.b64u_decode(wire.get("invite_gate"))
        _need(gate is not None and len(gate) == 32, "bad_request", "invite_gate must be 32 bytes base64url", 400)
        binding = wire.get("invite_binding")
        _need(isinstance(binding, str) and sc.HEX64_RE.match(binding) is not None, "bad_request",
              "invite_binding is 64 lowercase hex", 400)
        space = self.space(space_id)
        now = self.now()
        with self.tx():
            prior = self.one("SELECT * FROM join_requests WHERE space_id=? AND request_id=?", (space_id, req["request_id"]))
            if prior is not None:
                if bytes(prior["request"]) != raw:
                    raise SpaceError(409, "request_id_conflict")
                return {"ok": True, "duplicate": True, "request_id": prior["request_id"], "status": prior["status"]}
            inv = self.one("SELECT * FROM invites WHERE space_id=? AND invite_id=?", (space_id, req["invite_id"]))
            if inv is None:
                raise SpaceError(404, "unknown_invite")
            if inv["status"] == "revoked":
                raise SpaceError(410, "invite_revoked")
            if inv["status"] in ("used",):
                raise SpaceError(410, "invite_used")
            if inv["status"] == "locked":
                raise SpaceError(410, "invite_locked")
            if inv["expires_ts"] <= now:
                raise SpaceError(410, "invite_expired")
            bad_secret = not _consteq(sc.invite_gate_hash(gate), inv["secret_hash"])
            if bad_secret:
                # counted (and committed) before the refusal; the invite locks after INVITE_MAX_FAILURES
                failures = inv["failures"] + 1
                self.x("UPDATE invites SET failures=?, status=CASE WHEN ? >= ? THEN 'locked' ELSE status END"
                       " WHERE space_id=? AND invite_id=?",
                       (failures, failures, INVITE_MAX_FAILURES, space_id, inv["invite_id"]))
                self.audit("join.refused", {"invite_id": inv["invite_id"], "reason": "bad_invite_secret"},
                           space_id=space_id, device_id=device["device_id"])
        if bad_secret:
            raise SpaceError(403, "bad_invite_secret")
        with self.tx():
            inv = self.one("SELECT * FROM invites WHERE space_id=? AND invite_id=?", (space_id, req["invite_id"]))
            if inv["status"] != "open":  # taken, revoked or locked since the check above
                raise SpaceError(410, "invite_" + inv["status"])
            if space["archived"]:
                raise SpaceError(403, "archived")
            self._check_device_binding(device, req["member_id"])
            member = self.member(space_id, req["member_id"])
            if self.one("SELECT 1 FROM devices WHERE space_id=? AND device_id=?", (space_id, device["device_id"])):
                raise SpaceError(409, "already_member")
            if member is not None and member["status"] == "removed":
                raise SpaceError(403, "removed_member", "a removed member needs a new member id")
            if member is not None and member["status"] == "active":
                # A member's further device is added by one of the member's own devices (device.add), never by
                # an invite: an invite holder cannot claim someone else's member id and role.
                raise SpaceError(409, "member_exists", "add a device with device.add from an existing device")
            # A member id is bound to the keys of the devices that used it first, across the whole Spark: an
            # invite holder cannot take one another space or the organization knows (an org admin's, which every
            # member of an org space can see), whatever the invite's role (review finding V7-S2).
            bound = self._member_id_keys(req["member_id"], space_id)
            if (bound or self._member_id_known(req["member_id"])) and device["sign_pub"] not in bound:
                self.audit("join.refused", {"invite_id": inv["invite_id"], "reason": "member_id_taken"},
                           space_id=space_id, device_id=device["device_id"])
                raise SpaceError(409, "member_id_taken", "this member id belongs to another device on this Spark")
            self.x("UPDATE invites SET status='used', request_id=? WHERE space_id=? AND invite_id=?",
                   (req["request_id"], space_id, inv["invite_id"]))
            self.x("INSERT INTO join_requests(space_id, request_id, invite_id, member_id, device_id, sign_pub,"
                   " seal_pub, profile, request, sig, status, created_ts, resolved_seq, binding)"
                   " VALUES (?,?,?,?,?,?,?,?,?,?,'pending',?,NULL,?)",
                   (space_id, req["request_id"], inv["invite_id"], req["member_id"], device["device_id"],
                    device["sign_pub"], device["seal_pub"], profile, raw, wire["sig"], now, binding))
            self.audit("join.request", {"invite_id": inv["invite_id"], "request_id": req["request_id"],
                                        "member_id": req["member_id"]}, space_id=space_id,
                       member_id=req["member_id"], device_id=device["device_id"])
        return {"ok": True, "duplicate": False, "request_id": req["request_id"], "status": "pending"}

    def join_status(self, space_id: str, request_id: str, method: str, target: str, headers: dict,
                    body: bytes) -> dict:
        """The joining device polls its own request (signed with the key it registered)."""
        self.space(space_id)
        row = self.one("SELECT * FROM join_requests WHERE space_id=? AND request_id=?", (space_id, request_id)) \
            if sc.is_uuid(request_id) else None
        if row is None or headers.get("device") != row["device_id"]:
            raise SpaceError(404, "unknown_request")
        self._check_request(row["device_id"], row["sign_pub"], method, target, headers, body)
        out = {"request_id": request_id, "status": row["status"], "member_id": row["member_id"]}
        if row["status"] == "approved":
            m = self.member(space_id, row["member_id"])
            out["role"] = m["role"] if m else None
            out["epoch"] = self.space(space_id)["epoch"]
        return out

    # ---- reads ------------------------------------------------------------------------------------------

    def list_for_device(self, device_id: str) -> tuple[list[dict], list[dict], list[dict]]:
        out = []
        for d in self.all("SELECT space_id, member_id, device_id, sign_pub, status FROM devices WHERE device_id=?",
                          (device_id,)):
            space = self.space(d["space_id"])
            member = self.member(d["space_id"], d["member_id"])
            out.append({"space_id": d["space_id"], "owner_kind": space["owner_kind"], "org_id": space["org_id"],
                        "member_id": d["member_id"], "status": member["status"] if d["status"] == "active" else "removed",
                        "role": ROLE_NAMES.get(self.effective_role(space, member, d)) if member else None,
                        "epoch": space["epoch"], "archived": bool(space["archived"]), "head": space["head"]})
        orgs = [{"org_id": r["org_id"], "member_id": r["member_id"],
                 "admin": self.is_org_admin(r["org_id"], r["member_id"])}
                for r in self.all("SELECT org_id, member_id FROM org_devices WHERE device_id=? AND status='active'",
                                  (device_id,))]
        pending = [{"space_id": r["space_id"], "request_id": r["request_id"], "status": r["status"]}
                   for r in self.all("SELECT space_id, request_id, status FROM join_requests WHERE device_id=?"
                                     " AND status='pending'", (device_id,))]
        return out, orgs, pending

    def rights(self, space: dict, role: int) -> list[str]:
        r = ["read", "hide", "leave", "agent_access", "profile", "takedown_privacy"]
        if space["policy"].get("forks_allowed"):
            r.append("fork")
        if role >= ROLES["write"]:
            r += ["share", "withdraw_own", "propose", "lease_write", "rewrap"]
        if role >= ROLES["maintain"]:
            r += ["remove", "resolve_takedowns", "resolve_proposals", "edit_matters", "handover"]
        if role >= ROLES["admin"]:
            r += ["invite", "approve_joins", "set_roles", "remove_members", "rotate", "policy", "archive"]
        return r

    def summary(self, actor: Actor) -> dict:
        space = self.space(actor.space_id)
        sid = actor.space_id
        members = []
        for m in self.all("SELECT * FROM members WHERE space_id=? ORDER BY joined_ts, member_id", (sid,)):
            devices = self.all("SELECT device_id, sign_pub, seal_pub, status FROM devices WHERE space_id=? AND"
                               " member_id=? ORDER BY added_seq", (sid, m["member_id"]))
            members.append({"member_id": m["member_id"], "role": m["role"],
                            "effective_role": ROLE_NAMES.get(self.effective_role(space, m)),
                            "outside": bool(m["outside"]), "status": m["status"],
                            "owner": space["owner_kind"] == "person" and m["member_id"] == space["owner_member"],
                            "org_admin": self.org_admin_here(space, m["member_id"]),
                            "joined_at": iso(m["joined_ts"]), "ended_at": iso(m["ended_ts"]), "devices": devices})
        counts = {
            "items": self.one("SELECT COUNT(*) AS n FROM items WHERE space_id=? AND status='active'", (sid,))["n"],
            "open_takedowns": self.one("SELECT COUNT(*) AS n FROM takedowns WHERE space_id=? AND status='open'",
                                       (sid,))["n"],
            "open_proposals": self.one("SELECT COUNT(*) AS n FROM proposals WHERE space_id=? AND status='open'",
                                       (sid,))["n"],
            "pending_joins": self.one("SELECT COUNT(*) AS n FROM join_requests WHERE space_id=? AND status='pending'",
                                      (sid,))["n"],
        }
        owner = {"kind": space["owner_kind"], "member_id": space["owner_member"]} if space["owner_kind"] == "person" \
            else {"kind": "org", "org_id": space["org_id"]}
        me = {"member_id": actor.member_id, "device_id": actor.device_id, "role": ROLE_NAMES[actor.role],
              "rights": self.rights(space, actor.role),
              "hidden": [r["item_id"] for r in self.all("SELECT item_id FROM hidden WHERE space_id=? AND member_id=?",
                                                        (sid, actor.member_id))],
              "forks": [r["item_id"] for r in self.all("SELECT item_id FROM forks WHERE space_id=? AND member_id=?",
                                                       (sid, actor.member_id))]}
        me["usage"] = {"bytes": self.usage(sid, actor.member_id), "quota_bytes": self.quota_bytes(space)}
        if actor.role >= ROLES["admin"]:
            for m in members:
                m["usage_bytes"] = self.usage(sid, m["member_id"])
        return {"space_id": sid, "owner": owner, "policy": space["policy"], "epoch": space["epoch"],
                "rotation_pending": bool(space["rotation_pending"]), "archived": bool(space["archived"]),
                "head": space["head"], "created_at": iso(space["created_ts"]), "members": members, "me": me,
                "counts": counts, "escrow": self.escrow_status(space), "limits": LIMITS}

    def ops_since(self, actor: Actor, since: int, limit: int) -> dict:
        rows = self.all("SELECT * FROM ops WHERE space_id=? AND seq > ? ORDER BY seq LIMIT ?",
                        (actor.space_id, since, limit + 1))
        more = len(rows) > limit
        rows = rows[:limit]
        keys = {r["item_id"]: r for r in self.all(
            "SELECT k.item_id, k.epoch, k.wrapped_dk, i.revision, i.share_seq FROM item_keys k JOIN items i"
            " ON i.space_id=k.space_id AND i.item_id=k.item_id WHERE k.space_id=? AND i.status='active'",
            (actor.space_id,))}
        out = []
        for r in rows:
            # "Hide for me" is private to the member who hid something.
            if r["type"] == "item.hide" and r["member_id"] != actor.member_id:
                continue
            entry = {"seq": r["seq"], "type": r["type"], "applied_at": iso(r["applied_ts"]), "op": sc.b64u(r["op"]),
                     "sig": r["sig"], "enc": r["enc"], "purged": bool(r["purged"])}
            if r["enc"] is not None and r["type"] in ("takedown.request", "takedown.resolve") \
                    and not self._may_read_takedown_text(actor, r):
                # The reason of a privacy takedown ("there is my illness in it") is for the person who asked and
                # the maintainers who decide, not for every member (review finding V7-S8). The op still verifies:
                # it commits to the withheld field by hash.
                entry["enc"] = None
                entry["withheld"] = True
            if r["type"] == "item.share":
                k = keys.get(r["subject"])
                entry["item_key"] = {"epoch": k["epoch"], "wrapped_dk": k["wrapped_dk"]} \
                    if k is not None and k["share_seq"] == r["seq"] else None
            out.append(entry)
        cursor = rows[-1]["seq"] if rows else since
        head = self.one("SELECT head FROM spaces WHERE space_id=?", (actor.space_id,))["head"]
        return {"ops": out, "cursor": cursor, "more": more, "head": head}

    def _may_read_takedown_text(self, actor: Actor, row: dict) -> bool:
        if actor.role >= ROLES["maintain"]:
            return True
        try:
            body = json.loads(bytes(row["op"]).decode("utf-8")).get("body") or {}
        except (UnicodeDecodeError, ValueError):
            return False
        t = self.one("SELECT kind, requester FROM takedowns WHERE space_id=? AND takedown_id=?",
                     (actor.space_id, body.get("takedown_id")))
        if t is None:
            return row["member_id"] == actor.member_id
        return t["kind"] != "privacy" or t["requester"] == actor.member_id

    def keys_for(self, actor: Actor) -> dict:
        space = self.space(actor.space_id)
        wraps = self.all("SELECT epoch, wrap FROM key_wraps WHERE space_id=? AND device_id=? ORDER BY epoch",
                         (actor.space_id, actor.device_id))
        links = self.all("SELECT epoch, prev_wrap FROM epoch_links WHERE space_id=? ORDER BY epoch", (actor.space_id,))
        return {"epoch": space["epoch"], "rotation_pending": bool(space["rotation_pending"]), "wraps": wraps,
                "epoch_links": links}

    def item_keys(self, actor: Actor, item_ids: list[str], stale: bool, limit: int) -> dict:
        space = self.space(actor.space_id)
        base = ("SELECT i.item_id, i.revision, k.epoch, k.wrapped_dk FROM items i JOIN item_keys k ON"
                " k.space_id=i.space_id AND k.item_id=i.item_id WHERE i.space_id=? AND i.status='active'")
        if stale:
            rows = self.all(base + " AND k.epoch < ? ORDER BY i.share_seq LIMIT ?",
                            (actor.space_id, space["epoch"], limit))
        else:
            ids = [_item_id(i) for i in item_ids][:200]
            rows = [r for r in (self.one(base + " AND i.item_id=?", (actor.space_id, i)) for i in ids) if r]
        return {"epoch": space["epoch"], "items": rows}

    def rewrap(self, actor: Actor, rewraps: object) -> dict:
        """Lazy re-wrap after a rotation (any contributor's Mac): an item's data key under the current epoch
        replaces its older wrap. Bookkeeping, not an action: audited as a count, not logged as an op."""
        _need(actor.role >= ROLES["write"], "forbidden", "needs role write", 403)
        _need(isinstance(rewraps, list) and 0 < len(rewraps) <= 500, "bad_field", "rewraps is a list of 1-500")
        space = self.space(actor.space_id)
        n = 0
        with self.tx():
            for w in rewraps:
                _need(isinstance(w, dict), "bad_field", "a rewrap is an object")
                item_id = _item_id(w.get("item_id"))
                _need(w.get("epoch") == space["epoch"], "stale_epoch", "rewraps are for the current epoch", 409)
                problem = sc.ikey_problem(w.get("wrapped_dk"))
                _need(problem is None, "not_ciphertext", f"wrapped_dk: {problem}")
                cur = self.one("SELECT k.epoch FROM item_keys k JOIN items i ON i.space_id=k.space_id AND"
                               " i.item_id=k.item_id WHERE k.space_id=? AND k.item_id=? AND i.status='active'",
                               (actor.space_id, item_id))
                if cur is None or cur["epoch"] >= space["epoch"]:
                    continue
                self.x("UPDATE item_keys SET epoch=?, wrapped_dk=? WHERE space_id=? AND item_id=?",
                       (space["epoch"], w["wrapped_dk"], actor.space_id, item_id))
                n += 1
            self.audit("item_keys.rewrap", {"count": n, "epoch": space["epoch"]}, space_id=actor.space_id,
                       member_id=actor.member_id, device_id=actor.device_id)
        return {"rewrapped": n, "epoch": space["epoch"]}

    # ---- blobs -------------------------------------------------------------------------------------------

    def put_blob(self, actor: Actor, blob_id: str, data: bytes) -> dict:
        """One original's ciphertext (made on the member's Mac with the item's data key). Pending until an
        item.share from the same device attaches it; unattached uploads are deleted after a day."""
        space = self.space(actor.space_id)
        _need(sc.is_uuid(blob_id), "bad_field", "blob_id must be a lowercase UUID", 400)
        _need(actor.role >= ROLES["write"], "forbidden", "needs role write", 403)
        _need(not space["archived"], "archived", "the space is archived (read-only)", 403)
        _need(space["policy"].get("originals") != "text_only", "originals_not_allowed",
              "this space keeps text only", 403)
        problem = sc.blob_problem(data)
        _need(problem is None, "not_ciphertext", f"blob: {problem}")
        digest = sc.sha256_hex(data)
        path = self.blob_path(actor.space_id, blob_id)
        with self.tx():
            row = self.one("SELECT * FROM blobs WHERE space_id=? AND blob_id=?", (actor.space_id, blob_id))
            again = False
            if row is not None:
                if row["sha256"] == digest and row["device_id"] == actor.device_id and row["status"] != "deleted":
                    return {"blob_id": blob_id, "size": row["size"], "sha256": digest, "duplicate": True}
                if row["status"] == "deleted" and row["item_id"] is not None:
                    # its item was withdrawn, removed or replaced: the outbox entry is over (v8 C3)
                    raise SpaceError(410, "blob_gone")
                # v8 C3: an upload the daily sweep dropped before its share arrived (the link was down) comes again
                # from the same Mac with the same bytes
                again = row["status"] == "deleted" and row["device_id"] == actor.device_id and row["sha256"] == digest
                if not again:
                    raise SpaceError(409, "blob_exists")
            self.check_quota(space, actor.member_id, len(data))
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if again:
                _unlink(path)
            _write_new(path, data)
            _fsync_dir(path.parent)  # v8 C3: an accepted upload survives a power cut
            if again:
                self.x("UPDATE blobs SET status='pending', created_ts=?, role=NULL WHERE space_id=? AND blob_id=?",
                       (self.now(), actor.space_id, blob_id))
            else:
                self.x("INSERT INTO blobs(space_id, blob_id, device_id, item_id, size, sha256, status, created_ts)"
                       " VALUES (?,?,?,NULL,?,?,'pending',?)",
                       (actor.space_id, blob_id, actor.device_id, len(data), digest, self.now()))
            self.audit("blob.put", {"blob_id": blob_id, "size": len(data)}, space_id=actor.space_id,
                       member_id=actor.member_id, device_id=actor.device_id)
        return {"blob_id": blob_id, "size": len(data), "sha256": digest, "duplicate": False}

    def get_blob(self, actor: Actor, blob_id: str) -> bytes:
        row = self.one("SELECT b.*, i.status AS item_status FROM blobs b LEFT JOIN items i ON i.space_id=b.space_id"
                       " AND i.item_id=b.item_id WHERE b.space_id=? AND b.blob_id=?", (actor.space_id, blob_id)) \
            if sc.is_uuid(blob_id) else None
        if row is None:
            raise SpaceError(404, "unknown_blob")
        if row["status"] == "deleted" or (row["item_id"] and row["item_status"] != "active"):
            raise SpaceError(410, "blob_gone")
        if row["status"] == "pending" and row["device_id"] != actor.device_id:
            raise SpaceError(404, "unknown_blob")
        try:
            return self.blob_path(actor.space_id, blob_id).read_bytes()
        except FileNotFoundError:
            raise SpaceError(410, "blob_gone") from None

    # ---- queues -----------------------------------------------------------------------------------------

    def join_requests(self, actor: Actor, status: Optional[str]) -> list[dict]:
        _need(actor.role >= ROLES["admin"], "forbidden", "admins only", 403)
        rows = self.all("SELECT * FROM join_requests WHERE space_id=? AND (? IS NULL OR status=?) ORDER BY created_ts",
                        (actor.space_id, status, status))
        out = []
        for r in rows:
            inv = self.one("SELECT role, outside FROM invites WHERE space_id=? AND invite_id=?",
                           (actor.space_id, r["invite_id"]))
            out.append({"request_id": r["request_id"], "invite_id": r["invite_id"], "member_id": r["member_id"],
                        "device": {"device_id": r["device_id"], "sign_pub": r["sign_pub"], "seal_pub": r["seal_pub"]},
                        "profile": r["profile"], "status": r["status"], "created_at": iso(r["created_ts"]),
                        "role": inv["role"] if inv else None, "outside": bool(inv["outside"]) if inv else False,
                        "request": sc.b64u(r["request"]), "sig": r["sig"], "binding": r.get("binding")})
        return out

    def invites(self, actor: Actor) -> list[dict]:
        _need(actor.role >= ROLES["admin"], "forbidden", "admins only", 403)
        now = self.now()
        out = []
        for r in self.all("SELECT * FROM invites WHERE space_id=? ORDER BY created_seq", (actor.space_id,)):
            status = "expired" if r["status"] == "open" and r["expires_ts"] <= now else r["status"]
            out.append({"invite_id": r["invite_id"], "role": r["role"], "outside": bool(r["outside"]),
                        "host_key": r["host_key"], "expires_at": iso(r["expires_ts"]), "status": status,
                        "request_id": r["request_id"]})
        return out

    def takedowns(self, actor: Actor, status: Optional[str]) -> list[dict]:
        now = self.now()
        rows = self.all("SELECT * FROM takedowns WHERE space_id=? AND (? IS NULL OR status=?) ORDER BY created_ts",
                        (actor.space_id, status, status))
        if actor.role < ROLES["maintain"]:
            rows = [r for r in rows if r["requester"] == actor.member_id]
        return [{"takedown_id": r["takedown_id"], "item_id": r["item_id"], "kind": r["kind"],
                 "requester": r["requester"], "status": r["status"], "created_at": iso(r["created_ts"]),
                 "due_at": iso(r["due_ts"]), "overdue": r["status"] == "open" and r["due_ts"] is not None
                 and r["due_ts"] <= now, "op_seq": r["op_seq"], "resolved_seq": r["resolved_seq"]} for r in rows]

    def proposals(self, actor: Actor, status: Optional[str]) -> list[dict]:
        rows = self.all("SELECT * FROM proposals WHERE space_id=? AND (? IS NULL OR status=?) ORDER BY op_seq",
                        (actor.space_id, status, status))
        return [{"proposal_id": r["proposal_id"], "author": r["author"], "kind": r["kind"],
                 "targets": json.loads(r["targets"]), "status": r["status"], "op_seq": r["op_seq"],
                 "resolved_seq": r["resolved_seq"], "resolved_by": r["resolved_by"]} for r in rows]

    def audit_log(self, *, space_id: Optional[str] = None, org_id: Optional[str] = None, since: int = 0,
                  limit: int = 200) -> dict:
        col, key = ("space_id", space_id) if space_id else ("org_id", org_id)
        rows = self.all(f"SELECT * FROM audit WHERE {col}=? AND id > ? ORDER BY id LIMIT ?", (key, since, limit))
        return {"records": [{"id": r["id"], "space_id": r["space_id"], "org_id": r["org_id"], "seq": r["seq"],
                             "at": r["at"], "actor_member": r["actor_member"], "actor_device": r["actor_device"],
                             "action": r["action"], "target": json.loads(r["target"])} for r in rows],
                "cursor": rows[-1]["id"] if rows else since}

    def has_audio(self, space_id: str, item_id: str, kind: Optional[str] = None) -> bool:
        """A meeting or imported-media item, or one that carries an audio part (v8 C1)."""
        if kind in AUDIO_KINDS:
            return True
        return self.one("SELECT 1 FROM segments WHERE space_id=? AND item_id=? AND audio=1",
                        (space_id, item_id)) is not None

    def active_items(self, space_id: str) -> list[dict]:
        return self.all("SELECT item_id, revision, contributor, kind, share_seq FROM items WHERE space_id=? AND"
                        " status='active' ORDER BY share_seq", (space_id,))

    def item(self, space_id: str, item_id: str) -> Optional[dict]:
        return self.one("SELECT * FROM items WHERE space_id=? AND item_id=?", (space_id, item_id))

    def queued_purges(self, space_id: str) -> list[str]:
        return [r["item_id"] for r in self.all("SELECT item_id FROM organizer_purges WHERE space_id=? ORDER BY"
                                               " queued_ts", (space_id,))]

    def purge_done(self, space_id: str, item_id: str) -> None:
        self.x("DELETE FROM organizer_purges WHERE space_id=? AND item_id=?", (space_id, item_id))

    def stats(self) -> dict:
        return {"spaces": self.one("SELECT COUNT(*) AS n FROM spaces")["n"],
                "orgs": self.one("SELECT COUNT(*) AS n FROM orgs")["n"],
                "blob_bytes": self.one("SELECT COALESCE(SUM(size),0) AS n FROM blobs WHERE status!='deleted'")["n"]}


# ---- op handlers ----------------------------------------------------------------------------------------


class OpContext:
    def __init__(self, spaces: Spaces, space: dict, member: dict, device: dict, payload: dict, det: dict,
                 role: int, purges: list[str]):
        self.s = spaces
        self.space = space
        self.space_id = space["space_id"]
        self.member = member
        self.member_id = member["member_id"]
        self.device = device
        self.payload = payload
        self.body = payload["body"]
        self.det = det
        self.role = role
        self.purges = purges
        self.now = spaces.now()
        self.dead_blobs: list[str] = []
        self.rotated = False
        self.org_space = space["owner_kind"] == "org"

    def need_role(self, role: str) -> None:
        if self.role < ROLES[role]:
            raise SpaceError(403, "forbidden", f"needs role {role}")

    def next_seq(self) -> int:
        return self.s.one("SELECT head FROM spaces WHERE space_id=?", (self.space_id,))["head"] + 1

    def need_enc(self, required: bool) -> None:
        if required:
            _need("enc" in self.det, "bad_op", "this op carries its content in enc", 400)
        if "enc" in self.det or self.payload.get("epoch") is not None:
            _need(self.payload.get("epoch") == self.space["epoch"], "stale_epoch",
                  "content is encrypted with the current epoch's key", 409)
        _need("wrapped_dk" not in self.det or self.payload["type"] == "item.share", "bad_op",
              "only item.share carries wrapped_dk", 400)

    def active_devices(self, exclude_member: Optional[str] = None) -> list[str]:
        return [r["device_id"] for r in self.s.all(
            "SELECT d.device_id FROM devices d JOIN members m ON m.space_id=d.space_id AND m.member_id=d.member_id"
            " WHERE d.space_id=? AND d.status='active' AND m.status='active' AND (? IS NULL OR d.member_id != ?)"
            " ORDER BY d.added_seq, d.device_id", (self.space_id, exclude_member, exclude_member))]

    def active_item(self, item_id: str) -> dict:
        row = self.s.item(self.space_id, item_id)
        if row is None:
            raise SpaceError(404, "unknown_item")
        if row["status"] != "active":
            raise SpaceError(410, "item_gone", item_status=row["status"])
        return row

    def rotate(self, epoch: object, wraps: object, link: object, exclude_member: Optional[str] = None) -> int:
        """A new epoch: its key wrapped to every remaining active device, and the epoch link (the previous
        key under the new one). A removed member's devices never get a wrap for it."""
        new = self.space["epoch"] + 1
        _need(epoch == new, "bad_epoch", f"the next epoch is {new}", 409)
        problem = sc.elink_problem(link)
        _need(problem is None, "not_ciphertext", f"epoch_link: {problem}")
        devices = self.active_devices(exclude_member)
        stored = self.s._wraps(wraps, self.space_id, new, devices)
        for w in stored:
            self.s.x("INSERT OR REPLACE INTO key_wraps VALUES (?,?,?,?)", (self.space_id, new, w["device_id"], w["wrap"]))
        if self.org_space:
            # v8 B5: the new key also goes to the org admins' devices by the org's policy (escrow).
            self.s.store_escrow(self.space, new, _escrow_list(self.body.get("escrow_wraps"), set(devices)))
            self.s.check_escrow(self.space, new)
        self.s.x("INSERT OR REPLACE INTO epoch_links VALUES (?,?,?)", (self.space_id, new, link))
        self.s.x("UPDATE spaces SET epoch=?, rotation_pending=0 WHERE space_id=?", (new, self.space_id))
        self.space["epoch"] = new
        self.rotated = True
        return new


def _escrow_list(wraps: object, members: set[str]) -> Optional[list]:
    """Escrow wraps as sent, without those of devices that get a member wrap anyway; None when there are none."""
    if wraps is None:
        return None
    _need(isinstance(wraps, list) and all(isinstance(w, dict) for w in wraps), "bad_field",
          "escrow_wraps is a list of {device_id, epoch, wrap}")
    return [w for w in wraps if w.get("device_id") not in members] or None


def _op_id_of(wire: object) -> Optional[str]:
    try:
        payload = json.loads(sc.b64u_decode(wire.get("op")).decode("utf-8"))
        return payload.get("op_id") if isinstance(payload, dict) else None
    except Exception:
        return None


def _consteq(a: str, b: str) -> bool:
    import hmac
    return hmac.compare_digest(a.encode(), b.encode())


def _write_new(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
    finally:
        os.close(fd)


def _fsync_dir(path: Path) -> None:
    """Make a new file's directory entry durable (best effort where directories cannot be opened)."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _unlink(path: Path) -> None:
    try:
        size = path.stat().st_size
        # Overwrite before unlinking (best effort: the file system may keep old blocks; the bytes are ciphertext).
        with open(path, "r+b") as fh:
            fh.write(b"\0" * min(size, 64 * 1024 * 1024))
        path.unlink()
    except FileNotFoundError:
        pass


def read_host_keys() -> list[str]:
    """This Spark's SSH host public keys ("type base64"), for invites that pin the host key."""
    out = []
    ssh = Path("/etc/ssh")
    for p in sorted(ssh.glob("ssh_host_*_key.pub")) if ssh.is_dir() else []:
        try:
            parts = p.read_text().split()
        except OSError:
            continue
        if len(parts) >= 2:
            out.append(f"{parts[0]} {parts[1]}")
    return out


def _host_key(value: object) -> str:
    _need(isinstance(value, str) and len(value) <= 1024, "bad_field", "host_key is 'type base64'")
    parts = value.split()
    _need(len(parts) >= 2 and parts[0].startswith(("ssh-", "ecdsa-")), "bad_field", "host_key is 'type base64'")
    return f"{parts[0]} {parts[1]}"


# Each handler checks rights and fields, changes state, and returns (subject item id or None, effects for the
# client, audit target of ids and counts).

def h_space_meta(c: OpContext):
    c.need_role("admin")
    c.need_enc(True)
    return None, {}, {}


def h_space_policy(c: OpContext):
    c.need_role("admin")
    policy = c.s._policy(c.space["owner_kind"], c.body.get("policy") or {}, c.space["policy"])
    c.s.x("UPDATE spaces SET policy=? WHERE space_id=?", (_dumps(policy), c.space_id))
    return None, {"policy": policy}, {"fields": sorted((c.body.get("policy") or {}).keys())}


def h_space_archive(c: OpContext):
    c.need_role("admin")
    archived = c.body.get("archived")
    _need(isinstance(archived, bool), "bad_field", "archived is a boolean")
    c.s.x("UPDATE spaces SET archived=? WHERE space_id=?", (1 if archived else 0, c.space_id))
    return None, {"archived": archived}, {"archived": archived}


def h_invite_create(c: OpContext):
    c.need_role("admin")
    b = c.body
    invite_id = _uuid_field(b, "invite_id")
    _need(isinstance(b.get("secret_hash"), str) and sc.HEX64_RE.match(b["secret_hash"]) is not None,
          "bad_field", "secret_hash is 64 lowercase hex")
    expires = parse_ts(b.get("expires_at"))
    _need(expires is not None, "bad_field", "expires_at is an ISO-8601 time with an offset")
    _need(c.now < expires <= c.now + INVITE_MAX_S + 60, "bad_field", "an invite expires within 7 days")
    role = b.get("role", "write")
    _need(role in ROLES, "bad_field", "role is read, write, maintain or admin")
    outside = bool(b.get("outside", False))
    _need(not outside or c.org_space, "bad_field", "outside collaborators exist only in org spaces")
    host_key = None
    if b.get("host_key") is not None:
        host_key = _host_key(b["host_key"])
        mine = c.s._host_keys()
        if mine and host_key not in mine:
            raise SpaceError(422, "host_key_mismatch", "the pinned host key is not this Spark's")
    if c.s.one("SELECT 1 FROM invites WHERE space_id=? AND invite_id=?", (c.space_id, invite_id)):
        raise SpaceError(409, "invite_exists")
    c.s.x("INSERT INTO invites(space_id, invite_id, secret_hash, role, outside, host_key, expires_ts, status,"
          " created_by, created_seq) VALUES (?,?,?,?,?,?,?,'open',?,?)",
          (c.space_id, invite_id, b["secret_hash"], role, 1 if outside else 0, host_key, expires, c.member_id,
           c.next_seq()))
    return None, {"invite_id": invite_id, "expires_at": iso(expires)}, {"invite_id": invite_id, "role": role,
                                                                         "outside": outside}


def h_invite_revoke(c: OpContext):
    c.need_role("admin")
    invite_id = _uuid_field(c.body, "invite_id")
    row = c.s.one("SELECT status FROM invites WHERE space_id=? AND invite_id=?", (c.space_id, invite_id))
    if row is None:
        raise SpaceError(404, "unknown_invite")
    if row["status"] == "open":
        c.s.x("UPDATE invites SET status='revoked' WHERE space_id=? AND invite_id=?", (c.space_id, invite_id))
    return None, {"invite_id": invite_id}, {"invite_id": invite_id}


def h_join_approve(c: OpContext):
    c.need_role("admin")
    request_id = _uuid_field(c.body, "request_id")
    req = c.s.one("SELECT * FROM join_requests WHERE space_id=? AND request_id=?", (c.space_id, request_id))
    if req is None:
        raise SpaceError(404, "unknown_request")
    _need(req["status"] == "pending", "not_pending", f"the request is {req['status']}", 409)
    _need(not c.space["rotation_pending"], "rotation_pending", "rotate the space key before approving", 409)
    # The approving admin signs the joiner's member id and both public keys: every member Mac rebuilds the
    # space's devices from these signed ops alone, never from the Spark's tables (review finding V7-S1).
    _need(c.body.get("member_id") == req["member_id"], "approve_mismatch",
          "join.approve names the request's member id")
    approved = _device_record(c.body.get("device"))
    _need(approved == {"device_id": req["device_id"], "sign_pub": req["sign_pub"], "seal_pub": req["seal_pub"]},
          "approve_mismatch", "join.approve commits to the joining device's keys")
    inv = c.s.one("SELECT role, outside FROM invites WHERE space_id=? AND invite_id=?", (c.space_id, req["invite_id"]))
    role = c.body.get("role") or (inv["role"] if inv else "write")
    _need(role in ROLES, "bad_field", "role is read, write, maintain or admin")
    wraps = c.s._wraps(c.body.get("wraps"), c.space_id, c.space["epoch"], [req["device_id"]])
    member = c.s.member(c.space_id, req["member_id"])
    seq = c.next_seq()
    if member is None:
        c.s.x("INSERT INTO members(space_id, member_id, role, outside, status, joined_ts) VALUES (?,?,?,?,'active',?)",
              (c.space_id, req["member_id"], role, inv["outside"] if inv else 0, c.now))
    elif member["status"] == "active":
        role = member["role"]  # another device of an existing member
    else:
        c.s.x("UPDATE members SET role=?, status='active', ended_ts=NULL, joined_ts=? WHERE space_id=? AND"
              " member_id=?", (role, c.now, c.space_id, req["member_id"]))
    c.s.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',?)",
          (c.space_id, req["device_id"], req["member_id"], req["sign_pub"], req["seal_pub"], seq))
    c.s.x("INSERT OR REPLACE INTO key_wraps VALUES (?,?,?,?)",
          (c.space_id, c.space["epoch"], req["device_id"], wraps[0]["wrap"]))
    c.s.x("UPDATE join_requests SET status='approved', resolved_seq=? WHERE space_id=? AND request_id=?",
          (seq, c.space_id, request_id))
    return None, {"member_id": req["member_id"], "device_id": req["device_id"], "role": role}, \
        {"request_id": request_id, "member_id": req["member_id"], "role": role}


def h_join_reject(c: OpContext):
    c.need_role("admin")
    request_id = _uuid_field(c.body, "request_id")
    req = c.s.one("SELECT status FROM join_requests WHERE space_id=? AND request_id=?", (c.space_id, request_id))
    if req is None:
        raise SpaceError(404, "unknown_request")
    _need(req["status"] == "pending", "not_pending", f"the request is {req['status']}", 409)
    c.s.x("UPDATE join_requests SET status='rejected', resolved_seq=?, profile=NULL WHERE space_id=? AND request_id=?",
          (c.next_seq(), c.space_id, request_id))
    return None, {}, {"request_id": request_id}


def _protected_member(c: OpContext, member_id: str) -> Optional[str]:
    if c.space["owner_kind"] == "person" and member_id == c.space["owner_member"]:
        return "the owner"
    if c.org_space and c.s.org_admin_here(c.space, member_id) \
            and not c.s.org_admin_here(c.space, c.member_id, c.device):
        return "an org admin"
    return None


def h_member_role(c: OpContext):
    c.need_role("admin")
    member_id = _uuid_field(c.body, "member_id")
    role = c.body.get("role")
    _need(role in ROLES, "bad_field", "role is read, write, maintain or admin")
    m = c.s.member(c.space_id, member_id)
    if m is None or m["status"] != "active":
        raise SpaceError(404, "unknown_member")
    who = _protected_member(c, member_id)
    _need(who is None, "forbidden", f"cannot change the role of {who}", 403)
    if m["role"] == "admin" and role != "admin":
        admins = [x for x in c.s.all("SELECT * FROM members WHERE space_id=? AND status='active'", (c.space_id,))
                  if c.s.effective_role(c.space, x) == ROLES["admin"] and x["member_id"] != member_id]
        _need(bool(admins), "last_admin", "a space keeps at least one admin", 409)
    c.s.x("UPDATE members SET role=? WHERE space_id=? AND member_id=?", (role, c.space_id, member_id))
    return None, {"member_id": member_id, "role": role}, {"member_id": member_id, "role": role}


def _end_membership(c: OpContext, member_id: str, status: str) -> None:
    c.s.x("UPDATE members SET status=?, ended_ts=? WHERE space_id=? AND member_id=?",
          (status, c.now, c.space_id, member_id))
    c.s.x("UPDATE devices SET status=? WHERE space_id=? AND member_id=?", (status, c.space_id, member_id))
    # Wraps sealed to the member's devices are of no more use to anyone.
    c.s.x("DELETE FROM key_wraps WHERE space_id=? AND device_id IN (SELECT device_id FROM devices WHERE space_id=?"
          " AND member_id=?)", (c.space_id, c.space_id, member_id))
    c.s.x("UPDATE proposals SET status='withdrawn' WHERE space_id=? AND author=? AND status='open'",
          (c.space_id, member_id))
    c.s.x("UPDATE join_requests SET status='rejected' WHERE space_id=? AND member_id=? AND status='pending'",
          (c.space_id, member_id))


def h_member_remove(c: OpContext):
    c.need_role("admin")
    member_id = _uuid_field(c.body, "member_id")
    _need(member_id != c.member_id, "bad_field", "use member.leave to leave")
    m = c.s.member(c.space_id, member_id)
    if m is None or m["status"] != "active":
        raise SpaceError(404, "unknown_member")
    who = _protected_member(c, member_id)
    _need(who is None, "forbidden", f"cannot remove {who}", 403)
    _end_membership(c, member_id, "removed")
    epoch = c.rotate(c.body.get("epoch"), c.body.get("wraps"), c.body.get("epoch_link"), exclude_member=member_id)
    forks = c.s.one("SELECT COUNT(*) AS n FROM forks WHERE space_id=? AND member_id=?", (c.space_id, member_id))["n"]
    # Contributions stay, attributed (org spaces: org assets; group spaces: a removed member cannot be asked).
    return None, {"member_id": member_id, "epoch": epoch}, {"member_id": member_id, "epoch": epoch, "forks": forks}


def h_member_leave(c: OpContext):
    choice = c.body.get("contributions", "keep")
    _need(choice in ("keep", "withdraw"), "bad_field", "contributions is keep or withdraw")
    if c.space["owner_kind"] == "person" and c.member_id == c.space["owner_member"]:
        raise SpaceError(403, "owner_cannot_leave", "the owner archives or hands the space over instead")
    if choice == "withdraw":
        _need(c.space["policy"].get("on_leave") == "contributor_choice", "forbidden",
              "contributions stay in this space (org asset)", 403)
    if c.role == ROLES["admin"]:
        others = [x for x in c.s.all("SELECT * FROM members WHERE space_id=? AND status='active' AND member_id!=?",
                                     (c.space_id, c.member_id)) if c.s.effective_role(c.space, x) == ROLES["admin"]]
        _need(bool(others), "last_admin", "a space keeps at least one admin", 409)
    seq = c.next_seq()
    withdrawn = 0
    if choice == "withdraw":
        for it in c.s.all("SELECT item_id FROM items WHERE space_id=? AND contributor=? AND status='active'",
                          (c.space_id, c.member_id)):
            c.s.purge_item(c.space_id, it["item_id"], "withdrawn", c.member_id, "left", seq, c.purges)
            withdrawn += 1
    _end_membership(c, c.member_id, "left")
    # The leaver knows the current key; an admin's Mac makes the next one (epoch.rotate). Until then nothing new
    # is shared under the old key.
    c.s.x("UPDATE spaces SET rotation_pending=1 WHERE space_id=?", (c.space_id,))
    return None, {"rotation_pending": True, "withdrawn": withdrawn}, {"withdrawn": withdrawn}


def h_epoch_rotate(c: OpContext):
    c.need_role("admin")
    epoch = c.rotate(c.body.get("epoch"), c.body.get("wraps"), c.body.get("epoch_link"))
    return None, {"epoch": epoch}, {"epoch": epoch}


def h_device_add(c: OpContext):
    """A member adds another of their own devices (a second Mac): signed by an existing device of the member,
    with the current space key wrapped to the new device."""
    device = _device_record(c.body.get("device"))
    _need(not c.space["rotation_pending"], "rotation_pending", "an admin rotates the space key first", 409)
    if c.s.one("SELECT 1 FROM devices WHERE space_id=? AND device_id=?", (c.space_id, device["device_id"])):
        raise SpaceError(409, "device_exists")
    # v8: the new device is this member's own Mac (a device id belongs to one member on this Spark), not one whose
    # access was unpaired here
    c.s._check_device_binding(device, c.member_id, added=True)
    wraps = c.s._wraps(c.body.get("wraps"), c.space_id, c.space["epoch"], [device["device_id"]])
    c.s.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',?)",
          (c.space_id, device["device_id"], c.member_id, device["sign_pub"], device["seal_pub"], c.next_seq()))
    c.s.x("INSERT OR REPLACE INTO key_wraps VALUES (?,?,?,?)",
          (c.space_id, c.space["epoch"], device["device_id"], wraps[0]["wrap"]))
    return None, {"device_id": device["device_id"]}, {"device_id": device["device_id"]}


def h_device_remove(c: OpContext):
    """A member retires one of their devices (a lost Mac); an admin may retire anyone's. The space key rotates in
    the same op, like a member removal."""
    device_id = _uuid_field(c.body, "device_id")
    dev = c.s.one("SELECT * FROM devices WHERE space_id=? AND device_id=?", (c.space_id, device_id))
    if dev is None or dev["status"] != "active":
        raise SpaceError(404, "unknown_device")
    if dev["member_id"] != c.member_id:
        c.need_role("admin")
    _need(device_id != c.device["device_id"], "bad_field", "retire a device from another one")
    c.s.x("UPDATE devices SET status='removed' WHERE space_id=? AND device_id=?", (c.space_id, device_id))
    c.s.x("DELETE FROM key_wraps WHERE space_id=? AND device_id=?", (c.space_id, device_id))
    epoch = c.rotate(c.body.get("epoch"), c.body.get("wraps"), c.body.get("epoch_link"))
    return None, {"device_id": device_id, "epoch": epoch}, {"device_id": device_id, "epoch": epoch}


def h_member_profile(c: OpContext):
    c.need_enc(True)
    return None, {}, {}


def _blobs(c: OpContext, item_id: str) -> list[dict]:
    blobs = c.body.get("blobs") or []
    _need(isinstance(blobs, list) and len(blobs) <= 20, "bad_field", "blobs is a list of up to 20")
    out = []
    for b in blobs:
        _need(isinstance(b, dict) and sc.is_uuid(b.get("blob_id")), "bad_field", "blob_id must be a lowercase UUID")
        _need(b.get("role", "original") in BLOB_ROLES, "bad_field", "blob role is " + "/".join(sorted(BLOB_ROLES)))
        row = c.s.one("SELECT * FROM blobs WHERE space_id=? AND blob_id=?", (c.space_id, b["blob_id"]))
        _need(row is not None and row["status"] == "pending" and row["device_id"] == c.device["device_id"],
              "unknown_blob", "upload the blob from this device first", 409)
        _need(all(x["blob_id"] != b["blob_id"] for x in out), "bad_field", "a blob is listed once")
        out.append({"blob_id": b["blob_id"], "role": b.get("role", "original"), "size": row["size"]})
    if out:
        _need(c.space["policy"].get("originals") != "text_only", "originals_not_allowed",
              "this space keeps text only", 403)
    return out


def audio_limit_bytes(length_ms: int) -> int:
    """The largest audio blob (ciphertext) a part of this length may have (v8 C1)."""
    return AUDIO_OVERHEAD_BYTES + -(-length_ms * AUDIO_BYTES_PER_S // 1000)


def _segment(c: OpContext) -> Optional[dict]:
    segment = c.body.get("segment")
    if segment is None:
        return None
    _need(isinstance(segment, dict), "bad_field", "segment is an object")
    parent = _item_id(segment.get("parent_item_id"))
    start, end = segment.get("start_ms"), segment.get("end_ms")
    _need(isinstance(start, int) and isinstance(end, int) and 0 <= start < end, "bad_field",
          "segment start_ms < end_ms")
    rec = segment.get("recording_ms")
    _need(rec is None or (isinstance(rec, int) and rec >= end), "bad_field",
          "segment recording_ms is the whole recording's length (>= end_ms)")
    return {"parent_item_id": parent, "start_ms": start, "end_ms": end, "recording_ms": rec}


def _snapshot(c: OpContext, kind: str, item_id: str) -> Optional[dict]:
    """v8 C2: a snapshot (a frozen summary, a handover pack) names what it froze, by ids only (this body is plain):
    the matter, the pack, when, and the items of this space it draws on (when one of them is withdrawn or removed,
    the snapshot goes too)."""
    snap = c.body.get("snapshot")
    if snap is None:
        return None
    _need(kind == "snapshot" and isinstance(snap, dict) and set(snap) <= {"matter_id", "pack_id", "as_of", "cites"},
          "bad_field", "snapshot is {matter_id?, pack_id?, as_of?, cites?} on a snapshot item")
    _need(snap.get("matter_id") is None or (isinstance(snap["matter_id"], str) and re.fullmatch(
        r"[A-Za-z0-9._:-]{1,64}", snap["matter_id"]) is not None), "bad_field", "snapshot.matter_id is an id")
    _need(snap.get("pack_id") is None or sc.is_uuid(snap.get("pack_id")), "bad_field", "snapshot.pack_id is a UUID")
    if snap.get("as_of") is not None:
        as_of = parse_ts(snap["as_of"])
        _need(as_of is not None and as_of <= c.now + REQUEST_SKEW_S, "bad_field",
              "snapshot.as_of is an ISO-8601 time with an offset, not in the future")
    cites = snap.get("cites") or []
    _need(isinstance(cites, list) and len(cites) <= MAX_SNAPSHOT_CITES, "bad_field",
          f"snapshot.cites is a list of up to {MAX_SNAPSHOT_CITES} item ids")
    ids = sorted({_item_id(i) for i in cites})
    _need(item_id not in ids, "bad_field", "a snapshot does not cite itself")
    gone = [i for i in ids if (c.s.item(c.space_id, i) or {}).get("status") != "active"]
    if gone:
        raise SpaceError(422, "unknown_items", "a snapshot cites active items of this space", item_ids=gone[:20])
    return {"cites": ids}


class _Already:
    """What an op asks for is already done (a retried share, a second withdraw): answered like a duplicate, not
    logged again (v8 C3)."""

    def __init__(self, seq: Optional[int], effects: dict, accepted_as: str):
        self.result = {"ok": True, "duplicate": True, "accepted_as": accepted_as, "seq": seq, "effects": effects}


def h_item_share(c: OpContext):
    c.need_role("write")
    b = c.body
    item_id = _item_id(b.get("item_id"))
    kind = b.get("kind")
    if kind in NEVER_SHARED:
        raise SpaceError(422, "never_shared", "voiceprints, the dictionary, personalized recognition and whole"
                                              " recordings never leave the Mac")
    _need(kind in ITEM_KINDS, "bad_field", "unknown item kind")
    revision = b.get("revision")
    _need(isinstance(revision, int) and revision >= 0, "bad_field", "revision is an integer >= 0")
    share_key = _uuid_field(b, "share_key", required=False)
    cur = c.s.item(c.space_id, item_id)
    # v8 C3: the Mac's outbox may send a share again after the first one was applied and its answer lost, as the
    # same op (a plain duplicate, above) or remade (new op id, new data key: e.g. after a key rotation). The same
    # outbox entry (share_key) at the item's current revision is that share, accepted once: the remade op's own
    # uploads are dropped and nothing new is logged.
    if share_key is not None and cur is not None and cur["status"] == "active" and \
            cur["contributor"] == c.member_id and cur["share_key"] == share_key and cur["revision"] == revision:
        for x in b.get("blobs") or []:
            bid = x.get("blob_id") if isinstance(x, dict) else None
            if sc.is_uuid(bid) and c.s.one("SELECT 1 FROM blobs WHERE space_id=? AND blob_id=? AND status='pending'"
                                           " AND device_id=?", (c.space_id, bid, c.device["device_id"])):
                c.s.x("UPDATE blobs SET status='deleted' WHERE space_id=? AND blob_id=?", (c.space_id, bid))
                c.dead_blobs.append(bid)
        return _Already(cur["share_seq"], {"item_id": item_id, "revision": revision,
                                           "epoch": (c.s.one("SELECT epoch FROM item_keys WHERE space_id=? AND"
                                                             " item_id=?", (c.space_id, item_id)) or {}).get("epoch")},
                        "share_key")
    # v8 C2: a snapshot is frozen: always a new item, never revised (share a new snapshot instead)
    if cur is not None and (kind == "snapshot" or cur["kind"] == "snapshot"):
        raise SpaceError(409, "snapshot_frozen", "a snapshot is never revised; share a new one")
    snap = _snapshot(c, kind, item_id)
    _need("enc" in c.det and "wrapped_dk" in c.det, "bad_op", "item.share carries enc and wrapped_dk", 400)
    _need(not c.space["rotation_pending"], "rotation_pending", "an admin rotates the space key first", 409)
    c.need_enc(True)
    blobs = _blobs(c, item_id)
    segment = _segment(c)
    audio = [x for x in blobs if x["role"] == "audio"]
    if audio or kind == "audio_segment":
        # Audio only as segments: a whole meeting holds other people's words.
        _need(segment is not None, "audio_needs_segment", "audio is shared only as a segment of a recording")
        _need(segment["end_ms"] - segment["start_ms"] <= MAX_SEGMENT_MS, "segment_too_long",
              "a shared audio segment is at most 15 minutes")
    if audio:
        _audio_part(c, item_id, kind, segment, audio)
    if kind in AUDIO_KINDS:
        # V8R-15: a meeting or imported-media item carries at most its audio part; an "original" (or any other blob)
        # there could be the whole recording under another name, which the Spark cannot look inside to tell.
        _need(all(x["role"] == "audio" for x in blobs), "bad_field",
              "a meeting or imported-media item carries no blob but its audio part")
    package_id = _uuid_field(b, "package_id", required=False)
    if segment is not None:
        _recording_limit(c, item_id, segment)
    # v8 B6: the member's quota in this space (a new revision replaces the old one's fields and blobs)
    replaced = 0 if cur is None or cur["contributor"] != c.member_id else int(c.s.one(
        "SELECT COALESCE(SUM(LENGTH(enc)),0) AS n FROM ops WHERE space_id=? AND subject=? AND type='item.share' AND"
        " enc IS NOT NULL", (c.space_id, item_id))["n"]) + int(c.s.one(
            "SELECT COALESCE(SUM(size),0) AS n FROM blobs WHERE space_id=? AND item_id=? AND status='attached'",
            (c.space_id, item_id))["n"])
    c.s.check_quota(c.space, c.member_id, len(c.det["enc"]) - replaced)
    seq = c.next_seq()
    if cur is not None:
        if cur["status"] != "active":
            raise SpaceError(410, "item_gone", item_status=cur["status"])
        _need(cur["contributor"] == c.member_id, "forbidden", "the item was shared by another member", 403)
        if revision <= cur["revision"]:
            raise SpaceError(409, "stale_revision", "a newer revision is already shared")
        # A new revision deletes the old one's key, fields and blobs: past the withdraw window of an org space
        # that would shred an org asset the contributor may no longer withdraw (review finding V7-S3).
        if not _withdraw_window_open(c, cur):
            raise SpaceError(403, "window_passed", "past the withdraw window; share a new item instead")
        # A new revision replaces the old one: the old data key, fields and blobs go.
        c.s.x("UPDATE ops SET enc=NULL, purged=1 WHERE space_id=? AND subject=? AND type='item.share'",
              (c.space_id, item_id))
        old = c.s.all("SELECT blob_id FROM blobs WHERE space_id=? AND item_id=? AND status='attached'",
                      (c.space_id, item_id))
        c.s.x("UPDATE blobs SET status='deleted' WHERE space_id=? AND item_id=? AND status='attached'",
              (c.space_id, item_id))
        c.dead_blobs += [o["blob_id"] for o in old]
        c.s.x("UPDATE items SET revision=?, kind=?, device_id=?, share_seq=?, updated_seq=?, share_key=? WHERE"
              " space_id=? AND item_id=?",
              (revision, kind, c.device["device_id"], seq, seq, share_key, c.space_id, item_id))
    else:
        c.s.x("INSERT INTO items(space_id, item_id, contributor, device_id, kind, revision, status, share_seq,"
              " first_ts, updated_seq, share_key) VALUES (?,?,?,?,?,?,'active',?,?,?,?)",
              (c.space_id, item_id, c.member_id, c.device["device_id"], kind, revision, seq, c.now, seq, share_key))
    c.s.x("INSERT OR REPLACE INTO item_keys VALUES (?,?,?,?)",
          (c.space_id, item_id, c.space["epoch"], c.det["wrapped_dk"]))
    for x in blobs:
        c.s.x("UPDATE blobs SET status='attached', item_id=?, role=? WHERE space_id=? AND blob_id=?",
              (item_id, x["role"], c.space_id, x["blob_id"]))
    if segment is not None:
        c.s.x("INSERT OR REPLACE INTO segments(space_id, item_id, contributor, parent_item_id, start_ms, end_ms, audio,"
              " recording_ms) VALUES (?,?,?,?,?,?,?,?)",
              (c.space_id, item_id, c.member_id, segment["parent_item_id"], segment["start_ms"], segment["end_ms"],
               1 if audio else 0, segment["recording_ms"]))
    else:
        c.s.x("DELETE FROM segments WHERE space_id=? AND item_id=?", (c.space_id, item_id))
    if snap is not None:
        for cited in snap["cites"]:
            c.s.x("INSERT OR IGNORE INTO snapshot_cites VALUES (?,?,?)", (c.space_id, item_id, cited))
    target = {"item_id": item_id, "kind": kind, "revision": revision, "blobs": len(blobs), "package_id": package_id}
    if audio:
        target["audio_ms"] = segment["end_ms"] - segment["start_ms"]
    if snap is not None:
        target["cites"] = len(snap["cites"])
    return item_id, {"item_id": item_id, "revision": revision, "epoch": c.space["epoch"]}, target


def _audio_part(c: OpContext, item_id: str, kind: str, segment: dict, audio: list[dict]) -> None:
    """v8 C1: a meeting segment's audio, end-to-end encrypted to the members (the Spark stores the ciphertext and
    cannot open it). One audio blob per item, only on a meeting or imported-media item, only where the space allows
    it; a part of a recording, never all of it (the op names the recording's length); its ciphertext no larger than
    the part's length allows; one audio part per recording per member in a space."""
    _need(c.space["policy"].get("segment_audio", True) is not False, "audio_not_allowed",
          "this space does not take meeting audio", 403)
    _need(kind in AUDIO_KINDS, "bad_field", "audio goes with a meeting or imported-media item")
    _need(len(audio) == 1, "bad_field", "an item carries one audio part")
    _need(segment["recording_ms"] is not None, "bad_field",
          "an audio part names the whole recording's length (segment.recording_ms)")
    length = segment["end_ms"] - segment["start_ms"]
    # A part, never (nearly) the whole: at most 4/5 of the recording (review finding V8R-15; "1 ms shorter" was a
    # whole short meeting).
    _need(length * AUDIO_PART_DEN <= segment["recording_ms"] * AUDIO_PART_NUM, "whole_recording",
          "a whole recording is never shared, only a part of it (at most 4/5 of it)")
    limit = audio_limit_bytes(length)
    if audio[0]["size"] > limit:
        raise SpaceError(413, "audio_too_large", "the audio is larger than its length allows",
                         limit_bytes=limit, size_bytes=audio[0]["size"])
    other = c.s.one("SELECT s.item_id FROM segments s JOIN items i ON i.space_id=s.space_id AND i.item_id=s.item_id"
                    " WHERE s.space_id=? AND s.contributor=? AND s.parent_item_id=? AND s.audio=1 AND s.item_id!=?"
                    " AND i.status='active' LIMIT 1",
                    (c.space_id, c.member_id, segment["parent_item_id"], item_id))
    if other is not None:
        raise SpaceError(409, "one_part_per_recording", "one audio part of a recording per member in a space",
                         item_id=other["item_id"])


def _recording_limit(c: OpContext, item_id: str, segment: dict) -> None:
    """Parts of one recording a member shares, text or audio, add up to at most 15 minutes in a space: a whole
    meeting holds other people's words, and eight consecutive 15-minute parts are the whole meeting (review
    finding V7-S5). Overlaps count once; this item's own earlier revision does not count."""
    parent = segment["parent_item_id"]
    spans = [(r["start_ms"], r["end_ms"]) for r in c.s.all(
        "SELECT s.start_ms, s.end_ms FROM segments s JOIN items i ON i.space_id=s.space_id AND i.item_id=s.item_id"
        " WHERE s.space_id=? AND s.contributor=? AND s.parent_item_id=? AND s.item_id!=? AND i.status='active'",
        (c.space_id, c.member_id, parent, item_id))]
    spans.append((segment["start_ms"], segment["end_ms"]))
    total, end = 0, -1
    for start, stop in sorted(spans):
        if stop <= end:
            continue
        total += stop - max(start, end)
        end = stop
    _need(total <= MAX_SEGMENT_MS, "recording_share_limit",
          "parts of one recording are shared up to 15 minutes in a space")


def _withdraw_window_open(c: OpContext, item: dict) -> bool:
    window = c.space["policy"].get("withdraw_window_h")
    return window is None or c.now - item["first_ts"] <= window * 3600


def _already_withdrawn(c: OpContext, item_id: str) -> Optional[_Already]:
    """v8 C3: the member's own item they already withdrew (a remade withdraw or delete from the outbox)."""
    item = c.s.item(c.space_id, item_id)
    if item is not None and item["status"] == "withdrawn" and item["contributor"] == c.member_id and \
            item["ended_by"] == c.member_id:
        return _Already(item["ended_seq"], {"item_id": item_id, "status": "withdrawn"}, "withdrawn")
    return None


def h_item_withdraw(c: OpContext):
    item_id = _item_id(c.body.get("item_id"))
    done = _already_withdrawn(c, item_id)
    if done is not None:
        return done
    item = c.active_item(item_id)
    _need(item["contributor"] == c.member_id, "forbidden", "only the contributor withdraws an item", 403)
    if not _withdraw_window_open(c, item):
        raise SpaceError(403, "window_passed", "file a takedown request instead")
    c.s.purge_item(c.space_id, item_id, "withdrawn", c.member_id, "withdrawn", c.next_seq(), c.purges)
    return item_id, {"item_id": item_id, "status": "withdrawn"}, {"item_id": item_id}


def _open_takedown(c: OpContext, takedown_id: str, item_id: str, kind: str) -> dict:
    if c.s.one("SELECT 1 FROM takedowns WHERE space_id=? AND takedown_id=?", (c.space_id, takedown_id)):
        raise SpaceError(409, "takedown_exists")
    due = c.now + c.space["policy"]["takedown_window_h"] * 3600 if kind == "privacy" else None
    c.s.x("INSERT INTO takedowns VALUES (?,?,?,?,?,'open',?,?,?,NULL)",
          (c.space_id, takedown_id, item_id, kind, c.member_id, c.now, due, c.next_seq()))
    return {"takedown_id": takedown_id, "kind": kind, "due_at": iso(due)}


def h_item_delete(c: OpContext):
    """The contributor deletes their item: a withdraw, or in an org space past the window a takedown request."""
    item_id = _item_id(c.body.get("item_id"))
    done = _already_withdrawn(c, item_id)
    if done is not None:
        return done
    item = c.active_item(item_id)
    _need(item["contributor"] == c.member_id, "forbidden", "only the contributor deletes an item", 403)
    t = c.s.one("SELECT * FROM takedowns WHERE space_id=? AND item_id=? AND requester=? AND kind='other' AND"
                " status='open' ORDER BY created_ts LIMIT 1", (c.space_id, item_id, c.member_id))
    if t is not None:  # v8 C3: a remade delete past the window: the takedown it asked for is open already
        return _Already(t["op_seq"], {"item_id": item_id, "status": "takedown_requested", "takedown_id": t["takedown_id"],
                                      "kind": "other", "due_at": None}, "open_takedown")
    if _withdraw_window_open(c, item):
        c.s.purge_item(c.space_id, item_id, "withdrawn", c.member_id, "deleted", c.next_seq(), c.purges)
        return item_id, {"item_id": item_id, "status": "withdrawn"}, {"item_id": item_id, "outcome": "withdrawn"}
    takedown_id = str(uuid.uuid5(uuid.UUID(c.payload["op_id"]), "takedown"))
    t = _open_takedown(c, takedown_id, item_id, "other")
    return item_id, {"item_id": item_id, "status": "takedown_requested", **t}, \
        {"item_id": item_id, "outcome": "takedown", "takedown_id": takedown_id}


def h_takedown_request(c: OpContext):
    takedown_id = _uuid_field(c.body, "takedown_id")
    item_id = _item_id(c.body.get("item_id"))
    kind = c.body.get("kind")
    _need(kind in TAKEDOWN_KINDS, "bad_field", "kind is privacy or other")
    item = c.active_item(item_id)
    if kind == "other":
        # Anyone may ask to take down what exposes them (privacy); other reasons are the contributor's.
        _need(item["contributor"] == c.member_id, "forbidden", "only the contributor files this takedown", 403)
    elif item["contributor"] != c.member_id:
        # Someone else's item: a maintainer may reject it with a reason, and one member keeps at most a few open
        # at a time, so a privacy takedown is not a way for any reader to delete the org's assets wholesale
        # (review finding V7-S4).
        n = c.s.one("SELECT COUNT(*) AS n FROM takedowns WHERE space_id=? AND requester=? AND kind='privacy' AND"
                    " status='open'", (c.space_id, c.member_id))["n"]
        _need(n < MAX_OPEN_PRIVACY_TAKEDOWNS, "too_many_takedowns",
              f"at most {MAX_OPEN_PRIVACY_TAKEDOWNS} open privacy takedowns per member", 409)
    c.need_enc(False)
    t = _open_takedown(c, takedown_id, item_id, kind)
    return item_id, t, {"takedown_id": takedown_id, "item_id": item_id, "kind": kind}


def h_takedown_resolve(c: OpContext):
    c.need_role("maintain")
    takedown_id = _uuid_field(c.body, "takedown_id")
    decision = c.body.get("decision")
    _need(decision in ("accept", "reject"), "bad_field", "decision is accept or reject")
    t = c.s.one("SELECT * FROM takedowns WHERE space_id=? AND takedown_id=?", (c.space_id, takedown_id))
    if t is None:
        raise SpaceError(404, "unknown_takedown")
    _need(t["status"] == "open", "not_open", f"the takedown is {t['status']}", 409)
    seq = c.next_seq()
    if decision == "reject":
        if t["kind"] == "privacy":
            # A contributor's own privacy takedown is honoured. Anyone else's may be rejected, with a reason the
            # requester sees (enc); unless a maintainer rejects it, it is carried out when its window ends.
            item = c.s.item(c.space_id, t["item_id"])
            _need(item is None or item["contributor"] != t["requester"], "privacy_takedown",
                  "the contributor's own privacy takedown is honoured, not rejected", 403)
            c.need_enc(True)
        c.s.x("UPDATE takedowns SET status='rejected', resolved_seq=? WHERE space_id=? AND takedown_id=?",
              (seq, c.space_id, takedown_id))
        return t["item_id"], {"takedown_id": takedown_id, "status": "rejected"}, {"takedown_id": takedown_id,
                                                                                 "decision": decision}
    item = c.s.item(c.space_id, t["item_id"])
    if item is not None and item["status"] == "active":
        c.s.purge_item(c.space_id, t["item_id"], "removed", c.member_id, "takedown", seq, c.purges)
    c.s.x("UPDATE takedowns SET status='done', resolved_seq=? WHERE space_id=? AND takedown_id=?",
          (seq, c.space_id, takedown_id))
    return t["item_id"], {"takedown_id": takedown_id, "status": "done"}, {"takedown_id": takedown_id,
                                                                          "decision": decision}


def h_takedown_withdraw(c: OpContext):
    takedown_id = _uuid_field(c.body, "takedown_id")
    t = c.s.one("SELECT * FROM takedowns WHERE space_id=? AND takedown_id=?", (c.space_id, takedown_id))
    if t is None:
        raise SpaceError(404, "unknown_takedown")
    _need(t["requester"] == c.member_id, "forbidden", "only the requester withdraws a takedown", 403)
    _need(t["status"] == "open", "not_open", f"the takedown is {t['status']}", 409)
    c.s.x("UPDATE takedowns SET status='withdrawn', resolved_seq=? WHERE space_id=? AND takedown_id=?",
          (c.next_seq(), c.space_id, takedown_id))
    return t["item_id"], {"takedown_id": takedown_id, "status": "withdrawn"}, {"takedown_id": takedown_id}


def h_item_remove(c: OpContext):
    c.need_role("maintain")
    item_id = _item_id(c.body.get("item_id"))
    c.active_item(item_id)
    reason = c.body.get("reason", "other")
    _need(reason in ("policy", "privacy", "other"), "bad_field", "reason is policy, privacy or other")
    c.s.purge_item(c.space_id, item_id, "removed", c.member_id, reason, c.next_seq(), c.purges)
    return item_id, {"item_id": item_id, "status": "removed"}, {"item_id": item_id, "reason": reason}


def h_item_hide(c: OpContext):
    item_id = _item_id(c.body.get("item_id"))
    hidden = c.body.get("hidden", True)
    _need(isinstance(hidden, bool), "bad_field", "hidden is a boolean")
    if c.s.item(c.space_id, item_id) is None:
        raise SpaceError(404, "unknown_item")
    if hidden:
        c.s.x("INSERT OR IGNORE INTO hidden VALUES (?,?,?)", (c.space_id, c.member_id, item_id))
    else:
        c.s.x("DELETE FROM hidden WHERE space_id=? AND member_id=? AND item_id=?", (c.space_id, c.member_id, item_id))
    return item_id, {"item_id": item_id, "hidden": hidden}, {"item_id": item_id}


def h_item_fork(c: OpContext):
    item_id = _item_id(c.body.get("item_id"))
    c.active_item(item_id)
    _need(bool(c.space["policy"].get("forks_allowed")), "forks_not_allowed",
          "this space does not allow saving a copy to your own space", 403)
    c.s.x("INSERT OR IGNORE INTO forks VALUES (?,?,?,?)", (c.space_id, c.member_id, item_id, c.next_seq()))
    return item_id, {"item_id": item_id}, {"item_id": item_id}


def h_item_unfork(c: OpContext):
    item_id = _item_id(c.body.get("item_id"))
    c.s.x("DELETE FROM forks WHERE space_id=? AND member_id=? AND item_id=?", (c.space_id, c.member_id, item_id))
    return item_id, {"item_id": item_id}, {"item_id": item_id}


def h_matter_share(c: OpContext):
    c.need_role("write")
    package_id = _uuid_field(c.body, "package_id")
    ids = c.body.get("item_ids")
    _need(isinstance(ids, list) and 0 < len(ids) <= 500, "bad_field", "item_ids is a list of 1-500")
    ids = [_item_id(i) for i in ids]
    auto = c.body.get("auto", "ask")
    _need(auto in ("ask", "auto", "off"), "bad_field", "auto is ask, auto or off")
    mine = {r["item_id"] for r in c.s.all("SELECT item_id FROM items WHERE space_id=? AND contributor=? AND"
                                          " status='active'", (c.space_id, c.member_id))}
    unknown = sorted(set(ids) - mine)
    if unknown:
        raise SpaceError(422, "unknown_items", "share the package's items first", item_ids=unknown[:20])
    c.need_enc(False)
    prior = c.s.one("SELECT member_id FROM packages WHERE space_id=? AND package_id=?", (c.space_id, package_id))
    _need(prior is None or prior["member_id"] == c.member_id, "forbidden", "another member's package", 403)
    c.s.x("INSERT OR REPLACE INTO packages VALUES (?,?,?,?,?,'active',?)",
          (c.space_id, package_id, c.member_id, auto, len(ids), c.next_seq()))
    return None, {"package_id": package_id, "items": len(ids)}, {"package_id": package_id, "items": len(ids),
                                                                  "auto": auto}


def h_matter_unshare(c: OpContext):
    package_id = _uuid_field(c.body, "package_id")
    row = c.s.one("SELECT member_id FROM packages WHERE space_id=? AND package_id=?", (c.space_id, package_id))
    if row is None:
        raise SpaceError(404, "unknown_package")
    _need(row["member_id"] == c.member_id, "forbidden", "another member's package", 403)
    c.s.x("UPDATE packages SET status='stopped', auto='off' WHERE space_id=? AND package_id=?", (c.space_id, package_id))
    return None, {"package_id": package_id}, {"package_id": package_id}


def h_share_rule(c: OpContext):
    c.need_role("write")
    rule_id = _uuid_field(c.body, "rule_id")
    # A rule is for its member's own Macs: only that member changes or clears it (review finding V7-S17).
    owner = c.s.one("SELECT member_id FROM ops WHERE space_id=? AND type='share_rule.set' AND subject=? ORDER BY seq"
                    " LIMIT 1", (c.space_id, rule_id))
    _need(owner is None or owner["member_id"] == c.member_id, "forbidden", "another member's rule", 403)
    if c.payload["type"] == "share_rule.set":
        _need(c.body.get("kind") in ("rope", "matter"), "bad_field", "kind is rope or matter")
        _need(c.body.get("auto", "ask") in ("ask", "auto"), "bad_field", "auto is ask or auto")
        c.need_enc(True)
    return rule_id, {"rule_id": rule_id}, {"rule_id": rule_id}


def h_proposal_create(c: OpContext):
    c.need_role("write")
    proposal_id = _uuid_field(c.body, "proposal_id")
    kind = c.body.get("kind")
    _need(kind in PROPOSAL_KINDS, "bad_field", "kind is " + "/".join(sorted(PROPOSAL_KINDS)))
    targets = c.body.get("targets") or {}
    _need(isinstance(targets, dict), "bad_field", "targets is an object")
    clean = {}
    for key in ("matter_ids", "item_ids", "rope_ids"):
        vals = targets.get(key) or []
        _need(isinstance(vals, list) and len(vals) <= 50 and all(isinstance(v, str) and 0 < len(v) <= 64 for v in vals),
              "bad_field", f"targets.{key} is a list of ids")
        if vals:
            clean[key] = vals
    c.need_enc(False)
    if c.s.one("SELECT 1 FROM proposals WHERE space_id=? AND proposal_id=?", (c.space_id, proposal_id)):
        raise SpaceError(409, "proposal_exists")
    c.s.x("INSERT INTO proposals VALUES (?,?,?,?,?,'open',?,NULL,NULL)",
          (c.space_id, proposal_id, c.member_id, kind, _dumps(clean), c.next_seq()))
    return None, {"proposal_id": proposal_id}, {"proposal_id": proposal_id, "kind": kind}


def h_proposal_resolve(c: OpContext):
    c.need_role("maintain")
    proposal_id = _uuid_field(c.body, "proposal_id")
    decision = c.body.get("decision")
    _need(decision in ("accept", "reject"), "bad_field", "decision is accept or reject")
    p = c.s.one("SELECT status FROM proposals WHERE space_id=? AND proposal_id=?", (c.space_id, proposal_id))
    if p is None:
        raise SpaceError(404, "unknown_proposal")
    _need(p["status"] == "open", "not_open", f"the proposal is {p['status']}", 409)
    status = "accepted" if decision == "accept" else "rejected"
    c.s.x("UPDATE proposals SET status=?, resolved_seq=?, resolved_by=? WHERE space_id=? AND proposal_id=?",
          (status, c.next_seq(), c.member_id, c.space_id, proposal_id))
    return None, {"proposal_id": proposal_id, "status": status}, {"proposal_id": proposal_id, "decision": decision}


def h_proposal_withdraw(c: OpContext):
    proposal_id = _uuid_field(c.body, "proposal_id")
    p = c.s.one("SELECT * FROM proposals WHERE space_id=? AND proposal_id=?", (c.space_id, proposal_id))
    if p is None:
        raise SpaceError(404, "unknown_proposal")
    _need(p["author"] == c.member_id, "forbidden", "only the author withdraws a proposal", 403)
    _need(p["status"] == "open", "not_open", f"the proposal is {p['status']}", 409)
    c.s.x("UPDATE proposals SET status='withdrawn', resolved_seq=? WHERE space_id=? AND proposal_id=?",
          (c.next_seq(), c.space_id, proposal_id))
    return None, {"proposal_id": proposal_id, "status": "withdrawn"}, {"proposal_id": proposal_id}


def h_matter_handover(c: OpContext):
    matter_id = c.body.get("matter_id")
    _need(isinstance(matter_id, str) and 0 < len(matter_id) <= 64, "bad_field", "matter_id is an id")
    to = _uuid_field(c.body, "to_member_id")
    lead = c.s.one("SELECT member_id FROM matter_leads WHERE space_id=? AND matter_id=?", (c.space_id, matter_id))
    if not (lead and lead["member_id"] == c.member_id):
        c.need_role("maintain")
    target = c.s.member(c.space_id, to)
    _need(target is not None and target["status"] == "active" and c.s.effective_role(c.space, target) >= ROLES["write"],
          "bad_field", "the new 负责人 is an active member who can contribute")
    # v8 B3: the handover pack shared for it (a snapshot item in this space), if any
    pack = c.body.get("pack_item_id")
    if pack is not None:
        pack = _item_id(pack)
        _need(c.active_item(pack)["kind"] == "snapshot", "bad_field", "pack_item_id is a snapshot item of this space")
    c.s.x("INSERT OR REPLACE INTO matter_leads VALUES (?,?,?,?)", (c.space_id, matter_id, to, c.next_seq()))
    return None, {"matter_id": matter_id, "lead": to, "pack_item_id": pack}, \
        {"matter_id": matter_id, "to_member_id": to, "pack_item_id": pack}


def h_escrow_wrap(c: OpContext):
    """v8 B5: an admin's Mac wraps the current key to org admin devices that lack it (a new org admin, a raised
    recovery_admins policy)."""
    c.need_role("admin")
    _need(c.org_space, "bad_field", "escrow is for organization spaces")
    epoch = c.body.get("epoch")
    _need(epoch == c.space["epoch"], "stale_epoch", "escrow wraps are for the current epoch", 409)
    _need(isinstance(c.body.get("wraps"), list) and c.body["wraps"], "bad_field", "wraps is a non-empty list")
    n = c.s.store_escrow(c.space, epoch, _escrow_list(c.body["wraps"], set(c.active_devices())) or [])
    status = c.s.escrow_status(c.space)
    return None, {"epoch": epoch, "stored": n, "escrow_ok": status["ok"]}, {"epoch": epoch, "stored": n}


def h_agent_access(c: OpContext):
    """An agent on a member's Mac read from this space (AGENT-CONTRACT): recorded for the admins' audit."""
    client = c.body.get("client")
    tool = c.body.get("tool")
    _need(isinstance(client, str) and 0 < len(client) <= 64, "bad_field", "client is the agent's name")
    _need(isinstance(tool, str) and 0 < len(tool) <= 40, "bad_field", "tool is the MCP tool")
    counts = {k: c.body.get(k, 0) for k in ("matters", "items", "bytes")}
    _need(all(isinstance(v, int) and v >= 0 for v in counts.values()), "bad_field", "counts are integers")
    allowed = c.body.get("allowed", True)
    _need(isinstance(allowed, bool), "bad_field", "allowed is a boolean")
    return None, {}, {"client": client, "tool": tool, "allowed": allowed, **counts}


HANDLERS: dict[str, Callable[[OpContext], tuple]] = {
    "space.meta": h_space_meta,
    "space.policy": h_space_policy,
    "space.archive": h_space_archive,
    "invite.create": h_invite_create,
    "invite.revoke": h_invite_revoke,
    "join.approve": h_join_approve,
    "join.reject": h_join_reject,
    "member.role": h_member_role,
    "member.remove": h_member_remove,
    "member.leave": h_member_leave,
    "member.profile": h_member_profile,
    "device.add": h_device_add,
    "device.remove": h_device_remove,
    "epoch.rotate": h_epoch_rotate,
    "item.share": h_item_share,
    "item.withdraw": h_item_withdraw,
    "item.delete": h_item_delete,
    "item.remove": h_item_remove,
    "item.hide": h_item_hide,
    "item.fork": h_item_fork,
    "item.unfork": h_item_unfork,
    "takedown.request": h_takedown_request,
    "takedown.resolve": h_takedown_resolve,
    "takedown.withdraw": h_takedown_withdraw,
    "matter.share": h_matter_share,
    "matter.unshare": h_matter_unshare,
    "matter.handover": h_matter_handover,
    "share_rule.set": h_share_rule,
    "share_rule.clear": h_share_rule,
    "proposal.create": h_proposal_create,
    "proposal.resolve": h_proposal_resolve,
    "proposal.withdraw": h_proposal_withdraw,
    "agent.access": h_agent_access,
    "escrow.wrap": h_escrow_wrap,
}

# An archived space is read-only: nothing new comes in; withdraw, removal, takedowns, leave and key rotation work.
ARCHIVE_BLOCKED = {"item.share", "matter.share", "share_rule.set", "proposal.create", "invite.create",
                   "join.approve", "device.add", "matter.handover", "space.policy", "item.fork"}
