#!/usr/bin/env python3
"""[P1 stub] Read-only recall over the organizer state (stdlib only).

usage: recall.py --uds <data_dir>/organizer.sock --token-file <data_dir>/link_token [--k 3] QUERY...
       recall.py --url http://127.0.0.1:<forwarded port> --token-file ... QUERY...
The organizer serves only its private Unix socket by default; --url is for an SSH forward to it.
The organizer requires its link token on every request; it is read from --token-file, never argv.
Prints {"query", "events": [{event_id, title, status_line, status_facts, updated_at}]}.
"""

from __future__ import annotations

import argparse
import http.client
import json
import socket
import sys
import urllib.request
from pathlib import Path


class _UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP over the organizer's private Unix socket (stdlib only)."""

    def __init__(self, path: str, timeout: float):
        super().__init__("organizer", timeout=timeout)
        self._path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def fetch_state(url: str | None, uds: str | None, token: str | None) -> dict:
    headers = {"Authorization": "Bearer " + token} if token else {}
    if uds:
        conn = _UnixHTTPConnection(uds, timeout=10)
        try:
            conn.request("GET", "/v1/state", headers=headers)
            resp = conn.getresponse()
            if resp.status != 200:
                raise RuntimeError(f"organizer answered HTTP {resp.status}")
            return json.load(resp)
        finally:
            conn.close()
    req = urllib.request.Request(url.rstrip("/") + "/v1/state", headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def match(events: list[dict], query: str, k: int) -> list[dict]:
    terms = [t for t in query.split() if t]
    scored = []
    for ev in events:
        if ev.get("deleted"):
            continue
        hay = " ".join([ev.get("title", ""), ev.get("status_line", "")]
                       + [f.get("text", "") for f in ev.get("status_facts", [])])
        hits = sum(1 for t in terms if t in hay)
        if hits:
            scored.append((hits, ev.get("importance", 0), ev.get("updated_at") or "", ev))
    scored.sort(key=lambda s: (s[0], s[1], s[2]), reverse=True)
    return [{k2: s[3].get(k2) for k2 in ("event_id", "title", "status_line", "status_facts", "updated_at")}
            for s in scored[:k]]


def main() -> int:
    ap = argparse.ArgumentParser()
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--uds", help="the organizer's Unix socket, e.g. <data_dir>/organizer.sock")
    where.add_argument("--url", help="a loopback base URL forwarded to the socket")
    ap.add_argument("--token-file", help="the instance's link_token (<data_dir>/link_token)")
    ap.add_argument("--k", type=int, default=3)
    ap.add_argument("query", nargs="+")
    args = ap.parse_args()
    token = Path(args.token_file).read_text(encoding="ascii").strip() if args.token_file else None
    state = fetch_state(args.url, args.uds, token)
    query = " ".join(args.query)
    json.dump({"query": query, "events": match(state.get("events", []), query, args.k)},
              sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
