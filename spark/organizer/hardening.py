"""Process hardening at start (privacy review finding F10).

While the store is unlocked this process holds the library key, the derived keys and decrypted text. A native
crash (SQLCipher, Pillow, pypdfium2) would otherwise hand a core dump with all of it to the system's crash
collector (on Ubuntu, apport keeps the full core in /var/crash whatever the core limit), and a process of the
same account could read its memory through /proc/<pid>/mem. So the organizer makes itself non-dumpable
(PR_SET_DUMPABLE = 0: no core dump, no ptrace or /proc/<pid>/mem access by other processes of the account)
and sets a hard core-file limit of 0. The parser child (organizer/fileparse) already does the same.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import resource
import sys

PR_SET_DUMPABLE = 4
PR_GET_DUMPABLE = 3


def _libc():
    name = ctypes.util.find_library("c")
    return ctypes.CDLL(name, use_errno=True) if name else None


def harden_process() -> dict:
    """No core dumps, not dumpable. Returns what was applied (for the start log and tests)."""
    applied = {"core_limit": False, "dumpable_off": False}
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        applied["core_limit"] = True
    except (ValueError, OSError):
        pass
    if sys.platform.startswith("linux"):
        libc = _libc()
        if libc is not None and libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0:
            applied["dumpable_off"] = libc.prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) == 0
    return applied
