#!/usr/bin/env python3
"""Build privacy/space_vectors.json: the shared-spaces crypto vectors (SPACES-CONTRACT section 3).

Every key, nonce and id below is fixed and invented, so each output is deterministic (Ed25519 signatures are
deterministic; X25519 and ChaCha20-Poly1305 are given their ephemeral keys and nonces). The Python reference is
spark/organizer/space_member.py (the member side) and spark/organizer/space_crypto.py (what the Spark checks).
The Mac's Swift implementation (CryptoKit: Curve25519.Signing, Curve25519.KeyAgreement, HKDF<SHA256>, ChaChaPoly,
HMAC<SHA256>) must reproduce each "expected" value from the given inputs and open each wire value; a copy of this
file goes with the Mac tests and both suites assert its SHA-256.

    python3 privacy/make_space_vectors.py            # rewrite privacy/space_vectors.json
    python3 privacy/make_space_vectors.py --check    # exit 1 if the file would change
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "spark"))
from organizer import space_crypto as sc  # noqa: E402
from organizer import space_member as sm  # noqa: E402

OUT = os.path.join(HERE, "space_vectors.json")

SPACE_ID = "5b1e7c2a-0d3f-4e6a-9b8c-7d6e5f4a3b21"
DEVICE_A = "a1a1a1a1-0000-4000-8000-00000000000a"
DEVICE_B = "b2b2b2b2-0000-4000-8000-00000000000b"
MEMBER_A = "c3c3c3c3-0000-4000-8000-00000000000a"
ITEM_ID = "d4d4d4d4-0000-4000-8000-000000000001"
BLOB_ID = "e5e5e5e5-0000-4000-8000-000000000001"
OP_ID = "f6f6f6f6-0000-4000-8000-000000000001"
REQUEST_ID = "a7a7a7a7-0000-4000-8000-000000000001"
INVITE_ID = "b8b8b8b8-0000-4000-8000-000000000001"

SIGN_A = bytes(range(0, 32))
SEAL_A = bytes(range(32, 64))
SIGN_B = bytes(range(64, 96))
SEAL_B = bytes(range(96, 128))
K1 = bytes([0x21]) * 32
K2 = bytes([0x22]) * 32
DK = bytes([0x51]) * 32
EPH = bytes([0x31]) * 32
NONCE = bytes([0x41]) * 12
SECRET = bytes([0x61]) * 32


def h(b: bytes) -> str:
    return b.hex()


def u(b: bytes) -> str:
    return sc.b64u(b)


def build() -> dict:
    a = sm.Device(DEVICE_A, SIGN_A, SEAL_A)
    b = sm.Device(DEVICE_B, SIGN_B, SEAL_B)
    op_json = ('{"v":1,"space_id":"' + SPACE_ID + '","op_id":"' + OP_ID + '","type":"item.withdraw","member_id":"'
               + MEMBER_A + '","device_id":"' + DEVICE_A + '","created_at":"2026-09-30T08:00:00+00:00",'
               '"body":{"item_id":"' + ITEM_ID + '"}}').encode()
    target = "/v1/spaces/" + SPACE_ID + "/ops?since=0&limit=200"
    req_msg = sc.request_message("GET", target, "1790000000", "bm9uY2Utbm9uY2Utbm9uY2U", b"")
    join_json = ('{"v":1,"space_id":"' + SPACE_ID + '","invite_id":"' + INVITE_ID + '","request_id":"' + REQUEST_ID
                 + '","member_id":"' + MEMBER_A + '","device":{"device_id":"' + DEVICE_B + '","sign_pub":"'
                 + u(b.sign_pub) + '","seal_pub":"' + u(b.seal_pub) + '"},"created_at":"2026-09-30T08:00:00+00:00"}'
                 ).encode()
    item_plain = '{"title":"周会纪要","text":"哨兵：电话 13800138000","revision":3}'.encode()
    op_plain = '{"name":"实验室·SkillKnit"}'.encode()
    profile_plain = '{"display_name":"韩策"}'.encode()
    blob_plain = b"%PDF-1.7 synthetic original bytes"
    return {
        "note": "Shared-spaces crypto vectors (SPACES-CONTRACT section 3). All values invented. hex = lowercase hex,"
                " b64u = base64url without padding. See privacy/make_space_vectors.py.",
        "devices": [
            {"device_id": DEVICE_A, "sign_priv_hex": h(SIGN_A), "seal_priv_hex": h(SEAL_A),
             "expected_sign_pub_b64u": u(a.sign_pub), "expected_seal_pub_b64u": u(a.seal_pub)},
            {"device_id": DEVICE_B, "sign_priv_hex": h(SIGN_B), "seal_priv_hex": h(SEAL_B),
             "expected_sign_pub_b64u": u(b.sign_pub), "expected_seal_pub_b64u": u(b.seal_pub)},
        ],
        "op_signature": {"device_id": DEVICE_A, "domain": "mindloom-space-op-v1\\n",
                         "op_b64u": u(op_json), "expected_sig_b64u": a.sign(sc.OP_DOMAIN + op_json)},
        "request_signature": {"device_id": DEVICE_A, "method": "GET", "target": target, "date": "1790000000",
                              "nonce": "bm9uY2Utbm9uY2Utbm9uY2U", "body_b64u": "",
                              "expected_message_b64u": u(req_msg), "expected_sig_b64u": a.sign(req_msg)},
        "join_signature": {"device_id": DEVICE_B, "domain": "mindloom-space-join-v1\\n", "request_b64u": u(join_json),
                           "expected_sig_b64u": b.sign(sc.JOIN_DOMAIN + join_json)},
        "space_key_wrap": {"space_id": SPACE_ID, "epoch": 1, "device_id": DEVICE_B, "space_key_hex": h(K1),
                           "recipient_seal_priv_hex": h(SEAL_B), "eph_priv_hex": h(EPH), "nonce_hex": h(NONCE),
                           "aad": sm.wrap_aad(SPACE_ID, 1, DEVICE_B).decode(),
                           "expected": sm.wrap_space_key(K1, b.seal_pub, SPACE_ID, 1, DEVICE_B, EPH, NONCE)},
        "epoch_link": {"space_id": SPACE_ID, "epoch": 2, "new_key_hex": h(K2), "prev_key_hex": h(K1),
                       "nonce_hex": h(NONCE), "aad": f"mindloom-space-epoch-link-v1|{SPACE_ID}|2",
                       "expected": sm.epoch_link(K2, K1, SPACE_ID, 2, NONCE)},
        "item_key_wrap": {"space_id": SPACE_ID, "epoch": 1, "item_id": ITEM_ID, "space_key_hex": h(K1),
                          "data_key_hex": h(DK), "nonce_hex": h(NONCE),
                          "aad": f"mindloom-space-item-key-v1|{SPACE_ID}|1|{ITEM_ID}",
                          "expected": sm.wrap_item_key(K1, DK, SPACE_ID, 1, ITEM_ID, NONCE)},
        "item_enc": {"space_id": SPACE_ID, "item_id": ITEM_ID, "revision": 3, "data_key_hex": h(DK),
                     "nonce_hex": h(NONCE), "plaintext_b64u": u(item_plain),
                     "aad": f"mindloom-space-item-enc-v1|{SPACE_ID}|{ITEM_ID}|3",
                     "expected": sm.enc_item(DK, item_plain, SPACE_ID, ITEM_ID, 3, NONCE)},
        "op_enc": {"space_id": SPACE_ID, "op_id": OP_ID, "space_key_hex": h(K1), "nonce_hex": h(NONCE),
                   "plaintext_b64u": u(op_plain), "aad": f"mindloom-space-op-enc-v1|{SPACE_ID}|{OP_ID}",
                   "expected": sm.enc_op(K1, op_plain, SPACE_ID, OP_ID, NONCE)},
        "blob": {"space_id": SPACE_ID, "item_id": ITEM_ID, "blob_id": BLOB_ID, "data_key_hex": h(DK),
                 "nonce_hex": h(NONCE), "plaintext_b64u": u(blob_plain),
                 "aad": f"mindloom-space-blob-v1|{SPACE_ID}|{ITEM_ID}|{BLOB_ID}",
                 "expected_b64u": u(sm.seal_blob(DK, blob_plain, SPACE_ID, ITEM_ID, BLOB_ID, NONCE))},
        "join_profile": {"space_id": SPACE_ID, "request_id": REQUEST_ID, "recipient_seal_priv_hex": h(SEAL_A),
                         "eph_priv_hex": h(EPH), "nonce_hex": h(NONCE), "plaintext_b64u": u(profile_plain),
                         "aad": f"mindloom-space-join-profile-v1|{SPACE_ID}|{REQUEST_ID}",
                         "expected": sm.seal_profile(profile_plain, a.seal_pub, SPACE_ID, REQUEST_ID, EPH, NONCE)},
        "derived": {"first_epoch_key_hex": h(K1), "epoch2_key_hex": h(K2),
                    "expected_store_key_epoch1_hex": h(sm.store_key(K1)),
                    "expected_store_key_epoch2_hex": h(sm.store_key(K2)),
                    "expected_mask_key_hex": h(sm.mask_key(K1)),
                    "expected_store_key_id_epoch1": sc.store_key_id(sm.store_key(K1)),
                    "expected_mask_key_id": sc.mask_key_id(sm.mask_key(K1)),
                    "invite_secret_hex": h(SECRET), "expected_invite_gate_hex": h(sm.invite_gate(SECRET)),
                    "expected_invite_secret_hash": sc.invite_gate_hash(sm.invite_gate(SECRET)),
                    "request_id": REQUEST_ID,
                    "invite_binding_note": "HMAC-SHA256(HMAC-SHA256(secret, 'mindloom-space-join-bind-key-v1'),"
                                           " 'mindloom-space-join-bind-v2\\n' || join_signature.request bytes), hex",
                    "expected_invite_binding": sm.invite_binding(SECRET, join_json),
                    "detached_value": "mlenc1.AAAA", "expected_detached_sha256": sc.detached_hash("mlenc1.AAAA")},
    }


def render() -> bytes:
    return (json.dumps(build(), ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def main() -> int:
    data = render()
    if "--check" in sys.argv:
        with open(OUT, "rb") as fh:
            same = fh.read() == data
        print("space_vectors.json", "up to date" if same else "would change")
        return 0 if same else 1
    with open(OUT, "wb") as fh:
        fh.write(data)
    print("wrote", OUT, "sha256", hashlib.sha256(data).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
