"""Calibrate the Laya System One candidate on VALIDATION only, the way Laya's docs require:
one temperature per (question type, option-count bucket) -- laya.common.temp_bucket -- fitted by
NLL within Laya's clamp [0.5, 5.0], so the served checkpoint applies exactly what was measured.

Reads <run>/scores_val.jsonl (+ scores_merge_val.jsonl, scores_test.jsonl) from laya_s1.py.
Writes <run>/calibration.json, reliability_val.png, coverage_precision_val.png, and (with
--write-model) the temperatures into <run>/model/rl_agent_config.json.
Metrics and the tau rule are the same functions calibrate_s1.py uses for the reranker.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import load_jsonl  # noqa: E402

TMIN, TMAX = 0.5, 5.0
GRID = np.exp(np.linspace(np.log(TMIN), np.log(TMAX), 300))


def softmax(z):
    z = np.asarray(z, float)
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


def bucket(k, qtype="choice"):
    size = "2" if k <= 2 else "3-5" if k <= 5 else "6-10" if k <= 10 else "11+"
    return f"{qtype}:{size}"


def metrics(probs, golds, bins=15):
    conf = np.array([p.max() for p in probs])
    pred = np.array([int(p.argmax()) for p in probs])
    g = np.array(golds)
    correct = (pred == g).astype(float)
    brier = float(np.mean([((p - np.eye(len(p))[k]) ** 2).sum() for p, k in zip(probs, g)]))
    nll = float(np.mean([-np.log(max(p[k], 1e-12)) for p, k in zip(probs, g)]))
    edges = np.linspace(0, 1, bins + 1)
    ece, rel = 0.0, []
    for b in range(bins):
        m = (conf > edges[b]) & (conf <= edges[b + 1]) if b else (conf >= 0) & (conf <= edges[1])
        if m.sum():
            ece += m.mean() * abs(conf[m].mean() - correct[m].mean())
            rel.append((float(edges[b]), float(edges[b + 1]), int(m.sum()), float(conf[m].mean()),
                        float(correct[m].mean())))
    return {"n": len(g), "accuracy": float(correct.mean()), "ece15": float(ece), "brier": brier, "nll": nll,
            "reliability": rel}, conf, correct


def coverage_curve(conf, correct):
    o = np.argsort(-conf)
    c, k = conf[o], correct[o]
    prec = np.cumsum(k) / np.arange(1, len(k) + 1)
    cov = np.arange(1, len(k) + 1) / len(k)
    return c, prec, cov


def pick_tau(conf, correct, target):
    c, prec, cov = coverage_curve(conf, correct)
    ok = np.where(prec >= target)[0]
    best = None
    for i in ok[::-1]:
        if i + 1 == len(c) or c[i + 1] < c[i]:
            best = i
            break
    if best is None:
        return 1.01, 0.0, float("nan")
    return float(c[best]), float(cov[best]), float(prec[best])


def apply_tau(conf, correct, tau):
    m = conf >= tau
    return {"tau": tau, "coverage": float(m.mean()), "precision": float(correct[m].mean()) if m.any() else None,
            "n_fast": int(m.sum())}


def fit_T(Z, G):
    if not Z:
        return 1.0
    return float(min(GRID, key=lambda T: np.mean([-np.log(max(softmax(np.asarray(z) / T)[k], 1e-12))
                                                  for z, k in zip(Z, G)])))


def fit_buckets(Z, G, min_n=30):
    glob = fit_T(Z, G)
    temps = {}
    for b in sorted({bucket(len(z)) for z in Z}):
        sel = [i for i, z in enumerate(Z) if bucket(len(z)) == b]
        temps[b] = fit_T([Z[i] for i in sel], [G[i] for i in sel]) if len(sel) >= min_n else glob
    return glob, temps


def apply_T(Z, glob, temps):
    return [softmax(np.asarray(z) / temps.get(bucket(len(z)), glob)) for z in Z]


def ece_of(conf, correct, bins=15):
    edges = np.linspace(0, 1, bins + 1)
    e = 0.0
    for i in range(bins):
        m = (conf > edges[i]) & (conf <= edges[i + 1]) if i else (conf <= edges[1])
        if m.sum():
            e += m.mean() * abs(conf[m].mean() - correct[m].mean())
    return float(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--target-precision", type=float, default=0.97)
    ap.add_argument("--report-test", action="store_true")
    ap.add_argument("--write-model", action="store_true")
    ap.add_argument("--label", default="Laya")
    args = ap.parse_args()
    run = args.run
    sv = load_jsonl(f"{run}/scores_val.jsonl")
    Z = [s["logits"] for s in sv]
    G = [s["gold"] for s in sv]
    out = {"candidate": args.label, "models": {}}
    base_acc = np.mean([(0 if any(k not in ("NEW", "NONE") for k in s["keys"]) else s["keys"].index("NEW"))
                        == s["gold"] for s in sv])
    out["models"]["retrieval_top1"] = {"val_accuracy": float(base_acc)}

    m_raw, _, _ = metrics([softmax(z) for z in Z], G)
    m_raw.pop("reliability")
    glob, temps = fit_buckets(Z, G)
    P = apply_T(Z, glob, temps)
    m_t, conf, corr = metrics(P, G)
    # honest calibration error: 2-fold cross-fit in time order (fit on one half, score the other)
    half = len(Z) // 2
    cf = np.empty(len(Z))
    for a, b in ((slice(0, half), slice(half, None)), (slice(half, None), slice(0, half))):
        ia, ib = range(len(Z))[a], range(len(Z))[b]
        ga, ta = fit_buckets([Z[i] for i in ia], [G[i] for i in ia])
        cf[b] = np.array([p.max() for p in apply_T([Z[i] for i in ib], ga, ta)])
    ece_cf = ece_of(cf, corr)
    tau, cov, prec = pick_tau(conf, corr, args.target_precision)
    c_sorted, prec_curve, cov_curve = coverage_curve(conf, corr)
    rel = m_t.pop("reliability")
    out["models"]["system_one"] = {"temperature_global": glob, "temperature_by_options": temps,
                                   "val_raw": m_raw, "val_temp": m_t, "temp_crossfit_ece": ece_cf}
    out["calibration"] = {"temperature": [glob, 1.0, 1.0], "temperature_by_options": dict(temps)}
    out["fast_path"] = {"target_precision": args.target_precision, "tau": tau, "val_coverage": cov,
                        "val_precision": prec,
                        "accuracy_within_coverage": prec, "correct_fast_share": float(cov * prec) if cov else 0.0}
    pred = np.array([int(p.argmax()) for p in P])
    by = {}
    for lab in ("CAND", "NEW", "NONE"):
        m = np.array([(s["label"] if s["label"] in ("NEW", "NONE") else "CAND") == lab for s in sv])
        fast = conf >= tau
        by[lab] = {"n": int(m.sum()), "accuracy": float((pred[m] == np.array(G)[m]).mean()) if m.any() else None,
                   "fast_share": float(fast[m].mean()) if m.any() else None}
    out["val_by_label"] = by
    out["curve"] = {"coverage": [float(x) for x in cov_curve[::10]], "precision": [float(x) for x in prec_curve[::10]]}

    # ---- merge (noul): one temperature for the noul:2 bucket, thresholds per task ---------
    mp = f"{run}/scores_merge_val.jsonl"
    if os.path.exists(mp):
        mr = load_jsonl(mp)
        Zm = [r["logits"] for r in mr]
        Ym = [int(r["y"]) for r in mr]
        Tn = fit_T(Zm, Ym)
        out["calibration"]["temperature"][2] = Tn
        out["calibration"]["temperature_by_options"]["noul:2"] = Tn
        out["merge"] = {"temperature": Tn}
        for task in ("person", "event"):
            idx = [i for i, r in enumerate(mr) if r["task"] == task]
            y = np.array([Ym[i] for i in idx], float)
            p = np.array([softmax(np.asarray(Zm[i]) / Tn)[1] for i in idx])
            pr = (p >= 0.5).astype(float)
            cc = (pr == y).astype(float)
            o = np.argsort(p)
            ranks = np.empty(len(p))
            ranks[o] = np.arange(1, len(p) + 1)
            npos, nneg = (y == 1).sum(), (y == 0).sum()
            auc = (ranks[y == 1].sum() - npos * (npos + 1) / 2) / max(npos * nneg, 1)
            os_ = np.argsort(-p)
            cp = np.cumsum(y[os_]) / np.arange(1, len(y) + 1)
            okk = np.where(cp >= args.target_precision)[0]
            tsame = float(p[os_][okk[-1]]) if len(okk) else 1.01
            out["merge"][task] = {"n": len(y), "positives": int(npos), "accuracy": float(cc.mean()),
                                  "ece15": ece_of(np.maximum(p, 1 - p), cc), "brier": float(np.mean((p - y) ** 2)),
                                  "auc": float(auc), "same_threshold_97": tsame,
                                  "same_recall_at_threshold": float(((p >= tsame) & (y == 1)).sum() / max(npos, 1))}

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(5, 5))
        ax.plot([0, 1], [0, 1], color="#999", lw=1, ls="--")
        xs, ys, ns = [r[3] for r in rel], [r[4] for r in rel], [r[2] for r in rel]
        ax.scatter(xs, ys, s=[max(10, n / 2) for n in ns], color="#2f6fdf")
        ax.plot(xs, ys, color="#2f6fdf", lw=1.5)
        ax.set_xlabel("confidence (top option, per-bucket temperature)")
        ax.set_ylabel("accuracy")
        ax.set_title(f"{args.label} reliability, VALIDATION (n={len(G)})\nECE15={m_t['ece15']:.3f} "
                     f"(cross-fit {ece_cf:.3f})")
        fig.tight_layout()
        fig.savefig(f"{run}/reliability_val.png", dpi=130)
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.plot(cov_curve, prec_curve, color="#2f6fdf")
        ax.axhline(args.target_precision, color="#c33", lw=1, ls="--")
        ax.axvline(cov, color="#c33", lw=1, ls=":")
        ax.set_xlabel("coverage (share decided on the fast path)")
        ax.set_ylabel("precision of the kept decisions")
        ax.set_ylim(0.5, 1.005)
        ax.set_title(f"{args.label} coverage-precision, VALIDATION: tau={tau:.3f} keeps {cov:.0%} at {prec:.1%}")
        fig.tight_layout()
        fig.savefig(f"{run}/coverage_precision_val.png", dpi=130)
    except Exception as e:
        out["plot_error"] = repr(e)

    if args.report_test and os.path.exists(f"{run}/scores_test.jsonl"):
        st = load_jsonl(f"{run}/scores_test.jsonl")
        out["test"] = {}
        for name, filt in (("all", lambda s: True), ("scale-lab", lambda s: s["stream"] == "scale-lab"),
                           ("holdout-week-v2", lambda s: s["stream"] == "holdout-week-v2")):
            sub = [s for s in st if filt(s)]
            if not sub:
                continue
            Pt = apply_T([s["logits"] for s in sub], glob, temps)
            mt, ct, kt = metrics(Pt, [s["gold"] for s in sub])
            mt.pop("reliability")
            mt["fast_path"] = apply_tau(ct, kt, tau)
            out["test"][name] = mt

    if args.write_model and os.path.isdir(f"{run}/model"):
        cp = f"{run}/model/rl_agent_config.json"
        cfg = json.load(open(cp))
        cfg["temperature"] = out["calibration"]["temperature"]
        cfg["temperature_by_options"] = out["calibration"]["temperature_by_options"]
        cfg["fast_path_tau"] = tau
        json.dump(cfg, open(cp, "w"), indent=2, ensure_ascii=False)
    name = "report_test.json" if args.report_test else "calibration.json"
    json.dump(out, open(f"{run}/{name}", "w"), indent=1, ensure_ascii=False)
    s = {k: out[k] for k in ("models", "fast_path", "val_by_label") if k in out}
    s["merge"] = out.get("merge")
    s["test"] = out.get("test")
    print(json.dumps(s, indent=1, ensure_ascii=False)[:5000])


if __name__ == "__main__":
    main()
