#!/usr/bin/env python3
"""CHOICE examples: replay each stream in time order with ground-truth events so far (as
eval/retrieval/run_retrieval.py does) and, for every decision unit, ask "which ongoing matter is this?".

Options = the organizer's own top-k candidates (skills/event-assign/scripts/candidates.py, the shipped
fused score, k = 8) over the gold events opened so far, each rendered as a card built only from what the
live system would know about that event at that moment (its member units' snippets, people named in
them, sources, first/last time, size; never a gold title or summary), plus two fixed options:
  NEW   this starts a matter not listed
  NONE  not an ongoing matter / noise
Label: the best-ranked candidate that is one of the unit's gold events ("attach"); NEW when no gold
event is open yet ("new_unopened") or none of the open ones made the top k ("new_missed"); NONE when
the unit has no gold event (noise). Placement after the decision is the oracle's (first open gold event,
else a new event for gold[0]), so every pool is what a perfect assigner would have built.

Splits: TRAIN streams (scale-startup, scale-pm, dev-week-v1, split-dev); VALIDATION = the last ~20% of
each scale TRAIN stream by time (whole days); TEST = scale-lab and holdout-week-v2 (evaluation only).

  python3 eval/system_one/make_choice.py DATA_DIR [--k 8]
Needs DATA_DIR/units.jsonl, embeddings.npy, embed_index.json. Writes choice_{train,val,test}.jsonl and
choice_summary.json.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import random
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("candidates", ROOT / "skills/event-assign/scripts/candidates.py")
candidates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidates)

LETTERS = "ABCDEFGHIJ"
VAL_FRACTION = 0.2
WEEKDAY = "一二三四五六日"
TZ8 = timezone(timedelta(hours=8))


def clip(text: str, n: int) -> str:
    t = re.sub(r"\s+", " ", text or "").strip()
    return t if len(t) <= n else t[: n - 1] + "…"


def when(ts: float) -> str:
    d = datetime.fromtimestamp(ts, TZ8)
    return f"{d:%m-%d} 周{WEEKDAY[d.weekday()]} {d:%H:%M}"


def ago(hours: float) -> str:
    if hours < 1:
        return "不到1小时前"
    if hours < 48:
        return f"{hours:.0f}小时前"
    return f"{hours / 24:.1f}天前"


def source_key(name: str) -> str:
    return (name or "").strip().lower()


def val_cutoff(units: list[dict]) -> float:
    """Start of the day (UTC+8) by which 80% of the stream's units have arrived."""
    ts = sorted(u["ts"] for u in units)
    q = ts[int(len(ts) * (1 - VAL_FRACTION))]
    d = datetime.fromtimestamp(q, TZ8).replace(hour=0, minute=0, second=0, microsecond=0)
    return d.timestamp()


class Event:
    def __init__(self, gold: str, order: int):
        self.gold, self.order = gold, order
        self.members: list[dict] = []
        self.vecs: list[np.ndarray] = []
        self.persons: set = set()
        self.sources: set = set()
        self.first_ts = self.last_ts = None

    def add(self, u: dict, vec: np.ndarray):
        self.members.append(u)
        self.vecs.append(vec)
        self.persons.update(u["voice_persons"])
        self.sources.add(source_key(u["source_app"]))
        self.first_ts = u["ts"] if self.first_ts is None else min(self.first_ts, u["ts"])
        self.last_ts = u["ts"] if self.last_ts is None else max(self.last_ts, u["ts"])
        self._feat = None

    def feature(self) -> dict:
        if self._feat is None:
            c = np.mean(np.stack(self.vecs), axis=0)
            self._feat = {"event_id": self.gold, "order": self.order, "first_ts": self.first_ts,
                          "last_ts": self.last_ts, "person_ids": sorted(self.persons), "sources": sorted(self.sources),
                          "centroid": c.tolist(), "centroid_norm": float(np.linalg.norm(c))}
        return self._feat

    def card(self, now: float) -> dict:
        people = Counter()
        for m in self.members:
            people.update(set(m["text_speakers"]) | set(m["voice_labels"]))
        srcs = Counter(m["source_app"] for m in self.members)
        snippets = []
        picks = [self.members[0]] + self.members[-2:] if len(self.members) > 3 else list(self.members)
        seen = set()
        for m in picks:
            if m["unit_id"] in seen:
                continue
            seen.add(m["unit_id"])
            snippets.append({"when": when(m["ts"]), "source_app": m["source_app"],
                             "text": clip(m["text"], 90 if m is self.members[0] else 120)})
        return {"n_items": len(self.members), "first_seen": when(self.first_ts), "last_seen": when(self.last_ts),
                "last_seen_ago": ago((now - self.last_ts) / 3600.0),
                "sources": [s for s, _ in srcs.most_common(3)], "people": [p for p, _ in people.most_common(5)],
                "snippets": snippets}


def render_prompt(q: dict, options: list[dict]) -> str:
    seg = f"（这条素材里的第{q['segment_index'] + 1}段，共{q['n_segments']}段）" if q["segment_index"] is not None else ""
    lines = ["新素材" + seg + "：",
             f"时间：{q['when']}　来源：{q['source_app']}　类型：{q['kind']}",
             f"提到的人：{'、'.join(q['people']) or '无'}",
             f"内容：{q['text']}", "", "正在进行的事情（按检索相关度排序）："]
    for o in options:
        if o["key"] in ("NEW", "NONE"):
            continue
        c = o["card"]
        lines.append(f"[{o['key']}] 共{c['n_items']}条，{c['first_seen']} 至 {c['last_seen']}（{c['last_seen_ago']}）"
                     f"；来源：{'、'.join(c['sources'])}；人：{'、'.join(c['people']) or '无'}")
        for s in c["snippets"]:
            lines.append(f"    - {s['when']} {s['source_app']}：{s['text']}")
    lines.append("[NEW] 这是一件上面没有列出的新事情")
    lines.append("[NONE] 不是一件正在进行的事（闲聊、噪声）")
    lines.append("")
    lines.append("这条素材属于哪一项？只回答选项代号。")
    return "\n".join(lines)


def replay(units: list[dict], emb: np.ndarray, index: dict, k: int, cutoff: float | None) -> list[dict]:
    events: dict[str, Event] = {}
    out = []
    for u in sorted(units, key=lambda u: (u["ts"], u["item_order"], u["segment_index"] or 0)):
        vec = emb[index[u["unit_id"]]]
        feats = [e.feature() for e in events.values()]
        item = {"embedding": vec.tolist(), "ts": u["ts"], "person_ids": u["voice_persons"],
                "source": source_key(u["source_app"])}
        full = candidates.rank_candidates(item, feats, (), 10 ** 6) if feats else []
        order = [c["event_id"] for c in full]
        top = full[:k]
        gold = u["gold"]
        gold_open = [g for g in gold if g in events]
        gold_rank = min((order.index(g) for g in gold_open), default=None)
        if not gold:
            label, reason = "NONE", "noise"
        elif not gold_open:
            label, reason = "NEW", "new_unopened"
        elif gold_rank is not None and gold_rank < k:
            label, reason = LETTERS[gold_rank], "attach"
        else:
            label, reason = "NEW", "new_missed"
        options = []
        for i, c in enumerate(top):
            options.append({"key": LETTERS[i], "event_ref": c["event_id"], "card": events[c["event_id"]].card(u["ts"]),
                            "retrieval": {kk: c[kk] for kk in ("score", "similarity", "time", "same_source")}
                            | {"shared_persons": len(c["shared_persons"])}})
        options += [{"key": "NEW"}, {"key": "NONE"}]
        q = {"when": when(u["ts"]), "t": u["t"], "source_app": u["source_app"], "kind": u["kind"],
             "people": list(dict.fromkeys(u["voice_labels"] + u["text_speakers"])),
             "text": clip(u["text"], 800), "segment_index": u["segment_index"], "n_segments": u["n_segments"]}
        split = "test" if u["role"] == "test" else ("val" if cutoff is not None and u["ts"] >= cutoff else "train")
        ex = {"id": f"{u['stream']}:{u['unit_id']}", "stream": u["stream"], "split": split, "ref": u["ref"],
              "unit_id": u["unit_id"], "query": q, "options": options, "label": label, "label_reason": reason,
              "gold_events": gold, "gold_open": gold_open, "gold_rank": gold_rank, "pool_size": len(full),
              "tags": u["tags"], "text_source": u["text_source"]}
        ex["prompt"] = render_prompt(q, options)
        out.append(ex)
        # oracle placement
        if gold:
            tgt = gold_open[0] if gold_open else gold[0]
            if tgt not in events:
                events[tgt] = Event(tgt, len(events) + 1)
            events[tgt].add(u, vec)
    return out


def summarize(rows: list[dict], k: int) -> dict:
    lab = Counter("CAND" if r["label"] in LETTERS else r["label"] for r in rows)
    pos = Counter(r["label"] for r in rows if r["label"] in LETTERS)
    reasons = Counter(r["label_reason"] for r in rows)
    open_rows = [r for r in rows if r["gold_open"]]
    rec = lambda kk: round(sum(1 for r in open_rows if r["gold_rank"] is not None and r["gold_rank"] < kk)
                           / len(open_rows), 4) if open_rows else None
    return {"n": len(rows), "labels": dict(lab), "candidate_position": dict(sorted(pos.items())),
            "label_reason": dict(reasons),
            "oracle_recall": {"n_with_open_gold": len(open_rows), "@1": rec(1), "@5": rec(5), f"@{k}": rec(k)},
            "mean_pool": round(sum(r["pool_size"] for r in rows) / max(1, len(rows)), 2),
            "mean_options": round(sum(len(r["options"]) for r in rows) / max(1, len(rows)), 2)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--k", type=int, default=8)
    args = ap.parse_args()
    data = Path(args.data)
    units = [json.loads(l) for l in open(data / "units.jsonl", encoding="utf-8")]
    emb = np.load(data / "embeddings.npy")
    meta = json.loads((data / "embed_index.json").read_text())
    by_stream = defaultdict(list)
    for u in units:
        by_stream[u["stream"]].append(u)
    rows_all = []
    cutoffs = {}
    for stream, us in by_stream.items():
        cut = val_cutoff(us) if (us[0]["role"] == "train" and stream.startswith("scale-")) else None
        cutoffs[stream] = datetime.fromtimestamp(cut, TZ8).isoformat() if cut else None
        rows_all += replay(us, emb, meta["index"], args.k, cut)
    summary = {"k": args.k, "embed_model": meta["model"], "val_cutoffs": cutoffs, "splits": {}, "streams": {}}
    for split in ("train", "val", "test"):
        rows = [r for r in rows_all if r["split"] == split]
        with open(data / f"choice_{split}.jsonl", "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        summary["splits"][split] = summarize(rows, args.k)
    for (stream, split) in sorted({(r["stream"], r["split"]) for r in rows_all}):
        summary["streams"][f"{stream}/{split}"] = summarize(
            [r for r in rows_all if r["stream"] == stream and r["split"] == split], args.k)
    (data / "choice_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
