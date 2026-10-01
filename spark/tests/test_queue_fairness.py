"""v8 B6: in a shared space's organizer the members take turns in the job queue and matters with a near deadline
come first (items, briefs, maps); the personal store keeps plain time order. Synthetic content only."""

from __future__ import annotations

import json
from datetime import date, timedelta

from organizer.store import Store
from spacekit import new_id, payload
from test_spaces import spark, team  # noqa: F401 (fixture)


def queued_members(org, n: int) -> list[str]:
    origins = {r["item_id"]: r["member_id"] for r in org.store.all("SELECT item_id, member_id FROM space_item_origins")}
    return [origins[j["item_id"]] for j in org.store.job_plan(n)]


def test_members_take_turns_and_a_bulk_import_does_not_hold_others_back(spark):  # noqa: F811
    sid, a, (m,) = team(spark, owner="person", roles=("write",))
    a_items = [a.share(sid, f"合成：A 的素材 {i}")["item_id"] for i in range(8)]
    m_items = [m.share(sid, f"合成：M 的素材 {i}")["item_id"] for i in range(3)]
    assert a.lease(sid).status_code == 200
    # A's bulk import is older than M's three items: plain time order would run all of A's first
    r = a.organize(sid, [payload(i, f"咖啡馆 A{n}", minutes=n) for n, i in enumerate(a_items)])
    assert r.status_code == 200, r.text
    r = m.organize(sid, [payload(i, f"读书会 M{n}", minutes=100 + n) for n, i in enumerate(m_items)])
    assert r.status_code == 200, r.text
    org = spark.orgs.get(sid)
    order = queued_members(org, 11)
    assert order[:6] == [a.member_id, m.member_id] * 3 and order[6:] == [a.member_id] * 5
    # each member's own items stay in time order, and claiming follows the plan
    first = org.store.claim_next_job()
    second = org.store.claim_next_job()
    assert (first["item_id"], second["item_id"]) == (a_items[0], m_items[0])
    assert queued_members(org, 2) == [a.member_id, m.member_id]
    org.store.reset_running_jobs()   # the two claimed above were never run
    org.drain()
    assert org.store.queue_depth() == 0


def test_a_matter_with_a_near_deadline_comes_first(spark):  # noqa: F811
    sid, a, (m,) = team(spark, owner="person", roles=("write",))
    seed = m.share(sid, "合成：读书会 十月场地")["item_id"]
    assert a.lease(sid).status_code == 200
    assert m.organize(sid, [payload(seed, "读书会 十月场地", origin="m-reading")]).status_code == 200
    org = spark.orgs.get(sid)
    org.drain()
    ev = org.store.current_event_link(seed)["event_id"]
    soon = (date.fromisoformat(org._today()) + timedelta(days=3)).isoformat()
    org.store.x("UPDATE events SET status_facts=? WHERE event_id=?",
                (json.dumps([{"text": "场地要在周五前定", "state": "planned", "date": soon, "item_ids": [seed]}]), ev))
    org.store.bump()
    # A queues older items; M adds one more item of the same package (its matter has the deadline) and one other
    a_items = [a.share(sid, f"合成：A {i}")["item_id"] for i in range(4)]
    more = m.share(sid, "合成：读书会 场地报价")["item_id"]
    other = m.share(sid, "合成：M 别的事")["item_id"]
    assert a.organize(sid, [payload(i, f"咖啡馆 A{n}", minutes=n) for n, i in enumerate(a_items)]).status_code == 200
    assert m.organize(sid, [payload(more, "读书会 场地报价", minutes=200, origin="m-reading"),
                            payload(other, "体检 预约", minutes=201, origin="m-other")]).status_code == 200
    assert org.store.urgent_events() == {ev}
    plan = [j["item_id"] for j in org.store.job_plan(6)]
    assert plan[0] == more                          # the deadline's package first, though it is the newest
    assert plan[1:] == [a_items[0], other, a_items[1], a_items[2], a_items[3]]
    # briefs: the urgent matter's card is rewritten first
    org.store.x("UPDATE events SET needs_brief=1 WHERE deleted=0")
    assert org.store.next_brief() == ev
    # a deadline long past or far ahead is not urgent
    far = (date.fromisoformat(org._today()) + timedelta(days=30)).isoformat()
    org.store.x("UPDATE events SET status_facts=? WHERE event_id=?",
                (json.dumps([{"text": "年底前", "state": "planned", "date": far, "item_ids": [seed]}]), ev))
    org.store.bump()
    assert org.store.urgent_events() == set()
    assert [j["item_id"] for j in org.store.job_plan(2)] == [a_items[0], more]


def test_the_personal_store_keeps_time_order(tmp_path):
    store = Store(":memory:")
    assert store.fair_members is False and store.deadline_days == 0
    assert store.job_plan(5) == []
