#!/usr/bin/env python3
"""Deterministic validator (and repair) for matter-group output. The JSON schema is checked separately.

validate(output, context) -> list of error strings (empty = valid), each starting with its [category].
repair(output, context) -> a copy with the repairable errors fixed (REPAIRABLE); what cannot be repaired is
left for the retry. A second failure that is only [missing] is applied partly (the matters it left out are
judged again next pass): SALVAGEABLE.

context = {"judge": ["E5", ...],                          # the matters of this call, each placed exactly once
           "ropes": {"R2": {"parent": "R1" | "", "movable": bool}},   # existing ropes shown (never rejected ones)
           "titles": {"R2": "normalized title"},          # existing ropes' titles
           "raw_titles": {"R2": "title"}, "rejected_raw": ["title"],   # as shown (for same_rope)
           "rejected": ["normalized title", ...],         # ropes the user rejected: never proposed again
           "samples": {"E5": "I12"},                      # each judged matter's sample item
           "rope_matters": {"R2": ["E3", ...]}}           # matters already on each existing rope

Rules:
  [placement]  a placement names a matter that is not in `judge`, or places one twice.
  [missing]    a judged matter has no placement (retried once; afterwards the rest is applied).
  [rope]       a placement or a parent names a rope that is neither shown nor new.
  [new_rope]   two new ropes share a key.
Repairable (REPAIRABLE; not retried):
  [duplicate]  a new rope names a shown rope (-> its matters go to that rope) or an earlier new rope (-> merged
               into it): the same title once normalized, or two shared content words (same_rope). A later call of a
               pass otherwise re-proposes a rope of the first call under another name ("TG-2夹爪项目" beside
               "TG-2夹爪调试").
  [rejected]   a new rope names a rope the user rejected, by the same test (-> dissolved: its matters stay
               unplaced; a rejected proposal is never proposed again).
  [cycle]      a parent chain loops (-> the new rope that closes it becomes top-level).
  [thin]       a new rope holds fewer than two matters, directly or through its child ropes (-> dissolved: its
               matters and child ropes go to its parent).
  [evidence]   a new rope's evidence is not the sample of one of its matters (-> filtered; the first member's
               sample when nothing is left).
  [nest]       a nest entry moves a rope that is not movable (the user confirmed it, or it already has a parent),
               names an unknown parent, or would make a loop (-> dropped).

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import copy
import json
import re
import sys

REPAIRABLE = frozenset({"duplicate", "rejected", "cycle", "thin", "evidence", "nest"})
SALVAGEABLE = frozenset({"missing"})


_CJK = re.compile(r"[\u3400-\u9fff]+")
_LATIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.+-]*[A-Za-z0-9]|[A-Za-z]{2,}")
_STOP = frozenset("项目 相关 事务 工作 管理 事情 日常 个人 生活 其他 问题 准备 推进 处理 安排".split())


def title_terms(title: str) -> set[str]:
    """Content words of a rope title: CJK bigrams (minus a few generic ones) and Latin / alphanumeric tokens."""
    out: set[str] = set()
    for run in _CJK.findall(title or ""):
        out |= {run[i:i + 2] for i in range(len(run) - 1)} - _STOP
    out |= {t.lower() for t in _LATIN.findall(title or "")}
    return out


def same_rope(a: str, b: str) -> bool:
    """Two rope titles name the same rope: equal once normalized, sharing two content words ("A800集群维护" /
    "Spark集群维护", "栖木求职与入职" / "栖木产品总监入职"), or sharing a product / code name of three or more
    letters and digits ("TG-2硬件调试" / "TG-2夹爪项目"). "SkillKnit论文" / "GripDiff论文" share only 论文: two ropes."""
    if norm_title(a) == norm_title(b):
        return True
    shared = title_terms(a) & title_terms(b)
    return len(shared) >= 2 or any(len(t) >= 3 and t.isascii() for t in shared)


def norm_title(title: str) -> str:
    return re.sub(r"[\s·•.,，。、:：\-—_/（）()「」“”\"']", "", title or "").lower()


def categories(errors: list[str]) -> set[str]:
    return {e[1:e.index("]")] for e in errors if e.startswith("[") and "]" in e}


def _members(out: dict, context: dict) -> dict[str, list[str]]:
    """Direct matter placements per rope reference (existing id or new key)."""
    m: dict[str, list[str]] = {}
    for p in out.get("placements") or []:
        if p.get("rope"):
            m.setdefault(p["rope"], []).append(p["matter"])
    return m


def _parents(out: dict, context: dict) -> dict[str, str]:
    par = {r: (v.get("parent") or "") for r, v in (context.get("ropes") or {}).items()}
    for n in out.get("nest") or []:
        par[n["rope"]] = n["parent"]
    for r in out.get("new_ropes") or []:
        par[r["key"]] = r.get("parent") or ""
    return par


def _loops(par: dict[str, str], start: str) -> bool:
    seen, cur = set(), start
    while cur:
        if cur in seen:
            return True
        seen.add(cur)
        cur = par.get(cur, "")
    return False


def _size(key: str, out: dict, context: dict, par: dict[str, str]) -> int:
    """Matters on a rope, directly or through the ropes inside it (existing matters of shown ropes count)."""
    direct = _members(out, context)
    total, stack, seen = 0, [key], set()
    while stack:
        r = stack.pop()
        if r in seen:
            continue
        seen.add(r)
        total += len(direct.get(r, [])) + len((context.get("rope_matters") or {}).get(r, []))
        stack.extend(c for c, p in par.items() if p == r)
    return total


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    judge = list(context.get("judge") or [])
    ropes = context.get("ropes") or {}
    titles = {v: k for k, v in (context.get("titles") or {}).items()}
    rejected = set(context.get("rejected") or [])
    samples = context.get("samples") or {}
    new = output.get("new_ropes") or []
    keys = [r["key"] for r in new]
    if len(set(keys)) != len(keys):
        errors.append("[new_rope] two new ropes share a key")
    known = set(ropes) | set(keys)
    placed: dict[str, int] = {}
    for p in output.get("placements") or []:
        m = p.get("matter")
        if m not in judge:
            errors.append(f"[placement] {m} is not one of the matters to place")
        placed[m] = placed.get(m, 0) + 1
        if p.get("rope") and p["rope"] not in known:
            errors.append(f"[rope] {m} is placed on {p['rope']}, which is neither shown nor new")
    for m, n in placed.items():
        if n > 1:
            errors.append(f"[placement] {m} is placed {n} times; a matter hangs from at most one rope")
    missing = [m for m in judge if m not in placed]
    if missing:
        errors.append(f"[missing] no placement for {missing}; place every matter once (rope \"\" when none fits)")
    par = _parents(output, context)
    seen_titles: dict[str, str] = {}
    raw = context.get("raw_titles") or {}
    rejected_raw = context.get("rejected_raw") or []
    earlier: list[tuple[str, str]] = []
    for r in new:
        t = norm_title(r.get("title", ""))
        if r.get("parent") and r["parent"] not in known:
            errors.append(f"[rope] new rope {r['key']} sits in {r['parent']}, which is neither shown nor new")
        like = next((rid for rid, title in raw.items() if same_rope(title, r.get("title", ""))), None) or titles.get(t)
        mate = next((k for k, title in earlier if same_rope(title, r.get("title", ""))), None) or seen_titles.get(t)
        if t in rejected or any(same_rope(x, r.get("title", "")) for x in rejected_raw):
            errors.append(f"[rejected] 「{r['title']}」 was rejected by the user; never propose it again")
        elif like:
            errors.append(f"[duplicate] 「{r['title']}」 is rope {like} already; place the matters there")
        elif mate:
            errors.append(f"[duplicate] new ropes {mate} and {r['key']} name the same rope")
        seen_titles.setdefault(t, r["key"])
        earlier.append((r["key"], r.get("title", "")))
        if _loops(par, r["key"]):
            errors.append(f"[cycle] new rope {r['key']} is inside itself")
        elif _size(r["key"], output, context, par) < 2:
            errors.append(f"[thin] new rope {r['key']} holds fewer than two matters")
        own = {samples.get(m) for m in _members(output, context).get(r["key"], [])}
        own |= {samples.get(m) for c, p in par.items() if p == r["key"] for m in _members(output, context).get(c, [])}
        bad = [e for e in r.get("evidence") or [] if e not in own]
        if bad:
            errors.append(f"[evidence] new rope {r['key']} cites {bad}, which are not samples of its matters")
    for n in output.get("nest") or []:
        info = ropes.get(n.get("rope"))
        if not info or not info.get("movable"):
            errors.append(f"[nest] {n.get('rope')} cannot be moved (unknown, confirmed by the user, or inside a rope)")
        elif n.get("parent") not in known or n.get("parent") == n.get("rope"):
            errors.append(f"[nest] {n.get('rope')} into unknown {n.get('parent')}")
        elif _loops(par, n["rope"]):
            errors.append(f"[nest] {n['rope']} into {n['parent']} makes a loop")
    return errors


def repair(output: dict, context: dict) -> dict:
    out = copy.deepcopy(output)
    ropes = context.get("ropes") or {}
    titles = {v: k for k, v in (context.get("titles") or {}).items()}
    rejected = set(context.get("rejected") or [])
    samples = context.get("samples") or {}

    def redirect(old: str, new: str) -> None:
        for p in out.get("placements") or []:
            if p.get("rope") == old:
                p["rope"] = new
        for r in out.get("new_ropes") or []:
            if r.get("parent") == old:
                r["parent"] = new
        for n in out.get("nest") or []:
            if n.get("parent") == old:
                n["parent"] = new

    # duplicates and rejected titles
    raw = context.get("raw_titles") or {}
    rejected_raw = context.get("rejected_raw") or []
    kept, seen = [], []
    for r in out.get("new_ropes") or []:
        t = norm_title(r.get("title", ""))
        title = r.get("title", "")
        if t in rejected or any(same_rope(x, title) for x in rejected_raw):
            redirect(r["key"], "")
            continue
        like = next((rid for rid, x in raw.items() if same_rope(x, title)), None) or titles.get(t)
        if like:
            redirect(r["key"], like)
            continue
        mate = next((k for k, x in seen if same_rope(x, title)), None)
        if mate:
            redirect(r["key"], mate)
            continue
        seen.append((r["key"], title))
        kept.append(r)
    out["new_ropes"] = kept
    # nest entries that are not allowed
    out["nest"] = [n for n in out.get("nest") or []
                   if (ropes.get(n.get("rope")) or {}).get("movable") and n.get("parent") != n.get("rope")
                   and (n.get("parent") in ropes or n.get("parent") in {r["key"] for r in kept})]
    # cycles: the new rope that closes a loop becomes top-level; a nest that makes one is dropped
    for r in out["new_ropes"]:
        if _loops(_parents(out, context), r["key"]):
            r["parent"] = ""
    out["nest"] = [n for n in out["nest"] if not _loops(_parents(out, context), n["rope"])]
    # thin ropes dissolve into their parent (repeat: dissolving one can thin another)
    changed = True
    while changed:
        changed = False
        par = _parents(out, context)
        for r in list(out["new_ropes"]):
            if _size(r["key"], out, context, par) < 2:
                redirect(r["key"], r.get("parent") or "")
                out["new_ropes"].remove(r)
                changed = True
                break
    # evidence: samples of the rope's own matters
    par = _parents(out, context)
    members = _members(out, context)
    for r in out["new_ropes"]:
        own_matters = members.get(r["key"], []) + [m for c, p in par.items() if p == r["key"] for m in members.get(c, [])]
        own = [samples[m] for m in own_matters if samples.get(m)]
        ev = [e for e in r.get("evidence") or [] if e in own]
        r["evidence"] = ev or own[:1]
    for p in out.get("placements") or []:
        p["type"] = re.sub(r"\s+", "", p.get("type") or "")[:6] or "其他"
    return out


def salvage(candidate: dict | None, errors: list[str], context: dict) -> dict | None:
    """What the organizer applies when the output failed validation: the repaired candidate when every error was
    repairable or only a missing placement, and the repair leaves at most missing placements; None otherwise."""
    if candidate is None or not categories(errors) <= REPAIRABLE | SALVAGEABLE:
        return None
    fixed = repair(candidate, context)
    return fixed if categories(validate(fixed, context)) <= SALVAGEABLE else None


def main() -> int:
    out = json.loads(open(sys.argv[1], encoding="utf-8").read())
    ctx = json.loads(open(sys.argv[2], encoding="utf-8").read()) if len(sys.argv) > 2 else {}
    errs = validate(out, ctx)
    print(json.dumps(errs, ensure_ascii=False, indent=1))
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
