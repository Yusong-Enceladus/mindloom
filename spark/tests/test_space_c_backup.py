"""v8 contract C with the B4 backups: an audio part, a snapshot's sources and an outbox entry's share_key come back
from a restore and keep their rules there; a restore's purge list also takes the snapshots citing a purged item.
Synthetic content only."""

from __future__ import annotations

import os
from types import SimpleNamespace

from organizer import space_member as sm
from spacekit import new_id
from test_backup import export, make_spark, on, restore, world  # noqa: F401 (fixture)
from test_spaces import team

HOUR = 3_600_000


def snapshot(mac, sid: str, text: str, cites: list, share_key: str, item_id=None) -> dict:
    item_id = item_id or new_id()
    dk, e = os.urandom(32), mac.epoch(sid)
    return {"item_id": item_id, "result": mac.op(
        sid, "item.share", sm.snapshot_body(item_id, 1, cites=cites, share_key=share_key), epoch=e,
        enc=sm.enc_item(dk, {"text": text}, sid, item_id, 1), wrapped_dk=sm.wrap_item_key(mac.key(sid, e), dk, sid, e,
                                                                                         item_id))}


def test_audio_parts_snapshots_and_share_keys_survive_a_restore(world):
    sid, a, (b,) = team(SimpleNamespace(c=world.one.c, clock=world.clock), roles=("write",))
    rec = new_id()
    audio = b.share(sid, "合成：会议里的一段", kind="meeting_online", original=os.urandom(8000), blob_role="audio",
                    segment={"parent_item_id": rec, "start_ms": 0, "end_ms": 4000, "recording_ms": HOUR})
    assert audio["result"]["ok"], audio["result"]
    x = a.share(sid, "合成：周四复测")["item_id"]
    key = new_id()
    snap = snapshot(b, sid, "合成：乙的小结", [x], key)
    assert snap["result"]["ok"], snap["result"]
    r, bkey = export(a, sid)
    assert r.status_code == 200, r.text
    data = r.content
    out = restore(world.two.c, sid, data, bkey).json()
    assert out["ok"] and out["blobs"] == 1, out
    two = world.two.spaces
    assert two.one("SELECT item_id FROM snapshot_cites WHERE space_id=? AND snapshot_id=?",
                   (sid, snap["item_id"]))["item_id"] == x
    assert two.one("SELECT audio, recording_ms FROM segments WHERE space_id=? AND item_id=?",
                   (sid, audio["item_id"])) == {"audio": 1, "recording_ms": HOUR}
    assert two.one("SELECT role FROM blobs WHERE space_id=?", (sid,))["role"] == "audio"
    a2, b2 = on(a, world.two), on(b, world.two)
    # the outbox entry is still recognised, the recording's audio part still taken
    again = snapshot(b2, sid, "合成：乙的小结", [x], key, item_id=snap["item_id"])["result"]
    assert again["ok"] and again["accepted_as"] == "share_key"
    second = b2.share(sid, "合成：同一场另一段", kind="meeting_online", original=os.urandom(4000), blob_role="audio",
                      segment={"parent_item_id": rec, "start_ms": 60_000, "end_ms": 62_000, "recording_ms": HOUR})
    assert second["result"]["error"] == "one_part_per_recording"
    # withdrawing the cited item on the restored Spark takes the snapshot with it
    assert a2.ok(sid, "item.withdraw", {"item_id": x})
    assert two.item(sid, snap["item_id"])["status"] == "removed"
    # a restore whose purge list names the cited item (withdrawn after the backup) does the same
    out = restore(world.one.c, sid, data, bkey, mode="replace", purge=[x]).json()
    assert out["ok"] and out["purged"] == 1, out
    assert world.one.spaces.item(sid, snap["item_id"])["status"] == "removed"
    assert world.one.spaces.item(sid, audio["item_id"])["status"] == "active"
