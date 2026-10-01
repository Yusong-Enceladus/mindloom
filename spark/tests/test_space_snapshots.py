"""v8 contract C2: a snapshot is a frozen summary shared as a new item authored by the sharer (item.share, kind
"snapshot"). It is never revised; it names the space items it draws on, and goes with any of them that is withdrawn
or removed (a system record each), as a handover pack does. Synthetic content only."""

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

SENTINEL = "哨兵QZXV快照"


@pytest.fixture
def spark(settings, chat):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield SimpleNamespace(c=c, app=app, clock=clock, spaces=spaces, data=Path(settings.data_dir))


def team(spark, owner: str = "person", roles: tuple = ("write",)):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org() if owner == "org" else None
    sid = a.create_space(owner, org_id)
    members = []
    for i, role in enumerate(roles):
        m = Mac(spark.c, spark.clock, f"M{i}")
        r = m.request_join(sid, a.invite(sid, role=role))
        assert a.approve(sid, r.json()["request_id"])["ok"]
        m.sync_keys(sid)
        members.append(m)
    return sid, a, members


def snapshot(mac: Mac, sid: str, text: str, *, item_id=None, revision: int = 1, **snap) -> dict:
    """A snapshot share as the Mac makes it (space_member.snapshot_body), the frozen text under its own data key."""
    item_id = item_id or new_id()
    body = sm.snapshot_body(item_id, revision, **snap)
    dk = os.urandom(32)
    e = mac.epoch(sid)
    res = mac.op(sid, "item.share", body, epoch=e,
                 enc=sm.enc_item(dk, {"text": text, "title": "快照"}, sid, item_id, revision),
                 wrapped_dk=sm.wrap_item_key(mac.key(sid, e), dk, sid, e, item_id))
    return {"item_id": item_id, "result": res}


def test_a_snapshot_is_a_new_frozen_item_of_its_sharer(spark):
    sid, a, (b,) = team(spark)
    x = a.share(sid, "合成：周四复测机械臂")["item_id"]
    y = a.share(sid, "合成：周五交报告")["item_id"]
    snap = snapshot(b, sid, f"合成：乙的小结 {SENTINEL}", matter_id="E7", as_of="2026-09-20T10:00:00+08:00",
                    cites=[x, y.upper()])
    assert snap["result"]["ok"], snap["result"]
    item = spark.spaces.item(sid, snap["item_id"])
    assert item["contributor"] == b.member_id and item["kind"] == "snapshot"
    assert {r["item_id"] for r in spark.spaces.all("SELECT item_id FROM snapshot_cites WHERE snapshot_id=?",
                                                   (snap["item_id"],))} == {x, y}
    # members read it like any item; on the Spark it is ciphertext
    assert a.read_items(sid)[snap["item_id"]]["text"].endswith(SENTINEL)
    for p in spark.data.rglob("*"):
        if p.is_file():
            assert SENTINEL.encode() not in p.read_bytes(), p
    # frozen: never revised, and no item turns into one
    again = snapshot(b, sid, "合成：改一改", item_id=snap["item_id"], revision=2)["result"]
    assert again["status"] == 409 and again["error"] == "snapshot_frozen" and again["retry"] == "never"
    z = b.share(sid, "合成：普通素材")["item_id"]
    assert snapshot(b, sid, "合成：变成快照", item_id=z, revision=2)["result"]["error"] == "snapshot_frozen"
    # what it names: ids only, active items of this space, not itself
    sid2 = a.create_space()
    elsewhere = a.share(sid2, "合成：别的空间")["item_id"]
    res = snapshot(b, sid, "合成：引用别处", cites=[elsewhere])["result"]
    assert res["error"] == "unknown_items" and res["item_ids"] == [elsewhere]
    own = new_id()
    assert snapshot(b, sid, "合成：引用自己", item_id=own, cites=[own])["result"]["error"] == "bad_field"
    for bad in ({"title": "明文标题"}, {"matter_id": "带 空格"}, {"pack_id": "x"}, {"as_of": "2099-01-01T00:00:00+00:00"},
                {"cites": "x"}):
        item_id, dk, e = new_id(), os.urandom(32), b.epoch(sid)
        res = b.op(sid, "item.share", {"item_id": item_id, "revision": 1, "kind": "snapshot", "blobs": [],
                                       "snapshot": bad}, epoch=e, enc=sm.enc_item(dk, {"text": "x"}, sid, item_id, 1),
                   wrapped_dk=sm.wrap_item_key(b.key(sid, e), dk, sid, e, item_id))
        assert res["error"] == "bad_field", bad
    # the v8 B3 form (a handover pack: matter and pack ids) still works, and so does a snapshot naming nothing
    assert snapshot(b, sid, "合成：交接包", matter_id="E7", pack_id=new_id())["result"]["ok"]
    assert snapshot(b, sid, "合成：只是一段话")["result"]["ok"]
    # audio never rides on a snapshot
    item_id, dk, e = new_id(), os.urandom(32), b.epoch(sid)
    blob = b.upload(sid, item_id, b"RIFF....WAVE", dk)
    res = b.op(sid, "item.share", {**sm.snapshot_body(item_id, 1), "blobs": [{"blob_id": blob, "role": "audio"}],
                                   "segment": {"parent_item_id": new_id(), "start_ms": 0, "end_ms": 1000,
                                               "recording_ms": 60_000}}, epoch=e,
               enc=sm.enc_item(dk, {"text": "x"}, sid, item_id, 1),
               wrapped_dk=sm.wrap_item_key(b.key(sid, e), dk, sid, e, item_id))
    assert res["error"] == "bad_field"


def test_a_snapshot_goes_with_an_item_it_cites(spark):
    sid, a, (b, m) = team(spark, "org", ("write", "maintain"))
    x = a.share(sid, "合成：周四复测机械臂")["item_id"]
    y = b.share(sid, "合成：乙的记录")["item_id"]
    s1 = snapshot(b, sid, "合成：小结一", cites=[x, y])["item_id"]
    s2 = snapshot(a, sid, "合成：小结的小结", cites=[s1])["item_id"]          # a snapshot of a snapshot
    keep = snapshot(b, sid, "合成：只引乙", cites=[y])["item_id"]
    free = snapshot(b, sid, "合成：不引任何素材")["item_id"]
    head = a.get(f"/v1/spaces/{sid}").json()["head"]
    # A withdraws its own item: the quotes of it in others' frozen summaries go too, by system records
    res = a.ok(sid, "item.withdraw", {"item_id": x})
    ops = a.get(f"/v1/spaces/{sid}/ops", since=head, limit=100).json()["ops"]
    assert [o["type"] for o in ops] == ["item.withdraw", "system.remove", "system.remove"]
    removed = [json.loads(sc.b64u_decode(o["op"]))["body"] for o in ops[1:]]
    assert removed == [{"item_id": s1, "reason": "cited_item_gone", "cited_item_id": x},
                       {"item_id": s2, "reason": "cited_item_gone", "cited_item_id": s1}]
    assert ops[0]["seq"] == res["seq"] and ops[1]["seq"] == res["seq"] + 1
    for gone in (s1, s2):
        item = spark.spaces.item(sid, gone)
        assert item["status"] == "removed" and item["ended_reason"] == "cited_item_gone"
        assert spark.spaces.one("SELECT 1 FROM item_keys WHERE space_id=? AND item_id=?", (sid, gone)) is None
    assert {spark.spaces.item(sid, i)["status"] for i in (keep, free, y)} == {"active"}
    # members accept those records from their own replay of the log (they only remove)
    roster, accepted, rejected = sm.replay(a.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"], sid)
    assert not rejected and sum(e["type"] == "system.remove" for e in accepted) == 2
    readable = a.read_items(sid)
    assert s1 not in readable and s2 not in readable and keep in readable
    # a handover can no longer point at it
    res = a.op(sid, "matter.handover", {"matter_id": "E7", "to_member_id": b.member_id, "pack_item_id": s1})
    assert res["error"] == "item_gone"
    # a maintainer's removal of the other cited item takes the remaining snapshot citing it
    assert m.ok(sid, "item.remove", {"item_id": y, "reason": "privacy"})
    assert spark.spaces.item(sid, keep)["status"] == "removed"
    assert spark.spaces.item(sid, free)["status"] == "active"
    # an overdue privacy takedown carried out by the Spark cascades as well
    z = a.share(sid, "合成：第三条")["item_id"]
    s3 = snapshot(b, sid, "合成：引第三条", cites=[z])["item_id"]
    assert b.ok(sid, "takedown.request", {"takedown_id": new_id(), "item_id": z, "kind": "privacy"})
    spark.clock.advance(hours=73)
    spark.spaces.sweep(sid)
    assert spark.spaces.item(sid, z)["status"] == "removed" and spark.spaces.item(sid, s3)["status"] == "removed"
    records = [r["target"] for r in a.get(f"/v1/spaces/{sid}/audit").json()["records"] if r["action"] == "system.remove"]
    assert {r["reason"] for r in records} == {"cited_item_gone", "takedown_overdue"}
