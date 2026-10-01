#!/usr/bin/env python3
"""Generate Tests/MindloomLinkTests/Resources/seal_vectors.json for mlseal1.

This is an independent implementation of PHONE-CONTRACT §3 using the Python
`cryptography` package (OpenSSL), so the Swift/CryptoKit implementation is
checked against a second implementation rather than against itself.

    python3 Packages/MindloomLink/Vectors/make_seal_vectors.py

All keys, nonces and texts are synthetic and fixed. Never reuse them.
"""

import base64
import hashlib
import json
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PREFIX = "mlseal1."
INFO = b"mindloom-inbox-seal-v1"
AAD_PREFIX = "mindloom-inbox-v1|"
OUT = Path(__file__).resolve().parent.parent / "Tests/MindloomLinkTests/Resources/seal_vectors.json"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def raw_public(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def fixed(label: str, n: int) -> bytes:
    """Deterministic synthetic bytes, reproducible from the label."""
    return hashlib.sha256(("mindloom-test-vector:" + label).encode()).digest()[:n]


def seal_bytes(plaintext: bytes, entry_id: str, mac_pub: bytes, eph_priv: bytes, nonce: bytes) -> bytes:
    eph = X25519PrivateKey.from_private_bytes(eph_priv)
    eph_pub = raw_public(eph)
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey

    shared = eph.exchange(X25519PublicKey.from_public_bytes(mac_pub))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=eph_pub + mac_pub, info=INFO).derive(shared)
    box = ChaCha20Poly1305(key).encrypt(nonce, plaintext, (AAD_PREFIX + entry_id).encode())
    return eph_pub + nonce + box


def open_bytes(sealed: bytes, entry_id: str, mac_priv: bytes) -> bytes:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey

    mac = X25519PrivateKey.from_private_bytes(mac_priv)
    eph_pub, nonce, box = sealed[:32], sealed[32:44], sealed[44:]
    shared = mac.exchange(X25519PublicKey.from_public_bytes(eph_pub))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=eph_pub + raw_public(mac), info=INFO).derive(shared)
    return ChaCha20Poly1305(key).decrypt(nonce, box, (AAD_PREFIX + entry_id).encode())


def payload(obj: dict) -> bytes:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def tiny_png() -> bytes:
    """A valid 1x1 PNG built here, so the vector carries no real image."""
    import struct
    import zlib

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    pixels = zlib.compress(b"\x00\xd9\x8a\x4b\xff")
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


TINY_PNG = tiny_png()

CASES = [
    {
        "name": "text-keyboard",
        "entry_id": "5b0d7c1e-2f4a-4c61-9d3e-8a7b6c5d4e3f",
        "plaintext": payload({
            "v": 1, "kind": "text", "source": "iPhone 键盘",
            "created_at": "2026-09-30T09:15:02.345+08:00",
            "text": "明天下午三点和王老师对一下实验方案（测试向量，合成数据）",
        }),
    },
    {
        "name": "link-share",
        "entry_id": "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0",
        "plaintext": payload({
            "v": 1, "kind": "link", "source": "iPhone 分享",
            "created_at": "2026-09-30T21:04:59.000+08:00",
            "url": "https://example.com/notes?id=42", "title": "示例链接（合成）",
        }),
    },
    {
        "name": "image-share",
        "entry_id": "c0ffee00-1234-4abc-8def-001122334455",
        "plaintext": payload({
            "v": 1, "kind": "image", "source": "iPhone 分享",
            "created_at": "2026-09-30T12:00:00.000-07:00",
            "mime": "image/png", "bytes_b64": base64.b64encode(TINY_PNG).decode(),
        }),
    },
    {
        "name": "long-multiblock",
        "entry_id": "11111111-2222-4333-8444-555555555555",
        "plaintext": ("织机测试向量 synthetic block. " * 60).encode(),
    },
    {
        "name": "empty-plaintext",
        "entry_id": "00000000-0000-4000-8000-000000000000",
        "plaintext": b"",
    },
]


def main() -> None:
    vectors = []
    failures = []
    for index, case in enumerate(CASES):
        mac_priv = fixed(f"mac_priv:{index}", 32)
        eph_priv = fixed(f"eph_priv:{index}", 32)
        nonce = fixed(f"nonce:{index}", 12)
        mac_pub = raw_public(X25519PrivateKey.from_private_bytes(mac_priv))
        eph_pub = raw_public(X25519PrivateKey.from_private_bytes(eph_priv))
        sealed = seal_bytes(case["plaintext"], case["entry_id"], mac_pub, eph_priv, nonce)
        assert open_bytes(sealed, case["entry_id"], mac_priv) == case["plaintext"]
        wire = PREFIX + b64url(sealed)
        vectors.append({
            "name": case["name"],
            "entry_id": case["entry_id"],
            "mac_priv_hex": mac_priv.hex(),
            "mac_pub_hex": mac_pub.hex(),
            "eph_priv_hex": eph_priv.hex(),
            "eph_pub_hex": eph_pub.hex(),
            "nonce_hex": nonce.hex(),
            "plaintext_hex": case["plaintext"].hex(),
            "wire": wire,
        })

        name = case["name"]
        failures.append({"name": f"{name}/wrong-key", "vector": name, "entry_id": case["entry_id"],
                         "mac_priv_hex": fixed(f"other_mac_priv:{index}", 32).hex(), "wire": wire,
                         "expect": "open_failed"})
        failures.append({"name": f"{name}/wrong-entry-id", "vector": name,
                         "entry_id": "ffffffff-ffff-4fff-8fff-ffffffffffff", "mac_priv_hex": mac_priv.hex(),
                         "wire": wire, "expect": "open_failed"})
        # Flip one bit in each region: ephemeral key, nonce, ciphertext (if any), tag.
        regions = {"eph-pub": 5, "nonce": 32 + 3, "tag": len(sealed) - 2}
        if len(sealed) > 60:
            regions["ciphertext"] = 44 + (len(sealed) - 60) // 2
        for region, offset in regions.items():
            tampered = bytearray(sealed)
            tampered[offset] ^= 0x01
            failures.append({"name": f"{name}/tampered-{region}", "vector": name, "entry_id": case["entry_id"],
                             "mac_priv_hex": mac_priv.hex(), "wire": PREFIX + b64url(bytes(tampered)),
                             "expect": "open_failed"})

    first = vectors[0]
    body = first["wire"][len(PREFIX):]
    # Structural failures, independent of keys.
    failures += [
        {"name": "wrong-prefix", "vector": first["name"], "entry_id": first["entry_id"],
         "mac_priv_hex": first["mac_priv_hex"], "wire": "mlseal2." + body, "expect": "malformed_wire"},
        {"name": "padded-base64", "vector": first["name"], "entry_id": first["entry_id"],
         "mac_priv_hex": first["mac_priv_hex"], "wire": first["wire"] + "=", "expect": "malformed_wire"},
        {"name": "standard-alphabet", "vector": first["name"], "entry_id": first["entry_id"],
         "mac_priv_hex": first["mac_priv_hex"], "wire": PREFIX + body.replace("-", "+").replace("_", "/")
         if ("-" in body or "_" in body) else PREFIX + body + "+", "expect": "malformed_wire"},
        {"name": "too-short", "vector": first["name"], "entry_id": first["entry_id"],
         "mac_priv_hex": first["mac_priv_hex"], "wire": PREFIX + b64url(bytes(59)), "expect": "malformed_wire"},
        {"name": "truncated-tag", "vector": first["name"], "entry_id": first["entry_id"],
         "mac_priv_hex": first["mac_priv_hex"],
         "wire": PREFIX + b64url(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))[:-1]),
         "expect": "open_failed"},
    ]

    document = {
        "format": "mlseal1",
        "contract": "PHONE-CONTRACT §3",
        "generator": "Packages/MindloomLink/Vectors/make_seal_vectors.py (Python cryptography, independent of CryptoKit)",
        "hkdf_info": INFO.decode(),
        "aad_prefix": AAD_PREFIX,
        "note": "Synthetic keys and texts. The fixed ephemeral key and nonce exist only for these vectors.",
        "vectors": vectors,
        "open_failures": failures,
    }
    OUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT} ({len(vectors)} vectors, {len(failures)} open failures)")


if __name__ == "__main__":
    main()
