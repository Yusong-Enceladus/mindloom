"""The gate: what a member's or an invitee's SSH key may run on this Spark (v8 contract B1; docs/INFRA.md).

Both are forced commands written by organizer/access_keys.py; sshd runs them whatever the client asked for:

    zhiji-inbox bridge <access id>     a member Mac's key
    zhiji-inbox enroll <ticket id>     an invite's one-time key

**bridge** is an HTTP/1.1 bridge on stdin/stdout to the organizer's private Unix socket, and nothing else: no
shell, no port forwards (the line's `restrict`), no other socket (the socket path comes from this instance's
wrapper, never from the client). The member Mac runs `ssh -T <spark> bridge` and speaks HTTP over the session's
stdin/stdout (keep-alive; one request at a time). The bridge parses every request with h11 (a strict HTTP/1.1
state machine, so a request cannot be smuggled past it) and forwards it only when

  * the method is GET, POST, PUT or DELETE and the path is a member route: /v1/spaces…, /v1/orgs…, /v1/access/…,
    /v1/infra/… (everything else, the personal store, the inbox and the key routes, is refused here and again by
    the organizer);
  * it carries this key's own member credential (`Authorization: Bearer mlacc1.<this access id>.…`); the owner's
    link token or another member's credential is refused here.

It then adds the gate stamp (X-Mindloom-Gate, an HMAC under <data>/gate_key, organizer/access.py), which the
organizer requires next to a member credential, and streams the response back (large bodies, e.g. a space
backup, are streamed both ways). An idle session ends after 10 minutes.

**enroll** reads one JSON request on stdin (organizer/access.enroll_request: the invitee's own SSH public key, its
member id and device keys, signed by the device, and the ticket secret), relays it to the organizer with the
ticket's stamp and prints the organizer's one-line JSON answer: {"ok":true,"access_id","credential",…}. The
ticket's line is replaced by the member's line, so the invite key never works again.

Exit status: 0 = served / enrolled, 1 = refused, 2 = the organizer is unreachable.
"""

from __future__ import annotations

import json
import os
import re
import select
import sys
from pathlib import Path
from typing import Iterator, Optional

import h11
import httpx

from .access import ENROLL_MAX_BYTES, read_gate_key, gate_stamp

MEMBER_PREFIXES = ("/v1/spaces", "/v1/orgs", "/v1/access/", "/v1/infra/")
METHODS = {b"GET", b"POST", b"PUT", b"DELETE"}
PASS_HEADERS = {b"authorization", b"content-type", b"content-length", b"accept", b"x-mindloom-device",
                b"x-mindloom-date", b"x-mindloom-nonce", b"x-mindloom-signature", b"x-mindloom-backup-key",
                b"x-mindloom-restore"}
RESPONSE_HEADERS = {"content-type", "content-length", "www-authenticate", "retry-after", "x-mindloom-backup"}
# headers a request may carry only once (V8R-05): who is asking, which device signs, the gate stamp
SINGLE_HEADERS = (b"authorization", b"x-mindloom-gate", b"x-mindloom-device", b"x-mindloom-date", b"x-mindloom-nonce",
                  b"x-mindloom-signature", b"x-mindloom-backup-key", b"x-mindloom-restore", b"content-type",
                  b"content-length", b"transfer-encoding", b"host")
IDLE_S = 600.0
READ = 65536
_TARGET = re.compile(rb"/v1/[A-Za-z0-9._~\-/%]*(\?[A-Za-z0-9._~\-=&%+,]*)?\Z")


def member_path(path: str) -> bool:
    """The organizer side of the same rule (api.py checks it again for every member request)."""
    p = path.rstrip("/") or "/"
    return any(p.startswith(pre) if pre.endswith("/") else (p == pre or p.startswith(pre + "/"))
               for pre in MEMBER_PREFIXES) and ".." not in p and "//" not in p


def _paths() -> tuple[Path, Path]:
    data_dir = Path(os.environ.get("ORGANIZER_DATA_DIR", str(Path.home() / "hack" / "organizer-data")))
    uds = os.environ.get("ORGANIZER_UDS", "")
    return data_dir, (Path(uds) if uds else data_dir / "organizer.sock")


def _client(socket_path: Path, timeout: float = 600.0) -> httpx.Client:
    return httpx.Client(transport=httpx.HTTPTransport(uds=str(socket_path)), base_url="http://organizer",
                        timeout=httpx.Timeout(timeout, connect=10.0), trust_env=False)


class _Stdio:
    """Blocking reads from fd 0 with an idle timeout; writes to fd 1."""

    def __init__(self, rfd: int = 0, wfd: int = 1, idle_s: float = IDLE_S):
        self.rfd, self.wfd, self.idle_s = rfd, wfd, idle_s

    def read(self, waiting: bool) -> bytes:
        if waiting:
            ready, _, _ = select.select([self.rfd], [], [], self.idle_s)
            if not ready:
                return b""  # idle: treated like the client hanging up
        try:
            return os.read(self.rfd, READ)
        except OSError:
            return b""

    def write(self, data: Optional[bytes]) -> None:
        view = memoryview(data or b"")
        while view:
            n = os.write(self.wfd, view)
            view = view[n:]


class Bridge:
    def __init__(self, access_id: str, *, gate_key: str, client: httpx.Client, io: Optional[_Stdio] = None):
        self.access_id = access_id
        self.stamp = gate_stamp(gate_key, "member", access_id)
        self.client = client
        self.io = io or _Stdio()
        self.conn = h11.Connection(h11.SERVER, max_incomplete_event_size=64 * 1024)

    def _next(self, waiting: bool = False):
        while True:
            event = self.conn.next_event()
            if event is h11.NEED_DATA:
                data = self.io.read(waiting)
                self.conn.receive_data(data)
                if not data:
                    waiting = False
                continue
            return event

    def _send(self, event) -> None:
        self.io.write(self.conn.send(event))

    def _refuse(self, status: int, code: str, detail: str = "", close: bool = True) -> None:
        body = json.dumps({"error": code, **({"detail": detail} if detail else {})}).encode()
        headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
        if close:
            headers.append((b"connection", b"close"))
        self._send(h11.Response(status_code=status, headers=headers))
        self._send(h11.Data(data=body))
        self._send(h11.EndOfMessage())

    def _drain(self, limit: int = 1024 * 1024) -> bool:
        """Read and drop a refused request's body (at most `limit` bytes), so the session can go on."""
        n = 0
        while True:
            event = self._next()
            if isinstance(event, h11.EndOfMessage):
                return True
            if not isinstance(event, h11.Data):
                return False
            n += len(event.data)
            if n > limit:
                return False

    def _body(self) -> Iterator[bytes]:
        while True:
            event = self._next()
            if isinstance(event, h11.Data):
                yield bytes(event.data)
            elif isinstance(event, h11.EndOfMessage):
                return
            else:
                raise h11.RemoteProtocolError("unexpected event in a request body")

    def _check(self, req: h11.Request) -> Optional[tuple[int, str, str]]:
        if req.method not in METHODS:
            return 405, "gate_refused", "method not allowed"
        if _TARGET.match(req.target) is None:
            return 400, "bad_request", "origin-form target under /v1/ only"
        path = req.target.split(b"?", 1)[0].decode("ascii")
        if not member_path(path):
            return 403, "gate_refused", "this key reaches only the member routes"
        names = [k for k, _ in req.headers]
        if b"transfer-encoding" in names and b"content-length" in names:
            # h11 would let Transfer-Encoding win; refused outright so no length ever disagrees with the body.
            return 400, "bad_request", "Transfer-Encoding and Content-Length together"
        # One of each header that carries who is asking (review finding V8R-05): the gate checks exactly the value
        # it forwards; a second Authorization (e.g. the owner's link token before the member's credential) is
        # refused, not passed on for the organizer to read the other one.
        for name in SINGLE_HEADERS:
            if names.count(name) > 1:
                return 400, "bad_request", f"{name.decode()} more than once"
        auth = dict(req.headers).get(b"authorization", b"").decode("latin-1").strip()
        scheme, _, value = auth.partition(" ")
        if scheme.lower() != "bearer" or not value.strip().startswith(f"mlacc1.{self.access_id}."):
            return 403, "gate_refused", "send this Mac's own member credential"
        return None

    @staticmethod
    def _credential(req: h11.Request) -> bytes:
        """The member credential the gate checked, as the only Authorization header it forwards."""
        auth = dict(req.headers).get(b"authorization", b"").decode("latin-1").strip()
        return b"Bearer " + auth.partition(" ")[2].strip().encode("latin-1")

    def serve_one(self) -> bool:
        """One request/response cycle. False: the session is over."""
        event = self._next(waiting=True)
        if isinstance(event, h11.ConnectionClosed) or event is h11.PAUSED:
            return False
        if not isinstance(event, h11.Request):
            return False
        refusal = self._check(event)
        if refusal is not None:
            # A well-framed request refused by policy: its body is dropped and the session goes on; anything
            # malformed (400) or with a large body closes it.
            keep = refusal[0] != 400 and self._drain()
            self._refuse(*refusal, close=not keep)
            if not keep:
                return False
            self.conn.start_next_cycle()
            return True
        # The body is re-framed: h11 decoded it (Content-Length or chunked) and it goes upstream with the same
        # Content-Length h11 enforced, or chunked; a client's length header is never passed on by itself.
        headers = [(k, v) for k, v in event.headers if k in PASS_HEADERS and k not in (b"content-length",
                                                                                        b"authorization")]
        headers.append((b"authorization", self._credential(event)))
        lengths = [v for k, v in event.headers if k == b"content-length"]
        chunked = any(k == b"transfer-encoding" for k, _ in event.headers)
        has_length = bool(lengths) and not chunked
        if has_length:
            headers.append((b"content-length", lengths[0]))
        headers.append((b"x-mindloom-gate", self.stamp.encode("ascii")))
        body = self._body()
        try:
            request = self.client.build_request(event.method.decode(), event.target.decode("ascii"),
                                                headers=[(k.decode(), v.decode("latin-1")) for k, v in headers],
                                                content=body if (has_length or event.method in (b"POST", b"PUT"))
                                                else None)
            if not (has_length or event.method in (b"POST", b"PUT")):
                for _ in body:  # a GET/DELETE body (none expected): drained, not forwarded
                    pass
            response = self.client.send(request, stream=True)
        except httpx.HTTPError:
            for _ in body:
                pass
            self._refuse(503, "unavailable", "the organizer is not reachable")
            return False
        try:
            out = [(k.encode("latin-1"), v.encode("latin-1")) for k, v in response.headers.items()
                   if k.lower() in RESPONSE_HEADERS]
            self._send(h11.Response(status_code=response.status_code, headers=out))
            for chunk in response.iter_raw(READ):
                if chunk:
                    self._send(h11.Data(data=chunk))
            self._send(h11.EndOfMessage())
        finally:
            response.close()
        if self.conn.our_state is h11.MUST_CLOSE or self.conn.their_state is h11.MUST_CLOSE:
            return False
        try:
            self.conn.start_next_cycle()
        except h11.LocalProtocolError:
            return False
        return True

    def run(self) -> int:
        try:
            while self.serve_one():
                pass
        except h11.RemoteProtocolError:
            try:
                self._refuse(400, "bad_request", "malformed HTTP")
            except h11.LocalProtocolError:
                pass
            return 1
        except (BrokenPipeError, ConnectionResetError):
            return 0
        return 0


def _requested(expected: str) -> bool:
    """A forced command still sees what the client asked for: only nothing or the command's own name passes,
    so `ssh <spark> cat …` with a member key is refused instead of silently opening a bridge."""
    asked = (os.environ.get("SSH_ORIGINAL_COMMAND") or "").strip()
    return asked in ("", expected) or asked == f"zhiji-inbox {expected}"


def bridge_main(access_id: str) -> int:
    if not _requested("bridge"):
        print("zhiji-inbox: this key only opens the member bridge (ssh -T <spark> bridge)", file=sys.stderr)
        return 1
    data_dir, sock = _paths()
    if not sock.exists():
        print(f"zhiji-inbox: organizer socket not found ({sock})", file=sys.stderr)
        return 2
    with _client(sock) as client:
        return Bridge(access_id, gate_key=read_gate_key(data_dir), client=client).run()


def enroll_main(ticket_id: str, stdin: Optional[bytes] = None, client: Optional[httpx.Client] = None) -> int:
    def fail(code: str, status: int = 1) -> int:
        print(json.dumps({"ok": False, "error": code}))
        return status

    if not _requested("enroll"):
        return fail("not_allowed")
    raw = stdin if stdin is not None else sys.stdin.buffer.read(ENROLL_MAX_BYTES + 1)
    if len(raw) > ENROLL_MAX_BYTES:
        return fail("too_large")
    try:
        wire = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return fail("bad_request")
    data_dir, sock = _paths()
    own = client is None
    if own:
        if not sock.exists():
            return fail("unavailable", 2)
        client = _client(sock, 60.0)
    try:
        r = client.post(f"/v1/access/enroll/{ticket_id}", json=wire,
                        headers={"X-Mindloom-Gate": gate_stamp(read_gate_key(data_dir), "enroll", ticket_id)})
    except httpx.HTTPError:
        return fail("unavailable", 2)
    finally:
        if own:
            client.close()
    try:
        body = r.json()
    except ValueError:
        body = {"ok": False, "error": "unavailable"}
    if r.status_code != 200:
        body = {"ok": False, **{k: v for k, v in body.items() if k in ("error", "detail", "ticket_status")}}
    print(json.dumps(body, ensure_ascii=False))
    return 0 if r.status_code == 200 else 1


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("bridge", "enroll") or UUID.match(argv[1]) is None:
        print("usage: zhiji-inbox bridge <access id> | enroll <ticket id> (forced commands)", file=sys.stderr)
        return 1
    return bridge_main(argv[1]) if argv[0] == "bridge" else enroll_main(argv[1])
