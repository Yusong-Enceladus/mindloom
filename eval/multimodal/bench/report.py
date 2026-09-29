#!/usr/bin/env python3
"""Build the mm-v1 VLM benchmark tables from raw runs (results/raw/<stem>.jsonl) and their .meta.json.

Scores every run with score_vlm.py and writes results/scores/<stem>.json, results/summary.json and
results/tables.md (the tables BENCHMARK.md quotes). What each model's numbers come from is set per model in
bench/models.json:

  quality_runs  two single-stream test runs; quality = mean of the two (per type: mean of the per-type values;
                headline: macro average over the seven types, so each type weighs the same)
  latency_runs  single-stream test runs measured with no other client on the server; p50/p90 pooled over them
  c4_run        the concurrency-4 run on the fixed 28-image subset (4 per type); throughput = images / wall time
  extra_runs    other runs listed in the per-run table only (e.g. a throughput run measured under shared load)
  runs          per run: where it ran, and which load samples (results/load/<node>.tsv) and port show other
                clients' requests

  python3 bench/report.py --root . --models bench/models.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_vlm as sv  # noqa: E402

TYPES = ["chat_screenshot", "chart_dashboard", "slide", "whiteboard_handwriting", "receipt_invoice",
         "scanned_document", "form_label_sign"]
TYPE_ZH = {"chat_screenshot": "聊天截图", "chart_dashboard": "图表/看板", "slide": "幻灯片", "whiteboard_handwriting": "手写/白板",
           "receipt_invoice": "小票/销售单", "scanned_document": "扫描件", "form_label_sign": "标签/面单/标牌"}
TYPE_EXTRA = {
    "chat_screenshot": [("sender_acc", "发送者"), ("time_acc", "时间"), ("time_acc_labeled", "时间(有标签)"),
                        ("is_self_acc", "is_self"), ("sender_acc_similar_names", "近似名发送者"), ("msg_count_ok", "条数一致")],
    "chart_dashboard": [("point_acc", "数据点数值"), ("kpi_acc", "KPI"), ("trend_acc", "趋势"), ("chart_type_ok", "图型")],
    "slide": [("title_exact", "标题"), ("bullet_recall", "要点召回"), ("bullet_precision", "要点精确"), ("bullet_level_acc", "层级")],
    "whiteboard_handwriting": [("line_exact", "行完全一致"), ("struck_acc", "划掉判断"), ("struck_recall", "划掉召回"),
                               ("checked_recall", "打勾召回"), ("line_count_ok", "行数一致")],
    "receipt_invoice": [("merchant_ok", "商家"), ("date_ok", "日期"), ("doc_no_ok", "单号"), ("total_ok", "合计"),
                        ("item_f1", "明细F1"), ("self_consistent", "明细=合计")],
    "scanned_document": [("table_cell_acc", "表格单元格"), ("cer_order", "按顺序CER")],
    "form_label_sign": [("label_field_acc", "字段值完全一致"), ("label_field_contains", "字段值包含"), ("label_kind_ok", "类别")],
}
MACRO_KEYS = ("cer", "cer_order", "key_field_em", "qa_found", "fab_number_rate", "unsupported_rate", "num_recall",
              "halluc_img_rate")


def load_rows(path: Path) -> dict:
    rows = {}
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r.get("status") == 200:
            rows[r["id"]] = r
    return rows


def mean_of(vals):
    vals = [x for x in vals if x is not None]
    return round(statistics.mean(vals), 1) if vals else None


def fmt(x, suffix=""):
    return "–" if x is None else f"{x}{suffix}"


def aggregate(per: list[dict]) -> dict:
    """score_vlm.aggregate plus the share of images with any fabricated number or unsupported field."""
    out = sv.aggregate(per)
    if per:
        out["halluc_img_rate"] = round(100.0 * sum(1 for r in per if r["fab_numbers"] or r["unsupported"]) / len(per), 1)
    return out


def load_samples(path: Path) -> list[tuple[int, dict]]:
    """results/load/<node>.tsv: '<epoch> gpu=<util> p<port>=<running>/<waiting> ...' every 5 s."""
    out = []
    if not path.exists():
        return out
    for ln in path.read_text().splitlines():
        parts = ln.split()
        if len(parts) < 2:
            continue
        ports = {}
        for x in parts[2:]:
            k, v = x.split("=")
            r, w = v.split("/")
            ports[k[1:]] = (int(r), int(w))
        out.append((int(parts[0]), ports))
    return out


def load_during(rows: list[dict], env: dict, loads: Path) -> dict:
    """Other clients' requests while this run was in flight, from the node's load log (5-s samples)."""
    samples = load_samples(loads / env["load"]) if env.get("load") else []
    t0 = min(r["t_start"] for r in rows)
    t1 = max(r["t_end"] for r in rows)
    win = [(ts, p) for ts, p in samples if t0 <= ts <= t1]
    if not win:
        return {"samples": 0, "coverage": 0.0}
    port = env["port"]
    other_same, other_node, waiting = [], [], []
    for ts, p in win:
        own = sum(1 for r in rows if r["t_start"] <= ts <= r["t_end"])
        other_same.append(max(0, p.get(port, (0, 0))[0] - own))
        other_node.append(sum(v[0] for k, v in p.items() if k != port))
        waiting.append(p.get(port, (0, 0))[1])
    n = len(win)
    covered = (min(t1, win[-1][0]) - max(t0, win[0][0])) / max(1.0, t1 - t0)
    return {"samples": n, "coverage": round(100.0 * covered, 1),
            "other_same_share": round(100.0 * sum(x > 0 for x in other_same) / n, 1),
            "other_same_mean": round(sum(other_same) / n, 2),
            "other_node_share": round(100.0 * sum(x > 0 for x in other_node) / n, 1),
            "waiting_mean": round(sum(waiting) / n, 1)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--models", required=True)
    args = ap.parse_args()
    root = Path(args.root)
    models = json.loads(Path(args.models).read_text())
    manifest = json.loads((root / "manifest.json").read_text())
    recs = {it["id"]: json.loads((root / it["gt"]).read_text()) for it in manifest["items"] if it["split"] == "test"}
    raw = root / "results" / "raw"
    loads = root / "results" / "load"
    (root / "results" / "scores").mkdir(parents=True, exist_ok=True)
    summary = {"split": "test", "n_images": len(recs), "prompt_version": None, "models": {}}
    for m in models:
        key = m["key"]
        stems = list(dict.fromkeys(m["quality_runs"] + m["latency_runs"] + [m["c4_run"]] + m.get("extra_runs", [])))
        runs = {}
        for stem in stems:
            p = raw / f"{stem}.jsonl"
            if not p.exists():
                continue
            rows = load_rows(p)
            per = [sv.score_image(recs[i], rows[i]) for i in sorted(rows) if i in recs]
            by_type = {t: aggregate([r for r in per if r["type"] == t]) for t in TYPES}
            by_tag = {}
            for r in per:
                for t in r["hard"]:
                    by_tag.setdefault(t, []).append(r)
            meta_p = p.with_suffix(".meta.json")
            meta = json.loads(meta_p.read_text()) if meta_p.exists() else {"segments": []}
            if meta["segments"]:
                summary["prompt_version"] = meta["segments"][0].get("prompt_version")
            env = m.get("runs", {}).get(stem, {})
            out = {"model": key, "run": stem, "where": env.get("where"), "n": len(per),
                   "missing": sorted(set(recs) - set(rows)) if max((r.get("concurrency") or 1) for r in rows.values()) == 1 else None,
                   "concurrency": max((r.get("concurrency") or 1) for r in rows.values()),
                   "wall_s": round(max(r["t_end"] for r in rows.values()) - min(r["t_start"] for r in rows.values()), 1),
                   "load": load_during(list(rows.values()), env, loads),
                   "overall": aggregate(per), "by_type": by_type,
                   "by_hard_tag": {t: aggregate(v) for t, v in sorted(by_tag.items())}, "images": per}
            for k in MACRO_KEYS:
                out["overall"][f"{k}_macro"] = mean_of([a.get(k) for a in by_type.values() if a])
            (root / "results" / "scores" / f"{stem}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
            runs[stem] = {"rows": rows, "per": per, "agg": out}
        q = [runs[s] for s in m["quality_runs"] if s in runs]
        if not q:
            continue
        lat = [runs[s] for s in m["latency_runs"] if s in runs]
        s = {k: m.get(k) for k in ("display", "engine", "served", "weights_gb", "gpu_mem_gb", "mem_note", "notes")}
        s["quality_runs"] = [x["agg"]["run"] for x in q]
        s["latency_runs"] = [x["agg"]["run"] for x in lat]
        s["c4_run"] = m["c4_run"] if m["c4_run"] in runs else None
        for k in [f"{x}_macro" for x in MACRO_KEYS] + ["valid_json", "em_name", "em_date", "em_number"]:
            s[k] = mean_of([x["agg"]["overall"].get(k) for x in q])
        # headline type-specific accuracies (mean of the two quality runs)
        for t, k in (("chat_screenshot", "sender_acc"), ("chat_screenshot", "time_acc"), ("chart_dashboard", "point_acc"),
                     ("chart_dashboard", "kpi_acc")):
            s[f"{t}.{k}"] = mean_of([x["agg"]["by_type"][t].get(k) for x in q])
        s["latency_p50"] = sv.quantile([r["latency_s"] for x in lat for r in x["per"]], 0.5)
        s["latency_p90"] = sv.quantile([r["latency_s"] for x in lat for r in x["per"]], 0.9)
        s["out_tokens_mean"] = round(statistics.mean(r["completion_tokens"] or 0 for x in q for r in x["per"]), 1)
        s["prompt_tokens_mean"] = round(statistics.mean(r["prompt_tokens"] or 0 for r in q[0]["per"]), 1)
        s["truncated"] = sum(1 for x in q for r in x["per"] if r["finish_reason"] == "length")

        def identical(a, b):
            same = [a["rows"][i]["content"] == b["rows"][i]["content"] for i in a["rows"] if i in b["rows"]]
            return round(100.0 * sum(same) / len(same), 1) if same else None
        s["identical"] = {}
        if len(q) == 2:
            s["identical"][f"{q[0]['agg']['run']} = {q[1]['agg']['run']}"] = identical(q[0], q[1])
        if lat and lat[0] is not q[0]:
            if len(lat) == 2 and lat[1] is not q[1]:
                s["identical"][f"{lat[0]['agg']['run']} = {lat[1]['agg']['run']}"] = identical(lat[0], lat[1])
            s["identical"][f"{q[0]['agg']['run']} = {lat[0]['agg']['run']}"] = identical(q[0], lat[0])
        if s["c4_run"]:
            rows = list(runs[s["c4_run"]]["rows"].values())
            wall = max(r["t_end"] for r in rows) - min(r["t_start"] for r in rows)
            s["c4_n"] = len(rows)
            s["c4_img_per_min"] = round(60.0 * len(rows) / wall, 2)
            s["c4_out_tok_per_s"] = round(sum(r.get("completion_tokens") or 0 for r in rows) / wall, 1)
            s["c4_latency_p50"] = sv.quantile([r["latency_s"] for r in rows], 0.5)
            s["c4_load"] = runs[s["c4_run"]]["agg"]["load"]
            ref = lat[0] if lat else q[0]
            seq = [ref["rows"][i]["latency_s"] for i in runs[s["c4_run"]]["rows"] if i in ref["rows"]]
            s["c1_img_per_min_same_subset"] = round(60.0 * len(seq) / sum(seq), 2) if seq else None
            s["c1_out_tok_per_s_same_subset"] = round(
                sum(ref["rows"][i].get("completion_tokens") or 0 for i in runs[s["c4_run"]]["rows"] if i in ref["rows"])
                / sum(seq), 1) if seq else None
        s["runs"] = []
        for stem in stems:
            if stem not in runs:
                continue
            a = runs[stem]["agg"]
            o = a["overall"]
            s["runs"].append({"run": stem, "where": a["where"], "concurrency": a["concurrency"], "n": a["n"],
                              "wall_s": a["wall_s"], "load": a["load"],
                              "role": "+".join(r for r, lst in (("质量", m["quality_runs"]), ("延迟", m["latency_runs"]),
                                                                ("并发", [m["c4_run"]])) if stem in lst) or "参考",
                              **{k: o.get(k) for k in ("cer_macro", "key_field_em_macro", "qa_found_macro",
                                                       "fab_number_rate_macro", "unsupported_rate_macro",
                                                       "halluc_img_rate", "latency_p50", "latency_p90",
                                                       "out_tokens_mean")}})
        s["by_type"] = {}
        for t in TYPES:
            aa = [x["agg"]["by_type"].get(t) or {} for x in q]
            row = {k: mean_of([a.get(k) for a in aa]) for k in sorted(set().union(*aa))
                   if isinstance(next((a[k] for a in aa if k in a), None), (int, float))
                   and k not in ("n", "truncated", "n_key_fields", "latency_p50", "latency_p90")}
            row["n"] = aa[0].get("n")
            lat_t = [r["latency_s"] for x in lat for r in x["per"] if r["type"] == t]
            row["latency_p50"] = sv.quantile(lat_t, 0.5)
            row["latency_p90"] = sv.quantile(lat_t, 0.9)
            s["by_type"][t] = row
        tags = sorted(set().union(*[x["agg"]["by_hard_tag"] for x in q]))
        s["by_hard_tag"] = {}
        for t in tags:
            aa = [x["agg"]["by_hard_tag"].get(t) or {} for x in q]
            s["by_hard_tag"][t] = {"n": aa[0].get("n"), **{k: mean_of([a.get(k) for a in aa])
                                                            for k in ("cer", "key_field_em", "fab_number_rate")}}
        summary["models"][key] = s
    (root / "results" / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    (root / "results" / "tables.md").write_text(tables(summary))
    print(tables(summary))


def tables(summary: dict) -> str:
    ms = summary["models"]
    keys = list(ms)
    L = []
    L.append(f"### 质量总表（test {summary['n_images']} 张，每个模型两次单路运行的均值；按类型宏平均，每类 14 张同权）\n")
    L.append("| 模型 | JSON 合规 | CER ↓ | 关键字段 EM ↑ | 名称 / 日期时间 / 数字 EM ↑ | 聊天 发送者 / 时间 ↑ | 图表 数据点 / KPI ↑ | "
             "QA 可答 ↑ | 编造数字 ↓ | 无出处字段 ↓ | 有编造的图 ↓ | 数字召回 ↑ |")
    L.append("|" + "---|" * 12)
    for k in keys:
        s = ms[k]
        L.append(f"| **{s['display']}** | {fmt(s['valid_json'], '%')} | {fmt(s['cer_macro'], '%')} | "
                 f"{fmt(s['key_field_em_macro'], '%')} | {fmt(s['em_name'])} / {fmt(s['em_date'])} / {fmt(s['em_number'])} | "
                 f"{fmt(s['chat_screenshot.sender_acc'])} / {fmt(s['chat_screenshot.time_acc'])} | "
                 f"{fmt(s['chart_dashboard.point_acc'])} / {fmt(s['chart_dashboard.kpi_acc'])} | "
                 f"{fmt(s['qa_found_macro'], '%')} | {fmt(s['fab_number_rate_macro'], '%')} | "
                 f"{fmt(s['unsupported_rate_macro'], '%')} | {fmt(s['halluc_img_rate_macro'], '%')} | {fmt(s['num_recall_macro'], '%')} |")
    L.append("")
    L.append("### 速度与资源（延迟只取没有其他客户端的单路运行；并发 4 为固定的 28 张子集）\n")
    L.append("| 模型 | 引擎 · 量化 | 服务参数 | 单路 p50 / p90 | 输出 token（均值） | 并发 4 吞吐 | 并发 4 输出 tok/s | "
             "并发 4 单张 p50 | 内存 | 权重 |")
    L.append("|" + "---|" * 10)
    for k in keys:
        s = ms[k]
        tp = f"{fmt(s.get('c4_img_per_min'))} 张/分（单路 {fmt(s.get('c1_img_per_min_same_subset'))}）"
        tok = f"{fmt(s.get('c4_out_tok_per_s'))}（单路 {fmt(s.get('c1_out_tok_per_s_same_subset'))}）"
        mem = f"{fmt(s.get('gpu_mem_gb'))} GiB" + (f"（{s['mem_note']}）" if s.get("mem_note") else "")
        L.append(f"| **{s['display']}** | {s['engine']} | {s['served']} | {fmt(s['latency_p50'])} / {fmt(s['latency_p90'])} s | "
                 f"{fmt(s['out_tokens_mean'])} | {tp} | {tok} | {fmt(s.get('c4_latency_p50'))} s | {mem} | {fmt(s.get('weights_gb'))} GiB |")
    L.append("")
    L.append("### 按类型速览（每格：CER · 关键字段 EM · 有编造的图 · 单路 p50）\n")
    L.append("| 类型 | " + " | ".join(ms[k]["display"] for k in keys) + " |")
    L.append("|" + "---|" * (1 + len(keys)))
    for t in TYPES:
        cells = []
        for k in keys:
            r = ms[k]["by_type"][t]
            cells.append(f"{fmt(r.get('cer'), '%')} · {fmt(r.get('key_field_em'), '%')} · {fmt(r.get('halluc_img_rate'), '%')} · "
                         f"{fmt(r.get('latency_p50'))} s")
        L.append(f"| {TYPE_ZH[t]} | " + " | ".join(cells) + " |")
    L.append("")
    L.append("### 每次运行（test；\"他人请求\"= 同一服务上别的客户端在跑的采样占比，\"同机其他服务\"= 同一 GPU 上其他被监控服务在跑的占比，5 秒一采样）\n")
    L.append("| 模型 | 运行 | 用途 | 在哪跑 | 并发 | 用时 | 他人请求 / 排队均值 | 同机其他服务 | CER | 关键字段 EM | QA 可答 | 编造数字 | "
             "无出处字段 | p50 / p90 |")
    L.append("|" + "---|" * 14)
    for k in keys:
        s = ms[k]
        for r in s["runs"]:
            ld = r["load"]
            if ld.get("samples"):
                cov = "" if ld["coverage"] >= 95 else f"（日志覆盖 {ld['coverage']}%）"
                load = f"{ld['other_same_share']}% / {ld['waiting_mean']}{cov}"
                node = f"{ld['other_node_share']}%"
            else:
                load, node = "无日志", "–"
            L.append(f"| {s['display']} | `{r['run']}` | {r['role']} | {r['where'] or '–'} | {r['concurrency']} | {r['wall_s']} s | "
                     f"{load} | {node} | {fmt(r['cer_macro'], '%')} | {fmt(r['key_field_em_macro'], '%')} | "
                     f"{fmt(r['qa_found_macro'], '%')} | {fmt(r['fab_number_rate_macro'], '%')} | "
                     f"{fmt(r['unsupported_rate_macro'], '%')} | {fmt(r['latency_p50'])} / {fmt(r['latency_p90'])} s |")
    L.append("")
    L.append("两次运行输出逐字一致的比例：" + "；".join(
        f"{ms[k]['display']} " + "、".join(f"`{p}` {v}%" for p, v in ms[k]["identical"].items()) for k in keys) + "。\n")
    for t in TYPES:
        n = next((ms[k]["by_type"][t].get("n") for k in keys if ms[k]["by_type"].get(t)), None)
        L.append(f"### {TYPE_ZH[t]} `{t}`（test {n} 张）\n")
        extra = TYPE_EXTRA[t]
        L.append("| 模型 | CER | 关键字段 EM | " + " | ".join(lab for _, lab in extra) +
                 " | QA 可答 | 编造数字 | 无出处字段 | 有编造的图 | 单路 p50 / p90 | 输出 token |")
        L.append("|" + "---|" * (9 + len(extra)))
        for k in keys:
            r = ms[k]["by_type"][t]
            L.append(f"| {ms[k]['display']} | {fmt(r.get('cer'), '%')} | {fmt(r.get('key_field_em'), '%')} | " +
                     " | ".join(fmt(r.get(e), '%') for e, _ in extra) +
                     f" | {fmt(r.get('qa_found'), '%')} | {fmt(r.get('fab_number_rate'), '%')} | {fmt(r.get('unsupported_rate'), '%')} | "
                     f"{fmt(r.get('halluc_img_rate'), '%')} | {fmt(r.get('latency_p50'))} / {fmt(r.get('latency_p90'))} s | "
                     f"{fmt(r.get('out_tokens_mean'))} |")
        L.append("")
    tags = sorted({t for k in keys for t in ms[k]["by_hard_tag"]})
    L.append("### 难例标签（test；CER / 关键字段 EM，两次均值；n 为该标签的图片数）\n")
    L.append("| 标签 | n | " + " | ".join(ms[k]["display"] for k in keys) + " |")
    L.append("|" + "---|" * (2 + len(keys)))
    for t in tags:
        n = next((ms[k]["by_hard_tag"][t]["n"] for k in keys if t in ms[k]["by_hard_tag"]), None)
        cells = []
        for k in keys:
            h = ms[k]["by_hard_tag"].get(t)
            cells.append("–" if not h else f"{fmt(h['cer'], '%')} / {fmt(h['key_field_em'], '%')}")
        L.append(f"| `{t}` | {n} | " + " | ".join(cells) + " |")
    L.append("")
    return "\n".join(L)


if __name__ == "__main__":
    main()
