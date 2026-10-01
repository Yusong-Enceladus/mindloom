"""The one place that opens SQLite connections for the organizer's stores.

Every store connection (organizer.db, inbox.db, harness readers) is opened by connect() below, with
SQLCipher (the "sqlcipher3-wheels" package: SQLCipher 4 with its own bundled SQLite). A store opened
with a key is encrypted at rest: pages, the WAL and the rollback journal are all ciphertext, and a
connection without the key reads nothing (docs/PRIVACY.md).

  connect(path, key)       key = 32 raw bytes (the store key derived from the library key, organizer/keys.py);
                           None opens an unencrypted database (":memory:", or the phone inbox).
  is_plaintext(path)       an existing file with the plain SQLite header (a store written before encryption).
  encrypt_in_place(path, key)
                           copies a plaintext database into an encrypted one with sqlcipher_export(), then
                           replaces the plaintext file and removes its -wal / -shm / -journal. The freed disk
                           blocks of the old file are not overwritten (the filesystem may keep them).

The file-read sandbox reads an uploaded .sqlite file in memory with the standard library (fileparse/textish.py);
that is a parser for user bytes, not a store, and it never touches a file.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional
from urllib.parse import quote

from sqlcipher3 import dbapi2 as sqlite3

DatabaseError = sqlite3.DatabaseError
IntegrityError = sqlite3.IntegrityError
OperationalError = sqlite3.OperationalError
Row = sqlite3.Row
Connection = sqlite3.Connection
Cursor = sqlite3.Cursor

PLAIN_HEADER = b"SQLite format 3\x00"
SIDE_FILES = ("-wal", "-shm", "-journal")


def _key_pragma(key: bytes) -> str:
    if not isinstance(key, (bytes, bytearray)) or len(key) != 32:
        raise ValueError("a store key is 32 bytes")
    return "PRAGMA key = \"x'" + bytes(key).hex() + "'\""


def connect(path: str | Path, key: Optional[bytes] = None, *, check_same_thread: bool = False,
            isolation_level: Optional[str] = None, readonly: bool = False) -> sqlite3.Connection:
    """Open one connection. With a key the database is SQLCipher-encrypted (a new file is created encrypted);
    the key is applied before anything is read and checked by reading the schema, so a wrong key raises
    DatabaseError here instead of later."""
    target = str(path)
    if readonly and target != ":memory:":
        target = "file:" + quote(Path(target).resolve().as_posix()) + "?mode=ro"
        conn = sqlite3.connect(target, uri=True, check_same_thread=check_same_thread, isolation_level=isolation_level)
    else:
        conn = sqlite3.connect(target, check_same_thread=check_same_thread, isolation_level=isolation_level)
    try:
        if key is not None:
            conn.execute(_key_pragma(key))
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
    except BaseException:
        conn.close()
        raise
    return conn


def is_plaintext(path: str | Path) -> bool:
    try:
        with open(path, "rb") as fh:
            return fh.read(16) == PLAIN_HEADER
    except FileNotFoundError:
        return False


def remove_side_files(path: str | Path) -> None:
    for suffix in SIDE_FILES:
        try:
            os.unlink(str(path) + suffix)
        except FileNotFoundError:
            pass


def encrypt_in_place(path: str | Path, key: bytes) -> None:
    """Encrypt a plaintext SQLite database with `key` (SQLCipher raw key), keeping its content."""
    path = Path(path)
    tmp = path.with_name(path.name + ".enc-tmp")
    for p in (tmp, *(Path(str(tmp) + s) for s in SIDE_FILES)):
        if p.exists():
            p.unlink()
    src = connect(path, None)
    try:
        # Everything committed in the plaintext WAL is read through this connection; nothing is lost.
        src.execute("ATTACH DATABASE '" + str(tmp).replace("'", "''") + "' AS enc KEY \"x'" + bytes(key).hex() + "'\"")
        src.execute("SELECT sqlcipher_export('enc')")
        src.execute("DETACH DATABASE enc")
    finally:
        src.close()
    fd = os.open(tmp, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    check = connect(tmp, key)
    check.close()
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    remove_side_files(path)
    remove_side_files(tmp)


def open_for_analysis(path: str | Path, library_key: Optional[bytes] = None) -> sqlite3.Connection:
    """A read-only connection for analysis scripts over a synthetic run's store: a plaintext store from before
    encryption as it is, an encrypted one with `library_key` (default: the fixed synthetic key)."""
    if is_plaintext(path):
        return connect(path, None, readonly=True)
    from .keys import derive_keys, synthetic_library_key
    return connect(path, derive_keys(library_key or synthetic_library_key())[1], readonly=True)

