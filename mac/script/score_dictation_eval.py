#!/usr/bin/env python3
"""Score a DictationEvalCLI run against its manifest; prints aggregates only.

Metrics per duration bucket:
- diff: character edit distance to the reference over the reference length,
  after NFKC, lowercasing and dropping everything but letters and digits.
  With Typeless references this is "distance from Typeless's result", not a
  verbatim word error rate.
- punct/100: punctuation marks per 100 content characters.
- stops/100: sentence-final marks (。！？.!?) per 100 content characters.
- decode / polish: median milliseconds.
No transcript text is ever printed.
"""

import argparse
import json
import statistics
import unicodedata
from collections import defaultdict

STOPS = set("。！？.!?")


def content(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(ch for ch in text if unicodedata.category(ch)[0] in "LN")


def punctuation(text: str) -> tuple[int, int]:
    marks = [ch for ch in text if unicodedata.category(ch).startswith("P")]
    return len(marks), sum(1 for ch in marks if ch in STOPS)


def edit_distance(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--field", default="finalText",
                        help="rawText or finalText")
    parser.add_argument("--summary-out")
    args = parser.parse_args()

    manifest = {item["id"]: item for item in json.load(open(args.manifest))["items"]}
    results = json.load(open(args.results))["items"]

    groups = defaultdict(list)
    for result in results:
        item = manifest.get(result["id"])
        if not item:
            continue
        reference, hypothesis = item["reference"], result.get(args.field) or ""
        ref_content, hyp_content = content(reference), content(hypothesis)
        ref_p, ref_s = punctuation(reference)
        hyp_p, hyp_s = punctuation(hypothesis)
        row = {
            "errors": edit_distance(hyp_content, ref_content),
            "refChars": max(1, len(ref_content)),
            "hypChars": max(1, len(hyp_content)),
            "refPunct": ref_p, "refStops": ref_s,
            "hypPunct": hyp_p, "hypStops": hyp_s,
            "decodeMs": result.get("decodeMs"),
            "polishMs": result.get("polishMs"),
            "audio": item["durationSeconds"],
        }
        groups[item["bucket"]].append(row)
        groups["ALL"].append(row)

    order = ["lt5", "5to15", "15to30", "30to60", "60to120", "ALL"]
    summary = {}
    print(f"field={args.field}")
    print(f"{'bucket':8} {'n':>4} {'diff%':>7} {'punct/100 hyp|ref':>18} "
          f"{'stops/100 hyp|ref':>18} {'decode':>7} {'polish':>7}")
    for bucket in order:
        rows = groups.get(bucket)
        if not rows:
            continue
        errors = sum(r["errors"] for r in rows)
        ref_chars = sum(r["refChars"] for r in rows)
        hyp_chars = sum(r["hypChars"] for r in rows)
        stats = {
            "n": len(rows),
            "diffPercent": round(100 * errors / ref_chars, 2),
            "hypPunctPer100": round(100 * sum(r["hypPunct"] for r in rows) / hyp_chars, 2),
            "refPunctPer100": round(100 * sum(r["refPunct"] for r in rows) / ref_chars, 2),
            "hypStopsPer100": round(100 * sum(r["hypStops"] for r in rows) / hyp_chars, 2),
            "refStopsPer100": round(100 * sum(r["refStops"] for r in rows) / ref_chars, 2),
            "decodeMsMedian": median([r["decodeMs"] for r in rows]),
            "polishMsMedian": median([r["polishMs"] for r in rows]),
        }
        summary[bucket] = stats
        print(f"{bucket:8} {stats['n']:>4} {stats['diffPercent']:>7.2f} "
              f"{stats['hypPunctPer100']:>8.2f} | {stats['refPunctPer100']:<7.2f} "
              f"{stats['hypStopsPer100']:>8.2f} | {stats['refStopsPer100']:<7.2f} "
              f"{fmt(stats['decodeMsMedian']):>7} {fmt(stats['polishMsMedian']):>7}")
    if args.summary_out:
        json.dump({"field": args.field, "buckets": summary},
                  open(args.summary_out, "w"), indent=1)


def median(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return round(statistics.median(values)) if values else None


def fmt(value):
    return "-" if value is None else str(value)


if __name__ == "__main__":
    main()
