"""Link token: a shared secret that the Mac reads over its authenticated SSH connection.

The organizer only listens on loopback, but anything else on the Spark that can reach 127.0.0.1
(other users, other services, a stray tunnel) could otherwise read and write the store. The token
closes that: <data_dir>/link_token holds 64 hex characters from a CSPRNG (mode 0600, no newline),
created on first start and kept across restarts. The Mac fetches it with `ssh <host> cat <path>`
and sends "Authorization: Bearer <token>" on every request. The token is never logged.
"""

from __future__ import annotations

import hmac
import os
import re
import secrets
import stat
from pathlib import Path
from typing import Optional

TOKEN_RE = re.compile(r"[0-9a-f]{64}")


class LinkTokenError(RuntimeError):
    pass


def _read_token(path: Path) -> str:
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise LinkTokenError(f"{path} is not a regular file")
    if st.st_mode & 0o077:
        os.chmod(path, 0o600)
    value = path.read_text(encoding="ascii", errors="replace").strip()
    if not TOKEN_RE.fullmatch(value):
        raise LinkTokenError(f"{path} does not hold a 64-hex-character token; delete it to create a new one")
    return value


def ensure_link_token(path: Path) -> str:
    """Return the token in `path`, creating it (atomically, mode 0600) if it does not exist."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        return _read_token(path)
    except FileNotFoundError:
        pass
    token = secrets.token_hex(32)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, token.encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(tmp, path)  # atomic and never overwrites: a concurrent first start keeps one token
    except FileExistsError:
        return _read_token(path)
    finally:
        os.unlink(tmp)
    return token


def bearer_matches(header: Optional[str], token: str) -> bool:
    """Constant-time check of an Authorization header against the token."""
    if not header:
        return False
    scheme, _, value = header.strip().partition(" ")
    if scheme.lower() != "bearer":
        return False
    return hmac.compare_digest(value.strip().encode("latin-1", "replace"), token.encode("ascii"))
