"""Shared spaces, Spark side (SPACES-CONTRACT section 5 "Spark"): every stored blob is ciphertext (sentinel scan),
the space organizer sees placeholders only, op-log ordering and idempotency, invite expiry and one-time use, role
checks on every op, plus the rights the contract names (withdraw window, takedowns, proposals, removal with
rotation, crypto-shredding, forks, archive, audio only as segments, audit without content). Invented data only."""

from __future__ import annotations

import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.exceptions import InvalidTag
from fastapi.testclient import TestClient

from conftest import TEST_KEY, auth_headers
from organizer import db
from organizer import space_crypto as sc
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import HOST_KEY, Clock, Mac, new_id, payload

SENTINEL = "哨兵QZXV空间"
PHONE = "13912345678"


@pytest.fixture
def spark(settings, chat):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield SimpleNamespace(c=c, app=app, clock=clock, spaces=spaces, orgs=app.state.space_organizers,
                              chat=chat, data=Path(settings.data_dir))


def team(spark, owner: str = "org", roles: tuple = ("write",), policy=None):
    """A (admin; an org admin for org spaces) creates a space and admits one member per role."""
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org() if owner == "org" else None
    sid = a.create_space(owner, org_id, policy=policy)
    members = []
    for i, role in enumerate(roles):
        m = Mac(spark.c, spark.clock, f"M{i}")
        inv = a.invite(sid, role=role)
        r = m.request_join(sid, inv)
        assert r.status_code == 200, r.text
        assert a.approve(sid, r.json()["request_id"])["ok"]
        m.sync_keys(sid)
        members.append(m)
    return sid, a, members


def scan(root: Path, needles: list[str]) -> list[str]:
    hits = []
    for p in root.rglob("*"):
        if p.is_file() and not p.is_symlink():
            data = p.read_bytes()
            hits += [f"{p.name}:{n}" for n in needles if n.encode() in data]
    return hits


# ---- op log --------------------------------------------------------------------------------------------


def test_op_log_is_server_ordered_idempotent_and_verifiable(spark):
    sid, a, (b,) = team(spark)
    wires = [a.device.op(sid, a.member_id, "item.hide", {"item_id": new_id(), "hidden": True})]
    r = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": wires})
    assert r.json()["results"][0]["error"] == "unknown_item"  # refused ops take no seq
    shares = [a.share(sid, f"第{i}条 咖啡馆") for i in range(3)]
    seqs = [s["result"]["seq"] for s in shares]
    assert seqs == sorted(seqs) and len(set(seqs)) == 3
    head = spark.spaces.space(sid)["head"]
    # the same op again: the same seq, nothing appended
    wire = b.device.op(sid, b.member_id, "item.hide", {"item_id": shares[0]["item_id"], "hidden": True})
    first = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [wire]}).json()["results"][0]
    again = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [wire]}).json()["results"][0]
    assert first["ok"] and not first["duplicate"]
    assert again == {**first, "duplicate": True}
    assert spark.spaces.space(sid)["head"] == head + 1
    # the same op_id for another op
    other = b.device.op(sid, b.member_id, "item.hide", {"item_id": shares[1]["item_id"], "hidden": True},
                        op_id=json.loads(sc.b64u_decode(wire["op"]))["op_id"])
    res = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [other]}).json()["results"][0]
    assert res["error"] == "op_id_conflict" and res["status"] == 409
    # paging by cursor returns every op in order, and every signature verifies against the listed device keys
    seen, cursor = [], 0
    while True:
        page = b.get(f"/v1/spaces/{sid}/ops", since=cursor, limit=2).json()
        seen += page["ops"]
        cursor = page["cursor"]
        if not page["more"]:
            break
    assert [o["seq"] for o in seen] == sorted(o["seq"] for o in seen)
    keys = {d["device_id"]: d["sign_pub"] for m in b.get(f"/v1/spaces/{sid}").json()["members"] for d in m["devices"]}
    for o in seen:
        raw = sc.b64u_decode(o["op"])
        dev = json.loads(raw)["device_id"]
        assert sc.verify(sc.b64u_decode(keys[dev]), sc.OP_DOMAIN + raw, o["sig"])
    # "hide for me" is private: A does not see B's hide op
    assert not any(o["type"] == "item.hide" for o in a.get(f"/v1/spaces/{sid}/ops").json()["ops"])
    assert any(o["type"] == "item.hide" for o in seen)


def test_signed_op_that_fails_verification_is_rejected(spark):
    sid, a, (b,) = team(spark)
    head = spark.spaces.space(sid)["head"]
    wire = a.device.op(sid, a.member_id, "invite.revoke", {"invite_id": new_id()})
    bad = dict(wire, sig=b.device.sign(sc.OP_DOMAIN + sc.b64u_decode(wire["op"])))  # B's signature on A's op
    res = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [bad]}).json()["results"][0]
    assert res["status"] == 401 and res["error"] == "bad_signature"
    raw = bytearray(sc.b64u_decode(wire["op"]))
    raw[-3] = ord("x")
    tampered = dict(wire, op=sc.b64u(bytes(raw)))
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [tampered]}).json()["results"][0]["status"] in (400, 401)
    # B signs an op claiming to be A
    forged = b.device.op(sid, a.member_id, "invite.revoke", {"invite_id": new_id()})
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [forged]}).json()["results"][0]["error"] == "unknown_device"
    # a device that is not in the space
    stranger = Mac(spark.c, spark.clock, "X")
    w = stranger.device.op(sid, stranger.member_id, "item.hide", {"item_id": new_id()})
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [w]}).json()["results"][0]["error"] == "unknown_device"
    # a detached field that does not match its hash
    share = a.device.op(sid, a.member_id, "member.profile", {}, epoch=1,
                        enc=sm.enc_op(a.key(sid), {"n": 1}, sid, new_id()))
    share["enc"] = sm.enc_op(a.key(sid), {"n": 2}, sid, new_id())
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [share]}).json()["results"][0]["status"] == 400
    assert spark.spaces.space(sid)["head"] == head


def test_signed_requests(spark):
    sid, a, (b,) = team(spark)
    path = f"/v1/spaces/{sid}"
    assert b.get(path).status_code == 200
    assert spark.c.get(path).json()["error"] == "unknown_device"  # the link token alone reads nothing
    h = b.device.request_headers("GET", path, date=int(spark.clock()))
    assert spark.c.get(path, headers=h).status_code == 200
    assert spark.c.get(path, headers=h).json()["error"] == "replayed"
    h = b.device.request_headers("GET", path, date=int(spark.clock()) - 3600)
    assert spark.c.get(path, headers=h).json()["error"] == "stale_request"
    h = b.device.request_headers("GET", path + "/keys", date=int(spark.clock()))  # signed for another target
    assert spark.c.get(path, headers=h).json()["error"] == "bad_signature"
    h = a.device.request_headers("GET", path, date=int(spark.clock()))
    h["X-Mindloom-Device"] = b.device.device_id  # A's signature presented as B's device
    assert spark.c.get(path, headers=h).json()["error"] == "bad_signature"
    # GET /v1/spaces lists what a device belongs to
    listing = b.get("/v1/spaces").json()
    assert [s["space_id"] for s in listing["spaces"]] == [sid] and listing["spaces"][0]["role"] == "write"


# ---- invites -----------------------------------------------------------------------------------------


def test_invite_expiry_one_time_use_secret_and_host_key(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    too_long = a.invite(sid, hours=24 * 7 + 2)
    assert too_long["result"]["error"] == "bad_field"
    assert a.invite(sid, host_key="ssh-ed25519 AAAAotherhost")["result"]["error"] == "host_key_mismatch"
    inv = a.invite(sid, hours=24 * 7)
    assert inv["result"]["ok"]
    b, c, d = (Mac(spark.c, spark.clock, n) for n in "BCD")
    # a wrong secret is refused and counted; the invite stays usable
    r = b.request_join(sid, inv, secret=os.urandom(32))
    assert r.status_code == 403 and r.json()["error"] == "bad_invite_secret"
    r = b.request_join(sid, inv)
    assert r.status_code == 200 and r.json()["status"] == "pending"
    rid = r.json()["request_id"]
    # one-time: a second device cannot use it
    r = c.request_join(sid, inv)
    assert r.status_code == 410 and r.json()["error"] == "invite_used"
    # the joining device polls its own request, signed with the key it registered
    st = b.signed("GET", f"/v1/spaces/{sid}/join/{rid}")
    assert st.json()["status"] == "pending"
    assert c.signed("GET", f"/v1/spaces/{sid}/join/{rid}").status_code == 404
    assert a.approve(sid, rid)["ok"]
    assert b.signed("GET", f"/v1/spaces/{sid}/join/{rid}").json()["status"] == "approved"
    # expiry
    inv2 = a.invite(sid, hours=1)
    spark.clock.advance(hours=2)
    r = c.request_join(sid, inv2)
    assert r.status_code == 410 and r.json()["error"] == "invite_expired"
    # revoked
    inv3 = a.invite(sid)
    assert a.op(sid, "invite.revoke", {"invite_id": inv3["invite_id"]})["ok"]
    assert c.request_join(sid, inv3).json()["error"] == "invite_revoked"
    # locked after repeated wrong secrets
    inv4 = a.invite(sid)
    for _ in range(10):
        d.request_join(sid, inv4, secret=os.urandom(32))
    assert d.request_join(sid, inv4).json()["error"] == "invite_locked"
    # the join profile is ciphertext; a plaintext name is refused
    inv5 = a.invite(sid)
    wire = d.device.join(sid, inv5["invite_id"], inv5["secret"], d.member_id, profile="韩策")
    assert spark.c.post(f"/v1/spaces/{sid}/join", json=wire).json()["error"] == "not_ciphertext"
    # only the invite's secret hash is on the Spark
    assert scan(spark.data, [sc.b64u(inv["secret"]), inv["secret"].hex()]) == []
    listed = {i["invite_id"]: i["status"] for i in a.get(f"/v1/spaces/{sid}/invites").json()["invites"]}
    assert listed[inv["invite_id"]] == "used" and listed[inv2["invite_id"]] == "expired"


# ---- rights ----------------------------------------------------------------------------------------------


def _fresh_item(owner: Mac, sid: str) -> str:
    return owner.share(sid, "咖啡馆 权限测试")["item_id"]


def _cases(sid: str, a: Mac, others: dict):
    """(op type, body factory(actor), minimum role) for every op type whose right is a role."""
    def rotation(actor):
        body, _ = a.rotation_body(sid)
        return body

    def remove_member(actor):
        victim = Mac(a.c, a.clock, "victim")
        inv = a.invite(sid, role="read")
        rid = victim.request_join(sid, inv).json()["request_id"]
        a.approve(sid, rid)
        body, _ = a.rotation_body(sid, exclude_member=victim.member_id)
        return {**body, "member_id": victim.member_id}

    def join_approve(actor):
        joiner = Mac(a.c, a.clock, "joiner")
        inv = a.invite(sid, role="read")
        rid = joiner.request_join(sid, inv).json()["request_id"]
        dev = joiner.device.public()
        return {"request_id": rid, "member_id": joiner.member_id, "device": dev,
                "wraps": sm.wraps_for(a.key(sid), [dev], sid, a.epoch(sid))}

    def takedown(actor):
        item = _fresh_item(a, sid)
        tid = new_id()
        assert a.ok(sid, "takedown.request", {"takedown_id": tid, "item_id": item, "kind": "other"})
        return {"takedown_id": tid, "decision": "accept"}

    def proposal(actor):
        pid = new_id()
        assert a.ok(sid, "proposal.create", {"proposal_id": pid, "kind": "rename", "targets": {"matter_ids": ["m1"]}})
        return {"proposal_id": pid, "decision": "accept"}

    def share(actor):
        item_id, dk = new_id(), os.urandom(32)
        e = actor.epoch(sid)
        return {"__kw": {"epoch": e, "enc": sm.enc_item(dk, {"t": 1}, sid, item_id, 1),
                         "wrapped_dk": sm.wrap_item_key(actor.key(sid), dk, sid, e, item_id)},
                "item_id": item_id, "revision": 1, "kind": "text"}

    def with_enc(body):
        def f(actor):
            op_id = new_id()
            return {"__kw": {"epoch": actor.epoch(sid), "op_id": op_id,
                             "enc": sm.enc_op(actor.key(sid), {"x": 1}, sid, op_id)}, **body(actor)}
        return f

    return [
        ("item.share", share, "write"),
        ("matter.share", lambda actor: {"package_id": new_id(), "item_ids": [_fresh_item(actor, sid)]}, "write"),
        ("share_rule.set", with_enc(lambda actor: {"rule_id": new_id(), "kind": "rope"}), "write"),
        ("proposal.create", lambda actor: {"proposal_id": new_id(), "kind": "merge",
                                           "targets": {"matter_ids": ["m1", "m2"]}}, "write"),
        ("item.remove", lambda actor: {"item_id": _fresh_item(a, sid)}, "maintain"),
        ("takedown.resolve", takedown, "maintain"),
        ("proposal.resolve", proposal, "maintain"),
        ("matter.handover", lambda actor: {"matter_id": "m9", "to_member_id": a.member_id}, "maintain"),
        ("invite.create", lambda actor: {"invite_id": new_id(), "secret_hash": "0" * 64, "role": "read",
                                         "expires_at": "2026-09-23T00:00:00+00:00"}, "admin"),
        ("invite.revoke", lambda actor: {"invite_id": a.invite(sid)["invite_id"]}, "admin"),
        ("join.approve", join_approve, "admin"),
        ("member.role", lambda actor: {"member_id": others["read"].member_id, "role": "read"}, "admin"),
        ("member.remove", remove_member, "admin"),
        ("epoch.rotate", rotation, "admin"),
        ("space.policy", lambda actor: {"policy": {"takedown_window_h": 48}}, "admin"),
        ("space.archive", lambda actor: {"archived": False}, "admin"),
        ("space.meta", with_enc(lambda actor: {}), "admin"),
    ]


def test_role_checks_on_every_op(spark):
    sid, a, (reader, writer, maintainer, admin2) = team(spark, "person", ("read", "write", "maintain", "admin"))
    for m in (reader, writer, maintainer, admin2):
        m.sync_keys(sid)
    others = {"read": reader, "write": writer, "maintain": maintainer, "admin": admin2}
    order = ["read", "write", "maintain", "admin"]
    for type_, factory, need in _cases(sid, a, others):
        for role in order:
            actor = others[role]
            actor.sync_keys(sid)
            body = factory(actor)
            kw = body.pop("__kw", {})
            res = actor.op(sid, type_, body, **kw)
            allowed = order.index(role) >= order.index(need)
            assert res["ok"] == allowed, (type_, role, res)
            if not allowed:
                assert res["status"] == 403 and res["error"] == "forbidden", (type_, role, res)
            if type_ in ("member.remove", "epoch.rotate") and res["ok"]:
                a.space_keys[sid][body["epoch"]] = None  # placeholder, replaced by sync below
                for m in [a, *others.values()]:
                    m.sync_keys(sid)
    # rights that are not a role: someone else's item, request, proposal, package
    item = writer.share(sid, "咖啡馆 别人的")["item_id"]
    assert maintainer.op(sid, "item.withdraw", {"item_id": item})["error"] == "forbidden"
    assert maintainer.op(sid, "item.delete", {"item_id": item})["error"] == "forbidden"
    assert maintainer.op(sid, "takedown.request", {"takedown_id": new_id(), "item_id": item, "kind": "other"}
                         )["error"] == "forbidden"
    tid = new_id()
    assert reader.ok(sid, "takedown.request", {"takedown_id": tid, "item_id": item, "kind": "privacy"})
    assert writer.op(sid, "takedown.withdraw", {"takedown_id": tid})["error"] == "forbidden"
    pid = new_id()
    assert writer.ok(sid, "proposal.create", {"proposal_id": pid, "kind": "rename"})
    assert maintainer.op(sid, "proposal.withdraw", {"proposal_id": pid})["error"] == "forbidden"
    pkg = new_id()
    assert writer.ok(sid, "matter.share", {"package_id": pkg, "item_ids": [item]})
    assert maintainer.op(sid, "matter.unshare", {"package_id": pkg})["error"] == "forbidden"
    assert maintainer.op(sid, "matter.share", {"package_id": new_id(), "item_ids": [item]})["error"] == "unknown_items"
    # reads that are admin-only, and uploads that need write
    assert writer.get(f"/v1/spaces/{sid}/audit").status_code == 403
    assert maintainer.get(f"/v1/spaces/{sid}/join-requests").status_code == 403
    assert reader.signed("PUT", f"/v1/spaces/{sid}/blobs/{new_id()}", body=b"MLB1" + bytes(40),
                         content_type="application/octet-stream").status_code == 403
    # the owner of a group space cannot be demoted or removed by another admin
    assert admin2.op(sid, "member.role", {"member_id": a.member_id, "role": "read"})["error"] == "forbidden"
    body, _ = admin2.rotation_body(sid, exclude_member=a.member_id)
    assert admin2.op(sid, "member.remove", {**body, "member_id": a.member_id})["error"] == "forbidden"
    assert a.op(sid, "member.leave", {})["error"] == "owner_cannot_leave"


# ---- withdraw window, delete, takedowns ---------------------------------------------------------------


def test_withdraw_window_org_vs_group(spark):
    sid, a, (b,) = team(spark, "org")
    early = b.share(sid, "咖啡馆 早")["item_id"]
    late = b.share(sid, "咖啡馆 晚")["item_id"]
    spark.clock.advance(hours=23)
    assert b.ok(sid, "item.withdraw", {"item_id": early})["effects"]["status"] == "withdrawn"
    spark.clock.advance(hours=2)
    res = b.op(sid, "item.withdraw", {"item_id": late})
    assert res["status"] == 403 and res["error"] == "window_passed"
    # delete after the window becomes a takedown request (org asset); a maintainer decides
    res = b.ok(sid, "item.delete", {"item_id": late})
    assert res["effects"]["status"] == "takedown_requested"
    t = b.get(f"/v1/spaces/{sid}/takedowns").json()["takedowns"]
    assert [x["kind"] for x in t] == ["other"] and t[0]["requester"] == b.member_id
    assert a.ok(sid, "takedown.resolve", {"takedown_id": t[0]["takedown_id"], "decision": "reject"})
    assert spark.spaces.item(sid, late)["status"] == "active"
    # a group space: withdraw any time; the owner removes anything
    gsid, owner, (m,) = team(spark, "person")
    x = m.share(gsid, "读书会 书单")["item_id"]
    y = m.share(gsid, "读书会 地点")["item_id"]
    spark.clock.advance(hours=24 * 30)
    assert m.ok(gsid, "item.withdraw", {"item_id": x})
    assert owner.ok(gsid, "item.remove", {"item_id": y, "reason": "policy"})
    assert m.op(gsid, "item.withdraw", {"item_id": y})["status"] == 410


def test_privacy_takedown_is_honoured_within_the_window(spark):
    sid, a, (b, c) = team(spark, "org", ("write", "read"))
    item = b.share(sid, "读书会 名单", original=b"%PDF name list")
    blob_id = item["blobs"][0]["blob_id"]
    tid = new_id()
    # anyone exposed by an item may ask; the reason travels encrypted
    op_id = new_id()
    assert c.ok(sid, "takedown.request", {"takedown_id": tid, "item_id": item["item_id"], "kind": "privacy"},
                epoch=1, op_id=op_id, enc=sm.enc_op(c.key(sid), {"reason": "有我的号码"}, sid, op_id))
    # a maintainer may reject someone else's privacy takedown only with a reason (V7-S4)
    res = a.op(sid, "takedown.resolve", {"takedown_id": tid, "decision": "reject"})
    assert res["status"] == 400 and res["error"] == "bad_op"
    t = a.get(f"/v1/spaces/{sid}/takedowns", status="open").json()["takedowns"][0]
    assert t["kind"] == "privacy" and t["due_at"] and not t["overdue"]
    assert c.get(f"/v1/spaces/{sid}/takedowns").json()["takedowns"][0]["takedown_id"] == tid  # own requests
    # nobody acts within 72 h: the Spark carries it out
    spark.clock.advance(hours=73)
    assert spark.spaces.sweep()["takedowns"] == 1
    assert spark.spaces.item(sid, item["item_id"])["status"] == "removed"
    assert not spark.spaces.blob_path(sid, blob_id).exists()
    ops = a.get(f"/v1/spaces/{sid}/ops").json()["ops"]
    system = [o for o in ops if o["type"] == "system.remove"]
    assert len(system) == 1 and system[0]["sig"] is None  # unsigned, and it only removes
    assert json.loads(sc.b64u_decode(system[0]["op"]))["body"]["item_id"] == item["item_id"]
    assert a.get(f"/v1/spaces/{sid}/takedowns").json()["takedowns"][0]["status"] == "done"


def test_proposals_queue(spark):
    sid, a, (writer, maintainer) = team(spark, "org", ("write", "maintain"))
    pid = new_id()
    op_id = new_id()
    assert writer.ok(sid, "proposal.create", {"proposal_id": pid, "kind": "rename",
                                              "targets": {"matter_ids": ["E7"]}},
                     epoch=1, op_id=op_id, enc=sm.enc_op(writer.key(sid), {"title": "新名字"}, sid, op_id))
    queue = maintainer.get(f"/v1/spaces/{sid}/proposals", status="open").json()
    assert [p["proposal_id"] for p in queue["proposals"]] == [pid] and queue["organizer"] == []
    assert maintainer.ok(sid, "proposal.resolve", {"proposal_id": pid, "decision": "accept"})
    assert maintainer.get(f"/v1/spaces/{sid}/proposals").json()["proposals"][0]["status"] == "accepted"
    assert maintainer.op(sid, "proposal.resolve", {"proposal_id": pid, "decision": "reject"})["status"] == 409
    p2 = new_id()
    assert writer.ok(sid, "proposal.create", {"proposal_id": p2, "kind": "relation"})
    assert writer.ok(sid, "proposal.withdraw", {"proposal_id": p2})
    # a proposal's text is ciphertext only
    assert scan(spark.data, ["新名字"]) == []


# ---- removal, rotation, crypto-shredding ------------------------------------------------------------------


def test_remove_member_rotates_and_the_removed_device_cannot_read_new_items(spark):
    sid, a, (b, c) = team(spark, "org", ("write", "write"))
    old_item = a.share(sid, "咖啡馆 旧的")["item_id"]
    k1 = b.key(sid, 1)
    # rotation wraps must cover exactly the remaining devices
    body, _ = a.rotation_body(sid)  # still includes B
    res = a.op(sid, "member.remove", {**body, "member_id": b.member_id})
    assert res["error"] == "bad_wraps" and b.device.device_id in res["unexpected"]
    res = a.remove_member(sid, b.member_id)
    assert res["ok"] and res["effects"]["epoch"] == 2
    # B is out: every signed request answers not_member (with the forks to delete)
    r = b.get(f"/v1/spaces/{sid}/ops")
    assert r.status_code == 403 and r.json()["error"] == "not_member" and r.json()["member_status"] == "removed"
    w = b.device.op(sid, b.member_id, "item.hide", {"item_id": old_item})
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [w]}).json()["results"][0]["error"] == "not_member"
    # no wrap of epoch 2 for B's device; B's seal key opens none of the others
    wraps = spark.spaces.all("SELECT * FROM key_wraps WHERE space_id=? AND epoch=2", (sid,))
    assert {w["device_id"] for w in wraps} == {a.device.device_id, c.device.device_id}
    for w in wraps:
        with pytest.raises(InvalidTag):
            sm.unwrap_space_key(w["wrap"], b.device.seal_priv, sid, 2, w["device_id"])
    # C, still a member, gets epoch 2 and reaches epoch 1 through the link
    c.sync_keys(sid)
    assert c.epoch(sid) == 2 and c.key(sid, 1) == k1
    # an item shared after the rotation: wrapped under K2, which B (holding K1) cannot unwrap
    new = c.share(sid, "咖啡馆 新的")
    row = spark.spaces.one("SELECT * FROM item_keys WHERE space_id=? AND item_id=?", (sid, new["item_id"]))
    assert row["epoch"] == 2
    with pytest.raises(InvalidTag):
        sm.unwrap_item_key(row["wrapped_dk"], k1, sid, 2, new["item_id"])
    assert c.read_items(sid)[new["item_id"]]["text"] == "咖啡馆 新的"
    # a share under the old epoch is refused
    item_id, dk = new_id(), os.urandom(32)
    res = c.op(sid, "item.share", {"item_id": item_id, "revision": 1, "kind": "text"}, epoch=1,
               enc=sm.enc_item(dk, {}, sid, item_id, 1), wrapped_dk=sm.wrap_item_key(k1, dk, sid, 1, item_id))
    assert res["status"] == 409 and res["error"] == "stale_epoch"
    # lazy re-wrap of old items under epoch 2 by a member Mac
    stale = c.get(f"/v1/spaces/{sid}/item-keys", stale=1).json()["items"]
    assert [s["item_id"] for s in stale] == [old_item]
    dk_old = sm.unwrap_item_key(stale[0]["wrapped_dk"], c.key(sid, 1), sid, 1, old_item)
    r = c.signed("PUT", f"/v1/spaces/{sid}/item-keys", body=json.dumps({"rewraps": [
        {"item_id": old_item, "epoch": 2, "wrapped_dk": sm.wrap_item_key(c.key(sid), dk_old, sid, 2, old_item)}]}).encode())
    assert r.json() == {"rewrapped": 1, "epoch": 2}
    assert c.get(f"/v1/spaces/{sid}/item-keys", stale=1).json()["items"] == []
    assert c.read_items(sid)[old_item]["text"] == "咖啡馆 旧的"
    # contributions of a removed member stay, attributed
    assert all(o["member_id"] for o in spark.spaces.all("SELECT member_id FROM ops WHERE space_id=? AND"
                                                        " type='item.share'", (sid,)))


def test_leaving_requires_a_rotation_before_new_shares(spark):
    sid, a, (b,) = team(spark, "person")
    item = b.share(sid, "读书会 我的")["item_id"]
    assert b.ok(sid, "member.leave", {"contributions": "withdraw"})["effects"] == {"rotation_pending": True,
                                                                                 "withdrawn": 1}
    assert spark.spaces.item(sid, item)["status"] == "withdrawn"
    res = a.share(sid, "读书会 新")["result"]
    assert res["status"] == 409 and res["error"] == "rotation_pending"
    assert a.rotate(sid)["ok"]
    assert a.share(sid, "读书会 新")["result"]["ok"]
    # org spaces keep contributions: leaving with "withdraw" is refused
    osid, oa, (ob,) = team(spark, "org")
    ob.share(osid, "咖啡馆 组织资产")
    assert ob.op(osid, "member.leave", {"contributions": "withdraw"})["error"] == "forbidden"
    assert ob.ok(osid, "member.leave", {"contributions": "keep"})
    assert len(spark.spaces.active_items(osid)) == 1


def test_withdraw_crypto_shreds_the_item(spark):
    sid, a, (b,) = team(spark, "org")
    shared = b.share(sid, f"咖啡馆 {SENTINEL}", original=f"原件 {SENTINEL}".encode())
    item_id, blob_id = shared["item_id"], shared["blobs"][0]["blob_id"]
    wrapped = spark.spaces.one("SELECT wrapped_dk FROM item_keys WHERE space_id=? AND item_id=?",
                               (sid, item_id))["wrapped_dk"]
    enc = spark.spaces.one("SELECT enc FROM ops WHERE space_id=? AND subject=?", (sid, item_id))["enc"]
    assert a.read_items(sid)[item_id]["text"].endswith(SENTINEL)
    blob = a.signed("GET", f"/v1/spaces/{sid}/blobs/{blob_id}").content
    assert blob.startswith(b"MLB1")
    assert b.ok(sid, "item.withdraw", {"item_id": item_id})
    # the wrapped data key, the encrypted fields and the blob are gone from the Spark
    assert spark.spaces.one("SELECT 1 FROM item_keys WHERE item_id=?", (item_id,)) is None
    row = spark.spaces.one("SELECT enc, purged FROM ops WHERE space_id=? AND subject=?", (sid, item_id))
    assert row["enc"] is None and row["purged"] == 1
    assert not spark.spaces.blob_path(sid, blob_id).exists()
    assert a.signed("GET", f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 410
    assert item_id not in a.read_items(sid)
    assert scan(spark.data, [wrapped, enc[len(sc.ENC_PREFIX):][:40]]) == []
    # a copy of the ciphertext kept anywhere is dead without the data key, which no longer exists on the Spark
    with pytest.raises(InvalidTag):
        sm.open_blob(blob, os.urandom(32), sid, item_id, blob_id)
    # the op itself (who shared what, when) stays and still verifies
    op = next(o for o in a.get(f"/v1/spaces/{sid}/ops").json()["ops"] if o["type"] == "item.share")
    assert op["purged"] and op["enc"] is None and op["item_key"] is None
    raw = sc.b64u_decode(op["op"])
    assert sc.verify(b.device.sign_pub, sc.OP_DOMAIN + raw, op["sig"])
    # a withdrawn item cannot be shared again under the same id
    res = b.share(sid, "咖啡馆 再来", item_id=item_id, revision=2)["result"]
    assert res["status"] == 410


# ---- ciphertext only ---------------------------------------------------------------------------------------


def test_every_stored_blob_is_ciphertext(spark):
    sid, a, (b,) = team(spark, "person")
    for i in range(3):
        b.share(sid, f"读书会 {SENTINEL} {i}", original=f"{SENTINEL} 原件 {PHONE} {i}".encode() * 50,
                kind="document")
    # plaintext is refused at the door: blob, encrypted field, wrap
    r = b.signed("PUT", f"/v1/spaces/{sid}/blobs/{new_id()}", body=f"{SENTINEL}".encode() * 10,
                 content_type="application/octet-stream")
    assert r.status_code == 422 and r.json()["error"] == "not_ciphertext"
    # a field that is not shaped like ciphertext (the Mac's own tests guard that what it encrypts is encrypted)
    bad = b.device.op(sid, b.member_id, "member.profile", {}, epoch=1, enc="mlenc1.名字：" + SENTINEL)
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [bad]}).json()["results"][0]["error"] == "not_ciphertext"
    bad = b.device.op(sid, b.member_id, "member.profile", {}, epoch=1, enc=SENTINEL)
    assert spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [bad]}).json()["results"][0]["error"] == "not_ciphertext"
    for f in (spark.data / "spaces").rglob("*"):
        if f.is_file() and f.parent.name == "blobs":
            assert f.read_bytes().startswith(sc.BLOB_MAGIC)
    assert scan(spark.data, [SENTINEL, PHONE, "原件"]) == []


# ---- the space organizer ------------------------------------------------------------------------------------


def test_space_organizer_sees_placeholders_only(spark):
    sid, a, (b,) = team(spark, "org")
    x = a.share(sid, f"咖啡馆 开业，联系人电话 {PHONE}，{SENTINEL}")["item_id"]
    y = b.share(sid, "咖啡馆 豆子报价，邮箱 bean@example.com")["item_id"]
    assert a.get(f"/v1/spaces/{sid}/organizer/state").status_code == 423
    assert a.lease(sid).status_code == 200
    pending = a.get(f"/v1/spaces/{sid}/organizer/pending").json()["items"]
    assert {p["item_id"] for p in pending} == {x, y}
    # the Macs mask with the space mask key; an unmasked number is masked again by the Spark
    assert a.organize(sid, [payload(x, f"咖啡馆 开业，联系人电话 {PHONE}，{SENTINEL}", origin="pa-1",
                                    persons=[{"person_id": "voice-cluster-7", "display_name": "王师傅"}])]).json() \
        == {"accepted": 1, "duplicates": 0}
    assert b.organize(sid, [payload(y, "咖啡馆 豆子报价，邮箱 bean@example.com", minutes=3, origin="pb-1")]).json()[
        "accepted"] == 1
    spark.orgs.get(sid).drain()
    prompts = json.dumps([call[3] for call in spark.chat.calls], ensure_ascii=False)
    assert PHONE not in prompts and "bean@example.com" not in prompts
    assert "〔手机号·" in prompts and "〔邮箱·" in prompts
    assert "voice-cluster-7" not in prompts
    st = b.get(f"/v1/spaces/{sid}/organizer/state").json()
    live = [e for e in st["events"] if not e["deleted"]]
    assert len(live) == 1 and set(live[0]["item_ids"]) == {x, y}
    assert PHONE not in json.dumps(st, ensure_ascii=False)
    person_ids = [p["person_id"] for p in st["persons"]]
    assert person_ids and all(pid.startswith("sp-") for pid in person_ids)
    assert {(l["member_id"], l["matter_id"]) for l in st["same_as"]} == {(a.member_id, "pa-1"), (b.member_id, "pb-1")}
    # nothing readable on disk: the store is SQLCipher, the log holds ciphertext
    assert scan(spark.data, [SENTINEL, PHONE, "bean@example.com", "王师傅"]) == []


def test_space_organizer_lease_rules(spark):
    sid, a, (b, r) = team(spark, "org", ("write", "read"))
    x = a.share(sid, "咖啡馆 一")["item_id"]
    wrong = dict(a.lease_keys(sid), store_key=os.urandom(32).hex())
    assert a.lease(sid).status_code == 200
    assert a.post_json(f"/v1/spaces/{sid}/organizer/lock", {}).json() == {"locked": True}
    resp = a.post_json(f"/v1/spaces/{sid}/organizer/lease", wrong)
    assert resp.status_code == 409 and resp.json()["error"] == "wrong_key" and resp.json()["epoch"] == 1
    resp = a.post_json(f"/v1/spaces/{sid}/organizer/lease", dict(a.lease_keys(sid), mask_key=os.urandom(32).hex()))
    assert resp.json()["error"] == "wrong_mask_key"
    resp = a.post_json(f"/v1/spaces/{sid}/organizer/lease", dict(a.lease_keys(sid), epoch=2))
    assert resp.json()["error"] == "stale_epoch"
    # a reader may lease and read the derived state, but sends no payloads
    assert r.lease(sid).status_code == 200
    assert r.organize(sid, [payload(x, "咖啡馆 一")]).status_code == 403
    # payloads only for shared, active items at the shared revision
    assert b.organize(sid, [payload(new_id(), "咖啡馆 没共享")]).json()["error"] == "unknown_item"
    assert b.organize(sid, [payload(x, "咖啡馆 一", revision=2)]).json()["error"] == "revision_mismatch"
    assert b.organize(sid, [payload(x, "咖啡馆 一")]).json()["accepted"] == 1
    # withdrawn while the store is locked: purged at the next lease, before anything else
    y = b.share(sid, "咖啡馆 二")["item_id"]
    assert b.organize(sid, [payload(y, "咖啡馆 二")]).json()["accepted"] == 1
    spark.orgs.get(sid).drain()
    assert a.post_json(f"/v1/spaces/{sid}/organizer/lock", {}).status_code == 200
    assert b.ok(sid, "item.withdraw", {"item_id": y})
    assert spark.spaces.queued_purges(sid) == [y]
    assert a.lease(sid).json()["purged"] == 1
    assert spark.spaces.queued_purges(sid) == []
    st = a.get(f"/v1/spaces/{sid}/organizer/state").json()
    assert y not in {i for e in st["events"] for i in e["item_ids"]}
    assert b.organize(sid, [payload(y, "咖啡馆 二")]).json()["error"] == "item_gone"
    # the lease runs out without requests
    org = spark.orgs.get(sid)
    org._lease_deadline = 0.0
    assert a.get(f"/v1/spaces/{sid}/organizer/state").json()["error"] == "locked"


def test_rotation_rekeys_the_space_store(spark):
    sid, a, (b,) = team(spark, "org")
    x = a.share(sid, "咖啡馆 一")["item_id"]
    assert a.lease(sid).status_code == 200
    assert a.organize(sid, [payload(x, "咖啡馆 一")]).json()["accepted"] == 1
    old_store_key = sm.store_key(a.key(sid, 1))
    assert a.remove_member(sid, b.member_id)["ok"]
    # the rotation closed the store; the old epoch's key is refused, the new one needs the previous to re-key
    assert a.get(f"/v1/spaces/{sid}/organizer/state").json()["error"] == "locked"
    assert a.post_json(f"/v1/spaces/{sid}/organizer/lease", a.lease_keys(sid, 1)).json()["error"] == "stale_epoch"
    assert a.lease(sid).json()["error"] == "wrong_key"
    res = a.lease(sid, previous_epoch=1)
    assert res.status_code == 200 and res.json()["epoch"] == 2
    st = a.get(f"/v1/spaces/{sid}/organizer/state").json()
    assert st["store_id"]
    path = spark.spaces.space_dir(sid) / "organizer.db"
    a.post_json(f"/v1/spaces/{sid}/organizer/lock", {})
    with pytest.raises(db.DatabaseError):  # B's old key no longer opens the file
        db.connect(path, old_store_key)
    db.connect(path, sm.store_key(a.key(sid, 2))).close()
    assert a.lease(sid).status_code == 200  # the new key alone opens it from now on


def test_a_shared_package_stays_together(spark):
    """The sharer filed these items as one matter on their Mac: an item the organizer put elsewhere joins the
    shared matter holding most of its package (a model placement, once); a maintainer's removal wins; a package
    of fewer than three items keeps the model's grouping. (Lab end-to-end run, 2026-09-30: one of 24 items of
    two packages landed in another matter.)"""
    sid, a, (b, m) = team(spark, "org", ("write", "maintain"))
    texts = ["咖啡馆 开业定在十月八日", "咖啡馆 菜单下周定稿", "咖啡馆 豆子先订二十公斤", "装修报价三万，月底前完工"]
    ids = [a.share(sid, t)["item_id"] for t in texts]
    lamp = b.share(sid, "咖啡馆 灯具周四到")["item_id"]
    pair_texts = ["体检 周五空腹", "搬家 周六上午"]
    pair = [b.share(sid, t)["item_id"] for t in pair_texts]
    assert a.lease(sid).status_code == 200
    assert a.organize(sid, [payload(i, t, minutes=n, origin="pa-1")
                            for n, (i, t) in enumerate(zip(ids, texts))]).json()["accepted"] == 4
    assert b.organize(sid, [payload(lamp, "咖啡馆 灯具周四到", minutes=9, origin="pb-1")]
                      + [payload(i, t, minutes=10 + n, origin="pb-2")
                         for n, (i, t) in enumerate(zip(pair, pair_texts))]).json()["accepted"] == 3
    org = spark.orgs.get(sid)
    org.drain()

    def live():
        st = a.get(f"/v1/spaces/{sid}/organizer/state").json()
        return [e for e in st["events"] if not e["deleted"] and not e.get("merged_into")], st

    events, st = live()
    cafe = next(e for e in events if ids[0] in e["item_ids"])
    # the stray 装修报价 joined its package; B's item joined by the model as before
    assert set(ids) | {lamp} <= set(cafe["item_ids"])
    assert org.store.one("SELECT attached_by FROM event_items WHERE item_id=? AND removed=0",
                         (ids[3],))["attached_by"] == "model"
    # the event it left (now empty) is gone; the two-item package keeps the model's two matters
    assert all(set(e["item_ids"]) for e in events)
    assert len({e["event_id"] for e in events if set(e["item_ids"]) & set(pair)}) == 2
    assert {(l["member_id"], l["matter_id"]) for l in st["same_as"] if l["event_id"] == cafe["event_id"]} \
        == {(a.member_id, "pa-1"), (b.member_id, "pb-1")}
    hook = org.idle_hooks[0]
    assert hook.moved == 1
    # a maintainer takes it out again: that decision wins, the item is not moved back
    decision = {"decisions": [{"kind": "remove_item", "event_id": cafe["event_id"], "item_id": ids[3]}]}
    assert m.post_json(f"/v1/spaces/{sid}/organizer/decisions", decision).json()["applied"] == 1
    org.drain()
    events, _ = live()
    assert ids[3] not in next(e for e in events if ids[0] in e["item_ids"])["item_ids"]
    assert hook.moved == 1
    # withdrawn: its package row goes with it
    assert a.ok(sid, "item.withdraw", {"item_id": ids[3]})
    assert org.store.one("SELECT 1 FROM space_package_moves WHERE item_id=?", (ids[3],)) is None


def test_maintainers_edit_directly_and_answer_the_organizer(spark):
    sid, a, (w, m) = team(spark, "org", ("write", "maintain"))
    x = w.share(sid, "咖啡馆 一")["item_id"]
    assert m.lease(sid).status_code == 200
    assert w.organize(sid, [payload(x, "咖啡馆 一")]).json()["accepted"] == 1
    spark.orgs.get(sid).drain()
    ev = [e for e in m.get(f"/v1/spaces/{sid}/organizer/state").json()["events"] if not e["deleted"]][0]
    decision = {"decisions": [{"kind": "rename_event", "event_id": ev["event_id"], "title": "咖啡馆开业"}]}
    assert w.post_json(f"/v1/spaces/{sid}/organizer/decisions", decision).status_code == 403
    assert m.post_json(f"/v1/spaces/{sid}/organizer/decisions", decision).json() == {"applied": 1, "rejected": []}
    st = m.get(f"/v1/spaces/{sid}/organizer/state").json()
    assert any(e["title"] == "咖啡馆开业" for e in st["events"])


# ---- policy, archive, forks, audio, handover, audit ----------------------------------------------------------


def test_audio_only_as_segments_and_never_shared_kinds(spark):
    sid, a, (b,) = team(spark, "person")
    parent = new_id()
    for kind in ("recording", "voiceprint", "dictionary", "speaker_embedding"):
        res = b.share(sid, "x", kind=kind)["result"]
        assert res["status"] == 422 and res["error"] == "never_shared", kind
    res = b.share(sid, "会议", kind="meeting_offline", original=b"AUDIO", blob_role="audio")["result"]
    assert res["error"] == "audio_needs_segment"
    res = b.share(sid, "会议", kind="audio_segment", original=b"AUDIO", blob_role="audio",
                  segment={"parent_item_id": parent, "start_ms": 0, "end_ms": 16 * 60 * 1000})["result"]
    assert res["error"] == "segment_too_long"
    # v8 C1: an audio part names its recording's length (a part, never the whole; test_space_audio.py)
    res = b.share(sid, "会议里关于读书会的一分钟", kind="audio_segment", original=b"AUDIO", blob_role="audio",
                  segment={"parent_item_id": parent, "start_ms": 60_000, "end_ms": 120_000})["result"]
    assert res["error"] == "bad_field"
    res = b.share(sid, "会议里关于读书会的一分钟", kind="audio_segment", original=b"AUDIO", blob_role="audio",
                  segment={"parent_item_id": parent, "start_ms": 60_000, "end_ms": 120_000,
                           "recording_ms": 3_600_000})["result"]
    assert res["ok"]
    # a text-only space keeps no originals
    tsid, ta, (tb,) = team(spark, "person", policy={"originals": "text_only"})
    r = tb.signed("PUT", f"/v1/spaces/{tsid}/blobs/{new_id()}", body=b"MLB1" + os.urandom(40),
                  content_type="application/octet-stream")
    assert r.status_code == 403 and r.json()["error"] == "originals_not_allowed"
    assert tb.share(tsid, "只有文字")["result"]["ok"]


def test_archive_forks_handover(spark):
    sid, a, (b,) = team(spark, "org")
    item = b.share(sid, "咖啡馆 一")["item_id"]
    assert b.op(sid, "item.fork", {"item_id": item})["error"] == "forks_not_allowed"  # org default
    assert a.ok(sid, "space.policy", {"policy": {"forks_allowed": True}})
    assert b.ok(sid, "item.fork", {"item_id": item})
    assert b.op(sid, "matter.handover", {"matter_id": "E1", "to_member_id": b.member_id})["error"] == "forbidden"
    assert a.ok(sid, "matter.handover", {"matter_id": "E1", "to_member_id": b.member_id})
    # the 负责人 hands it on without being a maintainer
    c = Mac(spark.c, spark.clock, "C")
    rid = c.request_join(sid, a.invite(sid)).json()["request_id"]
    assert a.approve(sid, rid)["ok"]
    assert b.ok(sid, "matter.handover", {"matter_id": "E1", "to_member_id": c.member_id})
    assert b.op(sid, "matter.handover", {"matter_id": "E1", "to_member_id": b.member_id})["error"] == "forbidden"
    # archived: read-only, but withdraw and takedowns still work
    assert a.ok(sid, "space.archive", {"archived": True})
    assert b.share(sid, "咖啡馆 二")["result"]["error"] == "archived"
    assert b.ok(sid, "item.withdraw", {"item_id": item})
    assert a.ok(sid, "space.archive", {"archived": False})
    # removed: the device learns which forks to delete
    item2 = b.share(sid, "咖啡馆 三")["item_id"]
    assert b.ok(sid, "item.fork", {"item_id": item2})
    assert a.remove_member(sid, b.member_id)["ok"]
    r = b.get(f"/v1/spaces/{sid}")
    assert r.status_code == 403 and set(r.json()["purge_forks"]) == {item, item2}


def test_audit_log_records_without_content(spark):
    sid, a, (b,) = team(spark, "org")
    shared = b.share(sid, f"咖啡馆 {SENTINEL}", original=SENTINEL.encode())
    b.ok(sid, "agent.access", {"client": "Claude Code", "tool": "get_matter", "matters": 1, "items": 3})
    a.lease(sid)
    b.ok(sid, "item.withdraw", {"item_id": shared["item_id"]})
    records = a.get(f"/v1/spaces/{sid}/audit").json()["records"]
    actions = [r["action"] for r in records]
    for want in ("space.create", "invite.create", "join.request", "join.approve", "item.share", "agent.access",
                 "organizer.lease", "item.withdraw", "blob.put"):
        assert want in actions
    text = json.dumps(records, ensure_ascii=False)
    assert SENTINEL not in text and "mlenc1." not in text and "mlikey1." not in text and "mlwrap1." not in text
    # org admins see the org's records across its spaces
    org_id = spark.spaces.space(sid)["org_id"]
    r = a.signed("GET", f"/v1/orgs/{org_id}/audit")
    assert r.status_code == 200 and len(r.json()["records"]) >= len(records)
    assert b.signed("GET", f"/v1/orgs/{org_id}/audit").status_code == 401  # not an org admin device


def test_org_admins_and_org_spaces(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    b = Mac(spark.c, spark.clock, "B")
    # only an org admin's device creates an org space
    with pytest.raises(AssertionError, match="forbidden"):
        b.create_space("org", org_id)
    wire = a.device.org_op(org_id, a.member_id, "org.admin_add", {"member_id": b.member_id,
                                                                   "device": b.device.public()})
    assert spark.c.post(f"/v1/orgs/{org_id}/ops", json={"ops": [wire]}).json()["results"][0]["ok"]
    sid = b.create_space("org", org_id)
    # an org admin who joins an org space is its admin whatever the invite said
    rid = a.request_join(sid, b.invite(sid, role="read")).json()["request_id"]
    assert b.approve(sid, rid)["ok"]
    members = {m["member_id"]: m for m in b.get(f"/v1/spaces/{sid}").json()["members"]}
    assert members[a.member_id]["effective_role"] == "admin" and members[a.member_id]["org_admin"]
    summary = a.signed("GET", f"/v1/orgs/{org_id}").json()
    assert sid in summary["spaces"] and {x["member_id"] for x in summary["admins"]} == {a.member_id, b.member_id}
    # outside collaborators exist only in org spaces
    gsid = a.create_space("person")
    assert a.invite(gsid, outside=True)["result"]["error"] == "bad_field"
    assert b.invite(sid, outside=True)["result"]["ok"]


def test_spaces_work_while_the_personal_store_is_locked(settings, chat):
    settings.unlock_key = None
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org, spaces=Spaces(settings.data_dir, now=clock, host_keys=lambda: []))
    with TestClient(app, headers=auth_headers(app)) as c:
        assert c.get("/v1/state").status_code == 423
        a = Mac(c, clock, "A")
        sid = a.create_space("person")
        assert a.get(f"/v1/spaces/{sid}").status_code == 200
        assert a.share(sid, "读书会")["result"]["ok"]
        assert c.get("/v1/health").json()["spaces"]["spaces"] == 1
        assert c.get("/v1/state").status_code == 423  # and the other way round: nothing opened the personal store


def test_a_members_second_device(spark):
    sid, a, (b,) = team(spark, "org")
    # an invite holder cannot claim an existing member's id (and role)
    thief = Mac(spark.c, spark.clock, "thief")
    r = thief.request_join(sid, a.invite(sid, role="read"), member_id=a.member_id)
    assert r.status_code == 409 and r.json()["error"] == "member_exists"
    # B adds a second Mac from its first one: same member, same role, the current key wrapped to it
    second = sm.Device()
    res = b.ok(sid, "device.add", {"device": second.public(),
                                   "wraps": sm.wraps_for(b.key(sid), [second.public()], sid, b.epoch(sid))})
    assert res["effects"]["device_id"] == second.device_id
    b2 = Mac(spark.c, spark.clock, "B2")
    b2.device, b2.member_id = second, b.member_id
    b2.sync_keys(sid)
    assert b2.key(sid) == b.key(sid)
    item = b2.share(sid, "咖啡馆 从第二台 Mac")
    assert item["result"]["ok"]
    assert spark.spaces.item(sid, item["item_id"])["contributor"] == b.member_id
    # the lost first Mac is retired from the second one; the key rotates without it
    body, new_key = b2.rotation_body(sid)
    body["wraps"] = [w for w in body["wraps"] if w["device_id"] != b.device.device_id]
    assert b2.ok(sid, "device.remove", {"device_id": b.device.device_id, **body})
    r = b.get(f"/v1/spaces/{sid}")
    assert r.status_code == 403 and r.json()["member_status"] == "device_removed"
    assert b2.get(f"/v1/spaces/{sid}").json()["epoch"] == 2
