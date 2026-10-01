"""v8 B5 (org key escrow, recovering a space after losing an admin; closes V7-S7) and B6 (storage quota per member
per space). Synthetic members and content only."""

from __future__ import annotations

import json
import os

import pytest
from fastapi.testclient import TestClient

from conftest import TEST_KEY, auth_headers
from organizer import space_crypto as sc
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import Clock, Mac, new_id


@pytest.fixture
def env(tmp_path, settings, chat):
    clock = Clock()
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [], member_quota_mb=64)
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield {"c": c, "clock": clock, "spaces": spaces}


def macs(env, *names):
    return [Mac(env["c"], env["clock"], name=n) for n in names]


def create_org(mac: Mac, recovery: int) -> str:
    org_id = new_id()
    wire = mac.device.org_op(org_id, mac.member_id, "org.create",
                             {"device": mac.device.public(), "policy": {"recovery_admins": recovery}})
    r = mac.c.post("/v1/orgs", json=wire)
    assert r.status_code == 200 and r.json()["ok"], r.text
    return org_id


def org_op(mac: Mac, org_id: str, type_: str, body: dict) -> dict:
    r = mac.c.post(f"/v1/orgs/{org_id}/ops", json={"ops": [mac.device.org_op(org_id, mac.member_id, type_, body)]})
    assert r.status_code == 200, r.text
    return r.json()["results"][0]


def org_roster(mac: Mac, org_id: str) -> dict:
    r = mac.get(f"/v1/orgs/{org_id}")
    assert r.status_code == 200, r.text
    return sm.org_roster(r.json()["ops"], org_id)


def escrow_wraps(mac: Mac, org_id: str, space_id: str, key: bytes, epoch: int, exclude: set) -> list[dict]:
    """The reference: the new key wrapped to every admin device of the org (from its signed log) not already a
    member device."""
    devices = [d for d in sm.escrow_devices(org_roster(mac, org_id)) if d["device_id"] not in exclude]
    return sm.wraps_for(key, devices, space_id, epoch)


def create_org_space(mac: Mac, org_id: str, escrow: bool = True, name: str = "组织空间") -> tuple[str, dict]:
    space_id = new_id()
    k1 = os.urandom(32)
    op_id = new_id()
    body = {"owner": {"kind": "org", "org_id": org_id}, "device": mac.device.public(),
            "wraps": sm.wraps_for(k1, [mac.device.public()], space_id, 1)}
    if escrow:
        body["escrow_wraps"] = escrow_wraps(mac, org_id, space_id, k1, 1, {mac.device.device_id})
    wire = mac.device.op(space_id, mac.member_id, "space.create", body, epoch=1, op_id=op_id,
                         enc=sm.enc_op(k1, {"name": name}, space_id, op_id))
    r = mac.c.post("/v1/spaces", json=wire)
    if r.status_code == 200 and r.json().get("ok"):
        mac.space_keys[space_id] = {1: k1}
    return space_id, r.json()


def rotation(mac: Mac, org_id: str, space_id: str, exclude_member=None, escrow: bool = True) -> tuple[dict, bytes]:
    body, new_key = mac.rotation_body(space_id, exclude_member=exclude_member)
    if escrow:
        members = {d["device_id"] for d in sm.active_devices(mac.roster(space_id)[0], exclude_member)}
        body["escrow_wraps"] = escrow_wraps(mac, org_id, space_id, new_key, body["epoch"], members)
    return body, new_key


def test_policy_two_admins_every_new_key_is_escrowed(env):
    a, b = macs(env, "a", "b")
    org_id = create_org(a, recovery=2)
    # one admin only: the creator's own wrap is enough (min(2, admins))
    s1, res = create_org_space(a, org_id)
    assert res["ok"], res
    assert a.get(f"/v1/spaces/{s1}").json()["escrow"]["ok"] is True
    assert org_op(a, org_id, "org.admin_add", {"member_id": b.member_id, "device": b.device.public()})["ok"]
    st = a.get(f"/v1/spaces/{s1}").json()["escrow"]
    assert st["required"] == 2 and st["ok"] is False and [m["device_id"] for m in st["missing"]] == [b.device.device_id]
    # an admin's Mac fills the gap
    wraps = escrow_wraps(a, org_id, s1, a.key(s1), 1, {a.device.device_id})
    res = a.op(s1, "escrow.wrap", {"epoch": 1, "wraps": wraps})
    assert res["ok"] and res["effects"]["escrow_ok"] is True, res
    # a new org space without the second admin's wrap is refused; with it, accepted
    _, res = create_org_space(a, org_id, escrow=False)
    assert res["error"] == "escrow_required" and res["missing"] == [b.device.device_id]
    s2, res = create_org_space(a, org_id)
    assert res["ok"], res
    # a new key without escrow is refused, with it accepted
    body, _ = rotation(a, org_id, s2, escrow=False)
    res = a.op(s2, "epoch.rotate", body)
    assert res["ok"] is False and res["error"] == "escrow_required"
    body, key2 = rotation(a, org_id, s2)
    res = a.op(s2, "epoch.rotate", body)
    assert res["ok"], res
    a.space_keys[s2][2] = key2
    # B's escrow wrap of epoch 2 opens the new key on B's Mac
    r = b.get(f"/v1/orgs/{org_id}/escrow")
    assert r.status_code == 200, r.text
    mine = {x["space_id"]: x for x in r.json()["spaces"]}
    assert mine[s2]["epoch"] == 2
    assert sm.unwrap_space_key(mine[s2]["wrap"], b.device.seal_priv, s2, 2, b.device.device_id) == key2
    # escrow wraps only go to admin devices; non-admins cannot post them
    stranger = sm.Device()
    bad = sm.wraps_for(key2, [stranger.public()], s2, 2)
    res = a.op(s2, "escrow.wrap", {"epoch": 2, "wraps": bad})
    assert res["ok"] is False and res["error"] == "bad_wraps"


def test_recover_a_space_after_losing_its_only_admin(env):
    """V7-S7: A is the org space's only admin and loses the Mac. B (the other org admin, never a member of the space)
    takes it over with the escrowed key, removes A and rotates; C keeps working; A's old device is out."""
    a, b, c = macs(env, "a", "b", "c")
    org_id = create_org(a, recovery=2)
    assert org_op(a, org_id, "org.admin_add", {"member_id": b.member_id, "device": b.device.public()})["ok"]
    space_id, res = create_org_space(a, org_id)
    assert res["ok"], res
    inv = a.invite(space_id, role="write")
    jr = c.request_join(space_id, inv)
    assert jr.status_code == 200, jr.text
    assert a.approve(space_id, jr.json()["request_id"])["ok"]
    c.sync_keys(space_id)
    shared = c.share(space_id, "合成：周四B203复测机械臂")
    assert shared["result"]["ok"]
    # B is not a member: it cannot read the space
    assert b.get(f"/v1/spaces/{space_id}").status_code == 401
    # A's Mac is lost. B: first the organization drops A (its escrow wraps go), then B recovers the space.
    res = org_op(b, org_id, "org.admin_remove", {"member_id": a.member_id})
    assert res["ok"], res
    summary = b.get(f"/v1/orgs/{org_id}").json()
    assert {"space_id": space_id, "member_id": a.member_id} in summary["former_admins"]
    esc = {x["space_id"]: x for x in b.get(f"/v1/orgs/{org_id}/escrow").json()["spaces"]}[space_id]
    key1 = sm.unwrap_space_key(esc["wrap"], b.device.seal_priv, space_id, esc["epoch"], b.device.device_id)
    wire = b.device.op(space_id, b.member_id, "space.recover", {"device": b.device.public()})
    r = env["c"].post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]})
    res = r.json()["results"][0]
    assert res["ok"], res
    # B is an admin member now and reads what C shared
    b.space_keys[space_id] = {}
    b.sync_keys(space_id)
    assert b.key(space_id, 1) == key1
    assert b.read_items(space_id)[shared["item_id"]]["text"] == "合成：周四B203复测机械臂"
    assert b.get(f"/v1/spaces/{space_id}").json()["me"]["role"] == "admin"
    # B removes A with a new key (escrow: B is the only admin left, its member wrap is enough). B's Mac builds the
    # device list from the space's signed log read together with the organization's (its own takeover is in it).
    org = sm.org_roster(b.get(f"/v1/orgs/{org_id}").json()["ops"], org_id)
    roster = sm.replay(b.get(f"/v1/spaces/{space_id}/ops", since=0, limit=1000).json()["ops"], space_id, org=org)[0]
    new_key = os.urandom(32)
    devices = sm.active_devices(roster, exclude_member=a.member_id)
    assert {d["device_id"] for d in devices} == {b.device.device_id, c.device.device_id}
    body = {"member_id": a.member_id, "epoch": 2, "wraps": sm.wraps_for(new_key, devices, space_id, 2),
            "epoch_link": sm.epoch_link(new_key, key1, space_id, 2)}
    res = b.op(space_id, "member.remove", body)
    assert res["ok"], res
    b.space_keys[space_id][2] = new_key
    # C's Mac verifies the takeover against the organization's signed log, and gets the new key
    ops = c.get(f"/v1/spaces/{space_id}/ops", since=0, limit=1000).json()["ops"]
    roster, accepted, rejected = sm.replay(ops, space_id, org=org)
    assert not rejected and roster["members"][b.member_id]["status"] == "active"
    assert roster["members"][a.member_id]["status"] == "removed"
    # without the org's log the takeover is not admitted (a member Mac never trusts the Spark's word for it)
    _, _, rejected = sm.replay(ops, space_id)
    assert "space.recover" in [e["type"] for e in rejected]
    c.sync_keys(space_id)
    assert c.epoch(space_id) == 2
    # A's old device is out and gets no new key
    r = a.get(f"/v1/spaces/{space_id}/keys")
    assert r.status_code == 403 and r.json()["error"] == "not_member"


def test_recover_is_refused_without_escrow_or_rights(env):
    a, b, c = macs(env, "a", "b", "c")
    org_id = create_org(a, recovery=1)
    assert org_op(a, org_id, "org.admin_add", {"member_id": b.member_id, "device": b.device.public()})["ok"]
    space_id, res = create_org_space(a, org_id, escrow=False)    # policy 1: no escrow needed, none given
    assert res["ok"], res
    wire = b.device.op(space_id, b.member_id, "space.recover", {"device": b.device.public()})
    res = env["c"].post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]}).json()["results"][0]
    assert res["ok"] is False and res["error"] == "no_escrow"
    # a non-admin device, a forged signature, someone else's keys named
    wire = c.device.op(space_id, c.member_id, "space.recover", {"device": c.device.public()})
    res = env["c"].post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]}).json()["results"][0]
    assert res["ok"] is False and res["error"] == "unknown_device"
    wire = b.device.op(space_id, b.member_id, "space.recover", {"device": c.device.public()})
    res = env["c"].post(f"/v1/spaces/{space_id}/ops", json={"ops": [wire]}).json()["results"][0]
    assert res["ok"] is False
    # a person-owned space has no escrow
    ps = a.create_space()
    wire = a.device.op(ps, a.member_id, "space.recover", {"device": a.device.public()})
    res = env["c"].post(f"/v1/spaces/{ps}/ops", json={"ops": [wire]}).json()["results"][0]
    assert res["ok"] is False and res["error"] == "bad_op"


def test_a_removed_admin_who_held_only_escrow_forces_a_new_key(env):
    a, b = macs(env, "a", "b")
    org_id = create_org(a, recovery=2)
    assert org_op(a, org_id, "org.admin_add", {"member_id": b.member_id, "device": b.device.public()})["ok"]
    space_id, res = create_org_space(a, org_id)
    assert res["ok"]
    assert org_op(a, org_id, "org.admin_remove", {"member_id": b.member_id})["ok"]
    st = a.get(f"/v1/spaces/{space_id}").json()
    assert st["rotation_pending"] is True                      # B knew the current key through escrow
    shared = a.share(space_id, "合成：新素材")
    assert shared["result"]["ok"] is False and shared["result"]["error"] == "rotation_pending"
    body, key = rotation(a, org_id, space_id)
    assert a.op(space_id, "epoch.rotate", body)["ok"]
    a.space_keys[space_id][2] = key
    assert a.share(space_id, "合成：新素材")["result"]["ok"]
    assert env["spaces"].one("SELECT COUNT(*) AS n FROM escrow_wraps WHERE member_id=?", (b.member_id,))["n"] == 0


# ---- quota ------------------------------------------------------------------------------------------------------


def test_member_quota_per_space(env):
    a, b = macs(env, "a", "b")
    space_id = a.create_space(policy={"member_quota_mb": 1})
    inv = a.invite(space_id)
    jr = b.request_join(space_id, inv)
    assert a.approve(space_id, jr.json()["request_id"])["ok"]
    b.sync_keys(space_id)
    big = os.urandom(600 * 1024)
    first = a.share(space_id, "合成：第一份原件", original=big)
    assert first["result"]["ok"]
    # a second original would pass 1 MB for A in this space
    blob_id = new_id()
    blob = sm.seal_blob(os.urandom(32), big, space_id, new_id(), blob_id)
    r = a.signed("PUT", f"/v1/spaces/{space_id}/blobs/{blob_id}", body=blob, content_type="application/octet-stream")
    assert r.status_code == 413 and r.json()["error"] == "quota_exceeded"
    assert r.json()["quota_bytes"] == 1024 * 1024 and r.json()["used_bytes"] >= len(big)
    # B has its own quota in the same space
    assert b.share(space_id, "合成：B的原件", original=big)["result"]["ok"]
    me = a.get(f"/v1/spaces/{space_id}").json()
    assert me["me"]["usage"]["quota_bytes"] == 1024 * 1024 and me["me"]["usage"]["bytes"] >= len(big)
    assert {m["member_id"]: m["usage_bytes"] > 0 for m in me["members"]} == {a.member_id: True, b.member_id: True}
    # withdrawing frees it
    assert a.ok(space_id, "item.withdraw", {"item_id": first["item_id"]})
    assert a.share(space_id, "合成：第二份原件", original=big)["result"]["ok"]
    # the policy field is validated; 0 means the Spark owner's ceiling (a policy only lowers it, V8R-09)
    res = a.op(space_id, "space.policy", {"policy": {"member_quota_mb": -1}})
    assert res["ok"] is False
    assert a.ok(space_id, "space.policy", {"policy": {"member_quota_mb": 0}})
    ceiling = env["spaces"].member_quota_mb * 1024 * 1024
    assert a.get(f"/v1/spaces/{space_id}").json()["me"]["usage"]["quota_bytes"] == ceiling
    assert a.ok(space_id, "space.policy", {"policy": {"member_quota_mb": 1_000_000}})
    assert a.get(f"/v1/spaces/{space_id}").json()["me"]["usage"]["quota_bytes"] == ceiling


def test_the_spark_default_quota_applies_to_text_too(env):
    env["spaces"].member_quota_mb = 1
    a, = macs(env, "a")
    space_id = a.create_space()
    long_text = "合成长文" * 12000          # ~200 KB of encrypted fields per item
    results = [a.share(space_id, long_text)["result"] for _ in range(7)]
    ok = [r["ok"] for r in results]
    assert ok[:4] == [True] * 4 and False in ok
    assert results[ok.index(False)]["error"] == "quota_exceeded"
