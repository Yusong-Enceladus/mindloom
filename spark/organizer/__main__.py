"""python -m organizer  — serve the organizer on a private Unix socket.

The socket is ORGANIZER_UDS, default <ORGANIZER_DATA_DIR>/organizer.sock. It must live in a
directory owned by this user with no group/other access (ctl.sh keeps the data directory at 0700),
so only this user can hold the endpoint. The Mac forwards to it (ssh -L 127.0.0.1:<random>:<socket>)
and the local tools (ctl.sh, ops/spark_demo.sh, eval/smoke_api.py --uds, recall.py --uds) talk to
it directly.

A loopback TCP listener on ORGANIZER_HOST:ORGANIZER_PORT (default 127.0.0.1:8765) is served only
with ORGANIZER_TCP=1. A TCP port can be taken by any local user while the organizer is down; a
client that sends the link token there hands it to that user, who can then read the state once the
organizer is back. So nothing in this repository sends the token over TCP by default.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import stat
import sys
from pathlib import Path
from typing import Iterator, Optional

import uvicorn

from .api import create_app
from .config import Settings
from .hardening import harden_process


class UnsafeSocketPath(RuntimeError):
    pass


def check_private_socket_dir(socket_path: Path) -> None:
    """The socket's directory must be a real directory owned by us with mode 0700 (no group/other)."""
    if not socket_path.is_absolute():
        raise UnsafeSocketPath(f"{socket_path}: the socket path must be absolute")
    if len(os.fsencode(socket_path)) > 100:
        raise UnsafeSocketPath(f"{socket_path}: too long for a Unix socket path")
    parent = socket_path.parent
    st = os.lstat(parent)
    if not stat.S_ISDIR(st.st_mode):
        raise UnsafeSocketPath(f"{parent} is not a directory")
    if st.st_uid != os.getuid():
        raise UnsafeSocketPath(f"{parent} is not owned by this user")
    if st.st_mode & 0o077:
        raise UnsafeSocketPath(f"{parent} is accessible to other users; chmod 700 it")
    if socket_path.exists() or socket_path.is_symlink():
        existing = os.lstat(socket_path)
        if not stat.S_ISSOCK(existing.st_mode):
            raise UnsafeSocketPath(f"{socket_path} exists and is not a socket")


class _NoSignalServer(uvicorn.Server):
    """A second listener for the same app: the primary server owns signal handling."""

    @contextlib.contextmanager
    def capture_signals(self) -> Iterator[None]:
        yield


def build_servers(app, uds: Path, tcp: Optional[tuple[str, int]] = None) -> list[uvicorn.Server]:
    """The Unix socket server (it owns signal handling and the app lifespan), plus a loopback TCP
    server only when `tcp` is given (explicit opt-in)."""
    servers = [uvicorn.Server(uvicorn.Config(app, uds=str(uds), access_log=False, log_level="info"))]
    if tcp is not None:
        host, port = tcp
        # lifespan off: the primary server already starts and stops the worker.
        servers.append(_NoSignalServer(uvicorn.Config(app, host=host, port=port, access_log=False,
                                                      log_level="info", lifespan="off")))
    return servers


async def run_servers(servers: list[uvicorn.Server], uds: Optional[Path]) -> None:
    """Serve until any server stops (the primary one handles SIGINT/SIGTERM), then stop all."""
    tasks = [asyncio.create_task(s.serve()) for s in servers]
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for s in servers:
        s.should_exit = True
    await asyncio.gather(*tasks, return_exceptions=True)
    if uds is not None:
        with contextlib.suppress(FileNotFoundError):
            if stat.S_ISSOCK(os.lstat(uds).st_mode):
                os.unlink(uds)


def main() -> int:
    # Before anything holds a key: no core dumps, not dumpable (privacy review F10; organizer/hardening.py).
    hardened = harden_process()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("organizer").info("process hardening: %s", hardened)
    settings = Settings()
    tcp: Optional[tuple[str, int]] = None
    if settings.tcp:
        if settings.host not in ("127.0.0.1", "::1", "localhost"):
            print(f"refusing to bind {settings.host}: the organizer is loopback-only (use an SSH tunnel)",
                  file=sys.stderr)
            return 2
        tcp = (settings.host, settings.port)
    uds = settings.socket_path
    try:
        check_private_socket_dir(uds)
    except (UnsafeSocketPath, OSError) as exc:
        print(f"refusing to serve the Unix socket: {exc}", file=sys.stderr)
        return 2
    app = create_app(settings)
    # access_log off: request lines are harmless, but keep logs free of anything item-derived.
    asyncio.run(run_servers(build_servers(app, uds, tcp), uds))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
