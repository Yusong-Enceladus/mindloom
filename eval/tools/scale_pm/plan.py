#!/usr/bin/env python3
"""Deterministic item plan for the scale-pm scenario (no model calls).

  python3 eval/tools/scale_pm/plan.py -o /path/plan.json

Reads eval/scenarios/scale-pm/source/bible.json plus facts.py / fixed.py and writes one plan entry per item:
capture time, content time, format, source app, API kind, the matters it covers (event, facts it must
convey and whether each is new / a repeat / stale, oblique reference or not), cast with surface names,
noise flag, sensitivity, length target. Gold labels come from this plan, never from model output.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import uuid
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import facts as facts_mod  # noqa: E402
import fixed as fx  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
BIBLE = os.path.join(ROOT, "eval", "scenarios", "scale-pm", "source", "bible.json")
TZ = timezone(timedelta(hours=8))
START, END = date(2026, 8, 10), date(2026, 9, 20)
END_DT = datetime(2026, 9, 20, 23, 59, tzinfo=TZ)
NS = uuid.UUID("6f2b8c1e-5d0a-4f7e-9a3b-2c1d0e9f8a7b")
OWNER = "jiang_yuan"
SEED = 20260810

R = random.Random(SEED)
BIBLE_D = json.load(open(BIBLE, encoding="utf-8"))
EVENTS = {e["id"]: e for e in BIBLE_D["events"]}
EIDS = sorted(EVENTS)
PEOPLE = {p["id"]: p for p in BIBLE_D["people"]}
PEOPLE[OWNER] = {"id": OWNER, "name": "江予安", "aliases": BIBLE_D["protagonist"]["aliases"], "org": "澄湾集团",
                 "role": BIBLE_D["protagonist"]["role"]}
FACTS = {f["fact_id"]: f for f in facts_mod.facts()}
FACTS_BY_EVENT = defaultdict(list)
for f in FACTS.values():
    FACTS_BY_EVENT[f["event_id"]].append(f["fact_id"])

PRIV = {"E14", "E15", "E16", "E19"}
SENS = {"E11", "E12", "E13"}
LOW_STAKES = {"E20"}
BOSSES = {"han_lifeng", "zhou_qiming"}
WECHAT_CONTACTS = {"E14": ["ye_zhiqiu", "wang_rui", "zhou_yi", "kong_wei"], "E15": ["chen_ke", "meng_jia"],
                   "E16": ["cheng_yuan", "kong_wei", "ye_zhiqiu", "chen_ke"], "E19": ["cheng_yuan"]}
SENS_CHAT = {"E11": ["gu_nan", "zhao_yifan"], "E12": ["gu_nan", "wu_di", "xu_qing"], "E13": ["xu_qing", "gu_nan", "han_lifeng"]}
GROUPS = {
    "E01": ["小澄项目群", "小澄上线作战室"], "E02": ["会员频道 3.0 项目群"], "E03": ["问问小澄入口 AB 实验"],
    "E04": ["INC-0826 积分重复扣减", "稳定性改进跟进", "客服协同群"], "E05": ["会员频道 3.0 项目群", "客服协同群"],
    "E06": ["积分抵现 v2 对接群"], "E07": ["小澄合规评审"], "E08": ["小澄评测集"], "E09": ["秋季沟通会筹备群"],
    "E10": ["会员与增长组 OKR"], "E17": ["小澄数据"], "E18": ["AI 学习小组"], "E20": ["会员与增长小分队"],
    "E21": ["小澄竞品调研"],
}
QUOTA = {"feishu_transcript": 0, "tencent_transcript": 0, "zoom_transcript": 0, "phone_ime": 520, "mac_dictation": 250,
         "chat_paste": 400, "screenshot": 52, "pdf": 26, "email": 150, "claude_result": 44, "codex_result": 32, "doc_text": 41}
NOISE_PLAN = {"email": 35, "phone_ime": 45, "chat_paste": 24, "mac_dictation": 8}
TARGET_TOTAL = 1600
TARGET_SCALE = 1.08


def D(md: str) -> date:
    return date(2026, int(md[:2]), int(md[3:5]))


def DT(d: date, hm: str) -> datetime:
    h, m = hm.split(":")
    return datetime(d.year, d.month, d.day, int(h), int(m), tzinfo=TZ)


def days():
    d = START
    while d <= END:
        yield d
        d += timedelta(days=1)


def weekend(d: date) -> bool:
    return d.weekday() >= 5


PEAKS = {date(2026, 8, 26), date(2026, 9, 2), date(2026, 9, 10), date(2026, 9, 11), date(2026, 9, 17), date(2026, 9, 18)}


def day_weight(d: date) -> float:
    w = 16.0 if weekend(d) else 44.0
    if d >= date(2026, 8, 24):
        w *= 1.25
    if d in PEAKS:
        w = 95.0
    return w


# ------------------------------------------------------------------------------------------ items
ITEMS: list[dict] = []
BY_KEY: dict[str, dict] = {}


def new_item(key: str, fmt: str, cap: datetime, **kw) -> dict:
    it = {"key": key, "fmt": fmt, "cap": cap, "content_time": None, "matters": [], "cast": [], "named": [],
          "noise": False, "tags": [], "brainstorm": False}
    it.update(kw)
    ITEMS.append(it)
    BY_KEY[key] = it
    return it


def matter(it: dict, eid: str) -> dict:
    for m in it["matters"]:
        if m["event"] == eid:
            return m
    m = {"event": eid, "facts": [], "role": "context", "oblique": False}
    it["matters"].append(m)
    return m


KIND_OF = {"feishu_transcript": "document", "tencent_transcript": "document", "zoom_transcript": "document",
           "phone_ime": "text", "mac_dictation": "dictation", "chat_paste": "text", "screenshot": "image",
           "pdf": "document", "email": "text", "claude_result": "text", "codex_result": "text", "doc_text": "text"}


def build_fixed():
    for key, (md, hm, mins, plat, title, cast, evs, length) in fx.MEETINGS.items():
        d = D(md)
        start = DT(d, hm)
        cap = start + timedelta(minutes=mins + R.randint(12, 70))
        fmt = plat + "_transcript"
        app = {"feishu": "飞书妙记", "tencent": "腾讯会议", "zoom": "Zoom"}[plat]
        it = new_item("M:" + key, fmt, cap, app=app, title=title, content_time=start, duration_min=mins,
                      length=list(length), meeting_cast=list(cast))
        for e in evs:
            matter(it, e)
        it["cast"] = [p for p in cast]
    for key, (src, cap_s, kind) in fx.MEETING_COPIES.items():
        src_it = BY_KEY["M:" + src]
        cap = DT(D(cap_s[:5]), cap_s[6:])
        it = new_item("M:" + key, src_it["fmt"], cap, app=src_it["app"], title=src_it["title"],
                      content_time=src_it["content_time"], duration_min=src_it["duration_min"], length=src_it["length"],
                      meeting_cast=src_it["meeting_cast"], copy_of="M:" + src, copy_kind=kind)
        it["cast"] = list(src_it["cast"])
        it["tags"].append("duplicate_export" if kind == "dup" else "fragment")
    for key, (md, hm, evs, fname, scanned) in fx.PDFS.items():
        it = new_item("P:" + key, "pdf", DT(D(md), hm), app="Finder", filename=fname, scanned=scanned)
        for e in evs:
            matter(it, e)
    for key, (md, hm, style, evs, brief) in fx.SHOTS.items():
        it = new_item("S:" + key, "screenshot", DT(D(md), hm), app="截图", style=style, title=brief)
        for e in evs:
            matter(it, e)
    for key, (md, hm, app, title, cast, evs, merged) in fx.CHATS.items():
        it = new_item("C:" + key, "chat_paste", DT(D(md), hm), app=app, title=title, merged=merged)
        it["cast"] = list(cast)
        for e in evs:
            matter(it, e)
    for key, (md, hm, frm, to, cc, evs, personal) in fx.EMAILS.items():
        it = new_item("E:" + key, "email", DT(D(md), hm), app="个人邮箱" if personal else "邮件",
                      email={"from": frm, "to": to, "cc": cc, "personal": personal})
        it["cast"] = [frm] + to + cc
        for e in evs:
            matter(it, e)
    for key, (md, hm, fmt, mode, app, evs, obl) in fx.KEYS.items():
        it = new_item("K:" + key, fmt, DT(D(md), hm), app=app, mode=mode)
        for e in evs:
            matter(it, e)["oblique"] = obl
        if len(evs) >= 3:
            it["brainstorm"] = True
    for key, (md, hm, fmt, mode, evs) in fx.BRAINSTORMS_REQUIRED.items():
        it = new_item("K:" + key, fmt, DT(D(md), hm), app="备忘录", mode=mode, brainstorm=True)
        for e in evs:
            matter(it, e)
    for key, (md, hm, tool, evs, topic, export) in fx.AGENTS.items():
        d = D(md)
        cap = DT(d, hm)
        it = new_item("A:" + key, "claude_result" if tool == "Claude" else "codex_result", cap, app=tool, topic=topic,
                      export_return=export)
        for e in evs:
            matter(it, e)
    for key, (md, hm, sub, evs) in fx.DOCS.items():
        it = new_item("D:" + key, "doc_text", DT(D(md), hm), app={"缺陷单导出": "缺陷管理", "飞书文档评论导出": "飞书文档"}[sub], sub=sub)
        for e in evs:
            matter(it, e)
    # first conveyance of every fact
    for fid, f in FACTS.items():
        it = BY_KEY[f["first"]]
        m = matter(it, f["event_id"])
        m["facts"].append(fid)
        m["role"] = "first"


def fill_copies():
    for it in ITEMS:
        if it.get("copy_of"):
            src = BY_KEY[it["copy_of"]]
            it["matters"] = [{"event": m["event"], "facts": list(m["facts"]), "role": "repeat" if m["facts"] else "context",
                              "oblique": False} for m in src["matters"]]


def first_time(fid: str) -> datetime:
    return BY_KEY[FACTS[fid]["first"]]["cap"]


def valid_facts_at(eid: str, t: datetime) -> list[str]:
    """Facts of eid first conveyed before t and not superseded before t (in first-time order)."""
    out = []
    for fid in FACTS_BY_EVENT[eid]:
        if first_time(fid) < t:
            succ = FACTS[fid]["superseded_by"]
            if succ and first_time(succ) < t:
                continue
            out.append(fid)
    out.sort(key=first_time)
    return out


def add_auto_repeats():
    """Fixed items that cover an event without a first fact restate one or two recent facts of it."""
    for it in ITEMS:
        if it.get("copy_of"):
            continue
        t = it.get("content_time") or it["cap"]
        for m in it["matters"]:
            if m["facts"]:
                continue
            vf = [f for f in valid_facts_at(m["event"], t) if (t.date() - FACTS[f]["date_obj"]).days <= 10]
            if not vf:
                continue
            k = 2 if it["fmt"].endswith("transcript") else 1
            m["facts"] = vf[-k:]
            m["role"] = "repeat"


# ------------------------------------------------------------------------------------------ pool
POOL: list[dict] = []  # free mentions: {event, facts, role, date, oblique}


def mention_count() -> Counter:
    c = Counter()
    for it in ITEMS:
        for m in it["matters"]:
            c[m["event"]] += 1
    for m in POOL:
        c[m["event"]] += 1
    return c


def fact_mentions() -> Counter:
    c = Counter()
    for it in ITEMS:
        for m in it["matters"]:
            for f in m["facts"]:
                c[f] += 1
    for m in POOL:
        for f in m["facts"]:
            c[f] += 1
    return c


def plan_repeats():
    fm = fact_mentions()
    for fid, f in FACTS.items():
        fd = f["date_obj"]
        succ = f["superseded_by"]
        target = 3 + (R.random() < 0.6) + (R.random() < 0.3)
        need = max(2, target - fm[fid])
        if succ:
            sd = FACTS[succ]["date_obj"]
            # old value must be mentioned >= 3 times before the new one appears
            before = [x for x in range((sd - fd).days + 1)]
            for _ in range(max(need, 2)):
                off = R.choice(before[:-1] if len(before) > 1 else before)
                POOL.append({"event": f["event_id"], "facts": [fid], "role": "repeat", "date": fd + timedelta(days=off),
                             "must_before": succ})
            for _ in range(1 + (R.random() < 0.35)):
                off = R.choice([0, 1, 1, 2, 3, 4, 6])
                dd = sd + timedelta(days=off)
                if dd > END:
                    dd = sd + timedelta(days=R.randint(0, max(0, (END - sd).days)))
                POOL.append({"event": f["event_id"], "facts": [fid], "role": "stale", "date": dd, "stale_of": succ})
        else:
            for _ in range(need):
                off = R.choice([0, 0, 1, 1, 2, 3, 4, 5, 7, 9, 12])
                dd = fd + timedelta(days=off)
                if dd > END:
                    dd = fd + timedelta(days=R.randint(0, max(0, (END - fd).days)))
                POOL.append({"event": f["event_id"], "facts": [fid], "role": "repeat", "date": dd})


def event_range(eid: str) -> tuple[date, date]:
    ds = [FACTS[f]["date_obj"] for f in FACTS_BY_EVENT[eid]]
    lo = min(ds)
    done_like = EVENTS[eid]["status_at_end"].startswith(("已完成", "已通过", "已关单", "已取消", "已婉拒", "已在用", "稳定"))
    hi = min(END, max(ds) + timedelta(days=6)) if done_like else END
    return lo, hi


def plan_filler():
    have = mention_count()
    for eid in EIDS:
        target = round(EVENTS[eid]["target_items"] * TARGET_SCALE)
        need = target - have[eid]
        if need <= 0:
            continue
        lo, hi = event_range(eid)
        span = [lo + timedelta(days=i) for i in range((hi - lo).days + 1)]
        near = Counter()
        for f in FACTS_BY_EVENT[eid]:
            for k in range(-1, 3):
                near[FACTS[f]["date_obj"] + timedelta(days=k)] += 1
        weights = [day_weight(d) * (1 + 0.5 * near[d]) * (0.5 if eid in PRIV and not weekend(d) else 1.0) for d in span]
        for d in R.choices(span, weights=weights, k=need):
            POOL.append({"event": eid, "facts": [], "role": "context", "date": d})


# ------------------------------------------------------------------------------------------ brainstorms
BS_KS = [3] * 20 + [4] * 15 + [5] * 9 + [6] * 7 + [7] * 5 + [8] * 3


def take_from_pool(eid: str, d: date, span: int = 1):
    cands = [m for m in POOL if m["event"] == eid and abs((m["date"] - d).days) <= span and m["role"] != "stale"
             and not m.get("must_before")]
    if not cands:
        cands = [m for m in POOL if m["event"] == eid and abs((m["date"] - d).days) <= span and m["role"] != "stale"]
    if not cands:
        return None
    m = R.choice(cands)
    POOL.remove(m)
    return m


def plan_brainstorms():
    # required ones: attach a pooled mention (with its facts) where one exists near the date
    for it in ITEMS:
        if not it["brainstorm"]:
            continue
        for m in it["matters"]:
            if m["facts"]:
                continue
            got = take_from_pool(m["event"], it["cap"].date(), 1)
            if got:
                m["facts"] = got["facts"]
                m["role"] = got["role"]
    modes = [("phone_ime", "voice")] * 26 + [("mac_dictation", "dictation")] * 23 + [("phone_ime", "typed")] * 10
    R.shuffle(modes)
    ks = BS_KS[:]
    R.shuffle(ks)
    dates = []
    all_days = list(days())
    for wk in range(6):
        wdays = all_days[wk * 7:(wk + 1) * 7]
        n = 10 if wk < 5 else 9
        dates += R.choices(wdays, weights=[2.5 if weekend(d) else 1.0 for d in wdays], k=n)
    dates.sort()
    noisy = set(R.sample(range(len(dates)), 12))
    for i, d in enumerate(dates):
        fmt, mode = modes[i]
        k = ks[i]
        avail = Counter(m["event"] for m in POOL if abs((m["date"] - d).days) <= 1)
        evs = [e for e, _ in avail.most_common()]
        R.shuffle(evs)
        evs = evs[:k]
        if len(evs) < 3:
            continue
        if weekend(d):
            hm = R.choice(["10:40", "15:20", "21:10", "22:30", "20:05"])
        elif fmt == "mac_dictation":
            hm = R.choice(["21:15", "22:05", "22:40", "23:10", "20:50"])
        else:
            hm = R.choice(["08:20", "08:45", "12:30", "19:10", "18:50"])
        it = new_item(f"B:{d.isoformat()}-{i:02d}", fmt, DT(d, hm) + timedelta(minutes=R.randint(0, 14)),
                      app="备忘录", mode=mode, brainstorm=True)
        if i in noisy:
            it["noise_bits"] = True
        for e in evs:
            got = take_from_pool(e, d, 1)
            m = matter(it, e)
            if got:
                m["facts"] = got["facts"]
                m["role"] = got["role"]
                if got.get("stale_of"):
                    m["stale_of"] = got["stale_of"]


# ------------------------------------------------------------------------------------------ packing and formats
def ev_class(eids) -> str:
    s = set(eids)
    if s & PRIV:
        return "priv_mixed" if s - PRIV else "priv"
    if s & SENS:
        return "sens"
    return "work"


def allowed_formats(eids) -> list[str]:
    cls = ev_class(eids)
    if cls == "priv":
        fm = ["phone_ime", "mac_dictation", "chat_paste"]
        if set(eids) <= {"E14", "E15"}:
            fm.append("email")
        return fm
    if cls == "priv_mixed":
        return ["phone_ime", "mac_dictation"]
    if cls == "sens":
        fm = ["phone_ime", "mac_dictation", "chat_paste", "email"]
        return fm
    fm = ["phone_ime", "mac_dictation", "chat_paste", "email"]
    if set(eids) <= {"E01", "E02", "E04", "E05", "E09", "E10", "E12", "E18", "E20", "E03"}:
        fm.append("doc_text")
    return fm


def pack_pool(p_pair: float):
    by_day = defaultdict(list)
    for m in POOL:
        by_day[m["date"]].append(m)
    groups = []
    for d in sorted(by_day):
        ms = by_day[d]
        R.shuffle(ms)
        used = set()
        for i, m in enumerate(ms):
            if i in used:
                continue
            used.add(i)
            grp = [m]
            if R.random() < p_pair:
                want = 2 if R.random() < 0.8 else 3
                for j in range(i + 1, len(ms)):
                    if len(grp) >= want:
                        break
                    if j in used or ms[j]["event"] in {g["event"] for g in grp}:
                        continue
                    cls = ev_class([g["event"] for g in grp] + [ms[j]["event"]])
                    if cls == "priv_mixed" and R.random() > 0.15:
                        continue
                    grp.append(ms[j])
                    used.add(j)
            groups.append((d, grp))
    POOL.clear()
    return groups


def assign_formats(groups):
    used = Counter(it["fmt"] for it in ITEMS)
    free = {f: QUOTA[f] - used[f] - NOISE_PLAN.get(f, 0) for f in ("phone_ime", "mac_dictation", "chat_paste", "email", "doc_text")}
    total_free = sum(max(0, v) for v in free.values())
    n = len(groups)
    scale = n / max(1, total_free)
    remaining = {f: max(0.0, v * scale) for f, v in free.items()}
    order = list(range(n))
    R.shuffle(order)
    # constrained groups first
    order.sort(key=lambda i: len(allowed_formats([m["event"] for m in groups[i][1]])))
    out = [None] * n
    for i in order:
        d, grp = groups[i]
        allowed = allowed_formats([m["event"] for m in grp])
        w = [max(0.05, remaining.get(f, 0)) for f in allowed]
        f = R.choices(allowed, weights=w)[0]
        remaining[f] = remaining.get(f, 0) - 1
        out[i] = f
    return out


PHONE_APPS_WORK = [("飞书", 34), ("备忘录", 30), ("企业微信", 4), ("浏览器", 6), ("提醒事项", 8), ("日历", 4), ("微信", 6)]
PHONE_APPS_PRIV = [("微信", 50), ("备忘录", 38), ("提醒事项", 6), ("浏览器", 6)]
MAC_APPS_WORK = [("飞书文档", 30), ("备忘录", 25), ("邮件草稿", 15), ("Claude 输入框", 20), ("Codex 终端", 5), ("飞书", 5)]
MAC_APPS_PRIV = [("备忘录", 75), ("Claude 输入框", 25)]


def wpick(pairs):
    return R.choices([p for p, _ in pairs], weights=[w for _, w in pairs])[0]


def slot_time(d: date, fmt: str, cls: str, app: str | None = None) -> datetime:
    we = weekend(d)
    if cls in ("priv", "priv_mixed"):
        spans = [("07:40", "09:10", 2), ("12:05", "13:30", 3), ("19:00", "23:40", 6)] if not we else [("09:00", "23:30", 1)]
    elif fmt in ("chat_paste", "email", "doc_text"):
        spans = [("09:10", "12:00", 4), ("13:30", "19:30", 5), ("20:00", "22:30", 1)] if not we else [("10:00", "21:00", 1)]
    elif fmt == "mac_dictation":
        spans = [("20:30", "23:45", 6), ("11:00", "18:30", 3)] if not we else [("10:00", "23:30", 1)]
    else:  # phone
        spans = [("07:45", "09:30", 3), ("12:00", "13:40", 2), ("18:20", "20:10", 3), ("21:30", "23:40", 2), ("10:00", "18:00", 2)] \
            if not we else [("09:00", "23:30", 1)]
    a, b, _ = R.choices(spans, weights=[w for *_, w in spans])[0]
    ta, tb = DT(d, a), DT(d, b)
    return ta + timedelta(minutes=R.randint(0, int((tb - ta).total_seconds() // 60)))


def materialise(groups, fmts):
    for n, ((d, grp), fmt) in enumerate(zip(groups, fmts)):
        eids = [m["event"] for m in grp]
        cls = ev_class(eids)
        app = None
        if fmt == "phone_ime":
            app = wpick(PHONE_APPS_PRIV if cls in ("priv", "priv_mixed") else PHONE_APPS_WORK)
            if cls == "priv_mixed":
                app = "备忘录"
            if app == "企业微信" and "E08" not in eids:
                app = "飞书"
            if cls == "sens" and app in ("微信", "企业微信"):
                app = "备忘录"
            mode = "voice" if R.random() < 0.4 else "typed"
        elif fmt == "mac_dictation":
            app = wpick(MAC_APPS_PRIV if cls in ("priv", "priv_mixed") else MAC_APPS_WORK)
            if cls == "priv_mixed":
                app = "备忘录"
            mode = "dictation"
        elif fmt == "chat_paste":
            if cls == "priv":
                app = "微信"
            elif "E08" in eids and R.random() < 0.7:
                app = "企业微信"
            else:
                app = "飞书"
            mode = None
        elif fmt == "email":
            app = "个人邮箱" if cls == "priv" else "邮件"
            mode = None
        else:
            app = R.choice(["飞书文档", "日历", "缺陷管理", "问卷"])
            mode = None
        if fmt == "doc_text":
            if set(eids) & {"E05"}:
                app = "缺陷管理"
            elif set(eids) & {"E18", "E20"} and R.random() < 0.5:
                app = "问卷"
        cap = slot_time(d, fmt, cls, app)
        it = new_item(f"F:{d.isoformat()}-{n:04d}", fmt, cap, app=app, mode=mode)
        for m in grp:
            mm = matter(it, m["event"])
            mm["facts"] = m["facts"]
            mm["role"] = m["role"]
            if m.get("stale_of"):
                mm["stale_of"] = m["stale_of"]
            if m.get("must_before"):
                mm["must_before"] = m["must_before"]
        if fmt == "doc_text":
            it["sub"] = {"飞书文档": "飞书文档评论导出", "日历": "日历邀请文本", "缺陷管理": "缺陷单导出", "问卷": "问卷结果文本"}[app]


# ------------------------------------------------------------------------------------------ night of 8/26
def plan_incident_night():
    """8/26 21:50 -> 8/27 01:30: at least 25 items. Pull E04/E01/E05/E15 mentions of 8/26–8/27 into night slots."""
    night = [it for it in ITEMS if DT(date(2026, 8, 26), "21:50") <= it["cap"] <= DT(date(2026, 8, 27), "01:30")]
    need = 27 - len(night)
    slots = sorted(DT(date(2026, 8, 26), "21:55") + timedelta(minutes=R.randint(0, 215)) for _ in range(need))
    mix = ["E04"] * 13 + ["E01"] * 4 + ["E05"] * 1 + ["E15"] * 2 + ["E16"] * 1 + ["E04"] * 2
    fmts = ["chat_paste", "phone_ime", "chat_paste", "phone_ime", "mac_dictation", "chat_paste", "phone_ime"]
    for k, t in enumerate(slots):
        e = mix[k % len(mix)]
        cls = ev_class([e])
        fmt = "phone_ime" if cls == "priv" else fmts[k % len(fmts)]
        app = {"chat_paste": "飞书", "phone_ime": "微信" if cls == "priv" else R.choice(["飞书", "备忘录"]),
               "mac_dictation": "备忘录"}[fmt]
        if e == "E16":
            app = "微信"
        it = new_item(f"N:0826-{k:02d}", fmt, t, app=app, mode="typed" if fmt == "phone_ime" else None)
        m = matter(it, e)
        if e in ("E04", "E01") and t > first_time("E04-f2"):
            m["facts"] = R.choice([["E04-f2"], [], ["E01-f7"] if e == "E01" else ["E04-f1"]])
            m["role"] = "repeat" if m["facts"] else "context"
            if m["facts"] and m["facts"][0].split("-")[0] != e:
                m["facts"] = []
                m["role"] = "context"
        if e == "E15":
            it["cast"] = ["chen_ke"]


# ------------------------------------------------------------------------------------------ noise
NOISE_THEMES = BIBLE_D["noise_themes"]
HARD = ["信用卡积分换机票（和工作里的积分无关）", "楼下新开的小澄咖啡（一家咖啡店，和小澄助手无关）", "表妹考研面试（和任何招聘无关）",
        "朋友的独立游戏上线（和公司上线无关）", "别家公司的故障新闻（虚构公司）", "家里的猫可可吐毛球/驱虫（猫叫可可）"]


def plan_noise():
    total_items = len(ITEMS)
    target_noise = TARGET_TOTAL - total_items
    plan = []
    for f, n in NOISE_PLAN.items():
        plan += [f] * n
    while len(plan) < target_noise:
        plan.append("phone_ime")
    plan = plan[:max(0, target_noise)]
    R.shuffle(plan)
    counts = Counter(it["cap"].date() for it in ITEMS)
    all_days = list(days())
    deficits = {d: max(0.5, day_weight(d) * 1600 / sum(day_weight(x) for x in all_days) - counts[d]) for d in all_days}
    hard_idx = set(R.sample(range(len(plan)), max(1, len(plan) // 5)))
    cat_idx = set(R.sample(sorted(set(range(len(plan))) - hard_idx), 5))
    for i, fmt in enumerate(plan):
        d = R.choices(all_days, weights=[deficits[x] for x in all_days])[0]
        deficits[d] = max(0.3, deficits[d] - 1)
        if i in hard_idx:
            theme = HARD[i % len(HARD)]
        elif i in cat_idx:
            theme = HARD[5]
        else:
            theme = R.choice(NOISE_THEMES[:-1])
        if fmt == "email":
            app = R.choice(["邮件", "个人邮箱", "个人邮箱"])
            theme = R.choice(["系统通知邮件（虚构公司内部系统：报销、门禁、IT 工单）", "订阅邮件（虚构媒体的行业周刊）", "广告邮件（虚构电商预售、会员日）",
                              "物业电子账单", "航空里程到期提醒（信用卡积分换机票）" if i in hard_idx else "健身房续卡提醒"])
        elif fmt == "chat_paste":
            app = R.choice(["微信", "微信", "飞书", "企业微信"])
        elif fmt == "mac_dictation":
            app = "备忘录"
        else:
            app = R.choice(["备忘录", "微信", "浏览器", "提醒事项", "淘宝", "美团"])
        cls = "priv" if app in ("微信", "个人邮箱", "淘宝", "美团") else "work"
        it = new_item(f"Z:{d.isoformat()}-{i:03d}", fmt, slot_time(d, fmt, cls), app=app, noise=True, theme=theme,
                      mode=("voice" if R.random() < 0.35 else "typed") if fmt == "phone_ime" else None)
        it["tags"].append("noise")
        if i in hard_idx:
            it["tags"].append("hard_noise")


# ------------------------------------------------------------------------------------------ timing
def late_content():
    """~12% of items carry content older than capture by >1 day (pasted old chats, late exports, dragged PDFs)."""
    rates = {"chat_paste": 0.36, "doc_text": 0.4, "email": 0.12, "mac_dictation": 0.12, "phone_ime": 0.05,
             "tencent_transcript": 0.2, "feishu_transcript": 0.2, "zoom_transcript": 0.25, "pdf": 0.45, "screenshot": 0.4}
    firsts = {f["first"] for f in FACTS.values()}
    for it in ITEMS:
        if it["key"] in firsts or it["noise"] or it["brainstorm"] or it["key"].startswith("N:") or it.get("copy_of"):
            continue
        if it["fmt"] in ("claude_result", "codex_result"):
            continue
        if any(m.get("must_before") for m in it["matters"]):
            continue
        if R.random() >= rates.get(it["fmt"], 0):
            continue
        base = it.get("content_time") or it["cap"]
        shift = timedelta(days=R.choice([1, 2, 2, 3, 4]), hours=R.randint(1, 10))
        new_cap = base + shift
        if new_cap > END_DT:
            continue
        it["content_time"] = base
        it["cap"] = new_cap
        it["late"] = True


def fix_order():
    """Every mention of a fact comes after its first item; repeats flagged must_before come before the successor;
    nothing about an event is captured before that event's earliest first item, except meetings (pre-context)."""
    first_of_event = {}
    for fid, f in FACTS.items():
        t = first_time(fid)
        e = f["event_id"]
        first_of_event[e] = min(first_of_event.get(e, t), t)
    for _ in range(3):
        for it in ITEMS:
            for m in it["matters"]:
                for fid in m["facts"]:
                    ft = first_time(fid)
                    if BY_KEY[FACTS[fid]["first"]] is it:
                        continue
                    if it["cap"] <= ft:
                        it["cap"] = ft + timedelta(minutes=R.randint(3, 50))
                if m.get("must_before"):
                    lim = first_time(m["must_before"])
                    if it["cap"] >= lim:
                        lo = max(first_time(m["facts"][0]) if m["facts"] else lim - timedelta(hours=6), lim - timedelta(days=3))
                        span = max(1, int((lim - lo).total_seconds() // 60) - 2)
                        it["cap"] = lo + timedelta(minutes=R.randint(1, span))
                if not it["fmt"].endswith("transcript") and it["cap"] < first_of_event[m["event"]] and \
                        BY_KEY[FACTS[FACTS_BY_EVENT[m["event"]][0]]["first"]] is not it:
                    it["cap"] = first_of_event[m["event"]] + timedelta(minutes=R.randint(5, 90))
            if it["cap"] > END_DT:
                it["cap"] = END_DT - timedelta(minutes=R.randint(1, 30))
            if it.get("content_time") and it["content_time"] > it["cap"]:
                it["content_time"] = None


def diversify():
    for fid, f in FACTS.items():
        its = [it for it in ITEMS if any(fid in m["facts"] for m in it["matters"])]
        if len(its) >= 3 and len({it["fmt"] for it in its}) >= 2:
            continue
        fmts = {it["fmt"] for it in its}
        t0 = first_time(fid)
        cands = [it for it in ITEMS if it["cap"] > t0 and it["fmt"] not in fmts and not it.get("copy_of")
                 and any(m["event"] == f["event_id"] and not m["facts"] for m in it["matters"])]
        cands.sort(key=lambda it: it["cap"])
        for it in cands[:max(1, 3 - len(its))]:
            m = next(m for m in it["matters"] if m["event"] == f["event_id"] and not m["facts"])
            m["facts"] = [fid]
            m["role"] = "repeat"


def compute_roles():
    """Role of each fact mention by capture order: new (the first item), repeat (before the successor's first
    item), stale (after it)."""
    for it in ITEMS:
        it["fact_refs"] = []
        for m in it["matters"]:
            refs = []
            for fid in m["facts"]:
                f = FACTS[fid]
                if BY_KEY[f["first"]] is it:
                    role = "new"
                elif f["superseded_by"] and first_time(f["superseded_by"]) < it["cap"]:
                    role = "stale"
                else:
                    role = "repeat"
                refs.append({"fact_id": fid, "role": role})
                it["fact_refs"].append({"fact_id": fid, "role": role})
            m["refs"] = refs
            if m["role"] == "stale" and not any(r["role"] == "stale" for r in refs):
                m["role"] = "repeat"
            if any(r["role"] == "stale" for r in refs):
                m["role"] = "stale"


# ------------------------------------------------------------------------------------------ people
def surfaces(pid: str) -> list[str]:
    p = PEOPLE[pid]
    return [p["name"]] + [a for a in p.get("aliases", []) if a not in ("他", "我")]


COLLIDE = {("zhou_qiming", "周总"), ("zhou_yi", "周总"), ("wang_rui", "王老师"), ("wang_zhendong", "王老师"),
           ("lu_xiaolei", "Lily"), ("huang_li", "Lily Huang"), ("fang_ke", "可可"), ("cheng_yuan", "老程")}


def pick_surface(pid: str, fmt: str, speaker: bool) -> str:
    p = PEOPLE[pid]
    al = [a for a in p.get("aliases", []) if a not in ("他", "我")]
    if fmt == "tencent_transcript":
        latin = [a for a in al if a.replace(" ", "").isascii() and " " in a and a.split()[-1].isupper()]
        eng = [a for a in al if a.isascii() and " " not in a]
        r = R.random()
        if latin and r < 0.7:
            return f"{p['name']} {latin[0]}"
        if eng and r < 0.85:
            return eng[0]
        return p["name"] if r < 0.95 or not al else R.choice(al)
    if fmt == "feishu_transcript":
        return p["name"]
    if fmt == "zoom_transcript":
        eng = [a for a in al if a.isascii()]
        return R.choice(eng) if eng and R.random() < 0.5 else p["name"]
    if speaker:  # chat sender display name
        return p["name"] if R.random() < 0.55 or not al else R.choice(al)
    return p["name"] if R.random() < 0.35 or not al else R.choice(al)


def names_in(text: str) -> list[str]:
    out = []
    for pid, p in PEOPLE.items():
        if pid != OWNER and p["name"] in text:
            out.append(pid)
    return out


def assign_people():
    for it in ITEMS:
        eids = [m["event"] for m in it["matters"]]
        cls = ev_class(eids) if eids else "work"
        fmt = it["fmt"]
        # speakers / senders
        if fmt == "chat_paste" and not it["cast"] and not it["noise"]:
            if it["app"] == "微信":
                pool = sorted({p for e in eids for p in WECHAT_CONTACTS.get(e, [])}) or ["cheng_yuan"]
                it["cast"] = [R.choice(pool), OWNER]
                it["title"] = PEOPLE[it["cast"][0]]["name"]
            elif it["app"] == "企业微信":
                it["cast"] = ["huang_li", OWNER] + (["ma_xiao"] if R.random() < 0.3 else [])
                it["title"] = "禾数标注对接" if len(it["cast"]) > 2 else "黄莉（禾数标注）"
            elif cls == "sens":
                pool = sorted({p for e in eids for p in SENS_CHAT.get(e, [])})
                it["cast"] = [R.choice(pool), OWNER]
                it["title"] = PEOPLE[it["cast"][0]]["name"]
            else:
                ppl = sorted({p for e in eids for p in EVENTS[e]["people"] if p != OWNER and PEOPLE[p]["org"] == "澄湾集团"})
                single = R.random() < 0.4 or not any(e in GROUPS for e in eids)
                if single:
                    it["cast"] = [R.choice(ppl), OWNER]
                    it["title"] = PEOPLE[it["cast"][0]]["name"]
                else:
                    k = min(len(ppl), R.randint(2, 4))
                    it["cast"] = R.sample(ppl, k) + [OWNER]
                    ge = next(e for e in eids if e in GROUPS)
                    it["title"] = R.choice(GROUPS[ge])
                    it["merged"] = R.random() < 0.2
        if fmt == "email" and "email" not in it and not it["noise"]:
            if cls == "priv":
                pool = [p for e in eids for p in {"E14": ["wang_rui", "zhou_yi", "tian_ye"], "E15": ["chen_ke", "meng_jia", "wang_zhendong"]}.get(e, [])]
                other = R.choice(pool)
                personal = True
            else:
                ppl = sorted({p for e in eids for p in EVENTS[e]["people"] if p != OWNER and PEOPLE[p]["org"] == "澄湾集团"})
                if cls == "sens":
                    ppl = [p for p in ppl if p in ("gu_nan", "han_lifeng")] or ["gu_nan"]
                other = R.choice(ppl)
                personal = False
            if R.random() < 0.5:
                it["email"] = {"from": OWNER, "to": [other], "cc": [], "personal": personal}
            else:
                it["email"] = {"from": other, "to": [OWNER], "cc": [], "personal": personal}
            it["cast"] = [other]
        # named people: people mentioned in the facts, plus one or two more from the event
        named = []
        for m in it["matters"]:
            for fid in m["facts"]:
                named += names_in(FACTS[fid]["text"])
            ppl = [p for p in EVENTS[m["event"]]["people"] if p != OWNER]
            if cls in ("priv", "priv_mixed") and m["event"] not in PRIV:
                ppl = [p for p in ppl if p not in BOSSES]
            if ppl and R.random() < (0.55 if not fmt.endswith("transcript") else 0.2):
                named.append(R.choice(ppl))
        cast_set = set(it["cast"])
        seen = []
        for p in named:
            if p not in cast_set and p not in seen:
                seen.append(p)
        it["named"] = seen[:4]
    # surface forms
    for it in ITEMS:
        fmt = it["fmt"]
        it["cast_s"] = [[p, "我" if p == OWNER and fmt == "chat_paste" and it["app"] == "微信" else pick_surface(p, fmt, True)]
                        for p in it["cast"]]
        it["named_s"] = [[p, pick_surface(p, fmt, False)] for p in it["named"]]
    # collision quotas: each colliding alias in >= 7 items
    for pid, alias in sorted(COLLIDE):
        have = [it for it in ITEMS if any(p == pid and s.startswith(alias) for p, s in it["named_s"] + it["cast_s"])]
        cands = [it for it in ITEMS if any(p == pid for p, _ in it["named_s"]) and it not in have]
        R.shuffle(cands)
        for it in cands[:max(0, 7 - len(have))]:
            for ps in it["named_s"]:
                if ps[0] == pid:
                    ps[1] = alias
        if len(have) + len(cands) < 7:
            # add the person as a named mention on items of their events
            evs = [e for e, ev in EVENTS.items() if pid in ev["people"]]
            extra = [it for it in ITEMS if any(m["event"] in evs for m in it["matters"]) and pid not in it["named"]
                     and pid not in it["cast"] and not it["fmt"].endswith("transcript")]
            R.shuffle(extra)
            for it in extra[:7 - len(have) - len(cands)]:
                it["named"].append(pid)
                it["named_s"].append([pid, alias])
    # the owner is a person of every item she authors (not of noise forwarded to her)
    for it in ITEMS:
        pids = [p for p, _ in it["cast_s"]] + [p for p, _ in it["named_s"]]
        if not it["noise"] or it["fmt"] in ("phone_ime", "mac_dictation"):
            if OWNER not in pids:
                pids = [OWNER] + pids
        it["persons"] = list(dict.fromkeys(pids))


# ------------------------------------------------------------------------------------------ style flags
ASR_SUBS = [("小澄", "小程"), ("小澄", "小成"), ("栖木", "七木"), ("栖木", "期木"), ("鹭洲", "路洲"), ("鹭洲", "陆洲"), ("灰度", "恢复"),
            ("积分", "鸡分"), ("晋升", "进身"), ("复盘", "服盘"), ("Go/NoGo", "够不够"), ("OKR", "OK啊"), ("PRD", "P2D"),
            ("梁晨", "凉晨"), ("唐雨桐", "唐语童")]
ASR_BY_EVENT = {"E01": ["小澄", "灰度", "Go/NoGo", "PRD", "梁晨"], "E02": ["积分", "灰度"], "E03": ["小澄"], "E04": ["积分", "复盘"],
                "E05": ["积分", "唐雨桐"], "E07": ["小澄", "梁晨"], "E09": ["小澄"], "E10": ["OKR"], "E13": ["晋升"], "E14": ["栖木"],
                "E15": ["鹭洲"], "E16": ["栖木", "鹭洲"], "E12": ["梁晨"], "E21": ["小澄"], "E08": ["小澄"]}


def style_flags():
    xiaocheng_asr = 0
    for it in ITEMS:
        voice = it["fmt"] == "mac_dictation" or (it["fmt"] == "phone_ime" and it.get("mode") == "voice")
        rate = 0.2 if it["fmt"] == "mac_dictation" else (0.3 if it["fmt"] == "phone_ime" else 0)
        if it["fmt"] == "phone_ime" and not voice:
            rate = 0.3  # typos and pinyin slips when typing
        if R.random() < rate and not it["noise"]:
            cands = [w for m in it["matters"] for w in ASR_BY_EVENT.get(m["event"], [])]
            if cands:
                w = R.choice(cands)
                sub = R.choice([s for s in ASR_SUBS if s[0] == w])
                it["asr"] = list(sub)
                if sub[1] == "小程":
                    xiaocheng_asr += 1
                # a misheard name changes that person's surface
                for ps in it["named_s"]:
                    if PEOPLE[ps[0]]["name"] == sub[0]:
                        ps[1] = sub[1]
    # 小程 (ASR for 小澄) must collide with 老程 in >= 7 items
    cands = [it for it in ITEMS if "asr" not in it and any(m["event"] == "E01" for m in it["matters"])
             and (it["fmt"] == "mac_dictation" or it.get("mode") == "voice")]
    R.shuffle(cands)
    for it in cands[:max(0, 7 - xiaocheng_asr)]:
        it["asr"] = ["小澄", "小程"]
    # oblique follow-ups: later supplements that do not name the matter
    for it in ITEMS:
        if it["fmt"].endswith("transcript") or it["fmt"] in ("pdf", "screenshot", "email", "claude_result", "codex_result", "doc_text"):
            continue
        for m in it["matters"]:
            if m["role"] in ("repeat", "stale") and m["facts"]:
                fd = max(FACTS[f]["date_obj"] for f in m["facts"])
                if (it["cap"].date() - fd).days >= 1 and R.random() < 0.55:
                    m["oblique"] = True
            elif m["role"] == "context" and R.random() < 0.28:
                m["oblique"] = True
    for e in EIDS:
        have = sum(1 for it in ITEMS for m in it["matters"] if m["event"] == e and m["oblique"])
        cands = [(it, m) for it in ITEMS for m in it["matters"] if m["event"] == e and not m["oblique"]
                 and it["fmt"] in ("phone_ime", "mac_dictation", "chat_paste") and m["role"] != "first"]
        R.shuffle(cands)
        for it, m in cands[:max(0, 6 - have)]:
            m["oblique"] = True


def shot_cast():
    """Senders of chat screenshots; runs after every other draw from R so the rest of the plan is unchanged."""
    rs = random.Random(SEED + 1)
    for key, cast in fx.SHOT_CAST.items():
        it = BY_KEY["S:" + key]
        it["cast_s"] = [[p, s or (PEOPLE[p]["name"] if rs.random() < 0.6 else rs.choice(surfaces(p)))] for p, s in cast]
        it["persons"] = list(dict.fromkeys([OWNER] + [p for p, _ in it["cast_s"]] + it["persons"]))


def length_target(it: dict) -> list[int]:
    fmt = it["fmt"]
    if it.get("length"):
        return it["length"]
    if it["brainstorm"]:
        k = len(it["matters"])
        return [60 * k, 110 * k] if fmt == "mac_dictation" else [30 * k, 60 * k]
    return {"phone_ime": [5, 120] if R.random() < 0.75 else [80, 200], "mac_dictation": [60, 260] if R.random() < 0.7 else [250, 600],
            "chat_paste": [60, 400], "email": [150, 700], "claude_result": [300, 1200], "codex_result": [200, 1000],
            "doc_text": [100, 600], "screenshot": [0, 0], "pdf": [800, 2200]}.get(fmt, [50, 300])


# ------------------------------------------------------------------------------------------ gold: checkpoints and home grades
def item_id(key: str) -> str:
    return str(uuid.uuid5(NS, "scale-pm/" + key))


def checkpoints(sorted_items):
    marks = [("w1", "2026-08-16T23:59"), ("w2", "2026-08-23T23:59"), ("inc_night", "2026-08-27T01:40"),
             ("w3", "2026-08-30T23:59"), ("d0902", "2026-09-02T23:59"), ("w4", "2026-09-06T23:59"),
             ("w5", "2026-09-13T23:59"), ("d0918", "2026-09-18T23:59"), ("w6", "2026-09-20T23:59")]
    out = []
    for cid, ts in marks:
        T = datetime.fromisoformat(ts).replace(tzinfo=TZ)
        upto = [it for it in sorted_items if it["cap"] <= T]
        if not upto:
            continue
        last = upto[-1]
        present = sorted({m["event"] for it in upto for m in it["matters"]})
        expected, grades, why = {}, {}, {}
        for e in present:
            vf = [f for f in FACTS_BY_EVENT[e] if first_time(f) <= T and not (FACTS[f]["superseded_by"] and first_time(FACTS[f]["superseded_by"]) <= T)]
            vf.sort(key=first_time)
            pending = [f for f in vf if FACTS[f]["state"] == "planned" and FACTS[f]["due"]
                       and not (FACTS[f]["resolved_by"] and first_time(FACTS[f]["resolved_by"]) <= T)]
            future = [f for f in pending if date.fromisoformat(FACTS[f]["due"]) > T.date()]
            exp = []
            if vf:
                exp.append(vf[-1])
            for f in sorted(future, key=lambda x: FACTS[x]["due"]):
                if f not in exp and len(exp) < 3:
                    exp.append(f)
            if exp:
                expected[e] = exp
            g, reason = grade(e, T, vf, future)
            grades[e], why[e] = g, reason
        out.append({"checkpoint_id": cid, "after_item_id": item_id(last["key"]), "label": ts.replace("T", " "),
                    "expected": expected, "home": {"grades": grades, "why": why}})
    out[-1]["home"]["reference_order"] = ["E16", "E14", "E03", "E01", "E04", "E20", "E12"]
    return out


def grade(e: str, T: datetime, vf: list[str], future: list[str]) -> tuple[int, str]:
    if not vf:
        return 1, "有素材但还没有确定的事实"
    last = FACTS[vf[-1]]
    recent = (T - first_time(vf[-1])) <= timedelta(hours=24)
    if future:
        f = min(future, key=lambda x: FACTS[x]["due"])
        days_to = (date.fromisoformat(FACTS[f]["due"]) - T.date()).days
        owner_node = e in PRIV | {"E13"} or e in ("E10", "E01", "E09", "E18", "E21") and "江予安" not in FACTS[f]["text"]
        if e in LOW_STAKES:
            g = 2 if days_to <= 1 else 1
            return g, f"轻量小事；最近节点 {FACTS[f]['due']}（{days_to} 天后）"
        if days_to <= 1 or (e in {"E14", "E15", "E16"} and days_to <= 5):
            return 3, f"本人要在 {FACTS[f]['due']} 前办/答复（{days_to} 天后）"
        if days_to <= 7:
            return 2, f"{days_to} 天后有节点（{FACTS[f]['due']}）"
        return 1, f"最近节点在 {days_to} 天后（{FACTS[f]['due']}）"
    if last["state"] in ("done", "cancelled"):
        open_left = [f for f in vf if FACTS[f]["state"] in ("planned", "in_progress") and first_time(f) > first_time(vf[-1]) - timedelta(days=3)]
        if open_left:
            return 1, "最近有进展，仍有未了的尾巴"
        return (1, "刚办完/刚取消（24 小时内）") if recent else (0, "已办完或已取消，无待办")
    if recent:
        return 2, "24 小时内有新变化，但没有日期节点"
    return 1, "在进行，没有近期日期节点"


# ------------------------------------------------------------------------------------------ main
def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--p-pair", type=float, default=0.33)
    args = ap.parse_args(argv)
    for f in FACTS.values():
        f["date_obj"] = date.fromisoformat(f["date"])
    build_fixed()
    add_auto_repeats()
    fill_copies()
    plan_repeats()
    plan_filler()
    plan_brainstorms()
    groups = pack_pool(args.p_pair)
    fmts = assign_formats(groups)
    materialise(groups, fmts)
    plan_incident_night()
    plan_noise()
    late_content()
    fix_order()
    diversify()
    fix_order()
    compute_roles()
    assign_people()
    style_flags()
    for it in ITEMS:
        it["length"] = length_target(it)
        it["kind"] = KIND_OF[it["fmt"]]
        if it["fmt"] == "pdf" and it.get("scanned"):
            it["kind"] = "image"
        sens = sorted({FACTS[r["fact_id"]]["sensitive"] for r in it["fact_refs"] if FACTS[r["fact_id"]]["sensitive"]})
        evs = {m["event"] for m in it["matters"]}
        if evs & {"E14", "E15"}:
            sens.append("面试与offer")
        if "E16" in evs:
            sens.append("去留与家庭财务")
        if "E19" in evs:
            sens.append("健康")
        if "E12" in evs:
            sens.append("绩效")
        if "E11" in evs and any(m["role"] in ("first", "repeat") and m["facts"] for m in it["matters"] if m["event"] == "E11"):
            sens.append("面评")
        it["sensitive"] = sorted(set(sens))
    shot_cast()
    ITEMS.sort(key=lambda x: (x["cap"], x["key"]))
    cps = checkpoints(ITEMS)
    out = {"seed": SEED, "items": [], "facts": [], "checkpoints": cps}
    for it in ITEMS:
        o = {k: v for k, v in it.items() if k not in ("cap", "content_time", "cast", "named")}
        o["item_id"] = item_id(it["key"])
        o["t"] = it["cap"].isoformat(timespec="minutes")
        o["content_time"] = it["content_time"].isoformat(timespec="minutes") if it.get("content_time") else None
        o["events"] = [m["event"] for m in it["matters"]]
        for m in o["matters"]:
            m.pop("must_before", None)
        out["items"].append(o)
    for fid, f in FACTS.items():
        o = {k: v for k, v in f.items() if k != "date_obj"}
        o["valid_from"] = item_id(f["first"])
        out["facts"].append(o)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    report(out)
    return 0


def report(out):
    items = out["items"]
    fmts = Counter(it["fmt"] for it in items)
    non_noise = [it for it in items if not it["noise"]]
    multi = [it for it in non_noise if len(it["events"]) >= 2]
    meetings = [it for it in items if it["fmt"].endswith("transcript")]
    m3 = [it for it in meetings if len(it["events"]) >= 3]
    ev = Counter(e for it in items for e in it["events"])
    obl = [it for it in non_noise if any(m.get("oblique") for m in it["matters"])]
    obl_ev = Counter(m["event"] for it in items for m in it["matters"] if m.get("oblique"))
    stale = sum(1 for it in items for r in it["fact_refs"] if r["role"] == "stale")
    late = [it for it in items if it.get("content_time") and (datetime.fromisoformat(it["t"]) - datetime.fromisoformat(it["content_time"])) > timedelta(days=1)]
    per_day = Counter(it["t"][:10] for it in items)
    bs = [it for it in items if it["brainstorm"]]
    print(f"items {len(items)}  noise {len(items) - len(non_noise)}  formats {dict(fmts)}", file=sys.stderr)
    print(f"multi-matter {len(multi)}/{len(non_noise)} = {len(multi) / len(non_noise):.1%}; meetings >=3 events {len(m3)}/{len(meetings)}", file=sys.stderr)
    print(f"brainstorms {len(bs)} (6-8 events: {sum(1 for b in bs if len(b['events']) >= 6)})", file=sys.stderr)
    print(f"oblique items {len(obl)}/{len(non_noise)} = {len(obl) / len(non_noise):.1%}; min per event {min(obl_ev.values())}", file=sys.stderr)
    print(f"stale mentions {stale}; late content {len(late)} = {len(late) / len(items):.1%}", file=sys.stderr)
    print("event mentions " + " ".join(f"{e}:{ev[e]}/{EVENTS[e]['target_items']}" for e in EIDS) + f" total {sum(ev.values())}", file=sys.stderr)
    print("per day " + " ".join(f"{d[5:]}:{n}" for d, n in sorted(per_day.items())), file=sys.stderr)
    fm = Counter()
    kinds = defaultdict(set)
    for it in items:
        for r in it["fact_refs"]:
            fm[r["fact_id"]] += 1
            kinds[r["fact_id"]].add(it["fmt"])
    thin = [f for f in FACTS if fm[f] < 3 or len(kinds[f]) < 2]
    print(f"facts {len(FACTS)}; with <3 mentions or <2 source kinds: {thin}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
