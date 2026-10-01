"""v8 B1 against a real OpenSSH sshd on 127.0.0.1 (like the phone tests): an invite key redeems its ticket once, a
member key opens only the HTTP bridge to the organizer (member routes, its own credential), nothing else gets
through, and unpairing leaves authorized_keys byte-identical. Synthetic keys and data only.
"""

from __future__ import annotations

import getpass
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import h11
import httpx
import pytest

from organizer import space_member as sm
from organizer.access import enroll_request, ticket_hash
from organizer.api import create_app
from organizer.spaces import Spaces

from spacekit import Mac, new_id
from test_phone_link import FOREIGN, SPARK, SSHD, sshd_binary


class Reply:
    def __init__(self, status: int, body: bytes):
        self.status_code = status
        self.content = body
        self.text = body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.content)


class BridgeSession:
    """The member Mac's side of `ssh -T <spark> bridge`: HTTP/1.1 keep-alive over the session's stdin/stdout."""

    def __init__(self, argv: list[str], credential: str):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.credential = credential
        self.conn = h11.Connection(h11.CLIENT)

    def request(self, method: str, target: str, content: bytes | None = None, headers: dict | None = None,
                json_body=None) -> Reply:
        if json_body is not None:
            content = json.dumps(json_body).encode()
            headers = {**(headers or {}), "Content-Type": "application/json"}
        hdrs = [("Host", "organizer"), ("Authorization", f"Bearer {self.credential}")]
        hdrs += list((headers or {}).items())
        if content is not None:
            hdrs.append(("Content-Length", str(len(content))))
        out = self.conn.send(h11.Request(method=method, target=target, headers=hdrs))
        if content:
            out += self.conn.send(h11.Data(data=content))
        out += self.conn.send(h11.EndOfMessage())
        self.proc.stdin.write(out)
        self.proc.stdin.flush()
        status, body = None, bytearray()
        while True:
            ev = self.conn.next_event()
            if ev is h11.NEED_DATA:
                data = self.proc.stdout.read1(65536)
                self.conn.receive_data(data)
                if not data:
                    raise ConnectionError("bridge closed: " + self.proc.stderr.read().decode(errors="replace")[-300:])
                continue
            if isinstance(ev, h11.Response):
                status = ev.status_code
            elif isinstance(ev, h11.Data):
                body += ev.data
            elif isinstance(ev, h11.EndOfMessage):
                break
            elif isinstance(ev, h11.ConnectionClosed):
                raise ConnectionError("closed")
        if self.conn.our_state is h11.MUST_CLOSE or self.conn.their_state is h11.MUST_CLOSE:
            self.conn = h11.Connection(h11.CLIENT)  # the gate closed: a new session would be needed
        else:
            self.conn.start_next_cycle()
        return Reply(status, bytes(body))

    def get(self, target: str, **kw) -> Reply:
        return self.request("GET", target, **kw)

    def post(self, target: str, json=None, **kw) -> Reply:
        return self.request("POST", target, json_body=json, **kw)

    def close(self) -> int:
        self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=20)
        finally:
            self.proc.stdout.close()
            self.proc.stderr.close()


@pytest.fixture
def rig(tmp_path, settings, org):
    if sshd_binary() is None or shutil.which("ssh") is None or shutil.which("ssh-keygen") is None:
        pytest.skip("OpenSSH (sshd, ssh, ssh-keygen) is not installed")
    import uvicorn

    root = Path(tempfile.mkdtemp(prefix="za"))  # short: Unix socket paths are limited
    home = root / "home"
    (home / ".ssh").mkdir(parents=True)
    ak = root / "spark_ak"
    ak.write_bytes(FOREIGN)
    sock = root / "o.sock"
    gate = root / "zhiji-inbox"
    gate.write_text("#!/bin/sh\n"
                    f"export HOME='{home}' ORGANIZER_VENV='{sys.prefix}' ORGANIZER_DATA_DIR='{settings.data_dir}'"
                    f" ORGANIZER_UDS='{sock}' ZHIJI_INBOX_GATE='{gate}'\n"
                    f"exec '{SPARK / 'zhiji-inbox'}' \"$@\"\n")
    gate.chmod(0o755)
    settings.authorized_keys = ak
    settings.gate_path = str(gate)
    spaces = Spaces(settings.data_dir, host_keys=lambda: [])
    app = create_app(settings, organizer=org, spaces=spaces)
    server = uvicorn.Server(uvicorn.Config(app, uds=str(sock), log_level="warning", lifespan="on"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(200):
        if server.started:
            break
        time.sleep(0.02)
    for name in ("invite", "member", "stranger"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", str(root / name)], check=True)
    sshd = SSHD(root, "spark", ak)
    (root / "known_hosts").write_text(sshd.known_hosts_line())
    owner = httpx.Client(transport=httpx.HTTPTransport(uds=str(sock)), base_url="http://organizer",
                         headers={"Authorization": f"Bearer {app.state.link_token}"}, timeout=60, trust_env=False)
    rig = {"root": root, "ak": ak, "app": app, "port": sshd.port, "owner": owner, "sock": sock}
    yield rig
    owner.close()
    sshd.stop()
    server.should_exit = True
    thread.join(timeout=10)
    shutil.rmtree(root, ignore_errors=True)


def ssh_argv(rig, key: str, *args: str, extra: tuple = ()) -> list[str]:
    return ["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o",
            "IdentityAgent=none", "-o", f"UserKnownHostsFile={rig['root'] / 'known_hosts'}", "-o",
            "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "LogLevel=ERROR",
            "-i", str(rig["root"] / key), "-p", str(rig["port"]), *extra, f"{getpass.getuser()}@127.0.0.1", *args]


def ssh(rig, key: str, *args: str, stdin: bytes = b"", timeout: float = 30, extra: tuple = ()):
    argv = ssh_argv(rig, key, *args, extra=extra)
    try:
        return subprocess.run(argv, input=stdin, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(argv, "timeout", exc.stdout or b"", exc.stderr or b"")


def test_invite_enroll_bridge_and_unpair_through_a_real_sshd(rig):
    root, ak = rig["root"], rig["ak"]
    original = ak.read_bytes()
    # 1. the admin's Mac (here the owner) registers a ticket with the invite key's public half
    secret = secrets.token_bytes(32)
    ticket_id = new_id()
    expires = datetime.fromtimestamp(time.time() + 86400, timezone.utc).isoformat()
    r = rig["owner"].post("/v1/access/tickets", json={
        "ticket_id": ticket_id, "kind": "member", "ssh_key": (root / "invite.pub").read_text().strip(),
        "secret_hash": ticket_hash(secret), "expires_at": expires})
    assert r.status_code == 200, r.text
    # the invite key cannot do anything but enroll: a shell, another command, a tunnel
    assert ssh(rig, "invite", "cat /etc/hosts").returncode == 1
    assert ssh(rig, "invite", timeout=10, extra=("-W", "127.0.0.1:22")).returncode != 0
    # 2. the invitee's Mac redeems it with its own new key, device keys and member id
    device, member_id = sm.Device(), new_id()
    wire = enroll_request(device, ticket_id, secret, (root / "member.pub").read_text().strip(), member_id)
    r = ssh(rig, "invite", "enroll", stdin=json.dumps(wire).encode())
    assert r.returncode == 0, r.stdout + r.stderr
    out = json.loads(r.stdout.decode().strip().splitlines()[-1])
    assert out["ok"] is True and out["member_id"] == member_id and out["command"] == "bridge"
    # the invite key is dead now (its line was swapped for the member's)
    r = ssh(rig, "invite", "enroll", stdin=json.dumps(wire).encode())
    assert r.returncode == 255 and b"denied" in r.stderr.lower()
    # 3. the member's bridge: member routes with its own credential, keep-alive
    session = BridgeSession(ssh_argv(rig, "member", "bridge"), out["credential"])
    try:
        me = session.get("/v1/access/me")
        assert me.status_code == 200 and me.json()["access"]["member_id"] == member_id
        assert session.get("/v1/state").status_code == 403               # the personal store: not for members
        mac = Mac(session, time.time)
        mac.device, mac.member_id = device, member_id
        space_id = mac.create_space()
        shared = mac.share(space_id, "合成素材：B203 真机实验周四改到下午", original=os.urandom(3 * 1024 * 1024))
        assert shared["result"]["ok"], shared
        assert mac.read_items(space_id)[shared["item_id"]]["text"].startswith("合成素材")
        blob = mac.get(f"/v1/spaces/{space_id}/blobs/{shared['blobs'][0]['blob_id']}")
        assert blob.status_code == 200 and len(blob.content) > 3 * 1024 * 1024    # streamed back through the bridge
    finally:
        assert session.close() == 0
    # another command or a tunnel with the member key: refused
    r = ssh(rig, "member", "cat /etc/hosts")
    assert r.returncode == 1 and b"hosts" not in r.stdout
    assert ssh(rig, "member", timeout=10, extra=("-W", "127.0.0.1:22")).returncode != 0
    # a local forward straight to the organizer's socket: sshd refuses the channel, nothing comes back
    from test_phone_link import free_port
    port = free_port()
    fwd = subprocess.Popen(ssh_argv(rig, "member", extra=("-N", "-L", f"127.0.0.1:{port}:{rig['sock']}")),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        got = b""
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=5) as c:
                    c.sendall(b"GET /v1/health HTTP/1.1\r\nHost: o\r\nConnection: close\r\n\r\n")
                    c.settimeout(5)
                    try:
                        got = c.recv(4096)
                    except (socket.timeout, ConnectionResetError):
                        got = b""
                break
            except OSError:
                time.sleep(0.05)
        assert b"HTTP/1.1" not in got
    finally:
        fwd.terminate()
        fwd.wait(timeout=10)
    # the owner's token through the member's bridge: the gate refuses it
    s2 = BridgeSession(ssh_argv(rig, "member", "bridge"), rig["app"].state.link_token)
    try:
        assert s2.get("/v1/access/me").status_code == 403
    finally:
        s2.close()
    # a key that was never installed
    assert ssh(rig, "stranger", "bridge").returncode == 255
    # 4. unpair: the line goes, the file is byte-identical to before the invite, the key is refused, and an open
    #    session's next request is refused too
    s3 = BridgeSession(ssh_argv(rig, "member", "bridge"), out["credential"])
    try:
        assert s3.get("/v1/access/me").status_code == 200
        r = rig["owner"].delete(f"/v1/access/members/{out['access_id']}")
        assert r.status_code == 200 and r.json()["removed"] == 1
        assert ak.read_bytes() == original
        assert s3.get("/v1/access/me").status_code == 401
    finally:
        s3.close()
    r = ssh(rig, "member", "bridge")
    assert r.returncode == 255 and b"denied" in r.stderr.lower()
