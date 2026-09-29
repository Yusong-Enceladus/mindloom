"""Shared text and feature builders for System One (the fast scorer).

A CHOICE row becomes k+2 (query, option) pairs: one per retrieved event card,
plus NEW and NONE.  Each pair is scored by the cross-encoder (yes/no logit);
a small linear head adds the retrieval features the live organizer already has
(score, similarity, time, same source, shared people, rank, size).  The option
scores go through one softmax with a temperature: that is the "Choice".

The same builders run at training time and at serving time, so the text the
model sees live is byte-identical to what it was trained on.
"""
import json
import math

PREFIX = ("<|im_start|>system\nJudge whether the Document meets the requirements based on "
          "the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\"."
          "<|im_end|>\n<|im_start|>user\n")
SUFFIX = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"

INST_CHOICE = "判断这条新素材是不是这件事情的一部分（同一件正在进行的事）。"
INST_PERSON = "判断这两个称呼指的是不是同一个人。"
INST_EVENT = "判断这两个事件是不是同一件事、应该合并。"

NEW_DOC = "一件还没出现过的新事情：上面列出的正在进行的事情都不是它。"
NONE_DOC = "不是任何一件事：闲聊、噪声、广告通知或与工作事项无关的内容。"

Q_CHARS = 160
SNIP_CHARS = 60
MAX_PEOPLE = 5
KINDS = ["text", "dictation", "document", "image"]


def cut(s, n):
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[:n] + "…"


def query_text(q):
    people = "、".join((q.get("people") or [])[:MAX_PEOPLE]) or "无"
    seg = ""
    if q.get("n_segments", 1) > 1:
        seg = f"（第{q.get('segment_index', 0) + 1}段，共{q['n_segments']}段）"
    return (f"时间：{q.get('when', '')}　来源：{q.get('source_app', '')}　类型：{q.get('kind', '')}{seg}\n"
            f"提到的人：{people}\n内容：{cut(q.get('text'), Q_CHARS)}")


def card_text(card):
    people = "、".join((card.get("people") or [])[:MAX_PEOPLE]) or "无"
    head = (f"共{card.get('n_items', 0)}条，{card.get('first_seen', '')} 至 {card.get('last_seen', '')}"
            f"（{card.get('last_seen_ago', '')}）；来源：{'、'.join((card.get('sources') or [])[:3])}；人：{people}")
    lines = [head]
    snips = card.get("snippets") or []
    if len(snips) > 2:
        snips = [snips[0], snips[-1]]  # first and latest
    for s in snips:
        lines.append(f"- {s.get('when', '')} {s.get('source_app', '')}：{cut(s.get('text'), SNIP_CHARS)}")
    return "\n".join(lines)


def pair_text(inst, query, doc):
    return f"{PREFIX}<Instruct>: {inst}\n<Query>: {query}\n<Document>: {doc}{SUFFIX}"


def choice_pairs(row):
    """Return (keys, texts) for a CHOICE row: candidates in retrieval order, then NEW, NONE."""
    q = query_text(row["query"])
    keys, texts = [], []
    for o in row["options"]:
        if "card" in o:
            doc = card_text(o["card"])
        elif o["key"] == "NEW":
            doc = NEW_DOC
        else:
            doc = NONE_DOC
        keys.append(o["key"])
        texts.append(pair_text(INST_CHOICE, q, doc))
    return keys, texts


# ---- features for the linear head -------------------------------------------------
# One vector per option; blocks are type-specific so one weight vector serves all.
FEAT_NAMES = (
    ["c_bias", "c_score", "c_sim", "c_time", "c_same_src", "c_shared", "c_log_n", "c_inv_rank",
     "c_top1", "c_gap_top"]
    + ["n_bias", "n_top_score", "n_top_sim", "n_pool_empty", "n_ncand"]
    + ["z_bias", "z_top_score", "z_top_sim", "z_pool_empty", "z_qlen", "z_people"]
    + [f"z_kind_{k}" for k in KINDS]
)
D = len(FEAT_NAMES)
IDX = {n: i for i, n in enumerate(FEAT_NAMES)}


def choice_features(row):
    opts = row["options"]
    cands = [o for o in opts if "card" in o]
    top_score = max([o["retrieval"]["score"] for o in cands], default=0.0)
    top_sim = max([o["retrieval"]["similarity"] for o in cands], default=0.0)
    q = row["query"]
    feats = []
    rank = 0
    for o in opts:
        f = [0.0] * D
        if "card" in o:
            r = o["retrieval"]
            f[IDX["c_bias"]] = 1.0
            f[IDX["c_score"]] = r["score"]
            f[IDX["c_sim"]] = r["similarity"]
            f[IDX["c_time"]] = r["time"]
            f[IDX["c_same_src"]] = 1.0 if r.get("same_source") else 0.0
            f[IDX["c_shared"]] = min(r.get("shared_persons", 0), 3) / 3.0
            f[IDX["c_log_n"]] = math.log1p(o["card"].get("n_items", 0)) / 5.0
            f[IDX["c_inv_rank"]] = 1.0 / (rank + 1)
            f[IDX["c_top1"]] = 1.0 if rank == 0 else 0.0
            f[IDX["c_gap_top"]] = r["score"] - top_score
            rank += 1
        elif o["key"] == "NEW":
            f[IDX["n_bias"]] = 1.0
            f[IDX["n_top_score"]] = top_score
            f[IDX["n_top_sim"]] = top_sim
            f[IDX["n_pool_empty"]] = 1.0 if not cands else 0.0
            f[IDX["n_ncand"]] = len(cands) / 8.0
        else:
            f[IDX["z_bias"]] = 1.0
            f[IDX["z_top_score"]] = top_score
            f[IDX["z_top_sim"]] = top_sim
            f[IDX["z_pool_empty"]] = 1.0 if not cands else 0.0
            f[IDX["z_qlen"]] = math.log1p(len(q.get("text") or "")) / 7.0
            f[IDX["z_people"]] = min(len(q.get("people") or []), 4) / 4.0
            k = q.get("kind")
            if k in KINDS:
                f[IDX[f"z_kind_{k}"]] = 1.0
        feats.append(f)
    return feats


def gold_index(row):
    keys = [o["key"] for o in row["options"]]
    return keys.index(row["label"])


# ---- pair tasks (person merge, event merge) ----------------------------------------
def merge_pair_text(row, task):
    """Split the dataset's own prompt into the [甲] part (query) and the [乙] part (document)."""
    p = row["prompt"]
    head, rest = p.split("\n[乙]", 1)
    a = head[head.index("[甲]"):]
    b = "[乙]" + rest.rsplit("\n", 1)[0]
    inst = INST_PERSON if task == "person" else INST_EVENT
    return pair_text(inst, a, b)


def load_jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]
