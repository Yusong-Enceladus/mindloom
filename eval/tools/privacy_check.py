#!/usr/bin/env python3
"""Check an organizer data directory for plaintext (privacy contract v6, section 8 E2E). Synthetic data only.

  privacy_check.py --data-dir DIR --needle SENTINEL [--needle ...] [--key-stdin]

1. Every file under DIR is scanned for each needle (UTF-8 bytes): with the store encrypted, no needle may
   appear in any file (the phone inbox excepted while an entry still waits for the Mac).
2. With --key-stdin, a 64-hex library key is read from stdin (never from argv or the environment, never
   written anywhere), the store is opened read-only with the key derived from it, and each needle is looked
   up in every row of every table: after a delete, the deleted item's sentinel must be gone even for someone
   holding the key.

Prints JSON with counts and file / table names only, never content. Exit status 0 = no needle found, 1 = found.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))

from organizer import db, keys  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--needle", action="append", required=True, help="a synthetic sentinel string")
    ap.add_argument("--key-stdin", action="store_true", help="read the library key (64 hex) from stdin")
    a = ap.parse_args(argv)
    data = Path(a.data_dir).expanduser().resolve()
    if "Application Support" in str(data):
        raise SystemExit("refusing: synthetic data only")
    needles = [n.encode("utf-8") for n in a.needle]
    files = [p for p in data.rglob("*") if p.is_file() and not p.is_symlink()]
    hits: dict[str, list[str]] = {}
    for p in files:
        blob = p.read_bytes()
        for i, n in enumerate(needles):
            if n in blob:
                hits.setdefault(str(i), []).append(p.name)
    store = data / "organizer.db"
    out = {"files_scanned": len(files), "plaintext_hits": hits,
           "store_exists": store.exists(), "store_plaintext_header": db.is_plaintext(store),
           "key_id_on_disk": keys.read_key_id(data / "store.keyid")}
    found = bool(hits)
    if a.key_stdin:
        key = keys.parse_key_hex(sys.stdin.readline().strip())
        if key is None:
            raise SystemExit("stdin must hold the 64-hex library key")
        key_id, store_key, _ = keys.derive_keys(key)
        out["key_id"] = key_id
        decrypted: dict[str, dict[str, int]] = {}
        if store.exists():
            conn = db.connect(store, store_key, readonly=True)
            try:
                tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
                for t in tables:
                    for row in conn.execute(f'SELECT * FROM "{t}"'):
                        for v in row:
                            b = v if isinstance(v, bytes) else (str(v).encode("utf-8") if v is not None else b"")
                            for i, n in enumerate(needles):
                                if n in b:
                                    decrypted.setdefault(str(i), {}).setdefault(t, 0)
                                    decrypted[str(i)][t] += 1
            finally:
                conn.close()
        out["decrypted_hits"] = decrypted
        found = found or bool(decrypted)
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
