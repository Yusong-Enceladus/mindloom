"""Sealed phone entries (`mlseal1`, phone contract sections 3 and 5): what the Spark checks, never opens.

The phone seals every entry to the Mac's X25519 key before it leaves the phone. The Spark only relays the
wire string: it checks the *shape* here (prefix, base64url alphabet, length) so garbage is refused early,
and it stores the string byte for byte. It never decodes, parses or opens it, and it has no key that could.

Sizes follow the phone's reading of "36 MB sealed" (MindloomLink `MindloomSeal`): the sealed binary
`eph_pub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)` is at most 36,000,000 bytes, so the wire string
`"mlseal1." + base64url_nopad(sealed)` is at most 48,000,008 characters.

The entry id is part of the seal's additional authenticated data ("mindloom-inbox-v1|" + entry_id), so the
Spark must keep it exactly as the phone sent it: a lowercase UUID string. An upper-case or otherwise
different id is refused rather than normalized, because a normalized id would no longer open.
"""

from __future__ import annotations

import re
from typing import Optional

PREFIX = "mlseal1."
MAX_SEALED_BYTES = 36_000_000
# eph_pub ‖ nonce ‖ tag around an empty ciphertext: the smallest sealed binary the Mac could open.
MIN_SEALED_BYTES = 32 + 12 + 16


def _b64_chars(n_bytes: int) -> int:
    return (n_bytes * 4 + 2) // 3


MAX_WIRE_CHARS = len(PREFIX) + _b64_chars(MAX_SEALED_BYTES)  # 48,000,008
MIN_WIRE_CHARS = len(PREFIX) + _b64_chars(MIN_SEALED_BYTES)

ENTRY_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
_ALPHABET = re.compile(r"[A-Za-z0-9_-]*\Z")


def is_entry_id(value: Optional[str]) -> bool:
    """A lowercase UUID string, the only form a sealed entry's id (its AAD) can take."""
    return bool(value) and ENTRY_ID.match(value) is not None


def wire_problem(wire: Optional[str]) -> Optional[str]:
    """None if `wire` has the shape of an mlseal1 string, else a short error code. Shape only: the base64url
    body is never decoded."""
    if not isinstance(wire, str) or not wire.startswith(PREFIX):
        return "not_sealed"
    if len(wire) > MAX_WIRE_CHARS:
        return "too_large"
    if len(wire) < MIN_WIRE_CHARS:
        return "too_short"
    body_len = len(wire) - len(PREFIX)
    # unpadded base64 never leaves one character in the last group
    if body_len % 4 == 1 or _ALPHABET.match(wire, len(PREFIX)) is None:
        return "malformed"
    return None
