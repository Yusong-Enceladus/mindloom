"""Member and enrollment lines in the Spark owner's ~/.ssh/authorized_keys (v8 contract B1, docs/INFRA.md).

Two kinds of line, each tied to one forced command of the gate (organizer/gate.py) and marked by its last word:

    command="<abs>/zhiji-inbox bridge <access id>",restrict ssh-ed25519 AAAA… mindloom-member:<access id>
    command="<abs>/zhiji-inbox enroll <ticket id>",restrict ssh-ed25519 AAAA… mindloom-enroll:<ticket id>

`restrict` turns off port, agent and X11 forwarding, the pty and ~/.ssh/rc; the forced command replaces whatever
the client asks to run. A member key can therefore only run the bridge (HTTP to the organizer's private socket,
member routes only); an enrollment key, which travels inside an invite, can only redeem its own ticket once.

Byte rules (stricter than the phone lines in phone_keys.py):
- Every line that is not ours stays byte for byte as it was, including its line ending (LF or CRLF).
- Adding then removing a line leaves the file byte-identical to what it was before the line was added, also when
  the file did not end with a newline: the newline we had to add to end the last foreign line is recorded
  (`eof_fix`, the SHA-256 of the file before) and taken back at removal when nothing else changed meanwhile.
- An enrollment line is replaced by the member line in place (same position, same line ending), so redeeming an
  invite and unpairing later also restore the bytes from before the invite.
- A key that already appears on another line is refused (the member key must never also match a line without
  the forced command). Writes are atomic and serialized with the phone lines' lock (the same file).
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Iterable, Optional

from .phone_keys import (Refused, _locked, _target, check_gate_path, default_authorized_keys, fingerprint,
                         parse_pubkey)

MEMBER = "mindloom-member:"
ENROLL = "mindloom-enroll:"
KINDS = {MEMBER: "bridge", ENROLL: "enroll"}
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def check_ident(value: object) -> str:
    """Access and ticket ids are lowercase UUIDs: one plain word in authorized_keys and in the forced command."""
    if not isinstance(value, str) or _UUID.match(value) is None:
        raise Refused("bad_id", "an access or ticket id is a lowercase UUID")
    return value


def line_for(prefix: str, ident: str, gate: str, b64: str) -> bytes:
    """The authorized_keys line for a member (prefix MEMBER) or an enrollment ticket (prefix ENROLL)."""
    check_ident(ident)
    check_gate_path(gate)
    return f'command="{gate} {KINDS[prefix]} {ident}",restrict ssh-ed25519 {b64} {prefix}{ident}'.encode()


def _segments(data: bytes) -> list[bytes]:
    """The file as lines, each with its own terminator (the last one may have none)."""
    out, start = [], 0
    while start < len(data):
        end = data.find(b"\n", start)
        if end < 0:
            out.append(data[start:])
            break
        out.append(data[start:end + 1])
        start = end + 1
    return out


def _content(seg: bytes) -> bytes:
    return seg.rstrip(b"\n").rstrip(b"\r")


def _terminator(seg: bytes) -> bytes:
    return seg[len(_content(seg)):]


def marker_of(seg: bytes) -> Optional[tuple[str, str]]:
    """(prefix, id) when this line's last word is one of our markers (comment lines never are)."""
    stripped = _content(seg).strip()
    if not stripped or stripped.startswith(b"#"):
        return None
    last = stripped.split()[-1]
    for prefix in (MEMBER, ENROLL):
        if last.startswith(prefix.encode()):
            try:
                return prefix, last[len(prefix):].decode("ascii")
            except UnicodeDecodeError:
                return None
    return None


def _read(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return b""


def _write(path: Path, data: bytes) -> None:
    import contextlib
    import os
    import tempfile
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


def _key_elsewhere(segs: list[bytes], b64: str, skip: set[int]) -> bool:
    word = b64.encode()
    return any(i not in skip and word in _content(s).split() for i, s in enumerate(segs))


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def add(prefix: str, ident: str, pubkey: str, gate: str, *, path: Optional[Path] = None) -> dict:
    """Install (or keep) the line for `ident`. Idempotent: the same key again changes nothing; a new key for the
    same id replaces that line in place. Returns {"changed", "replaced", "eof_fix", "fingerprint"}; eof_fix is
    set when a final newline had to be added to the file (pass it back to remove())."""
    _, b64 = parse_pubkey(pubkey)
    line = line_for(prefix, ident, gate, b64)
    path = _target(path or default_authorized_keys())
    with _locked(path):
        data = _read(path)
        segs = _segments(data)
        ours = [i for i, s in enumerate(segs) if marker_of(s) == (prefix, ident)]
        if _key_elsewhere(segs, b64, set(ours)):
            raise Refused("key_in_use", "this key is already on another line of authorized_keys")
        if len(ours) == 1 and _content(segs[ours[0]]) == line:
            return {"changed": False, "replaced": False, "eof_fix": None, "fingerprint": fingerprint(b64)}
        eof_fix = None
        if ours:
            first = ours[0]
            new = [line + _terminator(segs[first]) if i == first else s for i, s in enumerate(segs)
                   if i == first or i not in ours]
            out = b"".join(new)
        else:
            if data and not data.endswith(b"\n"):
                eof_fix = _sha(data)
                out = data + b"\n" + line + b"\n"
            else:
                out = data + line + b"\n"
        _write(path, out)
        return {"changed": True, "replaced": bool(ours), "eof_fix": eof_fix, "fingerprint": fingerprint(b64)}


def swap(old: tuple[str, str], new_prefix: str, new_ident: str, pubkey: str, gate: str, *,
         path: Optional[Path] = None) -> dict:
    """Replace the line marked `old` (an enrollment ticket) by the line for (new_prefix, new_ident) in the same
    place with the same line ending. Refused with `no_line` when the old line is gone (ticket revoked or used)."""
    _, b64 = parse_pubkey(pubkey)
    line = line_for(new_prefix, new_ident, gate, b64)
    path = _target(path or default_authorized_keys())
    with _locked(path):
        segs = _segments(_read(path))
        olds = [i for i, s in enumerate(segs) if marker_of(s) == old]
        if not olds:
            raise Refused("no_line", "the ticket's line is not in authorized_keys any more")
        if any(marker_of(s) == (new_prefix, new_ident) for s in segs):
            raise Refused("exists", "that member line is already installed")
        if _key_elsewhere(segs, b64, set()):
            raise Refused("key_in_use", "this key is already on another line of authorized_keys")
        first = olds[0]
        out = b"".join(line + _terminator(segs[first]) if i == first else s for i, s in enumerate(segs)
                       if i == first or i not in olds)
        _write(path, out)
        return {"changed": True, "fingerprint": fingerprint(b64)}


def remove(prefix: str, ident: str, *, eof_fix: Optional[str] | Iterable[str] = None,
           path: Optional[Path] = None) -> dict:
    """Remove every line marked (prefix, ident). With the eof_fix add() returned (or every eof_fix ever recorded,
    so the order lines are removed in does not matter), the final newline an add had to put after the foreign
    content is taken back when what is left is exactly that content plus the newline: the file is then
    byte-identical to before the add."""
    check_ident(ident)
    fixes = {eof_fix} if isinstance(eof_fix, str) else set(eof_fix or ())
    path = _target(path or default_authorized_keys())
    with _locked(path):
        data = _read(path)
        segs = _segments(data)
        keep = [s for s in segs if marker_of(s) != (prefix, ident)]
        removed = len(segs) - len(keep)
        if not removed:
            return {"removed": 0}
        out = b"".join(keep)
        if fixes and out.endswith(b"\n") and _sha(out[:-1]) in fixes:
            out = out[:-1]
        _write(path, out)
        return {"removed": removed}


def listed(*, path: Optional[Path] = None) -> list[dict]:
    """Our lines: kind (member / enroll), id, fingerprint, the gate program and whether the line is restricted
    to exactly that forced command."""
    path = _target(path or default_authorized_keys())
    out = []
    for seg in _segments(_read(path)):
        mark = marker_of(seg)
        if mark is None:
            continue
        prefix, ident = mark
        words = _content(seg).strip().split()
        entry = {"kind": "member" if prefix == MEMBER else "enroll", "id": ident, "fingerprint": None,
                 "gate": None, "restricted": False}
        if len(words) >= 3:
            b64 = words[-2].decode("ascii", "replace")
            try:
                entry["fingerprint"] = fingerprint(b64)
            except Exception:  # noqa: BLE001 (a foreign-looking line: no fingerprint)
                pass
            options = _content(seg).strip()[: _content(seg).strip().rfind(words[-3])].strip().decode("utf-8", "replace")
            m = re.fullmatch(r'command="(/[A-Za-z0-9._/+-]+) (bridge|enroll) ([0-9a-f-]{36})",restrict', options)
            if m and m.group(3) == ident and m.group(2) == KINDS[prefix]:
                entry["gate"], entry["restricted"] = m.group(1), True
        out.append(entry)
    return out
