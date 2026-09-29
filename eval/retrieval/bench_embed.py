#!/usr/bin/env python3
"""Latency, throughput and memory of an embedding endpoint on the organizer's own texts.

Texts: every non-image item of the given synthetic scenarios, built the way the organizer embeds them
(source app name, newline, item text or "speaker: text" lines, cut to 2000 characters). Run it on the
Spark that serves the endpoint (loopback), so the numbers are what the organizer sees.

  single   one text per request, sequential (the organizer embeds one item per call): p50/p95/mean ms
  batch    --batch texts per request, sequential: texts/s
  memory   GPU memory of the serving process tree (nvidia-smi --query-compute-apps), found from the
           process that listens on the endpoint's port, plus the host's available memory

  python3 eval/retrieval/bench_embed.py --embed-url http://127.0.0.1:8013/v1 --out bench.json \
      eval/scenarios/dev-week-v1/scenario.json eval/scenarios/holdout-week-v2/scenario.json
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "spark"))

from organizer.clients import HashEmbedClient, OpenAIEmbedClient  # noqa: E402

EMBED_TEXT_CHARS = 2000  # organizer.organizer.EMBED_TEXT_CHARS


def texts_from(scenario_path: str) -> list[str]:
    sc = json.loads(Path(scenario_path).read_text(encoding="utf-8"))
    if sc.get("synthetic") is not True:
        raise SystemExit("refusing a scenario that is not marked synthetic")
    names = {p["person_id"]: p["display_name"] for p in sc["people"]}
    out = []
    for it in sc["items"]:
        if it["kind"] == "image":
            continue
        if it.get("segments"):
            body = "\n".join(f"{names.get(s.get('person_id'), '说话人')}：{s['text']}" for s in it["segments"])
        else:
            body = (f"{it['filename']}\n\n" if it.get("filename") else "") + it.get("text", "")
        out.append(f"{it['source_app']}\n{body[:EMBED_TEXT_CHARS]}")
    return out


def pct(values: list[float], q: float) -> float:
    s = sorted(values)
    return round(s[min(len(s) - 1, max(0, math.ceil(q * len(s)) - 1))], 2)


def _ppid(pid: int) -> int:
    try:
        return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def memory_of_port(port: int) -> dict:
    res: dict = {}
    try:
        ss = subprocess.run(["ss", "-ltnpH"], capture_output=True, text=True, timeout=10).stdout
        m = re.search(rf":{port}\s.*?pid=(\d+)", ss)
        root = int(m.group(1)) if m else None
        res["server_pid"] = root
        apps = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
                               "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=20).stdout
        rows = []
        for line in apps.strip().splitlines():
            pid, name, mem = [x.strip() for x in line.split(",")]
            pid_i, p = int(pid), int(pid)
            for _ in range(6):  # walk up to the listening server
                if p == root:
                    rows.append({"pid": pid_i, "name": name, "used_mib": int(mem)})
                    break
                p = _ppid(p)
                if p <= 1:
                    break
        res["gpu_processes"] = rows
        res["gpu_used_mib"] = sum(r["used_mib"] for r in rows)
        rss = 0
        for pid in [root] + [r["pid"] for r in rows]:
            if pid:
                for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                    if line.startswith("VmRSS:"):
                        rss += int(line.split()[1])
        res["rss_mib"] = round(rss / 1024)
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                res["host_mem_available_gib"] = round(int(line.split()[1]) / 1024 / 1024, 1)
    except (OSError, subprocess.SubprocessError, AttributeError, ValueError) as exc:
        res["error"] = repr(exc)
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenarios", nargs="+")
    ap.add_argument("--embed-url", default="", help="empty = HashEmbedClient (in-process, no model)")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--label", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    texts = [t for p in args.scenarios for t in texts_from(p)]
    client = OpenAIEmbedClient(args.embed_url) if args.embed_url else HashEmbedClient()
    model = client.model_id
    for t in texts[:5]:
        client.embed([t])  # warm-up
    single = []
    for _ in range(args.repeats):
        for t in texts:
            t0 = time.perf_counter()
            client.embed([t])
            single.append((time.perf_counter() - t0) * 1000.0)
    t0 = time.perf_counter()
    dim = 0
    for _ in range(args.repeats):
        for i in range(0, len(texts), args.batch):
            dim = len(client.embed(texts[i:i + args.batch])[0])
    batch_s = time.perf_counter() - t0
    result = {
        "label": args.label or model, "model": model, "embed_url": args.embed_url or None, "dim": dim,
        "texts": len(texts), "chars_p50": pct([len(t) for t in texts], 0.5), "chars_max": max(len(t) for t in texts),
        "single_ms": {"p50": pct(single, 0.5), "p95": pct(single, 0.95), "mean": round(statistics.mean(single), 2),
                      "n": len(single)},
        "batch": {"size": args.batch, "texts_per_s": round(args.repeats * len(texts) / batch_s, 1)},
        "memory": memory_of_port(urlparse(args.embed_url).port) if args.embed_url else {"gpu_used_mib": 0},
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
