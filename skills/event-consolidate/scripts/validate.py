#!/usr/bin/env python3
"""Semantic validator for event-consolidate output (the JSON schema is checked separately).

validate(output, context) -> list of error strings (empty = valid)
context = {"targets": ["E3", ...],          # events the small one may be merged with this time
           "can_unfile": bool,             # whether not_matter may be chosen this time
           "items": {"I1": text, ...},     # the small event's items as shown to the model
           "target_text": {"E3": text}}    # title + anchor + status line + sample of each target

Rules (a failed rule triggers the harness's single retry; a second failure is never applied, so the
small event simply stays as it is):
  0. candidate is the matter the small event is most like ("" if none); relation says how they relate:
     same (the candidate's own goal/deliverable/arrangement), part (a prerequisite, dependency, component or
     spin-off with its own deliverable: an interface, a review ticket, a contract, a demo, an interview, a
     report), related (same person, team, product, project, place or time only) or none.
     Only `same` may merge, and only with the candidate.
  1. merge: target is one of `targets`, small_is_matter is true, and the merge is grounded in a shared
     content word (a CJK bigram that is not a function word, or a Latin/alphanumeric token) between the
     small event and the target's title, anchor, status line or sample: either the quote itself shares one,
     or small_object shares one that also occurs in the small event's items. A bare "好的，收到" cannot merge.
  2. own_matter / not_matter: target is "".
  3. not_matter: only when can_unfile, and small_is_matter must be false (and vice versa: a non-matter
     is not merged).
  4. quote.text is copied verbatim (ignoring whitespace and punctuation) from the item it names.

CLI: python validate.py output.json [context.json]
"""

from __future__ import annotations

import json
import re
import sys

_NOT_WORD = re.compile(r"[^0-9A-Za-z\u3400-\u9fff]+")
_CJK = re.compile(r"[㐀-鿿]+")
_LATIN = re.compile(r"[A-Za-z][A-Za-z0-9_.+-]*[A-Za-z0-9]|[A-Za-z]{2,}")
# Bigrams too common to show that two texts are about the same thing.
STOP_BIGRAMS = frozenset("""
我们 你们 他们 她们 咱们 一下 一个 一些 这个 那个 这些 那些 这样 那样 这边 那边 这里 那里 今天 明天 昨天 后天 现在 已经 可以
没有 什么 怎么 时候 还是 就是 不是 如果 因为 所以 然后 但是 知道 需要 一起 下周 本周 上周 这周 周末 事情 东西 大家 自己 看看
好的 收到 时间 感觉 觉得 应该 还有 的话 一直 其实 之前 之后 以后 里面 问题 老师 同学 一定 可能 不过 而且 或者 已经 马上 刚才
下午 上午 晚上 中午 早上 今晚 麻烦 谢谢 辛苦 帮我 帮忙 我的 你的 他的 了吗 了吧 的时 候再 一次 两个 三个 几个 多少 这次 上次
下次 目前 还没 没问 回复 确认 一下吧 发给 发我 给我 告诉 通知 安排 进展 情况 结果 继续 开始 完成 准备 处理 看一 一看 月份
""".split())


def _squash(text: str) -> str:
    """Letters, digits and CJK only: a quote copied with other spacing or punctuation still counts as verbatim."""
    return _NOT_WORD.sub("", text or "").lower()


def terms(text: str) -> set[str]:
    """Content words: CJK bigrams minus function words, and Latin/alphanumeric tokens (lowercased)."""
    out: set[str] = set()
    for run in _CJK.findall(text or ""):
        for i in range(len(run) - 1):
            bg = run[i:i + 2]
            if bg not in STOP_BIGRAMS:
                out.add(bg)
    for tok in _LATIN.findall(text or ""):
        out.add(tok.lower())
    return out


def validate(output: dict, context: dict) -> list[str]:
    errors: list[str] = []
    verdict = output.get("verdict")
    target = output.get("target", "")
    is_matter = output.get("small_is_matter")
    targets = list(context.get("targets") or [])
    can_unfile = bool(context.get("can_unfile"))
    items = context.get("items") or {}
    quote = output.get("quote") or {}
    q_id, q_text = quote.get("item_id"), str(quote.get("text") or "")
    if verdict not in ("merge", "own_matter", "not_matter"):
        return [f"unknown verdict {verdict!r}"]
    candidate, relation = output.get("candidate", ""), output.get("relation")
    if relation == "same" and not candidate:
        errors.append("[relation] relation=same needs the candidate it is the same matter as")
    if verdict == "merge":
        if target not in targets:
            errors.append(f"[target] {target!r} cannot be merged with the small event this time (only {targets});"
                          " if none of those is the same matter, choose own_matter")
        if relation != "same":
            errors.append(f"[relation] relation={relation}: only the same matter is merged; choose own_matter"
                          + (" or not_matter" if can_unfile else ""))
        elif target != candidate:
            errors.append(f"[relation] merge target {target} must be the candidate {candidate}")
        if is_matter is False:
            errors.append("[consistency] small_is_matter=false: a non-matter is never merged; choose not_matter"
                          if can_unfile else "[consistency] small_is_matter=false: choose own_matter")
    elif target:
        errors.append(f"[target] verdict={verdict} must use target \"\"")
    if verdict == "not_matter":
        if not can_unfile:
            errors.append("[unfile] can_unfile is false: choose own_matter instead of not_matter")
        if is_matter is not False:
            errors.append("[consistency] not_matter means small_is_matter=false")
    if verdict == "own_matter" and is_matter is False and can_unfile:
        errors.append("[consistency] small_is_matter=false and can_unfile: choose not_matter")
    if q_id not in items:
        errors.append(f"[quote] quote.item_id {q_id!r} is not an item of the small event")
    elif not _squash(q_text) or _squash(q_text) not in _squash(items[q_id]):
        errors.append(f"[quote] quote.text is not copied verbatim from {q_id}")
    if verdict == "merge" and target in targets and not any(e.startswith("[quote]") for e in errors):
        t_terms = terms((context.get("target_text") or {}).get(target, ""))
        grounded = terms(" ".join(str(v) for v in items.values())) & t_terms
        if not (terms(q_text) & t_terms or terms(str(output.get("small_object") or "")) & grounded):
            errors.append(f"[quote_not_about_target] neither the quote nor small_object shares a word with {target}'s"
                          " title, object or sample that the small event's items also use: quote the sentence that"
                          " names the same activity/project/thing, or keep it apart (own_matter)")
    return errors


def main() -> int:
    output = json.load(open(sys.argv[1], encoding="utf-8"))
    context = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(output, context)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
