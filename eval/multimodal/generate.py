#!/usr/bin/env python3
"""Generate the synthetic multimodal eval set (eval/multimodal): 140 images in 7 information-bearing
types, one ground-truth JSON per image, a stratified dev/test split and a manifest with hashes.

Everything is invented and rendered locally (Pillow, numpy, matplotlib, reportlab, pdfium); no model is
called. Output is deterministic for the same fonts and library versions (recorded in the manifest).

  python eval/multimodal/generate.py                 # writes images/, gt/, manifest.json next to this file
  python eval/multimodal/generate.py --out /tmp/mm   # somewhere else (e.g. to diff against the committed set)
  python eval/multimodal/generate.py --only chat     # one type, for iterating on a renderer

The committed images and ground truth are the reference; regenerate only when a renderer changes, and
never after looking at model results on the test split.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import random
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from mmgen import chart, chat, fonts, form, receipt, scan, slide, whiteboard  # noqa: E402

VERSION = "mm-v1"
DEV_PER_TYPE = 6

# --------------------------------------------------------------------------- variant plans (20 per type)

CHAT = [
    dict(conv="beans", theme="light"),
    dict(conv="launch", theme="mint", time_style="yesterday"),
    dict(conv="dinner", theme="light"),
    dict(conv="tiles", theme="dark"),
    dict(conv="school", theme="lowc_light"),
    dict(conv="refund", theme="mint"),
    dict(conv="run", theme="dark", small=0.55),
    dict(conv="trip", theme="light", time_style="date"),
    dict(conv="rent", theme="lowc_dark"),
    dict(conv="samples", theme="light", similar=True, similar_pair=0),
    dict(conv="en_launch", theme="light"),
    dict(conv="en_move", theme="dark", time_style="weekday"),
    dict(conv="mixed_review", theme="mint"),
    dict(conv="mixed_vendor", theme="light", small=0.6),
    dict(conv="beans", theme="dark", similar=True, similar_pair=1, time_style="weekday"),
    dict(conv="launch", theme="lowc_light", similar=True, similar_pair=2, small=0.6),
    dict(conv="school", theme="mint", time_style="ampm", status_bar=False),
    dict(conv="en_launch", theme="light", similar=True, similar_pair=0, time_style="yesterday"),
    dict(conv="samples", theme="dark", similar=True, similar_pair=3, time_style="date"),
    dict(conv="trip", theme="light", time_style="ampm", small=0.5),
]

CHART = [
    dict(chart="bar", topic="sales", patterns=["rise_then_fall"]),
    dict(chart="bar", topic="users", patterns=["up"]),
    dict(chart="line", topic="latency", patterns=["down"]),
    dict(chart="line", topic="temp", patterns=["rise_then_fall"], small=True),
    dict(chart="line", lang="en", topic="conv", patterns=["fall_then_rise"]),
    dict(chart="bar", lang="en", topic="tickets", patterns=["up"], low_contrast=True),
    dict(chart="grouped_bar", patterns=["up", "down"], similar_colors=True, seed_hint="quarter"),
    dict(chart="grouped_bar", patterns=["up", "up"], seed_hint="region"),
    dict(chart="grouped_bar", lang="en", patterns=["up", "rise_then_fall"], similar_colors=True, small=True),
    dict(chart="pie", donut=True),
    dict(chart="pie", lang="en"),
    dict(chart="pie", low_contrast=True, small=True),
    dict(chart="hbar"),
    dict(chart="hbar", lang="en", jpeg=60),
    dict(chart="dashboard", patterns=["up"]),
    dict(chart="dashboard", dark=True, patterns=["fall_then_rise"]),
    dict(chart="dashboard", lang="en", patterns=["down"], small=True),
    dict(chart="dashboard", lang="en", dark=True, low_contrast=True, patterns=["rise_then_fall"]),
    dict(chart="line", topic="orders", patterns=["flat"]),
    dict(chart="bar", lang="en", topic="rev", patterns=["up"], jpeg=70),
]

SLIDE = [
    dict(content="weekly", theme="corporate"),
    dict(content="review", theme="corporate"),
    dict(content="launch", theme="minimal"),
    dict(content="research", theme="dark"),
    dict(content="budget", theme="lowc", small=True),
    dict(content="training", theme="minimal", similar=True, dense=True),
    dict(content="agenda", theme="corporate", photo=True),
    dict(content="en_review", theme="dark"),
    dict(content="en_launch", theme="dark", photo=True),
    dict(content="en_onboard", theme="minimal", similar=True),
    dict(content="weekly", theme="lowc"),
    dict(content="review", theme="dark", photo=True),
    dict(content="launch", theme="corporate", small=True),
    dict(content="research", theme="minimal", dense=True),
    dict(content="budget", theme="corporate", photo=True),
    dict(content="training", theme="dark"),
    dict(content="agenda", theme="lowc"),
    dict(content="en_review", theme="corporate", small=True),
    dict(content="en_launch", theme="minimal", dense=True),
    dict(content="en_onboard", theme="corporate", photo=True),
]

BOARD = [
    dict(content="weekly", font="hand_pen", surface="whiteboard", similar=True),
    dict(content="todo", font="hand_note", surface="notebook", size=56),
    dict(content="plan", font="hand_xing", surface="notebook", size=60),
    dict(content="formula", font="hand_wawa", surface="whiteboard"),
    dict(content="en_standup", font="hand_marker", surface="whiteboard", faint=True),
    dict(content="en_shopping", font="hand_chalk", surface="blackboard"),
    dict(content="sticky", font="hand_wawa", size=52),
    dict(content="weekly", font="kai", surface="whiteboard", far=True),
    dict(content="todo", font="hand_pen", surface="whiteboard", faint=True),
    dict(content="plan", font="hand_note", surface="notebook", similar=True, shadow=True, size=56),
    dict(content="formula", font="hand_xing", surface="whiteboard"),
    dict(content="en_standup", font="hand_bradley", surface="notebook", similar=True, size=52),
    dict(content="en_shopping", font="hand_noteworthy", surface="notebook", shadow=True, size=56),
    dict(content="sticky", font="hand_pen", similar=True, size=52),
    dict(content="weekly", font="hand_note", surface="blackboard"),
    dict(content="todo", font="hand_xing", surface="notebook", faint=True, size=56),
    dict(content="plan", font="hand_pen", surface="whiteboard", far=True),
    dict(content="formula", font="kai", surface="notebook", size=58),
    dict(content="en_standup", font="hand_chalk", surface="blackboard", similar=True),
    dict(content="en_shopping", font="hand_bradley", surface="whiteboard", far=True),
]

RECEIPT = [
    dict(kind="receipt"),
    dict(kind="receipt", similar=True),
    dict(kind="receipt", faint=True),
    dict(kind="receipt", far=True, glare=True),
    dict(kind="receipt", shadow=True),
    dict(kind="receipt", lang="en"),
    dict(kind="receipt", lang="en", faint=True),
    dict(kind="receipt", lang="en", similar=True),
    dict(kind="receipt", bg="wood"),
    dict(kind="receipt", lang="en", far=True),
    dict(kind="invoice"),
    dict(kind="invoice", similar=True, shadow=True),
    dict(kind="invoice", faint=True),
    dict(kind="invoice", lang="en"),
    dict(kind="invoice", lang="en", similar=True, glare=True),
    dict(kind="invoice", far=True),
    dict(kind="receipt", similar=True, faint=True),
    dict(kind="receipt", blur=1.3),
    dict(kind="invoice", lang="en", shadow=True),
    dict(kind="receipt", lang="en", glare=True),
]

SCAN = [
    dict(content="minutes", similar=True),
    dict(content="notice"),
    dict(content="lease"),
    dict(content="plan", similar=True),
    dict(content="en_memo"),
    dict(content="en_policy"),
    dict(content="en_minutes", similar=True),
    dict(content="minutes", faint=True),
    dict(content="notice", rotate=3.2),
    dict(content="lease", body_pt=9, dpi=120, blur=0.8),
    dict(content="plan", blur=1.4),
    dict(content="en_memo", similar=True, faint=True),
    dict(content="en_policy", body_pt=9, dpi=120, blur=0.7),
    dict(content="en_minutes", rotate=-2.8),
    dict(content="minutes", similar=True, body_pt=9, dpi=120, blur=0.7),
    dict(content="notice", similar=True, faint=True),
    dict(content="lease", rotate=2.6, blur=1.0),
    dict(content="plan"),
    dict(content="en_memo", rotate=-3.0),
    dict(content="en_policy", blur=1.4, faint=True),
]

LABEL = [
    dict(kind="shipping_label", similar=True),
    dict(kind="shipping_label", lang="en"),
    dict(kind="nameplate"),
    dict(kind="nameplate", faint=True, glare=True),
    dict(kind="price_tag", promo=True),
    dict(kind="price_tag"),
    dict(kind="price_tag", lang="en", promo=True),
    dict(kind="room_sign"),
    dict(kind="room_sign", lang="en", faint=True),
    dict(kind="hours_sign"),
    dict(kind="hours_sign", lang="en"),
    dict(kind="repair_form", similar=True),
    dict(kind="repair_form", hand_font="hand_note"),
    dict(kind="bin_label"),
    dict(kind="bin_label", lang="en", far=True),
    dict(kind="shipping_label", far=True, shadow=True),
    dict(kind="nameplate", motion=5),
    dict(kind="price_tag", promo=True, far=True),
    dict(kind="repair_form", hand_font="hand_xing"),
    dict(kind="room_sign", glare=True),
]

TYPES = [  # (type name, id prefix, builder, plan)
    ("chat_screenshot", "chat", chat.build, CHAT),
    ("chart_dashboard", "chart", chart.build, CHART),
    ("slide", "slide", slide.build, SLIDE),
    ("whiteboard_handwriting", "board", whiteboard.build, BOARD),
    ("receipt_invoice", "receipt", receipt.build, RECEIPT),
    ("scanned_document", "scan", scan.build, SCAN),
    ("form_label_sign", "label", form.build, LABEL),
]


# --------------------------------------------------------------------------- checks

def _norm(s: str) -> str:
    return re.sub(r"[\s,，]", "", s)


def check_item(item_id: str, r: dict) -> None:
    """Every exact/number QA answer must be readable from the drawn text."""
    blob = _norm("\n".join(r["text_lines"]))
    for qa in r["qa"]:
        a = qa["a"]
        if qa["match"] in ("exact", "contains"):
            if _norm(a) not in blob:
                raise AssertionError(f"{item_id}: exact answer {a!r} not in the drawn text")
        elif qa["match"] == "number":
            for num in re.findall(r"\d+(?:\.\d+)?", a.replace(",", "")):
                if num not in blob and num.rstrip("0").rstrip(".") not in blob:
                    raise AssertionError(f"{item_id}: number {num} of {a!r} not in the drawn text")
    assert r["lang"] in ("zh", "en", "mixed"), r["lang"]
    assert "合成数据" not in "".join(r["text_lines"]), "the synthetic-data mark must not be ground truth"


def assign_splits(groups: list[list[dict]], k: int, seed: str) -> None:
    """Stratified split: k dev items per type, chosen greedily so every hard tag and language has
    roughly 30% of its items in dev (at least one when it has two or more) and the rest in test. Ties
    are broken by a seeded shuffle. Sets entry["split"] in place."""
    rng = random.Random(seed)
    tags = lambda e: set(e["hard"]) | {"lang:" + e["lang"]}  # noqa: E731
    total: dict[str, int] = {}
    for g in groups:
        for e in g:
            for t in tags(e):
                total[t] = total.get(t, 0) + 1
    cap = {t: (max(1, round(0.3 * n)) if n >= 2 else 0) for t, n in total.items()}
    in_dev: dict[str, int] = {}
    for g in groups:
        order = g[:]
        rng.shuffle(order)
        chosen: list[dict] = []
        while len(chosen) < min(k, len(g)):
            def score(e):  # diminishing reward below a tag's cap, a firm penalty above it
                return sum(1 / (1 + in_dev.get(t, 0)) if in_dev.get(t, 0) < cap[t] else -2 for t in tags(e))
            best = max((e for e in order if e not in chosen), key=score)
            chosen.append(best)
            for t in tags(best):
                in_dev[t] = in_dev.get(t, 0) + 1
        for e in g:
            e["split"] = "dev" if e in chosen else "test"


# --------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(HERE), help="output directory (default: next to this script)")
    ap.add_argument("--only", help="generate one type prefix only (chat, chart, slide, board, receipt, scan, label)")
    args = ap.parse_args()
    out = Path(args.out)
    (out / "images").mkdir(parents=True, exist_ok=True)
    (out / "gt").mkdir(parents=True, exist_ok=True)

    from importlib.metadata import version

    entries, groups, built = [], [], {}
    for tname, prefix, build, plan in TYPES:
        if args.only and args.only != prefix:
            continue
        group = []
        for i, variant in enumerate(plan):
            item_id = f"{prefix}-{i:02d}"
            rng = random.Random(f"{VERSION}/{item_id}")
            r = build(i, dict(variant), rng)
            check_item(item_id, r)
            fname = f"{item_id}.{r['ext']}"
            path = out / "images" / fname
            if r["ext"] == "png":
                r["image"].save(path, format="PNG", optimize=True)
            else:
                r["image"].save(path, format="JPEG", quality=r.get("quality") or 80, optimize=True)
            w, h = r["image"].size
            entry = {"id": item_id, "type": tname, "image": f"images/{fname}", "gt": f"gt/{item_id}.json",
                     "lang": r["lang"], "hard": r["hard"], "topic": r["topic"], "width": w, "height": h,
                     "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            group.append(entry)
            built[item_id] = (r, variant)
        groups.append(group)
    assign_splits(groups, DEV_PER_TYPE, f"{VERSION}/split")
    for group in groups:
        for entry in group:
            r, variant = built[entry["id"]]
            gt = {"id": entry["id"], "type": entry["type"], "split": entry["split"], "image": entry["image"],
                  "lang": r["lang"], "hard": r["hard"], "synthetic": True, "image_sha256": entry["sha256"], "gt": r["gt"],
                  "text_lines": r["text_lines"], "qa": r["qa"], "render": r["render"], "variant": variant}
            (out / entry["gt"]).write_text(json.dumps(gt, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
            entries.append(entry)
            print(f"{entry['id']:<11} {entry['split']:<4} {entry['lang']:<5} {entry['width']}x{entry['height']} "
                  f"{','.join(entry['hard'])}")

    counts = {}
    for e in entries:
        c = counts.setdefault(e["type"], {"dev": 0, "test": 0})
        c[e["split"]] += 1
    hard_counts = {}
    for e in entries:
        for t in e["hard"]:
            hard_counts.setdefault(t, {"dev": 0, "test": 0})[e["split"]] += 1
    lang_counts = {}
    for e in entries:
        lang_counts.setdefault(e["lang"], {"dev": 0, "test": 0})[e["split"]] += 1
    manifest = {
        "version": VERSION,
        "description": "Synthetic multimodal eval set: 7 information-bearing image types with ground truth. "
                       "All people, shops, companies, addresses and numbers are invented; every image carries a "
                       "small '合成数据' mark that is not part of the ground truth.",
        "rules": {"dev": "may be used for prompt / pipeline work", "test": "report only; never tune on it"},
        "generator": {"script": "eval/multimodal/generate.py", "python": platform.python_version(),
                      **{pkg: version(pkg) for pkg in ("pillow", "numpy", "matplotlib", "reportlab", "pypdfium2", "fonttools")},
                      "platform": platform.platform(terse=True)},
        "fonts": fonts.describe(fonts.USED | {"hei", "hei_bold", "heiti", "heiti_med", "song", "song_bold"}),
        "counts": {"total": len(entries), "dev": sum(c["dev"] for c in counts.values()),
                   "test": sum(c["test"] for c in counts.values()), "by_type": counts, "by_lang": lang_counts,
                   "by_hard_tag": dict(sorted(hard_counts.items()))},
        "items": entries,
    }
    if not args.only:
        (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(manifest["counts"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
