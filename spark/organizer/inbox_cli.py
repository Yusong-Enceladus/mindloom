"""zhiji-inbox — put something from the phone into the organizer's inbox on this Spark.

An iOS Shortcut ("分享到织机", see docs/PHONE.md) runs this over SSH ("Run Script over SSH"), passing
the shared text on stdin:

    zhiji-inbox add --source iPhone                 # text from stdin
    zhiji-inbox add --source iPhone --image shot.png
    zhiji-inbox add --source iPhone --image -       # base64 (or raw PNG/JPEG) image on stdin
    zhiji-inbox status                              # how many shares wait for the Mac
    zhiji-inbox gate                                # SSH forced command: runs SSH_ORIGINAL_COMMAND only
                                                    # if it is one of the two commands above

It talks to the organizer's private Unix socket with the link token, both read from the data directory
(ORGANIZER_DATA_DIR, ORGANIZER_UDS), as the same user that runs the organizer. Nothing is sent anywhere
else: the share waits on the Spark until the Mac fetches it (GET /v1/inbox) and acks it, then its
content is dropped here. Exit status 0 = stored (or already stored), 1 = rejected, 2 = unreachable.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import shlex
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

import httpx

MAX_TEXT_CHARS = 400_000


def _paths() -> tuple[Path, Path]:
    data_dir = Path(os.environ.get("ORGANIZER_DATA_DIR", str(Path.home() / "hack" / "organizer-data")))
    uds = os.environ.get("ORGANIZER_UDS", "")
    return (Path(uds) if uds else data_dir / "organizer.sock"), data_dir / "link_token"


def _client(socket_path: Path, token_path: Path) -> httpx.Client:
    headers = {}
    if token_path.exists():
        headers["Authorization"] = "Bearer " + token_path.read_text(encoding="utf-8").strip()
    return httpx.Client(transport=httpx.HTTPTransport(uds=str(socket_path)), base_url="http://organizer",
                        headers=headers, timeout=30.0, trust_env=False)


def _read_image(arg: str, stdin: bytes) -> bytes:
    raw = stdin if arg == "-" else Path(arg).expanduser().read_bytes()
    if raw.startswith(b"\x89PNG") or raw.startswith(b"\xff\xd8"):
        return raw
    try:  # Shortcuts' "Base64 Encode" output (may wrap lines)
        decoded = base64.b64decode(b"".join(raw.split()), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SystemExit(f"zhiji-inbox: the image is neither PNG/JPEG nor base64 of one ({exc})")
    return decoded


def build_entry(source: str, text: Optional[str], image: Optional[bytes], inbox_id: Optional[str] = None,
                received_at: Optional[str] = None) -> dict:
    entry = {"inbox_id": inbox_id or str(uuid.uuid4()), "source": source,
             "kind": "image" if image else "text",
             "received_at": received_at or datetime.now().astimezone().isoformat(timespec="seconds")}
    if image:
        entry["image_b64"] = base64.b64encode(image).decode()
    elif text is not None:
        entry["text"] = text
    return entry


_GATE_FLAGS = {"--source": 1, "--image": 1, "--json": 0}


def gate_argv(original: Optional[str]) -> Optional[list[str]]:
    """For an SSH key restricted with command=".../zhiji-inbox gate": the argv of the command the phone
    asked for, or None if it is anything but `zhiji-inbox add [--source X] [--image -] [--json]` or
    `zhiji-inbox status`. Images come only on stdin (no file paths), so the key cannot read files."""
    try:
        words = shlex.split(original or "")
    except ValueError:
        return None
    if words and os.path.basename(words[0]) == "zhiji-inbox":
        words = words[1:]
    if words == ["status"]:
        return words
    if not words or words[0] != "add":
        return None
    i = 1
    while i < len(words):
        flag = words[i]
        if flag not in _GATE_FLAGS:
            return None
        if _GATE_FLAGS[flag]:
            if i + 1 >= len(words):
                return None
            value = words[i + 1]
            if flag == "--image" and value != "-":
                return None
            if flag == "--source" and not (0 < len(value) <= 64):
                return None
            i += 2
        else:
            i += 1
    return words


def main(argv: Optional[list[str]] = None, stdin: Optional[bytes] = None,
         client: Optional[httpx.Client] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["gate"]:
        allowed = gate_argv(os.environ.get("SSH_ORIGINAL_COMMAND"))
        if allowed is None:
            print("zhiji-inbox: this key may only run `zhiji-inbox add ...` or `zhiji-inbox status`", file=sys.stderr)
            return 1
        argv = allowed
    ap = argparse.ArgumentParser(prog="zhiji-inbox", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    add = sub.add_parser("add", help="store text (stdin) or an image for the Mac to pick up")
    add.add_argument("--source", default="iPhone", help="where it came from, shown as the source app (default iPhone)")
    add.add_argument("--image", help="image file, or - for a base64/raw image on stdin")
    add.add_argument("--text", help="text (default: read stdin)")
    add.add_argument("--json", action="store_true", help="print the server reply as JSON")
    sub.add_parser("status", help="how many shares are waiting for the Mac")
    args = ap.parse_args(argv)

    if client is None:
        socket_path, token_path = _paths()
        if not socket_path.exists():
            print(f"zhiji-inbox: organizer socket not found ({socket_path}); is the organizer running?",
                  file=sys.stderr)
            return 2
        client = _client(socket_path, token_path)

    try:
        if args.cmd == "status":
            reply = client.get("/v1/health")
            reply.raise_for_status()
            print(f"等待 Mac 取走：{reply.json().get('inbox_pending', 0)} 条")
            return 0
        raw_stdin = stdin if stdin is not None else (sys.stdin.buffer.read() if not sys.stdin.isatty() else b"")
        image = _read_image(args.image, raw_stdin) if args.image else None
        text = args.text if args.text is not None else (raw_stdin.decode("utf-8", "replace") if not image else None)
        if image is None and not (text or "").strip():
            print("zhiji-inbox: nothing to add (empty text)", file=sys.stderr)
            return 1
        if text is not None and len(text) > MAX_TEXT_CHARS:
            print(f"zhiji-inbox: text longer than {MAX_TEXT_CHARS} characters", file=sys.stderr)
            return 1
        reply = client.post("/v1/inbox", json=build_entry(args.source, text, image))
    except httpx.HTTPError as exc:
        print(f"zhiji-inbox: cannot reach the organizer: {exc}", file=sys.stderr)
        return 2
    if reply.status_code != 200:
        print(f"zhiji-inbox: rejected ({reply.status_code}): {reply.text[:300]}", file=sys.stderr)
        return 1
    body = reply.json()
    if args.json:
        print(json.dumps(body, ensure_ascii=False))
    else:
        print("已收进织机（等 Mac 取走后整理）" + ("，重复提交已忽略" if body.get("duplicate") else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
