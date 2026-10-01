"""SPACES-CONTRACT section 5, the end-to-end scenario on the Spark side: two synthetic Mac roots (A and B, each with
its own keys and originals in its own directory) and one Spark app.

  1. A creates an org space and invites B; B joins.
  2. Both share their version of the same matter.
  3. The assembled matter has the union of the items.
  4. B withdraws one item; A removes B.
  5. Rotation happens; B can no longer read new items.
  6. Scan the Spark for plaintext sentinels: none.

The organizer's model is the scripted FakeChat (no GPU); eval/tools/spaces_e2e.py runs the same flow against a
deployed instance with the real model. Invented content only."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidTag
from fastapi.testclient import TestClient

from conftest import auth_headers
from organizer import space_crypto as sc
from organizer import space_member as sm
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient
from organizer.spaces import Spaces
from spacekit import HOST_KEY, Clock, Mac, new_id, payload

SENTINELS = ["哨兵A咖啡馆ZQ1", "哨兵B咖啡馆ZQ2", "13700001111", "a.owner@example.com"]


class Root:
    """A synthetic Mac data root: what the Mac keeps locally (device keys, space keys, originals), in files."""

    def __init__(self, path: Path, mac: Mac):
        self.path = path
        self.mac = mac
        path.mkdir(parents=True)
        (path / "SYNTHETIC_DATA_ROOT").write_text("synthetic")
        self.save()

    def save(self) -> None:
        state = {"device_id": self.mac.device.device_id, "sign_priv": self.mac.device.sign_priv.hex(),
                 "seal_priv": self.mac.device.seal_priv.hex(), "member_id": self.mac.member_id,
                 "space_keys": {s: {str(e): k.hex() for e, k in keys.items()}
                                for s, keys in self.mac.space_keys.items()}}
        p = self.path / "keys.json"
        p.write_text(json.dumps(state))
        os.chmod(p, 0o600)

    def keep_original(self, item_id: str, text: str) -> None:
        (self.path / f"{item_id}.txt").write_text(text, encoding="utf-8")


@pytest.fixture
def world(settings, chat, tmp_path):
    clock = Clock()
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    spaces = Spaces(settings.data_dir, now=clock, host_keys=lambda: [HOST_KEY])
    app = create_app(settings, organizer=org, spaces=spaces)
    with TestClient(app, headers=auth_headers(app)) as c:
        a, b = Mac(c, clock, "A"), Mac(c, clock, "B")
        yield {"c": c, "app": app, "clock": clock, "spaces": spaces, "chat": chat, "spark_dir": Path(settings.data_dir),
               "A": a, "B": b, "rootA": Root(tmp_path / "mac-A", a), "rootB": Root(tmp_path / "mac-B", b)}


def share_matter(mac: Mac, root: Root, sid: str, matter_id: str, texts: list[str]) -> list[str]:
    """A shares its personal matter as a package: each item (original encrypted to the members), then the package
    with the sharer's hints (title) encrypted, then the organizing payload (masked by the Spark's rules)."""
    ids = []
    for i, text in enumerate(texts):
        s = mac.share(sid, text, original=f"原件：{text}".encode())
        assert s["result"]["ok"], s["result"]
        root.keep_original(s["item_id"], text)
        ids.append(s["item_id"])
    op_id = new_id()
    res = mac.op(sid, "matter.share", {"package_id": new_id(), "item_ids": ids, "auto": "ask"}, epoch=mac.epoch(sid),
                 op_id=op_id, enc=sm.enc_op(mac.key(sid), {"title": "咖啡馆开业", "matter_id": matter_id}, sid, op_id))
    assert res["ok"], res
    return ids


def test_two_macs_one_spark(world):
    A, B, c, spaces = world["A"], world["B"], world["c"], world["spaces"]
    # 1. A creates an org space and invites B; B joins (A sees B's name, sealed to A's device)
    org_id = A.create_org()
    sid = A.create_space("org", org_id, name="实验室")
    world["rootA"].save()
    invite = A.invite(sid, role="write")
    r = B.request_join(sid, invite, name="韩策")
    assert r.status_code == 200
    req = A.get(f"/v1/spaces/{sid}/join-requests", status="pending").json()["requests"][0]
    assert sm.open_profile(req["profile"], A.device.seal_priv, sid, req["request_id"]) == {"display_name": "韩策"}
    assert A.approve(sid, req["request_id"])["ok"]
    B.sync_keys(sid)
    world["rootB"].save()
    assert B.key(sid, 1) == A.key(sid, 1)

    # 2. both share their version of the same matter
    a_ids = share_matter(A, world["rootA"], sid, "personal-A-1",
                         [f"咖啡馆 开业定在下周一，{SENTINELS[0]}", f"咖啡馆 装修尾款联系 {SENTINELS[2]}"])
    b_ids = share_matter(B, world["rootB"], sid, "personal-B-7",
                         [f"咖啡馆 豆子报价每公斤120，{SENTINELS[1]}", f"咖啡馆 菜单打样发 {SENTINELS[3]}"])
    # members open each other's originals; the Spark could not
    assert set(A.read_items(sid)) == set(a_ids + b_ids) == set(B.read_items(sid))

    # 3. the assembled matter has the union of the items
    assert A.lease(sid).status_code == 200
    pending = {p["item_id"] for p in A.get(f"/v1/spaces/{sid}/organizer/pending").json()["items"]}
    assert pending == set(a_ids + b_ids)
    texts = {**{i: (world["rootA"].path / f"{i}.txt").read_text() for i in a_ids},
             **{i: (world["rootB"].path / f"{i}.txt").read_text() for i in b_ids}}
    # each contributor's Mac sends its own items (any contributor's Mac with the lease could send them all)
    for mac, ids, matter, base in ((A, a_ids, "personal-A-1", 0), (B, b_ids, "personal-B-7", 30)):
        body = [payload(i, texts[i], minutes=base + n, origin=matter) for n, i in enumerate(ids)]
        assert mac.organize(sid, body).json() == {"accepted": 2, "duplicates": 0}
    world["app"].state.space_organizers.get(sid).drain()
    st = B.get(f"/v1/spaces/{sid}/organizer/state").json()
    live = [e for e in st["events"] if not e["deleted"]]
    assert len(live) == 1 and set(live[0]["item_ids"]) == set(a_ids + b_ids)
    links = {(l["member_id"], l["matter_id"], l["items"]) for l in st["same_as"]}
    assert links == {(A.member_id, "personal-A-1", 2), (B.member_id, "personal-B-7", 2)}
    prompts = json.dumps([call[3] for call in world["chat"].calls], ensure_ascii=False)
    assert SENTINELS[2] not in prompts and SENTINELS[3] not in prompts  # numbers reach the model as placeholders

    # 4. B withdraws one item; A removes B
    assert B.ok(sid, "item.withdraw", {"item_id": b_ids[0]})
    assert A.remove_member(sid, B.member_id)["ok"]
    world["rootA"].save()

    # 5. rotation happened: B can no longer read new items
    assert A.epoch(sid) == 2
    new = A.share(sid, "咖啡馆 开业当天排班")
    assert new["result"]["effects"]["epoch"] == 2
    r = B.get(f"/v1/spaces/{sid}/ops")
    assert r.status_code == 403 and r.json()["error"] == "not_member"
    assert B.get(f"/v1/spaces/{sid}/keys").status_code == 403
    wrapped = spaces.one("SELECT wrapped_dk, epoch FROM item_keys WHERE space_id=? AND item_id=?",
                         (sid, new["item_id"]))
    with pytest.raises(InvalidTag):  # even with the wrap in hand, B's newest key is epoch 1
        sm.unwrap_item_key(wrapped["wrapped_dk"], B.key(sid), sid, wrapped["epoch"], new["item_id"])
    for w in spaces.all("SELECT * FROM key_wraps WHERE space_id=? AND epoch=2", (sid,)):
        with pytest.raises(InvalidTag):
            sm.unwrap_space_key(w["wrap"], B.device.seal_priv, sid, 2, w["device_id"])
    # the space store is re-keyed at the next lease; the withdrawn item is gone, B's other item stays attributed
    assert A.lease(sid).json()["error"] == "wrong_key"
    assert A.lease(sid, previous_epoch=1).status_code == 200
    assert A.organize(sid, [payload(new["item_id"], "咖啡馆 开业当天排班", minutes=90, origin="personal-A-1")]
                      ).json()["accepted"] == 1
    world["app"].state.space_organizers.get(sid).drain()
    st = A.get(f"/v1/spaces/{sid}/organizer/state").json()
    items = {i for e in st["events"] if not e["deleted"] for i in e["item_ids"]}
    assert b_ids[0] not in items and b_ids[1] in items and new["item_id"] in items
    assert (B.member_id, "personal-B-7", 1) in {(l["member_id"], l["matter_id"], l["items"]) for l in st["same_as"]}
    members = {m["member_id"]: m["status"] for m in A.get(f"/v1/spaces/{sid}").json()["members"]}
    assert members == {A.member_id: "active", B.member_id: "removed"}

    # 6. no plaintext sentinel anywhere on the Spark (the Macs' roots hold the originals, as they should)
    hits = []
    for p in world["spark_dir"].rglob("*"):
        if p.is_file():
            data = p.read_bytes()
            hits += [(p.name, s) for s in SENTINELS + ["韩策", "实验室"] if s.encode() in data]
    assert hits == []
    in_roots = [s for s in SENTINELS if any(s.encode() in p.read_bytes()
                                            for root in ("rootA", "rootB") for p in world[root].path.glob("*.txt"))]
    assert in_roots == SENTINELS  # the scan would have found them if they were there
