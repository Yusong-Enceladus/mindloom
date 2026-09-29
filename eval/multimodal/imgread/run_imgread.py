#!/usr/bin/env python3
"""Run the organizer's image-read path over a split of the mm-v1 eval set (synthetic images only).

Each image goes through organizer.image_read.read_image exactly as an intake item does: the shipped
skills/image-read files, the harness (guided JSON, validator, one retry), type step then that type's
extraction, and sanitize() when the retry still fails. Only the item context is fixed (no source app,
a fixed capture time), so nothing but the image tells the model what it is.

  --condition skills           the shipped skill (SKILL.md body in the system prompt)
  --condition without-skills   the same with the SKILL.md body replaced by a one-line task name
                               (eval/eval_common.strip_skill_text: global rules, schemas, validator, retry stay)
  --forced-type                skip the type step and extract with the true type (isolates extraction)

Rows (JSONL) carry the kept extraction as `content`, so eval/multimodal/bench/score_vlm.py scores them like
a benchmark run; score_imgread.py adds type accuracy, validator and latency numbers.

  python3 run_imgread.py --root eval/multimodal --split dev --url http://127.0.0.1:30102/v1 \
      --condition skills --out out/dev-skills.r1.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "spark"))
sys.path.insert(0, str(REPO / "eval"))

from organizer.clients import OpenAIChatClient  # noqa: E402
from organizer.image_read import read_image  # noqa: E402
from organizer.skills import Harness, SkillRegistry  # noqa: E402
from organizer.store import Store  # noqa: E402

CONTEXT = {"source_app": "", "captured_at": "2026-09-29T10:00:00+08:00"}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(REPO / "eval" / "multimodal"), help="holds manifest.json and images/")
    ap.add_argument("--split", default="dev")
    ap.add_argument("--ids", default="", help="comma-separated ids (overrides --split)")
    ap.add_argument("--url", required=True, help="OpenAI-compatible endpoint (…/v1)")
    ap.add_argument("--model", default="auto")
    ap.add_argument("--condition", choices=["skills", "without-skills"], default="skills")
    ap.add_argument("--forced-type", action="store_true")
    ap.add_argument("--concurrency", type=int, default=1)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = Path(args.root)
    manifest = json.loads((root / "manifest.json").read_text())
    wanted = set(filter(None, args.ids.split(",")))
    items = [it for it in manifest["items"] if (it["id"] in wanted if wanted else it["split"] == args.split)]
    if wanted and any(it["split"] == "test" for it in items) and args.split != "test":
        raise SystemExit("test images requested without --split test")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {json.loads(line)["id"] for line in out.read_text().splitlines()} if out.exists() else set()
    todo = [it for it in items if it["id"] not in done]

    registry = SkillRegistry(REPO / "skills")
    if args.condition == "without-skills":
        import eval_common
        eval_common.strip_skill_text(SimpleNamespace(registry=registry))
    store = Store(":memory:")
    client = OpenAIChatClient(args.url, args.model, 900.0)
    harness = Harness(registry, client, store)
    skill = registry.skills["image-read"]
    meta = {"condition": args.condition, "forced_type": args.forced_type, "model": client.model_id, "url": args.url,
            "prompt_hash": skill.prompt_hash, "skill_version": skill.version, "concurrency": args.concurrency,
            "split": args.split if not wanted else "ids", "n": len(todo), "started": time.time()}
    lock = threading.Lock()

    def work(it: dict) -> None:
        image = (root / it["image"]).read_bytes()
        t0 = time.time()
        try:
            res = read_image(harness, image, CONTEXT, subject=it["id"],
                             forced_type=it["type"] if args.forced_type else None)
            err = None
        except Exception as exc:  # noqa: BLE001 - recorded; the row is kept so the run completes
            res, err = None, repr(exc)[:500]
        t1 = time.time()
        row = {"id": it["id"], "type": it["type"], "split": it["split"], "condition": args.condition,
               "model": client.model_id, "latency_s": round(t1 - t0, 3), "status": 200 if res else -1, "error": err}
        if res is not None:
            steps = []
            for r in res.runs:
                rec = store.one("SELECT job_type, attempts, ok, prompt_tokens, completion_tokens, error, started_at,"
                                " ended_at FROM runs WHERE run_id=?", (r.run_id,))
                steps.append({"job": rec["job_type"], "attempts": rec["attempts"], "ok": bool(rec["ok"]),
                              "prompt_tokens": rec["prompt_tokens"], "completion_tokens": rec["completion_tokens"],
                              "latency_s": round(rec["ended_at"] - rec["started_at"], 3), "errors": r.errors[:6], "attempt_errors": r.attempt_errors})
            row.update({
                "detected_type": res.image_type, "detected": res.detected, "ok": res.ok, "sanitized": res.sanitized,
                "steps": steps, "attempts": res.attempts,
                "prompt_tokens": sum(s["prompt_tokens"] or 0 for s in steps),
                "completion_tokens": sum(s["completion_tokens"] or 0 for s in steps),
                "finish_reason": "stop", "content": json.dumps(res.output or {}, ensure_ascii=False),
                "reading": res.reading,
            })
        with lock:
            with out.open("a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(f"{it['id']:<11} {row['latency_s']:6.2f}s type={row.get('detected_type')} ok={row.get('ok')} "
                  f"att={row.get('attempts')} san={row.get('sanitized')} {err or ''}", flush=True)

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        list(pool.map(work, todo))
    meta["wall_s"] = round(time.time() - meta["started"], 2)
    meta_path = out.with_suffix(".meta.json")
    prev = json.loads(meta_path.read_text()) if meta_path.exists() else {"segments": []}
    prev["segments"].append(meta)
    meta_path.write_text(json.dumps(prev, ensure_ascii=False, indent=1))
    print(f"done {len(todo)} images in {meta['wall_s']} s", flush=True)


if __name__ == "__main__":
    main()
