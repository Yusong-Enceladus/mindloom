#!/usr/bin/env python3
"""Organizer throughput on a real model: serial (ORGANIZER_WORKERS=1) vs pipeline mode, same stream.

The stream is invented here from a seed (a retired couple's household and hobby matters; no scenario's
wording): dictations, pasted chats, long notes that mention two matters and meeting transcripts that
cover two or three, all queued at once (a burst / an import), then the organizer drains its queue.
It reports items/min, model calls per skill and the resulting event count for each worker setting.
Nothing is scored; this measures speed only.

  python3 eval/tools/throughput.py --llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8013/v1 \
      --items 36 --workers 1 4 --out ../out/throughput
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "spark"))

from organizer.api import build_organizer  # noqa: E402
from organizer.clients import OpenAIChatClient, OpenAIEmbedClient  # noqa: E402
from organizer.config import Settings  # noqa: E402

TZ = timezone(timedelta(hours=8))
BASE = datetime(2031, 4, 7, 8, 30, tzinfo=TZ)

# Invented matters: (short name, facts the lines draw from)
MATTERS = [
    ("老年大学书法班", ["书法班周三下午换到二楼教室", "要交一幅隶书作业", "老师让准备毛边纸两刀"]),
    ("阳台漏水", ["阳台地漏又往楼下渗水", "物业说周五派人来看", "楼下邻居拍了天花板的照片"]),
    ("钓鱼协会春季比赛", ["比赛定在水库东岸", "报名费八十元", "要提前一天去打窝"]),
    ("老伴的眼科复查", ["复查约在下周二上午", "要空腹验血", "带上次的检查单"]),
    ("小区合唱排练", ["合唱团要排两首新歌", "指挥说周六加练", "服装统一白衬衫"]),
    ("旧冰箱换新", ["旧冰箱压缩机坏了", "看中一台两门的", "商场说以旧换新补贴三百"]),
    ("外孙的钢琴考级", ["考级报了四级", "考场在少年宫", "要提前半小时到"]),
    ("社区菜地", ["菜地分到第十二块", "想种黄瓜和豆角", "水管要自己接"]),
    ("养老金认证", ["今年的认证要在手机上刷脸", "截止到月底", "不会弄可以去社保所"]),
    ("去青岛旅游", ["五月想去青岛住五天", "高铁票要提前十五天买", "住在栈桥附近"]),
    ("老房子出租", ["老房子租客月底退租", "中介说挂四千二", "要先把热水器修好"]),
    ("太极拳表演", ["重阳节有太极拳表演", "队形还没定", "要统一买练功服"]),
]
PEOPLE = ["老周", "刘阿姨", "小孙", "王师傅", "陈老师", "赵姐"]
FILLER = ["大家都到了吗，我这边声音有点小。", "好的，那今天就先这样。", "我先喝口水。"]


def _item(i: int, minutes: int, kind: str, app: str, text: str) -> dict:
    started = BASE + timedelta(minutes=minutes)
    return {"item_id": str(uuid.UUID(int=random.Random(i).getrandbits(128), version=4)).upper(), "revision": 1,
            "kind": kind, "source_app": {"bundle_id": None, "name": app}, "started_at": started.isoformat(),
            "ended_at": (started + timedelta(minutes=2)).isoformat(), "text": text, "sha256": f"{i:064x}"}


def invented_stream(n: int, seed: int = 7) -> list[dict]:
    rng = random.Random(seed)
    items, minute = [], 0
    for i in range(n):
        minute += rng.randint(20, 240)
        r = rng.random()
        if r < 0.12:  # a meeting transcript over two or three matters
            picked = rng.sample(MATTERS, rng.choice((2, 3)))
            turns, t = [], 3
            a, b = rng.sample(PEOPLE, 2)
            turns.append(f"{a}({t // 60:02d}:{t % 60:02d}):\n{rng.choice(FILLER)}")
            for name, facts in picked:
                for fact in rng.sample(facts, 2):
                    t += rng.randint(20, 90)
                    speaker = rng.choice((a, b))
                    turns.append(f"{speaker}({t // 60:02d}:{t % 60:02d}):\n说到{name}，{fact}。")
            t += 30
            turns.append(f"{a}({t // 60:02d}:{t % 60:02d}):\n{FILLER[1]}")
            items.append(_item(i, minute, "meeting_online", "腾讯会议", "\n\n".join(turns) + "\n"))
        elif r < 0.24:  # a long note about two matters
            (n1, f1), (n2, f2) = rng.sample(MATTERS, 2)
            text = f"记一下：{n1}，{'，'.join(rng.sample(f1, 2))}。另外{n2}那边，{'，'.join(rng.sample(f2, 2))}，别忘了。"
            items.append(_item(i, minute, "text", "备忘录", text))
        elif r < 0.42:  # a pasted chat
            name, facts = rng.choice(MATTERS)
            who = rng.choice(PEOPLE)
            text = f"{who}：{name}的事，{rng.choice(facts)}\n我：好的，我记下了\n{who}：{rng.choice(facts)}"
            items.append(_item(i, minute, "text", "微信", text))
        else:  # a dictation
            name, facts = rng.choice(MATTERS)
            text = f"{name}，{rng.choice(facts)}，{rng.choice(('回头再问问', '先这样', '周末再说', '记得提醒我'))}。"
            items.append(_item(i, minute, "dictation", "语音备忘", text))
    return items


def run(args, workers: int, items: list[dict], out: Path) -> dict:
    data = out / f"w{workers}"
    data.mkdir(parents=True, exist_ok=False)
    settings = Settings()
    settings.data_dir = data
    settings.require_token = False
    settings.start_worker = False
    settings.clock = "replay"
    settings.workers = workers
    settings.pipeline_lag = args.pipeline_lag
    chat = OpenAIChatClient(args.llm_url, "auto", 300)
    embed = OpenAIEmbedClient(args.embed_url, "auto") if args.embed_url else None
    org = build_organizer(settings, chat=chat, embedder=embed)
    rows = [dict(it) for it in items]
    org.ingest(rows, [None] * len(rows))
    t0 = time.time()
    steps = 0
    while org.step():
        steps += 1
        if steps % 20 == 0:
            done = org.store.scalar("SELECT COUNT(*) FROM jobs WHERE state='done'")
            print(f"[w{workers}] {time.time() - t0:.0f}s, jobs done {done}", flush=True)
    wall = time.time() - t0
    if org.pipeline is not None:
        org.pipeline.shutdown()
    calls = {r["job_type"]: r["n"] for r in org.store.all("SELECT job_type, COUNT(*) AS n FROM runs GROUP BY job_type")}
    result = {"workers": workers, "pipeline_lag": args.pipeline_lag if workers > 1 else None, "items": len(items),
              "wall_s": round(wall, 1), "items_per_min": round(len(items) / wall * 60, 2), "model_calls": calls,
              "events": org.store.count_events(),
              "split_items": org.store.scalar("SELECT COUNT(DISTINCT parent_id) FROM item_segments WHERE active=1")}
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--llm-url", required=True)
    ap.add_argument("--embed-url", default="")
    ap.add_argument("--items", type=int, default=36)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--workers", type=int, nargs="+", default=[1, 4])
    ap.add_argument("--pipeline-lag", type=int, default=2)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    items = invented_stream(args.items, args.seed)
    kinds: dict[str, int] = {}
    for it in items:
        kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
    results = [run(args, w, items, out) for w in args.workers]
    summary = {"stream": {"items": len(items), "seed": args.seed, "kinds": kinds}, "llm_url": args.llm_url,
               "embed_url": args.embed_url, "runs": results,
               "date": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")}
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
