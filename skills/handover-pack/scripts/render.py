#!/usr/bin/env python3
"""A stored handover pack as Markdown (the export, and the text of the snapshot item a member shares).

render(pack, sources, title, as_of, people=None) -> str
  pack     the stored pack (build.finish, item handles mapped to item ids)
  sources  {item_id: {"kind": "口述", "src": "微信", "t": "2026-09-03 20:10"}} for every cited item
Every claim ends with its sources as ①②… (numbered by first citation); the list of sources at the end gives each
number's item id, so the Mac can link them. Placeholders stay as they are: the Mac puts the originals back.
"""

from __future__ import annotations

from typing import Optional

CIRCLED = "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳"


def _num(n: int) -> str:
    return CIRCLED[n - 1] if 0 < n <= len(CIRCLED) else f"[{n}]"


def render(pack: dict, sources: dict, title: str, as_of: str, people: Optional[dict] = None) -> str:
    order: list[str] = []

    def refs(ids) -> str:
        out = []
        for i in ids or []:
            if i not in order:
                order.append(i)
            out.append(_num(order.index(i) + 1))
        return "".join(out)

    def line(text: str, ids, quote: str = "") -> str:
        q = f"——“{quote}”" if quote else ""
        r = refs(ids)
        return f"- {text}{q}" + (f" {r}" if r else "")

    people = people or {}
    out = [f"# 交接包：{title}", "",
           f"> 截至 {as_of}，由织机根据这件事的素材整理，每一句都标了出处；交接前请和原负责人核对。"]
    if people.get("from") or people.get("to"):
        out.append(f"> 交接：{people.get('from') or '原负责人'} → {people.get('to') or '新负责人'}")
    st = pack.get("status") or {}
    out += ["", "## 现在到哪了", "", f"{st.get('text', '')} {refs(st.get('evidence'))}".strip()]
    open_c = [c for c in pack.get("commitments") or [] if c["state"] == "open"]
    done_c = [c for c in pack.get("commitments") or [] if c["state"] == "done"]
    if open_c:
        out += ["", "## 谁还欠着什么", ""]
        for c in open_c:
            due = f"（{c['due']} 前）" if c.get("due") else ""
            to = f" → {c['to']}" if c.get("to") else ""
            out.append(line(f"**{c['who']}**{to}：{c['what']}{due}", c["evidence"], c.get("quote", "")))
    if pack.get("deadlines"):
        out += ["", "## 截止日", ""]
        for d in pack["deadlines"]:
            out.append(line(f"{d['date'] or '日期未定'}：{d['what']}", d["evidence"], d.get("quote", "")))
    if pack.get("decisions"):
        out += ["", "## 已经定下的事", ""]
        for d in pack["decisions"]:
            who = f"（{'、'.join(d['who'])}）" if d.get("who") else ""
            when = f"{d['date']} " if d.get("date") else ""
            out.append(line(f"{when}{d['what']}{who}", d["evidence"], d.get("quote", "")))
    if pack.get("open_questions"):
        out += ["", "## 还没有答案的问题", ""]
        for q in pack["open_questions"]:
            out.append(line(q["what"], q["evidence"], q.get("quote", "")))
    if pack.get("next_steps"):
        out += ["", "## 接手先做", ""]
        for s in pack["next_steps"]:
            out.append(line(s["what"], s["evidence"]))
    if done_c:
        out += ["", "## 已经兑现的承诺", ""]
        for c in done_c:
            out.append(line(f"{c['who']}：{c['what']}", c["evidence"], c.get("quote", "")))
    if pack.get("links"):
        out += ["", "## 先看这几条素材", ""]
        for ln in pack["links"]:
            out.append(line(ln["why"], [ln["item"]]))
    if order:
        out += ["", "## 出处", ""]
        for n, i in enumerate(order, 1):
            s = sources.get(i) or {}
            label = " · ".join(x for x in (s.get("t"), s.get("kind"), s.get("src")) if x)
            out.append(f"{_num(n)} {label}（素材 `{i}`）")
    return "\n".join(out) + "\n"
