"""File parsing for the file-read skill (kind "file" items).

parse_file(data, filename, mime) runs organizer/fileparse/worker.py in a child process with resource
limits and returns its JSON result (see worker.py). The organizer never parses user files in its own
process: a parser crash, a decompression bomb or a pathological file costs one child process, not the
service.

Limits (Linux; on macOS RLIMIT_AS is not enforced and the wall-clock timeout is the backstop):
  address space 3 GiB, CPU 60 s, wall clock 90 s, files written 0 bytes, 64 open files, no core dumps,
  empty environment, cwd "/", socket API disabled inside the child.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path
from typing import Optional

SPARK_DIR = str(Path(__file__).resolve().parents[2])   # .../spark (contains the organizer package)

MEM_LIMIT = 3 * 1024 ** 3
CPU_LIMIT_S = 60
WALL_LIMIT_S = 90
# The child sets its own limits first thing (no preexec_fn: the organizer is multi-threaded).
BOOT = """
import resource, sys
for res, value in ((resource.RLIMIT_AS, {mem}), (resource.RLIMIT_CPU, {cpu}), (resource.RLIMIT_FSIZE, 0),
                   (resource.RLIMIT_NOFILE, 64), (resource.RLIMIT_CORE, 0)):
    try:
        resource.setrlimit(res, (value, value))
    except (ValueError, OSError):
        pass  # e.g. RLIMIT_AS on macOS
sys.path.insert(0, {root!r})
from organizer.fileparse.worker import main
raise SystemExit(main())
"""


def failure(code: str, note: str) -> dict:
    return {"type": "", "text": "", "title": "", "counts": {}, "attachments": [], "fields": [], "error": code,
            "fmt": "", "notes": [note], "images": []}


def parse_file(data: bytes, filename: str, mime: str = "", *, mem: int = MEM_LIMIT, cpu: int = CPU_LIMIT_S,
               wall: float = WALL_LIMIT_S) -> dict:
    """Parse one file in the sandboxed child. Always returns a result dict (error set on failure);
    image parts come back as raw bytes under images[i]["data"]."""
    header = json.dumps({"filename": filename, "mime": mime}).encode("utf-8")
    payload = len(header).to_bytes(4, "big") + header + data
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "HOME": "/nonexistent",
           "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8", "OMP_NUM_THREADS": "1"}
    try:
        proc = subprocess.run([sys.executable, "-I", "-c", BOOT.format(mem=mem, cpu=cpu, root=SPARK_DIR)],
                              input=payload, capture_output=True, timeout=wall, env=env, cwd="/",
                              start_new_session=True)
    except subprocess.TimeoutExpired:
        return failure("too_large", f"解析超过 {int(wall)} 秒，已停止")
    if proc.returncode != 0:
        # Killed by RLIMIT_CPU (SIGXCPU), out of address space (MemoryError at import / abort) or a crash.
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
        oom = "MemoryError" in tail[0] or "Cannot allocate memory" in tail[0]
        code = "too_large" if proc.returncode < 0 or oom else "corrupt"
        return failure(code, f"解析进程退出（{proc.returncode}）：{tail[0][:160]}")
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        return failure("corrupt", "解析结果无法读取")
    for im in out.get("images") or []:
        im["data"] = base64.b64decode(im.pop("b64"))
    return out


def parse_inline(data: bytes, filename: str, mime: str = "") -> dict:
    """The same parse in this process, without limits (tests and debugging only)."""
    from .core import Budget
    from .dispatch import parse_bytes
    budget = Budget()
    out = parse_bytes(data, filename, mime, budget, 0).to_dict()
    out["notes"] = budget.notes
    out["images"] = [dict(im) for im in budget.images]
    return out


def available() -> Optional[str]:
    """None when every parser library is importable, else the missing one (for /v1/health)."""
    import importlib.util
    for mod in ("defusedxml", "openpyxl", "xlrd", "pypdfium2", "PIL", "olefile"):
        if importlib.util.find_spec(mod) is None:  # located, not imported: nothing is loaded into the service
            return mod
    return None
