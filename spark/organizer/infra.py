"""The admin console's view of this Spark (v8 contract B2; docs/INFRA.md): GET /v1/infra/health.

Organizer, model servers, GPU memory and disk, as numbers and states only: no item, matter, name, path of a
user's file, process list or other user's process id ever appears here. Who may call it: the Spark owner (link
token) and, through the gate, a member who administers an organization or a space on this Spark.

On a DGX Spark (GB10) the GPU shares the system memory, and nvidia-smi reports its memory as "[N/A]". The probe
then reports the unified memory from /proc/meminfo (total, available) and the sum of the GPU processes' memory
(nvidia-smi --query-compute-apps; summed, never listed). Each probe has a short timeout and the answer is cached
for a few seconds, so an admin console polling it costs the Spark next to nothing.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlsplit

import httpx

from . import __version__

CACHE_S = 15.0
SIZE_CACHE_S = 120.0
SMI_TIMEOUT_S = 4.0
MODEL_TIMEOUT_S = 3.0
DISK_LOW_FREE = 0.05           # below 5 % free: warning
MEMORY_LOW_MIB = 2048          # less than 2 GiB available: warning
STARTED = time.time()


def _num(value: str) -> Optional[float]:
    value = value.strip()
    try:
        return float(value)
    except ValueError:
        return None  # "[N/A]", "[Not Supported]"


def _meminfo(path: Path = Path("/proc/meminfo")) -> dict:
    out = {}
    try:
        for line in path.read_text().splitlines():
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable"):
                out[key] = int(rest.split()[0]) // 1024  # kB -> MiB
    except (OSError, ValueError, IndexError):
        pass
    return out


def dir_bytes(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def revision(root: Path) -> Optional[str]:
    """The deployed code's revision (an instance's app/REVISION, written at deploy), if any."""
    for p in (root / "REVISION", root.parent / "REVISION"):
        try:
            value = p.read_text(encoding="ascii").strip()
        except (OSError, UnicodeDecodeError):
            continue
        if value and len(value) <= 64 and all(c.isalnum() or c in "-._" for c in value):
            return value
    return None


class InfraProbe:
    def __init__(self, settings: Any, org: Any, spaces: Any, space_orgs: Any, access: Any, *,
                 run: Callable = subprocess.run, http: Optional[Callable] = None,
                 meminfo: Callable[[], dict] = _meminfo, now: Callable[[], float] = time.time):
        self.settings = settings
        self.org = org
        self.spaces = spaces
        self.space_orgs = space_orgs
        self.access = access
        self.run = run
        self.http = http or self._http_get
        self.meminfo = meminfo
        self.now = now
        self._lock = threading.Lock()
        self._cached: Optional[tuple[float, dict]] = None
        self._sizes: Optional[tuple[float, dict]] = None

    # ---- probes ---------------------------------------------------------------------------------------

    @staticmethod
    def _http_get(url: str) -> tuple[int, dict]:
        with httpx.Client(timeout=MODEL_TIMEOUT_S, trust_env=False) as c:
            r = c.get(url)
            try:
                return r.status_code, r.json()
            except ValueError:
                return r.status_code, {}

    def _model(self, role: str, base_url: str) -> dict:
        parts = urlsplit(base_url)
        entry: dict = {"role": role, "port": parts.port, "up": False, "model": None, "latency_ms": None}
        if parts.hostname not in ("127.0.0.1", "::1", "localhost"):
            entry["error"] = "not_loopback"
            return entry
        started = time.perf_counter()
        try:
            status, body = self.http(base_url.rstrip("/") + "/models")
        except (httpx.HTTPError, OSError) as exc:
            entry["error"] = type(exc).__name__
            return entry
        entry["latency_ms"] = round((time.perf_counter() - started) * 1000)
        entry["up"] = status == 200
        data = body.get("data") if isinstance(body, dict) else None
        if isinstance(data, list) and data and isinstance(data[0], dict):
            entry["model"] = str(data[0].get("id"))[:120]
        if status != 200:
            entry["error"] = f"http_{status}"
        return entry

    def models(self) -> list[dict]:
        out = [self._model("chat", self.settings.llm_base_url)]
        if self.settings.embed_base_url:
            out.append(self._model("embed", self.settings.embed_base_url))
        seen = {self.settings.llm_base_url.rstrip("/"), (self.settings.embed_base_url or "").rstrip("/")}
        for kind, client in sorted((getattr(self.org, "image_clients", None) or {}).items()):
            http = getattr(client, "_http", None)
            url = str(http.base_url) if http is not None and getattr(http, "base_url", None) else \
                getattr(client, "base_url", None)
            if isinstance(url, str) and url and url.rstrip("/") not in seen:
                seen.add(url.rstrip("/"))
                out.append(self._model(f"image:{kind}", url))
        return out

    def gpu(self) -> Optional[dict]:
        smi = shutil.which("nvidia-smi")
        if smi is None:
            return None
        try:
            q = self.run([smi, "--query-gpu=name,utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total",
                          "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=SMI_TIMEOUT_S)
        except (OSError, subprocess.TimeoutExpired):
            return {"available": False}
        if q.returncode != 0 or not q.stdout.strip():
            return {"available": False}
        gpus = []
        for line in q.stdout.strip().splitlines():
            cols = [c.strip() for c in line.split(",")]
            if len(cols) < 6:
                continue
            gpus.append({"name": cols[0][:60], "utilization_pct": _num(cols[1]), "temperature_c": _num(cols[2]),
                         "power_w": _num(cols[3]), "memory_used_mib": _num(cols[4]),
                         "memory_total_mib": _num(cols[5])})
        out: dict = {"available": True, "gpus": gpus}
        if gpus and all(g["memory_total_mib"] is None for g in gpus):
            # Unified memory (GB10): the system's memory is the GPU's.
            mem = self.meminfo()
            processes = None
            try:
                apps = self.run([smi, "--query-compute-apps=used_memory", "--format=csv,noheader,nounits"],
                                capture_output=True, text=True, timeout=SMI_TIMEOUT_S)
                if apps.returncode == 0:
                    processes = int(sum(_num(x) or 0 for x in apps.stdout.split()))
            except (OSError, subprocess.TimeoutExpired):
                pass
            out["unified_memory"] = {"total_mib": mem.get("MemTotal"), "available_mib": mem.get("MemAvailable"),
                                     "gpu_processes_mib": processes}
        return out

    def disk(self) -> dict:
        data = Path(self.settings.data_dir)
        try:
            usage = shutil.disk_usage(data)
            fs = {"total_gb": round(usage.total / 1e9, 1), "free_gb": round(usage.free / 1e9, 1),
                  "free_pct": round(100 * usage.free / usage.total, 1) if usage.total else None}
        except OSError:
            fs = {"total_gb": None, "free_gb": None, "free_pct": None}
        now = self.now()
        if self._sizes is None or now - self._sizes[0] > SIZE_CACHE_S:
            spaces_dir = data / "spaces"
            sizes = {"data_bytes": dir_bytes(data), "spaces_bytes": dir_bytes(spaces_dir) if spaces_dir.is_dir() else 0}
            self._sizes = (now, sizes)
        return {**fs, **self._sizes[1]}

    def organizer(self) -> dict:
        org = self.org
        locked = org.store.locked
        try:
            queue = None if locked else org.store.queue_depth()
        except Exception:  # noqa: BLE001 (locked meanwhile)
            locked, queue = True, None
        space_queue = 0
        for sid, o in list(getattr(self.space_orgs, "_orgs", {}).items()):
            try:
                if not o.store.locked:
                    space_queue += o.store.queue_depth()
            except Exception:  # noqa: BLE001
                continue
        root = Path(__file__).resolve().parents[2]
        return {"version": __version__, "revision": revision(root), "uptime_s": round(self.now() - STARTED),
                "workers": getattr(org, "workers", 1),
                "personal_store": {"locked": locked, "queue": queue,
                                   "last_error": None if locked else (org.last_error or "").split(":")[0] or None},
                "spaces": {**self.spaces.stats(), "organizers_unlocked": self.space_orgs.unlocked_count(),
                           "queue": space_queue},
                "access": self.access.stats()}

    # ---- the answer -------------------------------------------------------------------------------------

    def health(self) -> dict:
        with self._lock:
            now = self.now()
            if self._cached is not None and now - self._cached[0] < CACHE_S:
                return self._cached[1]
            models = self.models()
            gpu = self.gpu()
            disk = self.disk()
            warnings = []
            for m in models:
                if not m["up"]:
                    warnings.append(f"{m['role']}_down")
            if disk.get("free_pct") is not None and disk["free_pct"] < DISK_LOW_FREE * 100:
                warnings.append("disk_low")
            unified = (gpu or {}).get("unified_memory") or {}
            if unified.get("available_mib") is not None and unified["available_mib"] < MEMORY_LOW_MIB:
                warnings.append("memory_low")
            out = {"ok": not any(w.startswith("chat") or w == "disk_low" for w in warnings),
                   "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                   "organizer": self.organizer(), "models": models, "gpu": gpu, "disk": disk, "warnings": warnings}
            self._cached = (now, out)
            return out
