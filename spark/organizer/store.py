"""The organizer's store: one SQLCipher database per library (organizer.db), encrypted at rest.

Guarantees enforced here:
- Locked at rest (privacy contract section 2). The database is SQLCipher-encrypted with the store key
  derived from the Mac's library key (organizer/keys.py). A Store starts locked: nothing can be read until
  unlock(library_key) (POST /v1/unlock from the Mac over its SSH tunnel). lock() closes the connection and
  drops the keys; wipe(key_id) deletes the store. The only key-related value on disk is the plaintext
  sidecar store.keyid (the key_id, mode 0600), so /v1/health can say whose store this is while locked.
  A plaintext organizer.db written before encryption is encrypted on the first unlock (sqlcipher_export),
  then the plaintext file is deleted. ":memory:" stores (harness helpers) are never on disk and open unlocked.
- Item content is never rewritten, only purged (replaces "append-only"). Items are stored per
  (item_id, revision); the latest revision is the item's current content and a lower revision than the
  stored latest is stale and ignored, so a late retry can never roll an item back. SQLite triggers abort
  any UPDATE that changes an item's identity or time, or changes its content to anything but a purge
  (every content column NULL and purged = 1), and every DELETE on items. Only two paths remove content:
  the user's delete (purge_item: all revisions, children and derived rows; a content-free tombstone stays)
  and read-then-delete (an image / file blob is deleted in the same transaction that stores its reading).
- meta.store_id is a UUID created once with the database; clients use it to detect a reset store.
- Every change that a client must see bumps a global sequence number; GET /v1/state?since=
  returns rows whose seq is greater than the client's cursor.
- One connection shared across threads behind an RLock; transactions are short and never
  span a model call. Locking waits for a running transaction to finish.
- Semantic timestamps (events, links, questions, decisions, constraints, persons) come from the
  injected Clock (organizer/clock.py); audit timestamps (received_at, runs, jobs, proposals) stay on
  the wall clock. Orderings never depend on either: they use seq counters and stable short handles.
- Every event gets a short handle (E1, E2, ...) and every item a handle (I1, I2, ...) at creation.
  Handles are what the model sees; they are never reused.
- The phone inbox is not here: it lives in its own small inbox.db (organizer/inbox.py) because it must
  accept phone shares while this store is locked.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

from . import db, keys, masking
from .clock import Clock, WallClock


class StoreLocked(RuntimeError):
    """The store is locked: its key is not in memory (POST /v1/unlock first)."""


class WrongKey(RuntimeError):
    """The library key does not belong to the store on disk. `key_id` is the store's own (or None)."""

    def __init__(self, key_id: Optional[str]):
        super().__init__("wrong_key")
        self.key_id = key_id


class ItemPurged(RuntimeError):
    """The item was deleted by the user while it was being organized; nothing more is written for it."""


ITEMS_DDL = """
CREATE TABLE IF NOT EXISTS items(
  item_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  kind TEXT NOT NULL,
  source_app TEXT NOT NULL,
  started_at TEXT NOT NULL,
  started_ts REAL NOT NULL,
  ended_at TEXT,
  ended_ts REAL,
  text TEXT,
  segments TEXT,
  persons TEXT,
  sha256 TEXT,
  has_image INTEGER NOT NULL DEFAULT 0,
  received_at TEXT NOT NULL,
  meta TEXT,
  purged INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (item_id, revision)
);
"""

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta(key, value) VALUES ('seq', '0'), ('schema_version', '2');

""" + ITEMS_DDL + """
CREATE TABLE IF NOT EXISTS item_blobs(
  item_id TEXT NOT NULL, revision INTEGER NOT NULL, mime TEXT NOT NULL, data BLOB NOT NULL,
  PRIMARY KEY (item_id, revision)
);

-- A user-deleted item id (no content): a later POST /v1/items for it is refused with 410.
CREATE TABLE IF NOT EXISTS item_tombstones(item_id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS item_derived(
  item_id TEXT NOT NULL, revision INTEGER NOT NULL,
  derived_text TEXT, summary TEXT, messages TEXT, screenshot_run_id TEXT,
  embedding TEXT, embed_model TEXT, created_at TEXT NOT NULL,
  PRIMARY KEY (item_id, revision)
);

CREATE TABLE IF NOT EXISTS jobs(
  item_id TEXT NOT NULL, revision INTEGER NOT NULL, started_ts REAL NOT NULL,
  state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
  reason TEXT, error TEXT, error_category TEXT,
  enqueued_at REAL NOT NULL, not_before REAL NOT NULL DEFAULT 0,
  run_started REAL, run_ended REAL,
  PRIMARY KEY (item_id, revision)
);
CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state, started_ts);

CREATE TABLE IF NOT EXISTS events(
  event_id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  title_user_edited INTEGER NOT NULL DEFAULT 0,
  status_line TEXT NOT NULL DEFAULT '',
  status_facts TEXT NOT NULL DEFAULT '[]',
  importance REAL NOT NULL DEFAULT 0.5,
  importance_reason TEXT NOT NULL DEFAULT '',
  started_at TEXT, started_ts REAL, updated_at TEXT, updated_ts REAL,
  pinned INTEGER NOT NULL DEFAULT 0,
  feature_less INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0,
  merged_into TEXT,
  provenance TEXT NOT NULL DEFAULT '{}',
  needs_brief INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS event_items(
  event_id TEXT NOT NULL, item_id TEXT NOT NULL,
  attached_by TEXT NOT NULL, run_id TEXT, created_at TEXT NOT NULL,
  removed INTEGER NOT NULL DEFAULT 0, removed_by TEXT,
  item_revision INTEGER,
  PRIMARY KEY (event_id, item_id)
);
CREATE INDEX IF NOT EXISTS event_items_item ON event_items(item_id, removed);

CREATE TABLE IF NOT EXISTS persons(
  person_id TEXT PRIMARY KEY,
  display_name TEXT,
  name_source TEXT,
  origin TEXT NOT NULL,
  merged_into TEXT,
  created_at TEXT NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS person_links(
  a TEXT NOT NULL, b TEXT NOT NULL, relation TEXT NOT NULL, source TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (a, b)
);
CREATE TABLE IF NOT EXISTS item_persons(
  item_id TEXT NOT NULL, person_id TEXT NOT NULL, role TEXT NOT NULL,
  PRIMARY KEY (item_id, person_id)
);

CREATE TABLE IF NOT EXISTS decisions(
  decision_id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL, payload TEXT NOT NULL, origin TEXT NOT NULL,
  created_at TEXT NOT NULL, applied INTEGER NOT NULL, note TEXT
);
CREATE TABLE IF NOT EXISTS decision_receipts(
  external_id TEXT PRIMARY KEY NOT NULL,
  payload_digest TEXT NOT NULL,
  applied INTEGER NOT NULL,
  note TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS constraints(
  kind TEXT NOT NULL, a TEXT NOT NULL, b TEXT NOT NULL,
  decision_id INTEGER, created_at TEXT NOT NULL,
  PRIMARY KEY (kind, a, b)
);

CREATE TABLE IF NOT EXISTS questions(
  question_id TEXT PRIMARY KEY, kind TEXT NOT NULL, a TEXT NOT NULL, b TEXT NOT NULL,
  prompt_zh TEXT NOT NULL, created_at TEXT NOT NULL, status TEXT NOT NULL,
  answer INTEGER, answered_at TEXT, item_id TEXT, run_id TEXT
);

CREATE TABLE IF NOT EXISTS runs(
  run_id TEXT PRIMARY KEY, job_type TEXT NOT NULL, skill TEXT NOT NULL, version TEXT NOT NULL,
  model TEXT, prompt_hash TEXT NOT NULL, input_digest TEXT NOT NULL,
  output TEXT, error TEXT, attempts INTEGER NOT NULL,
  started_at REAL NOT NULL, ended_at REAL NOT NULL, ok INTEGER NOT NULL,
  prompt_tokens INTEGER, completion_tokens INTEGER, subject TEXT
);

CREATE TABLE IF NOT EXISTS proposals(
  proposal_id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, kind TEXT NOT NULL,
  target_id TEXT, payload TEXT NOT NULL, status TEXT NOT NULL, reason TEXT,
  created_at TEXT NOT NULL
);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def iso_to_ts(value: str) -> float:
    return datetime.fromisoformat(value).timestamp()


def new_id() -> str:
    return str(uuid.uuid4())


def dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


# Content of an item changes only by a purge: every content column NULL (source_app, NOT NULL, becomes '{}') and
# purged = 1. Identity and times never change; items are never deleted (a purged row keeps its id, revision, kind
# and times, which are not content).
INTEGRITY = """
DROP TRIGGER IF EXISTS items_no_update;
DROP TRIGGER IF EXISTS items_no_rewrite;
DROP TRIGGER IF EXISTS items_no_delete;
DROP TRIGGER IF EXISTS item_blobs_no_update;
CREATE TRIGGER items_no_rewrite BEFORE UPDATE ON items
WHEN NEW.item_id IS NOT OLD.item_id OR NEW.revision IS NOT OLD.revision OR NEW.kind IS NOT OLD.kind
  OR (NEW.source_app IS NOT OLD.source_app AND (NEW.purged = 0 OR NEW.source_app IS NOT '{}'))
  OR NEW.started_at IS NOT OLD.started_at
  OR NEW.started_ts IS NOT OLD.started_ts OR NEW.ended_at IS NOT OLD.ended_at OR NEW.ended_ts IS NOT OLD.ended_ts
  OR NEW.received_at IS NOT OLD.received_at OR NEW.has_image IS NOT OLD.has_image OR NEW.purged < OLD.purged
  OR ((NEW.text IS NOT OLD.text OR NEW.segments IS NOT OLD.segments OR NEW.persons IS NOT OLD.persons
       OR NEW.sha256 IS NOT OLD.sha256 OR NEW.meta IS NOT OLD.meta)
      AND (NEW.purged = 0 OR NEW.text IS NOT NULL OR NEW.segments IS NOT NULL OR NEW.persons IS NOT NULL
           OR NEW.sha256 IS NOT NULL OR NEW.meta IS NOT NULL))
BEGIN SELECT RAISE(ABORT, 'item content is never rewritten; only a purge (NULL) may change it'); END;
CREATE TRIGGER items_no_delete BEFORE DELETE ON items
BEGIN SELECT RAISE(ABORT, 'items are never deleted; a purge sets their content to NULL'); END;
CREATE TRIGGER item_blobs_no_update BEFORE UPDATE ON item_blobs
BEGIN SELECT RAISE(ABORT, 'item blobs are never rewritten; read-then-delete or a purge removes them'); END;
CREATE VIEW IF NOT EXISTS latest_items AS
  SELECT i.* FROM items i
  WHERE i.revision = (SELECT MAX(r.revision) FROM items r WHERE r.item_id = i.item_id);
"""

ITEM_COLS = ("item_id", "revision", "kind", "source_app", "started_at", "started_ts", "ended_at", "ended_ts", "text",
             "segments", "persons", "sha256", "has_image", "received_at", "meta", "purged")


def _secure_zero(buf: Optional[bytearray]) -> None:
    if buf is not None:
        for i in range(len(buf)):
            buf[i] = 0


class Store:
    """The organizer store. Store(path) starts locked; Store(path, key=library_key) is unlocked at once
    (harnesses on synthetic data); Store(":memory:") is an unencrypted, never-on-disk store (eval helpers)."""

    def __init__(self, path: str | Path, clock: Optional[Clock] = None, key: Optional[bytes] = None):
        self.clock: Clock = clock or WallClock()
        self.path = str(path)
        self.memory = self.path == ":memory:"
        if not self.memory:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._depth = 0
        self.conn: Optional[db.Connection] = None
        self.store_id: Optional[str] = None
        self.key_id: Optional[str] = None
        self._mask_key: Optional[bytearray] = None
        # Bumped on every unlock and lock, so the worker can tell a new session from the one it knew.
        self.generation = 0
        # The unlock session a worker thread's writes belong to (bind()); a write for an older session is refused.
        self._bound = threading.local()
        # Purges in this process (a model call that spans one re-checks what it writes) and the starts of the
        # purged texts, kept in memory only while unlocked, so an audit record written by a call already in flight
        # is cleared too.
        self.purges = 0
        self._purged_heads: set[str] = set()
        if self.memory:
            self._open(db.connect(":memory:", None, check_same_thread=False, isolation_level=None))
        elif key is not None:
            self.unlock(key)

    # ---- locking (privacy contract section 2) --------------------------------------------

    @property
    def locked(self) -> bool:
        return self.conn is None

    @property
    def keyid_path(self) -> Path:
        p = Path(self.path)
        return p.with_name("store.keyid") if p.name == "organizer.db" else Path(self.path + ".keyid")

    def disk_key_id(self) -> Optional[str]:
        """The key_id of the store on disk (plaintext sidecar), or None when there is no store yet."""
        return None if self.memory else keys.read_key_id(self.keyid_path)

    def unlock(self, library_key: bytes) -> dict:
        """Open (or create) the encrypted store with the Mac's library key. Idempotent with the same key.
        Raises WrongKey when the key belongs to another store; the store then stays locked."""
        key_id, store_key, mask_key = keys.derive_keys(library_key)
        with self._lock:
            if self.conn is not None:
                if self.memory or key_id == self.key_id:
                    return {"locked": False, "key_id": self.key_id, "created": False, "store_id": self.store_id}
                raise WrongKey(self.key_id)
            on_disk = self.disk_key_id()
            if on_disk is not None and on_disk != key_id:
                raise WrongKey(on_disk)
            path = Path(self.path)
            created = not (path.exists() and path.stat().st_size > 0)
            if not created and db.is_plaintext(path):
                # A store written before encryption: encrypt it with this key, then drop the plaintext file.
                db.encrypt_in_place(path, store_key)
            try:
                conn = db.connect(self.path, store_key, check_same_thread=False, isolation_level=None)
            except db.DatabaseError:
                raise WrongKey(on_disk) from None  # encrypted with another key (and no sidecar to say so)
            self._open(conn)
            if on_disk is None:
                keys.write_key_id(self.keyid_path, key_id)
            self.key_id = key_id
            self._mask_key = bytearray(mask_key)
            self.generation += 1
            return {"locked": False, "key_id": key_id, "created": created, "store_id": self.store_id}

    def _open(self, conn: db.Connection) -> None:
        try:
            conn.row_factory = db.Row
            if not self.memory:
                conn.execute("PRAGMA journal_mode=WAL")
                conn.execute("PRAGMA synchronous=NORMAL")
            # Freed pages are overwritten, so a purged item's old pages do not stay readable with the key.
            conn.execute("PRAGMA secure_delete=ON")
            self.conn = conn
            self.conn.executescript(SCHEMA)
            self._migrate()
            # Created exactly once per database file; a fresh database gets a fresh id.
            self.conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('store_id', ?)", (new_id(),))
            self.store_id = str(self.conn.execute("SELECT value FROM meta WHERE key = 'store_id'").fetchone()[0])
        except BaseException:
            self.conn = None
            conn.close()
            raise
        if not self.memory:
            os.chmod(self.path, 0o600)

    def lock(self) -> None:
        """Close the database and drop every key from memory (best effort: Python may still hold copies of
        request bytes until they are collected). Idempotent. Waits for a running transaction."""
        with self._lock:
            if self.memory:
                return
            if self.conn is not None:
                try:
                    self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                except db.DatabaseError:
                    pass
                self.conn.close()
                self.conn = None
                self.generation += 1
            _secure_zero(self._mask_key)
            self._mask_key = None
            self.key_id = None
            self.store_id = None
            self._purged_heads = set()

    def wipe(self, key_id: Optional[str]) -> None:
        """Delete the store (database, WAL, shared memory, sidecar). Allowed when key_id matches the store on
        disk or when no key-bound store exists; raises WrongKey otherwise. Works locked or unlocked."""
        with self._lock:
            on_disk = self.disk_key_id()
            if on_disk is not None and key_id != on_disk:
                raise WrongKey(on_disk)
            self.lock()
            path = Path(self.path)
            for p in (path, *(Path(self.path + s) for s in db.SIDE_FILES), self.keyid_path,
                      path.with_name(path.name + ".enc-tmp")):
                try:
                    p.unlink()
                except FileNotFoundError:
                    pass
            db.remove_side_files(path.with_name(path.name + ".enc-tmp"))

    def _c(self) -> db.Connection:
        conn = self.conn
        if conn is None:
            raise StoreLocked("locked")
        bound = getattr(self._bound, "generation", None)
        if bound is not None and bound != self.generation:
            # This thread works for an unlock session that has ended (a lock, or a wipe and a new key): what it
            # read or computed there is never written into the store opened since.
            raise StoreLocked("session ended")
        return conn

    def bind(self, generation: Optional[int]) -> None:
        """Tie this thread's store access to one unlock session (None: unbound). The worker binds every step,
        so a model call that returns after a lock, or after a wipe and an unlock with a new key, writes
        nothing."""
        self._bound.generation = generation

    # ---- masking (privacy contract section 3) ---------------------------------------------

    @property
    def masking(self) -> bool:
        return self._mask_key is not None

    def mask_text(self, text: Optional[str]) -> Optional[str]:
        """Mask with this library's mask key. An unencrypted in-memory store (eval helpers) has no key and
        leaves text as it is."""
        key = self._mask_key
        if key is None:
            if self.memory:
                return text
            raise StoreLocked("locked")
        return masking.mask_text(text, bytes(key))

    def mask_obj(self, value: Any) -> Any:
        key = self._mask_key
        if key is None:
            if self.memory:
                return value
            raise StoreLocked("locked")
        return masking.mask_obj(value, bytes(key))

    def _cols(self, table: str) -> set[str]:
        return {r["name"] for r in self.conn.execute(f"PRAGMA table_info({table})").fetchall()}

    def _add_col(self, table: str, col: str, decl: str) -> bool:
        if col in self._cols(table):
            return False
        self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
        return True

    def _rebuild_items(self) -> None:
        """Stores from before 2026-09-30 declared items.sha256 NOT NULL (a purged row sets it to NULL) and had
        the append-only triggers: rebuild the table once, keeping every row."""
        info = {r["name"]: dict(r) for r in self.conn.execute("PRAGMA table_info(items)").fetchall()}
        if not info or not info.get("sha256", {}).get("notnull"):
            return
        cols = ",".join(c for c in ITEM_COLS if c in info)
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            for stmt in ("DROP VIEW IF EXISTS latest_items", "DROP TRIGGER IF EXISTS items_no_update",
                         "DROP TRIGGER IF EXISTS items_no_delete", "DROP TRIGGER IF EXISTS items_no_rewrite",
                         "ALTER TABLE items RENAME TO items_v1"):
                self.conn.execute(stmt)
            self.conn.execute(ITEMS_DDL)
            self.conn.execute(f"INSERT INTO items({cols}) SELECT {cols} FROM items_v1")
            self.conn.execute("DROP TABLE items_v1")
            self.conn.execute("UPDATE meta SET value='2' WHERE key='schema_version'")
            self.conn.execute("COMMIT")
        except BaseException:
            self.conn.execute("ROLLBACK")
            raise
        self.conn.execute("VACUUM")  # once: the old table's pages are not kept as free space

    def _migrate(self) -> None:
        self._rebuild_items()
        self._add_col("items", "purged", "INTEGER NOT NULL DEFAULT 0")
        if self._add_col("questions", "apply_note", "TEXT"):
            pass  # why an answered question's decision could not be applied (status 'failed')
        if self._add_col("event_items", "item_revision", "INTEGER"):
            # Links made before revision tracking are treated as placed at the item's latest revision.
            self.conn.execute("UPDATE event_items SET item_revision ="
                              " (SELECT MAX(revision) FROM items i WHERE i.item_id = event_items.item_id)")
        # --- organizer-quality additions (all additive; existing rows are backfilled) ---
        self.conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('event_handle_seq', '0')")
        self.conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('item_handle_seq', '0')")
        if self._add_col("events", "handle", "INTEGER"):
            for n, row in enumerate(self.conn.execute(
                    "SELECT event_id FROM events ORDER BY seq, rowid").fetchall(), 1):
                self.conn.execute("UPDATE events SET handle=? WHERE event_id=?", (n, row["event_id"]))
            self.conn.execute("UPDATE meta SET value=(SELECT COALESCE(MAX(handle),0) FROM events)"
                              " WHERE key='event_handle_seq'")
        self.conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS events_handle ON events(handle)")
        # The event's fixed identity (its concrete object), set once from the seed item; briefs never
        # rewrite it, only a user rename does.
        self._add_col("events", "anchor", "TEXT NOT NULL DEFAULT ''")
        self._add_col("events", "anchor_source", "TEXT NOT NULL DEFAULT ''")
        # The item the event was created from (its anchor's seed): a purge of it clears the anchor.
        self._add_col("events", "anchor_item", "TEXT")
        if self._add_col("event_items", "link_seq", "INTEGER NOT NULL DEFAULT 0"):
            self.conn.execute("UPDATE event_items SET link_seq=rowid")
        # 1 = event-brief said this model-placed item is about another object; hidden from matching.
        self._add_col("event_items", "off_anchor", "INTEGER NOT NULL DEFAULT 0")
        if self._add_col("questions", "q_seq", "INTEGER NOT NULL DEFAULT 0"):
            self.conn.execute("UPDATE questions SET q_seq=rowid")
        self._add_col("questions", "day_key", "TEXT")
        self._add_col("questions", "provisional", "TEXT")
        self._add_col("questions", "b_items_at_ask", "TEXT")
        self._add_col("runs", "as_of", "TEXT")
        self._add_col("runs", "input_text", "TEXT")
        # The items whose text a run's input held (JSON list): a purge of any of them clears the run.
        self._add_col("runs", "read_items", "TEXT")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS item_handles(item_id TEXT PRIMARY KEY, n INTEGER NOT NULL UNIQUE)")
        if not self.conn.execute("SELECT 1 FROM item_handles LIMIT 1").fetchone():
            rows = self.conn.execute(
                "SELECT item_id FROM items GROUP BY item_id ORDER BY MIN(rowid)").fetchall()
            for n, row in enumerate(rows, 1):
                self.conn.execute("INSERT INTO item_handles(item_id, n) VALUES (?,?)", (row["item_id"], n))
            if rows:
                self.conn.execute("UPDATE meta SET value=? WHERE key='item_handle_seq'", (str(len(rows)),))
        # Items the organizer decided belong to no matter (or a user unfiled). They stay visible in an
        # Unfiled tray and can be filed later by the user or by a recheck when a matching event appears.
        # A derived reading (the image-read text) is published in /v1/state `readings`; its seq
        # moves when the reading is written. Readings stored before this column get a fresh seq so a
        # client with an older cursor still receives them once.
        if self._add_col("item_derived", "reading_seq", "INTEGER NOT NULL DEFAULT 0"):
            rows = self.conn.execute("SELECT item_id, revision FROM item_derived WHERE screenshot_run_id IS NOT NULL"
                                     " ORDER BY rowid").fetchall()
            for row in rows:
                self.conn.execute("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'seq'")
                self.conn.execute("UPDATE item_derived SET reading_seq = (SELECT CAST(value AS INTEGER) FROM meta"
                                  " WHERE key = 'seq') WHERE item_id=? AND revision=?", (row["item_id"], row["revision"]))
        # A screenshot reading's summary (the model's own words) is stored apart from its transcription.
        # Readings written before this column kept the summary as the first line of derived_text: split
        # it off and re-publish them once, so a client's reading text is the transcription only.
        if self._add_col("item_derived", "summary", "TEXT"):
            rows = self.conn.execute("SELECT item_id, revision, derived_text FROM item_derived"
                                     " WHERE screenshot_run_id IS NOT NULL AND COALESCE(derived_text, '') != ''"
                                     " ORDER BY rowid").fetchall()
            for row in rows:
                first, _, rest = row["derived_text"].partition("\n")
                self.conn.execute("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'seq'")
                self.conn.execute("UPDATE item_derived SET summary=?, derived_text=?, reading_seq = (SELECT CAST(value"
                                  " AS INTEGER) FROM meta WHERE key = 'seq') WHERE item_id=? AND revision=?",
                                  (first.strip(), rest, row["item_id"], row["revision"]))
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS unfiled(item_id TEXT PRIMARY KEY, reason TEXT NOT NULL, run_id TEXT,"
            " since TEXT NOT NULL, recheck_count INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0)")
        # --- item-split (contract B) ---
        # A split item's matters are organized as internal child items (one per segment). A child is an
        # ordinary item row (append-only, revision = the parent's revision, text = the segment's slice of
        # the parent text), so retrieval, event-assign, briefs, questions and decisions work unchanged.
        # Children never leave the Spark under their own id: /v1/state reports the parent item_id plus
        # the segment (seg_id, start, end, gist). active=0 marks a segment a later revision no longer has.
        self._add_col("item_derived", "split", "TEXT")
        # image-read: the image type, key fields and key numbers of a reading (JSON). NULL for a reading
        # stored by screenshot-read (published as type chat_screenshot / other, no fields).
        self._add_col("item_derived", "reading", "TEXT")
        # --- files (contract "file") ---
        # File metadata of an item revision (filename, uti, mime, size, local_text, captured_at) and the
        # parent media item of a video keyframe (parent_item_id, frame_ms), as JSON. NULL for other items.
        self._add_col("items", "meta", "TEXT")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS item_segments(child_id TEXT PRIMARY KEY, parent_id TEXT NOT NULL,"
            " parent_revision INTEGER NOT NULL, seg_id TEXT NOT NULL, seg_index INTEGER NOT NULL,"
            " start INTEGER NOT NULL, \"end\" INTEGER NOT NULL, gist TEXT NOT NULL DEFAULT '',"
            " active INTEGER NOT NULL DEFAULT 1, seq INTEGER NOT NULL DEFAULT 0)")
        self.conn.execute("CREATE INDEX IF NOT EXISTS item_segments_parent ON item_segments(parent_id, active)")
        # item-split marked this segment as no matter at all (chit-chat, a notice read out): it stays
        # unfiled and is never assigned.
        self._add_col("item_segments", "no_matter", "INTEGER NOT NULL DEFAULT 0")
        # --- consolidation pass (skill event-consolidate): one row per judged event, so an event is judged
        # again only after it doubled, gained a new nearest neighbour or went stale (organizer/consolidate.py).
        # outcome: merged / unfiled / kept / skipped / invalid / stale. No content. ---
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS consolidate_checks(event_id TEXT PRIMARY KEY, n_items INTEGER NOT NULL,"
            " near TEXT NOT NULL DEFAULT '[]', outcome TEXT NOT NULL, target TEXT, run_id TEXT,"
            " n_checks INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)")
        # --- people pass (skill person-resolve, organizer/people_pass.py). persons.status: NULL (a person),
        # 'role' (a role or desk that speaks in chats: 客服, 组委会) or 'not_person' (a label, heading, code key or
        # phrase read as a speaker; it keeps no links). person_checks: one verdict per judged person record
        # (name, kind, whether the name is also an ordinary word, the record it is the same as); no item
        # content. person_scan: the speaker rules and the mention index each item was last read with. ---
        self._add_col("persons", "status", "TEXT")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS person_checks(person_id TEXT PRIMARY KEY, name TEXT NOT NULL,"
            " verdict TEXT NOT NULL, common_word INTEGER NOT NULL DEFAULT 0, same_as TEXT, outcome TEXT NOT NULL,"
            " run_id TEXT, n_items INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS person_scan(item_id TEXT PRIMARY KEY, rules TEXT NOT NULL,"
            " mentions TEXT NOT NULL DEFAULT '')")
        # The phone inbox moved to its own inbox.db (organizer/inbox.py); an older store's inbox table is
        # handed over once after unlock (legacy_inbox_rows / drop_legacy_inbox) and then dropped.
        # Integrity triggers ("no rewrite, only purge") and the latest_items view, recreated on every open.
        self.conn.executescript(INTEGRITY)
        # Bytes of a revision that a later revision replaced are never read: a store written before
        # insert_item deleted them keeps them no longer.
        self.conn.execute("DELETE FROM item_blobs WHERE revision < (SELECT MAX(i.revision) FROM items i"
                          " WHERE i.item_id = item_blobs.item_id)")

    # ---- primitives -------------------------------------------------------------

    @contextmanager
    def tx(self) -> Iterator["Store"]:
        with self._lock:
            conn = self._c()
            outer = self._depth == 0
            if outer:
                conn.execute("BEGIN IMMEDIATE")
            self._depth += 1
            try:
                yield self
            except BaseException:
                self._depth -= 1
                if outer:
                    conn.execute("ROLLBACK")
                raise
            self._depth -= 1
            if outer:
                conn.execute("COMMIT")

    def x(self, sql: str, args: tuple | list = ()) -> db.Cursor:
        with self._lock:
            return self._c().execute(sql, args)

    def all(self, sql: str, args: tuple | list = ()) -> list[dict]:
        with self._lock:
            return [dict(r) for r in self._c().execute(sql, args).fetchall()]

    def one(self, sql: str, args: tuple | list = ()) -> Optional[dict]:
        with self._lock:
            row = self._c().execute(sql, args).fetchone()
            return dict(row) if row else None

    def scalar(self, sql: str, args: tuple | list = ()) -> Any:
        with self._lock:
            row = self._c().execute(sql, args).fetchone()
            return row[0] if row else None

    def now(self) -> str:
        """Semantic time (injected clock)."""
        return self.clock.now_iso()

    def _next(self, key: str) -> int:
        with self.tx():
            self.x("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = ?", (key,))
            return int(self.scalar("SELECT value FROM meta WHERE key = ?", (key,)))

    def bump(self) -> int:
        with self.tx():
            self.x("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'seq'")
            return int(self.scalar("SELECT value FROM meta WHERE key = 'seq'"))

    def cursor(self) -> int:
        return int(self.scalar("SELECT value FROM meta WHERE key = 'seq'"))

    # ---- items ------------------------------------------------------------------

    def insert_item(self, item: dict, image: Optional[bytes], reason: Optional[str] = None) -> bool:
        """Store one item revision and queue it for organizing.

        Returns False (counted as a duplicate, nothing changes) when this (item_id, revision) is
        already stored or when a higher revision of the item is already stored (stale retry).
        A higher revision becomes the item's current content and re-runs organizing for it.
        """
        with self.tx():
            if self.is_tombstoned(item["item_id"]):
                return False  # deleted by the user; the API answers 410 before it gets here
            latest = self.latest_revision(item["item_id"])
            if latest is not None and item["revision"] <= latest:
                return False
            started_ts = iso_to_ts(item["started_at"])
            ended_ts = iso_to_ts(item["ended_at"]) if item.get("ended_at") else None
            meta = {k: item[k] for k in META_KEYS if item.get(k) is not None}
            self.x(
                "INSERT INTO items(item_id, revision, kind, source_app, started_at, started_ts, ended_at, ended_ts,"
                " text, segments, persons, sha256, has_image, received_at, meta)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    item["item_id"], item["revision"], item["kind"], dumps(item["source_app"]),
                    item["started_at"], started_ts, item.get("ended_at"), ended_ts,
                    item.get("text"), dumps(item["segments"]) if item.get("segments") is not None else None,
                    dumps(item["persons"]) if item.get("persons") is not None else None,
                    item["sha256"], 1 if image else 0, now_iso(), dumps(meta) if meta else None,
                ),
            )
            if latest is None and not self.one("SELECT 1 FROM item_handles WHERE item_id=?", (item["item_id"],)):
                self.x("INSERT INTO item_handles(item_id, n) VALUES (?,?)",
                       (item["item_id"], self._next("item_handle_seq")))
            if image:
                if item["kind"] == "file":
                    mime = (item.get("mime") or "application/octet-stream")[:128]
                else:
                    mime = "image/png" if image.startswith(b"\x89PNG") else "image/jpeg"
                self.x("INSERT INTO item_blobs(item_id, revision, mime, data) VALUES (?,?,?,?)",
                       (item["item_id"], item["revision"], mime, image))
            self.x("UPDATE jobs SET state='superseded' WHERE item_id=? AND state IN ('queued','failed')",
                   (item["item_id"],))
            # Read-then-delete covers superseded revisions too: only the latest revision is ever read, so the
            # bytes of an older revision that was not read yet are deleted now instead of staying for good.
            self.x("DELETE FROM item_blobs WHERE item_id=? AND revision < ?", (item["item_id"], item["revision"]))
            self.enqueue(item["item_id"], item["revision"], started_ts,
                         reason or ("ingest" if latest is None else "revision"))
            return True

    def get_item(self, item_id: str, revision: Optional[int] = None) -> Optional[dict]:
        if revision is None:
            row = self.one("SELECT * FROM latest_items WHERE item_id=?", (item_id,))
        else:
            row = self.one("SELECT * FROM items WHERE item_id=? AND revision=?", (item_id, revision))
        return _decode_item(row) if row else None

    def latest_revision(self, item_id: str) -> Optional[int]:
        return self.scalar("SELECT MAX(revision) FROM items WHERE item_id=?", (item_id,))

    def get_blob(self, item_id: str, revision: int) -> Optional[dict]:
        return self.one("SELECT mime, data FROM item_blobs WHERE item_id=? AND revision=?", (item_id, revision))

    def save_derived(self, item_id: str, revision: int, *, drop_blob: bool = False, **fields: Any) -> None:
        """Store derived fields of an item revision. drop_blob=True is read-then-delete: the reading and the
        deletion of the image / file bytes commit in one transaction."""
        with self.tx():
            if self.is_tombstoned(item_id):
                raise ItemPurged(item_id)
            cur = self.one("SELECT * FROM item_derived WHERE item_id=? AND revision=?", (item_id, revision))
            row = dict(cur) if cur else {"item_id": item_id, "revision": revision}
            for key, value in fields.items():
                row[key] = dumps(value) if key in ("messages", "embedding") and value is not None else value
            row["created_at"] = now_iso()
            if "derived_text" in fields:
                row["reading_seq"] = self.bump()  # a new reading: clients pull it via /v1/state readings
            row["reading_seq"] = row.get("reading_seq") or 0
            for key in ("split", "reading"):
                if key in fields and fields[key] is not None:
                    row[key] = dumps(fields[key])
            cols = ["item_id", "revision", "derived_text", "summary", "messages", "screenshot_run_id", "embedding",
                    "embed_model", "created_at", "reading_seq", "split", "reading"]
            self.x(f"INSERT OR REPLACE INTO item_derived({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                   [row.get(c) for c in cols])
            if drop_blob:
                self.x("DELETE FROM item_blobs WHERE item_id=? AND revision=?", (item_id, revision))

    def mark_unreadable(self, item_id: str, revision: int, kind: str, why: str = "unreadable") -> bool:
        """A read that failed for good (retries exhausted, or the endpoint refused the image): the bytes are
        deleted all the same and the item gets an empty reading marked `unreadable`, so it is organized by
        what else is known. Returns False when there was nothing to do (already read, or no bytes)."""
        with self.tx():
            if self.is_tombstoned(item_id):
                return False
            derived = self.one("SELECT screenshot_run_id FROM item_derived WHERE item_id=? AND revision=?",
                               (item_id, revision))
            has_blob = self.one("SELECT 1 FROM item_blobs WHERE item_id=? AND revision=?", (item_id, revision))
            if not has_blob and (derived or {}).get("screenshot_run_id"):
                return False
            if not has_blob and kind not in ("image", "file"):
                return False
            reading = {"type": "other" if kind == "image" else "data", "error": why, "fields": [], "numbers": []}
            if kind == "file":
                reading.update(source="file-read", counts={}, attachments=[], doc_kind="", notes=[])
            self.save_derived(item_id, revision, drop_blob=True, derived_text="", summary="", messages=[],
                              screenshot_run_id=f"unreadable:{revision}", reading=reading)
            return True
    def get_derived(self, item_id: str, revision: int) -> dict:
        row = self.one("SELECT * FROM item_derived WHERE item_id=? AND revision=?", (item_id, revision)) or {}
        if row.get("messages"):
            row["messages"] = json.loads(row["messages"])
        if row.get("embedding"):
            row["embedding"] = json.loads(row["embedding"])
        for key in ("split", "reading"):
            if row.get(key):
                row[key] = json.loads(row[key])
        return row

    def readings_since(self, since: int) -> list[dict]:
        """Derived readings (image-read) of each item's current revision written after `since`."""
        rows = self.all(
            "SELECT d.item_id, d.revision, d.derived_text, d.summary, d.messages, d.screenshot_run_id, d.reading_seq,"
            " d.reading"
            " FROM item_derived d JOIN latest_items li ON li.item_id = d.item_id AND li.revision = d.revision"
            " WHERE d.screenshot_run_id IS NOT NULL AND d.reading_seq > ? ORDER BY d.reading_seq", (since,))
        for r in rows:
            r["messages"] = json.loads(r["messages"]) if r.get("messages") else []
            r["reading"] = json.loads(r["reading"]) if r.get("reading") else None
        return rows

    def item_handle(self, item_id: str) -> str:
        n = self.scalar("SELECT n FROM item_handles WHERE item_id=?", (item_id,))
        return f"I{n}" if n is not None else item_id

    def event_handle(self, event_id: str) -> str:
        n = self.scalar("SELECT handle FROM events WHERE event_id=?", (event_id,))
        return f"E{n}" if n is not None else event_id

    def event_id_by_handle(self, handle: str) -> Optional[str]:
        if not handle or not handle.startswith("E") or not handle[1:].isdigit():
            return None
        return self.scalar("SELECT event_id FROM events WHERE handle=?", (int(handle[1:]),))

    def count_items(self) -> int:
        """Items the Mac sent (internal segment children are not counted)."""
        return int(self.scalar("SELECT COUNT(DISTINCT item_id) FROM items WHERE purged = 0"
                               " AND item_id NOT IN (SELECT child_id FROM item_segments)") or 0)

    # ---- user delete (privacy contract section 2) ------------------------------------------

    def is_tombstoned(self, item_id: str) -> bool:
        return self.one("SELECT 1 FROM item_tombstones WHERE item_id=?", ((item_id or "").lower(),)) is not None

    def tombstoned(self, item_ids: list[str]) -> list[str]:
        """The ids among item_ids that the user deleted."""
        return [i for i in item_ids if self.is_tombstoned(i)]

    def purge_item(self, item_id: str) -> dict:
        """Delete an item on the user's request, across all revisions: its content columns become NULL, its
        blobs, derived rows (readings, embeddings, splits), persons and segments go, and so do its segment
        children (text slices of it) and a recording's keyframes (image items whose parent_item_id is it) the
        same way. Its event links are removed (removed_by 'user-delete') and facts citing it are dropped.

        Every event it was ever in (now, before a move or a merge, or in an event the user deleted) may quote
        it, and a card is not left to a later brief that can fail: a live event keeps only its user-typed title
        (or its anchor) until it is briefed again, and loses its status line and rank reason; a deleted event,
        or one left empty, is blanked. An anchor seeded from the item is cleared (the next brief sets one).
        Questions about it expire with their prompt blanked; run outputs and proposal payloads about it and about
        those events (their briefs and ranks quote it) are cleared, and so are those of every run whose recorded
        read set holds it (event-assign candidates, briefs, event-consolidate and person-resolve calls), as is any
        other audit record carrying the start of its text. The scheduled passes' own tables follow: its
        person_scan rows go, the person_checks of records it leaves with no item go, and the consolidate_checks
        rows of the events it was in go. A content-free tombstone keeps a later POST of the id out (410).
        Idempotent; an unknown id only gets its tombstone."""
        key = (item_id or "").lower()
        with self.tx():
            stored = [r["item_id"] for r in self.all("SELECT DISTINCT item_id FROM items WHERE lower(item_id)=?",
                                                     (key,))]
            # A recording's keyframes (and a GIF's extra frames) are image items of their own that carry text read
            # from it: they go with it.
            frames = [r["item_id"] for r in self.all(
                "SELECT DISTINCT item_id FROM items WHERE meta IS NOT NULL"
                " AND lower(json_extract(meta, '$.parent_item_id'))=?", (key,))]
            parents = [key] + [f.lower() for f in frames]
            pmarks = ",".join("?" * len(parents))
            children = [r["child_id"] for r in self.all(
                f"SELECT child_id FROM item_segments WHERE lower(parent_id) IN ({pmarks})", parents)]
            ids = list(dict.fromkeys(stored + frames + children))
            now = now_iso()
            for tomb in dict.fromkeys([key] + [i.lower() for i in frames + children]):
                self.x("INSERT OR IGNORE INTO item_tombstones(item_id, deleted_at) VALUES (?,?)", (tomb, now))
            self.purges += 1
            touched: list[str] = []
            if ids:
                marks = ",".join("?" * len(ids))
                # The start of each text of the item (its revisions, parts and readings): audit copies elsewhere
                # (a 60-character excerpt in another item's assign proposal, a question prompt) are found by it.
                heads = set()
                for r in self.all(f"SELECT text FROM items WHERE item_id IN ({marks}) UNION ALL SELECT derived_text"
                                  f" FROM item_derived WHERE item_id IN ({marks})", ids + ids):
                    head = (r["text"] or "").strip().replace("\n", " ").replace('"', " ")[:12]
                    if len(head) >= 8 and head.strip():
                        heads.add(head)
                self._purged_heads.update(heads)
                self.x(f"UPDATE items SET text=NULL, segments=NULL, persons=NULL, sha256=NULL, meta=NULL,"
                       f" source_app='{{}}', purged=1 WHERE item_id IN ({marks})", ids)
                touched = [r["event_id"] for r in self.all(
                    f"SELECT DISTINCT event_id FROM event_items WHERE item_id IN ({marks}) AND removed=0", ids)]
                # Every event it was ever linked to, removed links included (moved out, merged, event deleted).
                ever = list(dict.fromkeys(touched + [r["event_id"] for r in self.all(
                    f"SELECT DISTINCT event_id FROM event_items WHERE item_id IN ({marks})", ids)]))
                # The event whose anchor this item seeded; for events created before anchor_item was recorded,
                # the item linked first.
                seeded = {r["event_id"] for r in self.all(
                    f"SELECT event_id FROM events WHERE anchor_item IN ({marks})", ids)}
                for event_id in ever:
                    first = self.one("SELECT item_id FROM event_items WHERE event_id=? ORDER BY link_seq, rowid"
                                     " LIMIT 1", (event_id,))
                    ev_row = self.one("SELECT anchor_item FROM events WHERE event_id=?", (event_id,))
                    if ev_row and ev_row["anchor_item"] is None and first and first["item_id"] in ids:
                        seeded.add(event_id)
                self.x(f"UPDATE event_items SET removed=1, removed_by='user-delete' WHERE item_id IN ({marks})"
                       f" AND removed=0", ids)
                # People it named or who spoke in it (people pass): a record left with no item keeps no verdict.
                linked = [r["person_id"] for r in self.all(
                    f"SELECT DISTINCT person_id FROM item_persons WHERE item_id IN ({marks})", ids)]
                for table in ("item_blobs", "item_derived", "item_persons", "person_scan"):
                    self.x(f"DELETE FROM {table} WHERE item_id IN ({marks})", ids)
                for pid in linked:
                    if self.one("SELECT 1 FROM item_persons WHERE person_id=? LIMIT 1", (pid,)) is None:
                        self.x("DELETE FROM person_checks WHERE person_id=?", (pid,))
                self.x(f"DELETE FROM item_segments WHERE child_id IN ({marks}) OR parent_id IN ({marks})", ids + ids)
                self.x(f"UPDATE jobs SET state='purged', error=NULL WHERE item_id IN ({marks})", ids)
                self.x(f"DELETE FROM unfiled WHERE item_id IN ({marks})", ids)
                # Runs and proposals about the item, and about the events it was ever in (their briefs quote it),
                # keep no content; neither do ranks that listed those events, nor any other audit record or
                # question prompt that carries the start of its text.
                subjects = ids + ever
                smarks = ",".join("?" * len(subjects))
                self.x(f"UPDATE runs SET output=NULL, input_text=NULL WHERE subject IN ({smarks})", subjects)
                self.x(f"UPDATE proposals SET payload='{{}}', reason='' WHERE target_id IN ({smarks})", subjects)
                # Runs whose input held the item (a candidate in another item's assign, a member in a brief), by
                # the recorded read set rather than by a text prefix; and their proposals.
                read_by = [r["run_id"] for r in self.all(
                    f"SELECT run_id FROM runs WHERE read_items IS NOT NULL AND EXISTS (SELECT 1 FROM"
                    f" json_each(runs.read_items) j WHERE j.value IN ({marks}))", ids)]
                for n in range(0, len(read_by), 500):
                    chunk = read_by[n:n + 500]
                    cmarks = ",".join("?" * len(chunk))
                    self.x(f"UPDATE runs SET output=NULL, input_text=NULL WHERE run_id IN ({cmarks})", chunk)
                    self.x(f"UPDATE proposals SET payload='{{}}', reason='' WHERE run_id IN ({cmarks})", chunk)
                for event_id in ever:
                    handle = '"' + self.event_handle(event_id) + '"'
                    self.x("UPDATE runs SET output=NULL, input_text=NULL WHERE subject='home'"
                           " AND (instr(output, ?) > 0 OR instr(input_text, ?) > 0)", (handle, handle))
                    self.x("UPDATE proposals SET payload='{}', reason='' WHERE target_id='home'"
                           " AND instr(payload, ?) > 0", (handle,))
                for head in heads:
                    self.x("UPDATE runs SET output=NULL, input_text=NULL WHERE instr(output, ?) > 0"
                           " OR instr(input_text, ?) > 0", (head, head))
                    self.x("UPDATE proposals SET payload='{}', reason='' WHERE instr(payload, ?) > 0", (head,))
                    self.x("UPDATE questions SET prompt_zh='', status=CASE WHEN status='open' THEN 'expired'"
                           " ELSE status END WHERE instr(prompt_zh, ?) > 0", (head,))
                qs = self.all(f"SELECT question_id FROM questions WHERE a IN ({marks}) OR b IN ({marks})"
                              f" OR item_id IN ({marks})", ids * 3)
                for q in qs:
                    self.x("UPDATE questions SET prompt_zh='', status=CASE WHEN status='open' THEN 'expired'"
                           " ELSE status END WHERE question_id=?", (q["question_id"],))
                if qs:
                    self.bump()
                gone = set(ids)
                # The consolidation pass's record of these events (ids, counts, outcome; no content): they changed,
                # so they are judged afresh.
                emarks = ",".join("?" * len(ever))
                if ever:
                    self.x(f"DELETE FROM consolidate_checks WHERE event_id IN ({emarks})", ever)
                for event_id in ever:
                    ev = self.get_event(event_id)
                    if ev is None:
                        continue
                    anchor, anchor_source = ev["anchor"], ev["anchor_source"]
                    if event_id in seeded and anchor_source != "user":
                        anchor, anchor_source = "", ""
                    if ev["deleted"] or not self.event_item_ids(event_id):
                        # Deleted (by the user, or merged away) or left empty: nothing written from the item stays.
                        self.update_event(event_id, deleted=1, needs_brief=0, title="", status_line="",
                                          status_facts=[], anchor="", anchor_source="", importance_reason="",
                                          provenance={})
                        continue
                    facts = [f for f in ev["status_facts"] if not gone & set(f.get("item_ids") or [])]
                    title = ev["title"] if ev["title_user_edited"] else anchor
                    prov = {k: v for k, v in ev["provenance"].items() if k == "title" and ev["title_user_edited"]}
                    self.recompute_event(event_id)  # needs_brief=1: the card is written again without it
                    self.update_event(event_id, title=title, status_line="", status_facts=facts, anchor=anchor,
                                      anchor_source=anchor_source, importance_reason="", provenance=prov)
            return {"deleted": True, "revisions": len(stored), "children": len(children), "frames": len(frames),
                    "events": len(touched)}

    def checkpoint(self) -> None:
        """Move the WAL into the database file and truncate it (after a purge: old page versions leave the WAL)."""
        if self.memory:
            return
        with self._lock:
            try:
                self._c().execute("PRAGMA wal_checkpoint(TRUNCATE)")
            except db.OperationalError:
                pass

    def stats(self) -> dict:
        """Sizes, for the storage promise (contract section 2, GET /v1/stats). Unlocked only."""
        blob = int(self.scalar("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM item_blobs") or 0)
        derived = int(self.scalar(
            "SELECT COALESCE(SUM(COALESCE(LENGTH(CAST(derived_text AS BLOB)),0) + COALESCE(LENGTH(CAST(summary AS BLOB)),0)"
            " + COALESCE(LENGTH(CAST(messages AS BLOB)),0) + COALESCE(LENGTH(CAST(embedding AS BLOB)),0)"
            " + COALESCE(LENGTH(CAST(reading AS BLOB)),0) + COALESCE(LENGTH(CAST(split AS BLOB)),0)), 0)"
            " FROM item_derived") or 0)
        size = 0
        if not self.memory:
            for suffix in ("", *db.SIDE_FILES):
                try:
                    size += os.path.getsize(self.path + suffix)
                except OSError:
                    pass
        return {"items": self.count_items(), "blob_bytes": blob, "db_bytes": size, "derived_bytes": derived}

    def legacy_inbox_rows(self) -> list[dict]:
        """Phone-inbox rows of a store from before inbox.db (handed over once, then dropped)."""
        if not self.one("SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbox'"):
            return []
        return self.all("SELECT * FROM inbox ORDER BY seq")

    def drop_legacy_inbox(self) -> None:
        with self.tx():
            self.x("DROP TABLE IF EXISTS inbox")

    # ---- segments (item-split) -----------------------------------------------------

    def segment_of(self, child_id: str) -> Optional[dict]:
        return self.one("SELECT * FROM item_segments WHERE child_id=?", (child_id,))

    def segments_of(self, parent_id: str, active_only: bool = True) -> list[dict]:
        return self.all("SELECT * FROM item_segments WHERE parent_id=?" + (" AND active=1" if active_only else "")
                        + " ORDER BY seg_index, seg_id", (parent_id,))

    def child_for(self, parent_id: str, seg_id: str) -> Optional[str]:
        return self.scalar("SELECT child_id FROM item_segments WHERE parent_id=? AND seg_id=? AND active=1",
                           (parent_id, seg_id))

    def upsert_segment(self, child_id: str, parent_id: str, parent_revision: int, seg: dict, index: int) -> None:
        with self.tx():
            if self.is_tombstoned(parent_id):
                raise ItemPurged(parent_id)
            cur = self.segment_of(child_id)
            no_matter = int(bool(seg.get("no_matter")))
            if cur and cur["active"] and (cur["parent_id"], cur["parent_revision"], cur["seg_index"], cur["start"],
                                          cur["end"], cur["gist"], cur["no_matter"]) == (
                    parent_id, parent_revision, index, seg["start"], seg["end"], seg.get("gist") or "", no_matter):
                return  # unchanged (a retried job)
            self.x("INSERT INTO item_segments(child_id, parent_id, parent_revision, seg_id, seg_index, start, \"end\","
                   " gist, active, seq, no_matter) VALUES (?,?,?,?,?,?,?,?,1,?,?) ON CONFLICT(child_id) DO UPDATE SET"
                   " parent_revision=excluded.parent_revision, seg_index=excluded.seg_index, start=excluded.start,"
                   " \"end\"=excluded.\"end\", gist=excluded.gist, active=1, seq=excluded.seq,"
                   " no_matter=excluded.no_matter",
                   (child_id, parent_id, parent_revision, seg["seg_id"], index, seg["start"], seg["end"],
                    seg.get("gist") or "", self.bump(), no_matter))

    def retire_segment(self, child_id: str) -> None:
        with self.tx():
            self.x("UPDATE item_segments SET active=0, seq=? WHERE child_id=? AND active=1", (self.bump(), child_id))
            self.x("UPDATE jobs SET state='superseded' WHERE item_id=? AND state IN ('queued','failed')", (child_id,))

    # ---- jobs -------------------------------------------------------------------

    def enqueue(self, item_id: str, revision: int, started_ts: float, reason: str) -> None:
        with self.tx():
            self.x(
                "INSERT INTO jobs(item_id, revision, started_ts, state, attempts, reason, enqueued_at, not_before)"
                " VALUES (?,?,?,'queued',0,?,?,0)"
                " ON CONFLICT(item_id, revision) DO UPDATE SET state='queued', attempts=0, reason=excluded.reason,"
                " error=NULL, error_category=NULL, enqueued_at=excluded.enqueued_at, not_before=0",
                (item_id, revision, started_ts, reason, time.time()),
            )

    def requeue_latest(self, item_id: str, reason: str) -> None:
        item = self.get_item(item_id)
        if item:
            self.enqueue(item_id, item["revision"], item["started_ts"], reason)

    def claim_next_job(self) -> Optional[dict]:
        with self.tx():
            job = self.one(
                "SELECT * FROM jobs WHERE state='queued' AND not_before <= ? ORDER BY started_ts, item_id LIMIT 1",
                (time.time(),),
            )
            if job:
                self.x("UPDATE jobs SET state='running', run_started=?, attempts=attempts+1 WHERE item_id=? AND revision=?",
                       (time.time(), job["item_id"], job["revision"]))
                job["attempts"] += 1
            return job

    def finish_job(self, item_id: str, revision: int, state: str = "done",
                   error: Optional[str] = None, category: Optional[str] = None, delay_s: float = 0.0) -> None:
        with self.tx():
            self.x(
                # Only a running job is finished: a decision may have re-queued it meanwhile.
                "UPDATE jobs SET state=?, error=?, error_category=?, run_ended=?, not_before=?"
                " WHERE item_id=? AND revision=? AND state='running'",
                (state, error, category, time.time(), time.time() + delay_s, item_id, revision),
            )

    def reset_running_jobs(self) -> int:
        return self.x("UPDATE jobs SET state='queued' WHERE state='running'").rowcount

    def queue_depth(self) -> int:
        return int(self.scalar("SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')") or 0)

    # ---- events -----------------------------------------------------------------

    def create_event(self, item: dict, anchor: str = "", event_id: Optional[str] = None) -> str:
        event_id = event_id or new_id()
        with self.tx():
            if item.get("item_id") and self.is_tombstoned(item["item_id"]):
                raise ItemPurged(item["item_id"])  # never an event seeded from a deleted item
            self.x(
                "INSERT INTO events(event_id, started_at, started_ts, updated_at, updated_ts, created_at, seq,"
                " needs_brief, handle, anchor, anchor_source, anchor_item) VALUES (?,?,?,?,?,?,?,1,?,?,?,?)",
                (event_id, item["started_at"], item["started_ts"], item.get("ended_at") or item["started_at"],
                 item.get("ended_ts") or item["started_ts"], self.now(), self.bump(), self._next("event_handle_seq"),
                 (anchor or "").strip()[:40], "model" if anchor else "", item.get("item_id") or ""),
            )
        return event_id

    def get_event(self, event_id: str) -> Optional[dict]:
        row = self.one("SELECT * FROM events WHERE event_id=?", (event_id,))
        return _decode_event(row) if row else None

    def live_events(self) -> list[dict]:
        return [_decode_event(r) for r in self.all(
            "SELECT * FROM events WHERE deleted=0 ORDER BY updated_ts DESC, handle")]

    def count_events(self) -> int:
        return int(self.scalar("SELECT COUNT(*) FROM events WHERE deleted=0") or 0)

    def update_event(self, event_id: str, **fields: Any) -> None:
        if not fields:
            return
        with self.tx():
            sets, args = [], []
            for key, value in fields.items():
                if key in ("status_facts", "provenance"):
                    value = dumps(value)
                elif isinstance(value, bool):
                    value = int(value)
                sets.append(f"{key}=?")
                args.append(value)
            sets.append("seq=?")
            args.append(self.bump())
            self.x(f"UPDATE events SET {', '.join(sets)} WHERE event_id=?", [*args, event_id])

    def attach(self, event_id: str, item_id: str, attached_by: str, run_id: Optional[str] = None,
               item_revision: Optional[int] = None) -> None:
        """Link an item to an event. item_revision records which revision the placement is based on."""
        with self.tx():
            if self.is_tombstoned(item_id):
                raise ItemPurged(item_id)
            if item_revision is None:
                item_revision = self.latest_revision(item_id)
            self.x(
                "INSERT INTO event_items(event_id, item_id, attached_by, run_id, created_at, removed, item_revision,"
                " link_seq, off_anchor) VALUES (?,?,?,?,?,0,?,?,0) ON CONFLICT(event_id, item_id) DO UPDATE SET"
                " attached_by=excluded.attached_by, run_id=excluded.run_id, created_at=excluded.created_at,"
                " removed=0, removed_by=NULL, item_revision=excluded.item_revision, link_seq=excluded.link_seq,"
                " off_anchor=0",
                (event_id, item_id, attached_by, run_id, self.now(), item_revision, self.bump()),
            )
            self.clear_unfiled(item_id)
            self.recompute_event(event_id)

    def mark_placed(self, event_id: str, item_id: str, item_revision: int) -> None:
        """Keep an existing link but record that it now reflects item_revision."""
        with self.tx():
            self.x("UPDATE event_items SET item_revision=? WHERE event_id=? AND item_id=? AND removed=0",
                   (item_revision, event_id, item_id))
            self.recompute_event(event_id)

    def detach(self, event_id: str, item_id: str, removed_by: str) -> None:
        with self.tx():
            self.x("UPDATE event_items SET removed=1, removed_by=? WHERE event_id=? AND item_id=? AND removed=0",
                   (removed_by, event_id, item_id))
            self.recompute_event(event_id)

    def current_event_link(self, item_id: str) -> Optional[dict]:
        return self.one(
            "SELECT ei.*, e.deleted FROM event_items ei JOIN events e ON e.event_id = ei.event_id"
            " WHERE ei.item_id=? AND ei.removed=0 ORDER BY ei.link_seq DESC LIMIT 1",
            (item_id,),
        )

    def event_item_ids(self, event_id: str) -> list[str]:
        return [r["item_id"] for r in self.all(
            "SELECT ei.item_id FROM event_items ei JOIN latest_items li ON li.item_id = ei.item_id"
            " WHERE ei.event_id=? AND ei.removed=0 ORDER BY li.started_ts, ei.item_id",
            (event_id,),
        )]

    def matching_item_ids(self, event_id: str) -> list[str]:
        """Members used to match new items: all except model-placed items flagged off-anchor."""
        return [r["item_id"] for r in self.all(
            "SELECT ei.item_id FROM event_items ei JOIN latest_items li ON li.item_id = ei.item_id"
            " WHERE ei.event_id=? AND ei.removed=0 AND ei.off_anchor=0 ORDER BY li.started_ts, ei.item_id",
            (event_id,),
        )]

    def set_off_anchor(self, event_id: str, item_ids: list[str], clear_others: bool = False) -> list[str]:
        """Flag model-placed members as off-anchor (user placements are never flagged). Returns newly
        flagged ids. With clear_others, members not listed lose the flag (a later brief no longer sees
        them as another object), so they shape matching again."""
        flagged = []
        with self.tx():
            if clear_others:
                keep = set(item_ids)
                for r in self.all("SELECT item_id FROM event_items WHERE event_id=? AND removed=0 AND off_anchor=1",
                                  (event_id,)):
                    if r["item_id"] not in keep:
                        self.x("UPDATE event_items SET off_anchor=0 WHERE event_id=? AND item_id=?",
                               (event_id, r["item_id"]))
            for iid in item_ids:
                n = self.x("UPDATE event_items SET off_anchor=1 WHERE event_id=? AND item_id=? AND removed=0"
                           " AND attached_by='model' AND off_anchor=0", (event_id, iid)).rowcount
                if n:
                    flagged.append(iid)
        return flagged

    # ---- unfiled ----------------------------------------------------------------

    def set_unfiled(self, item_id: str, reason: str, run_id: Optional[str] = None) -> None:
        with self.tx():
            if self.is_tombstoned(item_id):
                raise ItemPurged(item_id)
            self.x("INSERT INTO unfiled(item_id, reason, run_id, since, recheck_count, seq) VALUES (?,?,?,?,0,?)"
                   " ON CONFLICT(item_id) DO UPDATE SET reason=excluded.reason, run_id=excluded.run_id,"
                   " seq=excluded.seq",
                   (item_id, reason, run_id, self.now(), self.bump()))

    def clear_unfiled(self, item_id: str) -> bool:
        with self.tx():
            n = self.x("DELETE FROM unfiled WHERE item_id=?", (item_id,)).rowcount
            if n:
                self.bump()
            return bool(n)

    def unfiled_items(self) -> list[dict]:
        return self.all("SELECT * FROM unfiled ORDER BY seq")

    def is_unfiled(self, item_id: str) -> bool:
        return self.one("SELECT 1 FROM unfiled WHERE item_id=?", (item_id,)) is not None

    def recompute_event(self, event_id: str) -> None:
        with self.tx():
            row = self.one(
                "SELECT MIN(li.started_ts) AS s_ts, MAX(COALESCE(li.ended_ts, li.started_ts)) AS u_ts"
                " FROM event_items ei JOIN latest_items li ON li.item_id = ei.item_id"
                " WHERE ei.event_id=? AND ei.removed=0",
                (event_id,),
            )
            fields: dict[str, Any] = {"needs_brief": 1}
            if row and row["s_ts"] is not None:
                first = self.one(
                    "SELECT li.started_at FROM event_items ei JOIN latest_items li ON li.item_id = ei.item_id"
                    " WHERE ei.event_id=? AND ei.removed=0 ORDER BY li.started_ts LIMIT 1", (event_id,))
                last = self.one(
                    "SELECT COALESCE(li.ended_at, li.started_at) AS t FROM event_items ei"
                    " JOIN latest_items li ON li.item_id = ei.item_id WHERE ei.event_id=? AND ei.removed=0"
                    " ORDER BY COALESCE(li.ended_ts, li.started_ts) DESC LIMIT 1", (event_id,))
                fields.update(started_at=first["started_at"], started_ts=row["s_ts"],
                              updated_at=last["t"], updated_ts=row["u_ts"])
            self.update_event(event_id, **fields)

    # ---- constraints / decisions --------------------------------------------------

    def add_constraint(self, kind: str, a: str, b: str, decision_id: Optional[int]) -> None:
        if kind == "apart_events":
            a, b = sorted((a, b))
        self.x("INSERT OR IGNORE INTO constraints(kind, a, b, decision_id, created_at) VALUES (?,?,?,?,?)",
               (kind, a, b, decision_id, self.now()))

    def has_constraint(self, kind: str, a: str, b: str) -> bool:
        if kind == "apart_events":
            a, b = sorted((a, b))
        return self.one("SELECT 1 FROM constraints WHERE kind=? AND a=? AND b=?", (kind, a, b)) is not None

    def forbidden_events_for(self, item_id: str) -> set[str]:
        return {r["b"] for r in self.all("SELECT b FROM constraints WHERE kind='forbid_item_event' AND a=?", (item_id,))}

    def record_decision(self, kind: str, payload: dict, origin: str, applied: bool, note: str = "") -> int:
        try:
            created = self.now()
        except RuntimeError:  # a replay clock with no item processed yet: nothing semantic to order against
            created = now_iso()
        cur = self.x(
            "INSERT INTO decisions(kind, payload, origin, created_at, applied, note) VALUES (?,?,?,?,?,?)",
            (kind, dumps(payload), origin, created, int(applied), note),
        )
        return int(cur.lastrowid)

    # ---- questions --------------------------------------------------------------

    def open_questions(self) -> list[dict]:
        return self.all("SELECT * FROM questions WHERE status='open' ORDER BY q_seq, question_id")

    def create_question(self, kind: str, a: str, b: str, prompt_zh: str, limit: int,
                        item_id: Optional[str] = None, run_id: Optional[str] = None, *,
                        day_key: Optional[str] = None, per_day: Optional[int] = None,
                        per_event_per_day: Optional[int] = None, provisional: Optional[dict] = None,
                        b_items: Optional[list[str]] = None, dry_run: bool = False) -> Optional[str]:
        """Create an open question unless a budget or an existing question/answer blocks it.

        limit            max open questions of this kind (same_event and same_person have separate budgets,
                         so unanswered person questions cannot starve "is this the same event?").
        per_day          max questions of this kind whose subject item falls on day_key (item date, not the
                         wall clock), answered or not, so answering does not refill the day.
        per_event_per_day  max questions about one target b per day_key.
        dry_run          only report whether the budget allows it (returns "ok" or None).
        """
        with self.tx():
            if any(self.is_tombstoned(x) for x in (item_id, a, b) if x):
                return None  # never a question about a deleted item
            if int(self.scalar("SELECT COUNT(*) FROM questions WHERE status='open' AND kind=?", (kind,))) >= limit:
                return None
            if item_id and self.one("SELECT 1 FROM questions WHERE item_id=? AND kind=?", (item_id, kind)):
                return None  # at most one question of this kind per item, ever
            if self.one("SELECT 1 FROM questions WHERE kind=? AND ((a=? AND b=?) OR (a=? AND b=?))",
                        (kind, a, b, b, a)):
                return None
            if day_key and per_day is not None and int(self.scalar(
                    "SELECT COUNT(*) FROM questions WHERE kind=? AND day_key=?", (kind, day_key))) >= per_day:
                return None
            if day_key and per_event_per_day is not None and int(self.scalar(
                    "SELECT COUNT(*) FROM questions WHERE kind=? AND day_key=? AND b=?",
                    (kind, day_key, b))) >= per_event_per_day:
                return None
            if dry_run:
                return "ok"
            qid = new_id()
            self.x(
                "INSERT INTO questions(question_id, kind, a, b, prompt_zh, created_at, status, item_id, run_id,"
                " q_seq, day_key, provisional, b_items_at_ask) VALUES (?,?,?,?,?,?,'open',?,?,?,?,?,?)",
                (qid, kind, a, b, prompt_zh, self.now(), item_id, run_id, self.bump(), day_key,
                 dumps(provisional) if provisional is not None else None,
                 dumps(b_items) if b_items is not None else None),
            )
            return qid

    def expire_stale_questions(self, now_ts: float, ttl_h: float = 72.0) -> int:
        """Expire open questions older than ttl_h (by the semantic clock). Placements are kept."""
        with self.tx():
            n = 0
            for q in self.open_questions():
                try:
                    created = datetime.fromisoformat(q["created_at"]).timestamp()
                except (TypeError, ValueError):
                    continue
                if now_ts - created >= ttl_h * 3600:
                    n += self.x("UPDATE questions SET status='expired' WHERE question_id=? AND status='open'",
                                (q["question_id"],)).rowcount
            if n:
                self.bump()
            return n

    def expire_questions_touching(self, ids: list[str]) -> None:
        if not ids:
            return
        marks = ",".join("?" * len(ids))
        with self.tx():
            n = self.x(
                f"UPDATE questions SET status='expired' WHERE status='open' AND (a IN ({marks}) OR b IN ({marks}))",
                [*ids, *ids],
            ).rowcount
            if n:
                self.bump()

    # ---- runs / proposals -------------------------------------------------------

    def record_run(self, run: dict) -> None:
        cols = ["run_id", "job_type", "skill", "version", "model", "prompt_hash", "input_digest", "output",
                "error", "attempts", "started_at", "ended_at", "ok", "prompt_tokens", "completion_tokens", "subject",
                "as_of", "input_text", "read_items"]
        row = dict(run)
        reads = row.get("read_items") or []
        row["read_items"] = dumps(reads) if reads else None
        if any(self.is_tombstoned(i) for i in reads):
            row["output"] = row["input_text"] = None  # it read an item deleted while it ran
        # A run's output is model text read from the material (and, for image-read, from an image): it is
        # masked like any derived text before it is stored. A run about a deleted item keeps no content, nor does
        # one that returned after a purge with the start of a deleted text in it.
        if row.get("subject") and self.is_tombstoned(row["subject"]):
            row["output"] = row["input_text"] = None
        if row.get("output") is not None:
            row["output"] = self.mask_obj(row["output"]) if not isinstance(row["output"], str) \
                else self.mask_text(row["output"])
        for key in ("error", "input_text"):
            if row.get(key):
                row[key] = self.mask_text(row[key])
        if self._quotes_purged(row.get("output")) or self._quotes_purged(row.get("input_text")):
            row["output"] = row["input_text"] = None
        if row.get("output") is not None and not isinstance(row["output"], str):
            row["output"] = dumps(row["output"])
        self.x(f"INSERT INTO runs({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", [row.get(c) for c in cols])

    def record_proposal(self, run_id: Optional[str], kind: str, target_id: Optional[str], payload: dict,
                        status: str, reason: str = "") -> None:
        if (target_id and self.is_tombstoned(target_id)) or self._quotes_purged(payload) \
                or self._quotes_purged(reason) or self._run_read_purged(run_id):
            payload, reason = {}, ""
        self.x(
            "INSERT INTO proposals(run_id, kind, target_id, payload, status, reason, created_at) VALUES (?,?,?,?,?,?,?)",
            (run_id, kind, target_id, dumps(payload), status, reason, now_iso()),
        )

    def _run_read_purged(self, run_id: Optional[str]) -> bool:
        """Whether the run read an item that has been deleted since (its proposal keeps no content)."""
        if not run_id:
            return False
        row = self.one("SELECT read_items FROM runs WHERE run_id=?", (run_id,))
        reads = json.loads(row["read_items"]) if row and row.get("read_items") else []
        return any(self.is_tombstoned(i) for i in reads)

    def _quotes_purged(self, value: Any) -> bool:
        if not self._purged_heads or value is None:
            return False
        text = value if isinstance(value, str) else dumps(value)
        return any(head in text for head in self._purged_heads)

    def recent_runs(self, limit: int = 50) -> list[dict]:
        rows = self.all("SELECT * FROM runs ORDER BY started_at DESC LIMIT ?", (limit,))
        for r in rows:
            r.pop("input_text", None)  # eval-only prompt capture is never served over the API
        for r in rows:
            if r.get("output"):
                try:
                    r["output"] = json.loads(r["output"])
                except ValueError:
                    pass
        return rows


# Item metadata kept per revision (see schemas.FILE_META_KEYS).
META_KEYS = ("filename", "uti", "mime", "size", "local_text", "captured_at", "parent_item_id", "frame_ms",
             "pictures_redacted")


def _decode_item(row: dict) -> dict:
    item = dict(row)
    item["meta"] = json.loads(item["meta"]) if item.get("meta") else {}
    item["source_app"] = json.loads(item["source_app"])
    item["segments"] = json.loads(item["segments"]) if item.get("segments") else []
    item["persons"] = json.loads(item["persons"]) if item.get("persons") else []
    return item


def _decode_event(row: dict) -> dict:
    ev = dict(row)
    ev["status_facts"] = json.loads(ev["status_facts"] or "[]")
    ev["provenance"] = json.loads(ev["provenance"] or "{}")
    for key in ("title_user_edited", "pinned", "feature_less", "deleted", "needs_brief"):
        ev[key] = bool(ev[key])
    return ev
