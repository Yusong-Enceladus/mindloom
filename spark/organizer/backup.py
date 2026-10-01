"""Encrypted backup and restore of one shared space (v8 contract B4; docs/INFRA.md).

What a backup holds: everything this Spark keeps for the space (spaces.db rows: the signed op log, key wraps,
epoch links, item keys, escrow wraps, invites, join requests, takedowns, proposals, the audit records; the
organization's rows for an org space; the ciphertext blobs; the space organizer's SQLCipher store file and its
key-id sidecars). Almost all of it is ciphertext already; the whole stream is encrypted again so that the ids,
times and roles are not readable either.

The key: an admin's Mac lends it for this one export (POST /v1/spaces/{id}/backup, signed by an admin device), like
the organizer lease; this module never sees a space key. Since the v8 review (V8R-13) it is a random key the Mac keeps
sealed to the space's admin devices and the org admins' escrow devices (a backup holds what only admins see: takedown
reasons, members' hides, the audit, join requests); backups made before used

    backup_key = HKDF-SHA256(ikm = K_epoch, salt = backup_id (16 bytes), info = "mindloom-space-backup-v1")

(reference derivation: space_member.backup_key), which every member of that epoch could derive. Either way nobody
else, the Spark included, can read a backup at rest on an admin's Mac or an external disk.

Stream format MLBK1:

    "MLBK1\\n" + header JSON + "\\n"        {"v":1,"format":"mindloom-space-backup-v1","backup_id","space_id",
                                            "epoch","created_at","chunk"}   (plaintext: which key opens it)
    frames: uint32 BE length + ChaCha20-Poly1305(chunk), nonce = 4 zero bytes + uint64 BE counter,
            AAD = SHA-256(magic + header line) + uint64 BE counter + final flag (1 byte)

The last frame carries the final flag, so a truncated or extended backup is refused. Inside, records:
1 type byte + uint64 BE length + payload: "M" the manifest (JSON), "B" a blob (36-byte id + bytes), "F" an
organizer file (1-byte name length + name + bytes), "E" the end.

Restore (POST /v1/spaces/{id}/restore, the stream as the body, the key in X-Mindloom-Backup-Key) decrypts into a
private spool, checks every frame, that every row is of this space (and its organization), the op log (each op
signed by a device the log itself admitted, from the genesis op on; the organization's log likewise, this Spark's
own when it has the organization), that the rows granting anything (space, members, devices, key wraps, the
organization's) grant no more than the log does, every encrypted field against the hash its op commits to and
every blob against its digest (review findings V8R-01). Then the logs decide (V8R-03): when this Spark's log
already holds the backup's, no row changes and only missing or damaged data comes back ("fill"); when this Spark's
log is a prefix of the backup's, the backup replaces it in one transaction ("full"); diverged logs are refused
unless the Spark owner forces it. Who may restore, decided before the body is read (V8R-10): the Spark owner (a new
or rebuilt Spark), or a member through the gate who is an admin of that space on this Spark now (a space whose
data got damaged). Items withdrawn or removed after the backup was made, which the restoring Mac knows from its
own copy of the log, are purged again right after (X-Mindloom-Restore: {"purge": [...]}).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Iterator, Optional

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

from . import space_crypto as sc
from .spaces import ROLES, SpaceError, Spaces, iso

MAGIC = b"MLBK1\n"
FORMAT = "mindloom-space-backup-v1"
CHUNK = 1024 * 1024
MAX_HEADER = 4096
MAX_FRAME = CHUNK + 16
MAX_MANIFEST = 512 * 1024 * 1024
ORGANIZER_FILES = ("organizer.db", "store.keyid", "store.maskid", "store.epoch")

# spaces.db tables a space's backup carries (every row WHERE space_id = ?), in restore order.
SPACE_TABLES = ("members", "devices", "ops", "key_wraps", "epoch_links", "items", "item_keys", "blobs", "invites",
                "join_requests", "takedowns", "proposals", "hidden", "forks", "packages", "matter_leads", "segments",
                "escrow_wraps", "organizer_purges", "snapshot_cites")
ORG_TABLES = ("org_admins", "org_devices", "org_ops")


def _enc_row(row: dict) -> dict:
    return {k: ({"$b64": sc.b64u(bytes(v))} if isinstance(v, (bytes, bytearray, memoryview)) else v)
            for k, v in row.items()}


def _dec_row(row: dict) -> dict:
    return {k: (sc.b64u_decode(v["$b64"]) if isinstance(v, dict) and "$b64" in v else v) for k, v in row.items()}


class _Sealer:
    def __init__(self, key: bytes, header_line: bytes):
        self.aead = ChaCha20Poly1305(key)
        self.hdr = hashlib.sha256(MAGIC + header_line).digest()
        self.counter = 0

    def frame(self, chunk: bytes, final: bool) -> bytes:
        nonce = b"\0\0\0\0" + struct.pack(">Q", self.counter)
        aad = self.hdr + struct.pack(">Q", self.counter) + (b"\1" if final else b"\0")
        self.counter += 1
        ct = self.aead.encrypt(nonce, chunk, aad)
        return struct.pack(">I", len(ct)) + ct


def _record(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack(">Q", len(payload)) + payload


# ---- export -----------------------------------------------------------------------------------------------


def snapshot(spaces: Spaces, organizers: Any, space_id: str, spool: Path) -> dict:
    """Rows, blob files and the organizer store, consistent with each other: taken under the spaces lock (no op,
    purge or upload runs meanwhile); blob files and the store are copied into `spool` (ciphertext)."""
    with spaces._lock:
        space = spaces.space(space_id)
        tables = {t: [_enc_row(r) for r in spaces.all(f"SELECT * FROM {t} WHERE space_id=?", (space_id,))]
                  for t in SPACE_TABLES}
        tables["audit"] = [_enc_row(r) for r in spaces.all("SELECT * FROM audit WHERE space_id=? ORDER BY id",
                                                           (space_id,))]
        org = None
        if space["org_id"]:
            org = {"orgs": [_enc_row(r) for r in spaces.all("SELECT * FROM orgs WHERE org_id=?", (space["org_id"],))]}
            for t in ORG_TABLES:
                org[t] = [_enc_row(r) for r in spaces.all(f"SELECT * FROM {t} WHERE org_id=?", (space["org_id"],))]
        blob_dir = spool / "blobs"
        blob_dir.mkdir(mode=0o700)
        blobs = []
        for b in spaces.all("SELECT blob_id, sha256 FROM blobs WHERE space_id=? AND status!='deleted' ORDER BY blob_id",
                            (space_id,)):
            src = spaces.blob_path(space_id, b["blob_id"])
            if src.exists():
                shutil.copyfile(src, blob_dir / b["blob_id"])
                blobs.append(b["blob_id"])
        files = []
        d = spaces.space_dir(space_id)
        org_inst = organizers._orgs.get(space_id) if organizers is not None else None
        store_lock = org_inst.store._lock if org_inst is not None else None
        with (store_lock if store_lock is not None else _nolock()):
            if org_inst is not None and not org_inst.store.locked:
                org_inst.store.checkpoint()
            for name in ORGANIZER_FILES:
                if (d / name).is_file():
                    shutil.copyfile(d / name, spool / name)
                    files.append(name)
        row = {k: v for k, v in space.items()}
        row["policy"] = json.dumps(space["policy"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return {"v": 1, "space": _enc_row(row), "tables": tables, "org": org, "blobs": blobs, "files": files}


@contextmanager
def _nolock():
    yield


def export_stream(spaces: Spaces, organizers: Any, space_id: str, key: bytes, backup_id: str, epoch: int,
                  now: float) -> Iterator[bytes]:
    """The whole MLBK1 stream, chunk by chunk. The spool (ciphertext copies) is deleted when the stream ends."""
    spool = Path(tempfile.mkdtemp(prefix=".backup-", dir=spaces.root))
    os.chmod(spool, 0o700)
    try:
        manifest = snapshot(spaces, organizers, space_id, spool)
        header = {"v": 1, "format": FORMAT, "backup_id": backup_id, "space_id": space_id, "epoch": epoch,
                  "created_at": iso(now), "chunk": CHUNK}
        header_line = json.dumps(header, separators=(",", ":"), sort_keys=True).encode() + b"\n"
        sealer = _Sealer(key, header_line)
    except BaseException:
        shutil.rmtree(spool, ignore_errors=True)
        raise

    def plaintext() -> Iterator[bytes]:
        yield _record(b"M", json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        for blob_id in manifest["blobs"]:
            data = (spool / "blobs" / blob_id).read_bytes()
            yield _record(b"B", blob_id.encode("ascii") + data)
        for name in manifest["files"]:
            data = (spool / name).read_bytes()
            yield _record(b"F", bytes([len(name)]) + name.encode("ascii") + data)
        yield _record(b"E", json.dumps({"blobs": len(manifest["blobs"]), "files": len(manifest["files"])}).encode())

    def frames() -> Iterator[bytes]:
        try:
            yield MAGIC + header_line
            buf = bytearray()
            for piece in plaintext():
                buf += piece
                while len(buf) > CHUNK:
                    yield sealer.frame(bytes(buf[:CHUNK]), False)
                    del buf[:CHUNK]
            yield sealer.frame(bytes(buf), True)
        finally:
            shutil.rmtree(spool, ignore_errors=True)
    return frames()


# ---- reading a backup ----------------------------------------------------------------------------------------


class BadBackup(SpaceError):
    def __init__(self, detail: str):
        super().__init__(422, "bad_backup", detail)


def read_header(fh: BinaryIO) -> tuple[dict, bytes]:
    if fh.read(len(MAGIC)) != MAGIC:
        raise BadBackup("not an MLBK1 backup")
    line = fh.readline(MAX_HEADER)
    if not line.endswith(b"\n"):
        raise BadBackup("header too long")
    try:
        header = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise BadBackup("header is not JSON") from None
    if not isinstance(header, dict) or header.get("v") != 1 or header.get("format") != FORMAT or \
            not sc.is_uuid(header.get("space_id")) or not sc.is_uuid(header.get("backup_id")) or \
            not isinstance(header.get("epoch"), int):
        raise BadBackup("unknown header")
    return header, line


def decrypt_records(fh: BinaryIO, key: bytes, header_line: bytes) -> Iterator[tuple[bytes, bytes]]:
    """(type, payload) of each record; raises BadBackup on a wrong key, a changed byte, truncation or extra data."""
    aead = ChaCha20Poly1305(key)
    hdr = hashlib.sha256(MAGIC + header_line).digest()
    counter = 0
    buf = bytearray()
    final = False

    def next_frame() -> Optional[bytes]:
        nonlocal counter, final
        if final:
            if fh.read(1):
                raise BadBackup("data after the final frame")
            return None
        head = fh.read(4)
        if len(head) < 4:
            raise BadBackup("truncated: the final frame is missing")
        (n,) = struct.unpack(">I", head)
        if not 16 <= n <= MAX_FRAME:
            raise BadBackup("bad frame length")
        ct = fh.read(n)
        if len(ct) < n:
            raise BadBackup("truncated frame")
        nonce = b"\0\0\0\0" + struct.pack(">Q", counter)
        for flag in (b"\0", b"\1"):
            try:
                pt = aead.decrypt(nonce, ct, hdr + struct.pack(">Q", counter) + flag)
            except InvalidTag:
                continue
            counter += 1
            final = flag == b"\1"
            return pt
        raise BadBackup("a frame does not open with this key (wrong key or changed bytes)")

    def need(n: int) -> bytes:
        while len(buf) < n:
            chunk = next_frame()
            if chunk is None:
                raise BadBackup("truncated record")
            buf.extend(chunk)
        out = bytes(buf[:n])
        del buf[:n]
        return out

    while True:
        kind = need(1)
        (n,) = struct.unpack(">Q", need(8))
        if kind == b"M" and n > MAX_MANIFEST:
            raise BadBackup("manifest too large")
        payload = need(n)
        yield kind, payload
        if kind == b"E":
            if buf or next_frame() is not None:
                raise BadBackup("data after the end record")
            return


# ---- verifying the logs (the Spark's own replay; it never imports space_member) -----------------------------------


def _payload(raw: bytes) -> Optional[dict]:
    try:
        p = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    return p if isinstance(p, dict) else None


def replay_org(org_ops: list, org_id: Optional[str]) -> dict:
    """The organization as its signed log alone describes it: admins and their state, every org device with its
    keys and state, the policy and the head. Raises BadBackup on an op that is not signed by an active admin
    device of the log itself (from the org.create op on)."""
    admins: dict[str, str] = {}
    devices: dict[str, dict] = {}
    policy: dict = {}
    ops = sorted(org_ops or [], key=lambda r: r["seq"])
    if [r["seq"] for r in ops] != list(range(1, len(ops) + 1)):
        raise BadBackup("the organization's log has gaps")
    for r in ops:
        raw = bytes(r["op"])
        p = _payload(raw)
        if p is None or p.get("org_id") != org_id or p.get("type") != r["type"]:
            raise BadBackup(f"org op {r['seq']} is malformed")
        body = p.get("body") or {}
        if r["seq"] == 1:
            dev = body.get("device") or {}
            if p["type"] != "org.create" or dev.get("device_id") != p.get("device_id") or \
                    not sc.verify(sc.public_key(dev.get("sign_pub")) or b"", sc.OP_DOMAIN + raw, r["sig"]):
                raise BadBackup("the organization's first op does not verify")
            admins[p["member_id"]] = "active"
            devices[dev["device_id"]] = {"member_id": p["member_id"], "sign_pub": dev.get("sign_pub"),
                                         "seal_pub": dev.get("seal_pub"), "status": "active"}
            policy = {"recovery_admins": (body.get("policy") or {}).get("recovery_admins", 1)}
            continue
        signer = devices.get(p.get("device_id"))
        if signer is None or signer["member_id"] != p.get("member_id") or signer["status"] != "active" or \
                admins.get(p.get("member_id")) != "active" or \
                not sc.verify(sc.public_key(signer.get("sign_pub")) or b"", sc.OP_DOMAIN + raw, r["sig"]):
            raise BadBackup(f"org op {r['seq']} is not signed by an admin device")
        if p["type"] == "org.admin_add":
            dev = body.get("device") or {}
            admins[body.get("member_id")] = "active"
            devices[dev.get("device_id")] = {"member_id": body.get("member_id"), "sign_pub": dev.get("sign_pub"),
                                             "seal_pub": dev.get("seal_pub"), "status": "active"}
        elif p["type"] == "org.device_add":       # v8: an admin's own further Mac
            dev = body.get("device") or {}
            devices[dev.get("device_id")] = {"member_id": p.get("member_id"), "sign_pub": dev.get("sign_pub"),
                                             "seal_pub": dev.get("seal_pub"), "status": "active"}
        elif p["type"] == "org.device_remove":
            if body.get("device_id") in devices:
                devices[body["device_id"]]["status"] = "removed"
        elif p["type"] == "org.admin_remove":
            admins[body.get("member_id")] = "removed"
            for d in devices.values():
                if d["member_id"] == body.get("member_id"):
                    d["status"] = "removed"
        elif p["type"] == "org.policy":
            policy = {"recovery_admins": body.get("recovery_admins")}
    return {"admins": admins, "devices": devices, "policy": policy, "head": len(ops)}


def verify_org(org: dict, org_id: str) -> dict:
    """Admin devices per member as the organization's signed log admits them now; raises on a bad op."""
    state = replay_org(org.get("org_ops") or [], org_id)
    out: dict[str, dict] = {}
    for device_id, d in state["devices"].items():
        if d["status"] == "active" and state["admins"].get(d["member_id"]) == "active":
            out.setdefault(d["member_id"], {})[device_id] = {"device_id": device_id, "sign_pub": d["sign_pub"],
                                                              "seal_pub": d["seal_pub"]}
    return out


def check_org_rows(org: dict, org_id: str, state: dict) -> None:
    """A backup's organization rows (written only when this Spark does not know the organization yet) grant
    nothing the organization's signed log does not (review finding V8R-01)."""
    rows = org.get("orgs") or []
    if len(rows) != 1:
        raise BadBackup("the organization row is missing")
    try:
        policy = json.loads(rows[0]["policy"])
    except (TypeError, ValueError):
        raise BadBackup("the organization's policy is not JSON") from None
    if policy != state["policy"] or rows[0].get("head") != state["head"]:
        raise BadBackup("the organization row does not match its signed log")
    for r in org.get("org_admins") or []:
        if r["member_id"] not in state["admins"] or \
                (r["status"] == "active" and state["admins"][r["member_id"]] != "active"):
            raise BadBackup("an org admin row is not in the organization's signed log")
    for r in org.get("org_devices") or []:
        d = state["devices"].get(r["device_id"])
        if d is None or d["member_id"] != r["member_id"] or \
                sc.public_key(d["sign_pub"]) != sc.public_key(r["sign_pub"]) or \
                sc.public_key(d["seal_pub"]) != sc.public_key(r["seal_pub"]) or \
                (r["status"] == "active" and d["status"] != "active"):
            raise BadBackup("an org device row is not in the organization's signed log")


def check_scope(manifest: dict, space_id: str) -> None:
    """Every row of a space's backup belongs to that space, and every organization row to its organization: a
    restore never writes into another space or organization (review finding V8R-01)."""
    for table, rows in manifest["tables"].items():
        if table not in SPACE_TABLES and table != "audit":
            raise BadBackup(f"an unknown table {table}")
        for r in rows:
            if not isinstance(r, dict) or r.get("space_id") != space_id:
                raise BadBackup(f"a {table} row belongs to another space")
    org_id = manifest["space"].get("org_id")
    if manifest.get("org"):
        if not org_id:
            raise BadBackup("organization rows for a space without an organization")
        for table, rows in manifest["org"].items():
            if table != "orgs" and table not in ORG_TABLES:
                raise BadBackup(f"an unknown table {table}")
            for r in rows:
                if not isinstance(r, dict) or r.get("org_id") != org_id:
                    raise BadBackup(f"an {table} row belongs to another organization")


_MISSING = object()


def replay_space(manifest: dict, space_id: str, org_state: Optional[dict]) -> dict:
    """The space as its signed op log alone describes it (genesis, joins, roles, removals, devices, rotations,
    policy, archive): every signed op is signed by a device the log itself admitted (genesis, join.approve,
    device.add, space.recover by an org admin device), every encrypted field matches the hash its op commits to,
    seq runs 1..head. `org_state`: replay_org of the space's organization (this Spark's own log of it when it has
    one, else the backup's)."""
    tables = manifest["tables"]
    org_devices = (org_state or {}).get("devices") or {}
    requests = {r["request_id"]: r for r in tables.get("join_requests") or []}
    invites_table = {r["invite_id"]: r for r in tables.get("invites") or []}
    st: dict = {"owner_kind": None, "owner_member": None, "org_id": None, "policy": {}, "epoch": 1,
                "archived": False, "rotation_pending": False, "members": {}, "devices": {}, "invites": {}}
    ops = sorted(tables["ops"], key=lambda r: r["seq"])
    if [r["seq"] for r in ops] != list(range(1, len(ops) + 1)) or len(ops) != manifest["space"]["head"] or not ops:
        raise BadBackup("the op log has gaps")

    def end(member_id: str, status: str) -> None:
        if member_id in st["members"]:
            st["members"][member_id]["status"] = status
        for d in st["devices"].values():
            if d["member_id"] == member_id:
                d["status"] = status

    for r in ops:
        raw = bytes(r["op"])
        p = _payload(raw)
        if p is None or p.get("space_id") != space_id or p.get("type") != r["type"]:
            raise BadBackup(f"op {r['seq']} is malformed")
        body = p.get("body") or {}
        if r["enc"] is not None and p.get("enc_sha256") != sc.detached_hash(r["enc"]):
            raise BadBackup(f"op {r['seq']}: the encrypted field does not match its hash")
        if r["sig"] is None:
            if r["type"] != "system.remove":
                raise BadBackup(f"op {r['seq']} is unsigned")
            continue
        if r["seq"] == 1:
            dev = body.get("device") or {}
            owner = body.get("owner") or {}
            if r["type"] != "space.create" or dev.get("device_id") != p.get("device_id") or \
                    not sc.verify(sc.public_key(dev.get("sign_pub")) or b"", sc.OP_DOMAIN + raw, r["sig"]):
                raise BadBackup("the genesis op does not verify")
            st["owner_kind"] = owner.get("kind")
            if st["owner_kind"] == "org":
                st["org_id"] = owner.get("org_id")
                od = org_devices.get(dev["device_id"])
                if od is None or od["member_id"] != p.get("member_id") or \
                        sc.public_key(od["sign_pub"]) != sc.public_key(dev.get("sign_pub")):
                    raise BadBackup("the org space was not created by a device of its organization's admins")
            elif st["owner_kind"] == "person":
                st["owner_member"] = p.get("member_id")
            else:
                raise BadBackup("the genesis op names no owner")
            st["policy"] = dict(body.get("policy") or {})
            st["members"][p["member_id"]] = {"role": "admin", "outside": 0, "status": "active"}
            st["devices"][dev["device_id"]] = {"member_id": p["member_id"], "sign_pub": dev.get("sign_pub"),
                                               "seal_pub": dev.get("seal_pub"), "status": "active"}
            continue
        if r["type"] == "space.recover":
            od = org_devices.get(p.get("device_id"))
            admins = (org_state or {}).get("admins") or {}
            if od is None or od["member_id"] != p.get("member_id") or admins.get(od["member_id"]) is None or \
                    not sc.verify(sc.public_key(od.get("sign_pub")) or b"", sc.OP_DOMAIN + raw, r["sig"]):
                raise BadBackup(f"op {r['seq']}: space.recover is not signed by an org admin device")
            m = st["members"].setdefault(od["member_id"], {"role": "admin", "outside": 0, "status": "active"})
            m.update(role="admin", status="active")
            st["devices"][p["device_id"]] = {"member_id": od["member_id"], "sign_pub": od["sign_pub"],
                                             "seal_pub": od["seal_pub"], "status": "active"}
            continue
        signer = st["devices"].get(p.get("device_id"))
        if signer is None or signer["member_id"] != p.get("member_id") or \
                not sc.verify(sc.public_key(signer["sign_pub"]) or b"", sc.OP_DOMAIN + raw, r["sig"]):
            raise BadBackup(f"op {r['seq']} ({r['type']}) is not signed by a device the log admitted")
        t = r["type"]
        if t == "invite.create":
            st["invites"][body.get("invite_id")] = {"role": body.get("role", "write"),
                                                    "outside": 1 if body.get("outside") else 0}
        elif t == "join.approve":
            dev = body.get("device") or {}
            req = requests.get(body.get("request_id")) or {}
            inv = st["invites"].get(req.get("invite_id")) or invites_table.get(req.get("invite_id")) or {}
            role = body.get("role") or inv.get("role") or "write"
            m = st["members"].get(body.get("member_id"))
            if m is None:
                st["members"][body.get("member_id")] = {"role": role, "outside": int(inv.get("outside") or 0),
                                                        "status": "active"}
            elif m["status"] != "active":
                m.update(role=role, status="active")
            st["devices"][dev.get("device_id")] = {"member_id": body.get("member_id"), "sign_pub": dev.get("sign_pub"),
                                                   "seal_pub": dev.get("seal_pub"), "status": "active"}
        elif t == "member.role":
            if body.get("member_id") in st["members"]:
                st["members"][body["member_id"]]["role"] = body.get("role")
        elif t == "member.remove":
            end(body.get("member_id"), "removed")
            st["epoch"] += 1
            st["rotation_pending"] = False
        elif t == "member.leave":
            end(p.get("member_id"), "left")
            st["rotation_pending"] = True
        elif t == "epoch.rotate":
            st["epoch"] += 1
            st["rotation_pending"] = False
        elif t == "device.add":
            dev = body.get("device") or {}
            st["devices"][dev.get("device_id")] = {"member_id": p["member_id"], "sign_pub": dev.get("sign_pub"),
                                                   "seal_pub": dev.get("seal_pub"), "status": "active"}
        elif t == "device.remove":
            if body.get("device_id") in st["devices"]:
                st["devices"][body["device_id"]]["status"] = "removed"
            st["epoch"] += 1
            st["rotation_pending"] = False
        elif t == "space.policy":
            st["policy"].update(body.get("policy") or {})
        elif t == "space.archive":
            st["archived"] = bool(body.get("archived"))
    return st


def check_space_rows(manifest: dict, space_id: str, st: dict) -> None:
    """The rows that decide who may do what (the space row, members, devices, key wraps) grant nothing the signed
    log does not: a restore can neither add a member or a device, raise a role, bring back someone removed, nor
    change the policy, the owner or the epoch (review finding V8R-01). Rows may be stricter than the log (an org
    admin removed from the organization is demoted in its spaces by the Spark itself)."""
    from .spaces import DEFAULT_POLICY
    space, tables = manifest["space"], manifest["tables"]
    if space.get("owner_kind") != st["owner_kind"] or space.get("org_id") != st["org_id"] or \
            space.get("owner_member") != st["owner_member"]:
        raise BadBackup("the space row's owner does not match the genesis op")
    try:
        policy = json.loads(space["policy"]) if isinstance(space["policy"], str) else dict(space["policy"])
    except (TypeError, ValueError):
        raise BadBackup("the space's policy is not JSON") from None
    defaults = DEFAULT_POLICY.get(st["owner_kind"], {})
    for key, value in policy.items():
        want = st["policy"].get(key, defaults.get(key, _MISSING))
        if want is _MISSING or value != want:
            raise BadBackup(f"the space's policy ({key}) is not what its signed log set")
    for key, value in st["policy"].items():
        if policy.get(key, _MISSING) != value:
            raise BadBackup(f"the space's policy ({key}) is not what its signed log set")
    if space.get("epoch") != st["epoch"] or bool(space.get("archived")) != st["archived"] or \
            (st["rotation_pending"] and not space.get("rotation_pending")):
        raise BadBackup("the space row's epoch or state does not match its signed log")
    for r in tables["members"]:
        m = st["members"].get(r["member_id"])
        if m is None or r.get("role") not in ROLES or int(r.get("outside") or 0) < m["outside"] or \
                (r["status"] == "active" and (m["status"] != "active" or ROLES[r["role"]] > ROLES.get(m["role"], 0))):
            raise BadBackup("a member row is not in the signed log")
    for d in tables["devices"]:
        a = st["devices"].get(d["device_id"])
        if a is None or a["member_id"] != d["member_id"] or sc.public_key(a["sign_pub"]) != sc.public_key(d["sign_pub"]) \
                or sc.public_key(a["seal_pub"]) != sc.public_key(d["seal_pub"]) or \
                (d["status"] == "active" and a["status"] != "active"):
            raise BadBackup("a device row is not in the signed log")
    for w in tables.get("key_wraps") or []:
        if w["device_id"] not in st["devices"] or not 1 <= int(w["epoch"]) <= st["epoch"]:
            raise BadBackup("a key wrap of a device the signed log never admitted")


def verify_space(manifest: dict, space_id: str, org_state: Optional[dict] = None) -> dict:
    """check_scope + replay_space + check_space_rows (+ the organization's rows when the backup carries them and
    no org_state from this Spark is given). Returns the replayed state."""
    check_scope(manifest, space_id)
    if org_state is None and manifest.get("org"):
        org_id = manifest["space"].get("org_id")
        org_state = replay_org(manifest["org"].get("org_ops") or [], org_id)
        check_org_rows(manifest["org"], org_id, org_state)
    st = replay_space(manifest, space_id, org_state)
    check_space_rows(manifest, space_id, st)
    for w in manifest["tables"].get("escrow_wraps") or []:
        if w["device_id"] not in ((org_state or {}).get("devices") or {}):
            raise BadBackup("an escrow wrap of a device that is not the organization's")
    return st


# ---- restore ------------------------------------------------------------------------------------------------


def _columns(spaces: Spaces, table: str) -> list[str]:
    return [r["name"] for r in spaces.all(f"PRAGMA table_info({table})")]


def _insert(spaces: Spaces, table: str, row: dict) -> None:
    cols = [c for c in _columns(spaces, table) if c in row and not (table == "audit" and c == "id")]
    spaces.x(f"INSERT INTO {table}({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
             [row[c] for c in cols])


def check_restorer(spaces: Spaces, space_id: str, member: Optional[dict]) -> Optional[dict]:
    """Who may restore, decided before anything is read (review finding V8R-10): the Spark owner (member None), or
    a member through the gate who is an admin of that space on this Spark now; a member never restores a space this
    Spark does not have. Returns the existing space row (None: the space is not here)."""
    existing = spaces.one("SELECT * FROM spaces WHERE space_id=?", (space_id,)) if sc.is_uuid(space_id) else None
    if member is not None:
        ok = False
        if existing is not None:
            space = spaces.space(space_id)
            m = spaces.member(space_id, member["member_id"])
            dev = spaces.one("SELECT * FROM devices WHERE space_id=? AND device_id=? AND status='active'",
                             (space_id, member["device_id"]))
            ok = m is not None and dev is not None and spaces.effective_role(space, m, dev) == ROLES["admin"]
        if not ok:
            raise SpaceError(403, "forbidden", "a space is restored by the Spark's owner or by one of its admins")
    return existing


def log_relation(spaces: Spaces, space_id: str, ops: list) -> str:
    """How a backup's op log stands to this Spark's log of the same space: "equal", "current_newer" (the backup's
    log is a prefix of this Spark's), "backup_newer" (this Spark's log is a prefix of the backup's: it lost its
    tail) or "diverged"."""
    cur = spaces.all("SELECT seq, op, sig FROM ops WHERE space_id=? ORDER BY seq", (space_id,))
    bk = sorted(ops, key=lambda r: r["seq"])
    n = min(len(cur), len(bk))
    for i in range(n):
        if bytes(cur[i]["op"]) != bytes(bk[i]["op"]) or cur[i]["sig"] != bk[i]["sig"]:
            return "diverged"
    if len(cur) == len(bk):
        return "equal"
    return "current_newer" if len(cur) > len(bk) else "backup_newer"


def restore(spaces: Spaces, organizers: Any, space_id: str, source: Path, key: bytes, *, mode: str = "new",
            purge: Optional[list] = None, member: Optional[dict] = None, force: bool = False) -> dict:
    """Restore a space from an MLBK1 file at `source` (the request body, spooled). `member`: the access record of
    a member coming through the gate (None: the Spark owner).

    The signed op log decides (review findings V8R-01, V8R-03):
      * every row of the backup must belong to this space (and its organization), and the rows that grant
        anything (the space row, members, devices, key wraps; the organization's rows) must be what the signed log
        grants, never more;
      * when this Spark has the space and its log already holds the backup's log (equal, or longer: a backup made
        before later removals, rotations, withdrawals), the Spark's log and every row stay as they are; only the
        damaged or missing data comes back from the backup (ciphertext blobs of items still there, a missing
        organizer store with the purges since queued), so a restore never brings back a removed member or an older
        key;
      * when this Spark's log is a prefix of the backup's (it lost its tail), the backup's rows replace it;
      * logs that diverge are refused (409 log_diverges); the Spark's owner may overwrite with force."""
    if mode not in ("new", "replace"):
        raise SpaceError(400, "bad_request", "mode is new or replace")
    purge = [str(i).lower() for i in (purge or [])]
    if any(not sc.is_uuid(i) for i in purge) or len(purge) > 10000:
        raise SpaceError(400, "bad_request", "purge is a list of item ids")
    if force and member is not None:
        raise SpaceError(403, "forbidden", "only the Spark's owner overwrites a space whose log diverged")
    existing = check_restorer(spaces, space_id, member)
    if existing is not None and mode != "replace":
        raise SpaceError(409, "space_exists", "restore with mode replace to overwrite it")
    spool = Path(tempfile.mkdtemp(prefix=".restore-", dir=spaces.root))
    os.chmod(spool, 0o700)
    try:
        with open(source, "rb") as fh:
            header, line = read_header(fh)
            if header["space_id"] != space_id:
                raise BadBackup("this backup is of another space")
            manifest, blobs, files, ended = None, [], [], False
            for kind, payload in decrypt_records(fh, key, line):
                if kind == b"M" and manifest is None:
                    try:
                        manifest = json.loads(payload.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        raise BadBackup("the manifest is not JSON") from None
                    if not isinstance(manifest, dict) or not isinstance(manifest.get("tables"), dict) or \
                            not isinstance(manifest.get("space"), dict) or \
                            not isinstance(manifest.get("blobs"), list) or not isinstance(manifest.get("files"), list):
                        raise BadBackup("the manifest is not a space backup")
                elif kind == b"B" and manifest is not None:
                    blob_id = payload[:36].decode("ascii", "replace")
                    if not sc.is_uuid(blob_id) or blob_id not in manifest["blobs"] or blob_id in blobs:
                        raise BadBackup("an unexpected blob")
                    (spool / blob_id).write_bytes(payload[36:])
                    blobs.append(blob_id)
                elif kind == b"F" and manifest is not None:
                    name = payload[1:1 + payload[0]].decode("ascii", "replace")
                    if name not in ORGANIZER_FILES or name not in manifest["files"] or name in files:
                        raise BadBackup("an unexpected file")
                    (spool / ("f-" + name)).write_bytes(payload[1 + payload[0]:])
                    files.append(name)
                elif kind == b"E":
                    ended = True
                else:
                    raise BadBackup("records out of order")
        if manifest is None or not ended or sorted(blobs) != sorted(manifest["blobs"]) or \
                sorted(files) != sorted(manifest["files"]):
            raise BadBackup("incomplete")
        try:
            manifest["space"] = _dec_row(manifest["space"])
            manifest["tables"] = {t: [_dec_row(r) for r in rows] for t, rows in manifest["tables"].items()}
            for t in SPACE_TABLES:
                manifest["tables"].setdefault(t, [])
            if manifest.get("org"):
                manifest["org"] = {t: [_dec_row(r) for r in rows] for t, rows in manifest["org"].items()}
        except (AttributeError, TypeError, KeyError):
            raise BadBackup("the manifest's rows are malformed") from None
        if manifest["space"].get("space_id") != space_id:
            raise BadBackup("the manifest is of another space")
        # The organization this Spark already has is checked against its own signed log, never the backup's.
        org_id = manifest["space"].get("org_id")
        known_org = bool(org_id) and spaces.one("SELECT 1 FROM orgs WHERE org_id=?", (org_id,)) is not None
        org_state = replay_org(spaces.all("SELECT * FROM org_ops WHERE org_id=? ORDER BY seq", (org_id,)), org_id) \
            if known_org else None
        try:
            verify_space(manifest, space_id, org_state)
        except (KeyError, TypeError, ValueError) as exc:
            raise BadBackup(f"the manifest's rows are malformed ({type(exc).__name__})") from None
        digests = {b["blob_id"]: b["sha256"] for b in manifest["tables"]["blobs"]}
        for blob_id in blobs:
            if sc.sha256_hex((spool / blob_id).read_bytes()) != digests.get(blob_id):
                raise BadBackup("a blob does not match its digest")
        relation = "new" if existing is None else log_relation(spaces, space_id, manifest["tables"]["ops"])
        if relation == "diverged" and not force:
            raise SpaceError(409, "log_diverges", "this Spark's log of the space is not the backup's log or a"
                             " continuation of it; the Spark's owner may overwrite it (force)")
        if relation in ("equal", "current_newer"):
            return _fill(spaces, organizers, space_id, manifest, spool, blobs, files, header, purge, member, relation)
        return _write(spaces, organizers, space_id, manifest, spool, blobs, files, header, mode, purge, member,
                      existing, relation, known_org)
    finally:
        shutil.rmtree(spool, ignore_errors=True)


def _fill(spaces: Spaces, organizers: Any, space_id: str, manifest: dict, spool: Path, blobs: list[str],
          files: list[str], header: dict, purge: list[str], member: Optional[dict], relation: str) -> dict:
    """This Spark's log already holds the backup's: no row changes. Ciphertext blobs of items still here whose file
    is missing or damaged come back; a missing organizer store comes back with every item no longer active queued
    for its purge (applied by the next lease)."""
    digests = {b["blob_id"]: b["sha256"] for b in manifest["tables"]["blobs"]}
    d = spaces.space_dir(space_id)
    (d / "blobs").mkdir(mode=0o700, parents=True, exist_ok=True)
    restored = 0
    for blob_id in blobs:
        row = spaces.one("SELECT sha256, status FROM blobs WHERE space_id=? AND blob_id=?", (space_id, blob_id))
        if row is None or row["status"] == "deleted" or row["sha256"] != digests.get(blob_id):
            continue  # gone here since the backup (withdrawn, removed, replaced): it stays gone
        path = spaces.blob_path(space_id, blob_id)
        if path.exists() and sc.sha256_hex(path.read_bytes()) == row["sha256"]:
            continue
        os.replace(spool / blob_id, path)
        os.chmod(path, 0o600)
        restored += 1
    store = False
    if "organizer.db" in files and not (d / "organizer.db").exists():
        inst = organizers._orgs.get(space_id) if organizers is not None else None
        if inst is None or inst.store.locked:
            if organizers is not None:
                organizers._orgs.pop(space_id, None)
                organizers._holders.pop(space_id, None)
            for name in ORGANIZER_FILES + ("organizer.db-wal", "organizer.db-shm"):
                if name not in ("store.maskid",) and (d / name).exists():
                    (d / name).unlink()
            for name in files:
                if name == "store.maskid" and (d / name).exists():
                    continue  # the space's mask key id never changes
                os.replace(spool / ("f-" + name), d / name)
                os.chmod(d / name, 0o600)
            with spaces.tx():
                for it in spaces.all("SELECT item_id FROM items WHERE space_id=? AND status!='active'", (space_id,)):
                    spaces.x("INSERT OR REPLACE INTO organizer_purges(space_id, item_id, queued_ts) VALUES (?,?,?)",
                             (space_id, it["item_id"], spaces.now()))
            store = True
    with spaces.tx():
        spaces.audit("space.restore", {"backup_id": header["backup_id"], "ops": len(manifest["tables"]["ops"]),
                                       "blobs": restored, "mode": "fill", "relation": relation},
                     space_id=space_id, member_id=(member or {}).get("member_id"),
                     device_id=(member or {}).get("device_id"))
    purged = _purge_after(spaces, space_id, purge)
    space = spaces.space(space_id)
    return {"ok": True, "space_id": space_id, "backup_id": header["backup_id"], "epoch": space["epoch"],
            "backup_epoch": header["epoch"], "head": space["head"], "ops": len(manifest["tables"]["ops"]),
            "items": len(manifest["tables"]["items"]), "blobs": restored, "organizer_store": store,
            "org": "kept" if space["org_id"] else "none", "purged": purged, "applied": "fill",
            "log": relation}


def _write(spaces: Spaces, organizers: Any, space_id: str, manifest: dict, spool: Path, blobs: list[str],
           files: list[str], header: dict, mode: str, purge: list[str], member: Optional[dict],
           existing: Optional[dict], relation: str, known_org: bool) -> dict:
    tables, org = manifest["tables"], manifest.get("org")
    # One device id, one key and one member across the whole Spark (the other spaces, organizations and the
    # access records).
    for d in tables["devices"]:
        for other in (spaces.one("SELECT sign_pub, member_id FROM devices WHERE device_id=? AND space_id!=? LIMIT 1",
                                 (d["device_id"], space_id)),
                      spaces.one("SELECT sign_pub, member_id FROM org_devices WHERE device_id=? LIMIT 1",
                                 (d["device_id"],))):
            if other is not None and other["sign_pub"] != d["sign_pub"]:
                raise SpaceError(409, "device_key_conflict", "a device of the backup is registered here with another key")
            if other is not None and other["member_id"] != d["member_id"]:
                raise SpaceError(409, "device_member_conflict", "a device of the backup belongs to another member here")
        rec = spaces.directory.device_record(d["device_id"]) if spaces.directory is not None else None
        if rec is not None and rec["member_id"] != d["member_id"]:
            raise SpaceError(409, "device_member_conflict", "a device of the backup belongs to another member here")
    if organizers is not None:
        inst = organizers._orgs.get(space_id)
        if inst is not None and not inst.store.locked:
            inst.lock()
        organizers._orgs.pop(space_id, None)
        organizers._holders.pop(space_id, None)
    d = spaces.space_dir(space_id)
    org_state = "none"
    with spaces.tx():
        if existing is not None:
            for t in SPACE_TABLES:
                spaces.x(f"DELETE FROM {t} WHERE space_id=?", (space_id,))
            spaces.x("DELETE FROM spaces WHERE space_id=?", (space_id,))
        if org:
            org_id = manifest["space"]["org_id"]
            if not known_org:
                for row in org.get("orgs") or []:
                    _insert(spaces, "orgs", row)
                for t in ORG_TABLES:
                    for row in org.get(t) or []:
                        _insert(spaces, t, row)
                org_state = "restored"
            else:
                org_state = "kept"
        _insert(spaces, "spaces", manifest["space"])
        for t in SPACE_TABLES:
            for row in tables[t]:
                _insert(spaces, t, row)
        if existing is None:  # a replaced space keeps its own (longer) audit trail
            for row in tables.get("audit") or []:
                _insert(spaces, "audit", row)
        spaces.audit("space.restore", {"backup_id": header["backup_id"], "ops": len(tables["ops"]),
                                       "blobs": len(blobs), "mode": mode, "relation": relation},
                     space_id=space_id, member_id=(member or {}).get("member_id"),
                     device_id=(member or {}).get("device_id"))
    # Files after the rows: the blob store and the organizer store (and its key-id sidecars) replace what was there.
    if existing is not None and d.exists():
        for name in ORGANIZER_FILES + ("organizer.db-wal", "organizer.db-shm"):
            if (d / name).exists():
                (d / name).unlink()
        if (d / "blobs").exists():
            shutil.rmtree(d / "blobs")
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    (d / "blobs").mkdir(mode=0o700, exist_ok=True)
    for blob_id in blobs:
        os.replace(spool / blob_id, d / "blobs" / blob_id)
        os.chmod(d / "blobs" / blob_id, 0o600)
    for name in files:
        os.replace(spool / ("f-" + name), d / name)
        os.chmod(d / name, 0o600)
    purged = _purge_after(spaces, space_id, purge)
    return {"ok": True, "space_id": space_id, "backup_id": header["backup_id"], "epoch": header["epoch"],
            "backup_epoch": header["epoch"], "head": spaces.space(space_id)["head"], "ops": len(tables["ops"]),
            "items": len(tables["items"]), "blobs": len(blobs), "organizer_store": "organizer.db" in files,
            "org": org_state, "purged": purged, "applied": "full", "log": relation}


def _purge_after(spaces: Spaces, space_id: str, purge: list[str]) -> int:
    """Items the restoring Mac saw withdrawn or removed after the backup: purged again, with a system record."""
    n = 0
    for item_id in purge:
        purges: list[str] = []
        with spaces.tx():
            item = spaces.item(space_id, item_id)
            if item is None or item["status"] != "active":
                continue
            seq = spaces._system_record(space_id, "system.remove", {"item_id": item_id, "reason": "restore"}, item_id)
            spaces.purge_item(space_id, item_id, "removed", None, "restore", seq, purges)
            spaces.audit("system.remove", {"item_id": item_id, "reason": "restore"}, space_id=space_id, seq=seq)
            spaces.cascade_snapshots(space_id, purges)
        spaces._run_purges(space_id, purges)
        n += 1
    return n


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
