"""v8 B1: per-member access (organizer/access_keys.py, access.py, access_api.py, gate.py). Synthetic keys only.

The real sshd enforcing the lines is in test_access_sshd.py; here: the byte rules of authorized_keys, the ticket
and enrollment rules, member scope and the device binding over the HTTP API, and the bridge's HTTP handling
in-process (pipes instead of an SSH session).
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from organizer import access_keys as ak
from organizer import space_crypto as sc
from organizer import space_member as sm
from organizer.access import Access, enroll_request, gate_stamp, read_gate_key, ticket_hash
from organizer.api import create_app
from organizer.gate import Bridge, _Stdio, member_path
from organizer.phone_keys import Refused

from spacekit import Clock, Mac, new_id
from test_phone_link import FOREIGN, ed25519_blob


def ssh_pub(seed: int) -> str:
    return "ssh-ed25519 " + base64.b64encode(ed25519_blob(bytes([seed]) * 32)).decode()


@pytest.fixture
def gate_program(tmp_path) -> str:
    p = tmp_path / "bin" / "zhiji-inbox"
    p.parent.mkdir()
    p.write_text("#!/bin/sh\nexit 0\n")
    p.chmod(0o755)
    return str(p)


# ---- authorized_keys: byte for byte -------------------------------------------------------------------------


@pytest.mark.parametrize("original", [FOREIGN, FOREIGN + b"\n", b"", b"ssh-ed25519 AAAAC3Nz x@y\r\n"],
                         ids=["no-final-newline", "final-newline", "empty", "crlf"])
def test_member_line_add_remove_is_byte_identical(tmp_path, gate_program, original):
    path = tmp_path / "authorized_keys"
    path.write_bytes(original)
    a = new_id()
    out = ak.add(ak.MEMBER, a, ssh_pub(1), gate_program, path=path)
    assert out["changed"] and (out["eof_fix"] is not None) == (original != b"" and not original.endswith(b"\n"))
    text = path.read_bytes()
    assert text.startswith(original) and text.endswith(f" mindloom-member:{a}\n".encode())
    assert f'command="{gate_program} bridge {a}",restrict ssh-ed25519 '.encode() in text
    # idempotent
    inode = path.stat().st_ino
    assert ak.add(ak.MEMBER, a, ssh_pub(1), gate_program, path=path)["changed"] is False
    assert path.stat().st_ino == inode
    assert ak.remove(ak.MEMBER, a, eof_fix=out["eof_fix"], path=path) == {"removed": 1}
    assert path.read_bytes() == original


def test_ticket_swapped_in_place_then_unpaired_restores_the_bytes(tmp_path, gate_program):
    path = tmp_path / "authorized_keys"
    path.write_bytes(FOREIGN)                       # no final newline, CRLF and comment lines inside
    t, a, other = new_id(), new_id(), new_id()
    res = ak.add(ak.ENROLL, t, ssh_pub(1), gate_program, path=path)
    ak.add(ak.MEMBER, other, ssh_pub(2), gate_program, path=path)   # someone enrolled before (after our ticket)
    before_swap = path.read_bytes()
    ak.swap((ak.ENROLL, t), ak.MEMBER, a, ssh_pub(3), gate_program, path=path)
    after = path.read_bytes()
    assert len(after.split(b"\n")) == len(before_swap.split(b"\n"))
    assert after.split(b"\n").index(next(x for x in after.split(b"\n") if x.endswith(a.encode()))) == \
        before_swap.split(b"\n").index(next(x for x in before_swap.split(b"\n") if x.endswith(t.encode())))
    assert ssh_pub(1).split()[1].encode() not in after          # the invite key is gone
    ak.remove(ak.MEMBER, other, path=path)
    ak.remove(ak.MEMBER, a, eof_fix=res["eof_fix"], path=path)
    assert path.read_bytes() == FOREIGN
    with pytest.raises(Refused) as e:
        ak.swap((ak.ENROLL, t), ak.MEMBER, new_id(), ssh_pub(4), gate_program, path=path)
    assert e.value.code == "no_line"


def test_a_key_on_another_line_and_bad_ids_are_refused(tmp_path, gate_program):
    path = tmp_path / "authorized_keys"
    path.write_bytes(ssh_pub(5).encode() + b" someone\n")
    with pytest.raises(Refused) as e:
        ak.add(ak.MEMBER, new_id(), ssh_pub(5), gate_program, path=path)
    assert e.value.code == "key_in_use"
    for bad in ("A" * 36, "x", new_id().upper(), "../x", "a b"):
        with pytest.raises(Refused):
            ak.add(ak.MEMBER, bad, ssh_pub(6), gate_program, path=path)
    a = new_id()
    ak.add(ak.MEMBER, a, ssh_pub(6), gate_program, path=path)
    listed = ak.listed(path=path)
    assert listed == [{"kind": "member", "id": a, "fingerprint": listed[0]["fingerprint"], "gate": gate_program,
                       "restricted": True}]


# ---- the API: tickets, enrollment, member scope ----------------------------------------------------------------


@pytest.fixture
def rig(tmp_path, settings, org, gate_program):
    settings.authorized_keys = tmp_path / "home" / ".ssh" / "authorized_keys"
    settings.authorized_keys.parent.mkdir(parents=True)
    settings.authorized_keys.write_bytes(FOREIGN)
    settings.gate_path = gate_program
    clock = Clock()
    from organizer.spaces import Spaces
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [])
    app = create_app(settings, organizer=org, spaces=spaces)
    app.state.access.now = clock
    owner = TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"})
    bare = TestClient(app)
    with owner, bare:
        yield {"app": app, "owner": owner, "bare": bare, "clock": clock, "ak": settings.authorized_keys,
               "access": app.state.access, "spaces": spaces}


def expires(clock: Clock, hours: float = 48) -> str:
    return datetime.fromtimestamp(clock() + hours * 3600, timezone.utc).isoformat()


def make_ticket(rig, client=None, kind: str = "member", seed: int = 40, **extra):
    secret = secrets.token_bytes(32)
    ticket_id = new_id()
    body = {"ticket_id": ticket_id, "kind": kind, "ssh_key": ssh_pub(seed), "secret_hash": ticket_hash(secret),
            "expires_at": expires(rig["clock"]), **extra}
    r = (client or rig["owner"]).post("/v1/access/tickets", json=body)
    return ticket_id, secret, r


def enroll(rig, ticket_id: str, secret: bytes, device: sm.Device, member_id: str, seed: int = 50,
           stamp_ticket: str | None = None):
    wire = enroll_request(device, ticket_id, secret, ssh_pub(seed), member_id)
    stamp = gate_stamp(rig["access"].gate_key, "enroll", stamp_ticket or ticket_id)
    return rig["bare"].post(f"/v1/access/enroll/{ticket_id}", json=wire, headers={"X-Mindloom-Gate": stamp})


class MemberClient:
    """A member Mac's requests as the bridge forwards them: its credential plus the gate stamp."""

    def __init__(self, rig, credential: str, access_id: str):
        self.c = rig["bare"]
        self.headers = {"Authorization": f"Bearer {credential}",
                        "X-Mindloom-Gate": gate_stamp(rig["access"].gate_key, "member", access_id)}

    def request(self, method, url, **kw):
        headers = {**self.headers, **(kw.pop("headers", None) or {})}
        return self.c.request(method, url, headers=headers, **kw)

    def get(self, url, **kw):
        return self.request("GET", url, **kw)

    def post(self, url, **kw):
        return self.request("POST", url, **kw)

    def delete(self, url, **kw):
        return self.request("DELETE", url, **kw)


def join_member(rig, seed: int = 50):
    ticket_id, secret, r = make_ticket(rig, seed=seed - 10)
    assert r.status_code == 200, r.text
    device, member_id = sm.Device(), new_id()
    r = enroll(rig, ticket_id, secret, device, member_id, seed=seed)
    assert r.status_code == 200, r.text
    out = r.json()
    return device, member_id, out, MemberClient(rig, out["credential"], out["access_id"])


def test_owner_ticket_then_enrollment_gives_one_credential_and_swaps_the_line(rig):
    ticket_id, secret, r = make_ticket(rig)
    assert r.status_code == 200 and r.json()["kind"] == "member", r.text
    assert f"mindloom-enroll:{ticket_id}".encode() in rig["ak"].read_bytes()
    device, member_id = sm.Device(), new_id()
    # a wrong secret counts a failure and changes nothing
    r = enroll(rig, ticket_id, b"\x00" * 32, device, member_id)
    assert r.status_code == 403 and r.json()["error"] == "bad_secret"
    # the stamp of another ticket does not reach this one; no stamp at all is a 401
    assert enroll(rig, ticket_id, secret, device, member_id, stamp_ticket=new_id()).status_code == 401
    r = enroll(rig, ticket_id, secret, device, member_id)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["credential"].startswith(f"mlacc1.{out['access_id']}.") and out["member_id"] == member_id
    text = rig["ak"].read_bytes()
    assert f"mindloom-enroll:{ticket_id}".encode() not in text and f"mindloom-member:{out['access_id']}".encode() in text
    # the credential's hash only: the secret is nowhere in the data directory
    secret_part = out["credential"].rsplit(".", 1)[1].encode()
    for f in Path(rig["access"].data_dir).rglob("*"):
        if f.is_file():
            assert secret_part not in f.read_bytes(), f
    # used up
    r = enroll(rig, ticket_id, secret, sm.Device(), new_id(), seed=51)
    assert r.status_code == 410 and r.json()["error"] == "ticket_used"


def test_member_reaches_member_routes_only_and_only_through_its_gate_stamp(rig):
    device, member_id, out, mc = join_member(rig)
    r = mc.get("/v1/access/me")
    assert r.status_code == 200 and r.json()["access"]["member_id"] == member_id and r.json()["may_invite"] is False
    for method, path in (("GET", "/v1/state"), ("GET", "/v1/inbox"), ("GET", "/v1/health"), ("POST", "/v1/unlock"),
                         ("POST", "/v1/wipe"), ("GET", "/v1/debug/runs"), ("GET", "/v1/stats"),
                         ("DELETE", "/v1/items/x")):
        r = mc.request(method, path, json={} if method == "POST" else None)
        assert r.status_code == 403 and r.json() == {"error": "member_scope"}, (method, path)
    # the credential without the gate stamp (a stolen credential used without the member's SSH key)
    r = rig["bare"].get("/v1/access/me", headers={"Authorization": f"Bearer {out['credential']}"})
    assert r.status_code == 401 and r.json()["error"] == "not_through_gate"
    # another access id's stamp, a forged stamp, a mangled credential
    other = gate_stamp(rig["access"].gate_key, "member", new_id())
    assert rig["bare"].get("/v1/access/me", headers={"Authorization": f"Bearer {out['credential']}",
                                                     "X-Mindloom-Gate": other}).status_code == 401
    forged = gate_stamp("00" * 32, "member", out["access_id"])
    assert rig["bare"].get("/v1/access/me", headers={"Authorization": f"Bearer {out['credential']}",
                                                     "X-Mindloom-Gate": forged}).status_code == 401
    bad = out["credential"][:-2] + ("AA" if not out["credential"].endswith("AA") else "BB")
    assert MemberClient(rig, bad, out["access_id"]).get("/v1/access/me").status_code == 401
    # the owner sees everything, the member only itself
    assert [m["access_id"] for m in rig["owner"].get("/v1/access/members").json()["members"]] == [out["access_id"]]
    assert rig["owner"].get("/v1/access/me").json()["caller"] == "owner"


def test_space_requests_through_the_gate_are_signed_by_the_enrolled_device(rig):
    device, member_id, out, mc = join_member(rig)
    clock = rig["clock"]
    mac = Mac(mc, clock)            # the member's Mac, talking through its access
    mac.device, mac.member_id = device, member_id
    space_id = mac.create_space()
    assert mac.get(f"/v1/spaces/{space_id}").status_code == 200
    # a request signed by another device: refused before any signature check
    stranger = sm.Device()
    r = mac.signed("GET", f"/v1/spaces/{space_id}", device=stranger)
    assert r.status_code == 403 and r.json()["error"] == "access_device"
    # an op signed by another device inside the body
    wire = stranger.op(space_id, member_id, "item.hide", {"item_id": new_id()})
    r = mc.post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]})
    assert r.status_code == 403 and r.json()["error"] == "access_device"
    other_space = sm.Device()
    r = mc.post("/v1/spaces", json=other_space.op(new_id(), member_id, "space.create", {}, epoch=1))
    assert r.status_code == 403 and r.json()["error"] == "access_device"


def test_tickets_for_new_members_need_an_admin_and_a_second_mac_needs_the_member(rig):
    device, member_id, out, mc = join_member(rig)
    # a plain member cannot invite people
    _, _, r = make_ticket(rig, client=mc, seed=60)
    assert r.status_code == 403
    # but it can add its own second Mac
    t2, s2, r = make_ticket(rig, client=mc, kind="device", seed=61)
    assert r.status_code == 200, r.text
    r = enroll(rig, t2, s2, sm.Device(), new_id(), seed=62)
    assert r.status_code == 403 and r.json()["error"] == "wrong_member"      # someone else's member id
    t3, s3, _ = make_ticket(rig, client=mc, kind="device", seed=63)
    second = sm.Device()
    r = enroll(rig, t3, s3, second, member_id, seed=64)
    assert r.status_code == 200, r.text
    # a member ticket reused for an existing member id is refused (second Macs come from the first one)
    t4, s4, _ = make_ticket(rig, seed=65)
    r = enroll(rig, t4, s4, sm.Device(), member_id, seed=66)
    assert r.status_code == 409 and r.json()["error"] == "member_exists"
    # after creating a space, the member is its admin but still invites nobody new to the Spark (review finding
    # V8R-06: any teammate may make a space); an org admin may
    mac = Mac(mc, rig["clock"])
    mac.device, mac.member_id = device, member_id
    mac.create_space()
    assert mc.get("/v1/access/me").json()["may_invite"] is False
    assert make_ticket(rig, client=mc, seed=67)[2].status_code == 403
    mac.create_org()
    assert mc.get("/v1/access/me").json()["may_invite"] is True
    _, _, r = make_ticket(rig, client=mc, seed=68)
    assert r.status_code == 200, r.text


def test_unpairing_restores_authorized_keys_and_stops_the_credential(rig):
    original = rig["ak"].read_bytes()
    device, member_id, out, mc = join_member(rig)
    assert rig["ak"].read_bytes() != original
    # a member unpairs its own Mac; afterwards the credential is dead
    r = mc.delete(f"/v1/access/members/{out['access_id']}")
    assert r.status_code == 200 and r.json()["removed"] == 1
    assert rig["ak"].read_bytes() == original                 # byte-identical, final newline taken back too
    assert mc.get("/v1/access/me").status_code == 401
    entries = rig["owner"].get("/v1/access/audit").json()["entries"]
    assert [e["action"] for e in entries] == ["access.ticket", "access.enroll", "access.revoke"]
    assert all(set(e["target"]) <= {"ticket_id", "kind", "access_id", "member_id"} for e in entries)


def test_expired_and_revoked_tickets_leave_no_line(rig):
    original = rig["ak"].read_bytes()
    t1, _, _ = make_ticket(rig, seed=70)
    t2, s2, _ = make_ticket(rig, seed=71)
    assert rig["owner"].delete(f"/v1/access/tickets/{t1}").json()["removed"] == 1
    rig["clock"].advance(hours=49)
    assert rig["access"].sweep() == 1
    assert rig["ak"].read_bytes() == original
    r = enroll(rig, t2, s2, sm.Device(), new_id())
    assert r.status_code == 410
    # ten wrong secrets lock a ticket
    t3, s3, _ = make_ticket(rig, seed=72)
    for _ in range(10):
        enroll(rig, t3, os.urandom(32), sm.Device(), new_id())
    assert enroll(rig, t3, s3, sm.Device(), new_id()).status_code == 429


def test_a_ticket_refuses_bad_input(rig):
    clock = rig["clock"]
    base = {"ticket_id": new_id(), "kind": "member", "ssh_key": ssh_pub(80), "secret_hash": "ab" * 32,
            "expires_at": expires(clock)}
    for change in ({"ticket_id": "X"}, {"kind": "admin"}, {"ssh_key": "ssh-rsa AAAA"}, {"secret_hash": "zz"},
                   {"expires_at": expires(clock, 24 * 8)}, {"expires_at": "tomorrow"}):
        r = rig["owner"].post("/v1/access/tickets", json={**base, **change, "ticket_id": change.get("ticket_id",
                                                                                                  new_id())})
        assert r.status_code == 422, change
    assert not any(ln.endswith(b"mindloom-enroll") for ln in rig["ak"].read_bytes().split())


def test_member_path_rule():
    for ok in ("/v1/spaces", "/v1/spaces/x/ops", "/v1/orgs/x", "/v1/access/me", "/v1/infra/health"):
        assert member_path(ok), ok
    for bad in ("/v1/state", "/v1/spacesx", "/v1/accessx", "/v1/infra", "/v1/spaces/../state", "/v1//spaces",
                "/v1/inbox", "/v1/unlock"):
        assert not member_path(bad), bad


# ---- the bridge, in-process ----------------------------------------------------------------------------------


class Pipes:
    def __init__(self):
        self.in_r, self.in_w = os.pipe()
        self.out_r, self.out_w = os.pipe()

    def io(self) -> _Stdio:
        return _Stdio(self.in_r, self.out_w, idle_s=5)

    def send(self, data: bytes) -> None:
        os.write(self.in_w, data)

    def close_input(self) -> None:
        os.close(self.in_w)

    def read_all(self) -> bytes:
        os.close(self.out_w)
        chunks = []
        while True:
            b = os.read(self.out_r, 65536)
            if not b:
                return b"".join(chunks)
            chunks.append(b)


def run_bridge(rig, access_id: str, raw: bytes) -> bytes:
    pipes = Pipes()
    bridge = Bridge(access_id, gate_key=rig["access"].gate_key, client=rig["bare"], io=pipes.io())
    t = threading.Thread(target=bridge.run)
    t.start()
    pipes.send(raw)
    pipes.close_input()
    t.join(timeout=30)
    assert not t.is_alive()
    return pipes.read_all()


def http(method: str, path: str, credential: str, body: bytes = b"", extra: str = "") -> bytes:
    head = f"{method} {path} HTTP/1.1\r\nHost: organizer\r\nAuthorization: Bearer {credential}\r\n{extra}"
    if body or method in ("POST", "PUT"):
        head += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
    return head.encode() + b"\r\n" + body


def test_bridge_forwards_member_requests_keepalive_and_stamps_them(rig):
    device, member_id, out, _ = join_member(rig)
    cred = out["credential"]
    raw = http("GET", "/v1/access/me", cred) + http("GET", "/v1/access/members", cred)
    got = run_bridge(rig, out["access_id"], raw)
    assert got.count(b"HTTP/1.1 200") == 2, got[:400]
    assert member_id.encode() in got


@pytest.mark.parametrize("raw,status", [
    (b"GET /v1/state HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\n\r\n", b"403"),
    (b"GET /v1/spaces/../state HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\n\r\n", b"403"),
    (b"GET http://evil/v1/spaces HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\n\r\n", b"400"),
    (b"PATCH /v1/spaces HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\n\r\n", b"405"),
    (b"GET /v1/access/me HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {owner}\r\n\r\n", b"403"),
    (b"GET /v1/access/me HTTP/1.1\r\nHost: o\r\n\r\n", b"403"),
    (b"POST /v1/spaces HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\nContent-Length: 2\r\n"
     b"Content-Length: 5\r\n\r\n{}", b"400"),
    (b"POST /v1/spaces HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {cred}\r\nTransfer-Encoding: chunked\r\n"
     b"Content-Length: 2\r\n\r\n2\r\n{}\r\n0\r\n\r\n", b"400"),
    (b"GARBAGE\r\n\r\n", b"400"),
], ids=["personal-route", "dotdot", "absolute-form", "method", "owner-token", "no-credential", "two-lengths",
        "te-and-cl", "garbage"])
def test_bridge_refuses_what_is_not_a_member_request(rig, raw, status):
    _, _, out, _ = join_member(rig)
    raw = raw.replace(b"{cred}", out["credential"].encode()).replace(b"{owner}", rig["app"].state.link_token.encode())
    got = run_bridge(rig, out["access_id"], raw)
    assert got.startswith(b"HTTP/1.1 " + status), got[:300]


def test_bridge_uses_its_own_credential_only(rig):
    _, _, a, _ = join_member(rig, seed=50)
    _, _, b, _ = join_member(rig, seed=52)
    # B's credential through A's key: refused by the gate (and A's stamp would not match B anyway)
    got = run_bridge(rig, a["access_id"], http("GET", "/v1/access/me", b["credential"]))
    assert got.startswith(b"HTTP/1.1 403")


def test_gate_key_is_shared_by_file(tmp_path):
    k1 = read_gate_key(tmp_path)
    assert len(k1) == 64 and read_gate_key(tmp_path) == k1
    assert oct((tmp_path / "gate_key").stat().st_mode & 0o777) == "0o600"
    acc = Access(tmp_path)
    assert acc.check_stamp(gate_stamp(k1, "member", "0" * 8 + "-0000-0000-0000-" + "0" * 12), "member")
    assert acc.check_stamp(gate_stamp(k1, "member", "0" * 8 + "-0000-0000-0000-" + "0" * 12), "enroll") is None
