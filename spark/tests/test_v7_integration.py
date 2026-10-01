"""v7 integration: the matter map (MAP-CONTRACT) inside a shared space (SPACES-CONTRACT).

A shared space's organizer is the same organizer as the personal one, so it draws maps and groups ropes too. These
tests pin what the merge must keep: the space state carries the map, ropes and relations; a withdrawn item leaves no
knot, strand or text behind in the space's map (the v6 purge rule, V7-M1); the package step still runs before the
grouping pass and the maps; nothing readable reaches the disk.
"""
from __future__ import annotations

import json

from spacekit import payload
from test_spaces import SENTINEL, scan, spark, team  # noqa: F401  (the fixture is used by name)

TEXTS = [f"咖啡馆第{i}步：把第{i}件准备做完" for i in range(8)] + [f"咖啡馆第8步：招牌明天装好 {SENTINEL}"]


def _live(mac, sid: str) -> tuple[list[dict], dict]:
    st = mac.get(f"/v1/spaces/{sid}/organizer/state").json()
    return [e for e in st["events"] if not e["deleted"] and not e.get("merged_into")], st


def _shared_matter(spark):
    sid, a, (b,) = team(spark, "org")
    ids = [a.share(sid, t)["item_id"] for t in TEXTS]
    assert a.lease(sid).status_code == 200
    accepted = a.organize(sid, [payload(i, t, minutes=10 * n, origin="pa-1")
                                for n, (i, t) in enumerate(zip(ids, TEXTS))]).json()["accepted"]
    assert accepted == len(TEXTS)
    org = spark.orgs.get(sid)
    org.drain()
    return sid, a, b, ids, org


def test_a_shared_space_draws_its_matter_map_with_ropes_and_relations_in_its_state(spark):
    sid, a, b, ids, org = _shared_matter(spark)
    events, st = _live(b, sid)
    cafe = next(e for e in events if ids[0] in e["item_ids"])
    assert set(ids) <= set(cafe["item_ids"])
    m = cafe["map"]
    assert m is not None and m["skill_version"] == org.registry.skills["matter-map"].version
    # client item ids (the shared item ids), not the organizer's handles
    assert set(m["strands"][0]["item_ids"]) <= set(ids)
    knot = m["knots"][0]
    assert knot["evidence"] == [ids[-1]] and knot["quote_item_id"] == ids[-1]
    assert "ropes" in st and "relations" in st and "facets" in cafe
    assert spark.chat.count("matter-map") == 1
    # the space organizer read the masked payloads; the store and the log on disk hold nothing readable
    assert scan(spark.data, [SENTINEL, "招牌明天装好"]) == []


def test_a_withdrawn_item_leaves_no_knot_or_text_in_the_space_map(spark):
    sid, a, b, ids, org = _shared_matter(spark)
    gone = ids[-1]
    events, _ = _live(a, sid)
    eid = next(e for e in events if gone in e["item_ids"])["event_id"]
    assert org.store.one("SELECT 1 FROM event_maps WHERE event_id=?", (eid,))
    # A withdraws (within the org window): the Spark purges the item from the space's organizer store
    assert a.ok(sid, "item.withdraw", {"item_id": gone})
    events, st = _live(b, sid)
    cafe = next(e for e in events if e["event_id"] == eid)
    assert gone not in cafe["item_ids"]
    m = cafe["map"]
    assert m is None or (gone not in json.dumps(m) and m["stale"] is True)
    raw = org.store.one("SELECT map FROM event_maps WHERE event_id=?", (eid,))
    assert raw is None or (gone not in raw["map"] and "招牌明天装好" not in raw["map"])
    assert gone not in json.dumps(st.get("relations", [])) and gone not in json.dumps(st.get("ropes", []))
    # redrawn without it
    org.drain()
    events, _ = _live(b, sid)
    m = next(e for e in events if e["event_id"] == eid)["map"]
    assert m is not None and gone not in json.dumps(m) and m["stale"] is False


def test_the_package_step_runs_before_grouping_and_maps(spark):
    """The idle hooks (no model calls) run ahead of the grouping pass and the idle maps, so a package the model
    split is whole again before its matter is grouped or drawn."""
    sid, a, b, ids, org = _shared_matter(spark)
    calls = []
    org.idle_hooks.insert(0, lambda: calls.append("hook") or False)
    grouper_run, mapper_run = org.grouper.run, org.mapper.run
    org.grouper.run = lambda *a_, **k: (calls.append("group"), grouper_run(*a_, **k))[1]
    org.mapper.run = lambda *a_, **k: (calls.append("map"), mapper_run(*a_, **k))[1]
    org.grouper.idle_due = lambda: True
    org._step()
    assert calls[:2] == ["hook", "group"]
