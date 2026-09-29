"""Regressions for home-rank inputs and staleness (S5-S7). Fake model; data invented."""

from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.clock import FixedClock

from conftest import event_of, ingest, make_item


def fixed_org(settings, chat, iso="2026-09-15T20:40:00+08:00"):
    clock = FixedClock(iso)
    return build_organizer(settings, chat=chat, embedder=HashEmbedClient(), clock=clock), clock


def test_rank_sees_dated_facts_split_into_upcoming_and_past(settings, chat):
    org, clock = fixed_org(settings, chat)
    lease = make_item("房东：明年月租1.3万，你考虑一下")
    ingest(org, lease)
    org.drain()
    ev = event_of(org, lease["item_id"])
    org.store.update_event(ev, status_facts=[
        {"text": "现租约9月30日到期", "state": "planned", "date": "2026-09-30", "quote": "", "item_ids": [lease["item_id"]]},
        {"text": "物业9月14日停水", "state": "planned", "date": "2026-09-14", "quote": "", "item_ids": [lease["item_id"]]}])
    org.rank()
    view = [d for s, d, _, _ in chat.calls if s == "home-rank"][-1]["events"][0]
    assert view["event_id"] == "E1"
    assert view["status_facts"][0] == {"text": "现租约9月30日到期", "state": "planned", "date": "2026-09-30"}
    assert "2026-09-30" in view["dates"]["upcoming"] and "2026-09-14" in view["dates"]["past"]
    assert org.store.get_event(ev)["importance"] != 0.5  # the E1 row mapped back


def test_events_outside_the_rank_window_cannot_keep_an_old_high_score(settings, chat):
    org, _ = fixed_org(settings, chat)
    org.rank_max_events = 2
    items = [make_item(t, minutes=i * 10) for i, t in enumerate(["咖啡馆菜单", "读书会书目", "搬家打包"])]
    ingest(org, *items)
    org.drain()
    oldest = event_of(org, items[0]["item_id"])
    org.store.update_event(oldest, importance=0.95)
    org.rank()
    ranked = [d for s, d, _, _ in chat.calls if s == "home-rank"][-1]["events"]
    assert len(ranked) == 2
    assert org.store.get_event(oldest)["importance"] <= 0.3


def test_rank_reruns_when_the_calendar_day_changes(settings, chat):
    org, clock = fixed_org(settings, chat)
    ingest(org, make_item("咖啡馆菜单"))
    org.drain()
    n = chat.count("home-rank")
    assert org.drain() == 0
    clock.set("2026-09-16T08:00:00+08:00")
    org.drain()
    assert chat.count("home-rank") == n + 1
    assert [d for s, d, _, _ in chat.calls if s == "home-rank"][-1]["now"] == "2026-09-16T08:00:00+08:00"
