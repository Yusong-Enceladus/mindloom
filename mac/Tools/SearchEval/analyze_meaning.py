#!/usr/bin/env python3
"""Scores saved MeaningEvalCLI runs (v12 search, HIST-009): the tables, intervals
and breakdowns in IMPLEMENTATION_STATUS.md 「search by meaning」.

Reads a query set and the rankings `MeaningEvalCLI eval --out` saved (record IDs
and similarities only) and prints numbers, category names and query counts only:
never a query, a record or an ID, so it may run on a private set.

    analyze_meaning.py --set SET --run qwen=RUN.json@0.75 [--run e5=RUN.json@0.87 ...] COMMAND

Commands:
  table             characters, meaning alone and combined, per category
  compare A B       paired bootstrap of nDCG@10 and R@10 (A minus B), overall, per
                    category and by kind of query; A and B are NAME:SYSTEM with
                    SYSTEM chars | meaning | combined
  floors NAME F,..  combined at several floors; records shown for queries with no answer
  heldout NAME F,.. the floor chosen on half the queries and scored on the other half
  screen NAME       the first screen (top 10): rows found only by meaning and how many
                    are relevant; relevant records that move in or out against characters
  auc NAME          how well similarity separates relevant from other records in the
                    meaning side's top 10, every query (area under the ROC curve)

Definitions (the same as MeaningEvalCLI): averages over queries that have an
answer; R@10 = relevant in the top 10 / min(10, relevant); nDCG@10 with gain
2^grade - 1; MRR = 1 / rank of the first record of the query's highest grade
(within 100). Combining is MeaningFusion.fuse: reciprocal rank (k 60, first 100 of
each), three tiers (every word; found by meaning; only some words).
"""
import argparse
import json
import math
import random
import re
import sys

SEED = 20261006
RESAMPLES = 10_000


def fuse(lexical, partial, meaning, similarity, floor, k=60.0, depth=100):
    found = [(i, s) for i, s in zip(meaning, similarity) if s >= floor][:depth]
    score, order, first_partial, whole = {}, [], {}, set()
    for rank, (i, p) in enumerate(zip(lexical, partial)):
        if i not in first_partial:
            first_partial[i] = p
            order.append(i)
        if not p:
            whole.add(i)
        if rank < depth:
            score[i] = score.get(i, 0) + 1 / (k + rank + 1)
    by_meaning = set()
    for rank, (i, _) in enumerate(found):
        if i in by_meaning:
            continue
        by_meaning.add(i)
        if i not in first_partial:
            order.append(i)
        score[i] = score.get(i, 0) + 1 / (k + rank + 1)
    position = {i: n for n, i in enumerate(order)}

    def tier(i):
        if i in whole:
            return 0
        return 1 if i in by_meaning else 2

    return sorted(order, key=lambda i: (tier(i), -score.get(i, 0), position[i]))


def ranked(run, system, floor):
    if system == "chars":
        return run["lexical"]
    if system == "meaning":
        return [i for i, s in zip(run["meaning"], run["similarity"]) if s >= floor]
    if not run["meaning"]:
        return run["lexical"]
    return fuse(run["lexical"], run["lexicalPartial"], run["meaning"], run["similarity"], floor)


def gains_of(query):
    if query.get("graded") is not None:
        return {k.upper(): v for k, v in query["graded"].items()}
    return {k.upper(): 1 for k in query.get("relevant", [])}


def metrics(order, gains):
    top = order[:10]
    relevant = {i: g for i, g in gains.items() if g > 0}
    if not relevant:
        return None
    hits = sum(1 for i in top if i in relevant)
    dcg = sum((2 ** gains.get(i, 0) - 1) / math.log2(n + 2) for n, i in enumerate(top))
    ideal = sum(
        (2 ** g - 1) / math.log2(n + 2)
        for n, g in enumerate(sorted(relevant.values(), reverse=True)[:10]))
    best = max(relevant.values())
    first = next((n for n, i in enumerate(order[:100]) if gains.get(i, 0) >= best), None)
    return {
        "r10": hits / min(10, len(relevant)),
        "ndcg": dcg / ideal if ideal else 0.0,
        "mrr": 1 / (first + 1) if first is not None else 0.0,
        "empty": int(not order),
    }


def mean(values):
    return sum(values) / len(values) if values else 0.0


def bootstrap(differences):
    rnd = random.Random(SEED)
    n = len(differences)
    means = sorted(
        sum(differences[rnd.randrange(n)] for _ in range(n)) / n for _ in range(RESAMPLES))
    return mean(differences), means[int(RESAMPLES * 0.025) - 1], means[int(RESAMPLES * 0.975) - 1]


class Data:
    def __init__(self, set_path, runs):
        loaded = json.load(open(set_path))
        self.queries = loaded["queries"]
        self.categories = []
        for query in self.queries:
            if query["category"] not in self.categories:
                self.categories.append(query["category"])
        self.runs = {}
        self.floors = {}
        for spec in runs:
            name, rest = spec.split("=", 1)
            path, _, floor = rest.rpartition("@")
            self.runs[name] = {r["id"]: r for r in json.load(open(path))}
            self.floors[name] = float(floor)

    def answerable(self):
        return [q for q in self.queries if metrics([], gains_of(q)) is not None]

    def score(self, name, system, queries, floor=None):
        floor = self.floors[name] if floor is None else floor
        out = {}
        for query in queries:
            run = self.runs[name].get(query["id"])
            if run is None:
                continue
            value = metrics(ranked(run, system, floor), gains_of(query))
            if value is not None:
                out[query["id"]] = value
        return out


def line(label, scores, n_label=None):
    values = list(scores.values())
    return (
        f"  {label:<14} n {len(values):>3}  R@10 {mean([v['r10'] for v in values]):.3f}"
        f"  nDCG@10 {mean([v['ndcg'] for v in values]):.3f}"
        f"  MRR {mean([v['mrr'] for v in values]):.3f}"
        f"  empty {sum(v['empty'] for v in values)}")


def unanswered_shown(data, name, system, floor=None):
    floor = data.floors[name] if floor is None else floor
    shown = []
    for query in data.queries:
        if metrics([], gains_of(query)) is None and query["id"] in data.runs[name]:
            shown.append(len(ranked(data.runs[name][query["id"]], system, floor)[:10]))
    return len(shown), mean(shown)


def table(data, _):
    first = next(iter(data.runs))
    for name, system in [(first, "chars")] + [
            (n, s) for n in data.runs for s in ("meaning", "combined")]:
        label = "characters" if system == "chars" else f"{name} {system} @ {data.floors[name]}"
        print(label)
        for category in data.categories:
            queries = [q for q in data.queries if q["category"] == category]
            scores = data.score(name, system, queries)
            if scores:
                print(line(category, scores))
        print(line("all", data.score(name, system, data.queries)))
        count, shown = unanswered_shown(data, name, system)
        if count:
            print(f"  no answer      n {count:>3}  first screen shows {shown:.1f} records")


def slices(data):
    has_digit = lambda q: bool(re.search(r"[0-9]", q["query"]))
    has_latin = lambda q: bool(re.search(r"[A-Za-z]", q["query"]))
    out = [("all", lambda q: True)]
    out += [(f"category {c}", (lambda c: lambda q: q["category"] == c)(c)) for c in data.categories]
    out += [(f"without {c}", (lambda c: lambda q: q["category"] != c)(c)) for c in data.categories]
    out += [("with a digit", has_digit), ("with Latin letters", has_latin),
            ("Chinese only", lambda q: not has_digit(q) and not has_latin(q))]
    return out


def compare(data, args):
    a_name, a_system = args.a.split(":")
    b_name, b_system = args.b.split(":")
    a = data.score(a_name, a_system, data.queries)
    b = data.score(b_name, b_system, data.queries)
    print(f"{a_name}:{a_system} minus {b_name}:{b_system} (paired bootstrap, {RESAMPLES} resamples, 95%)")
    for label, keep in slices(data):
        ids = [q["id"] for q in data.queries if keep(q) and q["id"] in a and q["id"] in b]
        if len(ids) < 2:
            continue
        parts = []
        for key, title in (("ndcg", "nDCG@10"), ("r10", "R@10")):
            differences = [a[i][key] - b[i][key] for i in ids]
            d, low, high = bootstrap(differences)
            parts.append(f"{title} {d:+.3f} [{low:+.3f}, {high:+.3f}]")
        differences = [a[i]["ndcg"] - b[i]["ndcg"] for i in ids]
        better = sum(1 for x in differences if x > 1e-9)
        worse = sum(1 for x in differences if x < -1e-9)
        print(f"  {label:<26} n {len(ids):>3}  {'  '.join(parts)}  better {better} worse {worse}")


def floors(data, args):
    name = args.name
    for floor in [float(x) for x in args.floors.split(",")]:
        scores = data.score(name, "combined", data.queries, floor)
        count, shown = unanswered_shown(data, name, "combined", floor)
        meaning_count, meaning_shown = unanswered_shown(data, name, "meaning", floor)
        print(
            f"  floor {floor:.2f}  nDCG@10 {mean([v['ndcg'] for v in scores.values()]):.3f}"
            f"  R@10 {mean([v['r10'] for v in scores.values()]):.3f}"
            f"  no answer (n {count}): combined shows {shown:.1f}, meaning alone {meaning_shown:.1f}")


def heldout(data, args):
    name = args.name
    candidates = [float(x) for x in args.floors.split(",")]
    answerable = data.answerable()
    chars = data.score(name, "chars", answerable)
    by_floor = {f: data.score(name, "combined", answerable, f) for f in candidates}
    ids = [q["id"] for q in answerable]
    rnd = random.Random(SEED)
    gains, chosen = [], {}
    splits = 1_000
    for _ in range(splits):
        shuffled = ids[:]
        rnd.shuffle(shuffled)
        tune, test = shuffled[: len(ids) // 2], shuffled[len(ids) // 2:]
        best = max(candidates, key=lambda f: (mean([by_floor[f][i]["ndcg"] for i in tune]), -f))
        chosen[best] = chosen.get(best, 0) + 1
        gains.append(mean([by_floor[best][i]["ndcg"] - chars[i]["ndcg"] for i in test]))
    gains.sort()
    print(
        f"  {splits} random halves: floor chosen on one half, nDCG@10 gain over characters on"
        f" the other: mean {mean(gains):+.3f}, 95% of splits in"
        f" [{gains[int(splits * 0.025)]:+.3f}, {gains[int(splits * 0.975) - 1]:+.3f}]")
    print("  floors chosen: " + ", ".join(f"{f:.2f} x{c}" for f, c in sorted(chosen.items())))
    fixed = data.floors[name]
    print(
        f"  the shipped floor {fixed:.2f} on all answerable queries: nDCG@10 gain"
        f" {mean([data.score(name, 'combined', answerable)[i]['ndcg'] - chars[i]['ndcg'] for i in ids]):+.3f}")


def screen(data, args):
    name = args.name
    floor = data.floors[name]
    queries_with, rows, relevant_rows = 0, 0, 0
    out_whole, out_partial, entered, out_queries = 0, 0, 0, set()
    for query in data.answerable():
        run = data.runs[name].get(query["id"])
        if run is None:
            continue
        gains = gains_of(query)
        chars = run["lexical"][:10]
        combined = ranked(run, "combined", floor)[:10]
        lexical = set(run["lexical"])
        only_meaning = [i for i in combined if i not in lexical]
        if only_meaning:
            queries_with += 1
        rows += len(only_meaning)
        relevant_rows += sum(1 for i in only_meaning if gains.get(i, 0) > 0)
        partial = {}
        for i, p in zip(run["lexical"], run["lexicalPartial"]):
            partial.setdefault(i, p)
        for i in chars:
            if gains.get(i, 0) > 0 and i not in combined:
                out_queries.add(query["id"])
                if partial.get(i):
                    out_partial += 1
                else:
                    out_whole += 1
        entered += sum(1 for i in combined if gains.get(i, 0) > 0 and i not in chars)
    print(
        f"  first screen rows found only by meaning: {rows} on {queries_with} queries;"
        f" relevant {relevant_rows} ({relevant_rows / max(1, rows):.0%})")
    print(
        f"  relevant records in the characters' top 10 that leave the combined top 10:"
        f" {out_whole} holding every word, {out_partial} holding some words, on {len(out_queries)} queries")
    print(f"  relevant records that enter the combined top 10: {entered}")


def auc(data, args):
    name = args.name
    related, other = [], []
    for query in data.queries:
        run = data.runs[name].get(query["id"])
        if run is None:
            continue
        gains = gains_of(query)
        for i, s in list(zip(run["meaning"], run["similarity"]))[:10]:
            (related if gains.get(i, 0) > 0 else other).append(s)
    pairs = len(related) * len(other)
    if not pairs:
        print("  no pairs")
        return
    combined = sorted([(s, 1) for s in related] + [(s, 0) for s in other])
    rank_sum, n, index = 0.0, len(combined), 0
    while index < n:
        end = index
        while end + 1 < n and combined[end + 1][0] == combined[index][0]:
            end += 1
        average = (index + end) / 2 + 1
        rank_sum += average * sum(1 for j in range(index, end + 1) if combined[j][1] == 1)
        index = end + 1
    value = (rank_sum - len(related) * (len(related) + 1) / 2) / pairs
    print(f"  AUC {value:.3f} (relevant {len(related)}, other {len(other)})")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--set", required=True)
    parser.add_argument("--run", action="append", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("table")
    p = sub.add_parser("compare")
    p.add_argument("a")
    p.add_argument("b")
    for command in ("floors", "heldout"):
        p = sub.add_parser(command)
        p.add_argument("name")
        p.add_argument("floors")
    for command in ("screen", "auc"):
        p = sub.add_parser(command)
        p.add_argument("name")
    args = parser.parse_args()
    data = Data(args.set, args.run)
    {"table": table, "compare": compare, "floors": floors, "heldout": heldout,
     "screen": screen, "auc": auc}[args.command](data, args)


if __name__ == "__main__":
    sys.exit(main())
