#!/usr/bin/env python3
"""Read the 33-format synthetic file set (eval/files-multiformat) through the organizer's real file-read path
and write predictions for eval/files-multiformat/tools/score.py.

Each file goes through organizer.file_read.read_file (sandboxed parse -> image-read for scanned pages and
embedded pictures -> file-read summary), exactly as eval/files/run_files.py does for files-v1. There is no
question-answering reader: each question's "answer" is the whole reading (text + summary + field values), so
the QA number is "the gold answer is present in what the organizer read", an upper bound for any reader of
that reading. key_line_recall / number_recall are the scorer's own text metrics. Synthetic data only.

  python run_multiformat.py --repo REPO --split test --out OUT [--llm-url URL] [--parse-only] [--workers 2]
"""
import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--repo", required=True)
ap.add_argument("--split", default="test")
ap.add_argument("--out", required=True)
ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
ap.add_argument("--parse-only", action="store_true")
ap.add_argument("--workers", type=int, default=2)
args = ap.parse_args()
REPO = Path(args.repo).resolve()
MF = REPO / "eval" / "files-multiformat"
sys.path.insert(0, str(REPO / "spark"))
sys.path.insert(0, str(REPO / "eval"))
sys.path.insert(0, str(REPO / "eval" / "files"))
import run_files  # noqa: E402
from organizer.file_read import read_file  # noqa: E402

out = Path(args.out)
out.mkdir(parents=True, exist_ok=False)
org = run_files.build(argparse.Namespace(out=str(out), llm_url=args.llm_url, parse_only=args.parse_only,
                                         condition="skills"))
man = json.loads((MF / "manifest.json").read_text())
entries = [e for e in man["entries"] if args.split in ("all", e["split"])]


def one(e):
    truth = json.loads((MF / e["truth"]).read_text())
    data = (MF / e["path"]).read_bytes()
    t0 = time.time()
    err = None
    try:
        res = read_file(org.harness, data, {"filename": e["filename"], "mime": truth.get("mime") or "",
                                            "sha256": truth.get("sha256") or "", "source_app": {"name": "Finder"},
                                            "captured_at": "2026-09-29T10:00:00+08:00"},
                        subject=e["file_id"], clients=org.image_clients)
        fields = " ".join(f"{f.get('label', '')} {f.get('value', '')}" for f in (res.fields or []))
        reading = "\n".join([res.text or "", res.summary or "", fields])
        typ, rerr, nimg = res.type, res.error, len(res.image_run_ids)
    except Exception as exc:  # a crash is scored as an empty reading
        reading, typ, rerr, nimg, err = "", None, None, 0, f"{type(exc).__name__}: {str(exc)[:120]}"
    took = time.time() - t0
    print(f"{e['file_id']:14s} {took:6.2f}s type={typ} err={rerr} imgs={nimg} {err or ''}", flush=True)
    return {"file_id": e["file_id"], "type": e["type"], "text_layer": e["text_layer"], "latency_s": round(took, 2),
            "reading_type": typ, "reading_error": rerr, "image_parts": nimg, "crash": err,
            "text": reading, "answers": {q["id"]: reading for q in truth["qa"]}}


with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
    recs = list(pool.map(one, entries))
with open(out / "preds.jsonl", "w", encoding="utf-8") as fh:
    for r in recs:
        fh.write(json.dumps({"file_id": r["file_id"], "text": r["text"], "answers": r["answers"]}, ensure_ascii=False) + "\n")
meta = [{k: v for k, v in r.items() if k not in ("text", "answers")} for r in recs]
(out / "meta.json").write_text(json.dumps({"split": args.split, "parse_only": args.parse_only,
                                           "model": getattr(org.harness.client, "model_id", None),
                                           "files": meta}, ensure_ascii=False, indent=1))
print("DONE", len(recs))
