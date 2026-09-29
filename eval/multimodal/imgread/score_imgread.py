#!/usr/bin/env python3
"""Score image-read runs (run_imgread.py) on mm-v1. No model is called.

Per run it reports
  - type step: accuracy and the confusion (true type -> detected type)
  - extraction, end to end, with eval/multimodal/bench/score_vlm.py (the benchmark's scorer, unchanged): an image
    read as the wrong type is scored in that type's form, so a routing miss costs what it would cost the user
  - validator: first-try pass rate (both steps valid at the first attempt), retried, still failing after the
    retry (kept through sanitize()), values emptied by sanitize()
  - gist grounding: numbers in the gist that appear nowhere in the image's ground truth, and gists with any
  - latency (whole read, and per step) and tokens

  python3 score_imgread.py --gt-root eval/multimodal --split dev --run skills=out/dev-skills.r1.jsonl ... --out s.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bench"))
import score_vlm  # noqa: E402
from textmetrics import numbers  # noqa: E402

TYPES = ["chat_screenshot", "chart_dashboard", "slide", "whiteboard_handwriting", "receipt_invoice",
         "scanned_document", "form_label_sign"]
# the type-specific headline metrics of the benchmark tables (score_vlm aggregate keys)
TYPE_METRICS = {
    "chat_screenshot": ["sender_acc", "time_acc", "is_self_acc", "msg_count_ok", "msg_text_exact"],
    "chart_dashboard": ["point_acc", "kpi_acc", "trend_acc", "chart_type_ok"],
    "slide": ["bullet_recall", "bullet_precision", "bullet_level_acc", "title_exact"],
    "whiteboard_handwriting": ["line_exact", "struck_recall", "struck_acc", "checked_acc"],
    "receipt_invoice": ["item_f1", "self_consistent", "date_ok"],
    "scanned_document": ["table_cell_acc"],
    "form_label_sign": ["label_field_acc", "label_field_contains", "label_kind_ok"],
}


def q(xs, p):
    return score_vlm.quantile(xs, p)


def summarize(rows: list[dict], recs: dict) -> dict:
    ok_rows = [r for r in rows if r.get("status") == 200]
    per = [score_vlm.score_image(recs[r["id"]], r) for r in ok_rows]
    by_type = defaultdict(list)
    for s in per:
        by_type[s["type"]].append(s)
    overall = score_vlm.aggregate(per)
    type_aggs = {t: score_vlm.aggregate(v) for t, v in sorted(by_type.items())}
    for k in ("cer", "key_field_em", "qa_found", "fab_number_rate", "unsupported_rate"):
        vals = [a[k] for a in type_aggs.values() if a.get(k) is not None]
        overall[f"{k}_macro"] = round(statistics.mean(vals), 1) if vals else None

    # the same extraction without the gist: comparable with the benchmark's fabricated-number rate (its
    # neutral prompt had no gist), and it separates the gist's numbers from the extracted fields' numbers
    per_ng = []
    for r in ok_rows:
        content = json.loads(r.get("content") or "{}")
        content.pop("gist", None)
        per_ng.append(score_vlm.score_image(recs[r["id"]], {**r, "content": json.dumps(content, ensure_ascii=False)}))
    ng_by_type = defaultdict(list)
    for x in per_ng:
        ng_by_type[x["type"]].append(x)
    ng_fab = [score_vlm.aggregate(v)["fab_number_rate"] for v in ng_by_type.values()]
    ng_img = [score_vlm.pct([int(bool(x["fab_numbers"] or x["unsupported"])) for x in v]) for v in ng_by_type.values()]

    confusion = Counter((r["type"], r.get("detected_type")) for r in ok_rows)
    type_acc = round(100.0 * sum(n for (t, d), n in confusion.items() if t == d) / max(1, len(ok_rows)), 1)
    first_try = sum(1 for r in ok_rows if all(s["attempts"] == 1 and s["ok"] for s in r["steps"]))
    retried = sum(1 for r in ok_rows if any(s["attempts"] > 1 for s in r["steps"]))
    still_failing = sum(1 for r in ok_rows if not r["steps"][-1]["ok"])
    detect_fail = sum(1 for r in ok_rows if not r.get("detected", True) and len(r["steps"]) == 2)

    gist_fab, gists_with_fab, gist_empty = [], 0, 0
    for r in ok_rows:
        gist = (r.get("reading") or {}).get("gist", "")
        if not gist:
            gist_empty += 1
            continue
        corpus = set(numbers(score_vlm.gt_corpus(recs[r["id"]])))
        extra = [n for n in numbers(gist) if n not in corpus]
        gist_fab += extra
        gists_with_fab += bool(extra)
    gist_nums = sum(len(numbers((r.get("reading") or {}).get("gist", ""))) for r in ok_rows)

    step_lat = defaultdict(list)
    for r in ok_rows:
        for s in r["steps"]:
            step_lat[s["job"]].append(s["latency_s"])
    lat = [r["latency_s"] for r in ok_rows]
    out = {
        "n": len(rows), "errors": len(rows) - len(ok_rows),
        "type_accuracy": type_acc,
        "type_confusion": sorted([t, d, n] for (t, d), n in confusion.items() if t != d),
        "first_try_valid": first_try, "retried": retried, "still_failing_after_retry": still_failing,
        "type_step_failed": detect_fail, "values_sanitized": sum(r.get("sanitized") or 0 for r in ok_rows),
        "gist_numbers": gist_nums, "gist_fabricated_numbers": len(gist_fab), "gists_with_fabricated_number": gists_with_fab,
        "gist_fabricated_examples": gist_fab[:10], "gists_empty": gist_empty,
        "latency_p50": q(lat, 0.5), "latency_p90": q(lat, 0.9),
        "step_latency_p50": {k: q(v, 0.5) for k, v in step_lat.items()},
        "prompt_tokens_mean": round(statistics.mean(r.get("prompt_tokens") or 0 for r in ok_rows), 1) if ok_rows else None,
        "completion_tokens_mean": round(statistics.mean(r.get("completion_tokens") or 0 for r in ok_rows), 1) if ok_rows else None,
        "fab_number_rate_macro_without_gist": round(statistics.mean(ng_fab), 1) if ng_fab else None,
        "images_with_fabrication_macro_without_gist": round(statistics.mean(ng_img), 1) if ng_img else None,
        "images_with_fabrication_macro": round(statistics.mean(
            score_vlm.pct([int(bool(x["fab_numbers"] or x["unsupported"])) for x in v]) for v in by_type.values()), 1)
            if by_type else None,
        "extraction": {k: overall.get(k) for k in ("cer_macro", "key_field_em_macro", "qa_found_macro", "fab_number_rate_macro",
                                                   "unsupported_rate_macro", "num_recall", "valid_json")},
        "by_type": {t: {**{k: a.get(k) for k in ("n", "cer", "key_field_em", "qa_found", "fab_number_rate", "latency_p50")},
                        **{k: a.get(k) for k in TYPE_METRICS.get(t, [])}}
                    for t, a in type_aggs.items()},
        "images": [{"id": s["id"], "detected": r.get("detected_type"), "fields_wrong": [f for f in s["fields"] if not f[2]],
                    "fab": s["fab_numbers"], "unsupported": s["unsupported"], "cer": [s["cer_dist"], s["cer_len"]],
                    "qa": s["qa"], "attempts": r.get("attempts"), "sanitized": r.get("sanitized")}
                   for s, r in zip(per, ok_rows)],
    }
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt-root", required=True)
    ap.add_argument("--split", default="dev")
    ap.add_argument("--run", action="append", default=[], help="name=path.jsonl")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    root = Path(args.gt_root)
    manifest = json.loads((root / "manifest.json").read_text())
    recs = {it["id"]: json.loads((root / it["gt"]).read_text()) for it in manifest["items"] if it["split"] == args.split}
    result = {"split": args.split, "runs": {}}
    for spec in args.run:
        name, path = spec.split("=", 1)
        rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
        rows = [r for r in rows if r["id"] in recs]
        s = summarize(rows, recs)
        result["runs"][name] = {"path": path, **s}
        e = s["extraction"]
        print(f"{name:<24} n={s['n']} type={s['type_accuracy']} CER={e['cer_macro']} keyEM={e['key_field_em_macro']} "
              f"QA={e['qa_found_macro']} fab={e['fab_number_rate_macro']} unsup={e['unsupported_rate_macro']} "
              f"first={s['first_try_valid']} retried={s['retried']} fail={s['still_failing_after_retry']} "
              f"fab-no-gist={s['fab_number_rate_macro_without_gist']} img-fab={s['images_with_fabrication_macro']}/"
              f"{s['images_with_fabrication_macro_without_gist']} "
              f"gistfab={s['gist_fabricated_numbers']}/{s['gist_numbers']} p50={s['latency_p50']} p90={s['latency_p90']} "
              f"tok={s['completion_tokens_mean']}")
        for t, a in s["by_type"].items():
            print(f"    {t:<24} " + " ".join(f"{k}={v}" for k, v in a.items() if k != "n"))
        if s["type_confusion"]:
            print("    confusion:", s["type_confusion"])
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
