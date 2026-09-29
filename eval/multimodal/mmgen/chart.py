"""(2) Dashboards and charts (matplotlib). Every number in the ground truth is printed in the image as a
data label, so an exact reading is possible; the trend is fixed by construction and re-checked.
"""

from __future__ import annotations

import io
import random

import matplotlib

matplotlib.use("Agg")
import logging  # noqa: E402

logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)
from matplotlib import pyplot as plt  # noqa: E402
from PIL import Image  # noqa: E402

from . import photo  # noqa: E402

TREND_ZH = {"up": "上升", "down": "下降", "flat": "基本持平", "rise_then_fall": "先升后降", "fall_then_rise": "先降后升"}
TREND_EN = {"up": "upward", "down": "downward", "flat": "flat", "rise_then_fall": "rises then falls",
            "fall_then_rise": "falls then rises"}

PALETTE = ["#2f6db3", "#e0803a", "#3f9b6b", "#b0463f", "#7a5aa6", "#8a8f99"]
SIMILAR = ["#3a6fb0", "#5b8ccc"]  # two close blues: the hard case


def classify(vals: list[float]) -> str:
    n = len(vals)
    first, last = vals[0], vals[-1]
    imax, imin = vals.index(max(vals)), vals.index(min(vals))
    inc = all(b >= a for a, b in zip(vals, vals[1:]))
    dec = all(b <= a for a, b in zip(vals, vals[1:]))
    span = max(vals) - min(vals)
    base = max(abs(first), 1e-9)
    if span / base <= 0.06:
        return "flat"
    if inc and last > first:
        return "up"
    if dec and last < first:
        return "down"
    if 0 < imax < n - 1 and vals[0] < vals[imax] and vals[-1] < vals[imax] and \
            all(b >= a for a, b in zip(vals[:imax + 1], vals[1:imax + 1])) and \
            all(b <= a for a, b in zip(vals[imax:], vals[imax + 1:])):
        return "rise_then_fall"
    if 0 < imin < n - 1 and all(b <= a for a, b in zip(vals[:imin + 1], vals[1:imin + 1])) and \
            all(b >= a for a, b in zip(vals[imin:], vals[imin + 1:])):
        return "fall_then_rise"
    return "mixed"


def make_series(rng: random.Random, n: int, pattern: str, lo: float, hi: float, decimals: int) -> list[float]:
    """Values following `pattern` exactly (strict steps, so rounding cannot break the shape)."""
    q = 10 ** decimals
    span = hi - lo
    if pattern == "flat":
        mid = rng.uniform(lo + span * 0.4, hi - span * 0.4)
        vals = [mid * (1 + rng.uniform(-0.02, 0.02)) for _ in range(n)]
    else:
        steps = [rng.uniform(0.6, 1.4) for _ in range(n - 1)]
        if pattern == "up":
            signs = [1] * (n - 1)
        elif pattern == "down":
            signs = [-1] * (n - 1)
        elif pattern == "rise_then_fall":
            k = rng.randrange(max(1, n // 3), n - max(1, n // 3))
            signs = [1] * k + [-1] * (n - 1 - k)
        else:
            k = rng.randrange(max(1, n // 3), n - max(1, n // 3))
            signs = [-1] * k + [1] * (n - 1 - k)
        raw = [0.0]
        for st, sg in zip(steps, signs):
            raw.append(raw[-1] + st * sg)
        rmin, rmax = min(raw), max(raw)
        vals = [lo + span * 0.15 + (r - rmin) / (rmax - rmin + 1e-9) * span * 0.75 for r in raw]
    out = [round(v * q) / q for v in vals]
    # keep strict monotonic steps after rounding
    if pattern != "flat":
        for i in range(1, n):
            if out[i] == out[i - 1]:
                out[i] = round((out[i] + (1 if signs[i - 1] > 0 else -1) / q) * q) / q
    return out


def fmt(v: float, decimals: int, comma: bool = True) -> str:
    return f"{v:,.{decimals}f}" if comma else f"{v:.{decimals}f}"


# --------------------------------------------------------------------------- chart specs

MONTHS_ZH = [f"{m}月" for m in range(1, 13)]


def spec_for(kind: str, rng: random.Random, lang: str, v: dict) -> dict:
    """Content for one chart: title, axes, categories, series, value formatting."""
    if kind in ("bar", "line") and lang == "zh":
        topic = v.get("topic") or rng.choice(["sales", "users", "latency", "temp", "orders"])
        if topic == "sales":
            start = rng.choice([0, 6]); n = 6
            return dict(title=f"2026年{'上' if start == 0 else '下'}半年 门店月销售额", cats=MONTHS_ZH[start:start + n],
                        y_label="销售额（万元）", unit="万元", lo=18, hi=60, dec=1, series=["销售额"], x_label="月份")
        if topic == "users":
            n = 8
            return dict(title="小程序周活跃用户", cats=[f"第{i}周" for i in range(1, n + 1)], y_label="周活跃用户（人）",
                        unit="人", lo=1200, hi=5200, dec=0, series=["周活跃"], x_label="周")
        if topic == "latency":
            n = 6
            return dict(title="下单接口平均延迟", cats=[f"v1.{i}" for i in range(n)], y_label="平均延迟（ms）", unit="ms",
                        lo=80, hi=420, dec=0, series=["P50 延迟"], x_label="版本")
        if topic == "temp":
            hours = ["08:00", "10:00", "12:00", "14:00", "16:00", "18:00", "20:00"]
            return dict(title="仓库室内温度记录", cats=hours, y_label="温度（℃）", unit="℃", lo=18, hi=34, dec=1,
                        series=["温度"], x_label="时间")
        n = 7
        return dict(title="近 7 天外卖订单量", cats=[f"9月{d}日" for d in range(14, 14 + n)], y_label="订单量（单）",
                    unit="单", lo=160, hi=520, dec=0, series=["订单量"], x_label="日期")
    if kind in ("bar", "line"):
        topic = v.get("topic") or rng.choice(["conv", "tickets", "rev"])
        if topic == "conv":
            months = ["Apr", "May", "Jun", "Jul", "Aug", "Sep"]
            return dict(title="Checkout conversion rate, 2026", cats=months, y_label="Conversion (%)", unit="%",
                        lo=1.8, hi=4.6, dec=2, series=["Conversion"], x_label="Month")
        if topic == "tickets":
            return dict(title="Support tickets per week", cats=[f"W{i}" for i in range(31, 39)], y_label="Tickets",
                        unit="tickets", lo=40, hi=260, dec=0, series=["Tickets"], x_label="Week")
        return dict(title="Monthly recurring revenue", cats=["Mar", "Apr", "May", "Jun", "Jul", "Aug"],
                    y_label="MRR ($K)", unit="$K", lo=42, hi=118, dec=1, series=["MRR"], x_label="Month")
    if kind == "grouped_bar":
        if lang == "zh":
            if v.get("seed_hint") != "region":
                return dict(title="线上与线下订单额对比", cats=["Q1", "Q2", "Q3", "Q4"], y_label="订单额（万元）", unit="万元",
                            lo=12, hi=88, dec=1, series=["线上", "线下"], x_label="季度")
            return dict(title="各区域 2025 与 2026 上半年营收", cats=["华东", "华南", "华北", "西南", "东北"],
                        y_label="营收（万元）", unit="万元", lo=30, hi=240, dec=0, series=["2025年", "2026年"], x_label="区域")
        return dict(title="Active users: iOS vs Android", cats=["Jun", "Jul", "Aug", "Sep"], y_label="Users (K)",
                    unit="K", lo=8, hi=46, dec=1, series=["iOS", "Android"], x_label="Month")
    if kind == "hbar":
        if lang == "zh":
            return dict(title="各部门 Q4 预算申请", cats=["研发部", "市场部", "运营部", "客服部", "行政部"], y_label="",
                        x_label="预算（万元）", unit="万元", lo=12, hi=180, dec=1, series=["预算"])
        return dict(title="Warehouse stock by category", cats=["Beans", "Milk", "Cups", "Syrups", "Snacks"],
                    y_label="", x_label="Units in stock", unit="units", lo=120, hi=2400, dec=0, series=["Stock"])
    if kind == "pie":
        if lang == "zh":
            title, cats = rng.choice([("9月各品类销售占比", ["拿铁", "美式", "手冲", "甜点", "其他"]),
                                      ("用户来源渠道占比", ["自然搜索", "朋友推荐", "社群", "门店扫码", "其他"])])
            return dict(title=title, cats=cats, unit="%", series=["占比"])
        return dict(title="Sessions by platform", cats=["Web", "iOS", "Android", "Mini-program", "Other"], unit="%",
                    series=["Share"])
    raise ValueError(kind)


def pie_values(rng: random.Random, n: int) -> list[float]:
    """Tenths of a percent that sum to exactly 100.0, largest first."""
    w = sorted([rng.uniform(0.4, 1.0) ** 2 for _ in range(n - 1)], reverse=True) + [0.05]
    total = sum(w)
    tenths = [max(12, round(x / total * 1000)) for x in w]
    tenths[0] += 1000 - sum(tenths)
    return [t / 10 for t in tenths]


def render_chart(kind: str, sp: dict, rng: random.Random, v: dict, lang: str):
    small = v.get("small", False)
    lowc = v.get("low_contrast", False)
    dpi = 72 if small else 110
    fs = 8 if small else 11
    plt.rcParams.update({"font.family": ["Hiragino Sans GB", "Helvetica"], "axes.unicode_minus": False,
                         "font.size": fs})
    label_col = "#b4b6bb" if lowc else "#222222"
    axis_col = "#c8c9cc" if lowc else "#444444"
    fig, ax = plt.subplots(figsize=(10, 6))
    fig.subplots_adjust(top=0.86, bottom=0.14, left=0.1 if kind != "hbar" else 0.16, right=0.96)
    cats = sp["cats"]
    n = len(cats)
    series_out = []
    trend = {}
    if kind == "pie":
        vals = pie_values(rng, n)
        labels = [f"{c} {fmt(p, 1)}%" for c, p in zip(cats, vals)]
        colors = PALETTE[:n]
        ax.pie(vals, labels=labels, colors=colors, startangle=90, counterclock=False,
               wedgeprops=dict(width=0.45 if v.get("donut") else 1, edgecolor="white"),
               textprops=dict(color=label_col, fontsize=fs + 1))
        ax.set_aspect("equal")
        series_out.append({"name": sp["series"][0], "values": vals, "labels": [f"{fmt(p, 1)}%" for p in vals]})
    else:
        pats = v.get("patterns") or [rng.choice(["up", "down", "rise_then_fall", "fall_then_rise", "flat"])]
        colors = SIMILAR if v.get("similar_colors") else PALETTE
        k = len(sp["series"])
        width = 0.8 / k
        for si, name in enumerate(sp["series"]):
            pat = pats[si % len(pats)]
            categorical = kind == "hbar" or sp.get("x_label") == "区域"
            if categorical and pat == "flat":
                pat = "up"
            vals = make_series(rng, n, pat, sp["lo"], sp["hi"], sp["dec"])
            if categorical:  # no order along the axis: shuffle, and record no trend
                rng.shuffle(vals)
            labs = [fmt(x, sp["dec"], comma=sp["dec"] == 0) for x in vals]
            xs = [i + (si - (k - 1) / 2) * width for i in range(n)] if kind in ("bar", "grouped_bar") else list(range(n))
            if kind in ("bar", "grouped_bar"):
                bars = ax.bar(xs, vals, width=width * 0.92, color=colors[si % len(colors)], label=name)
                for b, lab in zip(bars, labs):
                    ax.text(b.get_x() + b.get_width() / 2, b.get_height(), lab, ha="center", va="bottom",
                            fontsize=fs - (1 if k > 1 else 0), color=label_col)
            elif kind == "hbar":
                bars = ax.barh(range(n), vals, color=colors[si % len(colors)], label=name, height=0.6)
                for b, lab in zip(bars, labs):
                    ax.text(b.get_width(), b.get_y() + b.get_height() / 2, " " + lab, ha="left", va="center",
                            fontsize=fs, color=label_col)
            else:
                ax.plot(xs, vals, marker="o", color=colors[si % len(colors)], label=name, linewidth=2)
                off = (max(vals) - min(vals) + 1e-9) * 0.04
                for x, y, lab in zip(xs, vals, labs):
                    ax.text(x, y + off, lab, ha="center", va="bottom", fontsize=fs - 1, color=label_col)
            series_out.append({"name": name, "values": vals, "labels": labs})
            if not categorical:
                got = classify(vals)
                assert got == pat, (got, pat, vals)
                trend[name] = pat
        if kind == "hbar":
            ax.set_yticks(range(n), cats)
            ax.invert_yaxis()
            ax.set_xlabel(sp["x_label"], color=axis_col)
            ax.set_xlim(0, max(max(s["values"]) for s in series_out) * 1.18)
        else:
            ax.set_xticks(range(n), cats)
            ax.set_xlabel(sp["x_label"], color=axis_col)
            ax.set_ylabel(sp["y_label"], color=axis_col)
            top = max(max(s["values"]) for s in series_out)
            bottom = 0 if kind != "line" else min(min(s["values"]) for s in series_out) * 0.85
            ax.set_ylim(bottom, top * 1.14)
        if k > 1:  # above the plot area, so it never covers a bar or its label
            ax.legend(frameon=False, loc="lower right", bbox_to_anchor=(1.0, 1.0), ncol=k, labelcolor=label_col)
        ax.tick_params(colors=axis_col)
        for spn in ("top", "right"):
            ax.spines[spn].set_visible(False)
        for spn in ("left", "bottom"):
            ax.spines[spn].set_color(axis_col)
        ax.grid(axis="x" if kind == "hbar" else "y", color="#eeeeee" if not lowc else "#f4f4f4", linewidth=0.8)
        ax.set_axisbelow(True)
    fig.suptitle(sp["title"], fontsize=fs + 5, color=label_col if lowc else "#111111", x=0.5, y=0.95)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=dpi, facecolor="#fbfbfb" if lowc else "white")
    plt.close(fig)
    buf.seek(0)
    return Image.open(buf).convert("RGB"), series_out, trend


def render_dashboard(rng: random.Random, v: dict, lang: str):
    small = v.get("small", False)
    dark = v.get("dark", False)
    dpi = 72 if small else 100
    fs = 8 if small else 11
    plt.rcParams.update({"font.family": ["Hiragino Sans GB", "Helvetica"], "axes.unicode_minus": False, "font.size": fs})
    bg, fg, sub, card = (("#15171c", "#e8e9ec", "#9aa0aa", "#1f232b") if dark else ("#f3f4f7", "#1d1f24", "#6b7079", "white"))
    if v.get("low_contrast"):
        fg, sub = ("#5d626b", "#474b52") if dark else ("#a3a6ad", "#b8bbc1")
    fig = plt.figure(figsize=(12, 7), facecolor=bg)
    if lang == "zh":
        title = rng.choice(["门店经营看板 · 9月", "小程序运营日报"])
        rev = rng.uniform(12, 40); orders = rng.randrange(2100, 5200); aov = rev * 1e4 / orders
        rep = rng.uniform(28, 52)
        kpis = [("本月营收", f"¥{rev:.1f}万", f"{rng.choice(['+', '-'])}{rng.uniform(1, 18):.1f}%"),
                ("订单数", f"{orders:,}", f"{rng.choice(['+', '-'])}{rng.uniform(1, 12):.1f}%"),
                ("客单价", f"¥{aov:.1f}", f"{rng.choice(['+', '-'])}{rng.uniform(0.5, 6):.1f}%"),
                ("复购率", f"{rep:.1f}%", f"{rng.choice(['+', '-'])}{rng.uniform(0.2, 3):.1f}pt")]
        line_title, cats = "近 10 天日订单量（单）", [f"9/{d}" for d in range(12, 22)]
        unit = "单"
    else:
        title = rng.choice(["Store dashboard · September", "App daily metrics"])
        rev = rng.uniform(40, 140); orders = rng.randrange(1500, 4800)
        kpis = [("Revenue", f"${rev:.1f}K", f"{rng.choice(['+', '-'])}{rng.uniform(1, 18):.1f}%"),
                ("Orders", f"{orders:,}", f"{rng.choice(['+', '-'])}{rng.uniform(1, 12):.1f}%"),
                ("Avg. order", f"${rev * 1000 / orders:.2f}", f"{rng.choice(['+', '-'])}{rng.uniform(0.5, 6):.1f}%"),
                ("Refund rate", f"{rng.uniform(0.8, 4.5):.1f}%", f"{rng.choice(['+', '-'])}{rng.uniform(0.1, 1):.1f}pt")]
        line_title, cats = "Daily orders, last 10 days", [f"9/{d}" for d in range(12, 22)]
        unit = "orders"
    fig.text(0.04, 0.93, title, fontsize=fs + 9, color=fg, weight="bold")
    for i, (lab, val, delta) in enumerate(kpis):
        x0 = 0.04 + i * 0.235
        axk = fig.add_axes([x0, 0.66, 0.215, 0.2])
        axk.set_facecolor(card)
        axk.set_xticks([]); axk.set_yticks([])
        for spn in axk.spines.values():
            spn.set_visible(False)
        axk.text(0.08, 0.72, lab, fontsize=fs + 1, color=sub, transform=axk.transAxes)
        axk.text(0.08, 0.3, val, fontsize=fs + 12, color=fg, weight="bold", transform=axk.transAxes)
        up = delta.startswith("+")
        dcol = ("#2e9d63" if up else "#cf4b43") if not v.get("low_contrast") else sub
        axk.text(0.92, 0.32, delta, fontsize=fs + 1, color=dcol, ha="right", transform=axk.transAxes)
    pat = v.get("patterns", [rng.choice(["up", "down", "rise_then_fall", "fall_then_rise"])])[0]
    vals = make_series(rng, len(cats), pat, 120 if lang == "zh" else 90, 420, 0)
    assert classify(vals) == pat
    ax = fig.add_axes([0.06, 0.08, 0.9, 0.46], facecolor=card)
    ax.plot(range(len(cats)), vals, marker="o", color="#5b9bd5" if dark else "#2f6db3", linewidth=2)
    off = (max(vals) - min(vals)) * 0.05
    for x, y in enumerate(vals):
        ax.text(x, y + off, f"{int(y)}", ha="center", va="bottom", fontsize=fs - 1, color=fg)
    ax.set_xticks(range(len(cats)), cats, color=sub)
    ax.tick_params(colors=sub)
    ax.set_ylim(min(vals) * 0.85, max(vals) * 1.15)
    ax.set_title(line_title, color=fg, fontsize=fs + 2, loc="left")
    for spn in ax.spines.values():
        spn.set_color(sub if not dark else "#2c313a")
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=dpi, facecolor=bg)
    plt.close(fig)
    buf.seek(0)
    labs = [f"{int(y)}" for y in vals]
    return (Image.open(buf).convert("RGB"), title, kpis,
            {"name": line_title, "categories": cats, "values": vals, "labels": labs, "unit": unit, "trend": pat})


def build(idx: int, v: dict, rng: random.Random) -> dict:
    kind = v["chart"]
    lang = v.get("lang", "zh")
    hard = []
    if kind == "dashboard":
        img, title, kpis, line = render_dashboard(rng, v, lang)
        gt = {"chart_type": "dashboard", "title": title,
              "kpis": [{"label": a, "value": b, "delta": c} for a, b, c in kpis],
              "series": [{"name": line["name"], "categories": line["categories"], "values": line["values"],
                          "labels": line["labels"], "unit": line["unit"]}],
              "trend": {line["name"]: line["trend"]}}
        text_lines = [title] + [f"{a} {b} {c}" for a, b, c in kpis] + [line["name"]] + \
                     [f"{c}: {lab}" for c, lab in zip(line["categories"], line["labels"])]
        imax = line["values"].index(max(line["values"]))
        tz = TREND_ZH if lang == "zh" else TREND_EN
        if lang == "zh":
            qa = [(f"{kpis[0][0]}是多少？", kpis[0][1], "exact"), (f"{kpis[1][0]}是多少？", kpis[1][1], "number"),
                  (f"{kpis[3][0]}环比变化多少？", kpis[3][2], "exact"),
                  ("日订单量最高的是哪天？", line["categories"][imax], "exact"),
                  ("日订单量整体趋势？", tz[line["trend"]], "trend")]
        else:
            qa = [(f"What is the {kpis[0][0].lower()}?", kpis[0][1], "exact"),
                  (f"How many {kpis[1][0].lower()}?", kpis[1][1], "number"),
                  ("Which day had the most orders?", line["categories"][imax], "exact"),
                  ("Overall trend of daily orders?", tz[line["trend"]], "trend")]
        render_info = {"engine": "matplotlib", "dark": bool(v.get("dark"))}
    else:
        sp = spec_for(kind, rng, lang, v)
        img, series, trend = render_chart(kind, sp, rng, v, lang)
        gt = {"chart_type": kind, "title": sp["title"], "x_label": sp.get("x_label", ""),
              "y_label": sp.get("y_label", ""), "unit": sp["unit"], "categories": sp["cats"],
              "series": [{"name": s["name"], "values": s["values"], "labels": s["labels"]} for s in series],
              "trend": trend}
        text_lines = [sp["title"]]
        for s in series:
            text_lines += [f"{s['name']} {c}: {lab}" for c, lab in zip(sp["cats"], s["labels"])]
        s0 = series[-1]
        imax = s0["values"].index(max(s0["values"]))
        unit = "" if sp["unit"] in ("%",) else sp["unit"]
        pct = "%" if sp["unit"] == "%" and kind != "pie" else ""
        j = rng.randrange(len(sp["cats"]))
        if lang == "zh":
            qa = [(f"{sp['title']}中，{sp['cats'][j]}的{s0['name']}是多少？", f"{s0['labels'][j]}{pct}{unit}", "number"),
                  (f"{s0['name']}最高的是哪一项？", sp["cats"][imax], "exact")]
            if trend:
                qa.append((f"{s0['name']}的整体趋势？", TREND_ZH[trend[s0['name']]], "trend"))
        else:
            qa = [(f"In '{sp['title']}', what is the value for {sp['cats'][j]} ({s0['name']})?",
                   f"{s0['labels'][j]}{pct}", "number"),
                  (f"Which {'category' if kind in ('hbar', 'pie') else sp['x_label'].lower()} has the highest {s0['name']}?",
                   sp["cats"][imax], "exact")]
            if trend:
                qa.append((f"Overall trend of {s0['name']}?", TREND_EN[trend[s0['name']]], "trend"))
        render_info = {"engine": "matplotlib", "chart": kind}
        if v.get("similar_colors"):
            hard.append("similar_colors")
        if len(sp["cats"]) >= 8:
            hard.append("many_points")
    if v.get("small"):
        hard.append("small_text")
    if v.get("low_contrast"):
        hard.append("low_contrast")
    ext = "png"
    if v.get("jpeg"):
        ext = "jpg"
        render_info["jpeg"] = v["jpeg"]
    img = photo.add_mark(img, corner="tr")
    hard.append("units")
    return {"image": img, "ext": ext, "quality": v.get("jpeg", 85), "lang": lang, "hard": hard, "render": render_info, "gt": gt,
            "text_lines": text_lines, "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": kind}
