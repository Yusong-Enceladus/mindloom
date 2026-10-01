"""Regression tests for the v7 adversarial review of shared spaces (findings V7-S*). Each test replays the
review's attack and asserts the fixed behaviour. Invented data only.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from conftest import auth_headers
from organizer import space_crypto as sc
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import HOST_KEY, Clock, Mac, new_id

SENTINEL = "评审哨兵QX7空间"


@pytest.fixture
def spark(settings, chat):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield SimpleNamespace(c=c, app=app, clock=clock, spaces=spaces, data=Path(settings.data_dir),
                              settings=settings)


def admit(spark, admin: Mac, sid: str, role: str, member_id: str | None = None) -> Mac:
    m = Mac(spark.c, spark.clock, "M")
    if member_id:
        m.member_id = member_id
    inv = admin.invite(sid, role=role)
    r = m.request_join(sid, inv)
    assert r.status_code == 200, r.text
    assert admin.approve(sid, r.json()["request_id"])["ok"]
    m.sync_keys(sid)
    return m


def org_op(spark, admin: Mac, org_id: str, type_: str, body: dict) -> dict:
    wire = admin.device.org_op(org_id, admin.member_id, type_, body)
    r = spark.c.post(f"/v1/orgs/{org_id}/ops", json={"ops": [wire]})
    assert r.status_code == 200, r.text
    return r.json()["results"][0]


def role_of(m: Mac, sid: str) -> str:
    r = m.get(f"/v1/spaces/{sid}")
    assert r.status_code == 200, r.text
    return r.json()["me"]["role"]


def inject_device(spark, sid: str, member_id: str) -> sm.Device:
    """What anyone with the Spark account can do: add a device row for a real member in the plain spaces.db."""
    evil = sm.Device()
    pub = evil.public()
    spark.spaces.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',999)",
                   (sid, pub["device_id"], member_id, pub["sign_pub"], pub["seal_pub"]))
    return evil


# ---- V7-S1: members and devices come from the signed log, never from the Spark's tables ------------------


def test_s1_a_device_row_added_on_the_spark_never_receives_a_rotation(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    admit(spark, a, sid, "write")
    c = admit(spark, a, sid, "write")
    evil = inject_device(spark, sid, a.member_id)
    # The member side wraps the next key only to devices a signed op admitted. The Spark, trusting its tables,
    # wants a wrap for the injected row too, so the removal is refused (and the admin's Mac learns why) …
    res = a.remove_member(sid, c.member_id)
    assert not res["ok"] and res["error"] == "bad_wraps" and evil.device_id in res["missing"], res
    assert spark.spaces.one("SELECT 1 FROM key_wraps WHERE space_id=? AND device_id=?",
                            (sid, evil.device_id)) is None
    # … and the Mac sees that the Spark lists a device no member admitted.
    roster = a.roster(sid)[0]
    listed = {d["device_id"] for m in a.get(f"/v1/spaces/{sid}").json()["members"] for d in m["devices"]
              if d["status"] == "active"}
    admitted = {d["device_id"] for d in sm.active_devices(roster)}
    assert listed - admitted == {evil.device_id}
    # Without the injected row the same removal goes through and C gets no wrap.
    spark.spaces.x("DELETE FROM devices WHERE device_id=?", (evil.device_id,))
    res = a.remove_member(sid, c.member_id)
    assert res["ok"], res
    assert spark.spaces.one("SELECT 1 FROM key_wraps WHERE space_id=? AND epoch=2 AND device_id=?",
                            (sid, c.device.device_id)) is None


def test_s1b_an_op_signed_by_an_injected_device_is_not_applied_by_members(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = admit(spark, a, sid, "write")
    shared = a.share(sid, SENTINEL + " 只给成员看的原文")
    evil = inject_device(spark, sid, a.member_id)
    forged = evil.op(sid, a.member_id, "item.withdraw", {"item_id": shared["item_id"]})
    out = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [forged]}).json()["results"][0]
    assert out["ok"]  # the Spark trusts its own tables (an operator can always lie to it) …
    roster, accepted, rejected = b.roster(sid)
    # … but no member accepts the op: its device is in no signed op.
    assert [e["seq"] for e in rejected] == [out["seq"]]
    assert all(e["payload"]["op_id"] != json.loads(sc.b64u_decode(forged["op"]))["op_id"] for e in accepted)
    assert sm.roster_device(roster, a.member_id, evil.device_id) is None


def test_s1_join_approve_commits_to_the_joiners_keys(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = Mac(spark.c, spark.clock, "B")
    rid = b.request_join(sid, a.invite(sid)).json()["request_id"]
    req = a.join_request(sid, rid)
    wraps = sm.wraps_for(a.key(sid), [req["device"]], sid, 1)
    # an approval that does not name the joiner's keys, or names other keys, is refused
    assert a.op(sid, "join.approve", {"request_id": rid, "wraps": wraps})["error"] == "approve_mismatch"
    other = sm.Device().public()
    other["device_id"] = req["device"]["device_id"]
    res = a.op(sid, "join.approve", {"request_id": rid, "member_id": req["member_id"], "device": other,
                                     "wraps": wraps})
    assert res["error"] == "approve_mismatch"
    assert a.approve(sid, rid)["ok"]
    roster = a.roster(sid)[0]
    assert sm.roster_device(roster, b.member_id, b.device.device_id)["sign_pub"] == sc.b64u(b.device.sign_pub)


def test_s10_the_epoch_in_use_is_the_logs_not_the_sparks(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = admit(spark, a, sid, "write")
    admit(spark, a, sid, "write")
    assert a.remove_member(sid, b.member_id)["ok"]
    spark.spaces.x("UPDATE spaces SET epoch=1 WHERE space_id=?", (sid,))  # the Spark now says epoch 1
    roster = a.roster(sid)[0]
    assert roster["epoch"] == 2 and a.get(f"/v1/spaces/{sid}").json()["epoch"] == 1
    # the next rotation starts from the log's epoch, never from the lower one the Spark reports
    body, _ = a.rotation_body(sid)
    assert body["epoch"] == 3


# ---- V7-S2: a member id is bound to its keys across the Spark; org rights need the org device -----------------


def test_s2_an_invitee_cannot_claim_an_org_admins_member_id(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    x = Mac(spark.c, spark.clock, "X")
    assert org_op(spark, a, org_id, "org.admin_add", {"member_id": x.member_id, "device": x.device.public()})["ok"]
    sid = a.create_space("org", org_id)
    mallory = Mac(spark.c, spark.clock, "mallory")
    mallory.member_id = x.member_id
    r = mallory.request_join(sid, a.invite(sid, role="read"))
    assert r.status_code == 409 and r.json()["error"] == "member_id_taken"
    # a member id used in another space is taken too (attribution there would follow the impostor)
    other = admit(spark, a, a.create_space("org", org_id), "write")
    thief = Mac(spark.c, spark.clock, "thief")
    thief.member_id = other.member_id
    r = thief.request_join(sid, a.invite(sid, role="read"))
    assert r.status_code == 409 and r.json()["error"] == "member_id_taken"
    # another device under X's id is refused too (X's second Mac is added with device.add from X's first)
    r = Mac(spark.c, spark.clock, "X2")
    r.member_id = x.member_id
    assert r.request_join(sid, a.invite(sid, role="read")).json()["error"] == "member_id_taken"
    # X itself, from its own org device, joins with its id and is admin there
    x_sid = a.create_space("org", org_id)
    x_inv = a.invite(x_sid, role="read")
    rid = x.request_join(x_sid, x_inv).json()["request_id"]
    assert a.approve(x_sid, rid)["ok"]
    x.sync_keys(x_sid)
    assert role_of(x, x_sid) == "admin"  # X's org device is admin whatever the invite said


def test_s2_org_rights_follow_the_org_device_not_the_member_id(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    x = Mac(spark.c, spark.clock, "X")
    assert org_op(spark, a, org_id, "org.admin_add", {"member_id": x.member_id, "device": x.device.public()})["ok"]
    sid = a.create_space("org", org_id)
    # Suppose a device under X's member id got into this space without being X's org device (a second Mac of
    # X's added later, or a row someone wrote): it gets the role the space gave it, not the org's admin rights.
    second = Mac(spark.c, spark.clock, "X2")
    second.member_id = x.member_id
    pub = second.device.public()
    spark.spaces.x("INSERT INTO members(space_id, member_id, role, outside, status, joined_ts) VALUES"
                   " (?,?,'read',0,'active',0)", (sid, x.member_id))
    spark.spaces.x("INSERT INTO devices VALUES (?,?,?,?,?,'active',50)",
                   (sid, pub["device_id"], x.member_id, pub["sign_pub"], pub["seal_pub"]))
    assert role_of(second, sid) == "read"


# ---- V7-S3: past the window an org asset cannot be shredded by sharing a new revision -----------------------


def test_s3_past_the_window_a_reshare_is_refused_and_the_asset_stays(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    sid = a.create_space("org", org_id)
    w = admit(spark, a, sid, "write")
    item = w.share(sid, SENTINEL + " 组织资产")
    # within the window a contributor may still correct it
    assert w.share(sid, SENTINEL + " 组织资产 改过", item_id=item["item_id"], revision=2)["result"]["ok"]
    spark.clock.advance(hours=25)
    assert w.op(sid, "item.withdraw", {"item_id": item["item_id"]})["error"] == "window_passed"
    again = w.share(sid, " ", item_id=item["item_id"], revision=3)
    assert again["result"]["error"] == "window_passed"
    assert SENTINEL in json.dumps(a.read_items(sid), ensure_ascii=False)
    # a group space has no window: its contributor may always replace their own item
    g = a.create_space("person")
    gi = a.share(g, "小组 草稿")
    spark.clock.advance(hours=100)
    assert a.share(g, "小组 定稿", item_id=gi["item_id"], revision=2)["result"]["ok"]


# ---- V7-S4: a privacy takedown on someone else's item can be rejected, and is capped per member ---------------


def test_s4_a_maintainer_rejects_a_readers_takedown_with_a_reason(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    sid = a.create_space("org", org_id)
    w = admit(spark, a, sid, "write")
    r = admit(spark, a, sid, "read")
    item = w.share(sid, "实验记录 与任何人隐私无关")
    tid = new_id()
    assert r.ok(sid, "takedown.request", {"takedown_id": tid, "item_id": item["item_id"], "kind": "privacy"})
    op_id = new_id()
    rej = a.op(sid, "takedown.resolve", {"takedown_id": tid, "decision": "reject"}, epoch=a.epoch(sid),
               op_id=op_id, enc=sm.enc_op(a.key(sid), {"reason": "记录里没有个人信息"}, sid, op_id))
    assert rej["ok"], rej
    spark.clock.advance(hours=73)
    spark.spaces.sweep(sid)
    assert spark.spaces.item(sid, item["item_id"])["status"] == "active"
    # the contributor's own privacy takedown is honoured and cannot be rejected
    own = new_id()
    assert w.ok(sid, "takedown.request", {"takedown_id": own, "item_id": item["item_id"], "kind": "privacy"})
    op_id = new_id()
    res = a.op(sid, "takedown.resolve", {"takedown_id": own, "decision": "reject"}, epoch=a.epoch(sid),
               op_id=op_id, enc=sm.enc_op(a.key(sid), {"reason": "不行"}, sid, op_id))
    assert res["status"] == 403 and res["error"] == "privacy_takedown"


def test_s4_one_member_keeps_only_a_few_privacy_takedowns_open(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    sid = a.create_space("org", org_id)
    w = admit(spark, a, sid, "write")
    r = admit(spark, a, sid, "read")
    items = [w.share(sid, f"实验记录 第{n}份")["item_id"] for n in range(5)]
    results = [r.op(sid, "takedown.request", {"takedown_id": new_id(), "item_id": i, "kind": "privacy"})
               for i in items]
    assert [x["ok"] for x in results] == [True, True, True, False, False]
    assert results[3]["error"] == "too_many_takedowns"
    # the contributor is not capped on their own items
    assert all(w.ok(sid, "takedown.request", {"takedown_id": new_id(), "item_id": i, "kind": "privacy"})
               for i in items)


# ---- V7-S5: one recording's parts add up to at most 15 minutes per contributor ---------------------------------


def test_s5_consecutive_parts_of_one_recording_stop_at_fifteen_minutes(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = admit(spark, a, sid, "write")
    parent = new_id()
    oks = []
    for n in range(8):  # a two-hour meeting, end to end, as text parts (no audio)
        seg = {"parent_item_id": parent, "start_ms": n * 900_000, "end_ms": (n + 1) * 900_000}
        oks.append(a.share(sid, f"第{n}段", kind="meeting_offline", segment=seg))
    assert [x["result"]["ok"] for x in oks] == [True] + [False] * 7
    assert {x["result"]["error"] for x in oks[1:]} == {"recording_share_limit"}
    # parts of the same 15 minutes overlap and fit; another recording or another contributor has its own budget
    assert a.share(sid, "重叠", kind="meeting_offline",
                   segment={"parent_item_id": parent, "start_ms": 60_000, "end_ms": 600_000})["result"]["ok"]
    assert a.share(sid, "另一场", kind="audio_segment",
                   segment={"parent_item_id": new_id(), "start_ms": 0, "end_ms": 900_000})["result"]["ok"]
    assert b.share(sid, "乙的一段", kind="meeting_offline",
                   segment={"parent_item_id": parent, "start_ms": 0, "end_ms": 900_000})["result"]["ok"]
    # withdrawing a part gives its minutes back (9 of the 15 are still out in the overlapping part)
    assert a.ok(sid, "item.withdraw", {"item_id": oks[0]["item_id"]})
    assert a.share(sid, "换一段", kind="meeting_offline",
                   segment={"parent_item_id": parent, "start_ms": 3_600_000, "end_ms": 3_900_000})["result"]["ok"]


# ---- V7-S7: an admin removed from the organization loses admin rights in its spaces -----------------------------


def test_s7_a_removed_org_admin_is_demoted_where_another_admin_remains(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    x = Mac(spark.c, spark.clock, "X")
    assert org_op(spark, a, org_id, "org.admin_add", {"member_id": x.member_id, "device": x.device.public()})["ok"]
    shared = x.create_space("org", org_id)
    y = admit(spark, x, shared, "admin")
    alone = x.create_space("org", org_id)
    res = org_op(spark, a, org_id, "org.admin_remove", {"member_id": x.member_id})
    assert res["ok"]
    assert role_of(x, shared) == "write" and role_of(y, shared) == "admin"
    # where X is the only admin the Spark (which holds no key) cannot hand the space over: it is listed
    summary = a.signed("GET", f"/v1/orgs/{org_id}").json()
    assert summary["former_admins"] == [{"space_id": alone, "member_id": x.member_id}]


# ---- V7-S8: a privacy takedown's reason is for the requester and the maintainers -------------------------------


def test_s8_other_members_never_receive_a_privacy_takedown_reason(spark):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org()
    sid = a.create_space("org", org_id)
    w = admit(spark, a, sid, "write")
    r = admit(spark, a, sid, "read")
    other = admit(spark, a, sid, "read")
    item = w.share(sid, "会议纪要")
    op_id = new_id()
    enc = sm.enc_op(r.key(sid), {"reason": "里面有我的病情"}, sid, op_id)
    assert r.op(sid, "takedown.request", {"takedown_id": new_id(), "item_id": item["item_id"], "kind": "privacy"},
                epoch=r.epoch(sid), enc=enc, op_id=op_id)["ok"]

    def takedown_ops(m: Mac) -> list[dict]:
        return [o for o in m.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"]
                if o["type"] == "takedown.request"]

    seen = takedown_ops(other)
    assert len(seen) == 1 and seen[0]["enc"] is None and seen[0]["withheld"]
    assert w.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"]  # the contributor too
    assert takedown_ops(w)[0]["enc"] is None
    # the requester and a maintainer still read it, and a withheld op still verifies for everyone
    assert takedown_ops(r)[0]["enc"] == enc and takedown_ops(a)[0]["enc"] == enc
    _, accepted, rejected = sm.replay(other.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"], sid)
    assert rejected == [] and any(e["type"] == "takedown.request" for e in accepted)


# ---- V7-S9: the invite secret never reaches the Spark --------------------------------------------------------


def test_s9_the_spark_never_learns_the_invite_secret(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    inv = a.invite(sid, role="read")
    b = Mac(spark.c, spark.clock, "B")
    wire = b.device.join(sid, inv["invite_id"], inv["secret"], b.member_id)
    assert "invite_secret" not in wire
    assert sc.b64u(inv["secret"]) not in json.dumps(wire) and inv["secret"].hex() not in json.dumps(wire)
    # what the Spark receives (the gate) lets it file a request of its own, but not one the inviter accepts
    evil = sm.Device()
    forged = evil.join(sid, inv["invite_id"], os.urandom(32), new_id())
    forged["invite_gate"] = wire["invite_gate"]  # the gate it saw; the binding it cannot make
    r = spark.c.post(f"/v1/spaces/{sid}/join", json=forged)
    assert r.status_code == 200
    record = a.join_request(sid, r.json()["request_id"])
    assert sm.check_join_request(record, inv["secret"]) == "bad_binding"
    # an honest request passes the inviter's check; a wire that carries a secret is refused outright
    inv2 = a.invite(sid, role="read")
    rid = b.request_join(sid, inv2).json()["request_id"]
    assert sm.check_join_request(a.join_request(sid, rid), inv2["secret"]) is None
    inv3 = a.invite(sid, role="read")
    leaky = b.device.join(sid, inv3["invite_id"], inv3["secret"], new_id())
    leaky["invite_secret"] = sc.b64u(inv3["secret"])
    r = spark.c.post(f"/v1/spaces/{sid}/join", json=leaky)
    assert r.status_code == 400
    # nothing the Spark keeps holds a secret
    hits = [p.name for p in spark.data.rglob("*") if p.is_file() and any(
        x in p.read_bytes() for x in (inv["secret"], inv["secret"].hex().encode(), sc.b64u(inv["secret"]).encode()))]
    assert hits == []


# ---- V7-S17: a share rule belongs to the member who set it ---------------------------------------------------


def test_s17_another_writer_cannot_clear_a_members_rule(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = admit(spark, a, sid, "write")
    rule = new_id()
    op_id = new_id()
    assert a.ok(sid, "share_rule.set", {"rule_id": rule, "kind": "rope"}, epoch=1, op_id=op_id,
                enc=sm.enc_op(a.key(sid), {"title": "绳"}, sid, op_id))
    res = b.op(sid, "share_rule.clear", {"rule_id": rule})
    assert res["status"] == 403 and res["error"] == "forbidden"
    assert a.ok(sid, "share_rule.clear", {"rule_id": rule})


# ---- V7-S18: the replay guard survives a restart -----------------------------------------------------------------


def test_s18_a_signed_request_cannot_be_replayed_after_a_restart(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    target = f"/v1/spaces/{sid}"
    headers = a.device.request_headers("GET", target, b"", date=int(spark.clock()))
    assert spark.c.get(target, headers=headers).status_code == 200
    assert spark.c.get(target, headers=headers).json()["error"] == "replayed"
    # a new Spaces on the same data dir (the service restarted) still knows the nonce
    restarted = Spaces(spark.settings.data_dir, now=spark.clock, host_keys=lambda: [HOST_KEY])
    try:
        from organizer.spaces import SpaceError
        with pytest.raises(SpaceError) as exc:
            restarted.authenticate(sid, "GET", target, {"device": headers["X-Mindloom-Device"],
                                                         "date": headers["X-Mindloom-Date"],
                                                         "nonce": headers["X-Mindloom-Nonce"],
                                                         "signature": headers["X-Mindloom-Signature"]}, b"")
        assert exc.value.code == "replayed"
    finally:
        restarted.close()


# ---- V7-S16: "not a member" comes with the signed op that ended the access ---------------------------------------


def test_s16_not_a_member_carries_the_signed_removal_for_the_mac_to_check(spark):
    a = Mac(spark.c, spark.clock, "A")
    sid = a.create_space("person")
    b = admit(spark, a, sid, "write")
    roster_before = b.roster(sid)[0]  # what B's Mac knows before it is removed
    assert a.remove_member(sid, b.member_id)["ok"]
    r = b.get(f"/v1/spaces/{sid}")
    assert r.status_code == 403 and r.json()["error"] == "not_member"
    removal = r.json()["removal"]
    assert removal["type"] == "member.remove" and removal["sig"]
    # B's Mac checks it against its own roster: signed by A's admitted device, naming B
    raw = sc.b64u_decode(removal["op"])
    op = json.loads(raw)
    signer = sm.roster_device(roster_before, op["member_id"], op["device_id"])
    assert signer is not None and op["body"]["member_id"] == b.member_id
    assert sc.verify(sc.b64u_decode(signer["sign_pub"]), sc.OP_DOMAIN + raw, removal["sig"])
