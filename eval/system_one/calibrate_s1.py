"""Calibrate System One on VALIDATION only and pick the fast-path threshold.

Inputs: a run dir from train_s1.py (scores_val.jsonl, scores_test.jsonl, head.json,
scores_merge_val.jsonl) and the CHOICE data dir (for the features).  Also fits the
feature-only model (conditional logit on the retrieval features, trained on TRAIN)
as the comparison.  numpy only.

Writes <run>/calibration.json (temperature, isotonic knots if kept, tau, val metrics),
<run>/reliability_val.png, <run>/coverage_precision_val.png.
Test metrics are reported with --report-test, using the parameters frozen from val.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import D, choice_features, gold_index, load_jsonl

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--data", required=True)
ap.add_argument("--target-precision", type=float, default=0.97)
ap.add_argument("--report-test", action="store_true")
args = ap.parse_args()


def softmax(z):
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


# ---- metrics ------------------------------------------------------------------------
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
    # largest coverage whose kept set still has precision >= target (ties at the same conf kept together)
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


def fit_temperature(logit_rows, golds):
    grid = np.exp(np.linspace(np.log(0.05), np.log(20), 400))
    best = min(grid, key=lambda T: np.mean([-np.log(max(softmax(z / T)[k], 1e-12))
                                            for z, k in zip(logit_rows, golds)]))
    return float(best)


def pav(x, y):
    """Isotonic regression (pool adjacent violators) of y on x; returns knots (xs, ys)."""
    o = np.argsort(x)
    xs, ys = list(x[o]), list(y[o])
    blocks = [[ys[i], 1.0, xs[i], xs[i]] for i in range(len(ys))]
    out = []
    for b in blocks:
        out.append(b)
        while len(out) > 1 and out[-2][0] / out[-2][1] > out[-1][0] / out[-1][1]:
            s, n, lo, _ = out.pop(-2)
            out[-1] = [out[-1][0] + s, out[-1][1] + n, lo, out[-1][3]]
    kx = [(b[2] + b[3]) / 2 for b in out]
    ky = [b[0] / b[1] for b in out]
    return np.array(kx), np.array(ky)


def iso_apply(knots, c):
    kx, ky = knots
    return np.interp(c, kx, ky)


# ---- feature-only model (conditional logit) -----------------------------------------
def fit_feature_model(rows, l2=1e-3, iters=3000, lr=0.5):
    K = max(len(r["options"]) for r in rows)
    X = np.zeros((len(rows), K, D))
    M = np.zeros((len(rows), K), dtype=bool)
    for i, r in enumerate(rows):
        f = np.array(choice_features(r))
        X[i, :len(f)] = f
        M[i, :len(f)] = True
    G = np.array([gold_index(r) for r in rows])
    Y = np.zeros((len(rows), K))
    Y[np.arange(len(rows)), G] = 1
    w = np.zeros(D)
    for it in range(iters):
        z = np.where(M, X @ w, -1e9)
        z -= z.max(1, keepdims=True)
        p = np.exp(z) * M
        p /= p.sum(1, keepdims=True)
        grad = np.einsum("nk,nkd->d", p - Y, X) / len(rows) + l2 * w
        w -= lr * grad
    return w


# ---- load ---------------------------------------------------------------------------
run = args.run
head = json.load(open(f"{run}/head.json"))
w_head, a_head = np.array(head["w"]), head["a"]
data_val = {r["id"]: r for r in load_jsonl(f"{args.data}/choice_val.jsonl")}
data_test = {r["id"]: r for r in load_jsonl(f"{args.data}/choice_test.jsonl")}


def s1_logits(score_rows, data):
    Z, G, meta = [], [], []
    for s in score_rows:
        r = data[s["id"]]
        f = np.array(choice_features(r))
        Z.append(a_head * np.array(s["ce"]) + f @ w_head)
        G.append(s["gold"])
        meta.append(s)
    return Z, G, meta


sv = load_jsonl(f"{run}/scores_val.jsonl")
Zv, Gv, Mv = s1_logits(sv, data_val)

out = {"models": {}}
# baseline: organizer's retrieval order (top candidate, else NEW)
base_acc = np.mean([(0 if any(k not in ("NEW", "NONE") for k in m["keys"]) else m["keys"].index("NEW")) == g
                    for m, g in zip(Mv, Gv)])
out["models"]["retrieval_top1"] = {"val_accuracy": float(base_acc)}

# feature-only model
fm_path = f"{run}/feature_model.json"
if os.path.exists(fm_path):
    w_feat = np.array(json.load(open(fm_path))["w"])
else:
    w_feat = fit_feature_model(load_jsonl(f"{args.data}/choice_train.jsonl"))
    json.dump({"w": w_feat.tolist()}, open(fm_path, "w"))
Zf = [np.array(choice_features(data_val[m["id"]])) @ w_feat for m in Mv]
Tf = fit_temperature(Zf, Gv)
mf, _, _ = metrics([softmax(z / Tf) for z in Zf], Gv)
mf.pop("reliability")
out["models"]["feature_model"] = {"temperature": Tf, "val": mf}

# System One, raw and temperature-scaled
m_raw, _, _ = metrics([softmax(z) for z in Zv], Gv)
m_raw.pop("reliability")
T = fit_temperature(Zv, Gv)
Pv = [softmax(z / T) for z in Zv]
m_t, conf_t, corr_t = metrics(Pv, Gv)

# isotonic on top confidence: 2-fold cross-fit (time order) to decide if it helps
half = len(conf_t) // 2
cf = np.empty_like(conf_t)
for a, b in ((slice(0, half), slice(half, None)), (slice(half, None), slice(0, half))):
    cf[b] = iso_apply(pav(conf_t[a], corr_t[a]), conf_t[b])


def ece_of(conf, correct, bins=15):
    edges = np.linspace(0, 1, bins + 1)
    e = 0.0
    for i in range(bins):
        m = (conf > edges[i]) & (conf <= edges[i + 1]) if i else (conf <= edges[1])
        if m.sum():
            e += m.mean() * abs(conf[m].mean() - correct[m].mean())
    return float(e)


# temperature-only ECE, also cross-fitted, for a like-for-like comparison
cf_t = np.empty_like(conf_t)
for a, b in ((slice(0, half), slice(half, None)), (slice(half, None), slice(0, half))):
    Ta = fit_temperature([Zv[i] for i in range(len(Zv))[a]], [Gv[i] for i in range(len(Gv))[a]])
    cf_t[b] = np.array([softmax(Zv[i] / Ta).max() for i in range(len(Zv))[b]])
ece_iso_cf, ece_t_cf = ece_of(cf, corr_t), ece_of(cf_t, corr_t)
use_iso = ece_iso_cf < ece_t_cf - 0.005
iso = pav(conf_t, corr_t) if use_iso else None
conf_final = iso_apply(iso, conf_t) if use_iso else conf_t
tau, cov, prec = pick_tau(conf_final, corr_t, args.target_precision)
c_sorted, prec_curve, cov_curve = coverage_curve(conf_final, corr_t)

m_t_rel = m_t.pop("reliability")
out["models"]["system_one"] = {"a": a_head, "temperature": T, "val_raw": m_raw, "val_temp": m_t,
                               "iso_crossfit_ece": ece_iso_cf, "temp_crossfit_ece": ece_t_cf,
                               "isotonic_kept": bool(use_iso)}
out["chosen"] = "system_one" if m_t["nll"] <= mf["nll"] else "feature_model"
out["calibration"] = {"temperature": T, "isotonic": [iso[0].tolist(), iso[1].tolist()] if use_iso else None}
out["fast_path"] = {"target_precision": args.target_precision, "tau": tau, "val_coverage": cov,
                    "val_precision": prec}
# per-label view on val at tau
pred = np.array([int(p.argmax()) for p in Pv])
by = {}
for lab in ("CAND", "NEW", "NONE"):
    m = np.array([(mm["label"] if mm["label"] in ("NEW", "NONE") else "CAND") == lab for mm in Mv])
    fast = conf_final >= tau
    by[lab] = {"n": int(m.sum()), "accuracy": float((pred[m] == np.array(Gv)[m]).mean()) if m.any() else None,
               "fast_share": float(fast[m].mean()) if m.any() else None}
out["val_by_label"] = by

# ---- merge heads: temperature + threshold on val ------------------------------------
mp = f"{run}/scores_merge_val.jsonl"
if os.path.exists(mp):
    out["merge"] = {}
    for task in ("person", "event"):
        rows = [r for r in load_jsonl(mp) if r["task"] == task]
        z = np.array([r["ce"] for r in rows])
        y = np.array([r["y"] for r in rows])
        grid = np.exp(np.linspace(np.log(0.05), np.log(20), 400))

        def nll(T, b=0.0):
            p = 1 / (1 + np.exp(-(z / T + b)))
            return -np.mean(y * np.log(p + 1e-12) + (1 - y) * np.log(1 - p + 1e-12))
        Tm = float(min(grid, key=nll))
        bm = float(min(np.linspace(-4, 4, 161), key=lambda b: nll(Tm, b)))
        p = 1 / (1 + np.exp(-(z / Tm + bm)))
        pred = (p >= 0.5).astype(float)
        conf = np.maximum(p, 1 - p)
        corr = (pred == y).astype(float)
        # AUC
        o = np.argsort(p)
        ranks = np.empty(len(p))
        ranks[o] = np.arange(1, len(p) + 1)
        auc = (ranks[y == 1].sum() - (y == 1).sum() * ((y == 1).sum() + 1) / 2) / max((y == 1).sum() * (y == 0).sum(), 1)
        # threshold on p(same) for >= target precision on "merge"
        os_ = np.argsort(-p)
        cp = np.cumsum(y[os_]) / np.arange(1, len(y) + 1)
        okk = np.where(cp >= args.target_precision)[0]
        tsame = float(p[os_][okk[-1]]) if len(okk) else 1.01
        out["merge"][task] = {"n": len(y), "positives": int(y.sum()), "temperature": Tm, "bias": bm,
                              "accuracy": float(corr.mean()), "ece15": ece_of(conf, corr),
                              "brier": float(np.mean((p - y) ** 2)), "auc": float(auc),
                              "same_threshold_97": tsame,
                              "same_recall_at_threshold": float(((p >= tsame) & (y == 1)).sum() / max(y.sum(), 1))}

# ---- plots ---------------------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(5, 5))
    ax.plot([0, 1], [0, 1], color="#999", lw=1, ls="--")
    xs = [r[3] for r in m_t_rel]
    ys = [r[4] for r in m_t_rel]
    ns = [r[2] for r in m_t_rel]
    ax.scatter(xs, ys, s=[max(10, n / 2) for n in ns], color="#2f6fdf")
    ax.plot(xs, ys, color="#2f6fdf", lw=1.5)
    ax.set_xlabel("confidence (top option, temperature-scaled)")
    ax.set_ylabel("accuracy")
    ax.set_title(f"System One reliability, VALIDATION (n={len(Gv)})\nECE15={m_t['ece15']:.3f}  T={T:.2f}")
    fig.tight_layout()
    fig.savefig(f"{run}/reliability_val.png", dpi=130)
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.plot(cov_curve, prec_curve, color="#2f6fdf")
    ax.axhline(args.target_precision, color="#c33", lw=1, ls="--")
    ax.axvline(cov, color="#c33", lw=1, ls=":")
    ax.set_xlabel("coverage (share decided on the fast path)")
    ax.set_ylabel("precision of the kept decisions")
    ax.set_ylim(0.6, 1.005)
    ax.set_title(f"Coverage-precision, VALIDATION: tau={tau:.3f} keeps {cov:.0%} at {prec:.1%}")
    fig.tight_layout()
    fig.savefig(f"{run}/coverage_precision_val.png", dpi=130)
except Exception as e:  # plotting is optional
    out["plot_error"] = repr(e)

# ---- test (frozen parameters) --------------------------------------------------------
if args.report_test and os.path.exists(f"{run}/scores_test.jsonl"):
    st = load_jsonl(f"{run}/scores_test.jsonl")
    out["test"] = {}
    for name, filt in (("all", lambda s: True), ("scale-lab", lambda s: s["stream"] == "scale-lab"),
                       ("holdout-week-v2", lambda s: s["stream"] == "holdout-week-v2")):
        sub = [s for s in st if filt(s)]
        if not sub:
            continue
        Z, G, M = s1_logits(sub, data_test)
        P = [softmax(z / T) for z in Z]
        mt, conf, corr = metrics(P, G)
        mt.pop("reliability")
        if use_iso:
            conf = iso_apply(iso, conf)
        mt["fast_path"] = apply_tau(conf, corr, tau)
        mt["retrieval_top1_accuracy"] = float(np.mean(
            [(0 if any(k not in ("NEW", "NONE") for k in m["keys"]) else m["keys"].index("NEW")) == g
             for m, g in zip(M, G)]))
        Zf = [np.array(choice_features(data_test[m["id"]])) @ w_feat for m in M]
        mft, _, _ = metrics([softmax(z / Tf) for z in Zf], G)
        mft.pop("reliability")
        mt["feature_model"] = mft
        out["test"][name] = mt

json.dump(out, open(f"{run}/calibration.json" if not args.report_test else f"{run}/report_test.json", "w"),
          indent=1, ensure_ascii=False)
print(json.dumps({k: v for k, v in out.items()}, indent=1, ensure_ascii=False)[:6000])
