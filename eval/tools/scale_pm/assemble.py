#!/usr/bin/env python3
"""Assemble eval/scenarios/scale-pm/scenario.json from the plan (gold) and the Spark generations (text).

  python3 assemble.py --plan plan.json --gen gen.jsonl --stats gen_stats.json --out-dir eval/scenarios/scale-pm

Writes scenario.json, renders every screenshot and scanned page to assets/<ref>.png (Pillow), writes the
image-only PDFs of scanned documents, and writes pdf_jobs.json for render_pdfs.py (text PDFs, reportlab).
Gold labels come from the plan; generated text only decides which planned repeats actually made it into the
item (a repeat or stale fact whose keys are missing from the text is dropped from fact_refs) and which named
people actually appear.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import uuid
from collections import Counter
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "eval"))
sys.path.insert(0, os.path.join(ROOT, "eval", "tools"))
sys.path.insert(0, HERE)
from score import fact_matches  # noqa: E402

BIBLE = json.load(open(os.path.join(ROOT, "eval", "scenarios", "scale-pm", "source", "bible.json"), encoding="utf-8"))
OWNER = "jiang_yuan"
NS = uuid.UUID("6f2b8c1e-5d0a-4f7e-9a3b-2c1d0e9f8a7b")
DECOYS = {"E02": ("E01", "hard"), "E05": ("E04", "hard"), "E15": ("E14", "hard"), "E12": ("E13", "hard"),
          "E11": ("E14", "easy"), "E18": ("E09", "easy")}
IMAGE_ONLY_FIRST = {"E01-f14", "E02-f2", "E03-f5", "E04-f3", "E05-f1", "E08-f4", "E15-f10", "E19-f3", "E20-f2", "E11-f5", "E19-f2b"}
PLATFORM_FILE = {"feishu_transcript": "飞书妙记", "tencent_transcript": "腾讯会议", "zoom_transcript": "Zoom"}

HOME_RUBRIC = ("本场景作者自拟的首页重要度（0-3），由 tools/scale_pm/plan.py 按检查点时刻 T、场景内事实的日期和状态机械计算，"
               "不参考任何系统的输出。3 = 本人要在 T 之后 1 天内办理/到场/答复的有日期节点，或私事里的去留/offer 答复截止在 5 天内（栖木、鹭洲、去留）；"
               "2 = 仍在进行且 7 天内有任何人的日期节点，或 T 前 24 小时内出现了新变化但没有日期节点；"
               "1 = 未结束但最近节点在 7 天之后、只是在等别人、或刚办完/刚取消（24 小时内）；团建这类轻量小事最多 1（当天或次日就办时为 2）；"
               "0 = 办完或取消超过 24 小时且无待办。只看 T 时刻已经出现的事实（计划改期以新日期为准，已完成的计划不再算节点）。"
               "最后一个检查点另附 bible 给出的首页参考顺序 reference_order。")


def item_id(key: str) -> str:
    return str(uuid.uuid5(NS, "scale-pm/" + key))


def ref_of(key: str) -> str:
    k = key.replace(":", "-").lower()
    k = re.sub(r"2026-(\d\d)-(\d\d)", r"\1\2", k)
    return k


def load_gen(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("ok"):
            out[r["key"]] = r
    return out


def hms(sec):
    return "%02d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def fragment(src_it, src_gen, rnd):
    """A 10-minute slice of a transcript export, same export format."""
    turns = src_gen["turns"]
    total = turns[-1][1] if turns else 0
    t0 = rnd.randint(0, max(0, total - 600))
    sel = [t for t in turns if t0 <= t[1] <= t0 + 600] or turns[:6]
    names = {p: s for p, s in src_it["cast_s"]}
    start = datetime.fromisoformat(src_it["content_time"])
    if src_it["fmt"] == "tencent_transcript":
        head = f"会议主题：{src_it['title']}（片段）\n会议时间：{(start + timedelta(seconds=sel[0][1])).strftime('%Y-%m-%d %H:%M')}-{(start + timedelta(seconds=sel[-1][1] + 30)).strftime('%H:%M')}\n\n"
        body = "\n".join(f"{names.get(p, p)}({hms(s)}):\n{t}\n" for p, s, t in sel)
    elif src_it["fmt"] == "feishu_transcript":
        head = f"文字记录\n{src_it['title']}（片段）\n{start.strftime('%Y年%m月%d日 %H:%M')}\n\n"
        body = "\n".join(f"{names.get(p, p)} {hms(s)}\n{t}\n" for p, s, t in sel)
    else:
        head = f"{src_it['title']}（片段）\n\n"
        body = "\n".join(f"[{(start + timedelta(seconds=s)).strftime('%H:%M:%S')}] {names.get(p, p)}: {t}" for p, s, t in sel)
    return head + body, [p for p, _, _ in sel]


YEAR_RE = re.compile(r"(?<!\d)20(?:1\d|2[0-5])([-/年.])(?=\d{1,2}[-/月.]\d{1,2})")
ID_RE = re.compile(r"(?<!\d)(\d{6})(19|20)\d{2}[01]\d[0-3]\d[0-9Xx*]{3,4}(?![\dA-Za-z])")


def scrub(s):
    """Generated text only: wrong years (the scenario is 2026) and anything shaped like a national ID number."""
    if not isinstance(s, str):
        return s
    s = YEAR_RE.sub(lambda m: "2026" + m.group(1), s)
    return ID_RE.sub(lambda m: m.group(1)[:4] + "*" * 10 + "XXXX", s)


def scrub_obj(o):
    if isinstance(o, str):
        return scrub(o)
    if isinstance(o, list):
        return [scrub_obj(x) for x in o]
    if isinstance(o, dict):
        return {k: scrub_obj(v) for k, v in o.items()}
    return o


def clean_image(spec):
    spec = scrub_obj(spec)
    if spec.get("rows"):
        spec["rows"] = [r for r in spec["rows"] if any(str(v).strip() not in ("", "—", "-", "--", "/") for v in r)]
    for k in ("title", "subtitle", "note", "body", "footer"):
        if k in spec and not isinstance(spec[k], str):
            spec[k] = str(spec[k])
    return spec


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--gen", required=True)
    ap.add_argument("--stats", default="")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--no-render", action="store_true")
    args = ap.parse_args(argv)
    plan = json.load(open(args.plan, encoding="utf-8"))
    gen = load_gen(args.gen)
    facts = {f["fact_id"]: f for f in plan["facts"]}
    by_key = {it["key"]: it for it in plan["items"]}
    first_item = {fid: f["first"] for fid, f in facts.items()}
    out_dir = args.out_dir
    assets = os.path.join(out_dir, "assets")
    os.makedirs(assets, exist_ok=True)
    rnd = random.Random(7)

    people = []
    for pid, p in [(OWNER, None)] + [(p["id"], p) for p in BIBLE["people"]]:
        if pid == OWNER:
            people.append({"person_id": OWNER, "display_name": "江予安", "is_owner": True, "role": BIBLE["protagonist"]["role"],
                           "aliases": BIBLE["protagonist"]["aliases"],
                           "voice": {"mac_person_id": str(uuid.uuid5(NS, "voice/" + OWNER)).upper(), "user_label": "我",
                                     "tts_hint": "female-30s-brisk"}})
        else:
            people.append({"person_id": pid, "display_name": p["name"], "role": f"{p['role']}（{p['org']}）", "aliases": p["aliases"], "voice": None})
    events = []
    for e in BIBLE["events"]:
        ev = {"event_id": e["id"], "kind": "main", "title": e["title"], "summary": e["anchor"]}
        if e["id"] in DECOYS:
            ev.update({"kind": "decoy", "decoy_of": DECOYS[e["id"]][0], "difficulty": DECOYS[e["id"]][1]})
        events.append(ev)

    items, missing, pdf_jobs, dropped_refs = [], [], [], Counter()
    images_to_render = []
    for it in plan["items"]:
        key = it["key"]
        g = gen.get(key)
        if it.get("copy_of"):
            src = gen.get(it["copy_of"])
            if not src:
                missing.append(key)
                continue
            g = dict(src)
            if it["copy_kind"] == "frag":
                text, spk = fragment(by_key[it["copy_of"]], src, rnd)
                g["text"] = text
                g["turns"] = [t for t in src["turns"] if t[0] in spk]
                keep = []
                for m in it["matters"]:
                    quotes = [s["quote"] for s in src.get("segments", []) if s["event_id"] == m["event"]]
                    if any(q in text for q in quotes) or any(fact_matches(facts[f]["keys"], text) for f in m["facts"]):
                        keep.append(m)
                it["matters"] = keep or it["matters"][:1]
                it["fact_refs"] = [r for r in it["fact_refs"] if any(r["fact_id"] in m["facts"] for m in it["matters"])]
                g["segments"] = [s for s in src.get("segments", []) if s["quote"] in text]
        if not g:
            missing.append(key)
            continue
        g = dict(g)
        for k in ("text", "reading"):
            if g.get(k):
                g[k] = scrub(g[k])
        if g.get("image"):
            g["image"] = clean_image(g["image"])
            if g.get("reading"):
                import gen as genmod
                g["reading"] = genmod.image_text(g["image"])
        if not {m["event"] for m in it["matters"]} & {"E14", "E15", "E16"}:
            # a stray '鹭洲' (e.g. an invented clinic name) outside the 鹭洲 matters would be an unplanned cue
            for k in ("text", "reading"):
                if g.get(k):
                    g[k] = g[k].replace("鹭洲", "鹭岛")
            if g.get("image"):
                g["image"] = json.loads(json.dumps(g["image"], ensure_ascii=False).replace("鹭洲", "鹭岛"))
        fmt = it["fmt"]
        kind = it["kind"]
        if fmt == "email" and g.get("text"):
            import gen as genmod
            g["text"] = genmod.fix_email_direction(g["text"])
        o = {"item_id": item_id(key), "ref": ref_of(key), "t": it["t"], "kind": kind, "source_app": it["app"] or "其他",
             "format": fmt}
        if it.get("mode"):
            o["input_mode"] = it["mode"]
        if it.get("content_time") and it["content_time"] != it["t"]:
            o["content_time"] = it["content_time"]
        evs = [m["event"] for m in it["matters"]]
        content = g.get("text") or g.get("reading") or ""
        # fact refs: new ones always stay (gold evidence); repeats/stale only if the text carries the keys
        refs = []
        for r in it["fact_refs"]:
            if r["role"] == "new" or fact_matches(facts[r["fact_id"]]["keys"], content):
                refs.append(r)
            else:
                dropped_refs[r["role"]] += 1
        # people
        present = {p for p, s in g.get("people_present", [])}
        if fmt.endswith("transcript"):
            present |= {p for p, _, _ in g.get("turns", [])}
        if fmt == "chat_paste":
            present |= {p for p, _ in g.get("messages", []) if p}
        if fmt == "email" and it.get("email"):
            em = it["email"]
            present |= {em["from"], *em["to"], *em["cc"]}
        persons = []
        if fmt in ("phone_ime", "mac_dictation", "claude_result", "codex_result") or OWNER in present:
            persons.append(OWNER)
        mentions = []
        for p, s in it["cast_s"] + it["named_s"]:
            if p in present and p not in persons:
                persons.append(p)
            if p in present and p != OWNER:
                mentions.append({"person_id": p, "surface": s})
        if fmt == "screenshot" and it["style"] == "chat":
            persons = [OWNER] + [p for p, s in it["cast_s"] if p != OWNER and any(m["sender"] == s for m in g["image"]["messages"])] + \
                      [p for p, s in it["named_s"] if s and s in content]
            persons = list(dict.fromkeys(persons))
        o["persons"] = persons
        o["events"] = evs
        tags = []
        if it["noise"]:
            tags += ["noise"] + (["hard_noise"] if "hard_noise" in it["tags"] else [])
        if len(evs) >= 2:
            tags.append("multi_label")
        if it.get("brainstorm"):
            tags.append("brainstorm")
        if any(m.get("oblique") for m in it["matters"]):
            tags.append("oblique_followup")
        if any(r["role"] == "stale" for r in refs):
            tags.append("stale_restatement")
        if o.get("content_time") and datetime.fromisoformat(o["t"]) - datetime.fromisoformat(o["content_time"]) > timedelta(days=1):
            tags.append("late_content")
        if fmt in ("claude_result", "codex_result"):
            tags.append("agent_result")
        if it.get("export_return"):
            tags.append("export_return")
        if it.get("copy_kind"):
            tags.append("duplicate_export" if it["copy_kind"] == "dup" else "fragment")
        if any(first_item[r["fact_id"]] == key and r["fact_id"] in IMAGE_ONLY_FIRST for r in refs):
            tags.append("image_only_first")
        if g.get("summary_corrupted"):
            tags.append("summary_wrong_owner")
        if g.get("offplan_events"):
            # the model mentioned a matter the plan did not ask for; gold stays with the plan, the tag flags it
            tags += ["unplanned_mention:" + e for e in g["offplan_events"]]
        o["tags"] = tags
        # content per kind
        if fmt == "screenshot":
            o["image"] = g["image"]
            o["reading"] = g["reading"]
            images_to_render.append((o["ref"], g["image"]))
        elif fmt == "pdf":
            text = g["text"]
            o["filename"] = it["filename"]
            o["reading"] = text
            if it.get("scanned"):
                lines = [l for l in text.splitlines() if l.strip()]
                o["image"] = {"style": "generic_doc", "title": lines[0] if lines else it["filename"], "paragraphs": lines[1:]}
                images_to_render.append((o["ref"], o["image"]))
                o["tags"].append("scanned_pdf")
            else:
                o["text"] = text
                pdf_jobs.append({"file": o["ref"] + ".pdf", "text": text})
        elif fmt.endswith("transcript"):
            d = datetime.fromisoformat(it["content_time"])
            o["filename"] = f"{it['title']}_{d.strftime('%Y%m%d')}_{PLATFORM_FILE[fmt]}{'_片段' if it.get('copy_kind') == 'frag' else ''}.txt"
            o["text"] = g["text"]
        else:
            o["text"] = g["text"]
            if kind == "dictation":
                o["duration_ms"] = max(3000, len(g["text"]) * 230)
            if kind == "document" and not o.get("filename"):
                o["filename"] = it.get("filename") or "文档.txt"
        segs = [{"event_id": s["event_id"], "quote": s["quote"], "located": s.get("located", "model")} for s in g.get("segments", [])
                if s["event_id"] in evs]
        if segs and len(evs) >= 2:
            o["matter_segments"] = segs
        if refs:
            o["fact_refs"] = refs
        if mentions:
            o["person_mentions"] = mentions
        if it.get("sensitive"):
            o["sensitive"] = it["sensitive"]
        items.append(o)

    out_facts = []
    for f in plan["facts"]:
        o = {"fact_id": f["fact_id"], "event_id": f["event_id"], "text": f["text"], "keys": f["keys"],
             "valid_from": item_id(f["first"]), "superseded_by": f["superseded_by"], "state": f["state"]}
        if f["state"] == "planned" and f.get("due"):
            o["date"] = f["due"]
        out_facts.append(o)
    scenario = {
        "$schema": "../../schema/scenario.schema.json",
        "scenario_id": "scale-pm", "version": 1, "split": "dev", "synthetic": True, "locale": "zh-CN",
        "title": BIBLE["title"],
        "description": ("虚构：澄湾集团会员与增长产品负责人江予安 2026-08-10 至 09-20 的六周，约 1,600 条素材、21 件事、41 个人，"
                        "由 source/bible.json 经 tools/scale_pm/plan.py 确定性规划（金标准），再由自家 DGX Spark 上的模型逐条生成文字"
                        "（tools/scale_pm/gen.py）。八种入口：腾讯会议/飞书妙记/Zoom 逐字稿导出、手机键盘（打字/语音）、Mac Fn 口述、"
                        "微信/企业微信/飞书聊天粘贴、截图、PDF、邮件、Claude/Codex 结果贴回。一条里常混几件事，补充隔几天才到且不点名，"
                        "别名撞车（两个周总、两个王老师、两个 Lily、可可），形近事件成对出现。所有人物、公司、学校、金额均为虚构，"
                        "不引用任何真实会议或真实数据；截图用中性通用样式渲染并带合成数据标记。"),
        "source": "source/bible.json",
        "home_rubric": HOME_RUBRIC,
        "owner_person_id": OWNER,
        "people": people, "events": events, "items": items, "facts": out_facts,
        "checkpoints": plan["checkpoints"],
    }
    node_tok, node_calls, models = Counter(), Counter(), {}
    for r in gen.values():
        n = r.get("node")
        if n:
            node_calls[n] += 1
            node_tok[n] += (r.get("meta") or {}).get("completion_tokens") or 0
            models[n] = r.get("model")
    genblock = {"plan_seed": plan.get("seed"), "generator": "eval/tools/scale_pm/gen.py",
                "accepted_items_by_node": {n: {"model": models[n], "items": node_calls[n], "completion_tokens": node_tok[n]} for n in node_calls},
                "accepted_completion_tokens": sum(node_tok.values())}
    if args.stats:
        for pth in args.stats.split(","):
            if os.path.exists(pth):
                genblock.setdefault("runs", []).append(json.load(open(pth, encoding="utf-8")))
    scenario["generation"] = genblock
    with open(os.path.join(out_dir, "scenario.json"), "w", encoding="utf-8") as fh:
        json.dump(scenario, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    with open(os.path.join(out_dir, "pdf_jobs.json"), "w", encoding="utf-8") as fh:
        json.dump(pdf_jobs, fh, ensure_ascii=False)
    print(f"items {len(items)} missing {len(missing)} {missing[:10]}; dropped fact refs {dict(dropped_refs)}; pdf jobs {len(pdf_jobs)}; images {len(images_to_render)}",
          file=sys.stderr)
    if not args.no_render:
        import render_screenshots as rs
        from PIL import Image
        for ref, spec in images_to_render:
            path = os.path.join(assets, ref + ".png")
            rs.render(spec, path)
            if spec.get("style") == "generic_doc":
                Image.open(path).convert("RGB").save(os.path.join(assets, ref + ".pdf"), "PDF", resolution=150)
        print(f"rendered {len(images_to_render)} images", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
