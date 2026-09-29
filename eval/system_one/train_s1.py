"""Fine-tune Qwen3-Reranker as System One: listwise Choice over k candidates + NEW + NONE,
plus pointwise person-merge and event-merge heads, in one model.

score_i = a * ce_i + w . f_i        (ce_i = logit(yes) - logit(no) of the cross-encoder)
loss    = listwise CE over options  (proper scoring rule)
        + 0.5 * pointwise BCE on ce_i (each option judged on its own)
        + pointwise BCE on the merge pairs

Only the top N transformer layers train (fp32 master weights, bf16 autocast); the rest stay
frozen bf16.  A per-process memory cap turns an overrun into a Python OOM, not a node crash.

Writes: <out>/model (HF format, bf16), <out>/head.json, <out>/scores_{val,test}.jsonl,
<out>/progress.json.
"""
import argparse
import json
import math
import os
import random
import sys
import time

import torch
import torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import (D, FEAT_NAMES, choice_features, choice_pairs, gold_index, load_jsonl,
                       merge_pair_text)

ap = argparse.ArgumentParser()
ap.add_argument("--base", required=True)
ap.add_argument("--data", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--train-layers", type=int, default=6)
ap.add_argument("--max-minutes", type=float, default=65)
ap.add_argument("--neg", type=int, default=4, help="negatives per CHOICE row at train time")
ap.add_argument("--epochs", type=float, default=1.0)
ap.add_argument("--lr", type=float, default=2e-5)
ap.add_argument("--head-lr", type=float, default=5e-3)
ap.add_argument("--accum", type=int, default=4)
ap.add_argument("--max-len", type=int, default=768)
ap.add_argument("--mem-gb", type=float, default=0.0, help="cap for this process; 0 = auto")
ap.add_argument("--limit", type=int, default=0, help="debug: only this many train rows")
ap.add_argument("--no-merge", action="store_true")
ap.add_argument("--eval-only", action="store_true")
ap.add_argument("--dump", action="store_true", help="also score val/test with HF (slow; vLLM path preferred)")
args = ap.parse_args()

os.makedirs(args.out, exist_ok=True)
PROG = os.path.join(args.out, "progress.json")


def progress(**kw):
    kw["time"] = time.strftime("%H:%M:%S")
    with open(PROG, "w") as f:
        json.dump(kw, f)


def avail_gb():
    for l in open("/proc/meminfo"):
        if l.startswith("MemAvailable"):
            return int(l.split()[1]) / 1e6
    return 0.0


dev = torch.device("cuda")
total = torch.cuda.get_device_properties(0).total_memory / 1e9
cap = args.mem_gb or min(25.0, max(2.5, avail_gb() - 1.5))
torch.cuda.set_per_process_memory_fraction(min(1.0, cap / total))
print(f"memory: available {avail_gb():.1f} GB, cap {cap:.1f} GB of {total:.0f}", flush=True)

tok = AutoTokenizer.from_pretrained(args.base)
tok.padding_side = "left"
YES = tok.convert_tokens_to_ids("yes")
NO = tok.convert_tokens_to_ids("no")

model = AutoModelForCausalLM.from_pretrained(args.base, torch_dtype=torch.bfloat16)
model.to(dev)
layers = model.model.layers
n_layers = len(layers)
for p in model.parameters():
    p.requires_grad_(False)
train_from = n_layers - args.train_layers
trainable = []
for i in range(train_from, n_layers):
    layers[i].float()
    for p in layers[i].parameters():
        p.requires_grad_(True)
        trainable.append(p)
model.model.norm.float()
for p in model.model.norm.parameters():
    p.requires_grad_(True)
    trainable.append(p)
model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
model.config.use_cache = False
# yes/no rows of the (tied, frozen) output embedding
W_yn = model.lm_head.weight[[YES, NO]].detach().float()  # (2, H)

head_w = torch.zeros(D, device=dev, requires_grad=True)
head_a = torch.ones(1, device=dev, requires_grad=True)
print(f"layers {n_layers}, training top {args.train_layers}; trainable {sum(p.numel() for p in trainable)/1e6:.0f}M",
      flush=True)


def ce_logits(texts, grad):
    enc = tok(texts, padding=True, truncation=True, max_length=args.max_len, return_tensors="pt").to(dev)
    with torch.autocast("cuda", dtype=torch.bfloat16), torch.set_grad_enabled(grad):
        pos = (enc.attention_mask.cumsum(-1) - 1).clamp(min=0)
        h = model.model(input_ids=enc.input_ids, attention_mask=enc.attention_mask,
                        position_ids=pos).last_hidden_state[:, -1]
    lg = h.float() @ W_yn.T
    return lg[:, 0] - lg[:, 1]


# ---- data ---------------------------------------------------------------------------
d = args.data
choice_train = load_jsonl(f"{d}/choice_train.jsonl")
choice_val = load_jsonl(f"{d}/choice_val.jsonl")
choice_test = load_jsonl(f"{d}/choice_test.jsonl")
merge_train, merge_val = [], []
if not args.no_merge:
    for task, name in (("person", "person_merge"), ("event", "event_merge")):
        for r in load_jsonl(f"{d}/{name}_train.jsonl"):
            merge_train.append((task, merge_pair_text(r, task), 1.0 if r["label"] == "same" else 0.0))
        for r in load_jsonl(f"{d}/{name}_val.jsonl"):
            merge_val.append((task, r, merge_pair_text(r, task), 1.0 if r["label"] == "same" else 0.0))
if args.limit:
    random.seed(0)
    choice_train = random.sample(choice_train, args.limit)
    merge_train = random.sample(merge_train, min(len(merge_train), args.limit))

# ---- train --------------------------------------------------------------------------
def make_steps(seed):
    rng = random.Random(seed)
    steps = [("choice", r) for r in choice_train]
    m = merge_train[:]
    rng.shuffle(m)
    steps += [("merge", m[i:i + 8]) for i in range(0, len(m), 8)]
    rng.shuffle(steps)
    return steps


def step_loss(kind, x):
    if kind == "choice":
        keys, texts = choice_pairs(x)
        fe = choice_features(x)
        g0 = gold_index(x)
        # subsample: gold + NEW + NONE + top-2 negatives + random others (listwise over the subset)
        cand = [i for i, k in enumerate(keys) if k not in ("NEW", "NONE") and i != g0]
        keep_neg = cand[:2] + random.sample(cand[2:], min(len(cand[2:]), max(0, args.neg - 2)))
        sel = sorted(set([g0] + keep_neg + [i for i, k in enumerate(keys) if k in ("NEW", "NONE")]))
        keys = [keys[i] for i in sel]
        texts = [texts[i] for i in sel]
        feats = torch.tensor([fe[i] for i in sel], device=dev)
        ce = ce_logits(texts, True)
        s = head_a * ce + feats @ head_w
        g = sel.index(g0)
        l_list = F.cross_entropy(s[None], torch.tensor([g], device=dev))
        y = torch.zeros(len(keys), device=dev)
        y[g] = 1.0
        l_pt = F.binary_cross_entropy_with_logits(ce, y)
        return l_list + 0.5 * l_pt, l_list.item()
    texts = [t for _, t, _ in x]
    y = torch.tensor([lab for _, _, lab in x], device=dev)
    ce = ce_logits(texts, True)
    return F.binary_cross_entropy_with_logits(ce, y), None


if not args.eval_only:
    opt = torch.optim.AdamW([
        {"params": trainable, "lr": args.lr, "weight_decay": 0.01},
        {"params": [head_w, head_a], "lr": args.head_lr, "weight_decay": 0.0},
    ])
    steps = []
    ep = 0
    while len(steps) < int(args.epochs * len(make_steps(0))):
        steps += make_steps(ep)
        ep += 1
    steps = steps[:int(args.epochs * len(make_steps(0)))]
    n_opt = math.ceil(len(steps) / args.accum)
    warm = max(10, n_opt // 20)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda i: min(1.0, (i + 1) / warm) * max(0.05, 1 - i / n_opt))
    model.train()
    t0 = time.time()
    run_l, run_n = 0.0, 0
    for i, (kind, x) in enumerate(steps):
        if time.time() - t0 > args.max_minutes * 60:
            print(f"time guard: stopping at step {i}", flush=True)
            break
        loss, l_list = step_loss(kind, x)
        (loss / args.accum).backward()
        if l_list is not None:
            run_l += l_list
            run_n += 1
        if (i + 1) % args.accum == 0 or i + 1 == len(steps):
            torch.nn.utils.clip_grad_norm_(trainable, 1.0)
            opt.step()
            sched.step()
            opt.zero_grad(set_to_none=True)
        if (i + 1) % 50 == 0:
            el = time.time() - t0
            eta = el / (i + 1) * (len(steps) - i - 1)
            msg = dict(stage="train", step=i + 1, of=len(steps), listwise=round(run_l / max(run_n, 1), 4),
                       a=round(head_a.item(), 3), elapsed_min=round(el / 60, 1), eta_min=round(eta / 60, 1),
                       peak_gb=round(torch.cuda.max_memory_allocated() / 1e9, 2), avail_gb=round(avail_gb(), 1))
            print(json.dumps(msg), flush=True)
            progress(**msg)
            run_l, run_n = 0.0, 0

    # save: cast the trained layers back to bf16, HF format
    model.gradient_checkpointing_disable()
    for i in range(train_from, n_layers):
        layers[i].to(torch.bfloat16)
    model.model.norm.to(torch.bfloat16)
    model.config.use_cache = True
    model.save_pretrained(f"{args.out}/model", safe_serialization=True)
    tok.save_pretrained(f"{args.out}/model")
    with open(f"{args.out}/head.json", "w") as f:
        json.dump({"feat_names": FEAT_NAMES, "w": head_w.detach().cpu().tolist(), "a": head_a.item()}, f,
                  indent=1)
else:
    hj = json.load(open(f"{args.out}/head.json"))
    head_w.data = torch.tensor(hj["w"], device=dev)
    head_a.data = torch.tensor([hj["a"]], device=dev)

# ---- score val / test (raw; calibration happens on CPU afterwards) --------------------
model.eval()


@torch.no_grad()
def dump(rows, path, stage):
    with open(path, "w") as f:
        for j, r in enumerate(rows):
            keys, texts = choice_pairs(r)
            ce = []
            for k in range(0, len(texts), 12):
                ce += ce_logits(texts[k:k + 12], False).tolist()
            f.write(json.dumps({"id": r["id"], "stream": r["stream"], "keys": keys, "ce": ce,
                                "gold": gold_index(r), "label": r["label"],
                                "label_reason": r["label_reason"], "tags": r.get("tags", [])},
                               ensure_ascii=False) + "\n")
            if j % 100 == 0:
                progress(stage=stage, row=j, of=len(rows))


@torch.no_grad()
def dump_merge(rows, path):
    with open(path, "w") as f:
        for k in range(0, len(rows), 16):
            chunk = rows[k:k + 16]
            ce = ce_logits([t for _, _, t, _ in chunk], False).tolist()
            for (task, r, _, y), c in zip(chunk, ce):
                f.write(json.dumps({"task": task, "stream": r["stream"], "kind": r.get("kind"), "y": y, "ce": c,
                                    "truth_a": r.get("truth_a"), "purity_a": r.get("purity_a"),
                                    "purity_b": r.get("purity_b")}, ensure_ascii=False) + "\n")


if not args.dump:
    progress(stage="done")
    sys.exit(0)
dump(choice_val, f"{args.out}/scores_val.jsonl", "score_val")
if merge_val:
    dump_merge(merge_val, f"{args.out}/scores_merge_val.jsonl")
dump(choice_test, f"{args.out}/scores_test.jsonl", "score_test")
progress(stage="done")
print("done", flush=True)
