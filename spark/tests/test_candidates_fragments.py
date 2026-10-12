"""event-assign candidate retrieval at scale (skills/event-assign/scripts/candidates.py): reserved slots for the
events the score alone would hide, and the compact view of the candidates past the fifth.

All data here is invented for tests: unit vectors in a small space, one axis per topic.
"""

from __future__ import annotations

import importlib.util
import math

from conftest import REPO, assign_out, ingest, make_item


def _load():
    path = REPO / "skills" / "event-assign" / "scripts" / "candidates.py"
    spec = importlib.util.spec_from_file_location("test_candidates_fragments_mod", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cand = _load()
H = 3600.0


def vec(*xs):
    n = math.sqrt(sum(x * x for x in xs))
    return [x / n for x in xs]


def event(eid, centroid, *, n=1, last=0.0, order=1, terms=()):
    return {"event_id": eid, "centroid": centroid, "centroid_norm": 1.0, "first_ts": 0.0, "last_ts": last,
            "person_ids": [], "sources": ["chat"], "order": order, "n": n, "terms": list(terms)}


def item(centroid, ts=0.0, **kw):
    return dict({"embedding": centroid, "ts": ts, "person_ids": [], "source": "chat"}, **kw)


def ids(result):
    return [c["event_id"] for c in result]


def crowd():
    """Five events close to the item and some farther ones."""
    return [event(f"t{i}", vec(1, 0.15 * i + 0.05, 0), order=i + 1) for i in range(5)]


def test_without_reserve_the_top_k_by_score_are_returned_unchanged():
    evs = [event(f"e{i}", vec(1, 0.1 * i), order=i + 1) for i in range(8)]
    out = cand.rank_candidates(item(vec(1, 0)), evs, k=5)
    assert ids(out) == [f"e{i}" for i in range(5)]
    assert ids(cand.rank_candidates(item(vec(1, 0)), evs, k=5, reserve=0)) == ids(out)


def test_reserved_slot_goes_to_the_event_whose_object_the_item_names():
    named = event("named", vec(0.2, 0.2, 1), n=4, order=9, terms=["咖啡", "开业"])
    q = item(vec(1, 0, 0), terms=["咖啡", "开业", "菜单"])
    assert "named" not in ids(cand.rank_candidates(q, crowd() + [named], k=5))
    out = cand.rank_candidates(q, crowd() + [named], k=5, reserve=2, reserve_min_sim=0.1)
    assert "named" in ids(out) and len(out) == 5


def test_reserved_slots_show_the_largest_and_the_most_recently_active_event():
    big = event("big", vec(0.6, 0.1, 0.8), n=30, order=10, last=0.0)
    fresh = event("fresh", vec(0.55, 0.1, 0.8), n=2, order=11, last=100 * H)
    q = item(vec(1, 0, 0.3), ts=100 * H)
    out = ids(cand.rank_candidates(q, crowd() + [big, fresh], k=7, reserve=2, reserve_min_sim=0.2))
    assert "big" in out and "fresh" in out


def test_the_reserve_never_displaces_the_best_scores():
    evs = crowd() + [event("big", vec(0.6, 0.1, 0.8), n=30, order=10)]
    plain = ids(cand.rank_candidates(item(vec(1, 0, 0)), evs, k=5))
    out = ids(cand.rank_candidates(item(vec(1, 0, 0)), evs, k=5, reserve=2, reserve_min_sim=0.2))
    assert set(plain[:3]) <= set(out)  # the first k - reserve of the plain list are all there
    assert len(out) == 5 and len(set(out)) == 5


def test_a_reserved_slot_nothing_claims_goes_to_the_next_best_score():
    evs = [event(f"e{i}", vec(1, 0.4 * i), order=i + 1) for i in range(6)]
    out = cand.rank_candidates(item(vec(1, 0)), evs, k=5, reserve=3, reserve_min_sim=0.99)
    assert len(out) == 5


def test_reserve_respects_forbidden_and_deleted_events():
    named = event("named", vec(0.2, 0.2, 1), n=4, order=9, terms=["咖啡", "开业"])
    gone = dict(event("gone", vec(0.3, 0.2, 1), n=40, order=10), deleted=True)
    q = item(vec(1, 0, 0), terms=["咖啡", "开业"])
    out = ids(cand.rank_candidates(q, crowd() + [named, gone], forbidden=["named"], k=5, reserve=2, reserve_min_sim=0.0))
    assert "named" not in out and "gone" not in out


def test_the_organizer_passes_terms_and_reserve_through_and_shows_late_candidates_compactly(org, chat):
    """Twelve small events: the 6th and later candidates carry their first item only."""
    org.candidates_k, org.candidates_reserve, org.candidates_full_view = 8, 2, 3
    topics = ["咖啡馆菜单", "读书会书目", "阳台漏水", "钢琴考级", "社区菜地", "养老金认证", "旧冰箱换新", "太极拳表演", "青岛旅游"]
    chat.handlers["event-assign"] = lambda data, schema: assign_out("new", obj=data["item"]["text"][:8])
    for i, t in enumerate(topics):
        ingest(org, make_item(f"{t}的事情第一条记录，请记下来", minutes=10 * i))
        org.drain()
    data = [d for s, d, _, _ in chat.calls if s == "event-assign"][-1]
    assert len(data["candidates"]) == 8
    full = [bool(c["recent_items"]) or c["item_count"] == 1 for c in data["candidates"]]
    assert all(c["first_item"] for c in data["candidates"])
    assert all(not c["recent_items"] for c in data["candidates"][3:])
    assert any(full)
