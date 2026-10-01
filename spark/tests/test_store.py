import pytest

from conftest import ingest, make_item
from organizer.db import DatabaseError


def test_item_content_is_never_rewritten_only_purged(org):
    """The integrity rule that replaced "append-only" (privacy contract v6): model output and organizer code
    can never rewrite an item; the only mutation is a purge (every content column NULL, purged = 1)."""
    item = make_item("咖啡馆菜单周五前定下来")
    ingest(org, item)
    iid = item["item_id"]
    for sql in ("UPDATE items SET text='改掉' WHERE item_id=?",                   # rewrite the content
                "UPDATE items SET text=NULL WHERE item_id=?",                    # blank it without a purge
                "UPDATE items SET sha256='x' WHERE item_id=?",
                "UPDATE items SET revision=revision+1 WHERE item_id=?",          # identity and time never change
                "UPDATE items SET started_at='2020-01-01T00:00:00+08:00' WHERE item_id=?",
                "UPDATE items SET text=NULL, segments=NULL, persons=NULL, sha256=NULL, meta=NULL, purged=1,"
                " kind='text' WHERE item_id=?",                                   # a purge that also changes kind
                "DELETE FROM items WHERE item_id=?"):                             # never deleted
        with pytest.raises(DatabaseError):
            org.store.x(sql, (iid,))
    assert org.store.get_item(iid)["text"] == "咖啡馆菜单周五前定下来"
    # the purge path is allowed, and a purged row cannot be un-purged or refilled
    org.store.x("UPDATE items SET text=NULL, segments=NULL, persons=NULL, sha256=NULL, meta=NULL, purged=1"
                " WHERE item_id=?", (iid,))
    row = org.store.one("SELECT text, sha256, purged, kind FROM items WHERE item_id=?", (iid,))
    assert row == {"text": None, "sha256": None, "purged": 1, "kind": "dictation"}
    for sql in ("UPDATE items SET purged=0 WHERE item_id=?", "UPDATE items SET text='回来了' WHERE item_id=?"):
        with pytest.raises(DatabaseError):
            org.store.x(sql, (iid,))


def test_item_blobs_are_never_rewritten(org):
    from conftest import TINY_PNG_B64
    shot = make_item(kind="image", image_b64=TINY_PNG_B64)
    ingest(org, shot)
    with pytest.raises(DatabaseError):
        org.store.x("UPDATE item_blobs SET data=X'00' WHERE item_id=?", (shot["item_id"],))


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
