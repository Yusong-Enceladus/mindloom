"""v8: one member, several Macs (a second Mac through a device ticket, then device.add / org.device_add signed by the
first one), one device id = one member on the whole Spark, unpairing and retiring a Mac, and adding org admins as
signed ops (org.admin_add names a Mac the member already uses here). Through the access routes as a member's Mac
reaches them (credential + gate stamp). Synthetic members only."""

from __future__ import annotations

import os

from organizer import backup
from organizer import space_member as sm
from spacekit import Mac, new_id
from test_access import enroll, gate_program, join_member, make_ticket, MemberClient, rig  # noqa: F401 (fixtures)


def org_ops(mac: Mac, org_id: str, type_: str, body: dict) -> dict:
    r = mac.c.post(f"/v1/orgs/{org_id}/ops", json={"ops": [mac.device.org_op(org_id, mac.member_id, type_, body)]})
    assert r.status_code == 200, r.text
    return r.json()["results"][0]


def first_and_second_mac(rig):
    """Mac 1 enrolled as a new member, an org and an org space of its own with one item; Mac 2 enrolled through a
    device ticket Mac 1 made (same member id)."""
    device1, member_id, out1, mc1 = join_member(rig, seed=50)
    mac1 = Mac(mc1, rig["clock"], "mac1")
    mac1.device, mac1.member_id = device1, member_id
    org_id = mac1.create_org()
    sid = mac1.create_space("org", org_id)
    item = mac1.share(sid, "合成：第一台 Mac 记下的")["item_id"]
    t, secret, r = make_ticket(rig, client=mc1, kind="device", seed=61)
    assert r.status_code == 200, r.text
    device2 = sm.Device()
    r = enroll(rig, t, secret, device2, member_id, seed=62)
    assert r.status_code == 200, r.text
    out2 = r.json()
    mac2 = Mac(MemberClient(rig, out2["credential"], out2["access_id"]), rig["clock"], "mac2")
    mac2.device, mac2.member_id = device2, member_id
    return {"mac1": mac1, "mac2": mac2, "mc1": mc1, "out1": out1, "out2": out2, "org": org_id, "sid": sid,
            "item": item, "member": member_id}


def devices_of(view: dict) -> dict:
    return {d["device_id"]: d for d in view["devices"]}


def add_second_mac(env) -> None:
    mac1, mac2, sid = env["mac1"], env["mac2"], env["sid"]
    e = mac1.epoch(sid)
    assert mac1.ok(sid, "device.add", {"device": mac2.device.public(),
                                       "wraps": sm.wraps_for(mac1.key(sid), [mac2.device.public()], sid, e)})
    res = org_ops(mac1, env["org"], "org.device_add", {"device": mac2.device.public()})
    assert res["ok"] and res["effects"]["device_id"] == mac2.device.device_id, res


def test_a_second_mac_comes_in_through_its_first(rig):
    env = first_and_second_mac(rig)
    mac1, mac2, sid, org_id = env["mac1"], env["mac2"], env["sid"], env["org"]
    # Mac 1 sees its new Mac and what to sign for it
    view = env["mc1"].get("/v1/access/devices").json()
    d2 = devices_of(view)[mac2.device.device_id]
    assert d2["access"]["status"] == "active" and d2["to_add"] == {"spaces": [sid], "orgs": [org_id]}
    assert devices_of(view)[mac1.device.device_id]["to_add"] == {"spaces": [], "orgs": []}
    # Mac 2 is known to this Spark (it may list), but no space knows it yet
    r = mac2.get("/v1/spaces")
    assert r.status_code == 200 and r.json()["spaces"] == []
    assert mac2.get(f"/v1/spaces/{sid}").status_code == 401
    add_second_mac(env)
    assert devices_of(env["mc1"].get("/v1/access/devices").json())[mac2.device.device_id]["to_add"] == \
        {"spaces": [], "orgs": []}
    # Mac 2 opens what Mac 1 shared, shares itself, and is the org admin's device (admin in the org space)
    mac2.sync_keys(sid)
    assert mac2.read_items(sid)[env["item"]]["text"] == "合成：第一台 Mac 记下的"
    assert mac2.share(sid, "合成：第二台 Mac 记下的")["result"]["ok"]
    assert mac2.get(f"/v1/spaces/{sid}").json()["me"]["role"] == "admin"
    assert org_ops(mac2, org_id, "org.policy", {"recovery_admins": 1})["ok"]
    roster = sm.org_roster(mac2.get(f"/v1/orgs/{org_id}").json()["ops"], org_id)
    assert {d["device_id"] for d in sm.escrow_devices(roster)} == {mac1.device.device_id, mac2.device.device_id}
    space_roster = mac2.roster(sid)[0]
    assert set(space_roster["members"][env["member"]]["devices"]) == {mac1.device.device_id, mac2.device.device_id}
    # Mac 2 may join a space its member is not in yet with that member id (Mac 1 vouched for it)...
    host = Mac(rig["owner"], rig["clock"], "host")
    other = host.create_space("person")
    inv = host.invite(other, role="write")
    r = mac2.request_join(other, inv)
    assert r.status_code == 200, r.text
    assert host.approve(other, r.json()["request_id"])["ok"]
    view = env["mc1"].get("/v1/access/devices").json()
    assert other in view["spaces"] and devices_of(view)[mac1.device.device_id]["to_add"]["spaces"] == [other]
    # ...and nobody else can use that member id
    stranger = Mac(rig["owner"], rig["clock"], "stranger")
    stranger.member_id = env["member"]
    r = stranger.request_join(other, host.invite(other, role="read"))
    assert r.status_code == 409 and r.json()["error"] in ("member_exists", "member_id_taken")
    third = host.create_space("person")
    r = stranger.request_join(third, host.invite(third, role="read"))
    assert r.status_code == 409 and r.json()["error"] == "member_id_taken"
    # a plain member sees only its own Macs; an admin also those of a member it invited (in no space yet), whose
    # Mac it can then name in org.admin_add
    _, _, _, mc3 = join_member(rig, seed=80)
    assert mc3.get(f"/v1/access/devices?member_id={env['member']}").status_code == 403
    t, secret, r = make_ticket(rig, client=env["mc1"], seed=90)
    assert r.status_code == 200, r.text
    newcomer, newcomer_id = sm.Device(), new_id()
    assert enroll(rig, t, secret, newcomer, newcomer_id, seed=91).status_code == 200
    seen = env["mc1"].get(f"/v1/access/devices?member_id={newcomer_id}").json()["devices"]
    assert [(d["device_id"], d["seal_pub"]) for d in seen] == [(newcomer.device_id, newcomer.public()["seal_pub"])]
    res = org_ops(mac1, org_id, "org.admin_add", {"member_id": newcomer_id, "device": {
        k: seen[0][k] for k in ("device_id", "sign_pub", "seal_pub")}})
    assert res["ok"], res
    assert rig["owner"].get(f"/v1/access/devices?member_id={env['member']}").json()["member_id"] == env["member"]
    assert rig["owner"].get("/v1/access/devices").status_code == 422


def test_one_device_belongs_to_one_member(rig):
    env = first_and_second_mac(rig)
    mac1, sid, org_id = env["mac1"], env["sid"], env["org"]
    # P: someone with a Mac in a space of this Spark (through the owner's own connection)
    p = Mac(rig["owner"], rig["clock"], "P")
    psid = p.create_space("person")
    # P's device cannot be enrolled for another member, added by another member, or join under another id
    t, secret, _ = make_ticket(rig, seed=70)
    r = enroll(rig, t, secret, p.device, new_id(), seed=71)
    assert r.status_code == 409 and r.json()["error"] == "device_member_conflict"
    e = mac1.epoch(sid)
    res = mac1.op(sid, "device.add", {"device": p.device.public(),
                                      "wraps": sm.wraps_for(mac1.key(sid), [p.device.public()], sid, e)})
    assert res["status"] == 409 and res["error"] == "device_member_conflict"
    alias = Mac(rig["owner"], rig["clock"], "alias")
    alias.device = p.device
    r = alias.request_join(sid, mac1.invite(sid, role="read"))
    assert r.status_code == 409 and r.json()["error"] == "device_member_conflict"
    # org admins are added as signed ops naming the member's own Mac
    res = org_ops(mac1, org_id, "org.admin_add", {"member_id": new_id(), "device": p.device.public()})
    assert res["error"] == "device_member_conflict"
    res = org_ops(mac1, org_id, "org.admin_add", {"member_id": p.member_id, "device": sm.Device().public()})
    assert res["status"] == 409 and res["error"] == "unknown_member_device"
    res = org_ops(mac1, org_id, "org.admin_add", {"member_id": p.member_id, "device": p.device.public()})
    assert res["ok"] and res["effects"] == {"member_id": p.member_id, "device_id": p.device.device_id}
    # the new admin's Mac is now an escrow holder the org spaces lack, and admin where it joins an org space
    st = mac1.get(f"/v1/spaces/{sid}").json()["escrow"]
    assert p.device.device_id in [m["device_id"] for m in st["missing"]]
    r = p.request_join(sid, mac1.invite(sid, role="read"))
    assert mac1.approve(sid, r.json()["request_id"])["ok"]
    assert {m["member_id"]: m["effective_role"] for m in mac1.get(f"/v1/spaces/{sid}").json()["members"]}[
        p.member_id] == "admin"
    assert psid
    # through the gate a Mac signs as its own member only
    wire = mac1.device.op(sid, p.member_id, "item.hide", {"item_id": env["item"]})
    r = env["mc1"].post(f"/v1/spaces/{sid}/ops", json={"ops": [wire]})
    assert r.status_code == 403 and r.json()["error"] == "access_member"


def test_unpairing_and_retiring_a_second_mac(rig):
    env = first_and_second_mac(rig)
    mac1, mac2, sid, org_id = env["mac1"], env["mac2"], env["sid"], env["org"]
    add_second_mac(env)
    # an org space where Mac 2 holds an escrow wrap of the key (and is no member device)
    space_id, k1, op_id = new_id(), os.urandom(32), new_id()
    body = {"owner": {"kind": "org", "org_id": org_id}, "device": mac1.device.public(),
            "wraps": sm.wraps_for(k1, [mac1.device.public()], space_id, 1),
            "escrow_wraps": sm.wraps_for(k1, [mac2.device.public()], space_id, 1)}
    wire = mac1.device.op(space_id, mac1.member_id, "space.create", body, epoch=1, op_id=op_id,
                          enc=sm.enc_op(k1, {"name": "托管"}, space_id, op_id))
    assert env["mc1"].post("/v1/spaces", json=wire).json()["ok"]
    mac1.space_keys[space_id] = {1: k1}
    # Mac 2 is lost: Mac 1 unpairs it; the console lists where it still has to go
    r = env["mc1"].delete(f"/v1/access/members/{env['out2']['access_id']}")
    assert r.status_code == 200 and r.json()["removed"] == 1
    assert mac2.get("/v1/spaces").status_code == 401
    d2 = devices_of(env["mc1"].get("/v1/access/devices").json())[mac2.device.device_id]
    assert d2["access"]["status"] == "revoked" and d2["to_remove"] == {"spaces": [sid], "orgs": [org_id]}
    # an unpaired Mac is not added anywhere again
    e = mac1.epoch(space_id)
    res = mac1.op(space_id, "device.add", {"device": mac2.device.public(),
                                           "wraps": sm.wraps_for(k1, [mac2.device.public()], space_id, e)})
    assert res["error"] == "device_revoked"
    # Mac 1 retires it in the space (with a new key it does not get) and in the organization
    e = mac1.epoch(sid)
    new_key = os.urandom(32)
    res = mac1.op(sid, "device.remove", {"device_id": mac2.device.device_id, "epoch": e + 1,
                                         "wraps": sm.wraps_for(new_key, [mac1.device.public()], sid, e + 1),
                                         "epoch_link": sm.epoch_link(new_key, mac1.key(sid), sid, e + 1)})
    assert res["ok"], res
    mac1.space_keys[sid][e + 1] = new_key
    assert org_ops(mac1, org_id, "org.device_remove", {"device_id": mac1.device.device_id})["error"] == "bad_field"
    res = org_ops(mac1, org_id, "org.device_remove", {"device_id": mac2.device.device_id})
    assert res["ok"] and res["effects"]["rotation_pending"] == [space_id] and res["effects"]["still_member_in"] == []
    assert mac1.get(f"/v1/spaces/{space_id}").json()["rotation_pending"] is True   # it knew that key by escrow
    assert devices_of(env["mc1"].get("/v1/access/devices").json())[mac2.device.device_id]["to_remove"] == \
        {"spaces": [], "orgs": []}
    # the org's signed log (Mac reference and backup check) no longer counts it
    ops = mac1.get(f"/v1/orgs/{org_id}").json()["ops"]
    assert [d["device_id"] for d in sm.escrow_devices(sm.org_roster(ops, org_id))] == [mac1.device.device_id]
    rows = rig["spaces"].all("SELECT * FROM org_ops WHERE org_id=? ORDER BY seq", (org_id,))
    admins = backup.verify_org({"org_ops": rows}, org_id)
    assert set(admins[env["member"]]) == {mac1.device.device_id}
    assert rig["spaces"].escrow_devices(org_id)[0]["device_id"] == mac1.device.device_id
