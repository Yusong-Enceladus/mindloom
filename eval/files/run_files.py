#!/usr/bin/env python3
"""Run file-read on files-v1 and score it.

  python eval/files/run_files.py --split dev --out eval/files/results/dev-r1 [--llm-url http://127.0.0.1:8000/v1]
                                 [--parse-only] [--condition skills|bare] [--workers 4]

Every file goes through the organizer's real path (organizer.file_read.read_file: sandboxed parse, image
parts through image-read, the file-read skill with guided decoding, validator and retry) against the given
OpenAI-compatible endpoint. --parse-only skips every model call (parse + routing only). --condition bare
replaces each SKILL.md body with a one-line task name (eval_common.strip_skill_text), everything else equal.

Scores (per file, then macro over files):
  type_ok       reading type (and error) as expected
  text_recall   gold must_contain strings found in the reading text (NFKC, whitespace and punctuation folded)
  image_recall  gold must_contain_image strings (only readable through image-read) found in the text
  summary_hit   share of gold summary groups with at least one alternative in the summary
  summary_model the summary came from the model on the first or second attempt (not sanitized / plain)
  field_em      gold key fields whose value appears in the reading's fields (receipt-like documents)
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "spark"))
sys.path.insert(0, str(REPO / "eval"))

_PUNCT = str.maketrans({"：": ":", "，": ",", "。": ".", "（": "(", "）": ")", "－": "-", "—": "-", "–": "-", "／": "/",
                        "¥": "￥", "“": '"', "”": '"', "·": "", "•": "", "|": ""})


def norm(s: str) -> str:
    return "".join(unicodedata.normalize("NFKC", str(s or "")).translate(_PUNCT).split()).lower()


def build(args):
    from organizer.api import build_organizer
    from organizer.config import Settings
    s = Settings()
    s.data_dir = Path(args.out) / "db"
    s.skills_dir = REPO / "skills"
    s.start_worker = False
    s.embed_base_url = ""
    s.require_token = False
    s.record_inputs = True
    s.llm_base_url = args.llm_url
    s.llm_timeout_s = 300
    from organizer.keys import synthetic_library_key
    s.unlock_key = synthetic_library_key()  # encrypted store, fixed synthetic key (synthetic data only)
    if args.parse_only:

        class NoModel:
            model_id = "none"

            def complete(self, *a, **k):
                raise ValueError("parse-only run: no model calls")

        org = build_organizer(s, chat=NoModel())
    else:
        org = build_organizer(s)
    if args.condition == "bare":
        from eval_common import strip_skill_text
        strip_skill_text(org)
    return org


def score(gold: dict, reading: dict) -> dict:
    text_n = norm(reading["text"])
    summ_n = norm(reading["summary"])
    mc = gold.get("must_contain") or []
    mi = gold.get("must_contain_image") or []
    groups = gold.get("summary_groups") or []
    got_fields = {f["key"]: f["value"] for f in reading["fields"]}
    got_values = [f["value"] for f in reading["fields"]]
    gf = {k: v for k, v in (gold.get("fields") or {}).items() if v}
    df = gold.get("det_fields") or {}
    return {
        "type_ok": reading["type"] == gold["type"] and (reading.get("error") or None) == gold.get("error"),
        "text_recall": (sum(norm(x) in text_n for x in mc) / len(mc)) if mc else None,
        "image_recall": (sum(norm(x) in text_n for x in mi) / len(mi)) if mi else None,
        "summary_hit": (sum(any(norm(a) in summ_n for a in g) for g in groups) / len(groups)) if groups else None,
        "summary_model": reading["summary_source"] in ("model",),
        # a gold key value counts when some field value contains it (a value may keep its unit / currency)
        "field_em": (sum(any(norm(v) in norm(x) for x in got_values) for v in gf.values()) / len(gf)) if gf else None,
        "det_field_em": (sum(norm(got_fields.get(k, "")) == norm(v) for k, v in df.items()) / len(df)) if df else None,
        "missing_text": [x for x in mc if norm(x) not in text_n],
        "missing_image": [x for x in mi if norm(x) not in text_n],
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=["dev", "test", "all"], default="dev")
    ap.add_argument("--out", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--parse-only", action="store_true")
    ap.add_argument("--condition", choices=["skills", "bare"], default="skills")
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--only", default="")
    ap.add_argument("--rescore", action="store_true",
                    help="score the records in --out again with the current gold (no model calls)")
    args = ap.parse_args()
    out = Path(args.out)
    if args.rescore:
        records = json.loads((out / "records.json").read_text())
        for r in records:
            gold = json.loads((HERE / "gold" / f"{r['id']}.json").read_text())
            r["score"] = score(gold, r["reading"])
        old = json.loads((out / "summary.json").read_text())
        summary = summarize(records, {k: old[k] for k in ("split", "condition", "parse_only", "prompt_hash", "model")})
        (out / "summary_rescored.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False))
        return
    out.mkdir(parents=True, exist_ok=False)
    from organizer.file_read import read_file
    org = build(args)
    manifest = json.loads((HERE / "manifest.json").read_text())
    items = [i for i in manifest["items"] if args.split in ("all", i["split"]) and (not args.only or args.only in i["id"])]

    def one(item: dict) -> dict:
        gold = json.loads((HERE / "gold" / f"{item['id']}.json").read_text())
        data = (HERE / gold["path"]).read_bytes()
        started = time.time()
        res = read_file(org.harness, data, {"filename": gold["filename"], "mime": "", "sha256": gold["sha256"],
                                            "source_app": {"name": "Finder"}, "captured_at": "2026-09-29T10:00:00+08:00"},
                        subject=item["id"], clients=org.image_clients)
        took = time.time() - started
        reading = {"type": res.type, "error": res.error, "text": res.text, "summary": res.summary, "fields": res.fields,
                   "counts": res.counts, "attachments": res.attachments, "doc_kind": res.doc_kind,
                   "summary_source": res.summary_source, "notes": res.notes, "run_id": res.run_id}
        attempts = None
        if res.run_id:
            row = org.store.one("SELECT attempts FROM runs WHERE run_id=?", (res.run_id,))
            attempts = row["attempts"] if row else None
        rec = {"id": item["id"], "template": gold["template"], "latency_s": round(took, 3), "summary_attempts": attempts,
               "image_parts": len(res.image_run_ids), "reading": reading, "score": score(gold, reading)}
        print(f"{item['id']:12s} {took:6.2f}s type={res.type:12s} err={res.error} src={res.summary_source:9s} "
              f"{res.summary[:50]}", flush=True)
        return rec

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        records = list(pool.map(one, items))
    (out / "records.json").write_text(json.dumps(records, ensure_ascii=False, indent=1), encoding="utf-8")

    summary = summarize(records, {"split": args.split, "condition": args.condition, "parse_only": args.parse_only,
                                  "prompt_hash": org.registry.skills["file-read"].prompt_hash,
                                  "model": getattr(org.harness.client, "model_id", None)})
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    for r in records:
        s = r["score"]
        if s["missing_text"] or s["missing_image"] or not s["type_ok"]:
            print("MISS", r["id"], r["reading"]["type"], s["missing_text"], s["missing_image"])


def summarize(records: list, head: dict) -> dict:
    def mean(key):
        vals = [r["score"][key] for r in records if r["score"][key] is not None]
        return (round(sum(vals) / len(vals), 3), len(vals)) if vals else (None, 0)

    lat = sorted(r["latency_s"] for r in records)
    return {
        **head, "files": len(records),
        "type_ok": mean("type_ok"), "text_recall": mean("text_recall"), "image_recall": mean("image_recall"),
        "summary_hit": mean("summary_hit"), "summary_model": mean("summary_model"), "field_em": mean("field_em"),
        "det_field_em": mean("det_field_em"),
        "summary_first_try": sum(1 for r in records if r["summary_attempts"] == 1),
        "summary_calls": sum(1 for r in records if r["summary_attempts"] is not None),
        "latency_p50": round(statistics.median(lat), 2) if lat else None,
        "latency_p90": round(lat[max(0, int(len(lat) * 0.9) - 1)], 2) if lat else None,
    }


if __name__ == "__main__":
    main()
