#!/usr/bin/env python3
"""Score the image-read skill (formerly screenshot-read) on a scenario's rendered chat screenshots against image.messages.

Runs the organizer's real skill harness (SKILL.md prompt, schema-guided output, validate.py, one
retry) with a pluggable backend, so different vision models get exactly the same treatment:

  --backend openai     OpenAI-compatible /v1/chat/completions (vLLM, llama.cpp server)
  --backend step3-raw  llama.cpp /completion with an empty <think></think> prefilled (Step3-VL always
                       thinks through the chat endpoint); the JSON schema goes in "json_schema".

Per message (aligned by order): sender (right-hand bubbles must read "我"), is_self, time (the label
actually drawn above the message, '' when none), text (exact and difflib similarity, whitespace removed).
--rescore FILE recomputes the metrics of a saved result without calling a model. Synthetic scenarios only.

  python3 eval/tools/screenshot_eval.py --scenario eval/scenarios/dev-week-v1/scenario.json \
      --scenario eval/scenarios/holdout-week-v1/scenario.json --backend openai --url http://127.0.0.1:8000/v1 \
      --repeat 2 --out eval/runs/shots-qwen-nvfp4.json
"""

from __future__ import annotations

import argparse
import base64
import difflib
import json
import re
import statistics
import sys
import time
from pathlib import Path

import httpx

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(HERE))

import render_screenshots  # noqa: E402
from organizer.clients import ChatResult, OpenAIChatClient  # noqa: E402
from organizer.image_read import read_image  # noqa: E402
from organizer.skills import Harness, SkillRegistry  # noqa: E402
from organizer.store import Store  # noqa: E402


class Step3RawClient:
    """llama.cpp /completion with a hand-rendered ChatML prompt and an empty think block."""

    def __init__(self, base_url: str, timeout_s: float = 600.0):
        self._http = httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout_s, trust_env=False)
        props = self._http.get("/props").json()
        self.marker = props["media_marker"]
        self.model_id = "step3-vl-10b (llama.cpp /completion, empty think)"

    def complete(self, messages, schema, schema_name, max_tokens) -> ChatResult:
        parts, media = [], []
        for m in messages:
            content = m["content"]
            if isinstance(content, list):
                text = ""
                for c in content:
                    if c["type"] == "image_url":
                        media.append(c["image_url"]["url"].split(",", 1)[1])
                        text += self.marker
                    else:
                        text += c["text"]
                content = text
            parts.append(f"<|im_start|>{m['role']}\n{content}<|im_end|>\n")
        prompt = "".join(parts) + "<|im_start|>assistant\n<think>\n\n</think>\n"
        body = {"prompt": {"prompt_string": prompt, "multimodal_data": media}, "n_predict": max_tokens,
                "temperature": 0, "cache_prompt": False}
        if schema is not None:
            body["json_schema"] = schema
        r = self._http.post("/completion", json=body)
        r.raise_for_status()
        data = r.json()
        t = data.get("timings") or {}
        return ChatResult(text=data.get("content") or "", model=self.model_id,
                          prompt_tokens=t.get("prompt_n"), completion_tokens=t.get("predicted_n"))


def _norm(s: str) -> str:
    return re.sub(r"\s+", "", s or "")


def score_one(gold: dict, out: dict | None) -> dict:
    msgs = gold["messages"]
    self_name = gold.get("self_sender")
    pred = (out or {}).get("messages") or []
    shown = render_screenshots.visible_times(msgs)  # only drawn time labels can be read
    sender = is_self = time_ok = exact = 0
    sims = []
    for i, g in enumerate(msgs):
        p = pred[i] if i < len(pred) else {}
        mine = g["sender"] == self_name
        want = "我" if mine else g["sender"]
        sender += _norm(p.get("sender")) == _norm(want)
        is_self += bool(p) and bool(p.get("is_self")) == mine
        time_ok += bool(p) and _norm(p.get("time")) == _norm(shown[i])
        sim = difflib.SequenceMatcher(None, _norm(g["text"]), _norm(p.get("text"))).ratio() if p else 0.0
        sims.append(sim)
        exact += sim == 1.0
    return {"gold_messages": len(msgs), "pred_messages": len(pred), "kind": (out or {}).get("kind"),
            "sender_ok": sender, "is_self_ok": is_self, "time_ok": time_ok, "text_exact": exact,
            "text_sim_mean": round(sum(sims) / len(sims), 4)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", action="append", required=True)
    ap.add_argument("--backend", choices=["openai", "step3-raw"])
    ap.add_argument("--url")
    ap.add_argument("--model", default="auto")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--bare", action="store_true",
                    help="ablation: bare task prompt, no SKILL.md/schema/validate.py/retry (run_eval.BareHarness)")
    ap.add_argument("--rescore", help="saved result JSON to rescore (no model calls)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    if args.rescore:
        saved = json.loads(Path(args.rescore).read_text(encoding="utf-8"))
        gold = {}
        for spath in args.scenario:
            scenario = json.loads(Path(spath).read_text(encoding="utf-8"))
            gold.update({(scenario["scenario_id"], it.get("ref")): it["image"] for it in scenario["items"]
                         if it["kind"] == "image"})
        rows = [{**r, **score_one(gold[(r["scenario"], r["ref"])], r["output"] if r["ok"] else None)}
                for r in saved["rows"]]
        prev = saved["summary"]
        write_summary(rows, prev["model"], prev["backend"], prev["url"], args.out)
        return 0
    if not (args.backend and args.url):
        ap.error("--backend and --url are required unless --rescore")
    client = Step3RawClient(args.url) if args.backend == "step3-raw" else OpenAIChatClient(args.url, args.model, 600)
    registry = SkillRegistry(ROOT / "skills")
    store = Store(":memory:")
    if args.bare:
        sys.path.insert(0, str(HERE.parent))
        from run_eval import BareHarness
        harness = BareHarness(registry, client, store)
    else:
        harness = Harness(registry, client, store)
    rows = []
    for spath in args.scenario:
        scenario = json.loads(Path(spath).read_text(encoding="utf-8"))
        if scenario.get("synthetic") is not True:
            raise SystemExit(f"refusing non-synthetic scenario {spath}")
        for item in scenario["items"]:
            if item["kind"] != "image":
                continue
            png = Path(render_screenshots.asset_path(spath, item)).read_bytes()
            for rep in range(args.repeat):
                t0 = time.time()
                res = read_image(harness, png, {"source_app": item["source_app"], "captured_at": item["t"]},
                                 subject=item["item_id"])
                wall = time.time() - t0
                ids = [r.run_id for r in res.runs]
                run = store.one("SELECT SUM(prompt_tokens) AS prompt_tokens, SUM(completion_tokens) AS completion_tokens"
                                f" FROM runs WHERE run_id IN ({','.join('?' * len(ids))})", ids)
                # image-read's chat extraction, in the form score_one reads (kind "chat" = typed as a chat)
                output = ({**res.output, "kind": "chat" if res.image_type == "chat_screenshot" else res.image_type,
                           "messages": res.reading["messages"]} if res.ok else None)
                row = {"scenario": scenario["scenario_id"], "ref": item.get("ref"), "repeat": rep, "ok": res.ok,
                       "attempts": res.attempts, "latency_s": round(wall, 2), **(run or {}),
                       **score_one(item["image"], output),
                       "errors": [e for r in res.runs for e in r.errors][:3], "output": output}
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "output"}, ensure_ascii=False), flush=True)
    write_summary(rows, client.model_id + (" (bare prompt)" if args.bare else ""), args.backend, args.url, args.out)
    return 0


def write_summary(rows: list[dict], model: str, backend: str, url: str, out: str) -> None:
    g = sum(r["gold_messages"] for r in rows)
    lat = [r["latency_s"] for r in rows]
    summary = {"model": model, "backend": backend, "url": url, "images": len(rows),
               "ok": sum(r["ok"] for r in rows), "ok_first_attempt": sum(1 for r in rows if r["ok"] and r["attempts"] == 1),
               "kind_chat": sum(r["kind"] == "chat" for r in rows),
               "msg_count_match": sum(r["gold_messages"] == r["pred_messages"] for r in rows),
               "gold_messages": g,
               "sender_acc": round(sum(r["sender_ok"] for r in rows) / g, 4),
               "is_self_acc": round(sum(r["is_self_ok"] for r in rows) / g, 4),
               "time_acc": round(sum(r["time_ok"] for r in rows) / g, 4),
               "text_exact_acc": round(sum(r["text_exact"] for r in rows) / g, 4),
               "text_sim_mean": round(sum(r["text_sim_mean"] * r["gold_messages"] for r in rows) / g, 4),
               "latency_median_s": round(statistics.median(lat), 2), "latency_max_s": round(max(lat), 2),
               "completion_tokens_mean": round(statistics.mean([r.get("completion_tokens") or 0 for r in rows]), 1),
               "prompt_tokens_mean": round(statistics.mean([r.get("prompt_tokens") or 0 for r in rows]), 1)}
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    sys.exit(main())
