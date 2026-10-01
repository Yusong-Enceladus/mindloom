"""Keys of a library (privacy contract section 1).

The Mac creates one `library_key` (32 random bytes) per library and keeps it in its Keychain. It reaches
the Spark only in POST /v1/unlock, over the user's SSH tunnel, and lives here only in process memory:
it is never written to disk and never logged. Everything else is derived from it on the Spark:

  key_id    = lowercase hex of SHA-256("mindloom-key-id-v1" || library_key), first 16 characters
              (the only key-related value on disk: the plaintext sidecar store.keyid, mode 0600)
  store_key = HMAC-SHA256(library_key, "mindloom-store-v1")   SQLCipher raw key of organizer.db
  mask_key  = HMAC-SHA256(library_key, "mindloom-mask-v1")    placeholder tags (organizer/masking.py)
  access    = HMAC-SHA256(library_key, "mindloom-access-v1")  hex in the X-Mindloom-Access header of every
              data request after the Mac's unlock: the link token alone (a file anyone on the Spark account
              can read) does not read the store (review finding F1)

Harnesses on synthetic data (tests, eval runs, the scale runners, ctl.sh unlock-synthetic) unlock with
synthetic_library_key(): a fixed public value, or ORGANIZER_SYNTHETIC_KEY (64 hex characters). Anyone can
derive it, so a store unlocked with it is not private; it is never used for a real library.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
from pathlib import Path
from typing import Optional

KEY_HEX_RE = re.compile(r"[0-9a-fA-F]{64}")
KEY_ID_RE = re.compile(r"[0-9a-f]{16}")

SYNTHETIC_LIBRARY_KEY = hashlib.sha256(b"mindloom-synthetic-library-key-v1").digest()


def derive_keys(library_key: bytes) -> tuple[str, bytes, bytes]:
    """(key_id, store_key, mask_key) of a 32-byte library key."""
    if not isinstance(library_key, (bytes, bytearray)) or len(library_key) != 32:
        raise ValueError("library_key must be 32 bytes")
    library_key = bytes(library_key)
    key_id = hashlib.sha256(b"mindloom-key-id-v1" + library_key).hexdigest()[:16]
    store_key = hmac.new(library_key, b"mindloom-store-v1", hashlib.sha256).digest()
    mask_key = hmac.new(library_key, b"mindloom-mask-v1", hashlib.sha256).digest()
    return key_id, store_key, mask_key


def access_proof(library_key: bytes) -> str:
    """The X-Mindloom-Access header value for a library key (64 hex characters)."""
    if not isinstance(library_key, (bytes, bytearray)) or len(library_key) != 32:
        raise ValueError("library_key must be 32 bytes")
    return hmac.new(bytes(library_key), b"mindloom-access-v1", hashlib.sha256).hexdigest()


def parse_key_hex(value: object) -> Optional[bytes]:
    """The 32-byte library key of a request body's "key", or None when it is not 64 hex characters."""
    if not isinstance(value, str) or not KEY_HEX_RE.fullmatch(value):
        return None
    return bytes.fromhex(value)


def synthetic_library_key() -> bytes:
    """The library key harnesses on synthetic data unlock with (never a real library)."""
    value = os.environ.get("ORGANIZER_SYNTHETIC_KEY", "").strip()
    if value:
        key = parse_key_hex(value)
        if key is None:
            raise ValueError("ORGANIZER_SYNTHETIC_KEY must be 64 hex characters")
        return key
    return SYNTHETIC_LIBRARY_KEY


def read_key_id(path: Path) -> Optional[str]:
    """The key_id in a store.keyid sidecar, or None when there is none (or it is not a key id)."""
    try:
        value = path.read_text(encoding="ascii", errors="replace").strip()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return value if KEY_ID_RE.fullmatch(value) else None


def write_key_id(path: Path, key_id: str) -> None:
    """Write the sidecar atomically with mode 0600."""
    if not KEY_ID_RE.fullmatch(key_id):
        raise ValueError("not a key id")
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, key_id.encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
