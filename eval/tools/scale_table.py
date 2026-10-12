#!/usr/bin/env python3
"""One table over scale_run.py output directories (score.json + runtime.json each); several runs of the same
code/scenario are listed and averaged.

  python3 eval/tools/scale_table.py runs/lab-base-r1 runs/lab-base-r2 runs/lab-fixed1-r1 ...

Columns: events (pred/true, x truth), singletons, B3 P / R / F1, Link F1, hard / easy decoy leakage, noise in a real
event, real items left unfiled, model calls, input / output tokens, minutes. A run without score.json (not finished)
is skipped with a note.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path):
    score, runtime = path / "score.json", path / "runtime.json"
    if not score.exists() or not runtime.exists():
        print(f"# {path.name}: not finished", file=sys.stderr)
        return None
    s = json.loads(score.read_text(encoding="utf-8"))
    r = json.loads(runtime.read_text(encoding="utf-8"))
    cfg = json.loads((path / "config.json").read_text(encoding="utf-8")) if (path / "config.json").exists() else {}
    clus = s["final"]["clustering"]
    sm = s["summary"]
    singles = clus["pred_event_count"] - clus["pred_event_count_multi_item"]
    return {"name": path.name, "tag": cfg.get("tag", ""), "git": cfg.get("git", ""), "pred": sm["pred_event_count"],
            "true": sm["gold_event_count"], "singletons": singles, "bp": sm["bcubed_precision"], "br": sm["bcubed_recall"],
            "bf": sm["bcubed_f1"], "lf": sm["link_f1"], "hard": sm["hard_decoy_leakage"], "easy": sm["easy_decoy_leakage"],
            "nir": sm["noise_in_real_event_rate"], "fu": sm["false_unfiled"], "calls": r["model_calls"],
            "pin": r["prompt_tokens"], "pout": r["completion_tokens"], "min": r["seconds"] / 60}


def f(x, n=3):
    return "-" if x is None else f"{x:.{n}f}"


def main(argv) -> int:
    rows = [r for r in (load(Path(p)) for p in argv) if r]
    print("| run | tag | events pred/true | x | singletons | B3 P | B3 R | B3 F1 | Link F1 | hard / easy leak | noise in real | false unfiled | calls | input M | output M | min |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['name']} | {r['tag']} | {r['pred']}/{r['true']} | {r['pred'] / r['true']:.2f} | {r['singletons']} | "
              f"{f(r['bp'])} | {f(r['br'])} | **{f(r['bf'])}** | {f(r['lf'])} | {f(r['hard'])} / {f(r['easy'])} | {f(r['nir'])} | "
              f"{r['fu']} | {r['calls']} | {r['pin'] / 1e6:.1f} | {r['pout'] / 1e6:.2f} | {r['min']:.0f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
