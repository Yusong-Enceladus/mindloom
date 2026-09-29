"""System One candidate A: Laya (convaiinnovations/laya, multilingual checkpoint, Apache-2.0).

One Laya `choice` question per decision unit.  The state is the new item plus every retrieved
event card (labelled [A]..[H] with its retrieval score); the options are the card letters, NEW
and NONE, so all k+2 answers share one softmax in one forward pass.  Person-merge and
event-merge are Laya `noul` questions over the pair prompt.

Fine-tuning follows Laya's own recipe (notebooks/laya_finetune_typed_decisions_2xT4_kaggle.ipynb):
RLCD = REINFORCE with a group-mean baseline on Gaussian-perturbed logits, rewarded by a strictly
proper scoring rule (log + 0.75 spherical, laya.common.proper_reward), plus soft cross-entropy
guidance; AdamW encoder 2.5e-5 / head 1e-4, cosine, sigma 0.4 -> 0.1, group 4, clip 1.0.
Local changes, all for the shared GB10: bf16 autocast instead of fp16 + GradScaler, the 197M-
parameter token-embedding matrix frozen (memory), one process-wide memory cap, a time guard, and
candidate cards shuffled in training (the retrieval order puts the answer at A ~70% of the time;
the retrieval score stays in the card text, so the prior is still visible).

Temperatures are NOT fitted here: laya_calibrate.py fits one per (question type, option count
bucket) on VALIDATION and writes them into the checkpoint's rl_agent_config.json.

Usage (on the DGX Spark, laya-venv):
  python laya_s1.py --base models/laya/multilingual --data data --out runs/laya_zs --zero-shot
  python laya_s1.py --base models/laya/multilingual --data data --out runs/laya_ft --epochs 2
"""
import argparse
import json
import math
import os
import random
import sys
import time

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import card_text, cut, load_jsonl  # noqa: E402

LETTERS = "ABCDEFGH"
MAX_LEN = 2560
HEAD_MAX_LEN = 448
Q_CHARS = 400
INS_CHOICE = "这条新素材属于下面哪一件正在进行的事情？"
NEW_DESC = "一件上面没有列出的新事情"
NONE_DESC = "不是正在进行的事：闲聊、噪声、广告通知或与工作无关"
INS_PERSON = "[甲] 和 [乙] 这两个称呼指的是同一个人吗？"
INS_EVENT = "[甲] 和 [乙] 这两个事件是同一件事、应该合并吗？"


# ---- decision -> Laya (state, question) ----------------------------------------------
def query_block(q):
    people = "、".join((q.get("people") or [])[:5]) or "无"
    seg = ""
    if q.get("n_segments", 1) > 1:
        seg = f"（第{q.get('segment_index', 0) + 1}段，共{q['n_segments']}段）"
    return (f"时间：{q.get('when', '')}　来源：{q.get('source_app', '')}　类型：{q.get('kind', '')}{seg}\n"
            f"提到的人：{people}\n内容：{cut(q.get('text'), Q_CHARS)}")


def short_card(card):
    people = "、".join((card.get("people") or [])[:2]) or "无人名"
    snips = card.get("snippets") or []
    last = cut(snips[-1].get("text"), 18) if snips else ""
    return f"{people}；{last}"


def choice_state_question(row, order=None):
    """Return (state, question, keys) where keys[i] is the dataset option key behind Laya option i.

    `order` lists indices into row['options'] of the candidate cards in the order shown (default:
    retrieval order).  NEW and NONE are always the last two options."""
    opts = row["options"]
    cand_idx = [i for i, o in enumerate(opts) if "card" in o]
    if order is None:
        order = cand_idx
    lines = ["【新素材】", query_block(row["query"]), "", "【正在进行的事情（候选）】"]
    crit, keys = {}, []
    for j, i in enumerate(order):
        o = opts[i]
        L = LETTERS[j]
        lines.append(f"[{L}] 相关度{o['retrieval']['score']:.2f}；" + card_text(o["card"]))
        crit[L] = short_card(o["card"])
        keys.append(o["key"])
    if not order:
        lines.append("（还没有正在进行的事情）")
    crit["NEW"] = NEW_DESC
    crit["NONE"] = NONE_DESC
    keys += ["NEW", "NONE"]
    q = {"type": "choice", "instructions": INS_CHOICE, "criteria": crit}
    return "\n".join(lines), q, keys


def merge_state_question(row, task):
    p = row["prompt"].rsplit("\n", 1)[0]  # drop the "answer same/different" line
    return p, {"type": "noul", "instructions": INS_PERSON if task == "person" else INS_EVENT}


def to_internal(q):
    if q["type"] == "choice":
        return {"t": "choice", "ins": q["instructions"], "crit": q["criteria"]}
    return {"t": "noul", "ins": q["instructions"], "crit": q.get("criteria") or {}}


# ---- sequences -----------------------------------------------------------------------
def make_item(tok, state, q, target, max_len, head_max_len):
    from laya.common import QTYPES, build_sequence, render_options
    iq = to_internal(q)
    seq, markers = build_sequence(tok, state, iq, max_len, head_max_len)
    k = len(render_options(iq))
    if len(markers) != k:
        return None
    return {"ids": seq, "markers": markers, "qtype": QTYPES[iq["t"]], "target": target,
            "label": int(np.argmax(target))}


def collate(items, pad_id):
    n, L = len(items), max(len(it["ids"]) for it in items)
    kmax = max(len(it["markers"]) for it in items)
    ids = torch.full((n, L), pad_id, dtype=torch.long)
    att = torch.zeros((n, L), dtype=torch.long)
    mpos = torch.zeros((n, kmax), dtype=torch.long)
    mmask = torch.zeros((n, kmax), dtype=torch.bool)
    target = torch.zeros((n, kmax), dtype=torch.float32)
    for i, it in enumerate(items):
        ids[i, :len(it["ids"])] = torch.tensor(it["ids"])
        att[i, :len(it["ids"])] = 1
        k = len(it["markers"])
        mpos[i, :k] = torch.tensor(it["markers"])
        mmask[i, :k] = True
        target[i, :len(it["target"])] = torch.tensor(it["target"], dtype=torch.float32)
    return {"input_ids": ids, "attention_mask": att, "marker_pos": mpos, "marker_mask": mmask,
            "target": target, "qtype": torch.tensor([it["qtype"] for it in items])}


def choice_item(tok, row, shuffle_rng=None, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN):
    order = None
    if shuffle_rng is not None:
        order = [i for i, o in enumerate(row["options"]) if "card" in o]
        shuffle_rng.shuffle(order)
    state, q, keys = choice_state_question(row, order)
    t = [0.0] * len(keys)
    t[keys.index(row["label"])] = 1.0
    it = make_item(tok, state, q, t, max_len, head_max_len)
    if it is not None:
        it["keys"] = keys
    return it


def merge_item(tok, row, task, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN):
    state, q = merge_state_question(row, task)
    y = 1.0 if row["label"] == "same" else 0.0
    return make_item(tok, state, q, [1.0 - y, y], max_len, head_max_len)


# ---- main ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--zero-shot", action="store_true")
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--max-minutes", type=float, default=60)
    ap.add_argument("--mem-gb", type=float, default=4.5)
    ap.add_argument("--pairs-per-epoch", type=int, default=3000)
    ap.add_argument("--choice-bs", type=int, default=2)
    ap.add_argument("--pair-bs", type=int, default=8)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--splits", default="val,test")
    ap.add_argument("--no-dump", action="store_true")
    ap.add_argument("--train-top", type=int, default=0, help="train only the top N encoder layers (0 = all)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    prog_path = os.path.join(args.out, "progress.json")

    def progress(**kw):
        kw["time"] = time.strftime("%H:%M:%S")
        with open(prog_path, "w") as f:
            json.dump(kw, f)
        print(json.dumps(kw), flush=True)

    dev = torch.device("cuda")
    # create the CUDA context before the checkpoint lands in host memory: on the unified-memory GB10 the
    # context cannot be created once the CPU copy has eaten the remaining headroom (cudaErrorMemoryAllocation)
    torch.zeros(1, device=dev)
    total = torch.cuda.get_device_properties(0).total_memory / 1e9
    torch.cuda.set_per_process_memory_fraction(min(1.0, args.mem_gb / total))

    from laya.agent import Agent
    from laya.common import proper_reward
    agent = Agent(args.base, device="cuda")
    model, tok, cfg = agent.model, agent.tok, dict(agent.cfg)
    try:  # hand the CPU staging copy of the checkpoint back to the OS (unified memory)
        import ctypes
        import gc
        gc.collect()
        ctypes.CDLL("libc.so.6").malloc_trim(0)
    except OSError:
        pass
    pad = tok.pad_token_id
    d = args.data

    if not args.zero_shot:
        rng = random.Random(20260928)
        choice_train = load_jsonl(f"{d}/choice_train.jsonl")
        pt = [("person", r) for r in load_jsonl(f"{d}/person_merge_train.jsonl")]
        et = [("event", r) for r in load_jsonl(f"{d}/event_merge_train.jsonl")]
        if args.limit:
            choice_train = choice_train[:args.limit]
            pt, et = pt[:args.limit], et[:args.limit]

        def epoch_steps(ep):
            r = random.Random(1000 + ep)
            cs = [choice_item(tok, row, r) for row in choice_train]
            cs = [c for c in cs if c is not None]
            r.shuffle(cs)
            half = args.pairs_per_epoch // 2
            ps = r.sample(pt, min(half, len(pt))) + r.sample(et, min(half, len(et)))
            ps = [merge_item(tok, row, task) for task, row in ps]
            ps = [p for p in ps if p is not None]
            r.shuffle(ps)
            steps = [cs[i:i + args.choice_bs] for i in range(0, len(cs), args.choice_bs)]
            steps += [ps[i:i + args.pair_bs] for i in range(0, len(ps), args.pair_bs)]
            r.shuffle(steps)
            return steps

        # Laya recipe hyper-parameters
        GROUP, LR_ENC, LR_HEAD, S0, S1 = 4, 2.5e-5, 1.0e-4, 0.4, 0.1
        n_layers = len(model.encoder.layers)
        lo = n_layers - args.train_top if args.train_top else 0
        for n, p in model.named_parameters():
            frozen = n.startswith("encoder.embeddings.")
            if args.train_top and n.startswith("encoder.") and not n.startswith("encoder.final_norm"):
                parts = n.split(".")
                frozen = frozen or not (parts[1] == "layers" and int(parts[2]) >= lo)
            if frozen:
                p.requires_grad_(False)
                p.data = p.data.to(torch.bfloat16)  # frozen weights stay 16-bit (shared GB10 memory)
        model.encoder.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.head_checkpointing = True
        model.train()
        enc_p = [p for n, p in model.named_parameters() if p.requires_grad and n.startswith("encoder.")]
        head_p = [p for n, p in model.named_parameters() if p.requires_grad and not n.startswith("encoder.")]
        print(f"trainable encoder {sum(p.numel() for p in enc_p)/1e6:.0f}M head {sum(p.numel() for p in head_p)/1e6:.0f}M",
              flush=True)
        opt = torch.optim.AdamW([{"params": enc_p, "lr": LR_ENC}, {"params": head_p, "lr": LR_HEAD}],
                                weight_decay=0.01)
        steps0 = epoch_steps(0)
        n_ep = max(1, math.ceil(args.epochs))
        total_micro = int(len(steps0) * args.epochs)
        total_upd = max(1, total_micro // args.accum)
        sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=total_upd, eta_min=1e-6)
        progress(stage="train_start", micro_steps=total_micro, updates=total_upd,
                 n_choice=len(choice_train), steps_per_epoch=len(steps0))
        t0 = time.time()
        done, stop = 0, False
        run = {"loss": 0.0, "ce": 0.0, "r": 0.0, "n": 0}
        opt.zero_grad(set_to_none=True)
        for ep in range(n_ep):
            steps = steps0 if ep == 0 else epoch_steps(ep)
            for chunk in steps:
                if done >= total_micro:
                    break
                if time.time() - t0 > args.max_minutes * 60:
                    print(f"time guard: stopping at micro-step {done}", flush=True)
                    stop = True
                    break
                prog = done / max(1, total_micro - 1)
                sigma = S0 + (S1 - S0) * prog
                b = collate(chunk, pad)
                mask = b["marker_mask"].to(dev)
                qt = b["qtype"].to(dev)
                with torch.autocast("cuda", dtype=torch.bfloat16):
                    logits, act = model(b["input_ids"].to(dev), b["attention_mask"].to(dev),
                                        b["marker_pos"].to(dev), mask, qt)
                logits = logits.float()
                k = mask.sum(-1, keepdim=True).float()
                target = b["target"].to(dev)
                eps = torch.randn((GROUP,) + logits.shape, device=dev) * sigma * mask
                eps = (eps - eps.sum(-1, keepdim=True) / k) * mask
                z = logits.detach().unsqueeze(0) + eps
                qd = torch.softmax(z.masked_fill(~mask, -1e4), -1)
                with torch.no_grad():
                    r = proper_reward(qd, target.unsqueeze(0), qt, mask, w_sph=0.75, w_rps=1.0)
                    adv = r - r.mean(0, keepdim=True)
                    adv = adv / (adv.std() + 1e-6)
                logp = -(((z - logits.unsqueeze(0)) ** 2) * mask).sum(-1) / (2 * sigma ** 2)
                loss_rl = -(adv * logp).mean()
                loss_ce = -(target * torch.log_softmax(logits.masked_fill(~mask, -1e4), -1)).sum(-1).mean()
                loss = (loss_rl + loss_ce) / args.accum + 0.0 * act.sum()
                loss.backward()
                done += 1
                run["loss"] += float(loss.detach()) * args.accum
                run["ce"] += float(loss_ce)
                run["r"] += float(r.mean())
                run["n"] += 1
                if done % args.accum == 0 or done == total_micro:
                    torch.nn.utils.clip_grad_norm_(enc_p + head_p, 1.0)
                    opt.step()
                    sched.step()
                    opt.zero_grad(set_to_none=True)
                if done % 50 == 0:
                    el = time.time() - t0
                    progress(stage="train", micro=done, of=total_micro, epoch=ep + 1,
                             loss=round(run["loss"] / run["n"], 4), ce=round(run["ce"] / run["n"], 4),
                             reward=round(run["r"] / run["n"], 4), sigma=round(sigma, 3),
                             lr=sched.get_last_lr()[0], elapsed_min=round(el / 60, 1),
                             eta_min=round(el / done * (total_micro - done) / 60, 1),
                             peak_gb=round(torch.cuda.max_memory_allocated() / 1e9, 2))
                    run = {"loss": 0.0, "ce": 0.0, "r": 0.0, "n": 0}
            if stop or done >= total_micro:
                break
        # save in Laya's checkpoint layout (loadable by laya.Agent / laya-serve)
        from safetensors.torch import save_file
        model.eval()
        model.head_checkpointing = False
        mdir = os.path.join(args.out, "model")
        os.makedirs(mdir, exist_ok=True)
        save_file({k: v.detach().cpu().half().contiguous() for k, v in model.state_dict().items()},
                  os.path.join(mdir, "model.safetensors"))
        model.encoder.config.save_pretrained(os.path.join(mdir, "encoder"))
        tok.save_pretrained(os.path.join(mdir, "tokenizer"))
        cfg.update({"max_len": MAX_LEN, "head_max_len": HEAD_MAX_LEN, "fine_tuned": True,
                    "model_name": "laya-bestasr-system-one",
                    "temperature": [1.0, 1.0, 1.0], "temperature_by_options": {},
                    "fine_tune": {"micro_steps": done, "minutes": round((time.time() - t0) / 60, 1),
                                  "recipe": "RLCD (laya notebook) + CE, bf16, embeddings frozen",
                                  "train": "choice_train + person/event_merge_train"}})
        json.dump(cfg, open(os.path.join(mdir, "rl_agent_config.json"), "w"), indent=2, ensure_ascii=False)
        progress(stage="saved", micro=done)

    if args.no_dump:
        return
    # ---- dump raw logits (temperature 1) for calibration --------------------------------
    model.eval()

    @torch.no_grad()
    def logits_of(items, bs):
        out = []
        for i in range(0, len(items), bs):
            b = collate(items[i:i + bs], pad)
            with torch.autocast("cuda", dtype=torch.bfloat16):
                lg, _ = model(b["input_ids"].to(dev), b["attention_mask"].to(dev), b["marker_pos"].to(dev),
                              b["marker_mask"].to(dev), b["qtype"].to(dev))
            lg = lg.float().cpu().numpy()
            for j, it in enumerate(items[i:i + bs]):
                out.append(lg[j, :len(it["markers"])].tolist())
        return out

    for split in args.splits.split(","):
        rows = load_jsonl(f"{d}/choice_{split}.jsonl")
        items = [choice_item(tok, r) for r in rows]
        bad = sum(it is None for it in items)
        keep = [(r, it) for r, it in zip(rows, items) if it is not None]
        lg = logits_of([it for _, it in keep], 4)
        with open(os.path.join(args.out, f"scores_{split}.jsonl"), "w") as f:
            for (r, it), z in zip(keep, lg):
                f.write(json.dumps({"id": r["id"], "stream": r["stream"], "keys": it["keys"], "logits": z,
                                    "gold": it["keys"].index(r["label"]), "label": r["label"],
                                    "label_reason": r["label_reason"], "tags": r.get("tags", []),
                                    "n_tokens": len(it["ids"])}, ensure_ascii=False) + "\n")
        progress(stage=f"dumped_{split}", n=len(keep), skipped=bad)
    mrows = []
    for task, name in (("person", "person_merge"), ("event", "event_merge")):
        for r in load_jsonl(f"{d}/{name}_val.jsonl"):
            mrows.append((task, r))
    items = [merge_item(tok, r, t) for t, r in mrows]
    keep = [(t, r, it) for (t, r), it in zip(mrows, items) if it is not None]
    lg = logits_of([it for _, _, it in keep], 16)
    with open(os.path.join(args.out, "scores_merge_val.jsonl"), "w") as f:
        for (t, r, it), z in zip(keep, lg):
            f.write(json.dumps({"task": t, "stream": r["stream"], "kind": r.get("kind"),
                                "y": 1.0 if r["label"] == "same" else 0.0, "ce": z[1] - z[0], "logits": z,
                                "truth_a": r.get("truth_a"), "purity_a": r.get("purity_a"),
                                "purity_b": r.get("purity_b")}, ensure_ascii=False) + "\n")
    progress(stage="done", merge_val=len(keep))


if __name__ == "__main__":
    main()
