"""v8 integration: the v8 additions (handover packs, snapshots, backup and restore) next to the v7 matter map in one
shared space.

Each part was tested on its own branch; these tests pin what only the merged code can show: one withdrawn item takes
along everything written from it — the map's knot, the handover pack that cites it and the snapshot that cites it — and
a restore that re-applies a withdrawal the backup predates also clears that item from the restored organizer store's
map once a member lends the keys again. Synthetic members and content only.
"""
from __future__ import annotations

import json
from types import SimpleNamespace

from organizer import space_crypto as sc
from test_backup import export, on, restore, world  # noqa: F401  (the fixture is used by name)
from test_spaces import SENTINEL, scan, spark, team  # noqa: F401  (the fixture is used by name)
from test_v7_integration import TEXTS, _live, _shared_matter
from spacekit import payload


def _ops_after(mac, sid: str, seq: int) -> list[dict]:
    r = mac.get(f"/v1/spaces/{sid}/ops", since=seq, limit=100)
    assert r.status_code == 200, r.text
    return r.json()["ops"]


def test_one_withdrawn_item_takes_its_knot_pack_and_snapshot_along(spark):  # noqa: F811
    sid, a, b, ids, org = _shared_matter(spark)
    gone = ids[-1]
    events, _ = _live(b, sid)
    eid = next(e for e in events if gone in e["item_ids"])["event_id"]
    knot = next(e for e in events if e["event_id"] == eid)["map"]["knots"][0]
    assert knot["evidence"] == [gone]
    # the contributor asks for a handover pack; the Spark's (fake) model cites the latest item for the status
    res = b.post_json(f"/v1/spaces/{sid}/organizer/handover-pack", {"matter_id": eid, "from": "小王", "to": "小李"})
    assert res.status_code == 202, res.text
    pack_id = res.json()["pack_id"]
    org.drain()
    got = b.get(f"/v1/spaces/{sid}/organizer/handover-pack/{pack_id}").json()
    assert got["status"] == "ready" and gone in got["pack"]["status"]["evidence"], got
    # the pack goes into the space as a frozen snapshot that lists every item it draws on
    snap = b.share(sid, got["markdown"], kind="snapshot",
                   extra={"snapshot": {"matter_id": eid, "pack_id": pack_id, "cites": [ids[0], gone]}})
    assert snap["result"]["ok"], snap
    handed = a.op(sid, "matter.handover", {"matter_id": eid, "to_member_id": b.member_id,
                                           "pack_item_id": snap["item_id"]})
    assert handed["ok"], handed
    # one withdraw
    res = a.ok(sid, "item.withdraw", {"item_id": gone})
    # the knot: gone from the map the members read and from the store (redrawn without it, as in v7)
    events, st = _live(b, sid)
    cafe = next(e for e in events if e["event_id"] == eid)
    assert gone not in cafe["item_ids"]
    assert cafe["map"] is None or gone not in json.dumps(cafe["map"])
    raw = org.store.one("SELECT map FROM event_maps WHERE event_id=?", (eid,))
    assert raw is None or (gone not in raw["map"] and "招牌明天装好" not in raw["map"])
    # the pack: deleted on the Spark
    assert b.get(f"/v1/spaces/{sid}/organizer/handover-pack/{pack_id}").json()["error"] == "unknown_pack"
    # the snapshot: removed by an unsigned system record naming the cited item, and no member can open it
    removals = [json.loads(sc.b64u_decode(o["op"]))["body"] for o in _ops_after(a, sid, res["seq"])
                if o["type"] == "system.remove"]
    assert {"item_id": snap["item_id"], "reason": "cited_item_gone", "cited_item_id": gone}.items() <= \
        next(r for r in removals if r["item_id"] == snap["item_id"]).items(), removals
    assert snap["item_id"] not in b.read_items(sid) and gone not in b.read_items(sid)
    # a handover can no longer name the removed snapshot
    again = a.op(sid, "matter.handover", {"matter_id": eid, "to_member_id": a.member_id,
                                          "pack_item_id": snap["item_id"]})
    assert again["ok"] is False
    org.drain()
    events, _ = _live(b, sid)
    m = next(e for e in events if e["event_id"] == eid)["map"]
    assert m is not None and gone not in json.dumps(m)
    assert scan(spark.data, [SENTINEL, "招牌明天装好"]) == []


def test_a_restore_that_purges_a_later_withdrawal_clears_it_from_the_restored_map(world):  # noqa: F811
    one = SimpleNamespace(c=world.one.c, clock=world.clock)
    sid, a, (b,) = team(one, "org")
    ids = [a.share(sid, t)["item_id"] for t in TEXTS]
    assert a.lease(sid).status_code == 200
    assert b.organize(sid, [payload(i, t, minutes=10 * n, origin="pa-1")
                            for n, (i, t) in enumerate(zip(ids, TEXTS))]).status_code == 200
    world.one.orgs.get(sid).drain()
    gone = ids[-1]
    live = [e for e in a.get(f"/v1/spaces/{sid}/organizer/state").json()["events"] if gone in e["item_ids"]]
    assert live and live[0]["map"]["knots"][0]["evidence"] == [gone]
    eid = live[0]["event_id"]
    assert a.post_json(f"/v1/spaces/{sid}/organizer/lock", {}).status_code == 200
    r, key = export(a, sid)
    assert r.status_code == 200, r.text
    # after the backup the item is withdrawn; the admin's Mac knows it from its own copy of the log
    assert a.ok(sid, "item.withdraw", {"item_id": gone})
    res = restore(world.two.c, sid, r.content, key, purge=[gone])
    assert res.status_code == 200 and res.json()["purged"] == 1 and res.json()["organizer_store"], res.text
    # the restored organizer store (ciphertext; the Spark cannot open it) still holds the old map: the purge waits
    # for the next lease, when a member lends the keys
    waiting = world.two.spaces.one("SELECT COUNT(*) AS n FROM organizer_purges WHERE space_id=? AND item_id=?",
                                   (sid, gone))
    assert waiting["n"] == 1
    a2 = on(a, world.two)
    assert a2.lease(sid).status_code == 200
    org2 = world.two.orgs.get(sid)
    raw = org2.store.one("SELECT map FROM event_maps WHERE event_id=?", (eid,))
    assert raw is None or (gone not in raw["map"] and "招牌明天装好" not in raw["map"])
    st = a2.get(f"/v1/spaces/{sid}/organizer/state").json()
    cafe = next((e for e in st["events"] if e["event_id"] == eid), None)
    assert cafe is None or (gone not in cafe["item_ids"] and gone not in json.dumps(cafe.get("map")))
    assert gone not in a2.read_items(sid)
    assert scan(world.two.data, [SENTINEL, "招牌明天装好"]) == []
