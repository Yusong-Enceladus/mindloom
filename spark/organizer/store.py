"""SQLite store (stdlib only).

Guarantees enforced here:
- Source items are append-only per (item_id, revision); SQLite triggers reject UPDATE/DELETE.
  The latest revision is the item's current content; a revision lower than the stored latest is
  stale and ignored, so a late retry can never roll an item back.
- meta.store_id is a UUID created once with the database; clients use it to detect a reset store.
- Every change that a client must see bumps a global sequence number; GET /v1/state?since=
  returns rows whose seq is greater than the client's cursor.
- One connection shared across threads behind an RLock; transactions are short and never
  span a model call.
- Semantic timestamps (events, links, questions, decisions, constraints, persons) come from the
  injected Clock (organizer/clock.py); audit timestamps (received_at, runs, jobs, proposals) stay on
  the wall clock. Orderings never depend on either: they use seq counters and stable short handles.
- Every event gets a short handle (E1, E2, ...) and every item a handle (I1, I2, ...) at creation.
  Handles are what the model sees; they are never reused.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

from .clock import Clock, WallClock

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta(key, value) VALUES ('seq', '0'), ('schema_version', '1');

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
  sha256 TEXT NOT NULL,
  has_image INTEGER NOT NULL DEFAULT 0,
  received_at TEXT NOT NULL,
  PRIMARY KEY (item_id, revision)
);
CREATE TRIGGER IF NOT EXISTS items_no_update BEFORE UPDATE ON items
BEGIN SELECT RAISE(ABORT, 'items are append-only'); END;
CREATE TRIGGER IF NOT EXISTS items_no_delete BEFORE DELETE ON items
BEGIN SELECT RAISE(ABORT, 'items are append-only'); END;

CREATE VIEW IF NOT EXISTS latest_items AS
  SELECT i.* FROM items i
  WHERE i.revision = (SELECT MAX(r.revision) FROM items r WHERE r.item_id = i.item_id);

CREATE TABLE IF NOT EXISTS item_blobs(
  item_id TEXT NOT NULL, revision INTEGER NOT NULL, mime TEXT NOT NULL, data BLOB NOT NULL,
  PRIMARY KEY (item_id, revision)
);
CREATE TRIGGER IF NOT EXISTS item_blobs_no_update BEFORE UPDATE ON item_blobs
BEGIN SELECT RAISE(ABORT, 'item blobs are append-only'); END;

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


class Store:
    def __init__(self, path: str | Path, clock: Optional[Clock] = None):
        self.clock: Clock = clock or WallClock()
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._depth = 0
        self.conn = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(SCHEMA)
        self._migrate()
        # Created exactly once per database file; a fresh database gets a fresh id.
        self.conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('store_id', ?)", (new_id(),))
        self.store_id: str = str(self.scalar("SELECT value FROM meta WHERE key = 'store_id'"))

    def _cols(self, table: str) -> set[str]:
        return {r["name"] for r in self.conn.execute(f"PRAGMA table_info({table})").fetchall()}

    def _add_col(self, table: str, col: str, decl: str) -> bool:
        if col in self._cols(table):
            return False
        self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
        return True

    def _migrate(self) -> None:
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
        # --- phone inbox (contract C): held only until the Mac acks; acked rows keep no content ---
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS inbox(inbox_id TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL,"
            " text TEXT, image BLOB, received_at TEXT NOT NULL, created_at TEXT NOT NULL,"
            " acked INTEGER NOT NULL DEFAULT 0, acked_at TEXT, seq INTEGER NOT NULL)")

    # ---- primitives -------------------------------------------------------------

    @contextmanager
    def tx(self) -> Iterator["Store"]:
        with self._lock:
            outer = self._depth == 0
            if outer:
                self.conn.execute("BEGIN IMMEDIATE")
            self._depth += 1
            try:
                yield self
            except BaseException:
                self._depth -= 1
                if outer:
                    self.conn.execute("ROLLBACK")
                raise
            self._depth -= 1
            if outer:
                self.conn.execute("COMMIT")

    def x(self, sql: str, args: tuple | list = ()) -> sqlite3.Cursor:
        with self._lock:
            return self.conn.execute(sql, args)

    def all(self, sql: str, args: tuple | list = ()) -> list[dict]:
        with self._lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def one(self, sql: str, args: tuple | list = ()) -> Optional[dict]:
        with self._lock:
            row = self.conn.execute(sql, args).fetchone()
            return dict(row) if row else None

    def scalar(self, sql: str, args: tuple | list = ()) -> Any:
        with self._lock:
            row = self.conn.execute(sql, args).fetchone()
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

    def save_derived(self, item_id: str, revision: int, **fields: Any) -> None:
        with self.tx():
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
        return int(self.scalar("SELECT COUNT(DISTINCT item_id) FROM items"
                               " WHERE item_id NOT IN (SELECT child_id FROM item_segments)") or 0)

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

    # ---- phone inbox --------------------------------------------------------------

    def inbox_add(self, entry: dict, image: Optional[bytes]) -> tuple[str, bool]:
        """Store one phone share. Returns (inbox_id, created); a retry with the same inbox_id is not stored
        again (also after it was acked)."""
        inbox_id = (entry.get("inbox_id") or new_id()).lower()
        with self.tx():
            if self.one("SELECT 1 FROM inbox WHERE inbox_id=?", (inbox_id,)):
                return inbox_id, False
            self.x("INSERT INTO inbox(inbox_id, source, kind, text, image, received_at, created_at, acked, seq)"
                   " VALUES (?,?,?,?,?,?,?,0,?)",
                   (inbox_id, entry["source"], entry["kind"], entry.get("text"), image, entry["received_at"],
                    now_iso(), self.bump()))
        return inbox_id, True

    def inbox_since(self, since: int, limit: int) -> list[dict]:
        return self.all("SELECT inbox_id, source, kind, text, image, received_at, seq FROM inbox"
                        " WHERE acked=0 AND seq > ? ORDER BY seq LIMIT ?", (since, limit))

    def inbox_pending(self) -> int:
        return int(self.scalar("SELECT COUNT(*) FROM inbox WHERE acked=0") or 0)

    def inbox_ack(self, inbox_id: str) -> Optional[bool]:
        """Drop the content once the Mac has it. Returns True (acked now), False (already acked) or None
        (unknown id). The row stays as a content-free tombstone so a retried add is still a duplicate."""
        with self.tx():
            row = self.one("SELECT acked FROM inbox WHERE inbox_id=?", (inbox_id.lower(),))
            if row is None:
                return None
            if row["acked"]:
                return False
            self.x("UPDATE inbox SET acked=1, acked_at=?, text=NULL, image=NULL WHERE inbox_id=?",
                   (now_iso(), inbox_id.lower()))
            return True

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
            self.x(
                "INSERT INTO events(event_id, started_at, started_ts, updated_at, updated_ts, created_at, seq,"
                " needs_brief, handle, anchor, anchor_source) VALUES (?,?,?,?,?,?,?,1,?,?,?)",
                (event_id, item["started_at"], item["started_ts"], item.get("ended_at") or item["started_at"],
                 item.get("ended_ts") or item["started_ts"], self.now(), self.bump(), self._next("event_handle_seq"),
                 (anchor or "").strip()[:40], "model" if anchor else ""),
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
                "as_of", "input_text"]
        row = dict(run)
        if row.get("output") is not None and not isinstance(row["output"], str):
            row["output"] = dumps(row["output"])
        self.x(f"INSERT INTO runs({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", [row.get(c) for c in cols])

    def record_proposal(self, run_id: Optional[str], kind: str, target_id: Optional[str], payload: dict,
                        status: str, reason: str = "") -> None:
        self.x(
            "INSERT INTO proposals(run_id, kind, target_id, payload, status, reason, created_at) VALUES (?,?,?,?,?,?,?)",
            (run_id, kind, target_id, dumps(payload), status, reason, now_iso()),
        )

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
META_KEYS = ("filename", "uti", "mime", "size", "local_text", "captured_at", "parent_item_id", "frame_ms")


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
