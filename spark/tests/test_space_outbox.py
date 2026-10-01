"""v8 contract C3: shares made while the link is down wait in the Mac's outbox and are sent later, maybe twice.
The Spark accepts each once: the very same op again is a duplicate; a remade op for the same outbox entry
(share_key) at the item's current revision is that share; a second withdraw or delete is what already happened;
an upload the daily sweep dropped can come again; every refusal says whether to remake, wait or drop; and an op
answered "ok" is committed with a synchronous write. Synthetic content only."""

from __future__ import annotations

import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from conftest import auth_headers
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import HOST_KEY, Clock, Mac, new_id


@pytest.fixture
def spark(settings, chat):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield SimpleNamespace(c=c, app=app, clock=clock, spaces=spaces, data=Path(settings.data_dir),
                              settings=settings)


def team(spark, owner: str = "org", roles: tuple = ("write",), policy=None):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org() if owner == "org" else None
    sid = a.create_space(owner, org_id, policy=policy)
    members = []
    for i, role in enumerate(roles):
        m = Mac(spark.c, spark.clock, f"M{i}")
        r = m.request_join(sid, a.invite(sid, role=role))
        assert a.approve(sid, r.json()["request_id"])["ok"]
        m.sync_keys(sid)
        members.append(m)
    return sid, a, members


def share_wire(mac: Mac, sid: str, item_id: str, text: str, *, revision: int = 1, share_key=None,
               original: bytes | None = None) -> dict:
    """What the outbox holds for one share: the signed op (made now, with the key held now) and its upload."""
    dk, e = os.urandom(32), mac.epoch(sid)
    blobs = [{"blob_id": mac.upload(sid, item_id, original, dk), "role": "original"}] if original else []
    body = {"item_id": item_id, "revision": revision, "kind": "text", "blobs": blobs}
    if share_key:
        body["share_key"] = share_key
    wire = mac.device.op(sid, mac.member_id, "item.share", body, epoch=e,
                         enc=sm.enc_item(dk, {"text": text}, sid, item_id, revision),
                         wrapped_dk=sm.wrap_item_key(mac.key(sid, e), dk, sid, e, item_id))
    return {"wire": wire, "blobs": blobs, "dk": dk}


def send(spark, sid: str, wire: dict) -> dict:
    r = spark.c.post(f"/v1/spaces/{sid}/ops", json={"ops": [wire]})
    assert r.status_code == 200, r.text
    return r.json()["results"][0]


def head(spark, sid: str) -> int:
    return spark.spaces.space(sid)["head"]


def test_a_share_whose_answer_was_lost_is_accepted_once(spark):
    sid, a, (b,) = team(spark)
    item, key = new_id(), new_id()
    first = share_wire(b, sid, item, "合成：第一次发出", share_key=key, original=b"\x01" * 4096)
    res = send(spark, sid, first["wire"])
    assert res["ok"] and not res["duplicate"]
    seq, h = res["seq"], head(spark, sid)
    # the same signed op again (the answer never reached the Mac)
    again = send(spark, sid, first["wire"])
    assert again["ok"] and again["duplicate"] and again["seq"] == seq and head(spark, sid) == h
    # remade by the outbox (new op id, new data key, a new upload): accepted as that same share, its upload dropped
    remade = share_wire(b, sid, item, "合成：第一次发出", share_key=key, original=b"\x01" * 4096)
    new_blob = remade["blobs"][0]["blob_id"]
    assert spark.spaces.blob_path(sid, new_blob).exists()
    res = send(spark, sid, remade["wire"])
    assert res == {"ok": True, "duplicate": True, "accepted_as": "share_key", "seq": seq,
                   "effects": {"item_id": item, "revision": 1, "epoch": 1}, "op_id": res["op_id"]}
    assert head(spark, sid) == h
    assert not spark.spaces.blob_path(sid, new_blob).exists()
    assert spark.spaces.one("SELECT status FROM blobs WHERE blob_id=?", (new_blob,))["status"] == "deleted"
    assert a.read_items(sid)[item]["text"] == "合成：第一次发出"              # the first op's content and key
    # another outbox entry at the same revision is a real conflict, refused for good
    other = share_wire(b, sid, item, "合成：别的内容", share_key=new_id())
    res = send(spark, sid, other["wire"])
    assert res["error"] == "stale_revision" and res["retry"] == "never"
    # a new revision is a new entry; its own retry is accepted once, the old entry's is stale
    key2 = new_id()
    assert send(spark, sid, share_wire(b, sid, item, "合成：第二版", revision=2, share_key=key2)["wire"])["ok"]
    res = send(spark, sid, share_wire(b, sid, item, "合成：第二版", revision=2, share_key=key2)["wire"])
    assert res["accepted_as"] == "share_key"
    assert send(spark, sid, share_wire(b, sid, item, "合成：第一次发出", share_key=key)["wire"])["error"] == \
        "stale_revision"
    # someone else's entry key on my item changes nothing
    c = Mac(spark.c, spark.clock, "C")
    r = c.request_join(sid, a.invite(sid, role="write"))
    assert a.approve(sid, r.json()["request_id"])["ok"]
    c.sync_keys(sid)
    res = send(spark, sid, share_wire(c, sid, item, "合成：冒名", revision=2, share_key=key2)["wire"])
    assert res["error"] == "forbidden"


def test_a_queued_share_across_a_key_rotation(spark):
    sid, a, (b, c) = team(spark, "org", ("write", "write"))
    # made while the link was down, at epoch 1; meanwhile C is removed (epoch 2)
    item, key = new_id(), new_id()
    queued = share_wire(b, sid, item, "合成：断网时记下的", share_key=key)
    assert a.remove_member(sid, c.member_id)["ok"]
    res = send(spark, sid, queued["wire"])
    assert res["error"] == "stale_epoch" and res["retry"] == "remake"
    assert sm.outbox_action(res) == "remake"
    b.sync_keys(sid)
    res = send(spark, sid, share_wire(b, sid, item, "合成：断网时记下的", share_key=key)["wire"])
    assert res["ok"] and not res["duplicate"]
    # applied, answer lost, then a rotation: the remade op under the new key is still that one share
    item2, key2 = new_id(), new_id()
    sent = send(spark, sid, share_wire(b, sid, item2, "合成：发出去了", share_key=key2)["wire"])
    assert sent["ok"]
    assert a.rotate(sid)["ok"]
    b.sync_keys(sid)
    res = send(spark, sid, share_wire(b, sid, item2, "合成：发出去了", share_key=key2)["wire"])
    assert res["ok"] and res["accepted_as"] == "share_key" and res["seq"] == sent["seq"]
    # while a leaver's key is still current nothing new is shared; the outbox remakes after the rotation
    d = Mac(spark.c, spark.clock, "D")
    r = d.request_join(sid, a.invite(sid, role="write"))
    assert a.approve(sid, r.json()["request_id"])["ok"]
    assert d.ok(sid, "member.leave", {})
    res = send(spark, sid, share_wire(b, sid, new_id(), "合成：等换钥匙")["wire"])
    assert res["error"] == "rotation_pending" and res["retry"] == "remake"


def test_an_upload_the_sweep_dropped_comes_again(spark):
    sid, a, (b,) = team(spark)
    item = new_id()
    queued = share_wire(b, sid, item, "合成：带原件", share_key=new_id(), original=os.urandom(2048))
    blob = queued["blobs"][0]["blob_id"]
    sealed = spark.spaces.blob_path(sid, blob).read_bytes()      # the outbox keeps the sealed upload
    spark.clock.advance(hours=25)                                # the link stays down for a day
    assert spark.spaces.sweep(sid)["blobs"] == 1
    res = send(spark, sid, queued["wire"])
    assert res["error"] == "unknown_blob" and res["retry"] == "later"
    put = lambda data: b.signed("PUT", f"/v1/spaces/{sid}/blobs/{blob}", body=data,
                                content_type="application/octet-stream")
    assert put(sealed[:-1] + bytes([sealed[-1] ^ 1])).status_code == 409   # other bytes under that id
    r = put(sealed)
    assert r.status_code == 200 and r.json()["duplicate"] is False
    assert put(sealed).json()["duplicate"] is True
    assert send(spark, sid, queued["wire"])["ok"]
    assert a.get(f"/v1/spaces/{sid}/blobs/{blob}").content == sealed
    # once its item is gone, the upload is over
    assert b.ok(sid, "item.withdraw", {"item_id": item})
    r = put(sealed)
    assert r.status_code == 410 and r.json()["error"] == "blob_gone"


def test_a_second_withdraw_or_delete_is_what_already_happened(spark):
    sid, a, (b,) = team(spark)
    x = b.share(sid, "合成：要撤回的")["item_id"]
    first = b.ok(sid, "item.withdraw", {"item_id": x})
    h = head(spark, sid)
    again = b.ok(sid, "item.withdraw", {"item_id": x})
    assert again["duplicate"] and again["accepted_as"] == "withdrawn" and again["seq"] == first["seq"]
    assert b.ok(sid, "item.delete", {"item_id": x})["accepted_as"] == "withdrawn"
    assert head(spark, sid) == h
    assert a.op(sid, "item.withdraw", {"item_id": x})["error"] == "item_gone"     # not A's to withdraw
    # past the window a delete becomes one takedown request, however often it is sent
    y = b.share(sid, "合成：过了窗口")["item_id"]
    spark.clock.advance(hours=25)
    t1 = b.ok(sid, "item.delete", {"item_id": y})
    t2 = b.ok(sid, "item.delete", {"item_id": y})
    assert t1["effects"]["status"] == t2["effects"]["status"] == "takedown_requested"
    assert t2["accepted_as"] == "open_takedown" and t2["effects"]["takedown_id"] == t1["effects"]["takedown_id"]
    assert spark.spaces.one("SELECT COUNT(*) AS n FROM takedowns WHERE item_id=?", (y,))["n"] == 1


def test_an_accepted_op_survives_a_restart_and_refusals_say_what_to_do(spark):
    assert spark.spaces.one("PRAGMA synchronous")["synchronous"] == 2          # FULL: synced at every commit
    sid, a, (b,) = team(spark, "person", ("write",), policy={"member_quota_mb": 1})
    item, key = new_id(), new_id()
    entry = share_wire(b, sid, item, "合成：重启前", share_key=key)
    assert send(spark, sid, entry["wire"])["ok"]
    # another process over the same files (the Spark restarted)
    restarted = Spaces(spark.settings.data_dir, now=spark.clock, host_keys=lambda: [HOST_KEY])
    try:
        assert restarted.apply_ops(sid, [entry["wire"]])["results"][0]["duplicate"] is True
        remade = share_wire(b, sid, item, "合成：重启前", share_key=key)
        assert restarted.apply_ops(sid, [remade["wire"]])["results"][0]["accepted_as"] == "share_key"
    finally:
        restarted.close()
    # quota: send the same op again once space is freed
    big = share_wire(b, sid, new_id(), "合" * 40_000, original=os.urandom(1_000_000))
    res = send(spark, sid, big["wire"])
    assert res["status"] == 413 and res["error"] == "quota_exceeded" and res["retry"] == "later"
    assert sm.outbox_action(res) == "later"
    assert sm.outbox_action({"ok": True, "duplicate": True}) == "done"
    assert sm.outbox_action({"ok": False, "error": "forbidden", "retry": "never"}) == "drop"
    assert sm.outbox_action({"ok": False, "error": "whatever"}) == "drop"
    # a bad signature is never worth another try
    fresh = share_wire(b, sid, new_id(), "合成：签名坏了")["wire"]
    sig = fresh["sig"]
    res = send(spark, sid, dict(fresh, sig=sig[:-4] + ("AAAA" if not sig.endswith("AAAA") else "BBBB")))
    assert res["error"] == "bad_signature" and res["retry"] == "never"
