#!/usr/bin/env python3
"""Storage on the Spark before and after the privacy contract v6, measured on a COPY of an organizer store.

What it does (synthetic data only; the source file is only read, never opened for writing):
  1. copies --source (organizer.db, plus its -wal when that holds data) into --work;
  2. measures the copy as it was: file bytes, items the Mac sent, image / file blob bytes, derived bytes;
  3. applies read-then-delete: deletes every image / file blob (a finished run has read them all; one that was
     never read would be marked unreadable and deleted the same way), then VACUUM;
  4. encrypts the copy with SQLCipher (the same sqlcipher_export path as the service's first unlock), opens it
     with the organizer's Store (schema migration to the purge-only integrity rule) and checkpoints it;
  5. writes the numbers, including bytes per 1,000 items, as JSON.

  python eval/tools/privacy_storage.py --source <run>/data/organizer.db --work <scratch dir> --out storage.json

The copy is encrypted with the fixed synthetic key (organizer/keys.py): the source is synthetic data.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))

from organizer import db, keys  # noqa: E402
from organizer.store import Store  # noqa: E402


def file_bytes(path: Path) -> int:
    return sum(os.path.getsize(str(path) + s) for s in ("", *db.SIDE_FILES) if os.path.exists(str(path) + s))


def measure(conn) -> dict:
    one = lambda sql: conn.execute(sql).fetchone()[0]  # noqa: E731
    has_segments = one("SELECT COUNT(*) FROM sqlite_master WHERE name='item_segments'")
    child = " AND item_id NOT IN (SELECT child_id FROM item_segments)" if has_segments else ""
    blobs = conn.execute(
        "SELECT i.kind, COUNT(*), COALESCE(SUM(LENGTH(b.data)), 0) FROM item_blobs b JOIN items i"
        " ON i.item_id = b.item_id AND i.revision = b.revision GROUP BY i.kind").fetchall()
    by_kind = {k: {"count": n, "bytes": size} for k, n, size in blobs}
    derived = one("SELECT COALESCE(SUM(COALESCE(LENGTH(CAST(derived_text AS BLOB)),0)"
                  " + COALESCE(LENGTH(CAST(summary AS BLOB)),0) + COALESCE(LENGTH(CAST(messages AS BLOB)),0)"
                  " + COALESCE(LENGTH(CAST(embedding AS BLOB)),0) + COALESCE(LENGTH(CAST(reading AS BLOB)),0)"
                  " + COALESCE(LENGTH(CAST(split AS BLOB)),0)), 0) FROM item_derived")
    read = one("SELECT COUNT(*) FROM item_blobs b JOIN item_derived d ON d.item_id = b.item_id"
               " AND d.revision = b.revision AND d.screenshot_run_id IS NOT NULL")
    return {
        "items": one(f"SELECT COUNT(DISTINCT item_id) FROM items WHERE 1=1{child}"),
        "item_revisions": one("SELECT COUNT(*) FROM items"),
        "blob_count": sum(v["count"] for v in by_kind.values()),
        "blob_bytes": sum(v["bytes"] for v in by_kind.values()),
        "blobs_by_kind": by_kind,
        "blobs_with_reading": read,
        "derived_bytes": derived,
        "embedding_bytes": one("SELECT COALESCE(SUM(LENGTH(CAST(embedding AS BLOB))), 0) FROM item_derived"),
        "text_bytes": one("SELECT COALESCE(SUM(COALESCE(LENGTH(CAST(text AS BLOB)),0)"
                          " + COALESCE(LENGTH(CAST(segments AS BLOB)),0)), 0) FROM items"),
        "runs_output_bytes": one("SELECT COALESCE(SUM(LENGTH(CAST(output AS BLOB))), 0) FROM runs"),
        "runs_input_text_bytes": one("SELECT COALESCE(SUM(LENGTH(CAST(input_text AS BLOB))), 0) FROM runs")
        if "input_text" in {r[1] for r in conn.execute("PRAGMA table_info(runs)")} else 0,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, help="an organizer.db of a synthetic run (only read)")
    ap.add_argument("--work", required=True, help="a scratch directory for the copy (created)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    source, work = Path(a.source).resolve(), Path(a.work).resolve()
    if "Application Support" in str(source):
        raise SystemExit("refusing: synthetic stores only")
    if not db.is_plaintext(source):
        raise SystemExit("the source is not a plaintext store from before encryption")
    work.mkdir(parents=True, exist_ok=True)
    copy = work / "organizer.db"
    for p in (copy, *(Path(str(copy) + s) for s in db.SIDE_FILES), work / "store.keyid"):
        if p.exists():
            p.unlink()
    shutil.copyfile(source, copy)
    wal = Path(str(source) + "-wal")
    if wal.exists() and wal.stat().st_size > 0:
        shutil.copyfile(wal, str(copy) + "-wal")
    t0 = time.time()
    out: dict = {"source_bytes": file_bytes(source)}

    conn = db.connect(copy, None, isolation_level=None)
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    out["before"] = {**measure(conn), "db_bytes": file_bytes(copy)}
    # read-then-delete: a finished run has read every image and file; the bytes go
    conn.execute("PRAGMA secure_delete=ON")
    conn.execute("DELETE FROM item_blobs")
    conn.execute("VACUUM")
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    out["after_read_then_delete_plaintext"] = {**measure(conn), "db_bytes": file_bytes(copy)}
    conn.close()

    library_key = keys.synthetic_library_key()
    key_id, store_key, _ = keys.derive_keys(library_key)
    db.encrypt_in_place(copy, store_key)
    store = Store(copy, key=library_key)  # migrates to the purge-only rule, as the service's first unlock does
    store.checkpoint()
    conn = store.conn
    after = {**measure(conn), "db_bytes": file_bytes(copy)}
    store.lock()
    after["plaintext_header"] = db.is_plaintext(copy)
    out["after_encryption"] = after
    items = max(1, after["items"])
    out["bytes_per_1000_items"] = {
        "before": round(out["before"]["db_bytes"] * 1000 / items),
        "after": round(after["db_bytes"] * 1000 / items),
    }
    out["reduction_pct"] = round(100 * (1 - after["db_bytes"] / max(1, out["before"]["db_bytes"])), 1)
    mb = lambda n: round(n / 1e6, 1)  # noqa: E731
    out["summary_mb"] = {
        "db_before": mb(out["before"]["db_bytes"]), "db_after": mb(after["db_bytes"]),
        "blobs_before": mb(out["before"]["blob_bytes"]), "embeddings": mb(after["embedding_bytes"]),
        "per_1000_items_before": mb(out["bytes_per_1000_items"]["before"]),
        "per_1000_items_after": mb(out["bytes_per_1000_items"]["after"]),
        "embedding_share_pct": round(100 * after["embedding_bytes"] / max(1, after["db_bytes"]), 1),
        "encryption_overhead_pct": round(100 * (after["db_bytes"] / max(1, out["after_read_then_delete_plaintext"]
                                                                        ["db_bytes"]) - 1), 1),
    }
    out["key_id"] = key_id
    out["seconds"] = round(time.time() - t0, 1)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
