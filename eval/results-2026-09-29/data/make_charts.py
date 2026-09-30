"""Charts for EVAL.md, rendered from ../eval.json in a light and a dark variant (1920x1080 PNG).

Palette: the dataviz reference instance (validated: slots 1-3 all-pairs, both modes); text in ink tokens,
thin bars capped in thickness, values direct-labelled, recessive hairline grid, one y-axis per panel.
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402

V5 = Path(__file__).resolve().parents[1]
OUT = V5 / "charts"
OUT.mkdir(exist_ok=True)
E = json.loads((V5 / "eval.json").read_text())

for f in ("/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"):
    if Path(f).exists():
        font_manager.fontManager.addfont(f)
        FONT = font_manager.FontProperties(fname=f).get_name()
        break
plt.rcParams["font.family"] = [FONT, "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

THEMES = {
    "light": dict(surface="#fcfcfb", page="#f9f9f7", ink="#0b0b0b", ink2="#52514e", muted="#898781", grid="#e1e0d9",
                  axis="#c3c2b7", s1="#2a78d6", s2="#eb6834", s3="#1baf7a", neutral="#b3b2ab", good="#006300"),
    "dark": dict(surface="#1a1a19", page="#0d0d0d", ink="#ffffff", ink2="#c3c2b7", muted="#898781", grid="#2c2c2a",
                 axis="#383835", s1="#3987e5", s2="#d95926", s3="#199e70", neutral="#5d5c57", good="#0ca30c"),
}
W, H, DPI = 12, 6.75, 160  # 1920 x 1080


def fig_base(t, title, subtitle, ncols=1, wspace=0.35, top=0.80, left=0.07, bottom=0.12):
    fig, axes = plt.subplots(1, ncols, figsize=(W, H), dpi=DPI)
    fig.patch.set_facecolor(t["surface"])
    axes = list(axes) if ncols > 1 else [axes]
    for ax in axes:
        style_ax(ax, t)
    fig.text(0.045, 0.94, title, fontsize=21, color=t["ink"], weight="bold", ha="left", va="top")
    fig.text(0.045, 0.875, subtitle, fontsize=12.5, color=t["ink2"], ha="left", va="top")
    fig.subplots_adjust(left=left, right=0.97, top=top, bottom=bottom, wspace=wspace)
    return fig, axes


def style_ax(ax, t):
    ax.set_facecolor(t["surface"])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(t["axis"])
    ax.tick_params(colors=t["ink2"], labelsize=12.5, length=0)
    ax.grid(axis="x", color=t["grid"], linewidth=1)
    ax.set_axisbelow(True)


def foot(fig, t, text):
    fig.text(0.045, 0.03, text, fontsize=10.5, color=t["muted"], ha="left", va="bottom")


def save(fig, name, theme):
    p = OUT / f"{name}-{theme}.png"
    fig.savefig(p, facecolor=fig.get_facecolor())
    plt.close(fig)
    return p


def hbars(ax, t, labels, series, colors, names, xmax=1.0, fmt="{:.2f}", bar_h=0.34, gap=0.04):
    """Grouped horizontal bars, one group per label, first label on top."""
    n = len(series)
    ys = list(range(len(labels)))[::-1]
    for k, (vals, c) in enumerate(zip(series, colors)):
        off = (n - 1) / 2 * (bar_h + gap) - k * (bar_h + gap)
        for y, v in zip(ys, vals):
            if v is None:
                continue
            ax.barh(y + off, v, height=bar_h, color=c, edgecolor=t["surface"], linewidth=2)
            ax.text(v + xmax * 0.01, y + off, fmt.format(v), va="center", ha="left", fontsize=12, color=t["ink"])
    ax.set_yticks(ys)
    ax.set_yticklabels(labels, fontsize=13, color=t["ink"])
    ax.set_xlim(0, xmax * 1.12)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in colors]
    ax.legend(handles, names, loc="lower right", bbox_to_anchor=(1.0, 1.0), ncol=len(names), frameon=False, fontsize=12,
              labelcolor=t["ink2"])


# ------------------------------------------------------------------ 1. organizer models on the held-out set
SHORT = {"Qwen3.6-35B-A3B NVFP4 (default)": "Qwen3.6-35B-A3B（默认）", "Qwen3.8-27B-FP8": "Qwen3.8-27B-FP8",
         "Muse Glimmer-30B NVFP4": "Muse Glimmer-30B", "DeepSeek-V4-Flash": "DeepSeek-V4-Flash（占 2 台）",
         "Nemotron-3-Super-120B-A12B NVFP4": "Nemotron-3-Super-120B", "Nemotron-3-Nano-Omni-30B-A3B NVFP4": "Nemotron-3-Nano-Omni",
         "GLM-4.7-Flash (30B-A3B, bf16)": "GLM-4.7-Flash", "Gemma 4 26B-A4B-it (bf16)": "Gemma 4 26B-A4B",
         "gpt-oss-120b (reasoning low, +2048 tok)": "gpt-oss-120b", "Mistral Small 4 119B NVFP4": "Mistral Small 4 NVFP4"}


def chart_models(theme):
    t = THEMES[theme]
    rows = [r for r in E["organizer_models"]["holdout-week-v2"] if r["b3_f1_mean"] is not None]
    multi = "、".join(f"{SHORT.get(r['label'], r['label']).replace('（默认）', '').split('-')[0].split(' ')[0]} {r['n']} 次" for r in rows if r["n"] > 1)
    fig, (a1, a2) = fig_base(t, "整理模型对比：留出集 holdout-week-v2（46 条、7 件事）",
                             f"同一套技能和代码（2e532bc），每个模型独占一台 Spark。跑了 2 次的（{multi.replace(' 2 次', '')}）取均值，细线为两次范围；其余 1 次。",
                             ncols=2, wspace=0.08, bottom=0.17)
    fig.subplots_adjust(left=0.27, right=0.95)
    ys = list(range(len(rows)))[::-1]
    abl = next(r for r in E["skills_ablation"]["rows"] if r["set"].startswith("holdout") and r["skill"] == "event-assign" and r["metric"] == "B³ F1")
    for val, lab in ((abl["baselines"]["lexical τ=0.41"], "词法基线"), (abl["baselines"]["vector τ=0.60"], "向量基线")):
        a1.axvline(val, color=t["muted"], linewidth=1.2, linestyle=(0, (2, 3)), zorder=0.5)
        right = lab == "词法基线"
        a1.text(val + (0.01 if right else -0.01), -0.72, f"{lab} {val:.2f}", color=t["muted"], fontsize=10.5,
                ha="left" if right else "right", va="top")
    for y, r in zip(ys, rows):
        default = "default" in r["label"]
        c = t["s1"] if default else t["neutral"]
        v = r["b3_f1_mean"]
        a1.barh(y, v, height=0.36, color=c, edgecolor=t["surface"], linewidth=2)
        if r["n"] > 1:
            a1.plot(r["b3_f1_range"], [y, y], color=t["ink"], linewidth=1.5)
        lx = (r["b3_f1_range"][1] if r["n"] > 1 else v) + 0.012
        a1.text(lx, y, f"{v:.3f}", va="center", fontsize=12.5, color=t["ink"],
                weight="bold" if default else "normal")
        s = r["s_per_item_mean"]
        a2.barh(y, s, height=0.36, color=c, edgecolor=t["surface"], linewidth=2)
        a2.text(s + 1, y, f"{s:.0f} 秒/条", va="center", fontsize=12.5, color=t["ink"])
    a1.set_yticks(ys)
    a1.set_yticklabels([SHORT.get(r["label"], r["label"]) for r in rows], fontsize=13, color=t["ink"])
    a1.set_xlim(0, 1.0)
    a1.set_ylim(-1.25, len(rows) - 0.5)
    a2.set_ylim(-1.25, len(rows) - 0.5)
    a1.set_title("B³ F1（事件归属质量）↑", fontsize=14, color=t["ink"], loc="left", pad=8)
    a2.set_yticks(ys)
    a2.set_yticklabels([""] * len(rows))
    a2.set_xlim(0, max(r["s_per_item_mean"] for r in rows) * 1.3)
    a2.set_title("每条素材整理耗时 ↓", fontsize=14, color=t["ink"], loc="left", pad=8)
    fails = [f for f in E["organizer_models"]["not_scored"] if f.get("short")]
    note = ("没评上分：" + "；".join(f"{f.get('chart_name', f['model'])}（{f['short']}）" for f in fails)) if fails else ""
    foot(fig, t, (note + "\n" if note else "") + "出处：eval/models-v2/*、eval/results-2026-09-29/data/org/*。n = 1–2，默认模型两次之间就差 0.065，几个点的差距不稳定。")
    return save(fig, "01-organizer-models-holdout", theme)


# ------------------------------------------------------------------ 2. skill text ablation
def chart_ablation(theme):
    t = THEMES[theme]
    rows = {(r["skill"], r["metric"], r["set"].split(" ")[0]): r for r in E["skills_ablation"]["rows"]}
    items = [
        ("事件归属 B³ F1 · 留出集", rows[("event-assign", "B³ F1", "holdout-week-v2")]),
        ("卡片事实召回 · 留出集", rows[("event-brief", "card fact recall", "holdout-week-v2")]),
        ("首页 NDCG@5 · 留出集", rows[("home-rank", "home NDCG@5", "holdout-week-v2")]),
        ("读图关键字段准确 · 98 张", rows[("image-read", "key-field exact match", "mm-v1")]),
        ("读图类型判对 · 98 张", rows[("image-read", "image type correct", "mm-v1")]),
        ("文件概要一次合格 · 38 个", rows[("file-read", "summary valid on first try", "files-v1")]),
    ]
    fig, (ax,) = fig_base(t, "技能正文的作用：同一个模型，有 / 没有 SKILL.md 正文",
                          "没有正文时保留全局规则、JSON schema、校验器和重试，只去掉技能说明；每个条件 2 次取均值。", left=0.24, top=0.76)
    hbars(ax, t, [a for a, _ in items], [[r["with"] for _, r in items], [r["without"] for _, r in items]],
          [t["s1"], t["s2"]], ["有技能正文", "无技能正文"])
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_xticklabels(["0", "0.25", "0.50", "0.75", "1.00"])
    foot(fig, t, "出处：skills/event-assign|event-brief|home-rank|image-read|file-read/BENCHMARK.md（最终版本一节）。检索基线的留出集 B³ F1：向量 0.336、词法 0.463。")
    return save(fig, "02-skill-ablation", theme)


# ------------------------------------------------------------------ 3. scale runs vs no-model baseline
def chart_scale(theme):
    t = THEMES[theme]
    m = E["scale_runs"]["metrics"]
    fig, axes = fig_base(t, "规模场景：每个 1,500–1,600 条素材，对比无模型基线",
                         "三个虚构人物各五到六周的素材一次性粘贴，由一台 Spark 整理完后打分。startup 是留出场景。", ncols=4, wspace=0.28,
                         top=0.76, bottom=0.17)
    scen = ["lab", "startup", "pm"]
    names = {"lab": "实验室", "startup": "创业\n（留出）", "pm": "产品经理"}
    panels = [("b3_f1", "B³ F1 ↑"), ("link_f1", "Link F1 ↑"), ("segment_link_f1", "段级 Link F1 ↑"), ("lookalike_leak_hard", "易混事件泄漏 ↓")]
    for ax, (key, lab) in zip(axes, panels):
        ax.grid(axis="x", visible=False)
        ax.grid(axis="y", color=t["grid"], linewidth=1)
        xs = range(len(scen))
        bw = 0.28
        for k, (suffix, c, nm) in enumerate((("", t["s1"], "织机"), ("_baseline", t["neutral"], "无模型基线"))):
            vals = [m[key + suffix][s] for s in scen]
            pos = [x + (k - 0.5) * (bw + 0.04) for x in xs]
            ax.bar(pos, vals, width=bw, color=c, edgecolor=t["surface"], linewidth=2, label=nm)
            for p, v in zip(pos, vals):
                ax.text(p, v + 0.02, f"{v:.2f}", ha="center", va="bottom", fontsize=11, color=t["ink"])
        ax.set_xticks(list(xs))
        ax.set_xticklabels([names[s] for s in scen], fontsize=12, color=t["ink"])
        ax.set_ylim(0, 1.0)
        ax.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
        ax.set_title(lab, fontsize=14.5, color=t["ink"], loc="left", pad=10)
    axes[0].legend(loc="upper right", frameon=False, fontsize=11.5, labelcolor=t["ink2"])
    foot(fig, t, "出处：eval/scale/README.md。基线 = 字符二元组哈希相似度（三个阈值取最好）。最大弱点是碎片化：预测事件数是真值的 11–17 倍。")
    return save(fig, "03-scale-vs-baseline", theme)


# ------------------------------------------------------------------ 4. per-skill latency and token share
def chart_latency(theme):
    t = THEMES[theme]
    pooled = E["per_skill_latency_tokens"]["pooled_three_runs"]
    st = E["per_skill_latency_tokens"]["startup"]["skills"]
    order = ["event-assign", "item-split", "screenshot-read", "event-brief", "home-rank"]
    zh = {"event-assign": "事件归属 event-assign", "item-split": "多事拆分 item-split", "screenshot-read": "读截图 screenshot-read",
          "event-brief": "事件卡片 event-brief", "home-rank": "首页排序 home-rank"}
    fig, (a1, a2) = fig_base(t, "每个技能在 Spark 上花多少时间和 token",
                             "三个规模场景的真实调用记录（共 21,542 次，Qwen3.6-35B-A3B NVFP4），没有另跑；右图为 startup 场景。", ncols=2, wspace=0.08,
                             left=0.2, top=0.8, bottom=0.16)
    ys = list(range(len(order)))[::-1]
    for y, k in zip(ys, order):
        p50, p95 = pooled[k]["latency_p50_s"], pooled[k]["latency_p95_s"]
        a1.barh(y, p50, height=0.32, color=t["s1"], edgecolor=t["surface"], linewidth=2)
        a1.plot([p50, p95], [y, y], color=t["ink2"], linewidth=2)
        a1.scatter([p95], [y], s=60, color=t["ink2"], zorder=3, edgecolor=t["surface"], linewidth=2)
        a1.text(p95 + 0.8, y, f"p50 {p50:.1f} s · p95 {p95:.1f} s", va="center", fontsize=11.5, color=t["ink"])
    a1.set_yticks(ys)
    a1.set_yticklabels([zh[k] for k in order], fontsize=12.5, color=t["ink"])
    a1.set_xlim(0, 62)
    a1.set_xlabel("单次调用耗时（秒）：条 = 中位数，点 = p95", color=t["ink2"], fontsize=12)
    for y, k in zip(ys, order):
        share = st[k]["share_of_prompt_tokens"]
        a2.barh(y, share * 100, height=0.32, color=t["s2"], edgecolor=t["surface"], linewidth=2)
        extra = f"（{st[k]['calls']:,} 次，被拒 {1 - st[k]['ok_rate']:.0%}）" if k == "event-brief" else f"（{st[k]['calls']:,} 次）"
        pct_txt = "<1%" if share < 0.01 else f"{share:.0%}"
        a2.text(share * 100 + 1, y, f"{pct_txt}{extra}", va="center", fontsize=11.5, color=t["ink"])
    a2.set_yticks(ys)
    a2.set_yticklabels([""] * len(order))
    a2.set_xlim(0, 125)
    a2.set_xticks([0, 20, 40, 60, 80, 100])
    a2.set_xlabel("占输入 token 的比例（%）", color=t["ink2"], fontsize=12)
    lat = E["per_skill_latency_tokens"]
    foot(fig, t, f"端到端：每条素材约 {lat['startup']['calls_per_item']} 次调用、{lat['startup']['prompt_tokens_per_item']:,} 输入 token，约 3.7–4.0 条/分钟（GPU 利用率 87–94%）。\n"
                 f"出处：eval/results-2026-09-29/data/ledger_latency.json（规模场景 Spark 上的调用记录）")
    return save(fig, "04-per-skill-latency-tokens", theme)


# ------------------------------------------------------------------ 5. file read, 33 formats
def chart_files(theme):
    t = THEMES[theme]
    mf = E["file_read"]["multiformat_33"]
    if "full_path" not in mf:
        return None
    layers = [("layer:full", "有文字层（66 个）"), ("layer:partial", "部分内容在图里（13 个）"), ("layer:none", "纯图片 / 扫描 / 视频（36 个）"), ("all", "全部 115 个")]
    fig, (ax,) = fig_base(t, "读文件：33 种格式、115 个测试文件，金标准答案有没有被读出来",
                          "同一条整理器路径（沙箱解析 → 扫描页 / 嵌入图片交给 image-read → file-read 概要）；对照只做解析、不调模型。",
                          left=0.27, top=0.76, bottom=0.17)
    ex = mf["excluding_mac_routed_types"]
    labels = [b for _, b in layers] + ["不含 HEIC / 视频的 30 种（104 个）"]
    po = [mf["parse_only"][a]["qa_acc"] for a, _ in layers] + [ex["parse_only"]["answer_present"]]
    fp = [(mf["full_path"][a]["qa_acc"] + mf["full_path_r2"][a]["qa_acc"]) / 2 for a, _ in layers] + \
         [(ex["full_path"]["answer_present"] + ex["full_path_r2"]["answer_present"]) / 2]
    hbars(ax, t, labels, [fp, po], [t["s1"], t["neutral"]], ["解析 + 读图 + 概要（产品路径，2 次均值）", "只解析，不调模型"])
    ax.set_xlabel("金标准答案出现在读取结果里的比例（测试集 412 道题）", color=t["ink2"], fontsize=12)
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    foot(fig, t, "HEIC 由 Mac 转码、视频由 Mac 取音轨和关键帧，Spark 端按文件读会报 unsupported（11 个文件），所以纯图片一组偏低。\n出处：eval/files-multiformat（合成）、eval/results-2026-09-29/data/multiformat-*.json；Qwen3.6-35B-A3B NVFP4。")
    return save(fig, "05-file-read-33-formats", theme)


# ------------------------------------------------------------------ 6. privacy egress census
def chart_egress(theme):
    t = THEMES[theme]
    runs = E["privacy_egress"]["runs"]
    scen = [("lab", "实验室（1,508 条）"), ("startup", "创业（1,600 条）"), ("pm", "产品经理（1,600 条）")]
    fig, (ax,) = fig_base(t, "隐私：Spark 实际收到了什么（三个规模场景的实测字节）",
                          "从 Spark 上整理器数据库逐条统计 Mac 发来的内容（只读、只出汇总）。音频、声纹、说话人向量、词典没有字段，也没有出现。",
                          left=0.17, top=0.78, bottom=0.2)
    ys = list(range(len(scen)))[::-1]
    parts = [("text", "粘贴 / 口述文字", t["s1"]), ("document", "文档文字", t["s2"]), ("image", "截图（JPEG）", t["s3"])]
    for y, (s, lab) in zip(ys, scen):
        left = 0
        for key, nm, c in parts:
            d = runs[s]["by_kind"][key]
            mb = (d.get("text_bytes") or d.get("blob_bytes") or 0) / 1e6
            ax.barh(y, mb, left=left, height=0.34, color=c, edgecolor=t["surface"], linewidth=2, label=nm if y == ys[0] else None)
            if mb > 2.5:
                ax.text(left + mb / 2, y, f"{mb:.1f} MB", ha="center", va="center", fontsize=11.5, color="#ffffff")
            left += mb
        tx = runs[s]["by_kind"]["text"]["text_bytes"] / 1e6
        dc = runs[s]["by_kind"]["document"]["text_bytes"] / 1e6
        ax.text(left + 0.15, y, f"共 {left:.1f} MB（文字 {tx:.1f} + 文档 {dc:.1f} + 截图）\n音频 0 B · 声纹 / 向量 0", va="center",
                fontsize=12, color=t["ink"], linespacing=1.5)
    ax.set_yticks(ys)
    ax.set_yticklabels([b for _, b in scen], fontsize=13, color=t["ink"])
    ax.set_xlim(0, 19)
    ax.set_xlabel("收到的字节（MB）", color=t["ink2"], fontsize=12)
    ax.legend(loc="lower right", bbox_to_anchor=(1.0, 1.0), frameon=False, fontsize=12, labelcolor=t["ink2"], ncol=3)
    foot(fig, t, "162 张 JPEG 的 EXIF 只剩像素尺寸和色彩空间，GPS 0 张。音频/视频魔数 0 个；长度 ≥ 32 的浮点向量 0 个。模型和整理服务只监听 127.0.0.1。\n"
                 "注意：这批素材本来就不含音频（口述以文字粘贴）；「不发音频」由 Mac 端字段白名单和哨兵测试保证。出处：eval/results-2026-09-29/data/egress.json")
    return save(fig, "06-privacy-egress", theme)


made = []
for th in THEMES:
    for fn in (chart_models, chart_ablation, chart_scale, chart_latency, chart_files, chart_egress):
        p = fn(th)
        if p:
            made.append(str(p))
print("\n".join(made))
