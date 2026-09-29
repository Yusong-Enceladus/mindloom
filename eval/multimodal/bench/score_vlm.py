#!/usr/bin/env python3
"""Score VLM extraction runs (from run_vlm.py) against the mm-v1 ground truth. No model is called.

Per image it computes, from the model's JSON only:
  cer            character error rate of the image's text (README normalization: NFKC, no whitespace,
                 look-alike punctuation folded, the "合成数据" mark removed), composed the same way from
                 the ground truth and from the prediction; capped at 1 per image
  fields         key fields (names, dates/times, numbers/amounts/ids) plus flags and text fields, each
                 right/wrong; "key-field EM" = exact match over the name/date/number classes
  qa             each ground-truth question counts as answered when its answer can be read off the
                 extraction (number: all its numbers present; exact/contains: normalized substring;
                 date: a parsed date equal; trend: a series trend equal); no second model call
  fab_numbers    numbers in the output that appear nowhere in the image's ground truth (text_lines,
                 every gt value, qa answers), over all numbers in the output; a chat file bubble's drawn size
                 ("86 KB", not kept in the ground truth) is not counted
  unsupported    structured field values (not free text lines) that are not in the image: not a
                 normalized substring of the ground-truth text and more than 25% edits away from any
                 substring of it, over all non-empty structured values
  num_recall     share of numbers in text_lines that appear in the output
plus type-specific metrics (chat sender/time/is_self, chart points/trend/KPI, slide bullets, handwriting
struck/checked, receipt items F1 and self-consistency, scan table cells, label fields).

  python3 score_vlm.py --gt-root .. --run qwen36-q8=results/raw/qwen36-q8.r1.jsonl ... --out results/scores.json
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from textmetrics import (cer, eq_date, eq_num, eq_text, eq_time, norm, numbers, parse_date,  # noqa: E402
                         similarity, substring_distance, zeroish)

KEY_CLASSES = ("name", "date", "number")
FILE_SIZE = re.compile(r"\d+(?:\.\d+)?\s?[KMG]B\b", re.I)
TREND_WORDS = {"上升": "up", "下降": "down", "基本持平": "flat", "先升后降": "rise_then_fall", "先降后升": "fall_then_rise",
               "upward": "up", "downward": "down", "flat": "flat", "rises then falls": "rise_then_fall",
               "falls then rises": "fall_then_rise"}


# ---------------------------------------------------------------- parsing
def parse_output(text: str):
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", text)
    try:
        obj = json.loads(text)
        return obj if isinstance(obj, dict) else None
    except ValueError:
        pass
    m = re.search(r"\{.*\}", text, re.S)
    if m:
        try:
            obj = json.loads(m.group(0))
            return obj if isinstance(obj, dict) else None
        except ValueError:
            return None
    return None


def s(x) -> str:
    return "" if x is None else (x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) if isinstance(x, (dict, list)) else str(x))


def lst(x) -> list:
    return x if isinstance(x, list) else []


def dct(x) -> dict:
    return x if isinstance(x, dict) else {}


def leaves(o, path=""):
    """(path, value) for every scalar in a JSON value."""
    if isinstance(o, dict):
        for k, v in o.items():
            yield from leaves(v, f"{path}.{k}")
    elif isinstance(o, list):
        for v in o:
            yield from leaves(v, f"{path}[]")
    elif o is not None:
        yield path, o


# ---------------------------------------------------------------- alignment
def align(gt_items: list, pred_items: list, key=None, threshold: float = 0.5, sim_fn=None) -> list[tuple[int, int]]:
    """Order-preserving alignment maximizing summed similarity; pairs below threshold never match.
    sim_fn(gt_item, pred_item) overrides the default similarity of key(item)."""
    n, m = len(gt_items), len(pred_items)
    sim_fn = sim_fn or (lambda g, p: similarity(key(g), key(p)))
    sim = [[sim_fn(g, p) for p in pred_items] for g in gt_items]
    best = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            opt = max(best[i + 1][j], best[i][j + 1])
            if sim[i][j] >= threshold:
                opt = max(opt, sim[i][j] + best[i + 1][j + 1])
            best[i][j] = opt
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        if sim[i][j] >= threshold and abs(best[i][j] - (sim[i][j] + best[i + 1][j + 1])) < 1e-12:
            pairs.append((i, j))
            i, j = i + 1, j + 1
        elif best[i + 1][j] >= best[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def classify(key: str, value) -> str:
    k = key.lower()
    if any(t in k for t in ("date", "expiry", "time", "日期", "有效期")) or parse_date(value):
        return "date"
    if any(t in k for t in ("recipient", "sender", "reporter", "contact", "shop", "manufacturer", "carrier", "merchant",
                            "buyer", "product", "item", "room", "owner", "attendee", "taker", "人", "部门", "单位", "负责")):
        if not (k.endswith("phone") or k.endswith("ext") or "address" in k):
            return "name"
    v = norm(value)
    if v and sum(ch.isdigit() for ch in v) >= max(1, len(v) // 3):
        return "number"
    if "address" in k or "地址" in k:
        return "text"
    return "name" if v and len(v) <= 12 and not any(ch.isdigit() for ch in v) else "text"


# ---------------------------------------------------------------- per-type scorers
class Card:
    def __init__(self):
        self.fields: list[tuple[str, str, bool]] = []  # (class, name, correct)
        self.extra: dict[str, list] = defaultdict(list)  # metric -> list of 0/1 or numbers
        self.gt_text = ""
        self.pred_text = ""
        self.struct_values: list[str] = []  # structured values stated by the model (for "unsupported")

    def field(self, cls: str, name: str, ok: bool):
        self.fields.append((cls, name, bool(ok)))


def score_chat(gt: dict, p: dict, rec: dict, c: Card):
    msgs = gt["messages"]
    pm = [dct(x) for x in lst(p.get("messages"))]
    # the drawn group title carries the member count "(N)"; the ground truth leaves it out by convention
    title = re.sub(r"\s*[(（]\d+[)）]\s*$", "", s(p.get("chat_title")))
    c.gt_text = "\n".join([gt["chat_title"]] + [m["text"] for m in msgs])
    c.pred_text = "\n".join([title] + [s(m.get("text")) for m in pm])
    c.field("name", "chat_title", eq_text(title, gt["chat_title"]))
    c.struct_values += [title]
    # README: align by order. Same count -> position; otherwise an order-preserving alignment where the text
    # decides and the sender breaks near-ties (a voice bubble read as '5"' still aligns with "[语音 5秒]")
    if len(pm) == len(msgs):
        pairs = {i: i for i in range(len(msgs))}
    else:
        pairs = dict(align(msgs, pm, threshold=0.4, sim_fn=lambda g, q: 0.7 * similarity(g.get("text"), q.get("text")) +
                           0.3 * similarity(g.get("sender"), q.get("sender"))))
    c.extra["msg_count_ok"].append(int(len(pm) == len(msgs)))
    similar = "similar_names" in rec["hard"]
    for i, g in enumerate(msgs):
        q = pm[pairs[i]] if i in pairs else None
        if q is None:
            ok_sender = ok_time = ok_self = ok_kind = ok_text = False
        else:
            ps = norm(q.get("sender"))
            if g["is_self"]:
                ok_sender = ps in ("我", "Me", "me") or q.get("is_self") is True and not ps
            elif g.get("sender_shown") is False:
                # one-to-one chat: no name is drawn; the title, "对方", nothing, or the avatar's initial all
                # identify the other party
                ok_sender = q.get("is_self") is False and (ps in ("对方", "Other", "other", "") or ps in norm(g["sender"]))
            else:
                ok_sender = ps == norm(g["sender"])
            ok_time = eq_text(q.get("time"), g["time"])
            ok_self = q.get("is_self") is g["is_self"]
            ok_kind = s(q.get("kind")) == g["kind"]
            ok_text = eq_text(q.get("text"), g["text"])
        c.field("name", "sender", ok_sender)
        c.field("date", "time", ok_time)
        c.field("flag", "is_self", ok_self)
        c.field("flag", "kind", ok_kind)
        c.field("text", "message_text", ok_text)
        c.extra["sender_acc"].append(int(ok_sender))
        c.extra["time_acc"].append(int(ok_time))
        c.extra["is_self_acc"].append(int(ok_self))
        c.extra["msg_text_exact"].append(int(ok_text))
        if g["time"]:
            c.extra["time_acc_labeled"].append(int(ok_time))
        if similar:
            c.extra["sender_acc_similar_names"].append(int(ok_sender))
    for q in pm:
        if not q.get("is_self") and norm(q.get("sender")) not in norm(gt["chat_title"]):
            c.struct_values.append(s(q.get("sender")))
        c.struct_values.append(s(q.get("time")))


def _series_points(sr: dict, cats_default: list) -> list[tuple[str, str]]:
    cats = sr.get("categories") or cats_default
    return list(zip(cats, sr["labels"]))


def score_chart(gt: dict, p: dict, rec: dict, c: Card):
    gseries = gt["series"]
    pseries = [dct(x) for x in lst(p.get("series"))]
    gtx = [gt["title"]]
    for k in gt.get("kpis", []):
        gtx += [k["label"], k["value"], k["delta"]]
    for sr in gseries:
        for cat, lab in _series_points(sr, gt.get("categories", [])):
            gtx += [cat, lab]
    ptx = [s(p.get("title"))]
    for k in lst(p.get("kpis")):
        k = dct(k)
        ptx += [s(k.get("label")), s(k.get("value")), s(k.get("delta"))]
    for sr in pseries:
        for pt in lst(sr.get("points")):
            pt = dct(pt)
            ptx += [s(pt.get("category")), s(pt.get("value"))]
    c.gt_text, c.pred_text = "\n".join(gtx), "\n".join(ptx)
    c.field("text", "title", eq_text(p.get("title"), gt["title"]))
    c.struct_values += [x for x in ptx if x]
    # match series: by name when several, else the pred series with most points
    used = set()
    for gi, sr in enumerate(gseries):
        cand = None
        if len(gseries) == 1 and pseries:
            cand = max(range(len(pseries)), key=lambda j: len(lst(pseries[j].get("points"))))
        elif pseries:
            scored = sorted(((similarity(sr["name"], s(pseries[j].get("name"))), j) for j in range(len(pseries)) if j not in used),
                            reverse=True)
            if scored and scored[0][0] >= 0.5:
                cand = scored[0][1]
            elif gi < len(pseries) and gi not in used:
                cand = gi
        if cand is not None:
            used.add(cand)
        pts = [dct(x) for x in lst(pseries[cand].get("points"))] if cand is not None else []
        gpts = _series_points(sr, gt.get("categories", []))
        by_cat = {norm(x.get("category")): s(x.get("value")) for x in pts}
        if len(gseries) == 1:  # a single-series chart read as one series per bar still carries every point
            for sp in pseries:
                for x in lst(sp.get("points")):
                    by_cat.setdefault(norm(dct(x).get("category")), s(dct(x).get("value")))
        for k, (cat, lab) in enumerate(gpts):
            val = by_cat.get(norm(cat))
            if val is None and len(pts) == len(gpts):
                val = s(pts[k].get("value"))
            ok = val is not None and eq_num(val, lab)
            c.field("number", "point", ok)
            c.extra["point_acc"].append(int(ok))
            c.field("text", "category", norm(cat) in by_cat)
        if sr["name"] in gt.get("trend", {}):
            ok = cand is not None and s(pseries[cand].get("trend")) == gt["trend"][sr["name"]]
            c.field("flag", "trend", ok)
            c.extra["trend_acc"].append(int(ok))
    pk = [dct(x) for x in lst(p.get("kpis"))]
    for i, k in enumerate(gt.get("kpis", [])):
        q = next((x for x in pk if eq_text(x.get("label"), k["label"])), None)
        if q is None and len(pk) == len(gt["kpis"]):
            q = pk[i]
        okv = q is not None and eq_text(q.get("value"), k["value"])
        okd = q is not None and eq_text(q.get("delta"), k["delta"])
        c.field("number", "kpi_value", okv)
        c.field("number", "kpi_delta", okd)
        c.extra["kpi_acc"] += [int(okv), int(okd)]
    c.extra["chart_type_ok"].append(int(s(p.get("chart_type")) == gt["chart_type"]))


def score_slide(gt: dict, p: dict, rec: dict, c: Card):
    gb = gt["bullets"]
    pb = [dct(x) for x in lst(p.get("bullets"))]
    pk = [dct(x) for x in lst(p.get("kpis"))]
    gtx = [gt["title"]] + ([gt["subtitle"]] if gt["subtitle"] else []) + [b["text"] for b in gb] + \
          [f"{k['label']} {k['value']}" for k in gt.get("kpis", [])] + [gt["footer"], gt["page"]]
    ptx = [s(p.get("title"))] + ([s(p.get("subtitle"))] if s(p.get("subtitle")) else []) + [s(b.get("text")) for b in pb] + \
          [f"{s(k.get('label'))} {s(k.get('value'))}" for k in pk] + [s(p.get("footer")), s(p.get("page"))]
    c.gt_text, c.pred_text = "\n".join(gtx), "\n".join(ptx)
    c.field("text", "title", eq_text(p.get("title"), gt["title"]))
    c.extra["title_exact"].append(int(eq_text(p.get("title"), gt["title"])))
    if gt["subtitle"]:
        c.field("text", "subtitle", eq_text(p.get("subtitle"), gt["subtitle"]))
    pairs = align(gb, pb, key=lambda b: s(b.get("text")), threshold=0.9)
    c.extra["bullet_recall"].append((len(pairs), len(gb)))
    c.extra["bullet_precision"].append((len(pairs), len(pb)))
    for i, j in pairs:
        c.extra["bullet_level_acc"].append(int(pb[j].get("level") == gb[i]["level"]))
    matched = {i: j for i, j in pairs}
    for i, b in enumerate(gb):
        c.field("text", "bullet", i in matched and eq_text(pb[matched[i]].get("text"), b["text"]))
    for i, k in enumerate(gt.get("kpis", [])):
        q = next((x for x in pk if eq_text(x.get("label"), k["label"])), None)
        if q is None and len(pk) == len(gt["kpis"]):
            q = pk[i]
        c.field("number", "kpi_value", q is not None and eq_text(q.get("value"), k["value"]))
    c.field("number", "page", eq_text(p.get("page"), gt["page"]))
    c.field("text", "footer", eq_text(p.get("footer"), gt["footer"]))
    c.struct_values += [s(p.get("title")), s(p.get("subtitle")), s(p.get("footer")), s(p.get("page"))] + \
        [s(k.get("label")) for k in pk] + [s(k.get("value")) for k in pk]


def score_board(gt: dict, p: dict, rec: dict, c: Card):
    gl = gt["lines"]
    pl = [dct(x) for x in lst(p.get("lines"))]
    c.gt_text = "\n".join(x["text"] for x in gl)
    c.pred_text = "\n".join(s(x.get("text")) for x in pl)
    if len(pl) == len(gl):
        pairs = {i: i for i in range(len(gl))}
    else:
        pairs = dict(align(gl, pl, key=lambda x: s(x.get("text")), threshold=0.4))
    for i, g in enumerate(gl):
        q = pl[pairs[i]] if i in pairs else None
        okt = q is not None and eq_text(q.get("text"), g["text"])
        oks = q is not None and bool(q.get("struck")) == g["struck"]
        okc = q is not None and bool(q.get("checked")) == g["checked"]
        c.field("number" if any(ch.isdigit() for ch in g["text"]) else "text", "line", okt)
        c.field("flag", "struck", oks)
        c.field("flag", "checked", okc)
        c.extra["line_exact"].append(int(okt))
        c.extra["struck_acc"].append(int(oks))
        c.extra["checked_acc"].append(int(okc))
        if g["struck"]:
            c.extra["struck_recall"].append(int(q is not None and bool(q.get("struck"))))
        if g["checked"]:
            c.extra["checked_recall"].append(int(q is not None and bool(q.get("checked"))))
    c.extra["line_count_ok"].append(int(len(pl) == len(gl)))


def score_receipt(gt: dict, p: dict, rec: dict, c: Card):
    c.gt_text = "\n".join(rec["text_lines"])
    c.pred_text = "\n".join(s(x) for x in lst(p.get("lines")))
    c.field("name", "merchant", eq_text(p.get("merchant"), gt["merchant"]))
    if gt.get("buyer"):
        c.field("name", "buyer", eq_text(p.get("buyer"), gt["buyer"]))
    okd = eq_date(p.get("date"), gt["date"])
    c.field("date", "date", okd)
    # the ground truth writes time as 24-hour "14:23" and doc_no without the printed "#"; the prompt asks
    # for the printed form ("2:23 PM", "#5483"), so compare the value, not the notation
    if gt.get("time"):
        c.field("date", "time", eq_time(p.get("time"), gt["time"]))
    c.field("number", "doc_no", norm(p.get("doc_no")).lstrip("#") == norm(gt["doc_no"]).lstrip("#"))
    c.field("number", "total", eq_num(p.get("total"), gt["total"]))
    printed = any("小计" in ln or "subtotal" in ln.lower() for ln in rec["text_lines"])
    c.field("number", "subtotal", eq_num(p.get("subtotal"), gt["subtotal"]) or (not printed and not norm(p.get("subtotal"))))
    for k in ("discount", "tax"):
        c.field("number", k, (zeroish(p.get(k)) and zeroish(gt[k])) or eq_num(p.get(k), gt[k]))
    if gt.get("total_in_words"):
        c.field("text", "total_in_words", eq_text(p.get("total_in_words"), gt["total_in_words"]))
    # printed "by bank transfer", ground truth "Bank transfer": case is not the reading
    c.field("name", "payment_method", norm(p.get("payment_method")).lower() == norm(gt["payment_method"]).lower())
    for k in ("merchant", "total", "doc_no"):
        c.extra[f"{k}_ok"].append(int(c.fields[[f[1] for f in c.fields].index(k)][2]))
    c.extra["date_ok"].append(int(okd))
    gi = gt["items"]
    pi = [dct(x) for x in lst(p.get("items"))]
    used, tp = set(), 0
    for g in gi:
        best, bj = 0.0, None
        for j, q in enumerate(pi):
            if j in used:
                continue
            sim = similarity(q.get("name"), g["name"])
            if sim > best:
                best, bj = sim, j
        name_ok = bj is not None and best >= 0.8
        amt_ok = name_ok and eq_num(pi[bj].get("amount"), g["amount"])
        if name_ok:
            used.add(bj)
        tp += int(name_ok and amt_ok)
        c.field("name", "item_name", name_ok and eq_text(pi[bj].get("name"), g["name"]))
        c.field("number", "item_amount", amt_ok)
        c.field("number", "item_qty", name_ok and eq_num(pi[bj].get("qty"), g["qty"]))
        c.field("number", "item_unit_price", name_ok and eq_num(pi[bj].get("unit_price"), g["unit_price"]))
    prec = tp / len(pi) if pi else 0.0
    recall = tp / len(gi) if gi else 0.0
    c.extra["item_f1"].append(2 * prec * recall / (prec + recall) if prec + recall else 0.0)

    def num(x):
        n = numbers(x)
        return float(n[0]) if len(n) == 1 else (0.0 if not norm(x) else None)
    amts = [num(q.get("amount")) for q in pi]
    tot, disc, tax = num(p.get("total")), num(p.get("discount")), num(p.get("tax"))
    consistent = None not in amts and tot is not None and disc is not None and tax is not None and pi and \
        abs(sum(amts) - disc + tax - tot) <= 0.011
    c.extra["self_consistent"].append(int(bool(consistent)))
    c.struct_values += [s(p.get(k)) for k in ("merchant", "buyer", "date_text", "time", "doc_no", "subtotal", "discount",
                                              "tax", "total", "payment_method", "total_in_words")]
    for q in pi:
        c.struct_values += [s(q.get(k)) for k in ("name", "qty", "unit", "unit_price", "amount")]


def _scan_lines(title, fields, blocks, getter) -> list[str]:
    out = [title] + [f"{getter(f, 'key')}:{getter(f, 'value')}" for f in fields]
    for b in blocks:
        if getter(b, "type") == "table":
            out.append(" | ".join(s(x) for x in lst(b.get("header"))))
            out += [" | ".join(s(x) for x in lst(r)) for r in lst(b.get("rows"))]
        else:
            out.append(getter(b, "text"))
    return out


def score_scan(gt: dict, p: dict, rec: dict, c: Card):
    get = lambda o, k: s(dct(o).get(k))  # noqa: E731
    pf = [dct(x) for x in lst(p.get("fields"))]
    pbl = [dct(x) for x in lst(p.get("blocks"))]
    c.gt_text = "\n".join(_scan_lines(gt["title"], gt["fields"], gt["blocks"], get))
    c.pred_text = "\n".join(_scan_lines(s(p.get("title")), pf, pbl, get))
    c.field("text", "title", eq_text(p.get("title"), gt["title"]))
    for i, f in enumerate(gt["fields"]):
        q = next((x for x in pf if eq_text(x.get("key"), f["key"])), None)
        if q is None and len(pf) == len(gt["fields"]):
            q = pf[i]
        c.field(classify(f["key"], f["value"]), "header_field", q is not None and eq_text(q.get("value"), f["value"]))
    gtables = [b for b in gt["blocks"] if b["type"] == "table"]
    ptables = [b for b in pbl if s(b.get("type")) == "table"]
    for ti, t in enumerate(gtables):
        q = ptables[ti] if ti < len(ptables) else {}
        grid = [t["header"]] + t["rows"]
        pgrid = [lst(q.get("header"))] + [lst(r) for r in lst(q.get("rows"))]
        for r, row in enumerate(grid):
            for col, cell in enumerate(row):
                pv = pgrid[r][col] if r < len(pgrid) and col < len(pgrid[r]) else None
                ok = pv is not None and eq_text(pv, cell)
                c.extra["table_cell_acc"].append(int(ok))
                c.field(classify(t["header"][col] if col < len(t["header"]) else "", cell), "table_cell", ok)
    c.struct_values += [s(p.get("title"))] + [s(f.get("key")) for f in pf] + [s(f.get("value")) for f in pf]
    for t in ptables:
        c.struct_values += [s(x) for x in lst(t.get("header"))] + [s(x) for r in lst(t.get("rows")) for x in lst(r)]


def score_label(gt: dict, p: dict, rec: dict, c: Card):
    c.gt_text = "\n".join(rec["text_lines"])
    c.pred_text = "\n".join(s(x) for x in lst(p.get("lines")))
    pf = [dct(x) for x in lst(p.get("fields"))]
    strip_colon = lambda x: norm(x).rstrip(":")  # noqa: E731
    for f in gt["fields"]:
        cands = [x for x in pf if s(x.get("key")) == f["key"]]
        if not cands and f["label"]:
            cands = [x for x in pf if strip_colon(x.get("label")) == strip_colon(f["label"])]
        ok = any(eq_text(x.get("value"), f["value"]) for x in cands)
        c.field(classify(f["key"], f["value"]), f"field:{f['key']}", ok)
        c.extra["label_field_acc"].append(int(ok))
        # lenient view: the right value is inside the matched field (e.g. "Mon to Fri 7:30 AM to 8:00 PM")
        c.extra["label_field_contains"].append(int(any(norm(f["value"]) in norm(x.get("value")) for x in cands)))
    c.extra["label_kind_ok"].append(int(s(p.get("label_kind")) == gt["label_kind"]))
    c.struct_values += [s(x.get("label")) for x in pf] + [s(x.get("value")) for x in pf]


SCORERS = {"chat_screenshot": score_chat, "chart_dashboard": score_chart, "slide": score_slide,
           "whiteboard_handwriting": score_board, "receipt_invoice": score_receipt,
           "scanned_document": score_scan, "form_label_sign": score_label}


def gt_corpus(rec: dict) -> str:
    vals = list(rec["text_lines"]) + [s(v) for _, v in leaves(rec["gt"])] + [q["a"] for q in rec["qa"]]
    return "\n".join(vals)


def qa_found(rec: dict, p: dict) -> list[int]:
    strings = [s(v) for _, v in leaves(p)]
    flat = "|".join(norm(x) for x in strings)
    nums = set()
    for x in strings:
        nums.update(numbers(x))
    trends = {s(dct(x).get("trend")) for x in lst(p.get("series"))}
    out = []
    for q in rec["qa"]:
        a, how = q["a"], q["match"]
        if how == "number":
            want = numbers(a)
            ok = bool(want) and all(n in nums for n in want)
        elif how == "date":
            da = parse_date(a)
            ok = norm(a) in flat or any(parse_date(x) and eq_date(x, a) for x in strings) if da else norm(a) in flat
        elif how == "trend":
            ok = TREND_WORDS.get(a.strip().lower(), TREND_WORDS.get(a.strip())) in trends
        else:
            ok = bool(norm(a)) and norm(a) in flat
        out.append(int(ok))
    return out


def score_image(rec: dict, row: dict) -> dict:
    p = parse_output(row.get("content", ""))
    valid = p is not None
    p = p or {}
    if rec["type"] == "chat_screenshot" and isinstance(p.get("chat_title"), str):
        p = {**p, "chat_title": re.sub(r"\s*[(（]\d+[)）]\s*$", "", p["chat_title"])}  # drawn member count
    c = Card()
    SCORERS[rec["type"]](rec["gt"], p, rec, c)
    dist, length = cer(c.pred_text, c.gt_text)
    pred_flat = norm(c.pred_text)
    loc_dist = loc_len = 0
    for line in c.gt_text.split("\n"):
        nl = norm(line)
        if nl:
            loc_dist += min(substring_distance(nl, pred_flat), len(nl))
            loc_len += len(nl)
    corpus_norm = norm(gt_corpus(rec))
    corpus_nums = set(numbers(gt_corpus(rec)))
    pred_nums, all_nums = set(), set()
    # chat file bubbles draw the file size under the name ("86 KB", mmgen/chat.py); the ground truth keeps only
    # "[文件 名称]", so a size read off the bubble is printed text, not a fabricated number
    file_sizes = rec["type"] == "chat_screenshot" and any(m.get("kind") == "file" for m in rec["gt"]["messages"])
    for path, v in leaves(p):
        all_nums.update(numbers(s(v)))
        # the receipt/label free transcription `lines` is judged by CER (it also holds printed table headers
        # and row numbers that text_lines leaves out); everything else counts
        if not (path == ".lines[]" and rec["type"] in ("receipt_invoice", "form_label_sign")):
            pred_nums.update(numbers(FILE_SIZE.sub(" ", s(v)) if file_sizes else s(v)))
    fab = sorted(n for n in pred_nums if n not in corpus_nums)
    unsup, checked = [], 0
    for v in c.struct_values:
        nv = norm(v)
        if len(nv) < 2 or nv in ("对方", "Other", "other", "我", "Me"):
            continue
        checked += 1
        if nv in corpus_norm:
            continue
        if substring_distance(nv, corpus_norm) > max(1, int(0.25 * len(nv))):
            unsup.append(v)
    gt_nums = set(numbers("\n".join(rec["text_lines"])))
    return {
        "id": rec["id"], "type": rec["type"], "hard": rec["hard"], "lang": rec["lang"], "valid_json": int(valid),
        "finish_reason": row.get("finish_reason"), "latency_s": row.get("latency_s"),
        "prompt_tokens": row.get("prompt_tokens"), "completion_tokens": row.get("completion_tokens"),
        "cer_dist": loc_dist, "cer_len": loc_len, "cer_order_dist": dist, "cer_order_len": length,
        "fields": c.fields, "extra": dict(c.extra), "qa": qa_found(rec, p),
        "fab_numbers": fab, "n_pred_numbers": len(pred_nums),
        "unsupported": unsup, "n_struct_values": checked,
        "num_recall": [len(gt_nums & all_nums), len(gt_nums)],
    }


# ---------------------------------------------------------------- aggregation
def pct(xs):
    xs = [x for x in xs if x is not None]
    return round(100.0 * sum(xs) / len(xs), 1) if xs else None


def ratio(pairs):
    num = sum(a for a, _ in pairs)
    den = sum(b for _, b in pairs)
    return round(100.0 * num / den, 1) if den else None


def quantile(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 2)


def aggregate(rows: list[dict]) -> dict:
    if not rows:
        return {}
    fields = [f for r in rows for f in r["fields"]]
    key = [f for f in fields if f[0] in KEY_CLASSES]
    out = {
        "n": len(rows),
        "valid_json": pct([r["valid_json"] for r in rows]),
        "cer": ratio([(r["cer_dist"], r["cer_len"]) for r in rows]),
        "cer_order": ratio([(r["cer_order_dist"], r["cer_order_len"]) for r in rows]),
        "key_field_em": pct([int(f[2]) for f in key]),
        "n_key_fields": len(key),
        "qa_found": pct([x for r in rows for x in r["qa"]]),
        "fab_number_rate": ratio([(len(r["fab_numbers"]), r["n_pred_numbers"]) for r in rows]),
        "unsupported_rate": ratio([(len(r["unsupported"]), r["n_struct_values"]) for r in rows]),
        "num_recall": ratio([tuple(r["num_recall"]) for r in rows]),
        "latency_p50": quantile([r["latency_s"] for r in rows], 0.5),
        "latency_p90": quantile([r["latency_s"] for r in rows], 0.9),
        "out_tokens_mean": round(statistics.mean(r["completion_tokens"] or 0 for r in rows), 1),
        "prompt_tokens_mean": round(statistics.mean(r["prompt_tokens"] or 0 for r in rows), 1),
        "truncated": sum(1 for r in rows if r["finish_reason"] == "length"),
    }
    for cls in ("name", "date", "number", "text", "flag"):
        out[f"em_{cls}"] = pct([int(f[2]) for f in fields if f[0] == cls])
    extras = defaultdict(list)
    for r in rows:
        for k, v in r["extra"].items():
            extras[k] += v
    for k, v in extras.items():
        if v and isinstance(v[0], (list, tuple)):
            out[k] = ratio(v)
        elif k == "item_f1":
            out[k] = round(100.0 * statistics.mean(v), 1)
        else:
            out[k] = pct(v)
    return out


def oracle(rec: dict) -> dict:
    """The ground truth written in the prompt's output format (scorer self-check: must score perfectly)."""
    g, t = rec["gt"], rec["type"]
    if t == "chat_screenshot":
        return {"chat_title": g["chat_title"], "is_group": g["is_group"],
                "messages": [{k: m[k] for k in ("sender", "is_self", "time", "text", "kind")} for m in g["messages"]]}
    if t == "chart_dashboard":
        series = [{"name": sr["name"], "trend": g.get("trend", {}).get(sr["name"], "none"),
                   "points": [{"category": cat, "value": lab} for cat, lab in _series_points(sr, g.get("categories", []))]}
                  for sr in g["series"]]
        return {"chart_type": g["chart_type"], "title": g["title"], "x_label": g.get("x_label", ""),
                "y_label": g.get("y_label", ""), "unit": g.get("unit", ""), "kpis": g.get("kpis", []), "series": series}
    if t == "slide":
        return {k: g[k] for k in ("title", "subtitle", "bullets", "kpis", "footer", "page")}
    if t == "whiteboard_handwriting":
        return {"surface": g["surface"], "lines": g["lines"]}
    if t == "receipt_invoice":
        out = {k: s(g.get(k, "")) for k in ("doc_kind", "merchant", "buyer", "date", "date_text", "time", "doc_no",
                                            "currency", "subtotal", "discount", "tax", "total", "payment_method",
                                            "total_in_words")}
        out["items"] = [{k: s(it[k]) for k in ("name", "qty", "unit", "unit_price", "amount")} for it in g["items"]]
        out["lines"] = rec["text_lines"]
        return out
    if t == "scanned_document":
        return {"title": g["title"], "fields": g["fields"],
                "blocks": [{"type": b["type"], "text": b.get("text", ""), "header": b.get("header", []), "rows": b.get("rows", [])}
                           for b in g["blocks"]]}
    return {"label_kind": g["label_kind"], "fields": g["fields"], "lines": rec["text_lines"]}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt-root", required=True, help="eval/multimodal")
    ap.add_argument("--run", action="append", default=[], help="name=path.jsonl (repeatable)")
    ap.add_argument("--split", default="test")
    ap.add_argument("--self-check", action="store_true", help="score the ground truth itself (all splits)")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    root = Path(args.gt_root)
    manifest = json.loads((root / "manifest.json").read_text())
    recs = {}
    for it in manifest["items"]:
        if it["split"] == args.split or args.self_check:
            recs[it["id"]] = json.loads((root / it["gt"]).read_text())
    if args.self_check:
        per = [score_image(r, {"content": json.dumps(oracle(r), ensure_ascii=False)}) for r in recs.values()]
        bad = [(r["id"], r["cer_dist"], [f for f in r["fields"] if not f[2]], r["fab_numbers"], r["unsupported"],
                r["qa"], r["num_recall"]) for r in per
               if r["cer_dist"] or r["cer_order_dist"] or not all(f[2] for f in r["fields"]) or r["fab_numbers"] or r["unsupported"]
               or not all(r["qa"]) or r["num_recall"][0] != r["num_recall"][1]]
        for b in bad:
            print("SELF-CHECK MISMATCH", json.dumps(b, ensure_ascii=False))
        print(f"self-check: {len(per) - len(bad)}/{len(per)} images score perfectly")
        return
    result = {"split": args.split, "runs": {}}
    for spec in args.run:
        name, path = spec.split("=", 1)
        rows = {}
        for line in Path(path).read_text().splitlines():
            row = json.loads(line)
            if row["id"] in recs and row.get("status") == 200:
                rows[row["id"]] = row
        missing = sorted(set(recs) - set(rows))
        per = [score_image(recs[i], rows[i]) for i in sorted(rows)]
        by_type = defaultdict(list)
        by_tag = defaultdict(list)
        for r in per:
            by_type[r["type"]].append(r)
            for t in r["hard"]:
                by_tag[t].append(r)
        overall = aggregate(per)
        type_aggs = {t: aggregate(v) for t, v in sorted(by_type.items())}
        # macro over types for the headline quality numbers, so each type weighs the same
        for k in ("cer", "cer_order", "key_field_em", "qa_found", "fab_number_rate", "unsupported_rate"):
            vals = [a[k] for a in type_aggs.values() if a.get(k) is not None]
            overall[f"{k}_macro"] = round(statistics.mean(vals), 1) if vals else None
        result["runs"][name] = {"path": path, "missing": missing, "overall": overall, "by_type": type_aggs,
                                "by_hard_tag": {t: aggregate(v) for t, v in sorted(by_tag.items())},
                                "by_lang": {l: aggregate([r for r in per if r["lang"] == l]) for l in ("zh", "en", "mixed")},
                                "images": per}
        o = overall
        print(f"{name:<28} n={o['n']} json={o['valid_json']} CER={o['cer_macro']} keyEM={o['key_field_em_macro']} "
              f"QA={o['qa_found_macro']} fabNum={o['fab_number_rate_macro']} unsup={o['unsupported_rate_macro']} "
              f"p50={o['latency_p50']} p90={o['latency_p90']} tok={o['out_tokens_mean']} missing={len(missing)}")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
