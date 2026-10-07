#!/usr/bin/env python3
"""A blind check of the private real set's judgments (v12 search, review fix).

The private real set's queries and grades were written by the implementing agent,
from sampled records, on excerpts of at most 125 characters. Before its numbers
count as established, the owner grades a random sample of the pooled query-record
pairs, seeing each record in full and not knowing which search found it; `score`
then reports how far the owner's grades agree with the agent's and what the
first-screen numbers become under the owner's grades.

    blind_grading.py make  --set SET --judged JUDGED --pool POOL --run RUN@FLOOR --dir DIR [--n 150]
    blind_grading.py score --dir DIR

`make` writes, only inside ~/.mindloom-private-eval (files 0600):
  DIR/待判断.csv     one row per pair, in random order: number, query, date, source,
                     the record's text, an empty column for the grade
  DIR/判断说明.txt   what the grades mean
  DIR/key.json       which pair each number is, the agent's grade, and which
                     searches put the record on the first screen (not to be opened
                     while grading)
`score` prints numbers only (agreement, kappa, first-screen precision by search),
never a query or a record.
"""
import argparse
import csv
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_meaning import gains_of, ranked  # noqa: E402

PRIVATE = os.path.realpath(os.path.expanduser("~/.mindloom-private-eval"))
GRADE_COLUMN = "判断（0 无关 / 1 相关 / 2 正是要找的）"
CELL_LIMIT = 30_000


def private_dir(path):
    real = os.path.realpath(path)
    if not (real + "/").startswith(PRIVATE + "/"):
        sys.exit("refusing: the sample holds private text and lives only in ~/.mindloom-private-eval")
    os.makedirs(real, mode=0o700, exist_ok=True)
    os.chmod(real, 0o700)
    return real


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8-sig" if path.endswith(".csv") else "utf-8") as f:
        f.write(text)
    os.chmod(path, 0o600)


def make(args):
    directory = private_dir(args.dir)
    queries = {q["id"]: q for q in json.load(open(args.set))["queries"]}
    judged = json.load(open(args.judged))
    pool = json.load(open(args.pool))
    path, _, floor = args.run.rpartition("@")
    runs = {r["id"]: r for r in json.load(open(path))}
    first = {}
    for query_id, run in runs.items():
        first[query_id] = (set(ranked(run, "chars", 0)[:10]),
                           set(ranked(run, "combined", float(floor))[:10]))
    strata = {}
    seen = set()
    for pair in pool:
        query_id, record_id = pair["query"], pair["id"].upper()
        grade = {k.upper(): v for k, v in judged.get(query_id, {}).items()}.get(record_id)
        if grade is None or (query_id, record_id) in seen or query_id not in first:
            continue
        seen.add((query_id, record_id))
        chars, combined = first[query_id]
        where = ("both" if record_id in chars and record_id in combined
                 else "characters" if record_id in chars
                 else "combined" if record_id in combined else "other")
        strata.setdefault((where, min(grade, 2)), []).append((pair, grade, where))
    rnd = random.Random(args.seed)
    keys = sorted(strata)
    share = max(1, args.n // len(keys))
    chosen = []
    for key in keys:
        group = strata[key][:]
        rnd.shuffle(group)
        chosen += group[:share]
    rnd.shuffle(chosen)
    rows, key_out = [], {}
    for number, (pair, grade, where) in enumerate(chosen, start=1):
        text = pair["text"]
        if len(text) > CELL_LIMIT:
            text = text[:CELL_LIMIT] + f"……（后面还有 {len(text) - CELL_LIMIT} 字，略）"
        rows.append([number, queries[pair["query"]]["query"], pair["date"][:10], pair["source"],
                     text, ""])
        key_out[str(number)] = {"query": pair["query"], "record": pair["id"].upper(),
                                "agent": grade, "first_screen": where}
    out = []
    buffer = _Lines(out)
    writer = csv.writer(buffer)
    writer.writerow(["编号", "搜索词", "记录日期", "来源", "记录全文", GRADE_COLUMN])
    writer.writerows(rows)
    write_private(os.path.join(directory, "待判断.csv"), "".join(out))
    write_private(os.path.join(directory, "key.json"), json.dumps(key_out, ensure_ascii=False))
    write_private(os.path.join(directory, "判断说明.txt"), INSTRUCTIONS)
    counts = {}
    for _, grade, where in chosen:
        counts[(where, min(grade, 2))] = counts.get((where, min(grade, 2)), 0) + 1
    print(f"sample: {len(chosen)} pairs from {len(seen)} judged pairs; per stratum "
          + ", ".join(f"{w}/{g}: {c}" for (w, g), c in sorted(counts.items())))


class _Lines:
    def __init__(self, out):
        self.out = out

    def write(self, text):
        self.out.append(text)


INSTRUCTIONS = """按意思搜索的评测：请你判断

文件「待判断.csv」里每一行是一次搜索和一条记录。请只看「搜索词」和「记录全文」，
在最后一列填一个数字：

  0  无关：搜这句话时，不想看到这条记录
  1  相关：和要找的有关，看到它不嫌多余
  2  正是要找的：搜这句话就是为了找它（或者和它同样要紧的）

不用管这条记录是怎么被找到的，表里也没有写。key.json 记着每一行的来历，判完之前请不要打开。
可以只判一部分：没填的行不计入。判完保存（仍用 CSV 格式），告诉 Claude 即可。
"""


def score(args):
    directory = private_dir(args.dir)
    key = json.load(open(os.path.join(directory, "key.json")))
    with open(os.path.join(directory, "待判断.csv"), encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        header = next(reader)
        grade_at = len(header) - 1
        owner = {}
        for row in reader:
            if len(row) > grade_at and row[grade_at].strip() in ("0", "1", "2"):
                owner[row[0].strip()] = int(row[grade_at].strip())
    pairs = [(key[n]["agent"], g, key[n]["first_screen"]) for n, g in owner.items() if n in key]
    if not pairs:
        print("no grades yet")
        return
    n = len(pairs)
    exact = sum(1 for a, o, _ in pairs if min(a, 2) == o) / n
    binary = sum(1 for a, o, _ in pairs if (a > 0) == (o > 0)) / n
    print(f"graded {n} of {len(key)}; same grade {exact:.0%}; same relevant/not {binary:.0%}")
    print(f"  Cohen's kappa (relevant or not) {kappa([(int(a > 0), int(o > 0)) for a, o, _ in pairs], 2):.2f};"
          f" weighted kappa (0/1/2) {kappa([(min(a, 2), o) for a, o, _ in pairs], 3, weighted=True):.2f}")
    matrix = [[0] * 3 for _ in range(3)]
    for a, o, _ in pairs:
        matrix[min(a, 2)][o] += 1
    print("  agent grade (rows) against owner grade (columns): "
          + "; ".join(f"{r}: " + " ".join(str(x) for x in matrix[r]) for r in range(3)))
    for where in ("characters", "combined", "both", "other"):
        group = [(a, o) for a, o, w in pairs if w == where]
        if group:
            print(f"  first screen {where:<10} n {len(group):>3}: relevant by the agent"
                  f" {sum(1 for a, _ in group if a > 0) / len(group):.0%}, by the owner"
                  f" {sum(1 for _, o in group if o > 0) / len(group):.0%}")


def kappa(pairs, levels, weighted=False):
    n = len(pairs)
    observed = [[0.0] * levels for _ in range(levels)]
    for a, b in pairs:
        observed[a][b] += 1 / n
    rows = [sum(observed[i]) for i in range(levels)]
    cols = [sum(observed[i][j] for i in range(levels)) for j in range(levels)]

    def weight(i, j):
        if not weighted:
            return 0.0 if i == j else 1.0
        return ((i - j) / (levels - 1)) ** 2

    disagree = sum(weight(i, j) * observed[i][j] for i in range(levels) for j in range(levels))
    chance = sum(weight(i, j) * rows[i] * cols[j] for i in range(levels) for j in range(levels))
    return 1 - disagree / chance if chance else 1.0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("make")
    for name in ("--set", "--judged", "--pool", "--run", "--dir"):
        p.add_argument(name, required=True)
    p.add_argument("--n", type=int, default=150)
    p.add_argument("--seed", type=int, default=20261006)
    p = sub.add_parser("score")
    p.add_argument("--dir", required=True)
    args = parser.parse_args()
    {"make": make, "score": score}[args.command](args)


if __name__ == "__main__":
    main()
