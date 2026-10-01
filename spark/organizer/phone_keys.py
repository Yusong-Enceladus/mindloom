"""The phone's SSH key on this Spark (phone contract sections 0.4 and 4): one line in ~/.ssh/authorized_keys.

    command="<abs path>/zhiji-inbox gate",restrict ssh-ed25519 AAAA… mindloom-phone:<key id>

The key can then run only `zhiji-inbox gate`, which lets through `add` (sealed or the Shortcut forms) and
`status`, nothing else; `restrict` turns off port, agent and X11 forwarding, the pty and ~/.ssh/rc. A lost
phone can only drop sealed entries into the inbox.

The Mac installs and removes the line over its own SSH connection (never through the gate):

    zhiji-inbox authorize-phone --key-id <id> --pubkey "ssh-ed25519 AAAA… [comment]"
    zhiji-inbox revoke-phone --key-id <id>
    zhiji-inbox list-phones

Rules this module keeps:
- Every other line of authorized_keys is left byte for byte as it was. A line is ours only if it is not a
  comment and its last word is exactly `mindloom-phone:<key id>`.
- authorize is idempotent: the same key id and key again changes nothing; the same key id with a new key
  replaces that one line in place. A key that already appears on any line that is not this phone's is
  refused, so the phone's key can never also match a line without the forced command.
- Writes are atomic (a 0600 temporary file in the same directory, fsync, rename, directory fsync) and
  serialized with a lock file, so a concurrent change or a crash never leaves a half-written file.
- The key id and key text are validated strictly; nothing from them reaches a shell.
"""

from __future__ import annotations

import base64
import binascii
import contextlib
import fcntl
import hashlib
import os
import re
import struct
import tempfile
from pathlib import Path
from typing import Iterator, Optional

MARKER_PREFIX = "mindloom-phone:"
KEY_TYPE = "ssh-ed25519"
# The same rule as the phone's pairing payload (PairingPayload.isValidKeyID): safe as one word anywhere.
KEY_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_COMMENT = re.compile(r"[A-Za-z0-9._:@+=-]{1,128}\Z")
_GATE_PATH = re.compile(r"/[A-Za-z0-9._/+-]{1,1023}\Z")


class Refused(ValueError):
    """Input the command will not act on. `code` is a short machine-readable reason."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def default_authorized_keys() -> Path:
    return Path.home() / ".ssh" / "authorized_keys"


def check_key_id(key_id: Optional[str]) -> str:
    if not isinstance(key_id, str) or KEY_ID.match(key_id) is None:
        raise Refused("bad_key_id", "the key id must be 1-64 of A-Z a-z 0-9 . _ - and start with a letter or digit")
    return key_id


def parse_pubkey(text: Optional[str]) -> tuple[str, str]:
    """`ssh-ed25519 <base64> [comment]` → (type, base64). The blob must be exactly the SSH encoding of an
    ed25519 key (string "ssh-ed25519", string of 32 bytes) in canonical base64. The comment is dropped."""
    words = (text or "").split()
    if len(words) not in (2, 3):
        raise Refused("bad_pubkey", "expected one OpenSSH public key line: ssh-ed25519 AAAA… [comment]")
    ktype, b64 = words[0], words[1]
    if ktype != KEY_TYPE:
        raise Refused("bad_pubkey", "only ssh-ed25519 phone keys are accepted")
    if len(words) == 3 and _COMMENT.match(words[2]) is None:
        raise Refused("bad_pubkey", "the key comment may only use A-Z a-z 0-9 . _ : @ + = -")
    try:
        raw = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        raise Refused("bad_pubkey", "the key is not valid base64") from None
    name = KEY_TYPE.encode()
    expected_head = struct.pack(">I", len(name)) + name + struct.pack(">I", 32)
    if len(raw) != len(expected_head) + 32 or not raw.startswith(expected_head):
        raise Refused("bad_pubkey", "the key is not an ed25519 public key")
    if base64.b64encode(raw).decode() != b64:
        raise Refused("bad_pubkey", "the key's base64 is not canonical")
    return ktype, b64


def fingerprint(b64: str) -> str:
    """The SHA256 fingerprint ssh-keygen -l prints for this key."""
    digest = hashlib.sha256(base64.b64decode(b64)).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def check_gate_path(path: str) -> str:
    """The forced command's program: an absolute path of plain characters (it goes inside command="…"),
    no `..`, and an executable file."""
    if not isinstance(path, str) or _GATE_PATH.match(path) is None or "/../" in path + "/" or "//" in path:
        raise Refused("bad_gate_path", "the gate path must be absolute and use only A-Z a-z 0-9 . _ / + -")
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        raise Refused("bad_gate_path", "the gate program does not exist or is not executable")
    return path


def default_gate_path() -> str:
    """ZHIJI_INBOX_GATE (set by the zhiji-inbox wrapper that ran this, or by an instance's own wrapper), else
    this checkout's spark/zhiji-inbox."""
    env = os.environ.get("ZHIJI_INBOX_GATE", "").strip()
    return env or str(Path(__file__).resolve().parents[1] / "zhiji-inbox")


def phone_line(gate_path: str, ktype: str, b64: str, key_id: str) -> bytes:
    return f'command="{gate_path} gate",restrict {ktype} {b64} {MARKER_PREFIX}{key_id}'.encode()


# ---- authorized_keys file handling ------------------------------------------------------------------


def _marker_of(line: bytes) -> Optional[str]:
    """The key id if this line carries a mindloom-phone marker as its last word (comments never do)."""
    stripped = line.strip()
    if not stripped or stripped.startswith(b"#"):
        return None
    last = stripped.split()[-1]
    if not last.startswith(MARKER_PREFIX.encode()):
        return None
    try:
        return last[len(MARKER_PREFIX):].decode("ascii")
    except UnicodeDecodeError:
        return None


def _read_lines(path: Path) -> list[bytes]:
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return []
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()  # the final newline
    return lines


def _target(path: Path) -> Path:
    """Write through a symlinked authorized_keys to the file it points at (keeping the link)."""
    return Path(os.path.realpath(path))


@contextlib.contextmanager
def _locked(path: Path) -> Iterator[None]:
    directory = path.parent
    if not directory.exists():
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(directory / ".mindloom-phone.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _write_atomic(path: Path, lines: list[bytes]) -> None:
    data = b"".join(line + b"\n" for line in lines)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".authorized_keys.mindloom.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    dfd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def authorize(key_id: str, pubkey: str, *, path: Optional[Path] = None, gate_path: Optional[str] = None) -> dict:
    key_id = check_key_id(key_id)
    ktype, b64 = parse_pubkey(pubkey)
    gate = check_gate_path(gate_path or default_gate_path())
    line = phone_line(gate, ktype, b64, key_id)
    path = _target(path or default_authorized_keys())
    with _locked(path):
        lines = _read_lines(path)
        ours = [i for i, ln in enumerate(lines) if _marker_of(ln) == key_id]
        for i, ln in enumerate(lines):
            if i not in ours and b64.encode() in ln.split():
                raise Refused("key_in_use", "this key is already on another line of authorized_keys")
        if len(ours) == 1 and lines[ours[0]] == line:
            return {"ok": True, "key_id": key_id, "changed": False, "replaced": False,
                    "fingerprint": fingerprint(b64)}
        if ours:
            new = [line if i == ours[0] else ln for i, ln in enumerate(lines) if i == ours[0] or i not in ours]
        else:
            new = lines + [line]
        _write_atomic(path, new)
        return {"ok": True, "key_id": key_id, "changed": True, "replaced": bool(ours), "fingerprint": fingerprint(b64)}


def revoke(key_id: str, *, path: Optional[Path] = None) -> dict:
    key_id = check_key_id(key_id)
    path = _target(path or default_authorized_keys())
    with _locked(path):
        lines = _read_lines(path)
        keep = [ln for ln in lines if _marker_of(ln) != key_id]
        removed = len(lines) - len(keep)
        if removed:
            _write_atomic(path, keep)
    return {"ok": True, "key_id": key_id, "removed": removed}


def list_phones(*, path: Optional[Path] = None) -> dict:
    path = _target(path or default_authorized_keys())
    phones = []
    for ln in _read_lines(path):
        key_id = _marker_of(ln)
        if key_id is None:
            continue
        words = ln.strip().split()
        entry = {"key_id": key_id, "type": None, "fingerprint": None, "gate": None, "restricted": False}
        if len(words) >= 3:
            ktype, b64 = words[-3].decode("ascii", "replace"), words[-2].decode("ascii", "replace")
            options = ln.strip()[: ln.strip().rfind(words[-3])].strip().decode("utf-8", "replace")
            entry["type"] = ktype
            with contextlib.suppress(binascii.Error, ValueError):
                entry["fingerprint"] = fingerprint(b64)
            m = re.fullmatch(r'command="(/[A-Za-z0-9._/+-]+) gate",restrict', options)
            entry["gate"] = m.group(1) if m else None
            entry["restricted"] = m is not None
        phones.append(entry)
    return {"ok": True, "phones": phones}
