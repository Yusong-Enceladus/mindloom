"""One table for every System One / System Two candidate, all calibrated on VALIDATION only.

For each model: calibrate on val (temperature; Laya: one per option-count bucket), pick tau on val for
>= 97% precision, then freeze and apply to TEST (scale-lab + holdout-week-v2, never used for training or
calibration) and to the 300-decision TEST sample System Two ran on.

Inputs (whichever exist):
  runs/r1/scores_{val,test}.jsonl + head.json + feature_model.json     reranker (candidate B)
  runs/laya_zs/scores_{val,test}.jsonl                                 Laya zero-shot
  runs/laya_ft/scores_{val,test}.jsonl                                 Laya fine-tuned (candidate A)
  runs/s2/s2_logprob{_val,}.jsonl, s2_skill.jsonl, sample_ids.json      System Two (LLM)
  runs/*/latency.json                                                  p50/p90 per decision on GB10

  python report_s1.py --runs ../runs --data ../data --out ../runs/report
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from laya_calibrate import apply_T, apply_tau, coverage_curve, fit_T, fit_buckets, metrics, pick_tau  # noqa
from s1_common import choice_features, load_jsonl  # noqa: E402

TARGET = 0.97


def softmax(z):
    z = np.asarray(z, float)
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


def load(p):
    return load_jsonl(p) if os.path.exists(p) else None


def summarize(P, G, tau):
    m, conf, corr = metrics(P, G)
    rel = m.pop("reliability")
    m["fast"] = apply_tau(conf, corr, tau)
    return m, rel, conf, corr


def fit_Tb(z, y):
    grid = np.exp(np.linspace(np.log(0.05), np.log(20), 200))

    def nll(T, b):
        p = 1 / (1 + np.exp(-(z / T + b)))
        return -np.mean(y * np.log(p + 1e-12) + (1 - y) * np.log(1 - p + 1e-12))
    T = float(min(grid, key=lambda t: nll(t, 0.0)))
    b = float(min(np.linspace(-6, 6, 241), key=lambda bb: nll(T, bb)))
    return T, b


def merge_metrics(z, y, target=TARGET):
    n = len(y)
    rng = np.random.RandomState(0)
    fold = rng.permutation(n) % 2
    p = np.empty(n)
    for f in (0, 1):
        T, b = fit_Tb(z[fold != f], y[fold != f])
        p[fold == f] = 1 / (1 + np.exp(-(z[fold == f] / T + b)))
    T, b = fit_Tb(z, y)  # served parameters (all of val)
    pred = (p >= 0.5).astype(float)
    conf = np.maximum(p, 1 - p)
    corr = (pred == y).astype(float)
    edges = np.linspace(0, 1, 16)
    ece = 0.0
    for i in range(15):
        m = (conf > edges[i]) & (conf <= edges[i + 1]) if i else (conf <= edges[1])
        if m.sum():
            ece += m.mean() * abs(conf[m].mean() - corr[m].mean())
    o = np.argsort(p)
    ranks = np.empty(n)
    ranks[o] = np.arange(1, n + 1)
    npos, nneg = (y == 1).sum(), (y == 0).sum()
    auc = (ranks[y == 1].sum() - npos * (npos + 1) / 2) / max(npos * nneg, 1)
    os_ = np.argsort(-p)
    cp = np.cumsum(y[os_]) / np.arange(1, n + 1)
    ok = np.where(cp >= target)[0]
    thr = float(p[os_][ok[-1]]) if len(ok) else 1.01
    # decide both ways: merge if p >= thr, keep apart if p <= lo (>= 97% precision on "different")
    cn = np.cumsum(1 - y[o]) / np.arange(1, n + 1)
    okn = np.where(cn >= target)[0]
    lo = float(p[o][okn[-1]]) if len(okn) else -0.01
    decided = (p >= thr) | (p <= lo)
    return {"n": int(n), "positives": int(npos), "accuracy": float(corr.mean()), "ece15": float(ece),
            "brier": float(np.mean((p - y) ** 2)), "auc": float(auc), "temperature": T, "bias": b,
            "merge_threshold_97": thr, "merge_recall_at_97": float(((p >= thr) & (y == 1)).sum() / max(npos, 1)),
            "apart_threshold_97": lo, "fast_coverage_both_ways": float(decided.mean())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    R, D = args.runs, args.data
    os.makedirs(args.out, exist_ok=True)
    val = {r["id"]: r for r in load_jsonl(f"{D}/choice_val.jsonl")}
    test = {r["id"]: r for r in load_jsonl(f"{D}/choice_test.jsonl")}
    sample = set(json.load(open(f"{R}/s2/sample_ids.json"))) if os.path.exists(f"{R}/s2/sample_ids.json") else set()
    models = {}  # name -> {"val": (P, G, ids), "test": (P, G, ids), "cal": ...}

    def top1(rows):
        G = [r["options"].index(next(o for o in r["options"] if o["key"] == r["label"])) for r in rows]
        P = []
        for r in rows:
            p = np.full(len(r["options"]), 1e-6)
            keys = [o["key"] for o in r["options"]]
            p[0 if any(k not in ("NEW", "NONE") for k in keys) else keys.index("NEW")] = 1.0
            P.append(p / p.sum())
        return P, G, [r["id"] for r in rows]

    vrows, trows = list(val.values()), list(test.values())
    models["retrieval top-1 (no model)"] = {"val": top1(vrows), "test": top1(trows), "cal": "none"}

    # feature-only conditional logit (TRAIN-fitted in calibrate_s1.py)
    fm = f"{R}/r1/feature_model.json"
    if os.path.exists(fm):
        w = np.array(json.load(open(fm))["w"])

        def feat(rows):
            Z = [np.array(choice_features(r)) @ w for r in rows]
            G = [r["options"].index(next(o for o in r["options"] if o["key"] == r["label"])) for r in rows]
            return Z, G, [r["id"] for r in rows]
        Zv, Gv, Iv = feat(vrows)
        Zt, Gt, It = feat(trows)
        grid = np.exp(np.linspace(np.log(0.05), np.log(20), 300))
        T = float(min(grid, key=lambda t: np.mean([-np.log(max(softmax(z / t)[k], 1e-12)) for z, k in zip(Zv, Gv)])))
        models["retrieval features, logistic"] = {"val": ([softmax(z / T) for z in Zv], Gv, Iv),
                                                  "test": ([softmax(z / T) for z in Zt], Gt, It), "cal": f"T={T:.2f}"}

    # reranker
    if os.path.exists(f"{R}/r1/scores_val.jsonl") and os.path.exists(f"{R}/r1/scores_test.jsonl"):
        head = json.load(open(f"{R}/r1/head.json"))
        wh, ah = np.array(head["w"]), head["a"]

        def rr(split, data):
            Z, G, I = [], [], []
            for s in load_jsonl(f"{R}/r1/scores_{split}.jsonl"):
                Z.append(ah * np.array(s["ce"]) + np.array(choice_features(data[s["id"]])) @ wh)
                G.append(s["gold"])
                I.append(s["id"])
            return Z, G, I
        Zv, Gv, Iv = rr("val", val)
        Zt, Gt, It = rr("test", test)
        grid = np.exp(np.linspace(np.log(0.05), np.log(20), 300))
        T = float(min(grid, key=lambda t: np.mean([-np.log(max(softmax(z / t)[k], 1e-12)) for z, k in zip(Zv, Gv)])))
        models["Qwen3-Reranker-0.6B fine-tuned (B)"] = {"val": ([softmax(z / T) for z in Zv], Gv, Iv),
                                                         "test": ([softmax(z / T) for z in Zt], Gt, It),
                                                         "cal": f"T={T:.2f}", "run": "r1"}

    for run, name in (("laya_zs", "Laya multilingual zero-shot"), ("laya_ft", "Laya multilingual fine-tuned (A)")):
        sv, st = load(f"{R}/{run}/scores_val.jsonl"), load(f"{R}/{run}/scores_test.jsonl")
        if not sv:
            continue
        Zv, Gv = [s["logits"] for s in sv], [s["gold"] for s in sv]
        glob, temps = fit_buckets(Zv, Gv)
        ent = {"val": (apply_T(Zv, glob, temps), Gv, [s["id"] for s in sv]),
               "cal": "T per bucket " + ", ".join(f"{k}={v:.2f}" for k, v in temps.items()), "run": run}
        if st:
            ent["test"] = (apply_T([s["logits"] for s in st], glob, temps), [s["gold"] for s in st],
                           [s["id"] for s in st])
        models[name] = ent

    lv, lt = load(f"{R}/s2/s2_logprob_val.jsonl"), load(f"{R}/s2/s2_logprob.jsonl")
    if lt:
        def lp(rows, T):
            P = [softmax(np.log(np.maximum([r["probs"][k] for k in r["keys"]], 1e-9)) / T) for r in rows]
            return P, [r["gold"] for r in rows], [r["id"] for r in rows]
        T = 1.0
        if lv:
            Zv = [np.log(np.maximum([r["probs"][k] for k in r["keys"]], 1e-9)) for r in lv]
            T = fit_T(Zv, [r["gold"] for r in lv])
        ent = {"test": lp(lt, T), "cal": f"T={T:.2f}" + ("" if lv else " (no val)"), "s2": True}
        if lv:
            ent["val"] = lp(lv, T)
        models["System Two: Qwen3.6-35B-A3B direct, answer logprob"] = ent

    # ---- metrics ------------------------------------------------------------------------
    table, rels = {}, {}
    for name, e in models.items():
        row = {"calibration": e["cal"]}
        tau = 1.01
        if "val" in e:
            P, G, _ = e["val"]
            m, conf, corr = metrics(P, G)
            rels[name] = m.pop("reliability")
            tau, cov, prec = pick_tau(conf, corr, TARGET)
            m["fast"] = {"tau": tau, "coverage": cov, "precision": prec}
            row["val"] = m
        if "test" in e:
            P, G, I = e["test"]
            for sub, keep in (("test_all", lambda i: True),
                              ("test_scale_lab", lambda i: i.startswith("scale-lab")),
                              ("test_holdout_v2", lambda i: i.startswith("holdout-week-v2")),
                              ("test_sample300", lambda i: i in sample)):
                idx = [j for j, i in enumerate(I) if keep(i)]
                if not idx:
                    continue
                m, _, conf, corr = summarize([P[j] for j in idx], [G[j] for j in idx], tau)
                row[sub] = m
        lat = None
        for p in (f"{R}/{e.get('run', '_')}/latency.json",):
            if os.path.exists(p):
                lat = json.load(open(p))
        if e.get("s2"):
            ms = [r["ms"] for r in lt]
            lat = {"p50_ms": float(np.percentile(ms, 50)), "p90_ms": float(np.percentile(ms, 90)),
                   "mode": "HTTP to shared vLLM, 4 concurrent"}
        row["latency"] = lat
        table[name] = row

    sk = load(f"{R}/s2/s2_skill.jsonl")
    if sk:
        n = len(sk)
        dec = [r for r in sk if r["pred"] is not None]
        ms = [r["ms"] for r in sk]
        table["System Two: event-assign skill (organizer Harness)"] = {
            "calibration": "none (no probabilities; 'ask' = escalate)",
            "test_sample300": {"n": n, "accuracy": sum(r["pred"] == r["label"] for r in sk) / n,
                               "decided_share": len(dec) / n,
                               "decided_precision": (sum(r["pred"] == r["label"] for r in dec) / len(dec)) if dec else None,
                               "ask_share": sum(r["action"] == "ask" for r in sk) / n,
                               "invalid": sum(not r["valid"] for r in sk),
                               "accuracy_with_provisional": sum((r["pred"] or r.get("provisional")) == r["label"]
                                                                for r in sk) / n},
            "latency": {"p50_ms": float(np.percentile(ms, 50)), "p90_ms": float(np.percentile(ms, 90)),
                        "mode": "HTTP to shared vLLM, 4 concurrent, schema-guided JSON + validate"}}

    # ---- merge judges (VALIDATION only: there is no merge TEST set) -------------------------
    # T and bias are fitted with 2-fold cross-fitting so the reported ECE is out-of-sample.
    merges = {}
    for run, name in (("r1", "reranker"), ("laya_zs", "Laya zero-shot"), ("laya_ft", "Laya fine-tuned")):
        rows = load(f"{R}/{run}/scores_merge_val.jsonl")
        if not rows:
            continue
        merges[name] = {}
        for task in ("person", "event"):
            sub = [r for r in rows if r["task"] == task]
            z = np.array([r["ce"] for r in sub])
            y = np.array([r["y"] for r in sub])
            merges[name][task] = merge_metrics(z, y)
    table["_merge_val"] = merges
    json.dump(table, open(f"{args.out}/report.json", "w"), indent=1, ensure_ascii=False)

    # ---- figures -----------------------------------------------------------------------
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    colors = ["#8a8a8a", "#b07d2b", "#2f6fdf", "#9a4fc4", "#c0392b", "#1f9d6b"]
    fig, ax = plt.subplots(figsize=(6.2, 5.6))
    ax.plot([0, 1], [0, 1], color="#bbb", lw=1, ls="--", label="perfect calibration")
    for (name, rel), c in zip(rels.items(), colors):
        if name.startswith("retrieval top-1"):
            continue
        xs, ys, ns = [r[3] for r in rel], [r[4] for r in rel], [r[2] for r in rel]
        ece = table[name]["val"]["ece15"]
        ax.plot(xs, ys, color=c, lw=1.6, marker="o", ms=4, label=f"{name}  (ECE {ece:.3f})")
    ax.set_xlabel("confidence of the chosen option (calibrated)")
    ax.set_ylabel("accuracy")
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1.02)
    ax.set_title("System One reliability on VALIDATION (15 bins)")
    ax.legend(fontsize=7, loc="upper left")
    fig.tight_layout()
    fig.savefig(f"{args.out}/s1_reliability_val.png", dpi=150)

    fig, ax = plt.subplots(figsize=(6.2, 4.4))
    for (name, e), c in zip(models.items(), colors):
        if "test" not in e or name.startswith("retrieval top-1"):
            continue
        P, G, I = e["test"]
        m, conf, corr = metrics(P, G)
        cc, prec, cov = coverage_curve(conf, corr)
        ax.plot(cov, prec, color=c, lw=1.5, label=name + (" (300-decision sample)" if e.get("s2") else ""))
        tau = table[name].get("val", {}).get("fast", {}).get("tau")
        if tau is not None and tau <= 1:
            f = table[name]["test_all" if "test_all" in table[name] else "test_sample300"]["fast"]
            ax.scatter([f["coverage"]], [f["precision"] or 0], color=c, s=30, zorder=3)
    ax.axhline(TARGET, color="#c33", lw=1, ls="--")
    ax.set_ylim(0.0, 1.005)
    ax.set_xlabel("coverage (decisions taken on the fast path)")
    ax.set_ylabel("precision of those decisions")
    ax.set_title("TEST coverage vs precision; dots = tau frozen on VALIDATION")
    ax.legend(fontsize=7, loc="center left")
    fig.tight_layout()
    fig.savefig(f"{args.out}/s1_coverage_test.png", dpi=150)
    print(json.dumps(table, indent=1, ensure_ascii=False)[:12000])


if __name__ == "__main__":
    main()
