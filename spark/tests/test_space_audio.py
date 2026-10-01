"""v8 contract C1: a meeting segment's audio, end-to-end encrypted to the members of a shared space. The Spark stores
the ciphertext and can never open it; parts only (never a whole recording, at most 15 minutes, one audio part per
recording and member in a space, the size bounded by the length); purged with the item. Synthetic audio only."""

from __future__ import annotations

import base64
import os
import struct
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.exceptions import InvalidTag
from fastapi.testclient import TestClient

from conftest import auth_headers
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import AUDIO_BYTES_PER_S, AUDIO_OVERHEAD_BYTES, MAX_SEGMENT_MS, Spaces, audio_limit_bytes
from spacekit import HOST_KEY, Clock, Mac, new_id, payload

AUDIO_SENTINEL = b"QZXV-AUDIO-SENTINEL-v8"
HOUR = 3_600_000


@pytest.fixture
def spark(settings, chat):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        yield SimpleNamespace(c=c, app=app, clock=clock, spaces=spaces, data=Path(settings.data_dir))


def team(spark, owner: str = "org", roles: tuple = ("write",), policy=None):
    a = Mac(spark.c, spark.clock, "A")
    org_id = a.create_org() if owner == "org" else None
    sid = a.create_space(owner, org_id, policy=policy)
    members = []
    for i, role in enumerate(roles):
        m = Mac(spark.c, spark.clock, f"M{i}")
        r = m.request_join(sid, a.invite(sid, role=role))
        assert r.status_code == 200, r.text
        assert a.approve(sid, r.json()["request_id"])["ok"]
        m.sync_keys(sid)
        members.append(m)
    return sid, a, members


def wav(seconds: float, marker: bytes = AUDIO_SENTINEL) -> bytes:
    """A synthetic 16 kHz mono 16-bit WAV of this length with a marker in its samples (no real sound)."""
    n = int(16_000 * seconds)
    samples = (marker * (2 * n // len(marker) + 1))[: 2 * n]
    header = b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, 16_000, 32_000, 2, 16) + b"data" + struct.pack("<I", len(samples))
    return header + samples


def part(parent: str, start: int, end: int, recording: int = HOUR) -> dict:
    return {"parent_item_id": parent, "start_ms": start, "end_ms": end, "recording_ms": recording}


def share_audio(mac: Mac, sid: str, seconds: float, segment: dict, *, kind: str = "meeting_offline",
                item_id=None, revision: int = 1, extra=None):
    return mac.share(sid, "合成：会议里这一段的转写", kind=kind, item_id=item_id, revision=revision,
                     original=wav(seconds), blob_role="audio", segment=segment, extra=extra)


def blob_files(spark, sid: str) -> list[Path]:
    d = spark.spaces.space_dir(sid) / "blobs"
    return sorted(d.iterdir()) if d.exists() else []


def scan(root: Path, needle: bytes) -> list[str]:
    return [str(p) for p in root.rglob("*") if p.is_file() and needle in p.read_bytes()]


def test_an_audio_part_reaches_the_members_and_the_spark_cannot_open_it(spark):
    sid, a, (b, r) = team(spark, "org", ("write", "read"))
    parent = new_id()
    audio = wav(30)
    shared = b.share(sid, "合成：周四 B203 的那三十秒", kind="meeting_offline", original=audio, blob_role="audio",
                     segment=part(parent, 60_000, 90_000))
    assert shared["result"]["ok"], shared["result"]
    blob_id = shared["blobs"][0]["blob_id"]
    # every member device opens it: the item key from the op log, the space key from its own wrap
    for mac in (a, r):
        got = mac.get(f"/v1/spaces/{sid}/blobs/{blob_id}")
        assert got.status_code == 200
        entry = next(e for e in mac.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"]
                     if e["type"] == "item.share")
        k = entry["item_key"]
        dk = sm.unwrap_item_key(k["wrapped_dk"], mac.key(sid, k["epoch"]), sid, k["epoch"], shared["item_id"])
        opened = sm.open_blob(got.content, dk, sid, shared["item_id"], blob_id)
        assert opened == audio
        # the member Mac checks the sound against the part the signed op declares before playing it
        seconds = (len(opened) - 44) / 32_000
        assert sm.audio_part_ok(int(seconds * 1000), part(parent, 60_000, 90_000))
        assert not sm.audio_part_ok(int(seconds * 1000) + 60_000, part(parent, 60_000, 90_000))
    # the Spark: ciphertext only on disk, and none of the keys it is ever lent opens it
    assert scan(spark.data, AUDIO_SENTINEL) == []
    sealed = spark.spaces.blob_path(sid, blob_id).read_bytes()
    assert sealed.startswith(b"MLB1") and len(sealed) == len(audio) + 32
    lease = a.lease_keys(sid)
    lent = [bytes.fromhex(lease["store_key"]), bytes.fromhex(lease["mask_key"]), sm.backup_key(a.key(sid), new_id())]
    wrapped = spark.spaces.one("SELECT wrapped_dk FROM item_keys WHERE space_id=? AND item_id=?",
                               (sid, shared["item_id"]))["wrapped_dk"]
    for key in lent:
        with pytest.raises(InvalidTag):
            sm.open_blob(sealed, key, sid, shared["item_id"], blob_id)
        with pytest.raises(Exception):
            sm.unwrap_item_key(wrapped, key, sid, 1, shared["item_id"])
    # the organizer gets the part's masked transcript, never its sound
    assert a.lease(sid).status_code == 200
    item = payload(shared["item_id"], "合成：会议里说周四复测", kind="meeting_offline")
    bad = {**item, "kind": "file", "filename": "part.wav", "mime": "audio/wav",
           "bytes_b64": base64.b64encode(audio).decode()}
    res = b.organize(sid, [bad])
    assert res.status_code == 422 and res.json()["error"] == "audio_not_for_organizer"
    assert b.organize(sid, [item]).status_code == 200
    assert scan(spark.data, AUDIO_SENTINEL) == []
    # the space's limits tell the Mac what it may send
    limits = a.get(f"/v1/spaces/{sid}").json()["limits"]
    assert limits["segment_ms"] == MAX_SEGMENT_MS and limits["audio_bytes_per_s"] == AUDIO_BYTES_PER_S


def test_audio_parts_are_parts_short_small_and_one_per_recording(spark):
    sid, a, (b, c) = team(spark, "org", ("write", "write"))
    rec = new_id()
    # the op names the recording's length, and a part is never all of it
    res = share_audio(b, sid, 5, {"parent_item_id": rec, "start_ms": 0, "end_ms": 5_000})["result"]
    assert res["error"] == "bad_field" and res["retry"] == "never"
    short = new_id()
    res = share_audio(b, sid, 5, part(short, 0, 300_000, recording=300_000))["result"]
    assert res["error"] == "whole_recording"
    res = share_audio(b, sid, 5, part(short, 0, 5_000, recording=4_000))["result"]
    assert res["error"] == "bad_field"                                   # recording shorter than the part's end
    res = share_audio(b, sid, 5, part(rec, 0, 16 * 60_000))["result"]
    assert res["error"] == "segment_too_long"
    # audio goes with a meeting or imported media, as one blob
    res = share_audio(b, sid, 5, part(rec, 0, 5_000), kind="dictation")["result"]
    assert res["error"] == "bad_field"
    item_id, dk = new_id(), os.urandom(32)
    blobs = [{"blob_id": b.upload(sid, item_id, wav(2), dk), "role": "audio"} for _ in range(2)]
    e = b.epoch(sid)
    res = b.op(sid, "item.share", {"item_id": item_id, "revision": 1, "kind": "meeting_online", "blobs": blobs,
                                   "segment": part(rec, 0, 2_000)}, epoch=e,
               enc=sm.enc_item(dk, {"text": "两段"}, sid, item_id, 1),
               wrapped_dk=sm.wrap_item_key(b.key(sid, e), dk, sid, e, item_id))
    assert res["error"] == "bad_field"
    # the ciphertext is bounded by the declared length (a "10-second part" cannot carry an hour of sound)
    item_id = new_id()
    big = b.upload(sid, item_id, os.urandom(audio_limit_bytes(10_000) - 32 + 1), dk)
    res = b.op(sid, "item.share", {"item_id": item_id, "revision": 1, "kind": "meeting_online",
                                   "blobs": [{"blob_id": big, "role": "audio"}], "segment": part(rec, 0, 10_000)},
               epoch=e, enc=sm.enc_item(dk, {"text": "十秒"}, sid, item_id, 1),
               wrapped_dk=sm.wrap_item_key(b.key(sid, e), dk, sid, e, item_id))
    assert res["status"] == 413 and res["error"] == "audio_too_large"
    assert res["limit_bytes"] == AUDIO_OVERHEAD_BYTES + 10 * AUDIO_BYTES_PER_S
    # one audio part per recording and member; text parts of it still fit in the 15 minutes
    first = share_audio(b, sid, 20, part(rec, 600_000, 620_000))
    assert first["result"]["ok"], first["result"]
    second = share_audio(b, sid, 20, part(rec, 700_000, 720_000))["result"]
    assert second["status"] == 409 and second["error"] == "one_part_per_recording"
    assert second["item_id"] == first["item_id"]
    assert b.share(sid, "合成：同一场的另一段文字", kind="meeting_offline",
                   segment=part(rec, 700_000, 760_000))["result"]["ok"]
    # another recording, or another member's own recording, has its own part
    assert share_audio(b, sid, 3, part(new_id(), 0, 3_000))["result"]["ok"]
    assert share_audio(c, sid, 3, part(new_id(), 0, 3_000))["result"]["ok"]
    # the same item may be cut again (a new revision) within the window
    again = share_audio(b, sid, 10, part(rec, 600_000, 610_000), item_id=first["item_id"], revision=2)
    assert again["result"]["ok"], again["result"]
    # a space may refuse meeting audio, or keep text only
    assert a.ok(sid, "space.policy", {"policy": {"segment_audio": False}})
    res = share_audio(c, sid, 3, part(new_id(), 0, 3_000))["result"]
    assert res["status"] == 403 and res["error"] == "audio_not_allowed"
    assert a.op(sid, "space.policy", {"policy": {"segment_audio": "yes"}})["error"] == "bad_field"
    tsid, _, (tb,) = team(spark, "person", policy={"originals": "text_only"})
    r = tb.signed("PUT", f"/v1/spaces/{tsid}/blobs/{new_id()}", body=b"MLB1" + os.urandom(64),
                  content_type="application/octet-stream")
    assert r.status_code == 403 and r.json()["error"] == "originals_not_allowed"


def test_withdrawn_or_removed_audio_is_purged_and_frees_the_part(spark):
    sid, a, (b,) = team(spark, "org", ("write",))
    rec = new_id()
    shared = share_audio(b, sid, 15, part(rec, 0, 15_000))
    assert shared["result"]["ok"]
    blob_id = shared["blobs"][0]["blob_id"]
    path = spark.spaces.blob_path(sid, blob_id)
    assert path.exists()
    assert b.ok(sid, "item.withdraw", {"item_id": shared["item_id"]})
    assert not path.exists()
    assert spark.spaces.one("SELECT status FROM blobs WHERE space_id=? AND blob_id=?", (sid, blob_id))["status"] == \
        "deleted"
    assert spark.spaces.one("SELECT 1 FROM item_keys WHERE space_id=? AND item_id=?", (sid, shared["item_id"])) is None
    assert a.get(f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 410
    entry = next(e for e in a.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"]
                 if e["type"] == "item.share")
    assert entry["enc"] is None and entry["purged"] and entry["item_key"] is None
    # the recording's audio part is free again
    other = share_audio(b, sid, 15, part(rec, 30_000, 45_000))
    assert other["result"]["ok"], other["result"]
    # a maintainer's removal purges too
    path2 = spark.spaces.blob_path(sid, other["blobs"][0]["blob_id"])
    assert a.ok(sid, "item.remove", {"item_id": other["item_id"], "reason": "privacy"})
    assert not path2.exists()
    # a new revision replaces the old sound
    third = share_audio(b, sid, 5, part(rec, 50_000, 55_000))
    old = spark.spaces.blob_path(sid, third["blobs"][0]["blob_id"])
    assert share_audio(b, sid, 4, part(rec, 50_000, 54_000), item_id=third["item_id"], revision=2)["result"]["ok"]
    assert not old.exists()
    # an overdue privacy takedown by someone else is carried out by the Spark, sound included
    assert a.ok(sid, "takedown.request", {"takedown_id": new_id(), "item_id": third["item_id"], "kind": "privacy"})
    spark.clock.advance(hours=73)
    spark.spaces.sweep(sid)
    assert blob_files(spark, sid) == []
    assert scan(spark.data, AUDIO_SENTINEL) == []
