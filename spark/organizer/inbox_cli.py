"""zhiji-inbox — put something from the phone into the organizer's inbox on this Spark.

The 织机 iPhone app (docs/PHONE.md) seals every entry to the Mac's key on the phone and sends it over SSH,
with the sealed string on stdin. The Spark keeps it as is and cannot open it:

    zhiji-inbox add --sealed --id <entry id> --json    # an mlseal1 string on stdin (organizer/sealed.py)
    zhiji-inbox status                                  # how many entries wait for the Mac

Only sealed entries are accepted. The plaintext path of the retired iOS Shortcut ("分享到织机", `add --source
…` / `--image -` / text on stdin) is refused with `not_sealed`: it could not seal, so its shares waited here
in plaintext until the Mac took them (privacy review F9).

The phone's SSH key runs only the gate (a forced command, organizer/phone_keys.py):

    zhiji-inbox gate        # runs SSH_ORIGINAL_COMMAND only if it is
                            # `zhiji-inbox add --sealed --id <uuid> [--json]` (flags in any order)
                            # or `zhiji-inbox status`

Admin, run by the Mac over its own SSH to pair and unpair a phone (never allowed through the gate); each
prints one JSON line:

    zhiji-inbox authorize-phone --key-id <id> --pubkey "ssh-ed25519 AAAA… [comment]"   (--pubkey - reads stdin)
    zhiji-inbox revoke-phone --key-id <id>
    zhiji-inbox list-phones

v8 (organizer/gate.py, docs/INFRA.md): the forced commands of teammates' keys, written by organizer/access_keys.py
and never reachable through the phone gate:

    zhiji-inbox bridge <access id>    a member Mac's HTTP bridge to the organizer (member routes only)
    zhiji-inbox enroll <ticket id>    an invite's one-time key: redeem the ticket, get the member line and credential

`add` and `status` talk to the organizer's private Unix socket with the link token, both read from the data
directory (ORGANIZER_DATA_DIR, ORGANIZER_UDS), as the same user that runs the organizer. Nothing is sent
anywhere else: an entry waits on the Spark until the Mac fetches it (GET /v1/inbox) and acks it, then its
content is dropped here. Exit status 0 = stored (or already stored) / done, 1 = rejected / refused,
2 = unreachable / I/O error. With --json, `add` always prints one JSON line: {"ok":true,"id",…} or
{"ok":false,"error":<code>}.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

import httpx

from . import phone_keys, sealed

# stdin bound (bytes read at most): a sealed wire string of the largest size plus a trailing CRLF.
MAX_SEALED_STDIN = sealed.MAX_WIRE_CHARS + 2
MAX_PUBKEY_STDIN = 4096

ADMIN = ("authorize-phone", "revoke-phone", "list-phones")


def _paths() -> tuple[Path, Path]:
    data_dir = Path(os.environ.get("ORGANIZER_DATA_DIR", str(Path.home() / "hack" / "organizer-data")))
    uds = os.environ.get("ORGANIZER_UDS", "")
    return (Path(uds) if uds else data_dir / "organizer.sock"), data_dir / "link_token"


def _client(socket_path: Path, token_path: Path, timeout: float = 30.0) -> httpx.Client:
    headers = {}
    if token_path.exists():
        headers["Authorization"] = "Bearer " + token_path.read_text(encoding="utf-8").strip()
    return httpx.Client(transport=httpx.HTTPTransport(uds=str(socket_path)), base_url="http://organizer",
                        headers=headers, timeout=timeout, trust_env=False)


def _read_stdin(stdin: Optional[bytes], limit: int) -> bytes:
    """At most limit + 1 bytes of stdin (one more than allowed tells "too large" apart without reading an
    unbounded stream into memory)."""
    if stdin is not None:
        return stdin[: limit + 1]
    if sys.stdin is None or sys.stdin.isatty():
        return b""
    return sys.stdin.buffer.read(limit + 1)


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def build_sealed_entry(entry_id: str, wire: str, received_at: Optional[str] = None) -> dict:
    """A sealed entry as the organizer stores it: the id exactly as the phone sent it, the wire string as is,
    and no plaintext metadata (the real source and time are inside the seal)."""
    return {"inbox_id": entry_id, "source": "sealed", "kind": "sealed", "blob": wire,
            "received_at": received_at or _now()}


_GATE_FLAGS = {"--json": 0, "--sealed": 0, "--id": 1}
_UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z")


def gate_argv(original: Optional[str]) -> Optional[list[str]]:
    """For an SSH key restricted with command=".../zhiji-inbox gate": the argv of the command the phone
    asked for, or None if it is anything but `zhiji-inbox add --sealed --id <uuid> [--json]` (flags in any
    order, each at most once) or `zhiji-inbox status`. The sealed string comes on stdin; there are no file
    paths, so the key cannot read files; plaintext adds (--source, --image, --text) and the admin commands
    (authorize-phone, revoke-phone, list-phones) never pass."""
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
    seen: set[str] = set()
    i = 1
    while i < len(words):
        flag = words[i]
        if flag not in _GATE_FLAGS or flag in seen:
            return None
        seen.add(flag)
        if _GATE_FLAGS[flag]:
            if i + 1 >= len(words) or _UUID.match(words[i + 1]) is None:
                return None
            i += 2
        else:
            i += 1
    if not {"--sealed", "--id"} <= seen:
        return None
    return words


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="zhiji-inbox", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    add = sub.add_parser("add", help="store an entry (stdin) for the Mac to pick up")
    add.add_argument("--sealed", action="store_true",
                     help="stdin is an mlseal1 string sealed to the Mac's key (the 织机 iPhone app); required")
    add.add_argument("--id", help="the lowercase UUID the entry was sealed with")
    # The retired plaintext path's flags are still parsed, so an old Shortcut gets a clear refusal (not_sealed).
    add.add_argument("--source", help=argparse.SUPPRESS)
    add.add_argument("--image", help=argparse.SUPPRESS)
    add.add_argument("--text", help=argparse.SUPPRESS)
    add.add_argument("--json", action="store_true", help="print one JSON line")
    sub.add_parser("status", help="how many entries are waiting for the Mac")
    auth = sub.add_parser("authorize-phone", help="let a phone key run only the gate (admin; not via the gate)")
    auth.add_argument("--key-id", required=True)
    auth.add_argument("--pubkey", required=True, help='"ssh-ed25519 AAAA… [comment]", or - to read it from stdin')
    auth.add_argument("--json", action="store_true", help="(always JSON)")
    rev = sub.add_parser("revoke-phone", help="remove a phone key's line (admin; not via the gate)")
    rev.add_argument("--key-id", required=True)
    rev.add_argument("--json", action="store_true", help="(always JSON)")
    lst = sub.add_parser("list-phones", help="the phone keys in authorized_keys (admin; not via the gate)")
    lst.add_argument("--json", action="store_true", help="(always JSON)")
    return ap


def _admin(args: argparse.Namespace, stdin: Optional[bytes]) -> int:
    try:
        if args.cmd == "authorize-phone":
            pubkey = args.pubkey
            if pubkey == "-":
                raw = _read_stdin(stdin, MAX_PUBKEY_STDIN)
                if len(raw) > MAX_PUBKEY_STDIN:
                    raise phone_keys.Refused("bad_pubkey", "the public key on stdin is too long")
                pubkey = raw.decode("ascii", "replace")
            out = phone_keys.authorize(args.key_id, pubkey)
        elif args.cmd == "revoke-phone":
            out = phone_keys.revoke(args.key_id)
        else:
            out = phone_keys.list_phones()
    except phone_keys.Refused as exc:
        print(json.dumps({"ok": False, "error": exc.code}))
        print(f"zhiji-inbox {args.cmd}: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(json.dumps({"ok": False, "error": "io"}))
        print(f"zhiji-inbox {args.cmd}: {exc.strerror or exc}", file=sys.stderr)
        return 2
    print(json.dumps(out, ensure_ascii=False))
    return 0


def main(argv: Optional[list[str]] = None, stdin: Optional[bytes] = None,
         client: Optional[httpx.Client] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] in (["bridge"], ["enroll"]):
        # v8: the forced commands of a member Mac's key and of an invite's one-time key (organizer/gate.py).
        from . import gate
        return gate.main(argv)
    if argv[:1] == ["gate"]:
        original = os.environ.get("SSH_ORIGINAL_COMMAND")
        allowed = gate_argv(original)
        if allowed is None:
            if "--json" in (original or "").split():
                print(json.dumps({"ok": False, "error": "not_allowed"}))
            print("zhiji-inbox: this key may only run `zhiji-inbox add ...` or `zhiji-inbox status`", file=sys.stderr)
            return 1
        argv = allowed
    args = _parser().parse_args(argv)
    if args.cmd in ADMIN:
        return _admin(args, stdin)

    as_json = args.cmd == "add" and args.json

    def fail(code: str, message: str, status: int = 1) -> int:
        if as_json:
            print(json.dumps({"ok": False, "error": code}))
        print(f"zhiji-inbox: {message}", file=sys.stderr)
        return status

    # Check an add before anything is sent (and before the organizer is looked for).
    entry: Optional[dict] = None
    if args.cmd == "add":
        if args.sealed:
            if args.image or args.text is not None or args.source is not None:
                return fail("bad_args", "--sealed takes only --id and --json (the source is inside the seal)")
            if not sealed.is_entry_id(args.id):
                return fail("bad_id", "--sealed needs --id <the lowercase UUID the entry was sealed with>")
            raw = _read_stdin(stdin, MAX_SEALED_STDIN)
            if len(raw) > MAX_SEALED_STDIN:
                return fail("too_large", f"a sealed entry is at most {sealed.MAX_WIRE_CHARS} characters")
            try:
                wire = raw.rstrip(b" \t\r\n").decode("ascii")
            except UnicodeDecodeError:
                return fail("malformed", "a sealed entry is ASCII (mlseal1. + base64url)")
            problem = sealed.wire_problem(wire)
            if problem:
                return fail(problem, f"not an acceptable sealed entry ({problem})")
            entry = build_sealed_entry(args.id, wire)
        else:
            # Nothing of a plaintext share is read, stored or forwarded: the phone app seals every entry.
            return fail("not_sealed", "only sealed entries are accepted (add --sealed --id <uuid>); the plaintext"
                        " phone path (the iOS Shortcut) is retired because it cannot seal")

    if client is None:
        socket_path, token_path = _paths()
        if not socket_path.exists():
            return fail("unavailable", f"organizer socket not found ({socket_path}); is the organizer running?", 2)
        # a large sealed document takes a moment to hand over and store: 30 s plus 2 s per MB
        size_mb = len(entry.get("blob") or "") / 1_000_000 if entry else 0.0
        client = _client(socket_path, token_path, timeout=30.0 + 2.0 * size_mb)

    try:
        if args.cmd == "status":
            reply = client.get("/v1/health")
            reply.raise_for_status()
            print(f"等待 Mac 取走：{reply.json().get('inbox_pending', 0)} 条")
            return 0
        reply = client.post("/v1/inbox", json=entry)
    except httpx.HTTPError as exc:
        return fail("unavailable", f"cannot reach the organizer: {exc}", 2)
    if reply.status_code != 200:
        return fail("rejected", f"rejected ({reply.status_code}): {reply.text[:300]}")
    body = reply.json()
    if as_json:
        print(json.dumps(body, ensure_ascii=False))
    else:
        print("已收进织机（已锁好，只有你的 Mac 能打开）" + ("，重复提交已忽略" if body.get("duplicate") else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
