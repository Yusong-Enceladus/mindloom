"""v6 integration: the scheduled passes (event-consolidate, person-resolve) keep the privacy contract.

- They run only while the store is unlocked, and what they write is bound to the unlock session: a lock, or a
  wipe and an unlock with a new key, while one of their model calls is in flight leaves nothing of it written
  (the rule of review finding F4, now for the passes' pool calls too).
- Deleting an item clears their records the way it clears the others (F5): runs and proposals by the recorded
  read set, the person_scan row of the item, the person_checks of a record left with no item, and the
  consolidate_checks rows of the events it was in. A deleted item is never read by a pass again.
- What they hold in memory (event views, the name index) goes with a lock.

All data here is invented for tests.
"""

from __future__ import annotations

import json
import threading

import pytest

from conftest import TEST_KEY, FakeChat, assign_out, event_of, ingest, make_item
from test_consolidate import by_topic, cafe_with_fragment
from test_people_pass import chat_text, verdict

from organizer import db, keys
from organizer.api import build_organizer
from organizer.clients import HashEmbedClient
from organizer.store import StoreLocked

OTHER_KEY = bytes([0x24]) * 32
SENTINEL = "哨兵JKWQ字样"


def elsewhere(fn):
    """Run fn on another thread, as an API request would (the worker's own thread is bound to its session)."""
    out: dict = {}
    t = threading.Thread(target=lambda: out.setdefault("r", fn()))
    t.start()
    t.join()
    return out.get("r")


def forget_and_rekey(org) -> None:
    """"Make the Spark forget me", then the Mac unlocks at once with its new key (contract section 6)."""
    key_id = keys.derive_keys(TEST_KEY)[0]
    assert elsewhere(lambda: org.wipe(key_id)) == {"wiped": True}
    assert elsewhere(lambda: org.unlock(OTHER_KEY))["created"] is True


def dump(settings, key: bytes = OTHER_KEY) -> str:
    """Every row of every table of the store on disk, decrypted with `key`."""
    conn = db.connect(settings.data_dir / "organizer.db", keys.derive_keys(key)[1])
    try:
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        return "\n".join(f"{t}: {r!r}" for t in tables for r in conn.execute(f"SELECT * FROM {t}"))
    finally:
        conn.close()


def settle(org) -> None:
    """Let every model call of the forgotten session finish (a pass that stopped early does not wait for its pool
    calls), then drain the new session."""
    if org.pipeline is not None:
        org.pipeline.pool.shutdown(wait=True)
    else:
        return
    from concurrent.futures import ThreadPoolExecutor
    org.pipeline.pool = ThreadPoolExecutor(max_workers=org.pipeline.workers)
    org.drain()


def organizer(settings, chat, workers: int = 1):
    settings.workers = workers
    settings.record_inputs = True  # every call's input is kept: the strictest case for "nothing left"
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    org.consolidator.idle_min_items = 1
    return org


def two_fragments(org, chat) -> list[dict]:
    """Three cafe items in one event and two cafe fragments event-assign put into events of their own."""
    cafe = [make_item(t + SENTINEL, minutes=10 * i)
            for i, t in enumerate(["咖啡馆开业菜单周五前定下来", "咖啡馆招牌下周二安装", "咖啡馆豆子报价出来了"])]
    frags = [make_item("咖啡馆开业那天的气球已经订好" + SENTINEL, minutes=40),
             make_item("咖啡馆开业海报今晚印出来" + SENTINEL, minutes=50)]
    chat.push("event-assign", assign_out("new", obj="开业气球"), assign_out("new", obj="开业海报"))
    return cafe + frags


# ---- session binding --------------------------------------------------------------------------------------


@pytest.mark.parametrize("workers", [1, 3])
def test_a_consolidation_call_in_flight_during_forget_writes_nothing_into_the_next_store(settings, workers):
    chat = FakeChat()
    org = organizer(settings, chat, workers)
    items = two_fragments(org, chat)
    chat.handlers["event-consolidate"] = by_topic
    chat.before["event-consolidate"] = lambda _data: forget_and_rekey(org)
    ingest(org, *items)
    org.drain()
    settle(org)
    assert chat.count("event-consolidate") >= (2 if workers > 1 else 1)  # on the pool with 3 workers
    rows = dump(settings)
    assert SENTINEL not in rows
    assert "consolidate" not in rows  # no run, proposal or check of the forgotten pass in the new store
    if org.pipeline is not None:
        org.pipeline.shutdown()


@pytest.mark.parametrize("workers", [1, 3])
def test_a_person_resolve_call_in_flight_during_forget_writes_nothing_into_the_next_store(settings, workers):
    chat = FakeChat()
    org = organizer(settings, chat, workers)
    chat.handlers["person-resolve"] = lambda data, schema: verdict()
    chat.before["person-resolve"] = lambda _data: forget_and_rekey(org)
    ingest(org, make_item(chat_text(f"郝一川：吧台尺寸{SENTINEL}量好了", f"纪明舒：海报{SENTINEL}我来", "我：好"),
                          kind="text", app="微信"),
           make_item(chat_text(f"庞序：押金{SENTINEL}另付", "郝一川：好"), kind="text", app="微信", minutes=5))
    org.drain()
    settle(org)
    assert chat.count("person-resolve") >= (2 if workers > 1 else 1)
    rows = dump(settings)
    assert SENTINEL not in rows and "person_resolve" not in rows
    with db.connect(settings.data_dir / "organizer.db", keys.derive_keys(OTHER_KEY)[1]) as conn:
        assert conn.execute("SELECT COUNT(*) FROM person_checks").fetchone()[0] == 0
    if org.pipeline is not None:
        org.pipeline.shutdown()


def test_a_lock_during_a_pass_writes_nothing_and_the_pass_runs_again_after_the_next_unlock(settings):
    chat = FakeChat()
    org = organizer(settings, chat)
    items, frag = cafe_with_fragment(org, chat)
    chat.handlers["event-consolidate"] = by_topic
    counts = "SELECT (SELECT COUNT(*) FROM runs WHERE job_type='consolidate'), (SELECT COUNT(*) FROM consolidate_checks)"
    before = tuple(org.store._c().execute(counts).fetchone())  # the pass that judged the cafe event alone
    calls = chat.count("event-consolidate")
    chat.before["event-consolidate"] = lambda _data: elsewhere(org.lock)
    ingest(org, frag)
    org.drain()
    assert org.store.locked and chat.count("event-consolidate") > calls
    org.unlock(TEST_KEY)
    assert tuple(org.store._c().execute(counts).fetchone()) == before
    assert event_of(org, frag["item_id"]) != event_of(org, items[0]["item_id"])  # nothing merged yet
    org.drain()
    assert event_of(org, frag["item_id"]) == event_of(org, items[0]["item_id"])  # judged again, merged now


def test_the_passes_never_run_while_the_store_is_locked(settings):
    chat = FakeChat()
    org = organizer(settings, chat)
    items, frag = cafe_with_fragment(org, chat)
    ingest(org, frag)
    org.lock()
    calls = len(chat.calls)
    assert org.drain() == 0 and len(chat.calls) == calls
    with pytest.raises(StoreLocked):
        org.consolidator.idle_due()
    with pytest.raises(StoreLocked):
        org.people_pass.idle_due()


def test_what_the_passes_hold_in_memory_goes_with_a_lock(settings):
    chat = FakeChat()
    org = organizer(settings, chat)
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    ingest(org, frag, make_item(chat_text("郝一川：吧台尺寸量好了", "我：好"), kind="text", app="微信", minutes=60))
    org.drain()
    assert org.consolidator._view_cache and org.people_pass._index is not None
    org.lock()
    assert org.consolidator._view_cache == {} and org.people_pass._index is None


# ---- delete (F5 semantics for the passes' records) ----------------------------------------------------------


def test_deleting_an_item_a_consolidation_call_read_clears_that_run_and_its_proposal(org, chat):
    org.consolidator.idle_min_items = 1
    chat.handlers["event-consolidate"] = by_topic
    items, frag = cafe_with_fragment(org, chat)
    ingest(org, frag)
    org.drain()
    run = org.store.one("SELECT * FROM runs WHERE job_type='consolidate' AND output IS NOT NULL"
                        " AND instr(read_items, ?) > 0", (frag["item_id"],))
    assert run is not None
    small = run["subject"]
    reads = json.loads(run["read_items"])
    # it read the fragment (the small event) and the matter's opening item (the directory sample)
    assert frag["item_id"] in reads and items[0]["item_id"] in reads
    assert org.store.one("SELECT 1 FROM proposals WHERE run_id=? AND payload != '{}'", (run["run_id"],))
    assert org.store.one("SELECT 1 FROM consolidate_checks WHERE event_id=?", (small,))
    # the matter's opening item is deleted: the run about another event that showed it keeps nothing
    org.delete_item(items[0]["item_id"])
    after = org.store.one("SELECT output, input_text FROM runs WHERE run_id=?", (run["run_id"],))
    assert after["output"] is None and after["input_text"] is None
    assert org.store.all("SELECT payload FROM proposals WHERE run_id=?", (run["run_id"],)) == [{"payload": "{}"}]
    # the events it was in are judged afresh: their consolidate_checks rows are gone
    ever = [r["event_id"] for r in org.store.all("SELECT DISTINCT event_id FROM event_items WHERE item_id=?",
                                                  (items[0]["item_id"],))]
    assert ever and not org.store.all(
        f"SELECT 1 FROM consolidate_checks WHERE event_id IN ({','.join('?' * len(ever))})", ever)


def test_deleting_an_item_a_person_resolve_call_read_clears_the_run_and_the_record_of_the_pass(org, chat):
    chat.handlers["person-resolve"] = lambda data, schema: verdict()
    only = make_item(chat_text(f"上官岚：展位图纸{SENTINEL}周五发", "我：好"), kind="text", app="微信")
    other = make_item(chat_text("郝一川：吧台尺寸量好了", "我：好"), kind="text", app="微信", minutes=5)
    ingest(org, only, other)
    org.drain()
    pid = next(p for p in org.people.item_person_ids(only["item_id"]) if org.people.name(p) == "上官岚")
    run = org.store.one("SELECT * FROM runs WHERE job_type='person' AND subject=?", (pid,))
    assert only["item_id"] in json.loads(run["read_items"])  # the call showed the lines it was read from
    assert org.store.one("SELECT 1 FROM person_checks WHERE person_id=?", (pid,))
    assert org.store.one("SELECT 1 FROM person_scan WHERE item_id=?", (only["item_id"],))
    org.delete_item(only["item_id"])
    after = org.store.one("SELECT output, input_text FROM runs WHERE run_id=?", (run["run_id"],))
    assert after["output"] is None and after["input_text"] is None
    assert all(r["payload"] == "{}" for r in org.store.all("SELECT payload FROM proposals WHERE run_id=?",
                                                           (run["run_id"],)))
    assert org.store.one("SELECT 1 FROM person_scan WHERE item_id=?", (only["item_id"],)) is None
    assert org.store.one("SELECT 1 FROM person_checks WHERE person_id=?", (pid,)) is None  # no item left
    kept = next(p for p in org.people.item_person_ids(other["item_id"]) if org.people.name(p) == "郝一川")
    assert org.store.one("SELECT 1 FROM person_checks WHERE person_id=?", (kept,))  # others keep theirs
    # the pass never reads the deleted item again
    calls = chat.count("person-resolve")
    org.drain()
    assert org.store.one("SELECT 1 FROM person_scan WHERE item_id=?", (only["item_id"],)) is None
    assert not org.people_pass.has_work() and chat.count("person-resolve") == calls
    rows = "\n".join(repr(r) for t in ("runs", "proposals", "person_checks", "person_scan", "consolidate_checks")
                     for r in org.store.all(f"SELECT * FROM {t}"))
    assert SENTINEL not in rows
