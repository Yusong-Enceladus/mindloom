import sqlite3

import pytest

from conftest import ingest, make_item


def test_items_are_append_only(org):
    item = make_item("咖啡馆菜单周五前定下来")
    ingest(org, item)
    with pytest.raises(sqlite3.DatabaseError):
        org.store.x("UPDATE items SET text='改掉' WHERE item_id=?", (item["item_id"],))
    with pytest.raises(sqlite3.DatabaseError):
        org.store.x("DELETE FROM items WHERE item_id=?", (item["item_id"],))
    assert org.store.get_item(item["item_id"])["text"] == "咖啡馆菜单周五前定下来"


def test_ingest_is_idempotent_by_item_and_revision(org):
    item = make_item("读书会订房间")
    assert ingest(org, item) == (1, 0)
    assert ingest(org, item) == (0, 1)
    rev2 = dict(item, revision=2, text="读书会订房间，改到周日下午两点")
    assert ingest(org, rev2) == (1, 0)
    # both revisions are kept; only the latest is queued
    assert org.store.scalar("SELECT COUNT(*) FROM items WHERE item_id=?", (item["item_id"],)) == 2
    jobs = org.store.all("SELECT revision, state FROM jobs WHERE item_id=? ORDER BY revision", (item["item_id"],))
    assert [(j["revision"], j["state"]) for j in jobs] == [(1, "superseded"), (2, "queued")]
    assert org.store.count_items() == 1


def test_older_revision_arriving_late_is_ignored_as_stale(org):
    item = make_item("搬家清单", revision=3)
    ingest(org, item)
    assert ingest(org, dict(item, revision=2, text="搬家清单旧版")) == (0, 1)
    assert org.store.latest_revision(item["item_id"]) == 3
    assert org.store.scalar("SELECT COUNT(*) FROM items WHERE item_id=?", (item["item_id"],)) == 1
    queued = org.store.all("SELECT revision FROM jobs WHERE item_id=? AND state='queued'", (item["item_id"],))
    assert [q["revision"] for q in queued] == [3]


def test_jobs_are_claimed_in_started_at_order(org):
    late = make_item("咖啡馆 late", minutes=30)
    early = make_item("咖啡馆 early", minutes=-30)
    mid = make_item("咖啡馆 mid", minutes=0)
    ingest(org, late, early, mid)
    order = []
    while (job := org.store.claim_next_job()) is not None:
        order.append(job["item_id"])
        org.store.finish_job(job["item_id"], job["revision"])
    assert order == [early["item_id"], mid["item_id"], late["item_id"]]


def test_cursor_increases_and_state_is_delta(org):
    ingest(org, make_item("咖啡馆菜单"))
    org.drain()
    full = org.state(0)
    assert len(full["events"]) == 1
    again = org.state(full["cursor"])
    assert again["events"] == [] and again["cursor"] == full["cursor"]


def test_worker_resets_running_jobs_after_restart(org):
    ingest(org, make_item("体检预约"))
    job = org.store.claim_next_job()
    assert job is not None
    assert org.store.reset_running_jobs() == 1
    assert org.store.claim_next_job()["item_id"] == job["item_id"]
