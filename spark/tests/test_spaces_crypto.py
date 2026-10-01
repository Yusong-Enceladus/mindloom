"""Shared spaces crypto (SPACES-CONTRACT sections 3 and 5 "Crypto"): the shared vectors, wrap/unwrap, epoch links,
item keys and blobs open only with the right key and AAD, the Spark refuses an op whose signature fails, and the
service never imports the member-side module (it never holds a space key). Invented values only."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidTag

from conftest import REPO
from organizer import space_crypto as sc
from organizer import space_member as sm

VECTORS = REPO / "privacy" / "space_vectors.json"
# Changes only together with the file (and the Mac's copy of it).
VECTORS_SHA256 = "4c1c1a181d2521250ddbc264faeb2591e8d02cff48b2e3848100d7fe4d067d1a"


def hx(s: str) -> bytes:
    return bytes.fromhex(s)


@pytest.fixture(scope="module")
def v() -> dict:
    return json.loads(VECTORS.read_text(encoding="utf-8"))


def test_vectors_file_is_pinned():
    assert hashlib.sha256(VECTORS.read_bytes()).hexdigest() == VECTORS_SHA256


def test_vectors_file_is_current():
    import subprocess
    import sys
    r = subprocess.run([sys.executable, str(REPO / "privacy" / "make_space_vectors.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_device_keys(v):
    for d in v["devices"]:
        dev = sm.Device(d["device_id"], hx(d["sign_priv_hex"]), hx(d["seal_priv_hex"]))
        assert sc.b64u(dev.sign_pub) == d["expected_sign_pub_b64u"]
        assert sc.b64u(dev.seal_pub) == d["expected_seal_pub_b64u"]


def _dev(v, device_id):
    d = next(x for x in v["devices"] if x["device_id"] == device_id)
    return sm.Device(d["device_id"], hx(d["sign_priv_hex"]), hx(d["seal_priv_hex"]))


def test_signatures(v):
    a = _dev(v, v["op_signature"]["device_id"])
    op = sc.b64u_decode(v["op_signature"]["op_b64u"])
    assert a.sign(sc.OP_DOMAIN + op) == v["op_signature"]["expected_sig_b64u"]
    assert sc.verify(a.sign_pub, sc.OP_DOMAIN + op, v["op_signature"]["expected_sig_b64u"])
    tampered = op.replace(b"withdraw", b"withdrew")
    assert not sc.verify(a.sign_pub, sc.OP_DOMAIN + tampered, v["op_signature"]["expected_sig_b64u"])
    assert not sc.verify(a.sign_pub, sc.JOIN_DOMAIN + op, v["op_signature"]["expected_sig_b64u"])  # domain bound

    r = v["request_signature"]
    msg = sc.request_message(r["method"], r["target"], r["date"], r["nonce"], sc.b64u_decode(r["body_b64u"]))
    assert sc.b64u(msg) == r["expected_message_b64u"]
    assert a.sign(msg) == r["expected_sig_b64u"]

    j = v["join_signature"]
    b = _dev(v, j["device_id"])
    raw = sc.b64u_decode(j["request_b64u"])
    assert b.sign(sc.JOIN_DOMAIN + raw) == j["expected_sig_b64u"]
    assert not sc.verify(a.sign_pub, sc.JOIN_DOMAIN + raw, j["expected_sig_b64u"])  # another device's key


def test_space_key_wrap(v):
    w = v["space_key_wrap"]
    recipient = hx(w["recipient_seal_priv_hex"])
    b = sm.Device(w["device_id"], bytes(32), recipient)
    out = sm.wrap_space_key(hx(w["space_key_hex"]), b.seal_pub, w["space_id"], w["epoch"], w["device_id"],
                            hx(w["eph_priv_hex"]), hx(w["nonce_hex"]))
    assert out == w["expected"]
    assert sc.wrap_problem(out) is None
    assert sm.unwrap_space_key(out, recipient, w["space_id"], w["epoch"], w["device_id"]) == hx(w["space_key_hex"])
    with pytest.raises(InvalidTag):  # another device's seal key
        sm.unwrap_space_key(out, bytes([0x99]) * 32, w["space_id"], w["epoch"], w["device_id"])
    with pytest.raises(InvalidTag):  # the wrap is bound to its epoch
        sm.unwrap_space_key(out, recipient, w["space_id"], w["epoch"] + 1, w["device_id"])
    raw = bytearray(sc.b64u_decode(out[len(sc.WRAP_PREFIX):]))
    raw[50] ^= 1
    with pytest.raises(InvalidTag):  # a tampered byte
        sm.unwrap_space_key(sc.WRAP_PREFIX + sc.b64u(bytes(raw)), recipient, w["space_id"], w["epoch"], w["device_id"])


def test_epoch_link_item_key_fields_blob_profile(v):
    e = v["epoch_link"]
    link = sm.epoch_link(hx(e["new_key_hex"]), hx(e["prev_key_hex"]), e["space_id"], e["epoch"], hx(e["nonce_hex"]))
    assert link == e["expected"] and sc.elink_problem(link) is None
    assert sm.open_epoch_link(link, hx(e["new_key_hex"]), e["space_id"], e["epoch"]) == hx(e["prev_key_hex"])
    with pytest.raises(InvalidTag):  # only the newer key opens the link
        sm.open_epoch_link(link, hx(e["prev_key_hex"]), e["space_id"], e["epoch"])

    k = v["item_key_wrap"]
    wrapped = sm.wrap_item_key(hx(k["space_key_hex"]), hx(k["data_key_hex"]), k["space_id"], k["epoch"], k["item_id"],
                               hx(k["nonce_hex"]))
    assert wrapped == k["expected"] and sc.ikey_problem(wrapped) is None
    assert sm.unwrap_item_key(wrapped, hx(k["space_key_hex"]), k["space_id"], k["epoch"], k["item_id"]) \
        == hx(k["data_key_hex"])
    with pytest.raises(InvalidTag):  # a key wrapped for one item does not open as another's
        sm.unwrap_item_key(wrapped, hx(k["space_key_hex"]), k["space_id"], k["epoch"],
                           "00000000-0000-4000-8000-000000000000")

    i = v["item_enc"]
    plain = sc.b64u_decode(i["plaintext_b64u"])
    enc = sm.enc_item(hx(i["data_key_hex"]), plain, i["space_id"], i["item_id"], i["revision"], hx(i["nonce_hex"]))
    assert enc == i["expected"] and sc.enc_problem(enc) is None
    assert sm.dec_item(enc, hx(i["data_key_hex"]), i["space_id"], i["item_id"], i["revision"]) == json.loads(plain)
    with pytest.raises(InvalidTag):  # bound to the revision
        sm.dec_item(enc, hx(i["data_key_hex"]), i["space_id"], i["item_id"], i["revision"] + 1)

    o = v["op_enc"]
    plain = sc.b64u_decode(o["plaintext_b64u"])
    enc = sm.enc_op(hx(o["space_key_hex"]), plain, o["space_id"], o["op_id"], hx(o["nonce_hex"]))
    assert enc == o["expected"]
    assert sm.dec_op(enc, hx(o["space_key_hex"]), o["space_id"], o["op_id"]) == json.loads(plain)

    b = v["blob"]
    plain = sc.b64u_decode(b["plaintext_b64u"])
    blob = sm.seal_blob(hx(b["data_key_hex"]), plain, b["space_id"], b["item_id"], b["blob_id"], hx(b["nonce_hex"]))
    assert sc.b64u(blob) == b["expected_b64u"] and sc.blob_problem(blob) is None
    assert sm.open_blob(blob, hx(b["data_key_hex"]), b["space_id"], b["item_id"], b["blob_id"]) == plain

    p = v["join_profile"]
    recipient = hx(p["recipient_seal_priv_hex"])
    pub = sm.Device("x", bytes(32), recipient).seal_pub
    plain = sc.b64u_decode(p["plaintext_b64u"])
    prof = sm.seal_profile(plain, pub, p["space_id"], p["request_id"], hx(p["eph_priv_hex"]), hx(p["nonce_hex"]))
    assert prof == p["expected"] and sc.profile_problem(prof) is None
    assert sm.open_profile(prof, recipient, p["space_id"], p["request_id"]) == json.loads(plain)


def test_derived_keys(v):
    d = v["derived"]
    k1, k2 = hx(d["first_epoch_key_hex"]), hx(d["epoch2_key_hex"])
    assert sm.store_key(k1).hex() == d["expected_store_key_epoch1_hex"]
    assert sm.store_key(k2).hex() == d["expected_store_key_epoch2_hex"]
    assert sm.mask_key(k1).hex() == d["expected_mask_key_hex"]
    assert sc.store_key_id(sm.store_key(k1)) == d["expected_store_key_id_epoch1"]
    assert sc.mask_key_id(sm.mask_key(k1)) == d["expected_mask_key_id"]
    gate = sm.invite_gate(hx(d["invite_secret_hex"]))
    assert gate.hex() == d["expected_invite_gate_hex"]
    assert sc.invite_gate_hash(gate) == d["expected_invite_secret_hash"]
    join_bytes = sc.b64u_decode(v["join_signature"]["request_b64u"])
    assert sm.invite_binding(hx(d["invite_secret_hex"]), join_bytes) == d["expected_invite_binding"]
    assert sc.detached_hash(d["detached_value"]) == d["expected_detached_sha256"]


def test_shape_checks_refuse_plaintext():
    assert sc.enc_problem("标题：周会") == "not_ciphertext"
    assert sc.enc_problem("mlenc1.这不是密文") == "malformed"
    assert sc.enc_problem("mlenc1." + sc.b64u(b"short")) == "too_short"
    assert sc.wrap_problem("mlwrap1." + sc.b64u(bytes(91))) == "bad_length"
    assert sc.blob_problem(b"%PDF-1.7 plaintext") == "not_ciphertext"
    assert sc.blob_problem(b"MLB1" + bytes(10)) == "too_short"
    assert sc.b64u_decode("abc$") is None and sc.b64u_decode("a") is None
    assert sc.b64u_decode("YWJj") == b"abc" and sc.b64u_decode("YWI=") == b"ab"


def test_service_never_imports_the_member_side():
    """The Spark verifies and stores; it never wraps, unwraps or opens. Only the reference module, the vectors
    generator, the tests and the E2E harness use organizer/space_member.py."""
    org = REPO / "spark" / "organizer"
    for p in org.glob("*.py"):
        if p.name == "space_member.py":
            continue
        code = "\n".join(ln for ln in p.read_text(encoding="utf-8").splitlines()
                         if re.match(r"\s*(from\s+[\w.]+\s+import\s|import\s+[\w.]+)", ln))
        if p.name == "backup.py":
            # v8 B4: the backup stream is sealed with a key the admin's Mac lends for one export (like the organizer
            # lease's store key); the Spark still never derives, wraps or unwraps a space key.
            code = code.replace("from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305", "")
        assert not re.search(r"space_member|ChaCha20Poly1305|X25519PrivateKey|Ed25519PrivateKey|aead|hkdf", code), \
            p.name
