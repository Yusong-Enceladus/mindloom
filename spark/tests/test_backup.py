"""v8 B4: encrypted backup of a space (op log, keys, ciphertext blobs, the organizer store) and the restore drill:
restore onto a fresh Spark and onto a damaged one, then check that members read exactly what they read before.
Synthetic members and content only."""

from __future__ import annotations

import dataclasses
import json
import os
import struct
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from conftest import auth_headers
from organizer import backup
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import HOST_KEY, Clock, Mac, new_id, payload
from test_spaces import scan, team

SENTINEL = "哨兵BK-5521 合成：B203真机叠衣实验改到周四"


def make_spark(settings, chat, data_dir: Path, clock: Clock):
    s = dataclasses.replace(settings, data_dir=data_dir)
    org = build_organizer(s, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(s, organizer=org, spaces=spaces)
    client = TestClient(app, headers=auth_headers(app))
    client.__enter__()
    return SimpleNamespace(c=client, app=app, spaces=spaces, orgs=app.state.space_organizers, data=data_dir)


@pytest.fixture
def world(settings, chat, tmp_path):
    clock = Clock()
    one = make_spark(settings, chat, tmp_path / "spark1", clock)
    two = make_spark(settings, chat, tmp_path / "spark2", clock)
    yield SimpleNamespace(one=one, two=two, clock=clock, chat=chat)
    one.c.__exit__(None, None, None)
    two.c.__exit__(None, None, None)


def populate(w):
    """An org space with an admin (A), a contributor (M0) and a member removed (M1): items with originals, one
    withdrawn, a key rotation, and an organizer store with shared matters."""
    sid, a, (m0, m1) = team(SimpleNamespace(c=w.one.c, clock=w.clock), roles=("write", "read"))
    s1 = m0.share(sid, SENTINEL, original=b"\x89PNG synthetic original " + os.urandom(2048))
    s2 = m0.share(sid, "合成：咖啡馆 豆子报价每公斤120", original=os.urandom(4096))
    s3 = a.share(sid, "合成：咖啡馆 开业定在十月")
    gone = m0.share(sid, "合成：咖啡馆 这条会撤回")
    assert all(x["result"]["ok"] for x in (s1, s2, s3, gone))
    assert m0.ok(sid, "item.withdraw", {"item_id": gone["item_id"]})
    assert a.remove_member(sid, m1.member_id)["ok"]
    m0.sync_keys(sid)
    assert a.lease(sid).status_code == 200
    r = m0.organize(sid, [payload(s2["item_id"], "咖啡馆 豆子报价每公斤120"),
                          payload(s3["item_id"], "咖啡馆 开业定在十月", minutes=5)])
    assert r.status_code == 200, r.text
    w.one.orgs.get(sid).drain()
    assert a.post_json(f"/v1/spaces/{sid}/organizer/lock", {}).status_code == 200
    return sid, a, m0, m1, {"s1": s1, "s2": s2, "s3": s3, "gone": gone}


def export(mac: Mac, sid: str, epoch: int | None = None):
    backup_id = new_id()
    e = epoch or mac.epoch(sid)
    key = sm.backup_key(mac.key(sid, e), backup_id)
    r = mac.post_json(f"/v1/spaces/{sid}/backup", {"backup_id": backup_id, "epoch": e, "key": key.hex()})
    return r, key


def restore(client, sid: str, data: bytes, key: bytes, **opts):
    return client.post(f"/v1/spaces/{sid}/restore", content=data,
                       headers={"X-Mindloom-Backup-Key": key.hex(), "X-Mindloom-Restore": json.dumps(opts),
                                "Content-Type": "application/octet-stream"})


def ops_of(mac: Mac, sid: str) -> list:
    r = mac.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000)
    assert r.status_code == 200, r.text
    return r.json()["ops"]


def on(mac: Mac, spark) -> Mac:
    """The same Mac (keys, device) talking to another Spark."""
    other = Mac(spark.c, mac.clock, mac.name)
    other.device, other.member_id, other.space_keys, other.data_keys = mac.device, mac.member_id, mac.space_keys, \
        mac.data_keys
    return other


def test_restore_drill_onto_a_fresh_spark(world):
    sid, a, m0, m1, items = populate(world)
    r, key = export(a, sid)
    assert r.status_code == 200 and r.headers["x-mindloom-backup"], r.text
    data = r.content
    assert data.startswith(backup.MAGIC)
    # what sits on the admin's disk: no content, no ids beyond the space and backup ids in the header
    for needle in (SENTINEL.encode(), "咖啡馆".encode(), m0.member_id.encode(), items["s1"]["item_id"].encode(),
                   a.device.device_id.encode(), b"item.share", b"mlenc1", b"MLB1"):
        assert needle not in data, needle
    # only an admin pulls a backup, with a key of the current epoch
    assert export(m0, sid)[0].status_code == 403
    assert export(a, sid, epoch=1)[0].json()["error"] == "stale_epoch"
    # the drill: a fresh Spark (the owner restores), then every member reads exactly what it read before
    r = restore(world.two.c, sid, data, key)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["organizer_store"] is True and out["org"] == "restored" and out["blobs"] == 2
    a2, m02, m12 = on(a, world.two), on(m0, world.two), on(m1, world.two)
    assert ops_of(a2, sid) == ops_of(a, sid)
    assert m02.read_items(sid) == m0.read_items(sid)
    assert SENTINEL in json.dumps(m02.read_items(sid), ensure_ascii=False)
    for name in ("s1", "s2"):
        blob_id = items[name]["blobs"][0]["blob_id"]
        assert m02.get(f"/v1/spaces/{sid}/blobs/{blob_id}").content == m0.get(f"/v1/spaces/{sid}/blobs/{blob_id}").content
    assert m02.get(f"/v1/spaces/{sid}/keys").json() == m0.get(f"/v1/spaces/{sid}/keys").json()
    assert items["gone"]["item_id"] not in m02.read_items(sid)              # withdrawn stays withdrawn
    assert m12.get(f"/v1/spaces/{sid}/keys").status_code == 403             # removed stays removed
    # the organizer store comes back too: the same matters, opened with the members' key
    assert a2.lease(sid).status_code == 200
    st1 = {e["title"]: sorted(e["item_ids"]) for e in json.loads(json.dumps(
        a2.get(f"/v1/spaces/{sid}/organizer/state").json()["events"])) if not e["deleted"]}
    assert st1 and all(len(v) >= 1 for v in st1.values())
    assert a.lease(sid).status_code == 200
    st0 = {e["title"]: sorted(e["item_ids"]) for e in a.get(f"/v1/spaces/{sid}/organizer/state").json()["events"]
           if not e["deleted"]}
    assert st0 == st1
    # and the restored Spark keeps working: a new share, a new key
    assert m02.share(sid, "合成：恢复之后的新素材")["result"]["ok"]
    assert a2.rotate(sid)["ok"]
    # nothing readable at rest on the new Spark either
    assert scan(world.two.data, [SENTINEL, "咖啡馆"]) == []


def test_a_changed_truncated_or_foreign_backup_is_refused(world):
    sid, a, m0, m1, items = populate(world)
    r, key = export(a, sid)
    data = r.content
    head_end = data.index(b"\n", len(backup.MAGIC)) + 1
    flipped = bytearray(data)
    flipped[head_end + 40] ^= 1
    assert restore(world.two.c, sid, bytes(flipped), key).json()["error"] == "bad_backup"
    # drop the final frame
    frames, pos = [], head_end
    while pos < len(data):
        (n,) = struct.unpack(">I", data[pos:pos + 4])
        frames.append(data[pos:pos + 4 + n])
        pos += 4 + n
    truncated = data[:head_end] + b"".join(frames[:-1]) if len(frames) > 1 else data[:-10]
    assert restore(world.two.c, sid, truncated, key).json()["error"] == "bad_backup"
    assert restore(world.two.c, sid, data + b"x", key).json()["error"] == "bad_backup"
    assert restore(world.two.c, sid, data, os.urandom(32)).json()["error"] == "bad_backup"
    assert restore(world.two.c, new_id(), data, key).json()["error"] == "bad_backup"   # another space's route
    # an existing space is not overwritten unless asked
    assert restore(world.one.c, sid, data, key).json()["error"] == "space_exists"
    assert not world.two.spaces.one("SELECT 1 FROM spaces WHERE space_id=?", (sid,))


def repack(data: bytes, key: bytes, change) -> bytes:
    """A backup re-encrypted with the right key after `change(manifest)`: what a member who knows the space key
    could forge. The restore must still refuse what the signed log does not admit."""
    import io
    fh = io.BytesIO(data)
    header, line = backup.read_header(fh)
    records = list(backup.decrypt_records(fh, key, line))
    manifest = json.loads(records[0][1])
    change(manifest)
    records[0] = (b"M", json.dumps(manifest).encode())
    sealer = backup._Sealer(key, line)
    plain = b"".join(backup._record(k, p) for k, p in records)
    chunks = [plain[i:i + backup.CHUNK] for i in range(0, len(plain), backup.CHUNK)] or [b""]
    return backup.MAGIC + line + b"".join(sealer.frame(c, i == len(chunks) - 1) for i, c in enumerate(chunks))


def test_a_forged_manifest_is_refused_by_the_log_replay(world):
    sid, a, m0, m1, items = populate(world)
    r, key = export(a, sid)
    stranger = sm.Device()

    def add_device(man):
        man["tables"]["devices"].append({"space_id": sid, "device_id": stranger.device_id, "member_id": m0.member_id,
                                         "sign_pub": stranger.public()["sign_pub"],
                                         "seal_pub": stranger.public()["seal_pub"], "status": "active",
                                         "added_seq": 1})

    def edit_op(man):
        op = next(o for o in man["tables"]["ops"] if o["type"] == "member.remove")
        raw = backup.sc.b64u_decode(op["op"]["$b64"])
        op["op"]["$b64"] = backup.sc.b64u(raw.replace(m1.member_id.encode(), m0.member_id.encode()))

    def drop_op(man):
        man["tables"]["ops"] = [o for o in man["tables"]["ops"] if o["type"] != "item.withdraw"]

    for change, detail in ((add_device, "device row"), (edit_op, "not signed"), (drop_op, "gaps")):
        res = restore(world.two.c, sid, repack(r.content, key, change), key)
        assert res.status_code == 422 and detail in res.json()["detail"], (detail, res.json())
    assert restore(world.two.c, sid, repack(r.content, key, lambda m: None), key).status_code == 200


def test_items_withdrawn_after_the_backup_are_purged_again(world):
    sid, a, m0, m1, items = populate(world)
    r, key = export(a, sid)
    # after the backup, M0 withdraws s1; the restoring Mac knows it from its own copy of the log
    assert m0.ok(sid, "item.withdraw", {"item_id": items["s1"]["item_id"]})
    res = restore(world.two.c, sid, r.content, key, purge=[items["s1"]["item_id"]])
    assert res.status_code == 200 and res.json()["purged"] == 1, res.text
    m02 = on(m0, world.two)
    assert items["s1"]["item_id"] not in m02.read_items(sid)
    blob_id = items["s1"]["blobs"][0]["blob_id"]
    assert m02.get(f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 410
    assert ops_of(m02, sid)[-1]["type"] == "system.remove"
    assert scan(world.two.data, [SENTINEL]) == []


def test_restore_over_a_damaged_space_and_who_may_do_it(world):
    sid, a, m0, m1, items = populate(world)
    r, key = export(a, sid)
    # damage: an original's ciphertext is lost on disk
    blob_id = items["s2"]["blobs"][0]["blob_id"]
    world.one.spaces.blob_path(sid, blob_id).unlink()
    assert m0.get(f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 410
    # a contributor coming through the gate may not restore; an admin of the space may
    path = world.one.spaces.root / "drill.mlbk"
    path.write_bytes(r.content)
    with pytest.raises(backup.SpaceError) as e:
        backup.restore(world.one.spaces, world.one.orgs, sid, path, key, mode="replace",
                       member={"member_id": m0.member_id, "device_id": m0.device.device_id})
    assert e.value.code == "forbidden"
    out = backup.restore(world.one.spaces, world.one.orgs, sid, path, key, mode="replace",
                         member={"member_id": a.member_id, "device_id": a.device.device_id})
    assert out["ok"] and out["org"] == "kept"
    assert m0.get(f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 200
    audit = a.get(f"/v1/spaces/{sid}/audit").json()["entries"] if "entries" in a.get(f"/v1/spaces/{sid}/audit").json() \
        else a.get(f"/v1/spaces/{sid}/audit").json()
    text = json.dumps(audit, ensure_ascii=False)
    assert "space.backup" in text and "space.restore" in text and SENTINEL not in text
