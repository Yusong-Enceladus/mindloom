"""Shared spaces, Spark side of the crypto (SPACES-CONTRACT section 3): verify and check shapes, never open.

What the Spark does with keys:
  * It verifies Ed25519 signatures of member devices: every op in a space's log, every signed request, every
    join request. A member's action therefore cannot be forged by the Spark or by anyone who only holds the
    link token.
  * It checks the *shape* of every ciphertext it stores (prefix, base64url alphabet, length) and stores it
    byte for byte: space-key wraps (sealed to member devices), epoch links, wrapped item data keys, encrypted
    op fields, join profiles and item blobs. A string that does not have the shape of ciphertext is refused,
    so a client bug cannot put plaintext into the op log by accident.
  * It never holds a space key. The only keys it ever sees are the space organizer's store key and mask key,
    lent by a member Mac for one lease (in memory only, like the v6 library key), both derived one-way from a
    space key: they open the organizer store and tag placeholders, and nothing else.

Wire formats (all binary fields base64url without padding; padding is accepted on input):
  device keys        sign_pub = Ed25519 public key (32 bytes); seal_pub = X25519 public key (32 bytes)
  op signature       Ed25519(sign_priv, "mindloom-space-op-v1\\n" || op_bytes)       op_bytes = the op's UTF-8 JSON
  join signature     Ed25519(sign_priv, "mindloom-space-join-v1\\n" || request_bytes)
  request signature  Ed25519(sign_priv, "mindloom-space-req-v1\\n" METHOD "\\n" target "\\n" date "\\n" nonce "\\n"
                     hex(SHA-256(body)))  target = raw path plus "?" and the raw query when there is one
  space-key wrap     "mlwrap1."  + b64u(eph_pub 32 | nonce 12 | ct 32 | tag 16)       (92 bytes)
  epoch link         "mlelink1." + b64u(nonce 12 | ct 32 | tag 16)                    (60 bytes)
  item data key      "mlikey1."  + b64u(nonce 12 | ct 32 | tag 16)                    (60 bytes)
  encrypted field    "mlenc1."   + b64u(nonce 12 | ct | tag 16)                       (>= 29 bytes)
  join profile       "mlpro1."   + b64u(eph_pub 32 | nonce 12 | ct | tag 16)          (>= 61 bytes)
  item blob          b"MLB1" | nonce 12 | ct | tag 16                                 (raw bytes, >= 33)
The member side (how each is made and opened) is organizer/space_member.py, the reference the Mac follows;
the shared vectors are privacy/space_vectors.json.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import re
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

OP_DOMAIN = b"mindloom-space-op-v1\n"
JOIN_DOMAIN = b"mindloom-space-join-v1\n"
REQ_DOMAIN = "mindloom-space-req-v1"

WRAP_PREFIX = "mlwrap1."
ELINK_PREFIX = "mlelink1."
IKEY_PREFIX = "mlikey1."
ENC_PREFIX = "mlenc1."
PROFILE_PREFIX = "mlpro1."
BLOB_MAGIC = b"MLB1"

WRAP_BYTES = 32 + 12 + 32 + 16
ELINK_BYTES = 12 + 32 + 16
IKEY_BYTES = 12 + 32 + 16
ENC_MIN_BYTES = 12 + 1 + 16
PROFILE_MIN_BYTES = 32 + 12 + 1 + 16
BLOB_MIN_BYTES = len(BLOB_MAGIC) + 12 + 1 + 16

MAX_ENC_BYTES = 256 * 1024          # an encrypted op field (item metadata and text, hints, reasons)
MAX_PROFILE_BYTES = 4 * 1024
MAX_BLOB_BYTES = 36_000_000         # one original (the phone's sealed-entry ceiling)

_B64U = re.compile(r"[A-Za-z0-9_-]*={0,2}\Z")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
HEX64_RE = re.compile(r"[0-9a-f]{64}\Z")
NONCE_RE = re.compile(r"[A-Za-z0-9_-]{16,64}\Z")


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(bytes(data)).decode("ascii").rstrip("=")


def b64u_decode(value: object) -> Optional[bytes]:
    """The bytes of a base64url string (padding optional), or None when it is not one."""
    if not isinstance(value, str) or _B64U.match(value) is None:
        return None
    body = value.rstrip("=")
    if len(body) % 4 == 1:
        return None
    try:
        return base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))
    except (binascii.Error, ValueError):
        return None


def is_uuid(value: object) -> bool:
    """A lowercase UUID string: every id in a space's log (space, op, member, device, invite, blob …)."""
    return isinstance(value, str) and UUID_RE.match(value) is not None


def public_key(value: object) -> Optional[bytes]:
    """A 32-byte public key in base64url, or None."""
    raw = b64u_decode(value)
    return raw if raw is not None and len(raw) == 32 else None


def verify(sign_pub: bytes, message: bytes, signature: object) -> bool:
    """Ed25519 verification of `signature` (base64url, 64 bytes) over `message` with the raw public key."""
    sig = b64u_decode(signature)
    if sig is None or len(sig) != 64 or len(sign_pub) != 32:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(bytes(sign_pub)).verify(sig, message)
        return True
    except (InvalidSignature, ValueError):
        return False


def request_message(method: str, target: str, date: str, nonce: str, body: bytes) -> bytes:
    """The bytes a member device signs for one HTTP request to a space route."""
    digest = hashlib.sha256(body or b"").hexdigest()
    return "\n".join((REQ_DOMAIN, method.upper(), target, date, nonce, digest)).encode("utf-8")


def _shape(value: object, prefix: str, exact: Optional[int] = None, minimum: int = 0,
           maximum: Optional[int] = None) -> Optional[str]:
    if not isinstance(value, str) or not value.startswith(prefix):
        return "not_ciphertext"
    raw = b64u_decode(value[len(prefix):])
    if raw is None:
        return "malformed"
    if exact is not None and len(raw) != exact:
        return "bad_length"
    if len(raw) < minimum:
        return "too_short"
    if maximum is not None and len(raw) > maximum:
        return "too_large"
    return None


def wrap_problem(value: object) -> Optional[str]:
    return _shape(value, WRAP_PREFIX, exact=WRAP_BYTES)


def elink_problem(value: object) -> Optional[str]:
    return _shape(value, ELINK_PREFIX, exact=ELINK_BYTES)


def ikey_problem(value: object) -> Optional[str]:
    return _shape(value, IKEY_PREFIX, exact=IKEY_BYTES)


def enc_problem(value: object) -> Optional[str]:
    return _shape(value, ENC_PREFIX, minimum=ENC_MIN_BYTES, maximum=MAX_ENC_BYTES)


def profile_problem(value: object) -> Optional[str]:
    return _shape(value, PROFILE_PREFIX, minimum=PROFILE_MIN_BYTES, maximum=MAX_PROFILE_BYTES)


def blob_problem(data: bytes) -> Optional[str]:
    if not data.startswith(BLOB_MAGIC):
        return "not_ciphertext"
    if len(data) < BLOB_MIN_BYTES:
        return "too_short"
    if len(data) > MAX_BLOB_BYTES:
        return "too_large"
    return None


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def detached_hash(value: str) -> str:
    """What a signed op commits to for a detached field (enc, wrapped_dk): SHA-256 of its UTF-8 string, hex."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def store_key_id(store_key: bytes) -> str:
    """The id of a space organizer store key (the plaintext sidecar store.keyid): first 16 hex of SHA-256."""
    return hashlib.sha256(b"mindloom-space-store-id-v1" + bytes(store_key)).hexdigest()[:16]


def mask_key_id(mask_key: bytes) -> str:
    """The id of a space mask key (sidecar store.maskid), so a lease with another mask key is refused."""
    return hashlib.sha256(b"mindloom-space-mask-id-v1" + bytes(mask_key)).hexdigest()[:16]


def invite_gate_hash(gate: bytes) -> str:
    """What the Spark keeps of an invite (the invite.create field secret_hash): a hash of the invite's gate token.

    The invite code (Mac to Mac, never through the Spark) carries a one-time secret. A joiner sends only the gate
    token derived from it (space_member.invite_gate) beside the signed request, so the Spark can check that the
    joiner holds the invite and use it up, without ever seeing the secret. The binding of the request to the
    invite is an HMAC under another key derived from the secret (space_member.invite_binding): the Spark stores
    it and the inviting admin's Mac checks it, so whoever runs the Spark cannot bind a device of its own to an
    invite (review finding V7-S9)."""
    return hashlib.sha256(b"mindloom-space-invite-v1" + bytes(gate)).hexdigest()
