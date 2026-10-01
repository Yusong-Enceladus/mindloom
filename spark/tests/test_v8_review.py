"""Regression tests for the adversarial review of claude/v8 (Spark side; findings V8R-01..V8R-16). Synthetic data
only. Each test asserts the safe behaviour; the R-numbered ones are the review's own proof tests (two of them had a
precondition the fix now refuses, noted where they were adapted)."""

from __future__ import annotations

import io
import json
import os
from types import SimpleNamespace

import pytest

from organizer import backup
from organizer import space_member as sm

from organizer.spaces import SpaceError
from spacekit import Clock, Mac, new_id, payload
from test_access import join_member, make_ticket, enroll, MemberClient, rig, gate_program  # noqa: F401
from test_backup import export, make_spark, on, repack, restore, world  # noqa: F401 (fixture)
from test_spaces import team

SENTINEL = "哨兵REVIEW-V8 合成：B203 真机叠衣实验改到周四"
HOUR_MS = 3_600_000


def _reseal(data: bytes, key: bytes, mutate) -> bytes:
    """Decrypt an MLBK1 stream with its key, let `mutate` change the manifest, encrypt it again (same key)."""
    fh = io.BytesIO(data)
    header, line = backup.read_header(fh)
    records = list(backup.decrypt_records(fh, key, line))
    out = []
    for kind, pl in records:
        if kind == b"M":
            manifest = json.loads(pl.decode())
            mutate(manifest)
            pl = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode()
        out.append(backup._record(kind, pl))
    plain = b"".join(out)
    sealer = backup._Sealer(key, line)
    frames = [backup.MAGIC + line]
    while len(plain) > backup.CHUNK:
        frames.append(sealer.frame(plain[:backup.CHUNK], False))
        plain = plain[backup.CHUNK:]
    frames.append(sealer.frame(plain, True))
    return b"".join(frames)


def test_R1_restore_by_a_space_admin_cannot_write_rows_into_another_space(rig):
    """A teammate who is admin only of their OWN space restores a crafted backup of it whose manifest carries a
    members row and a devices row for the VICTIM space. Safe: refused (or the foreign rows ignored)."""
    clock = rig["clock"]
    # the victim: the Spark owner's Mac creates a space and shares a sentinel item, then organizes it
    owner = Mac(rig["owner"], clock, "owner")
    victim = owner.create_space(name="合成：实验室共享空间")
    shared = owner.share(victim, SENTINEL)
    assert shared["result"]["ok"], shared
    # the attacker: any teammate with a member ticket, through the gate; it makes its own space X
    device, member_id, out, mc = join_member(rig)
    att = Mac(mc, clock, "attacker")
    att.device, att.member_id = device, member_id
    own = att.create_space(name="合成：我自己的空间")
    # not a member of the victim space
    assert att.get(f"/v1/spaces/{victim}").status_code == 401
    r, key = export(att, own)
    assert r.status_code == 200, r.text

    def mutate(m):
        dev = next(d for d in m["tables"]["devices"] if d["device_id"] == device.device_id)
        mem = next(x for x in m["tables"]["members"] if x["member_id"] == member_id)
        m["tables"]["devices"].append({**dev, "space_id": victim})
        m["tables"]["members"].append({**mem, "space_id": victim, "role": "admin", "status": "active"})

    crafted = _reseal(r.content, key, mutate)
    r = restore(mc, own, crafted, key, mode="replace")
    # SAFE: a restore of space X never touches space Y
    after = att.get(f"/v1/spaces/{victim}")
    assert after.status_code in (401, 403), (r.status_code, r.text, after.status_code, after.text[:300])


def test_R1b_restore_cannot_lift_the_spaces_policy_quota(rig):
    """A space admin restores its space's own backup with policy member_quota_mb = 0 (no quota) and owner_member
    rewritten. Safe: the Spark keeps the signed policy (the restore cannot change what the log says)."""
    clock = rig["clock"]
    device, member_id, out, mc = join_member(rig)
    att = Mac(mc, clock, "attacker")
    att.device, att.member_id = device, member_id
    own = att.create_space(name="合成：配额", policy={"member_quota_mb": 1})
    before = rig["spaces"].space(own)["policy"]
    r, key = export(att, own)

    def mutate(m):
        pol = json.loads(m["space"]["policy"])
        pol["member_quota_mb"] = 0
        m["space"]["policy"] = json.dumps(pol)

    r = restore(mc, own, _reseal(r.content, key, mutate), key, mode="replace")
    assert rig["spaces"].space(own)["policy"].get("member_quota_mb") == before.get("member_quota_mb"), r.text


def test_R2_member_ticket_cannot_claim_a_member_id_already_known_on_this_spark(rig):
    """The owner's Mac is a member of spaces under member id O but has no access record (it uses the link token).
    An invitee redeeming an ordinary member ticket names O as its member id. Safe: refused (V7-S2 binding)."""
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    sid = owner.create_space(name="合成：空间")
    ticket_id, secret, r = make_ticket(rig, seed=80)
    assert r.status_code == 200, r.text
    thief = sm.Device()
    r = enroll(rig, ticket_id, secret, thief, owner.member_id, seed=81)
    assert r.status_code in (403, 409), r.text


def test_R2b_squatted_member_id_then_passes_the_join_binding(rig):
    """Consequence of R2: with the owner's member id squatted through access, the thief's device passes the
    'member id bound to its keys' join check in a space the owner is not in."""
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    owner.create_space(name="合成：A")
    # another admin's space the owner is not in (made through the gate by a second teammate)
    d2, m2, out2, mc2 = join_member(rig, seed=90)
    adm = Mac(mc2, clock, "admin2")
    adm.device, adm.member_id = d2, m2
    other = adm.create_space(name="合成：B")
    inv = adm.invite(other)
    ticket_id, secret, r = make_ticket(rig, seed=82)
    thief = sm.Device()
    r = enroll(rig, ticket_id, secret, thief, owner.member_id, seed=83)
    if r.status_code != 200:
        return  # R2 fixed
    th = Mac(MemberClient(rig, r.json()["credential"], r.json()["access_id"]), clock, "thief")
    th.device, th.member_id = thief, owner.member_id
    r = th.request_join(other, inv, member_id=owner.member_id)
    # SAFE: member_id_taken (O is bound to the owner's device key)
    assert r.status_code == 409 and r.json().get("error") == "member_id_taken", r.text


def test_R1c_injected_admin_reads_the_victim_spaces_organized_text_and_removes_items(rig, chat):
    """Impact of R1: the injected 'admin' reads the victim space's organized (masked) text while a member's lease
    is open, and can sign destructive ops there."""
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    victim = owner.create_space(name="合成：实验室共享空间")
    shared = owner.share(victim, SENTINEL)
    device, member_id, out, mc = join_member(rig)
    att = Mac(mc, clock, "attacker")
    att.device, att.member_id = device, member_id
    own = att.create_space(name="合成：我自己的空间")
    r, key = export(att, own)

    def mutate(m):
        dev = next(d for d in m["tables"]["devices"] if d["device_id"] == device.device_id)
        mem = next(x for x in m["tables"]["members"] if x["member_id"] == member_id)
        m["tables"]["devices"].append({**dev, "space_id": victim})
        m["tables"]["members"].append({**mem, "space_id": victim, "role": "admin", "status": "active"})

    refused = restore(mc, own, _reseal(r.content, key, mutate), key, mode="replace")
    assert refused.status_code == 422 and refused.json()["error"] == "bad_backup", refused.text   # fixed: refused
    # the victim's own Mac organizes as usual (lease + masked payload)
    assert owner.lease(victim).status_code == 200
    assert owner.organize(victim, [payload(shared["item_id"], SENTINEL)]).status_code == 200
    rig["app"].state.space_organizers.get(victim).drain()
    s = att.get(f"/v1/spaces/{victim}/organizer/state", since=0)
    leaked = s.status_code == 200 and "B203" in s.text
    summary = att.get(f"/v1/spaces/{victim}")
    rm = att.op(victim, "item.remove", {"item_id": shared["item_id"]})
    assert not leaked and not rm.get("ok") and summary.status_code == 401, (s.status_code, leaked, rm)


def test_R3_restore_of_an_older_backup_brings_a_removed_member_back(settings, chat, tmp_path):
    """Backup while M1 is a member, then M1 is removed (key rotation), then an admin restores that backup (the
    drill / a damaged space). Safe: M1 stays removed and the epoch does not go back to a key M1 holds."""
    from types import SimpleNamespace
    from test_backup import make_spark
    from test_spaces import team
    from spacekit import Clock
    clock = Clock()
    one = make_spark(settings, chat, tmp_path / "spark1", clock)
    try:
        sid, a, (m0, m1) = team(SimpleNamespace(c=one.c, clock=clock), roles=("write", "read"))
        assert m0.share(sid, SENTINEL)["result"]["ok"]
        r, key = export(a, sid)
        assert r.status_code == 200, r.text
        assert a.remove_member(sid, m1.member_id)["ok"]
        epoch_after_removal = one.spaces.space(sid)["epoch"]
        assert m1.get(f"/v1/spaces/{sid}").status_code == 403
        out = restore(one.c, sid, r.content, key, mode="replace")
        assert out.status_code == 200, out.text
        back = m1.get(f"/v1/spaces/{sid}")
        epoch_now = one.spaces.space(sid)["epoch"]
        assert back.status_code == 403 and epoch_now >= epoch_after_removal, (back.status_code, epoch_now,
                                                                               epoch_after_removal)
    finally:
        one.c.__exit__(None, None, None)


def test_R4_any_member_lifts_the_storage_quota_by_making_its_own_space(rig):
    """The Spark's per-member quota (ORGANIZER_MEMBER_QUOTA_MB, here 1 MB) is only a default: any teammate makes
    its own space with member_quota_mb 0 ("no quota") and stores beyond it on the owner's disk."""
    clock = rig["clock"]
    rig["spaces"].member_quota_mb = 1
    device, member_id, out, mc = join_member(rig)
    att = Mac(mc, clock, "attacker")
    att.device, att.member_id = device, member_id
    own = att.create_space(name="合成：无限", policy={"member_quota_mb": 0})
    stored = 0
    for _ in range(3):
        item = new_id()
        r = att.signed("PUT", f"/v1/spaces/{own}/blobs/{new_id()}",
                       body=sm.seal_blob(os.urandom(32), os.urandom(900 * 1024), own, item, new_id()),
                       content_type="application/octet-stream")
        if r.status_code == 200:
            stored += r.json()["size"]
    assert stored <= 1024 * 1024, f"stored {stored} bytes past a 1 MB Spark quota ({r.status_code} {r.text[:200]})"


def test_R5_bridge_owner_token_smuggled_as_a_second_authorization_header(rig):
    """The gate checks the LAST Authorization header (dict()) but forwards every one; Starlette reads the FIRST.
    A member key holder who knows the link token (e.g. a teammate who used the owner's SSH account before v8)
    becomes caller 'owner' on member routes. Safe: refused (one Authorization header only, the member's)."""
    from test_access import run_bridge
    _, _, out, _ = join_member(rig)
    owner = rig["app"].state.link_token
    raw = (f"GET /v1/access/me HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {owner}\r\n"
           f"Authorization: Bearer {out['credential']}\r\n\r\n").encode()
    got = run_bridge(rig, out["access_id"], raw)
    assert b'"caller":"owner"' not in got, got[:400]


def test_R6_admin_of_any_own_space_unpairs_a_teammate_from_the_whole_spark(rig):
    """X (a plain teammate) makes its own space, invites Y (e.g. the lab's org admin) into it; once Y joined, X
    is 'an admin of Y's scope' and unpairs Y's Mac from the Spark (all spaces and orgs). Safe: refused."""
    clock = rig["clock"]
    dx, mx, outx, mcx = join_member(rig, seed=50)
    dy, my, outy, mcy = join_member(rig, seed=70)
    x = Mac(mcx, clock, "X")
    x.device, x.member_id = dx, mx
    y = Mac(mcy, clock, "Y")
    y.device, y.member_id = dy, my
    lab_org = y.create_org()                 # Y administers the lab's organization
    sid = x.create_space(name="合成：X 的小组")
    inv = x.invite(sid)
    r = y.request_join(sid, inv)
    assert r.status_code == 200, r.text
    assert x.approve(sid, r.json()["request_id"])["ok"]
    r = mcx.delete(f"/v1/access/members/{outy['access_id']}")
    assert r.status_code == 403, (r.status_code, r.text, lab_org)


def test_R7_unpaired_member_is_let_back_in_by_any_teammate_and_still_reads_the_space(rig):
    """The owner unpairs teammate M (who is in the owner's space S). Unpairing leaves M's device an active member
    of S with S's key (removal waits for someone to click). Any other teammate T who made a space of its own may
    invite, so T's member ticket lets M's same Mac enroll again, and M reads S at once. Safe: an unpaired device
    stays out of the spaces until a space admin re-admits it (or unpair removes it from them)."""
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    sid = owner.create_space(name="合成：实验室")
    dm, mm, outm, mcm = join_member(rig, seed=50)
    m = Mac(mcm, clock, "M")
    m.device, m.member_id = dm, mm
    inv = owner.invite(sid)
    r = m.request_join(sid, inv)
    assert r.status_code == 200, r.text
    assert owner.approve(sid, r.json()["request_id"])["ok"]
    assert rig["owner"].delete(f"/v1/access/members/{outm['access_id']}").json()["ok"]
    assert m.get(f"/v1/spaces/{sid}").status_code == 401       # credential dead
    # T: any teammate; makes a space of its own and so "may invite"
    dt, mt, outt, mct = join_member(rig, seed=70)
    t = Mac(mct, clock, "T")
    t.device, t.member_id = dt, mt
    t.create_space(name="合成：T")
    ticket_id, secret, r = make_ticket(rig, client=mct, seed=80)
    assert r.status_code == 403, r.text                       # fixed (V8R-06): a space admin invites nobody new
    ticket_id, secret, r = make_ticket(rig, seed=80)          # even the owner's ticket ...
    assert r.status_code == 200, r.text
    r = enroll(rig, ticket_id, secret, dm, mm, seed=81)       # ... does not take M's same Mac, same member id
    assert r.status_code == 409 and r.json()["error"] == "device_revoked", r.text
    # and whatever way the unpaired device found in, the spaces refuse it
    with pytest.raises(SpaceError) as e:
        rig["spaces"]._refuse_unpaired(dm.device_id)
    assert e.value.code == "device_revoked"


def test_R8_restore_spools_an_unlimited_body_from_any_member_before_any_check(rig):
    """POST /v1/spaces/{any uuid}/restore through the gate: the whole body is written to the Spark's disk before
    the admin check and with no size limit (here 45 MB > the 40 MB body limit, to a space that does not exist).
    Safe: refused up front (403/404/413) instead of reading it all."""
    _, _, out, mc = join_member(rig)
    body = b"MLBK1\n" + b"x" * (45 * 1024 * 1024)
    r = mc.post(f"/v1/spaces/{new_id()}/restore", content=body,
                headers={"X-Mindloom-Backup-Key": "00" * 32, "Content-Type": "application/octet-stream"})
    assert r.status_code in (403, 404, 413), (r.status_code, r.text[:200])


# ---- further regressions (beyond the review's own proof tests) ---------------------------------------------------


def test_V8R01_rows_are_checked_against_the_signed_log_on_a_full_restore(world):
    """Onto a Spark without the space (the full path): a backup whose member row raises a role or brings a removed
    member back, whose policy lifts the quota, whose epoch goes back, or that carries a row of another space, is
    refused; the untouched one restores."""
    sid, a, (m0, m1) = team(SimpleNamespace(c=world.one.c, clock=world.clock), roles=("read", "write"))
    assert m1.share(sid, SENTINEL)["result"]["ok"]
    assert a.remove_member(sid, m1.member_id)["ok"]
    r, key = export(a, sid)

    def raise_role(m):
        next(x for x in m["tables"]["members"] if x["member_id"] == m0.member_id)["role"] = "admin"

    def back_from_removal(m):
        next(x for x in m["tables"]["members"] if x["member_id"] == m1.member_id)["status"] = "active"

    def lift_quota(m):
        pol = json.loads(m["space"]["policy"])
        pol["member_quota_mb"] = 0
        m["space"]["policy"] = json.dumps(pol)

    def epoch_back(m):
        m["space"]["epoch"] = 1

    def foreign_row(m):
        m["tables"]["hidden"].append({"space_id": new_id(), "member_id": m0.member_id, "item_id": new_id()})

    for change, detail in ((raise_role, "member row"), (back_from_removal, "member row"), (lift_quota, "policy"),
                           (epoch_back, "epoch"), (foreign_row, "another space")):
        res = restore(world.two.c, sid, repack(r.content, key, change), key)
        assert res.status_code == 422 and detail in res.json()["detail"], (detail, res.json())
    assert restore(world.two.c, sid, repack(r.content, key, lambda m: None), key).status_code == 200


def test_V8R03_a_backup_older_than_the_log_only_fills_in_data(world):
    """The Spark's log holds the backup's and more: no row goes back. A removed member stays removed, the epoch
    stays, a damaged blob of an item still there comes back, a withdrawn item's blob does not."""
    sid, a, (m0, m1) = team(SimpleNamespace(c=world.one.c, clock=world.clock), roles=("write", "read"))
    keep = m0.share(sid, "合成：留着的", original=os.urandom(3000))
    gone = m0.share(sid, "合成：之后撤回的", original=os.urandom(3000))
    r, key = export(a, sid)
    assert m0.ok(sid, "item.withdraw", {"item_id": gone["item_id"]})
    assert a.remove_member(sid, m1.member_id)["ok"]
    epoch = world.one.spaces.space(sid)["epoch"]
    world.one.spaces.blob_path(sid, keep["blobs"][0]["blob_id"]).unlink()      # damage
    out = restore(world.one.c, sid, r.content, key, mode="replace")
    assert out.status_code == 200, out.text
    res = out.json()
    assert res["applied"] == "fill" and res["log"] == "current_newer" and res["blobs"] == 1, res
    assert world.one.spaces.space(sid)["epoch"] == epoch
    assert m1.get(f"/v1/spaces/{sid}").status_code == 403
    assert m0.get(f"/v1/spaces/{sid}/blobs/{keep['blobs'][0]['blob_id']}").status_code == 200
    assert m0.get(f"/v1/spaces/{sid}/blobs/{gone['blobs'][0]['blob_id']}").status_code == 410
    assert not world.one.spaces.blob_path(sid, gone["blobs"][0]["blob_id"]).exists()


def test_V8R03_backup_newer_replaces_and_a_diverged_log_is_refused(world):
    """This Spark lost the log's tail: the newer backup replaces it. Two logs that differ: refused for an admin
    through the gate and for the owner, unless the owner forces it."""
    sid, a, (m0,) = team(SimpleNamespace(c=world.one.c, clock=world.clock), roles=("write",))
    old, old_key = export(a, sid)
    assert m0.share(sid, "合成：后来的一条")["result"]["ok"]
    new, new_key = export(a, sid)
    # the second Spark has the older state only
    assert restore(world.two.c, sid, old.content, old_key).status_code == 200
    res = restore(world.two.c, sid, new.content, new_key, mode="replace")
    assert res.status_code == 200 and res.json()["applied"] == "full" and res.json()["log"] == "backup_newer", res.text
    # diverge: each Spark appends a different op
    assert on(m0, world.two).share(sid, "合成：二号上的一条")["result"]["ok"]
    assert m0.share(sid, "合成：一号上的一条")["result"]["ok"]
    head, key3 = export(a, sid)
    res = restore(world.two.c, sid, head.content, key3, mode="replace")
    assert res.status_code == 409 and res.json()["error"] == "log_diverges", res.text
    path = world.two.spaces.root / "diverged.mlbk"
    path.write_bytes(head.content)
    with pytest.raises(SpaceError) as e:
        backup.restore(world.two.spaces, world.two.orgs, sid, path, key3, mode="replace",
                       member={"member_id": a.member_id, "device_id": a.device.device_id}, force=True)
    assert e.value.code == "forbidden"
    res = restore(world.two.c, sid, head.content, key3, mode="replace", force=True)
    assert res.status_code == 200 and res.json()["applied"] == "full", res.text


def test_V8R05_the_organizer_refuses_a_second_authorization_header(rig):
    """Without the gate in between too: two Authorization (or gate stamp) headers are refused outright."""
    _, _, out, _ = join_member(rig)
    owner = rig["app"].state.link_token
    r = rig["bare"].get("/v1/access/me", headers=[("Authorization", f"Bearer {owner}"),
                                                  ("Authorization", f"Bearer {out['credential']}")])
    assert r.status_code == 400 and r.json()["error"] == "duplicate_header", r.text
    # the bridge forwards one Authorization only, the credential it checked
    from test_access import run_bridge
    raw = (f"GET /v1/access/me HTTP/1.1\r\nHost: o\r\nAuthorization: Bearer {out['credential']}\r\n"
           f"X-Mindloom-Gate: member:{out['access_id']}:{'0' * 64}\r\nX-Mindloom-Gate: x\r\n\r\n").encode()
    got = run_bridge(rig, out["access_id"], raw)
    assert b"400" in got.split(b"\r\n", 1)[0] and b'"caller"' not in got, got[:300]


def test_V8R06_V8R14_a_space_admin_gets_no_spark_wide_powers_an_org_admin_does(rig):
    clock = rig["clock"]
    dx, mx, outx, mcx = join_member(rig, seed=50)
    x = Mac(mcx, clock, "X")
    x.device, x.member_id = dx, mx
    x.create_space(name="合成：X 的空间")
    me = mcx.get("/v1/access/me").json()
    assert me["space_admin_of"] and me["may_invite"] is False
    assert mcx.get("/v1/infra/health").status_code == 403
    assert make_ticket(rig, client=mcx, seed=60)[2].status_code == 403
    # an org admin: health without the owner's personal store, may invite
    dy, my, outy, mcy = join_member(rig, seed=70)
    y = Mac(mcy, clock, "Y")
    y.device, y.member_id = dy, my
    y.create_org()
    h = mcy.get("/v1/infra/health")
    assert h.status_code == 200 and "personal_store" not in h.json()["organizer"], h.text
    assert "personal_store" in rig["owner"].get("/v1/infra/health").json()["organizer"]
    assert mcy.get("/v1/access/me").json()["may_invite"] is True
    # X cannot see Y's Macs, nor Y unpair X (X is in none of Y's organizations' spaces)
    assert mcx.get("/v1/access/devices", params={"member_id": my}).status_code == 403
    assert mcy.delete(f"/v1/access/members/{outx['access_id']}").status_code == 403


def test_V8R06_the_owner_may_let_space_admins_invite(settings, org, tmp_path, gate_program):
    from fastapi.testclient import TestClient
    from organizer.api import create_app
    from organizer.spaces import Spaces
    from test_phone_link import FOREIGN
    settings.authorized_keys = tmp_path / "home" / ".ssh" / "authorized_keys"
    settings.authorized_keys.parent.mkdir(parents=True)
    settings.authorized_keys.write_bytes(FOREIGN)
    settings.gate_path = gate_program
    settings.space_admins_invite = True
    clock = Clock()
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [])
    app = create_app(settings, organizer=org, spaces=spaces)
    app.state.access.now = clock
    with TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"}) as owner, \
            TestClient(app) as bare:
        r2 = {"app": app, "owner": owner, "bare": bare, "clock": clock, "ak": settings.authorized_keys,
              "access": app.state.access, "spaces": spaces}
        dx, mx, outx, mcx = join_member(r2, seed=50)
        x = Mac(mcx, clock, "X")
        x.device, x.member_id = dx, mx
        x.create_space(name="合成：X")
        assert make_ticket(r2, client=mcx, seed=60)[2].status_code == 200


def test_V8R09_total_storage_and_spaces_per_member(rig):
    clock = rig["clock"]
    rig["spaces"].member_quota_mb = 0          # no per-space ceiling here; the per-member total still holds
    rig["spaces"].member_total_mb = 1
    device, member_id, out, mc = join_member(rig)
    att = Mac(mc, clock, "attacker")
    att.device, att.member_id = device, member_id
    stored = 0
    for i in range(3):                         # one blob per space, three spaces
        sid = att.create_space(name=f"合成：{i}")
        r = att.signed("PUT", f"/v1/spaces/{sid}/blobs/{new_id()}",
                       body=sm.seal_blob(os.urandom(32), os.urandom(450 * 1024), sid, new_id(), new_id()),
                       content_type="application/octet-stream")
        if r.status_code == 200:
            stored += r.json()["size"]
        else:
            assert r.status_code == 413 and r.json()["scope"] == "spark", r.text
    assert stored <= 1024 * 1024
    rig["spaces"].max_spaces_per_member = 3
    space_id = new_id()
    k1 = os.urandom(32)
    wire = device.op(space_id, member_id, "space.create",
                     {"owner": {"kind": "person"}, "device": device.public(),
                      "wraps": sm.wraps_for(k1, [device.public()], space_id, 1)},
                     epoch=1, enc=sm.enc_op(k1, {"name": "x"}, space_id, new_id()))
    r = mc.post("/v1/spaces", json=wire)
    assert r.status_code == 409 and r.json()["error"] == "too_many_spaces", r.text


def test_V8R10_restore_refused_before_the_body(rig):
    """A member who does not administer the space is refused before any byte is read; a declared length above the
    Spark's limit is refused before reading too."""
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    sid = owner.create_space(name="合成：别人的")
    _, _, out, mc = join_member(rig)
    r = mc.post(f"/v1/spaces/{sid}/restore", content=b"MLBK1\n" + b"x" * 1024,
                headers={"X-Mindloom-Backup-Key": "00" * 32, "Content-Type": "application/octet-stream"})
    assert r.status_code == 403, r.text
    r = rig["owner"].post(f"/v1/spaces/{sid}/restore", content=b"x",
                          headers={"X-Mindloom-Backup-Key": "00" * 32, "Content-Length": str(9 * 1024 ** 3),
                                   "Content-Type": "application/octet-stream"})
    assert r.status_code in (413, 400), r.text


def test_V8R15_a_meeting_item_carries_its_audio_part_only_and_never_most_of_the_recording(rig):
    clock = rig["clock"]
    owner = Mac(rig["owner"], clock, "owner")
    sid = owner.create_space(name="合成：会议")
    rec = new_id()
    whole = owner.share(sid, "合成：会议原件", kind="meeting_online", original=os.urandom(4000),
                        segment={"parent_item_id": rec, "start_ms": 0, "end_ms": 60_000, "recording_ms": HOUR_MS})
    assert whole["result"]["ok"] is False and whole["result"]["error"] == "bad_field", whole["result"]
    most = owner.share(sid, "合成：几乎整场", kind="meeting_online", original=os.urandom(4000), blob_role="audio",
                       segment={"parent_item_id": rec, "start_ms": 0, "end_ms": 90_000, "recording_ms": 100_000})
    assert most["result"]["error"] == "whole_recording", most["result"]
    part = owner.share(sid, "合成：一段", kind="meeting_online", original=os.urandom(4000), blob_role="audio",
                       segment={"parent_item_id": rec, "start_ms": 0, "end_ms": 80_000, "recording_ms": 100_000})
    assert part["result"]["ok"], part["result"]
    seg = {"start_ms": 0, "end_ms": 80_000, "recording_ms": 100_000}
    assert sm.audio_part_ok(80_000, seg) and not sm.audio_part_ok(90_000, {**seg, "end_ms": 90_000})
