#!/usr/bin/env python3
"""Score file-reading predictions against the ground truth (no model calls here).

  # 1) questions for a reader (file path + questions, no answers), one JSON per line
  python eval/files-multiformat/tools/score.py --questions --split dev > /tmp/files-dev-questions.jsonl
  # 2) the reader writes one line per file: {"file_id": "pptx-01", "answers": {"q1": "...", ...}, "text": "<optional full reading>"}
  python eval/files-multiformat/tools/score.py --pred /tmp/preds.jsonl --split dev [--out /tmp/files-dev-score.json]

QA matching: exact = the gold string (or an accepted variant) appears as a whole token in the answer; contains = it
appears anywhere (after NFKC, lower case, dropping spaces and punctuation); number = some number in the answer equals
the gold (tol absolute if given; "96.2%" also counts as 0.962 and "3.6万" as 36000). If the reader also returns
`text`, key-line recall (share of truth key lines found in it) and number recall are reported, split by text layer
(full / partial / none = image-only) so OCR-free extraction and picture reading are not mixed. Tune only on dev;
report test once.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from extract import has_number, norm  # noqa: E402

ROOT = os.path.dirname(HERE)
_NUM = re.compile(r"(?<![\d.])(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?\s*(万|%|％)?")


def numbers_in(s: str) -> list[float]:
    s = unicodedata.normalize("NFKC", str(s))
    out = []
    for m in _NUM.finditer(s):
        v = float((m.group(1) or "").replace(",", "") + (m.group(2) or ""))
        if m.group(3) == "万":
            out.append(v * 10000)
        elif m.group(3) in ("%", "％"):
            out += [v, v / 100]
        else:
            out.append(v)
    return out


def match(qa: dict, pred) -> bool:
    if pred is None:
        return False
    pred = str(pred)
    golds = [qa["a"]] + list(qa.get("accept", []))
    if qa["match"] == "number":
        g = float(qa["a"])
        tol = qa.get("tol")
        for v in numbers_in(pred):
            if (abs(v - g) <= tol) if tol is not None else (abs(v - g) <= 1e-6 * max(1.0, abs(g))):
                return True
        return any(norm(a) and norm(a) in norm(pred) for a in qa.get("accept", []))
    npred = norm(pred)
    for a in golds:
        na = norm(a)
        if not na:
            continue
        if qa["match"] == "exact":
            if re.search(r"(?<![0-9a-z])" + re.escape(na) + r"(?![0-9a-z])", npred):
                return True
        elif na in npred:
            return True
    return False


def load_entries(split: str | None, types: set | None) -> list[dict]:
    with open(os.path.join(ROOT, "manifest.json"), encoding="utf-8") as fh:
        man = json.load(fh)
    out = []
    for e in man["entries"]:
        if split and e["split"] != split:
            continue
        if types and e["type"] not in types:
            continue
        with open(os.path.join(ROOT, e["truth"]), encoding="utf-8") as fh:
            out.append((e, json.load(fh)))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--split", choices=["dev", "test"])
    ap.add_argument("--types", help="comma-separated file types")
    ap.add_argument("--questions", action="store_true", help="print questions (no answers) for a reader")
    ap.add_argument("--pred", help="predictions JSONL")
    ap.add_argument("--out", help="write the full report JSON here")
    args = ap.parse_args(argv)
    types = set(args.types.split(",")) if args.types else None
    entries = load_entries(args.split, types)
    if args.questions:
        for e, t in entries:
            print(json.dumps({"file_id": e["file_id"], "path": os.path.join("eval/files-multiformat", e["path"]), "filename": t["filename"],
                              "mime": t["mime"], "questions": [{"id": q["id"], "q": q["q"]} for q in t["qa"]]}, ensure_ascii=False))
        return 0
    if not args.pred:
        ap.error("--pred or --questions is required")
    preds = {}
    with open(args.pred, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                p = json.loads(line)
                preds[p["file_id"]] = p
    rows, agg = [], {}
    for e, t in entries:
        p = preds.get(e["file_id"])
        ans = (p or {}).get("answers", {})
        qa_hits = [match(q, ans.get(q["id"])) for q in t["qa"]]
        row = {"file_id": e["file_id"], "type": e["type"], "split": e["split"], "text_layer": t["text_layer"], "missing": p is None,
               "qa": sum(qa_hits) / len(qa_hits), "qa_hits": qa_hits}
        text = (p or {}).get("text")
        if text is not None:
            nt = norm(text)
            kl = t["key_lines"]
            row["key_line_recall"] = sum(norm(x) in nt for x in kl) / len(kl) if kl else None
            nums = t.get("numbers", [])
            row["number_recall"] = sum(has_number(text, n["value"]) for n in nums) / len(nums) if nums else None
        rows.append(row)
        for key in ("all", f"type:{e['type']}", f"layer:{t['text_layer']}"):
            a = agg.setdefault(key, {"files": 0, "qa_n": 0, "qa_hit": 0, "missing": 0, "klr": [], "nr": []})
            a["files"] += 1
            a["qa_n"] += len(qa_hits)
            a["qa_hit"] += sum(qa_hits)
            a["missing"] += p is None
            if row.get("key_line_recall") is not None:
                a["klr"].append(row["key_line_recall"])
            if row.get("number_recall") is not None:
                a["nr"].append(row["number_recall"])
    mean = lambda xs: round(sum(xs) / len(xs), 4) if xs else None  # noqa: E731
    summary = {k: {"files": a["files"], "missing": a["missing"], "qa_acc": round(a["qa_hit"] / a["qa_n"], 4) if a["qa_n"] else None,
                   "qa_n": a["qa_n"], "key_line_recall": mean(a["klr"]), "number_recall": mean(a["nr"])} for k, a in agg.items()}
    print(f"{'group':18s} files miss  qa_acc  qa_n  key_lines  numbers")
    for k in ["all"] + sorted(x for x in summary if x.startswith("layer:")) + sorted(x for x in summary if x.startswith("type:")):
        s = summary[k]
        f = lambda v: "   -  " if v is None else f"{v:6.3f}"  # noqa: E731
        print(f"{k:18s} {s['files']:5d} {s['missing']:4d}  {f(s['qa_acc'])} {s['qa_n']:5d}  {f(s['key_line_recall'])}    {f(s['number_recall'])}")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"split": args.split, "summary": summary, "files": rows}, fh, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
