"""Charts for docs/EVALUATION.md (public repository), rendered from ../eval.json in a light and a dark variant (1920x1080 PNG).

Same visual system as v5/data/make_charts.py (helpers copied unchanged): the dataviz reference palette (slots 1-3
validated all-pairs in both modes), text in ink tokens, thin bars, values direct-labelled, recessive hairline grid,
one y-axis per panel. Series roles: s1 = v6 / the product path, s2 = before (v5) / the comparison, neutral = baseline
or control.
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402

V6 = Path(__file__).resolve().parents[1]  # eval/results-2026-09-30
OUT = V6 / "charts"
OUT.mkdir(exist_ok=True)
E = json.loads((V6 / "eval.json").read_text())
V5 = E["v5_carried_over"]

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


def vgrid(ax, t):
    ax.grid(axis="x", visible=False)
    ax.grid(axis="y", color=t["grid"], linewidth=1)


def foot(fig, t, text):
    fig.text(0.045, 0.03, text, fontsize=10.5, color=t["muted"], ha="left", va="bottom")


def save(fig, name, theme):
    p = OUT / f"{name}-{theme}.png"
    fig.savefig(p, facecolor=fig.get_facecolor(), metadata={"Software": None})
    plt.close(fig)
    return p


def legend_top(ax, t, handles, names, ncol=None):
    ax.legend(handles, names, loc="lower right", bbox_to_anchor=(1.0, 1.0), ncol=ncol or len(names), frameon=False, fontsize=12,
              labelcolor=t["ink2"])


def fig_legend(fig, t, colors, names, y=0.80):
    fig.legend([plt.Rectangle((0, 0), 1, 1, color=c) for c in colors], names, loc="upper right", bbox_to_anchor=(0.97, y),
               ncol=len(names), frameon=False, fontsize=12, labelcolor=t["ink2"])


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
    legend_top(ax, t, [plt.Rectangle((0, 0), 1, 1, color=c) for c in colors], names)


def vgroups(ax, t, groups, series, colors, fmt="{:.2f}", bw=0.24, ymax=1.0, label_pad=0.015, fs=11):
    """Grouped vertical bars: groups on x, one bar per series inside each group."""
    n = len(series)
    last = {}  # group -> label y of the previous bar in that group (nudge labels of neighbours with close values)
    for k, (vals, c) in enumerate(zip(series, colors)):
        pos = [x + (k - (n - 1) / 2) * (bw + 0.03) for x in range(len(groups))]
        for g, (p, v) in enumerate(zip(pos, vals)):
            if v is None:
                continue
            ax.bar(p, v, width=bw, color=c, edgecolor=t["surface"], linewidth=2)
            ly = v + ymax * label_pad
            if n >= 3 and g in last and abs(ly - last[g]) < ymax * 0.055:
                ly = last[g] + ymax * 0.055
            last[g] = ly
            ax.text(p, ly, fmt.format(v), ha="center", va="bottom", fontsize=fs, color=t["ink"])
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels(groups, fontsize=12, color=t["ink"])
    ax.set_ylim(0, ymax)


SC_ZH = {"lab": "实验室", "pm": "产品经理", "startup": "创业\n（留出）", "lab-v3": "实验室\n演示副本"}


# ------------------------------------------------------------------ 01 scale scenarios vs baseline, before / after consolidation
def chart_scale(theme):
    t = THEMES[theme]
    S = E["scale_consolidation"]["scenarios"]
    scen = ["lab", "pm", "startup"]
    fig, axes = fig_base(t, "规模场景：加了事件合并（event-consolidate）之后，对比整理前和无模型基线",
                         "三个虚构人物各 1,510–1,600 条素材，同一套评分器。startup 是留出场景，从没用来调参。每个场景运行时整理跑了 1 次。",
                         ncols=3, wspace=0.22, top=0.70, bottom=0.17, left=0.06)
    panels = [("bcubed_f1", "baseline_b3_f1", "B³ F1（归事件质量）↑", 1.0),
              ("link_f1", "baseline_link_f1", "Link F1（真事一对一对上）↑", 1.0),
              ("hard_decoy_leakage", "baseline_hard_decoy_leakage", "难干扰泄漏（相像的两件事被混）↓", 1.0)]
    colors = [t["neutral"], t["s2"], t["s1"]]
    for ax, (key, bkey, lab, ymax) in zip(axes, panels):
        vgrid(ax, t)
        series = [[S[s][bkey] for s in scen], [S[s]["before"][key] for s in scen], [S[s]["after"][key] for s in scen]]
        vgroups(ax, t, [SC_ZH[s] for s in scen], series, colors, ymax=ymax, bw=0.25, fs=10.5)
        ax.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
        ax.set_title(lab, fontsize=14, color=t["ink"], loc="left", pad=10)
    fig_legend(fig, t, colors, ["无模型基线", "整理前（v5）", "加了事件合并（v6）"])
    h = E["headline"]
    foot(fig, t, f"B³ F1 是基线的 {h['b3_vs_baseline_range'][0]:.1f}–{h['b3_vs_baseline_range'][1]:.1f} 倍；提高全部来自召回，精确率持平或略降。"
                 "代价：lab 的难干扰泄漏升高（一件演示被并进了它演示的实验）。\n"
                 "出处：v6/quality/QUALITY.md 第一轮 §3（代码 f4fe3ed）；基线 = 字符二元组相似度，scale/SUMMARY.md。")
    return save(fig, "01-scale-vs-baseline", theme)


# ------------------------------------------------------------------ 02 predicted matters vs truth
def chart_matters(theme):
    t = THEMES[theme]
    S = E["scale_consolidation"]["scenarios"]
    scen = ["lab", "pm", "startup", "lab-v3"]
    names = {"lab": "实验室（dev）", "pm": "产品经理（dev）", "startup": "创业（留出）", "lab-v3": "实验室演示副本"}
    fig, (ax,) = fig_base(t, "碎片化：整理出的事件数，对比真实的事件数",
                          "同一批素材，整理前（v5）和运行时事件合并之后（v6）。竖线 = 真值，虚线 = 目标上限（真值的 3 倍）。",
                          left=0.16, top=0.78, bottom=0.17)
    ys = list(range(len(scen)))[::-1]
    bh = 0.3
    for y, s in zip(ys, scen):
        r = S[s]
        for off, part, c in ((bh / 2 + 0.02, "before", t["s2"]), (-bh / 2 - 0.02, "after", t["s1"])):
            n = r[part]["pred_event_count"]
            one = r[part]["singletons"]
            ax.barh(y + off, n, height=bh, color=c, edgecolor=t["surface"], linewidth=2)
            tag = "v2 状态，" if (s == "lab-v3" and part == "before") else ""
            ax.text(max(n, 3 * r["true_events"]) + 5, y + off, f"{n} 件（{tag}其中只有 1 条的 {one} 件）", va="center", fontsize=11.5, color=t["ink"])
        tr = r["true_events"]
        ax.plot([tr, tr], [y - 0.42, y + 0.42], color=t["ink"], linewidth=2, zorder=4)
        ax.plot([3 * tr, 3 * tr], [y - 0.42, y + 0.42], color=t["muted"], linewidth=1.4, linestyle=(0, (2, 2)), zorder=4)
    ax.text(S["lab"]["true_events"], ys[0] + 0.5, "真值", ha="center", va="bottom", fontsize=11, color=t["ink"])
    ax.text(3 * S["lab"]["true_events"], ys[0] + 0.5, "3 倍", ha="center", va="bottom", fontsize=11, color=t["muted"])
    ax.set_yticks(ys)
    ax.set_yticklabels([f"{names[s]}\n真值 {S[s]['true_events']} 件" for s in scen], fontsize=12.5, color=t["ink"])
    ax.set_xlim(0, 470)
    ax.set_ylim(-0.6, len(scen) - 0.3)
    ax.set_xlabel("事件数", color=t["ink2"], fontsize=12)
    legend_top(ax, t, [plt.Rectangle((0, 0), 1, 1, color=c) for c in (t["s2"], t["s1"])], ["整理前（v5）", "加了事件合并（v6）"])
    foot(fig, t, "startup 没有降到 3 倍以内（84 件 = 4.2 倍；中间版本 68 件）。演示副本是从一份已经合并过一次的状态（184 件）继续整理的。\n"
                 "出处：v6/quality/QUALITY.md 第一轮 §3；只有 1 条的事件由 quality/tools/frag.py 统计。")
    return save(fig, "02-matters-vs-truth", theme)


# ------------------------------------------------------------------ 03 masking on / off with per-run dots
def chart_masking(theme):
    t = THEMES[theme]
    runs = E["masking_eval"]["per_run"]
    cols = [("numbers", "off", "压力集\n不遮号", t["s2"]), ("numbers", "on", "压力集\n遮号", t["s1"]),
            ("holdout", "off", "对照 A\n（输入相同）", t["neutral"]), ("holdout", "on", "对照 B\n（输入相同）", t["neutral"])]
    fig, axes = fig_base(t, "遮号会不会影响整理效果：同一套数据，遮号和不遮号各跑 5 次",
                         "压力集 = 46 条留出集里写进 37 处合成号码。对照 = 原留出集：里面没有号码，两组输入逐字节相同，差距全是运行波动。\n"
                         "点 = 每次运行，横线 = 均值，竖线 = ±1 标准差。压力集各 5 次，对照各 3 次。",
                         ncols=3, wspace=0.22, top=0.73, bottom=0.2, left=0.06)
    import statistics
    panels = [("bcubed_f1", "B³ F1 ↑"), ("link_f1", "Link F1 ↑"), ("card_fact_recall", "卡片事实召回 ↑")]
    for ax, (key, lab) in zip(axes, panels):
        vgrid(ax, t)
        for x, (st, mk, _, c) in enumerate(cols):
            vals = [r[key] for r in runs if r["set"] == st and r["mask"] == mk]
            n = len(vals)
            xs = [x + (i - (n - 1) / 2) * 0.07 for i in range(n)]
            ax.scatter(xs, vals, s=70, color=c, edgecolor=t["surface"], linewidth=2, zorder=3)
            ag = E["masking_eval"]["aggregate"][st][mk][key]
            m, sd = ag["mean"], ag["sd"]
            ax.plot([x - 0.3, x + 0.3], [m, m], color=t["ink"], linewidth=2, zorder=4)
            ax.plot([x + 0.34, x + 0.34], [m - sd, m + sd], color=t["ink2"], linewidth=1.5, zorder=4)
            ax.text(x, 0.165, f"{m:.3f}\n±{sd:.3f}", ha="center", va="bottom", fontsize=10.5, color=t["ink"], linespacing=1.3)
        ax.axvline(1.5, color=t["axis"], linewidth=1)
        ax.set_xticks(range(len(cols)))
        ax.set_xticklabels([c[2] for c in cols], fontsize=11, color=t["ink"])
        ax.set_xlim(-0.55, len(cols) - 0.45)
        ax.set_ylim(0.15, 0.9)
        ax.set_yticks([0.3, 0.45, 0.6, 0.75, 0.9])
        ax.set_title(lab, fontsize=14, color=t["ink"], loc="left", pad=10)
    p = E["masking_eval"]["paired_calls_numbers_set"]
    foot(fig, t, f"去掉整条运行的连锁波动（成对调用，同一上下文）：归事件和不遮号版本相同 {p['event_assign']['same_as_unmasked']}/{p['event_assign']['calls']}，"
                 f"和原样再发相同 {p['event_assign']['same_as_replay']}/{p['event_assign']['calls']}；卡片说到的金标准事实 {p['event_brief']['gold_facts_named_unmasked']} 对 {p['event_brief']['gold_facts_named_replay']}。\n"
                 "n = 5 只能排除约 0.05 以上的 B³ F1 影响。出处：v6/privacy/MASK-EVAL.md §2–§3、v6/privacy/mask-eval.json（代码 ef3392a，遮号规则 v1）。")
    return save(fig, "03-masking-on-off", theme)


# ------------------------------------------------------------------ 04 item-split over-splitting
def chart_split(theme):
    t = THEMES[theme]
    sp = E["item_split"]
    fr = E["heldout_full_run"]
    groups = ["实验室\n（dev）", "产品经理\n（dev）", "创业（留出）\n只切不归", "创业（留出）\n完整运行"]
    before_o = [sp["lab"]["v1.1.1_stored"]["single_matter_oversplit_rate"], sp["pm"]["v1.1.1_stored"]["single_matter_oversplit_rate"],
                sp["startup"]["v1.1.1_stored"]["single_matter_oversplit_rate"], fr["startup-A"]["oversplit"]]
    after_o = [sp["lab"]["v1.3.0"]["single_matter_oversplit_rate"], sp["pm"]["v1.3.0"]["single_matter_oversplit_rate"],
               sp["startup"]["v1.3.0"]["single_matter_oversplit_rate"], fr["startup-B"]["oversplit"]]
    before_r = [sp["lab"]["v1.1.1_stored"]["matter_recall_in_multi"], sp["pm"]["v1.1.1_stored"]["matter_recall_in_multi"],
                sp["startup"]["v1.1.1_stored"]["matter_recall_in_multi"], fr["startup-A"]["matter_recall_in_multi"]]
    after_r = [sp["lab"]["v1.3.0"]["matter_recall_in_multi"], sp["pm"]["v1.3.0"]["matter_recall_in_multi"],
               sp["startup"]["v1.3.0"]["matter_recall_in_multi"], fr["startup-B"]["matter_recall_in_multi"]]
    fig, (a1, a2) = fig_base(t, "多事拆分 item-split：只讲一件事的素材被切开的比例",
                             "item-split 1.3.0 参照用户已有的事件来切，顺带一提的不切。\n"
                             "前三组是只切不归的重放（1.1.1 → 1.3.0），最后一组是留出场景的完整运行（1.2.0 → 1.3.0）。",
                             ncols=2, wspace=0.2, top=0.70, bottom=0.2, left=0.06)
    for ax in (a1, a2):
        vgrid(ax, t)
    vgroups(a1, t, groups, [[v * 100 for v in before_o], [v * 100 for v in after_o]], [t["s2"], t["s1"]], fmt="{:.1f}%", ymax=40, bw=0.32)
    a1.set_yticks([0, 10, 20, 30, 40])
    a1.set_yticklabels(["0", "10%", "20%", "30%", "40%"])
    a1.set_title("只讲一件事却被切开 ↓", fontsize=14, color=t["ink"], loc="left", pad=10)
    vgroups(a2, t, groups, [before_r, after_r], [t["s2"], t["s1"]], fmt="{:.2f}", ymax=1.0, bw=0.32)
    a2.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
    a2.set_title("讲了几件事的素材里，每件事被找回 ↑（不该变差）", fontsize=14, color=t["ink"], loc="left", pad=10)
    fig_legend(fig, t, (t["s2"], t["s1"]), ["之前", "item-split 1.3.0"])
    foot(fig, t, "dev 场景的重放里 known_matters 用的是整理完的最终事件标题，对早期素材偏乐观；完整运行里用的是实时的事件目录。每个条件跑 1 次。\n"
                 "出处：v6/quality/QUALITY.md 第二轮 §3（只切不归，eval/tools/split_scale.py）、§4（完整运行，A = 8ecc90f，B = abd9cf0）。")
    return save(fig, "04-item-split-oversplit", theme)


# ------------------------------------------------------------------ 05 people
def chart_people(theme):
    t = THEMES[theme]
    P = E["people"]
    scen = ["lab", "pm", "startup"]
    fig, axes = fig_base(t, "人物：说话人规则、中英文名合并、按名字连上提到他的素材（person-resolve）",
                         "在三个规模场景整理后的状态上，用新代码让运行时的人物整理自己跑完，再用同一个评分器打分。每个场景 1 次。",
                         ncols=3, wspace=0.24, top=0.70, bottom=0.17, left=0.06)
    panels = [("person_link_degraded", "人物关联（规模报告的口径）↑", 1.0, "{:.2f}"),
              ("item_level_recall", "条目级人物召回 ↑", 1.0, "{:.2f}"),
              ("not_a_scenario_person", "不是任何场景人物的「人」↓", 100, "{:.0f}")]
    for ax, (key, lab, ymax, fmt) in zip(axes, panels):
        vgrid(ax, t)
        vgroups(ax, t, [SC_ZH[s] for s in scen], [[P[s]["before"][key] for s in scen], [P[s]["after"][key] for s in scen]],
                [t["s2"], t["s1"]], fmt=fmt, ymax=ymax, bw=0.32)
        ax.set_title(lab, fontsize=14, color=t["ink"], loc="left", pad=10)
        if ymax == 1.0:
            ax.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
    fig_legend(fig, t, (t["s2"], t["s1"]), ["之前", "人物整理之后"])
    pr = [P[s]["after"]["item_level_precision"] for s in scen]
    foot(fig, t, f"条目级精确率：lab {pr[0]:.3f}、startup {pr[2]:.3f}；pm {pr[1]:.3f} 是因为 pm 的金标准人物表不全（按原文核对，97.9% 的连接是素材里写着的场景人物）。\n"
                 "出处：v6/quality/QUALITY.md 第二轮 §3（person-resolve 1.2.0，代码 8138c7f）。")
    return save(fig, "05-people-linking", theme)


# ------------------------------------------------------------------ 06 consolidation cost
def chart_cost(theme):
    t = THEMES[theme]
    C = E["consolidation_cost"]["per_library"]
    lat = V5["per_skill_latency_tokens"]
    scen = ["lab", "pm", "startup", "lab-v3"]
    names = {"lab": "实验室（1,510 条）", "pm": "产品经理（1,600 条）", "startup": "创业（1,600 条）", "lab-v3": "实验室演示副本"}
    fig, (a1, a2) = fig_base(t, "事件合并的代价：一个 1,500–1,600 条的库整理一次",
                             "左：输入 token（百万）。整理素材本身的 token 来自 v5 规模运行的调用记录；事件合并含合并后重写卡片。右：墙钟时间。",
                             ncols=2, wspace=0.08, top=0.78, bottom=0.18, left=0.17)
    ys = list(range(len(scen)))[::-1]
    for y, s in zip(ys, scen):
        c = C[s]
        base = c["organizing_prompt_tokens_v5"] / 1e6
        cons = c["consolidate_prompt_tokens"] / 1e6
        reb = c["rebrief_prompt_tokens"] / 1e6
        a1.barh(y, base, height=0.36, color=t["neutral"], edgecolor=t["surface"], linewidth=2)
        a1.barh(y, cons, left=base, height=0.36, color=t["s1"], edgecolor=t["surface"], linewidth=2)
        a1.barh(y, reb, left=base + cons, height=0.36, color=t["s2"], edgecolor=t["surface"], linewidth=2)
        a1.text(base + cons + reb + 1.5, y, f"+{c['overhead_share']:.1%}", va="center", fontsize=12.5, color=t["ink"], weight="bold")
        a1.text(base / 2, y, f"{base:.1f} M", va="center", ha="center", fontsize=11.5, color=t["ink"])
        sc = "lab" if s == "lab-v3" else s
        org_min = lat[sc]["organize_minutes"]
        a2.barh(y, org_min / 60, height=0.36, color=t["neutral"], edgecolor=t["surface"], linewidth=2)
        a2.barh(y, c["busy_minutes"] / 60, left=org_min / 60, height=0.36, color=t["s1"], edgecolor=t["surface"], linewidth=2)
        a2.text(org_min / 60 + c["busy_minutes"] / 60 + 0.12, y, f"{org_min / 60:.1f} 小时 + {c['busy_minutes']:.0f} 分钟", va="center",
                fontsize=11.5, color=t["ink"])
    a1.set_yticks(ys)
    a1.set_yticklabels([names[s] for s in scen], fontsize=12.5, color=t["ink"])
    a1.set_xlim(0, 100)
    a1.set_xlabel("输入 token（百万）", color=t["ink2"], fontsize=12)
    a2.set_yticks(ys)
    a2.set_yticklabels([""] * len(scen))
    a2.set_xlim(0, 10.5)
    a2.set_xlabel("小时：整理素材（v5）+ 事件合并（v6）", color=t["ink2"], fontsize=12)
    legend_top(a2, t, [plt.Rectangle((0, 0), 1, 1, color=c) for c in (t["neutral"], t["s1"], t["s2"])],
               ["整理素材本身", "event-consolidate", "合并后重写卡片"])
    fr = E["heldout_full_run"]
    foot(fig, t, f"合并只在空闲时跑，调用 289–479 次、每次约 1 万输入 token，目录部分同一轮共享（前缀缓存）。边整理边合并的完整运行里，合并占输入 token 的 "
                 f"{fr['startup-A']['consolidate_share_of_prompt_tokens']:.1%} / {fr['startup-B']['consolidate_share_of_prompt_tokens']:.1%}。\n"
                 "合并的时间是在和别的任务共用的 Spark 上量的。出处：v6/quality/QUALITY.md 第一轮 §5、第二轮 §4；v5/eval.json（规模运行调用记录）。")
    return save(fig, "06-consolidation-cost", theme)


# ------------------------------------------------------------------ 07 privacy review fixes + Spark storage
def chart_privacy(theme):
    t = THEMES[theme]
    pv = E["privacy"]
    st = pv["spark_storage"]
    fig, (a1, a2) = fig_base(t, "隐私：评审找到的缺口修好了多少，Spark 上还存多少",
                             f"Mac ↔ Spark 隐私端到端检查 {pv['e2e']['final']}，手机端到端 {E['phone']['e2e']['final']}（全部合成数据）。",
                             ncols=2, wspace=0.42, top=0.70, bottom=0.2, left=0.2)
    rd = pv["screenshot_redaction"]
    nl = rd["synthetic_layouts"]
    rows = [("30 种常见号码写法\n被遮住", 0, 30, 30),
            (f"{nl} 种合成截图布局\nSpark 模型读不出号码", nl - rd["legible_before_fix"], nl - rd["legible_after_fix"], nl)]
    ys = [1, 0]
    for y, (lab, b, a, n) in zip(ys, rows):
        a1.barh(y + 0.2, b / n, height=0.34, color=t["s2"], edgecolor=t["surface"], linewidth=2)
        a1.barh(y - 0.2, a / n, height=0.34, color=t["s1"], edgecolor=t["surface"], linewidth=2)
        a1.text(b / n + 0.02, y + 0.2, f"{b}/{n}", va="center", fontsize=12, color=t["ink"])
        a1.text(a / n + 0.02, y - 0.2, f"{a}/{n}", va="center", fontsize=12, color=t["ink"])
    a1.set_yticks(ys)
    a1.set_yticklabels([r[0] for r in rows], fontsize=12.5, color=t["ink"])
    a1.set_xlim(0, 1.2)
    a1.set_xticks([0, 0.5, 1.0])
    a1.set_xticklabels(["0", "50%", "100%"])
    a1.set_title("评审发现 → 修复后", fontsize=14, color=t["ink"], loc="left", pad=36)
    legend_top(a1, t, [plt.Rectangle((0, 0), 1, 1, color=c) for c in (t["s2"], t["s1"])], ["评审时", "修复后"])
    per = 1000 / st["items"] / 1e6
    emb = st["embedding_bytes"] * per
    blob_b = st["blob_bytes_before"] * per
    tot_b = st["bytes_per_1000_items_before"] / 1e6
    tot_a = st["bytes_per_1000_items_after"] / 1e6
    parts = [("before", tot_b, [emb, blob_b, tot_b - emb - blob_b]), ("after", tot_a, [emb, 0, tot_a - emb])]
    cols = [t["neutral"], t["s2"], t["s3"]]
    labs = ["向量（JSON）", "图片 / 文件原件", "其他"]
    ys2 = [1, 0]
    for y, (_, tot, segs) in zip(ys2, parts):
        left = 0
        for v, c in zip(segs, cols):
            if v > 0:
                a2.barh(y, v, left=left, height=0.4, color=c, edgecolor=t["surface"], linewidth=2)
                if v > 7:
                    a2.text(left + v / 2, y, f"{v:.1f}", ha="center", va="center", fontsize=11, color="#ffffff")
                else:
                    a2.text(left + v / 2, y + 0.27, f"{v:.1f}", ha="center", va="bottom", fontsize=11, color=t["ink"])
            left += v
        a2.text(tot + 1, y, f"{tot:.1f} MB", va="center", fontsize=12.5, color=t["ink"], weight="bold")
    a2.set_yticks(ys2)
    a2.set_yticklabels(["v5：明文，\n保留图片原件", "v6：读完即删\n+ SQLCipher 加密"], fontsize=12.5, color=t["ink"])
    a2.set_xlim(0, 80)
    a2.set_xlabel("每 1,000 条素材在 Spark 上占的字节（MB）", color=t["ink2"], fontsize=12)
    a2.set_title("Spark 存储（实验室状态副本，1,510 条）", fontsize=14, color=t["ink"], loc="left", pad=36)
    legend_top(a2, t, [plt.Rectangle((0, 0), 1, 1, color=c) for c in cols], labs)
    foot(fig, t, "左：评审时 13 种布局里 7 种没涂住、模型读得出号码；遮号规则 v2 之后 30/30。右：「其他」= 文字、调用记录、索引，含加密开销 +2.1%；\n"
                 "向量占加密库的 64%。出处：v6/review/FINDINGS.md F2、F8；v6/privacy/SPARK.md（Storage numbers，68/68）；v6/phone/E2E.md（66/66）。")
    return save(fig, "07-privacy-fixes-storage", theme)


# ------------------------------------------------------------------ 08 skill text ablation (v5 data, refreshed)
def chart_ablation(theme):
    t = THEMES[theme]
    rows = {(r["skill"], r["metric"], r["set"].split(" ")[0]): r for r in V5["skills_ablation"]["rows"]}
    items = [
        ("归事件 B³ F1 · 留出集", rows[("event-assign", "B³ F1", "holdout-week-v2")]),
        ("卡片事实召回 · 留出集", rows[("event-brief", "card fact recall", "holdout-week-v2")]),
        ("首页 NDCG@5 · 留出集", rows[("home-rank", "home NDCG@5", "holdout-week-v2")]),
        ("读图关键字段准确 · 98 张", rows[("image-read", "key-field exact match", "mm-v1")]),
        ("读图类型判对 · 98 张", rows[("image-read", "image type correct", "mm-v1")]),
        ("文件概要一次合格 · 38 个", rows[("file-read", "summary valid on first try", "files-v1")]),
    ]
    fig, (ax,) = fig_base(t, "技能正文的作用：同一个模型，有 / 没有 SKILL.md 正文",
                          "没有正文时保留全局规则、JSON schema、校验器和重试，只去掉技能说明；每个条件 2 次取均值。（v5 测量，v6 未重跑）", left=0.24, top=0.76)
    hbars(ax, t, [a for a, _ in items], [[r["with"] for _, r in items], [r["without"] for _, r in items]],
          [t["s1"], t["s2"]], ["有技能正文", "无技能正文"])
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_xticklabels(["0", "0.25", "0.50", "0.75", "1.00"])
    sc = E["skill_eval_cases_v6"]
    foot(fig, t, "v6 新技能的可执行用例（虚构，每个跑 3 次）："
                 + "；".join(f"{k.split(' ')[0]} {v['all_pass']}/{v['cases']} 全过" for k, v in sc.items()) + "。\n"
                 "出处：整理器仓库 skills/*/BENCHMARK.md（最终版本一节）、v5/EVAL.md §3；v6/quality/QUALITY.md。检索基线的留出集 B³ F1：向量 0.336、词法 0.463。")
    return save(fig, "08-skill-ablation", theme)


# ------------------------------------------------------------------ 09 organizer models (v5 data, refreshed)
SHORT = {"Qwen3.6-35B-A3B NVFP4 (default)": "Qwen3.6-35B-A3B（默认）", "Qwen3.8-27B-FP8": "Qwen3.8-27B-FP8",
         "Muse Glimmer-30B NVFP4": "Muse Glimmer-30B", "DeepSeek-V4-Flash": "DeepSeek-V4-Flash（占 2 台）",
         "Nemotron-3-Super-120B-A12B NVFP4": "Nemotron-3-Super-120B", "Nemotron-3-Nano-Omni-30B-A3B NVFP4": "Nemotron-3-Nano-Omni",
         "GLM-4.7-Flash (30B-A3B, bf16)": "GLM-4.7-Flash", "Gemma 4 26B-A4B-it (bf16)": "Gemma 4 26B-A4B",
         "Mistral Small 4 119B NVFP4": "Mistral Small 4 NVFP4"}


def chart_models(theme):
    t = THEMES[theme]
    rows = [r for r in V5["organizer_models"]["holdout-week-v2"] if r["b3_f1_mean"] is not None]
    fig, (a1, a2) = fig_base(t, "整理模型对比：留出集 holdout-week-v2（46 条、7 件事）",
                             "同一套技能和代码（v5 的 2e532bc），每个模型独占一台 Spark。默认、Gemma、GLM 跑了 2 次取均值，细线为两次范围；\n"
                             "其余 1 次。v5 的测量，v6 没有重跑。",
                             ncols=2, wspace=0.08, bottom=0.17, top=0.75)
    fig.subplots_adjust(left=0.27, right=0.95)
    ys = list(range(len(rows)))[::-1]
    abl = next(r for r in V5["skills_ablation"]["rows"] if r["set"].startswith("holdout") and r["skill"] == "event-assign" and r["metric"] == "B³ F1")
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
        a1.text(lx, y, f"{v:.3f}", va="center", fontsize=12.5, color=t["ink"], weight="bold" if default else "normal")
        s = r["s_per_item_mean"]
        a2.barh(y, s, height=0.36, color=c, edgecolor=t["surface"], linewidth=2)
        a2.text(s + 1, y, f"{s:.0f} 秒/条", va="center", fontsize=12.5, color=t["ink"])
    a1.set_yticks(ys)
    a1.set_yticklabels([SHORT.get(r["label"], r["label"]) for r in rows], fontsize=13, color=t["ink"])
    a1.set_xlim(0, 1.0)
    a1.set_ylim(-1.25, len(rows) - 0.5)
    a2.set_ylim(-1.25, len(rows) - 0.5)
    a1.set_title("B³ F1（归事件质量）↑", fontsize=14, color=t["ink"], loc="left", pad=8)
    a2.set_yticks(ys)
    a2.set_yticklabels([""] * len(rows))
    a2.set_xlim(0, max(r["s_per_item_mean"] for r in rows) * 1.3)
    a2.set_title("每条素材整理耗时 ↓", fontsize=14, color=t["ink"], loc="left", pad=8)
    base = [r["bcubed_f1"] for k, r in E["holdout_small_set"]["v6_runs"].items() if k.startswith("h2-base")]
    foot(fig, t, "没评上分：gpt-oss-120b（推理关不掉，每条约 125 秒，跑到 24/46 条时停止）。n = 1–2，默认模型两次之间就差 0.065。\n"
                 f"默认模型在较新的代码上（关闭事件合并）两次都是 {base[0]:.3f}，只能在同一代码的行之间比。出处：v5/EVAL.md §4、v6/quality/QUALITY.md §4。")
    return save(fig, "09-organizer-models-holdout", theme)


# ------------------------------------------------------------------ 10 file read, 33 formats (v5 data, refreshed)
def chart_files(theme):
    t = THEMES[theme]
    mf = V5["file_read"]["multiformat_33"]
    layers = [("layer:full", "有文字层（66 个）"), ("layer:partial", "部分内容在图里（13 个）"), ("layer:none", "纯图片 / 扫描 / 视频（36 个）"), ("all", "全部 115 个")]
    fig, (ax,) = fig_base(t, "读文件：33 种格式、115 个测试文件，金标准答案有没有被读出来",
                          "同一条整理器路径（沙箱解析 → 扫描页 / 嵌入图片交给 image-read → file-read 概要）；对照只做解析、不调模型。（v5 测量，v6 未重跑）",
                          left=0.29, top=0.76, bottom=0.17)
    ex = mf["excluding_mac_routed_types"]
    labels = [b for _, b in layers] + ["不含 HEIC / 视频的 30 种（104 个）"]
    po = [mf["parse_only"][a]["qa_acc"] for a, _ in layers] + [ex["parse_only"]["answer_present"]]
    fp = [(mf["full_path"][a]["qa_acc"] + mf["full_path_r2"][a]["qa_acc"]) / 2 for a, _ in layers] + \
         [(ex["full_path"]["answer_present"] + ex["full_path_r2"]["answer_present"]) / 2]
    hbars(ax, t, labels, [fp, po], [t["s1"], t["neutral"]], ["解析 + 读图 + 概要（产品路径，2 次均值）", "只解析，不调模型"])
    ax.set_xlabel("金标准答案出现在读取结果里的比例（测试集 412 道题）", color=t["ink2"], fontsize=12)
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    foot(fig, t, "HEIC 由 Mac 转码、视频由 Mac 取音轨和关键帧，Spark 端按文件读会报 unsupported（11 个文件），所以纯图片一组偏低。\n"
                 "v6 起文件里的图片要 Mac 先涂抹过（送出副本）才交给读图模型，这条路径没有在这套评测集上重跑。出处：v5/EVAL.md §9（合成数据）。")
    return save(fig, "10-file-read-33-formats", theme)


# ------------------------------------------------------------------ 11 per-skill latency and token share (v5 data, refreshed)
def chart_latency(theme):
    t = THEMES[theme]
    pooled = V5["per_skill_latency_tokens"]["pooled_three_runs"]
    st = V5["per_skill_latency_tokens"]["startup"]["skills"]
    order = ["event-assign", "item-split", "screenshot-read", "event-brief", "home-rank"]
    zh = {"event-assign": "归事件 event-assign", "item-split": "多事拆分 item-split", "screenshot-read": "读截图 screenshot-read",
          "event-brief": "事件卡片 event-brief", "home-rank": "首页排序 home-rank"}
    fig, (a1, a2) = fig_base(t, "每个技能在 Spark 上花多少时间和 token",
                             "三个规模场景的真实调用记录（共 21,542 次，Qwen3.6-35B-A3B NVFP4）；右图为 startup 场景。v5 测量，不含 v6 的事件合并。",
                             ncols=2, wspace=0.08, left=0.2, top=0.8, bottom=0.16)
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
    lat = V5["per_skill_latency_tokens"]
    foot(fig, t, f"端到端：每条素材约 {lat['startup']['calls_per_item']} 次调用、{lat['startup']['prompt_tokens_per_item']:,} 输入 token，约 3.7–4.0 条/分钟（GPU 利用率 87–94%）。\n"
                 "出处：v5/EVAL.md §5（v5/data/ledger_latency.json）")
    return save(fig, "11-per-skill-latency-tokens", theme)


made = []
for th in THEMES:
    for fn in (chart_scale, chart_matters, chart_masking, chart_split, chart_people, chart_cost, chart_privacy,
               chart_ablation, chart_models, chart_files, chart_latency):
        made.append(str(fn(th)))
print("\n".join(made))
