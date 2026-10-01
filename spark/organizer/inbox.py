"""The phone inbox (contract C) in its own small inbox.db.

A phone share (zhiji-inbox add, over SSH) must be accepted while the organizer store is locked (after a
Spark restart, before the Mac reconnects), so the inbox cannot live in the encrypted organizer.db. It is a
transient hand-over, not a store: an entry waits here only until the Mac fetches it (GET /v1/inbox) and
acks it; the ack deletes its content and keeps a content-free row (id, source, kind, times) so a retried
add stays a duplicate. secure_delete overwrites acked content in the database file, and wipe() drops what
is still waiting.

What waits here is sealed (the 织机 iPhone app, phone contract section 5): `blob` holds the phone's `mlseal1.`
string exactly as received. It is sealed to the Mac's key; nothing on the Spark can open it, and this module
never looks inside. The row's id is kept byte for byte (a lowercase UUID), because it is part of the seal.
New plaintext entries are refused (schemas.InboxIn: the iOS Shortcut path is retired). The text / image
columns remain only for rows handed over once from the in-store inbox of an organizer.db written before
inbox.db existed (import_legacy), which the Mac takes right after the unlock that moves them.

Sequence numbers are milliseconds since the epoch (strictly increasing), so they are always above the
cursors a Mac kept from the older in-store inbox (whose seq was the organizer's small change counter).
"""

from __future__ import annotations

import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from . import db


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class InboxStore:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self.conn = db.connect(self.path, None, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = db.Row
        if self.path != ":memory:":
            # A rollback journal (no WAL): acked content is overwritten in the file itself (secure_delete).
            self.conn.execute("PRAGMA journal_mode=DELETE")
        self.conn.execute("PRAGMA secure_delete=ON")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS inbox(inbox_id TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL,"
            " text TEXT, image BLOB, received_at TEXT NOT NULL, created_at TEXT NOT NULL,"
            " acked INTEGER NOT NULL DEFAULT 0, acked_at TEXT, seq INTEGER NOT NULL)")
        # inbox.db files from before sealed entries have no blob column (a sealed entry's mlseal1 string)
        if "blob" not in {r[1] for r in self.conn.execute("PRAGMA table_info(inbox)")}:
            self.conn.execute("ALTER TABLE inbox ADD COLUMN blob TEXT")
        self.conn.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        self.conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('seq', '0')")
        if self.path != ":memory:":
            import os
            os.chmod(self.path, 0o600)

    def _next_seq(self) -> int:
        last = int(self.conn.execute("SELECT value FROM meta WHERE key='seq'").fetchone()[0])
        seq = max(last + 1, int(time.time() * 1000))
        self.conn.execute("UPDATE meta SET value=? WHERE key='seq'", (str(seq),))
        return seq

    def add(self, entry: dict, image: Optional[bytes]) -> tuple[str, bool]:
        """Store one phone share. Returns (inbox_id, created); a retry with the same inbox_id is not stored
        again (also after it was acked). A sealed entry's id arrives as a lowercase UUID (schemas.InboxIn
        refuses any other form), so lower() never changes it."""
        inbox_id = (entry.get("inbox_id") or str(uuid.uuid4())).lower()
        with self._lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                if self.conn.execute("SELECT 1 FROM inbox WHERE inbox_id=?", (inbox_id,)).fetchone():
                    self.conn.execute("COMMIT")
                    return inbox_id, False
                self.conn.execute(
                    "INSERT INTO inbox(inbox_id, source, kind, text, image, blob, received_at, created_at, acked, seq)"
                    " VALUES (?,?,?,?,?,?,?,?,0,?)",
                    (inbox_id, entry["source"], entry["kind"], entry.get("text"), image, entry.get("blob"),
                     entry["received_at"], _now_iso(), self._next_seq()))
                self.conn.execute("COMMIT")
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
        return inbox_id, True

    def since(self, since: int, limit: int) -> list[dict]:
        with self._lock:
            return [dict(r) for r in self.conn.execute(
                "SELECT inbox_id, source, kind, text, image, blob, received_at, seq FROM inbox"
                " WHERE acked=0 AND seq > ? ORDER BY seq LIMIT ?", (since, limit)).fetchall()]

    def page(self, since: int, limit: int, budget: int) -> tuple[list[dict], bool]:
        """Unacked entries after `since`, oldest first, up to `limit` entries and `budget` content bytes
        (always at least one entry). Sizes are looked up first and only the entries on the page are read,
        so a queue of large sealed entries (up to 48 MB each) is never loaded at once. Returns (rows, more)."""
        with self._lock:
            sizes = self.conn.execute(
                "SELECT seq, COALESCE(length(CAST(text AS BLOB)), 0) + COALESCE(length(image), 0)"
                " + COALESCE(length(blob), 0) FROM inbox WHERE acked=0 AND seq > ? ORDER BY seq LIMIT ?",
                (since, limit)).fetchall()
            chosen, total = [], 0
            for seq, n in sizes:
                if chosen and total + n > budget:
                    break
                chosen.append(seq)
                total += n
            rows = [dict(r) for r in self.conn.execute(
                "SELECT inbox_id, source, kind, text, image, blob, received_at, seq FROM inbox"
                " WHERE acked=0 AND seq > ? AND seq <= ? ORDER BY seq", (since, chosen[-1])).fetchall()] if chosen else []
            return rows, len(chosen) < len(sizes) or len(sizes) == limit

    def pending(self) -> int:
        with self._lock:
            return int(self.conn.execute("SELECT COUNT(*) FROM inbox WHERE acked=0").fetchone()[0])

    def one(self, inbox_id: str) -> Optional[dict]:
        with self._lock:
            row = self.conn.execute("SELECT * FROM inbox WHERE inbox_id=?", (inbox_id.lower(),)).fetchone()
            return dict(row) if row else None

    def ack(self, inbox_id: str) -> Optional[bool]:
        """Drop the content once the Mac has it. Returns True (acked now), False (already acked) or None
        (unknown id). The row stays as a content-free tombstone so a retried add is still a duplicate."""
        with self._lock:
            row = self.conn.execute("SELECT acked FROM inbox WHERE inbox_id=?", (inbox_id.lower(),)).fetchone()
            if row is None:
                return None
            if row["acked"]:
                return False
            self.conn.execute("UPDATE inbox SET acked=1, acked_at=?, text=NULL, image=NULL, blob=NULL"
                              " WHERE inbox_id=?", (_now_iso(), inbox_id.lower()))
            return True

    def import_legacy(self, rows: list[dict]) -> int:
        """Rows of the inbox table of an older organizer.db (unlocked once): kept with their ids, in their order."""
        n = 0
        with self._lock:
            for r in rows:
                if self.conn.execute("SELECT 1 FROM inbox WHERE inbox_id=?", (r["inbox_id"],)).fetchone():
                    continue
                self.conn.execute(
                    "INSERT INTO inbox(inbox_id, source, kind, text, image, received_at, created_at, acked, acked_at, seq)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (r["inbox_id"], r["source"], r["kind"], None if r["acked"] else r.get("text"),
                     None if r["acked"] else r.get("image"), r["received_at"], r["created_at"], r["acked"],
                     r.get("acked_at"), self._next_seq()))
                n += 1
        return n

    def wipe(self) -> int:
        """Forget everything still waiting (POST /v1/wipe); acked rows hold no content and stay as ids."""
        with self._lock:
            n = self.conn.execute("UPDATE inbox SET acked=1, acked_at=?, text=NULL, image=NULL, blob=NULL"
                                  " WHERE acked=0", (_now_iso(),)).rowcount
            self.conn.execute("VACUUM")
            return n

    def close(self) -> None:
        with self._lock:
            self.conn.close()
