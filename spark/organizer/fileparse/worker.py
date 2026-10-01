"""Sandboxed parser process: reads one file from stdin, writes the parse result as JSON to stdout.

stdin:  4-byte big-endian header length, JSON header {"filename", "mime"}, then the raw file bytes.
stdout: JSON {type, text, title, counts, attachments, fields, error, fmt, notes, images: [{id, label, page, b64}]}

The parent (organizer/fileparse/__init__.py) starts this with CPU, memory, file-size and open-file limits,
a wall-clock timeout, an empty environment and, where the kernel allows it, no network namespace. Here
the socket API is disabled as well before any parser is imported, so no library can open a connection.
"""

from __future__ import annotations

import base64
import json
import socket
import sys


def _no_network() -> None:
    def refuse(*_a, **_k):
        raise OSError("network access is disabled in the file parser")

    class NoSocket(socket.socket):  # type: ignore[misc]
        def __init__(self, *a, **k):
            refuse()

    socket.socket = NoSocket  # type: ignore[misc]
    socket.create_connection = refuse  # type: ignore[assignment]
    socket.getaddrinfo = refuse  # type: ignore[assignment]
    socket.socketpair = refuse  # type: ignore[assignment]


def main() -> int:
    _no_network()
    sys.setrecursionlimit(4000)
    stream = sys.stdin.buffer
    n = int.from_bytes(stream.read(4), "big")
    header = json.loads(stream.read(n).decode("utf-8"))
    data = stream.read()
    from .core import Budget
    from .dispatch import parse_bytes
    budget = Budget()
    parsed = parse_bytes(data, header.get("filename") or "", header.get("mime") or "", budget, 0)
    out = parsed.to_dict()
    out["notes"] = budget.notes
    out["media_skipped"] = budget.media_skipped
    out["images"] = [{"id": im["id"], "label": im["label"], "page": im["page"],
                      "b64": base64.b64encode(im["data"]).decode("ascii")} for im in budget.images]
    sys.stdout.buffer.write(json.dumps(out, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
