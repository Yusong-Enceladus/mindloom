#!/usr/bin/env python3
"""Generate the text of every planned scale-pm item with the Spark models (OpenAI-compatible endpoints).

  python3 eval/tools/scale_pm/gen.py --plan plan.json --out gen.jsonl \
      --endpoint qwen-2930=http://127.0.0.1:18001/v1=qwen3.6-35b-a3b-nvfp4=8 ...

Each endpoint is name=url=model=concurrency. Items become ready once the (at most two) earlier related items
they quote for continuity are done. The model is told the facts an item must convey, in plain words; it is
never shown event ids, event titles or gold labels. Transcript timestamps, chat names/times, e-mail headers
and export headers are rendered here, deterministically. Resumable: keys already in --out are skipped.
Only synthetic scenario text is ever sent.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import threading
import time
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "eval"))
from score import fact_matches, normalize_text  # noqa: E402

BIBLE = json.load(open(os.path.join(ROOT, "eval", "scenarios", "scale-pm", "source", "bible.json"), encoding="utf-8"))
EVENTS = {e["id"]: e for e in BIBLE["events"]}
PEOPLE = {p["id"]: p for p in BIBLE["people"]}
OWNER = "jiang_yuan"
PEOPLE[OWNER] = {"id": OWNER, "name": "江予安", "aliases": BIBLE["protagonist"]["aliases"], "role": "本人：澄湾集团会员与增长产品负责人（L7）", "org": "澄湾集团"}

AVOID = {"E01": ["小澄", "导购助手"], "E02": ["会员频道", "等级卡", "积分商城"], "E03": ["搜索框", "入口", "AB"], "E04": ["故障", "INC", "重复扣"],
         "E05": ["BUG-4471", "4471", "余额不一致"], "E06": ["积分抵现", "接口"], "E07": ["合规", "LGL"], "E08": ["标注", "评测集", "禾数"],
         "E09": ["沟通会", "演示"], "E10": ["OKR"], "E11": ["HC", "招聘", "候选人"], "E12": ["绩效", "校准"], "E13": ["晋升", "答辩", "L8"],
         "E14": ["栖木"], "E15": ["鹭洲"], "E16": ["去留"], "E17": ["清洗脚本", "埋点"], "E18": ["学习小组"], "E19": ["结节", "B超", "B 超"],
         "E20": ["团建"], "E21": ["竞品"]}
SYSTEM = ("你是中文合成数据写手，为一个完全虚构的评测场景写素材。场景里的人物、公司、"
          "产品和金额全部是虚构的，不涉及任何真实的人、公司或会议。严格按要求的格式只输出素材本身，不要解释，不要写'好的'，"
          "不要用 markdown 标题、加粗或代码块围栏（Codex 输出里的代码除外）。不要给内容加'事件''第几件事'之类的标签。少用表情符号。")
PROTAGONIST = ("江予安，34 岁，女，上海，澄湾集团的产品负责人（L7），直属上级是产品总监韩立峰，再往上是 VP 周启明；"
               "手下有三个产品经理和一个实习生。说话直接、想到什么说什么。")
NOISE_HEAD = "写作背景：江予安，34 岁，女，住上海，在一家互联网公司上班，家里养了一只叫可可的猫。"


ANCHOR = {
    "E01": "澄湾 App 首页的 AI 导购助手「小澄」v1.0 上线（先灰度再全量），梁晨负责，马骁做算法，罗一鸣前端，唐雨桐测试，丁宁是项目 PMO",
    "E02": "会员频道 3.0 改版上线（等级权益页 + 新版积分商城），赵一帆负责；设计苏蔓、前端罗一鸣、后端贺子轩、测试唐雨桐、运营陆小蕾",
    "E03": "想在首页搜索框下方加一个'问问小澄'入口，需要搜索团队负责人曹磊同意，担心分走搜索 GMV",
    "E04": "8/26 晚上的线上故障 INC-20260826-01「积分重复扣减」（SRE 林澈值班拉群，积分后端贺子轩和支付后端孙浩修，客服白露）",
    "E05": "测试环境里的普通缺陷 BUG-4471：积分商城页的积分余额和'我的'页不一致（会员频道 3.0 的缺陷，唐雨桐提、贺子轩修，不是线上故障）",
    "E06": "会员频道的积分商城要用支付团队的'积分抵现 v2 接口'，需要支付产品沈之恒排期、支付后端孙浩开发和提测",
    "E07": "小澄的合规评审（评审单 LGL-2026-117）：法务魏婷、数据安全方可审隐私、日志留存和 AI 生成内容，梁晨对接",
    "E08": "小澄评测集 v1：找外包供应商禾数标注（项目经理黄莉）标注 2,000 条真实意图 query，涉及报价、预算（财务郑启）、合同和交付，马骁用它做评测",
    "E09": "9/16「澄湾秋季产品沟通会」上小澄的现场演示，市场部杨可欣牵头，江予安准备脚本",
    "E10": "会员与增长组的 Q4 OKR 草案，要交给韩立峰",
    "E11": "团队招一个高级产品经理（会员方向，HC-2026-031），江予安是面试官，HRBP 顾南管流程",
    "E12": "年中绩效季：江予安给三个下属赵一帆、梁晨、吴迪打分并参加校准，HRBP 顾南组织",
    "E13": "江予安自己被提名 L7→L8 晋升，要准备述职材料和答辩",
    "E14": "江予安私下在面前同事叶知秋内推的 AI 创业公司栖木智能（岗位 AI Agent 产品总监）。栖木这边的人只有：内推人叶知秋、CTO 田野、创始人兼 CEO 周屹（也被叫周总）、HRD 王蕊，不要编别的人名。这事在公司任何渠道都不提",
    "E15": "江予安私下在面猎头陈可（远岫人才）推荐的鹭洲集团（岗位 电商增长高级产品专家）。鹭洲这边的人只有：猎头陈可、面试官宋文博、部门总监王振东（也被叫王总/王老师）、交叉面彭越、HR 孟佳，不要编别的人名。这事在公司任何渠道都不提",
    "E16": "江予安在想要不要离开澄湾：留下、去栖木、去鹭洲怎么比，牵涉家里房贷，和丈夫程远、前老板孔维商量",
    "E17": "江予安用 Codex 写小澄埋点日志的清洗脚本 clean_xc_events.py，给数据分析师秦朗做周报取数",
    "E18": "平台技术部金牧发起的内部 AI 学习小组，请江予安做一次分享",
    "E19": "江予安本人体检查出甲状腺结节，要去医院专科复查（纯私事）",
    "E20": "团队中秋团建和中秋礼盒，实习生陶然张罗",
    "E21": "实习生陶然写三家 AI 导购竞品（拾味、比邻购、青橙助手，都是虚构的）的体验报告",
}
RULES = ("写作规则：1) 用符合说话人身份的口语自己组织语言，不要照抄下面引号里的句子；2) 要求写出的事实必须写对，关键数字/日期照写；"
         "3) 不要编造任何没给出的原因、根因、金额、比例、人数、日期或结论，需要细节时用模糊说法（'还在查''回头对一下'）；"
         "4) 背景里的事情只是背景，不必复述，更不要把它们说成今天刚发生；5) 不要提到下面没列出的其他项目；"
         "6) 不要写'江予安在某某 App 里口述'之类的说明，也不要写时间戳或 App 名作开头；7) 说话人不会用自己的名字称呼自己；"
         "8) 背景说明是给你看的，不要把背景说明、人物介绍原样写进去；9) 涉及已知情况里的数字时必须和已知情况一致，不要给同一个指标另编一个数。\n")
EXTRA = {
    "K:0904_contract_seal": "必须包含这句原话：标注那个合同今天终于盖了 7.2 走的",
    "K:0915_recon_delay": "必须包含这句原话：对账那个又拖到月底 孙浩说9/30",
    "K:0826_night_dump": ("要按这个意思口述（可以加语气词，顺序不变）：小澄灰度先暂停，一键抵扣开关关掉；明早跟白露对客服话术；"
                          "会员那个余额不一致别混进复盘，那是缓存问题；今晚八点那个面试肯定去不了了，跟陈可说改周五 8/28 晚上八点；哦对，体检复查是 9/5 那个号别忘了。"),
    "K:0904_qimu_3rd": "口述里要有一句：周总问我为什么想离开大厂。（这里的周总是栖木 CEO 周屹）",
    "S:chat_zhou_demo": "消息里要有周总（周启明）说的：演示压到 3 分钟。",
    "C:0919_wangrui_78": "王蕊要说一句：78 可以（即 base 78,000×14）。",
    "C:0915_team_rain": "要有人说：周六下雨 改剧本杀。",
}


def strip_refs(s: str) -> str:
    return re.sub(r"[（(]\s*(?:见\s*)?E\d\d\s*[)）]", "", re.sub(r"（来自合规意见 E\d\d）", "", s)).replace("  ", " ")


def pdesc(pid: str) -> str:
    p = PEOPLE[pid]
    return f"{p['name']}（{p.get('role', '')}{'，' + p['org'] if p.get('org') and p['org'] not in ('澄湾集团',) else ''}）"


# ------------------------------------------------------------------------------------------ prompt pieces
class Ctx:
    def __init__(self, plan):
        self.plan = plan
        self.facts = {f["fact_id"]: f for f in plan["facts"]}
        self.items = plan["items"]
        self.by_key = {it["key"]: it for it in self.items}
        self.first_t = {fid: self.by_key[f["first"]]["t"] for fid, f in self.facts.items()}
        self.by_event = defaultdict(list)
        for f in plan["facts"]:
            self.by_event[f["event_id"]].append(f["fact_id"])

    def known(self, eid: str, t: str) -> list[str]:
        out = []
        for fid in self.by_event[eid]:
            if self.first_t[fid] <= t:
                succ = self.facts[fid]["superseded_by"]
                if succ and self.first_t[succ] <= t:
                    continue
                out.append(fid)
        out.sort(key=lambda f: self.first_t[f])
        return out


def when(it) -> str:
    return it.get("content_time") or it["t"]


def fmt_dt(ts: str) -> str:
    d = datetime.fromisoformat(ts)
    wd = "一二三四五六日"[d.weekday()]
    return f"{d.month}月{d.day}日（周{wd}）{d.strftime('%H:%M')}"


def keys_readable(keys):
    return "；".join(" 或 ".join(k.split("|")) for k in keys)


def md(fid, ctx) -> str:
    d = ctx.facts[fid]["date"]
    return f"{int(d[5:7])}/{int(d[8:10])}"


def matter_block(ctx: Ctx, it, k: int, m: dict) -> str:
    e = m["event"]
    t = when(it)
    lines = [f"【事情{k}】背景：{ANCHOR[e]}"]
    kn = [f for f in ctx.known(e, t) if f not in m["facts"]]
    nk = 6 if it["fmt"].endswith("transcript") or it["fmt"] in ("pdf", "claude_result") else 2
    if kn and not it.get("brainstorm"):
        lines.append("  已经知道的情况（背景，不必复述）：" + "；".join(f"{md(f, ctx)} {strip_refs(ctx.facts[f]['text'])}" for f in kn[-nk:]))
    for r in m.get("refs", []):
        f = ctx.facts[r["fact_id"]]
        txt = strip_refs(f["text"])
        if r["role"] == "new":
            lines.append(f"  必须写出（这是这个消息第一次出现，发生在 {md(r['fact_id'], ctx)}）：{txt}。关键数字/日期要原样出现：{keys_readable(f['keys'])}。")
        elif r["role"] == "repeat":
            lines.append(f"  要再提到（这是 {md(r['fact_id'], ctx)} 就有的消息）：{txt}。关键数字/日期照写：{keys_readable(f['keys'])}。")
        else:
            succ = ctx.facts[f["superseded_by"]]
            lines.append(f"  有人还按旧说法在说：{txt}（旧值照写：{keys_readable(f['keys'])}）；其实 {md(f['superseded_by'], ctx)} 已经改成：{strip_refs(succ['text'])}。"
                         "写成说话的人没更新或记错了（比如'不是……吗'），江予安本人不认同旧说法；可以有人顺口纠正，也可以没人纠正。")
    if not m.get("refs"):
        lines.append("  这件事只聊近况、进度、担心或下一步安排，不要引入新的日期、数字或结论。")
    if m.get("oblique"):
        av = "、".join(AVOID.get(e, []))
        lines.append(f"  指代方式：这是隔了几天的补充，不要点明是哪件事——不要出现这些词：{av}；用'那个事''上次说的''那边'、只报数字、或只用人名昵称来指代。")
    return "\n".join(lines)


def cast_block(it) -> str:
    out = []
    for pid, s in it["cast_s"]:
        if pid == OWNER:
            continue
        out.append(f"{pdesc(pid)}，在文中写作「{s}」")
    names = []
    for pid, s in it["named_s"]:
        if pid == OWNER:
            continue
        names.append(f"{pdesc(pid)}，写作「{s}」")
    txt = ""
    if out:
        txt += "出场的人：" + "；".join(out) + "。\n"
    if names:
        txt += "文中要提到的人（照这个写法写，至少出现一次）：" + "；".join(names) + "。\n"
    return txt


def asr_line(it) -> str:
    if not it.get("asr"):
        return ""
    a, b = it["asr"]
    return f"语音/输入法的错字：把「{a}」写成「{b}」（至少出现一次，这是识别或输入错误，不要解释）。\n"


def span_instr(it) -> str:
    if len(it["matters"]) < 2:
        return ""
    n = len(it["matters"])
    return (f"\n正文之后另起一行写 ===摘录===，然后每件事一行，格式「编号|原文片段」，编号 1–{n} 对应上面的事情编号，"
            "原文片段是正文里讲这件事的一句话，必须逐字照抄正文（10–40 字）。")


def length_line(it) -> str:
    a, b = it["length"]
    return f"长度约 {a}–{b} 字。"


FORMAT_TEXT = {
    "phone_ime": "江予安在手机上用织机键盘在「{app}」里{how}的一段字。{where}{length}碎句、省略、少标点都可以，很口语。",
    "mac_dictation": "江予安在 Mac 上按 Fn 口述、转写后进了「{app}」。{where}口语化，带'那个/就是/呃/对吧'，断句随意。{length}",
}


def reminder(it) -> str:
    n = len(it["matters"])
    if not n:
        return ""
    return (f"\n再次提醒：只写上面列出的 {n} 件事，不要提到任何其他工作项目、其他公司的面试或其他私事"
            "（比如没列出来的上线、故障、招聘、绩效、晋升、团建、体检、别家公司）；人物只用上面给出的人。")


def build_prompt(ctx: Ctx, it, prior: list[str]) -> tuple[str, int, bool]:
    user, mt, lj = _build_prompt(ctx, it, prior)
    if not it["noise"] and not it["fmt"].endswith("transcript"):
        user += reminder(it)
    return user, mt, lj


def _build_prompt(ctx: Ctx, it, prior: list[str]) -> tuple[str, int, bool]:
    fmt = it["fmt"]
    head = f"写作背景：{PROTAGONIST}\n素材时间：{fmt_dt(it['t'])}"
    if it.get("content_time") and it["content_time"][:10] != it["t"][:10]:
        head += f"；素材内容本身发生在 {fmt_dt(it['content_time'])}（她过了几天才把它放进来）"
    head += "。\n"
    if it["noise"]:
        return noise_prompt(it, NOISE_HEAD + f"素材时间：{fmt_dt(it['t'])}。\n"), 900, False
    matters = "\n".join(matter_block(ctx, it, k + 1, m) for k, m in enumerate(it["matters"]))
    cont = ""
    if prior:
        cont = "（参考：她之前关于这些事的两条素材片段，保持人物和说法一致，不要照抄）\n" + "\n---\n".join(p[:220] for p in prior) + "\n"
    body = head + RULES + cont + cast_block(it) + asr_line(it) + (("特别要求：" + EXTRA[it["key"]] + "\n") if it["key"] in EXTRA else "")
    long_job = False
    if fmt.endswith("transcript"):
        long_job = True
        return transcript_prompt(ctx, it, body, matters), int(it["length"][1] * 1.1) + 800, True
    if fmt in ("phone_ime", "mac_dictation"):
        how = {"typed": "打", "voice": "语音输入", "dictation": "口述"}.get(it.get("mode") or "typed", "打")
        app = it["app"]
        if app == "微信":
            where = "这是她发出去的微信消息（只有她这一侧，可能是连着发的几句）。"
        elif app in ("飞书", "企业微信"):
            where = f"这是她在{app}里发给同事的消息（只有她这一侧）。"
        elif app == "Claude 输入框":
            where = "这是她口述给 Claude 的提问/指令本身（要 Claude 帮忙做事）。"
        elif app == "Codex 终端":
            where = "这是她口述给 Codex 的指令本身。"
        elif app == "邮件草稿":
            where = "这是她口述的邮件草稿。"
        elif app == "飞书文档":
            where = "这是她口述进飞书文档的一段记录。"
        elif app in ("浏览器",):
            where = "这是她在浏览器搜索框/网页里输入的一段文字（可能是搜索词加几句备注）。"
        else:
            where = "这是她给自己的随手记。"
        if it["brainstorm"]:
            where += ("她一口气说好几件事，用'还有''对了''另外''哦还有个事'串起来，事与事之间没有标题和编号，"
                      "每件事都要说到。" + ("中间夹一两句和这些事都无关的闲话（比如午饭、猫、快递、天气）。" if it.get("noise_bits") else ""))
        text = FORMAT_TEXT[fmt].format(app=app, how=how, where=where, length=length_line(it))
        return body + text + "\n\n要写进去的内容：\n" + matters + span_instr(it) + "\n只输出她输入的文字本身。", 1400 if it["brainstorm"] else 700, False
    if fmt == "chat_paste":
        return chat_prompt(ctx, it, body, matters), 1800, False
    if fmt == "email":
        return email_prompt(ctx, it, body, matters), 1500, False
    if fmt in ("claude_result", "codex_result"):
        return agent_prompt(ctx, it, body, matters), 2200, False
    if fmt == "doc_text":
        sub = it.get("sub", "飞书文档评论导出")
        spec = {"缺陷单导出": "缺陷管理系统导出的缺陷单文本：字段行（编号、标题、状态、优先级、提单人、处理人、环境、复现步骤、处理记录带时间）",
                "飞书文档评论导出": "飞书文档评论导出的文本：先一行文档名，然后每条评论一行「评论人 日期 时间：内容」，可有回复",
                "日历邀请文本": "日历邀请复制出来的文本：标题、时间、地点/会议号、组织者、参会人、议程",
                "问卷结果文本": "问卷结果页复制出来的文本：问卷名、回收数、各题统计、若干条文字反馈"}[sub]
        return body + f"这是一段{spec}。{length_line(it)}\n\n要写进去的内容：\n" + matters + span_instr(it) + "\n只输出这段文本。", 1400, False
    if fmt == "pdf":
        return pdf_prompt(ctx, it, body, matters), 3200, True
    if fmt == "screenshot":
        return shot_prompt(ctx, it, body, matters), 1600, False
    raise ValueError(fmt)


def noise_prompt(it, head) -> str:
    fmt = it["fmt"]
    theme = it.get("theme", "日常琐事")
    where = {"phone_ime": f"江予安在手机「{it['app']}」里{'语音输入' if it.get('mode') == 'voice' else '打'}的一段字（5–80 字，碎句）",
             "mac_dictation": "江予安在 Mac 上按 Fn 口述进备忘录的一段话（30–150 字，口语）",
             "chat_paste": f"从{it['app']}复制粘贴过来的一小段聊天（3–8 行，一行一句「名字：内容」，名字用虚构的朋友/同事/群友昵称，可带[图片]占位）",
             "email": "一封发给江予安、与她的工作项目无关的邮件（发件方是虚构的商家、媒体、物业或公司内部系统）：先写「发件人：…」「主题：…」两行，再写正文（100–300 字，邮箱用 .example 域名）"}[fmt]
    hard = "（注意：这条素材和她的任何工作项目、面试、晋升、体检都没有关系，只是字面上碰巧沾边。）" if "hard_noise" in it["tags"] else ""
    return head + f"写{where}。主题：{theme}。{hard}不要提到任何工作项目、同事、面试或公司名。\n只输出素材本身。"


def transcript_prompt(ctx, it, body, matters) -> str:
    cast = it["meeting_cast"]
    spk = "；".join(f"S{i + 1}={'江予安本人（' + PEOPLE[OWNER]['role'] + '）' if p == OWNER else pdesc(p)}" for i, p in enumerate(cast))
    a, b = it["length"]
    kind = it["title"]
    inter = ""
    if len(it["matters"]) >= 3:
        inter = "这场会覆盖好几件事，讨论要穿插进行：中途会绕回前面的话题、有人插话、有人跑题再拉回来，不要一件事讲完再讲下一件。"
    special = ""
    if it["key"].startswith("M:hc_"):
        special = "这是一场面试（江予安和同事是面试官），候选人做自我介绍、回答问题、反问。"
        if it["key"] == "M:hc_jiangwen_0820":
            special += "候选人离开后面试官简短交流，结论是可以过。"
        else:
            special += "逐字稿里不下结论。"
    if it["key"].startswith("M:standup"):
        special = "这是 10 分钟的上线站会，节奏快，每人几句。"
    summary = ""
    if it["fmt"] == "feishu_transcript" and it.get("with_summary"):
        summary = ("\n正文之后另起一行写 ===纪要===，然后写这场会的「智能纪要」：一段总结（3–5 句）和「待办」列表（每行「负责人：事项（截止日期）」）。")
    return (body + f"这是一场会议「{kind}」的逐字稿，会议软件自动转写。参会人（用编号标发言人）：{spk}。{special}{inter}\n"
            f"总长度约 {a}–{b} 字，至少 {max(8, a // 180)} 段发言；口语、有'嗯''那个''就是说'、有人打断、有重复和口误，像真实转写。\n\n"
            f"会上要谈到的事：\n{matters}\n\n"
            "输出格式：每段发言一行，以「S编号：」开头，例如「S2：嗯我这边补充一下……」。不要写时间戳，不要写会议标题。"
            + summary +
            "\n最后另起一行写 ===摘录===，然后每件事一行「编号|原文片段」，编号对应上面的事情编号，原文片段必须是逐字照抄的某段发言中的一句（10–40 字）。")


def chat_prompt(ctx, it, body, matters) -> str:
    cast = it["cast_s"]
    spk = "；".join(f"S{i + 1}={'江予安本人' if p == OWNER else pdesc(p)}" for i, (p, _) in enumerate(cast))
    n = random.Random(it["key"]).choice([4, 5, 6, 8, 10, 12, 15]) if not it.get("merged") else random.Random(it["key"]).choice([12, 18, 25, 35])
    extra = "可以夹一两个 [图片] 或 [文件] xxx.pdf 占位，偶尔一句「xx 撤回了一条消息」。" if random.Random(it["key"] + "x").random() < 0.25 else ""
    app = it["app"]
    return (body + f"这是从{app}「{it.get('title', '')}」里复制出来的一段聊天记录。发言人：{spk}。约 {n} 行（3–40 行之间），一行一句。{extra}\n"
            "口语、简短，像真实工作群/私聊，每个人按自己的身份说话。\n\n要聊到的内容：\n" + matters +
            "\n\n输出格式：每行「S编号：内容」，不要写时间，不要写群名。" + span_instr(it))


def email_prompt(ctx, it, body, matters) -> str:
    em = it["email"]
    frm = "江予安" if em["from"] == OWNER else pdesc(em["from"])
    to = "、".join("江予安" if p == OWNER else pdesc(p) for p in em["to"])
    cc = "、".join(pdesc(p) for p in em["cc"]) if em["cc"] else "无"
    return (body + f"这是一封邮件。发件人：{frm}；收件人：{to}；抄送：{cc}。{'这是个人邮箱里的邮件。' if em['personal'] else '这是公司邮箱里的工作邮件。'}"
            f"{length_line(it)}\n\n邮件要写到的内容：\n{matters}\n\n输出格式：第一行「主题：…」，空一行后是正文（称呼、正文、落款）。不要写发件人/收件人/日期行。" + span_instr(it))


def export_text(ctx, it) -> str:
    import fixed as fx  # noqa
    e = it["matters"][0]["event"]
    kn = ctx.known(e, it["t"])
    title = fx.EXPORT_TITLES.get(e, EVENTS[e]["title"])
    lines = [f"【{title}】", "现在到哪一步：" + strip_refs(ctx.facts[kn[-1]]["text"]) if kn else "现在到哪一步：刚开始"]
    for f in kn[-4:]:
        d = ctx.facts[f]["date"][5:].replace("-", "/")
        lines.append(f"- {d} {strip_refs(ctx.facts[f]['text'])}")
    return "\n".join(lines)


def agent_prompt(ctx, it, body, matters) -> str:
    tool = "Claude" if it["fmt"] == "claude_result" else "Codex"
    topic = it.get("topic", "")
    if tool == "Claude":
        form = "Claude 的回答正文（可以有分点、表格用竖线对齐的纯文本），像真实的 AI 助手回答。"
    else:
        form = ("Codex 在终端里的输出：可以有命令行、运行日志、diff（以 --- +++ @@ 开头）、Python/SQL 代码、报错 Traceback、测试结果。"
                "代码里的表名、字段、路径都是虚构的（例如 xc_events、clean_xc_events.py）。")
    exp = ""
    if it.get("export_return"):
        exp = f"她先把织机里这件事导出成纯文本发给了 {tool}，导出的内容是：\n{export_text(ctx, it)}\n"
    return (body + exp + f"她让 {tool} 帮忙：{topic}。下面要写的是 {tool} 返回、被她原样粘回来的结果。{form}长度约 {it['length'][0]}–{it['length'][1]} 字。\n\n"
            f"结果里要体现的内容：\n{matters}\n\n只输出 {tool} 的结果本身。" + span_instr(it))


def pdf_prompt(ctx, it, body, matters) -> str:
    fn = it.get("filename", "文档.pdf")
    scanned = "这是一份扫描件（纸质文件扫描），版式是正式报告/信函。" if it.get("scanned") else ""
    return (body + f"这是一份 PDF 文档「{fn}」的正文文字。{scanned}要像真实的正式文档：第一行是文档标题，然后分节（用'一、二、'或'1. 2.'编号），"
            f"可有表格（用竖线分隔的纯文本行）。长度约 {it['length'][0]}–{it['length'][1]} 字。所有机构、医院、公司都是虚构的。\n\n文档要包含的内容：\n{matters}\n\n只输出文档正文。"
            + span_instr(it))


def shot_prompt(ctx, it, body, matters) -> str:
    style = it["style"]
    brief = it.get("title", "")
    if style == "chat":
        cast = it["cast_s"] or [["jiang_yuan", "我"]]
        spk = "；".join(f"S{i + 1}={'江予安本人' if p == OWNER else pdesc(p)}" for i, (p, _) in enumerate(cast))
        return (body + f"这是一张聊天截图（{brief}）。发言人：{spk}。写 4–9 条消息。\n\n截图里要有的内容：\n{matters}\n\n"
                "输出格式：第一行「标题|聊天窗口标题」，之后每条消息一行「S编号|HH:MM|内容」，时间递增且不晚于素材时间。" + span_instr(it))
    schema = {
        "table": '{"title": "看板/问卷标题", "subtitle": "时间范围或筛选条件", "columns": ["列名", ...], "rows": [["值", ...], ...], "note": "底部说明"}，rows 3–10 行',
        "card": '{"title": "卡片标题", "fields": [["字段名", "值"], ...], "body": "正文（可空）", "footer": "底部小字"}，fields 4–10 个',
        "design": '{"title": "设计稿标题", "blocks": [{"label": "区块名", "text": "区块里的文字"}, ...], "annotations": ["评审批注", ...]}，blocks 3–6 个，annotations 0–4 条',
    }[style]
    key = it["key"]
    hint = ""
    if key.startswith("S:alert_"):
        hint = "这是监控系统的告警卡片：告警名、级别、服务、触发时间、指标与当前值、状态、值班人。只写截图那一刻已有的信息。"
    elif key.startswith("S:bug_"):
        hint = "这是缺陷管理系统里的一张缺陷单卡片：编号、标题、状态、优先级、提单人、处理人、环境、最近一条处理记录。"
    elif key.startswith("S:sms_"):
        hint = "这是手机短信截图，做成卡片：发信方（虚构医院预约平台）、时间、短信正文。"
    elif key.startswith("S:cal_"):
        hint = "这是日历邀请卡片：标题、时间、地点/会议号、组织者、参会人。"
    elif key.startswith("S:offer_"):
        hint = "这是 HR 发来的 offer 明细页（虚构公司的中性样式）：职位、职级、base、月数、签字费/期权/RSU、入职日期、答复截止等字段。"
    elif key.startswith("S:design_"):
        hint = "这是设计稿截图：几个界面区块和评审批注（批注用'@某人'或人名开头）。"
    elif key.startswith("S:dash_") or key in ("S:vote", "S:survey"):
        hint = "这是看板/统计页截图：一个表格，2–6 行数据，不要空行。"
    return (body + f"这是一张截图：{brief}。{hint}界面是中性的通用样式（不模仿任何真实 App），虚构的'澄湾数据台'等内部系统。\n\n截图里要有的内容：\n{matters}\n\n"
            f"只输出一个 JSON 对象：{schema}。所有要求的数字/日期必须出现在 JSON 的值里；除此之外不要编造金额、比例、人数等数值，其余单元格用状态、名称、时间或'—'。")


# ------------------------------------------------------------------------------------------ parsing and rendering
SPAN_RE = re.compile(r"^\s*(\d+)\s*[|｜]\s*(.+?)\s*$")


def split_spans(raw: str):
    parts = re.split(r"\n\s*===\s*摘录\s*===\s*\n?", raw, maxsplit=1)
    body = parts[0]
    spans = []
    if len(parts) > 1:
        for line in parts[1].splitlines():
            m = SPAN_RE.match(line)
            if m:
                spans.append((int(m.group(1)), m.group(2).strip("「」\"' ")))
    return body.strip(), spans


def clean(s: str) -> str:
    s = re.sub(r"^```[a-zA-Z]*\n|\n```\s*$", "", s.strip())
    return s.strip()


TURN_RE = re.compile(r"^\s*S(\d+)\s*[:：]\s*(.+)$")


def hms(sec: int) -> str:
    return "%02d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def render_transcript(it, body: str, rnd: random.Random):
    parts = re.split(r"\n\s*===\s*纪要\s*===\s*\n?", body, maxsplit=1)
    turns_raw, summary = parts[0], (parts[1].strip() if len(parts) > 1 else "")
    cast = it["meeting_cast"]
    names = {i + 1: s for i, (p, s) in enumerate(it["cast_s"])}
    turns = []
    for line in turns_raw.splitlines():
        m = TURN_RE.match(line)
        if m and int(m.group(1)) in names:
            turns.append([int(m.group(1)), m.group(2).strip()])
        elif turns and line.strip() and not line.startswith("==="):
            turns[-1][1] += line.strip()
    if len(turns) < 4:
        return None, "too few turns"
    unknown = None
    if it["fmt"] == "feishu_transcript" and rnd.random() < 0.12:
        cand = [i for i in names if cast[i - 1] != OWNER]
        unknown = rnd.choice(cand) if cand else None
    start = datetime.fromisoformat(it["content_time"])
    sec = rnd.randint(2, 20)
    out_turns = []
    for idx, txt in turns:
        out_turns.append((idx, sec, txt))
        sec += int(len(txt) / 4.2) + rnd.randint(1, 6)
    if it["fmt"] == "tencent_transcript":
        att = "、".join(PEOPLE[p]["name"] for p in cast)
        end = start + timedelta(seconds=sec)
        head = f"会议主题：{it['title']}\n会议时间：{start.strftime('%Y-%m-%d %H:%M')}-{end.strftime('%H:%M')}\n参会人：{att}\n\n"
        lines = [f"{names[i]}({hms(s)}):\n{t}\n" for i, s, t in out_turns]
        text = head + "\n".join(lines)
    elif it["fmt"] == "feishu_transcript":
        head = f"文字记录\n{it['title']}\n{start.strftime('%Y年%m月%d日 %H:%M')}\n\n"
        if summary:
            summary = maybe_corrupt_summary(summary, it, rnd)
            head += "智能纪要\n" + summary + "\n\n"
        lines = []
        for i, s, t in out_turns:
            nm = "说话人 2" if unknown == i else names[i]
            lines.append(f"{nm} {hms(s)}\n{t}\n")
        text = head + "\n".join(lines)
    else:  # zoom
        head = f"{it['title']}\nZoom 会议转写 {start.strftime('%Y-%m-%d %H:%M')}\n\n"
        lines = [f"[{(start + timedelta(seconds=s)).strftime('%H:%M:%S')}] {names[i]}: {t}" for i, s, t in out_turns]
        text = head + "\n".join(lines)
    return {"text": text, "turns": [[cast[i - 1], s, t] for i, s, t in out_turns], "unknown_speaker": cast[unknown - 1] if unknown else None,
            "summary_corrupted": it.get("_corrupted", False)}, None


def maybe_corrupt_summary(summary: str, it, rnd) -> str:
    """~10% of Feishu smart summaries name the wrong owner for a to-do (the transcript body is the truth)."""
    if rnd.random() >= 0.2:
        return summary
    names = [PEOPLE[p]["name"] for p in it["meeting_cast"] if p != OWNER]
    for n in names:
        if n in summary:
            other = rnd.choice([x for x in names if x != n] or [n])
            if other != n:
                it["_corrupted"] = True
                return summary.replace(n, other, 1)
    return summary


NAME_RE = re.compile(r"^\s*([^：:|｜]{1,14})\s*[:：]\s*(.+)$")


def name_index(cast, name: str):
    """Map a name the model wrote instead of an S-number back to the cast index (1-based)."""
    name = name.strip()
    for i, (p, s) in enumerate(cast):
        forms = {s, PEOPLE[p]["name"], *[a for a in PEOPLE[p].get("aliases", [])]}
        if p == OWNER:
            forms |= {"我", "江予安"}
        if name in forms:
            return i + 1
    return None


def render_chat(it, body: str, rnd: random.Random):
    cast = it["cast_s"]
    names = {i + 1: s for i, (p, s) in enumerate(cast)}
    msgs = []
    for line in body.splitlines():
        m = TURN_RE.match(line)
        if m and int(m.group(1)) in names:
            msgs.append([int(m.group(1)), m.group(2).strip()])
            continue
        nm = NAME_RE.match(line)
        if nm and name_index(cast, nm.group(1)):
            msgs.append([name_index(cast, nm.group(1)), nm.group(2).strip()])
        elif line.strip() and ("撤回了一条消息" in line or line.strip().startswith("[")) and msgs:
            msgs.append([0, line.strip()])
    if len(msgs) < 2:
        return None, "too few chat lines"
    base = datetime.fromisoformat(it.get("content_time") or it["t"]) - timedelta(minutes=len(msgs) * 2 + 5)
    with_time = rnd.random() < 0.15 or it.get("merged") or it.get("content_time")
    lines = []
    t = base
    for idx, txt in msgs:
        t += timedelta(minutes=rnd.choice([0, 0, 1, 1, 2, 3, 5]))
        if idx == 0:
            lines.append(txt)
            continue
        nm = names[idx]
        prefix = f"[{t.strftime('%m-%d %H:%M')}] " if with_time else ""
        lines.append(f"{prefix}{nm}：{txt}")
    text = "\n".join(lines)
    if it.get("merged"):
        text = f"群聊\"{it.get('title', '')}\"的聊天记录\n" + text
    return {"text": text, "messages": [[cast[i - 1][0] if i else None, txt] for i, txt in msgs]}, None


def addr(pid: str, personal: bool) -> str:
    p = PEOPLE[pid]
    if pid == OWNER:
        return "江予安 <ann.jiang@mail.example>" if personal else "江予安 <yuan.jiang@chengwan.example>"
    latin = [a for a in p.get("aliases", []) if a.isascii() and " " in a]
    # no Latin alias: given.family from the pinyin id (never a "pid." prefix, which reads as a gold label)
    parts = pid.split("_")
    handle = latin[0].lower().replace(" ", ".") if latin else ".".join(parts[1:] + parts[:1])
    dom = {"栖木智能": "qimu-ai.example", "鹭洲集团": "luzhou-group.example", "远岫人才": "yuanxiu-talent.example",
           "禾数标注": "heshu-label.example"}.get(p.get("org"), "chengwan.example")
    return f"{p['name']} <{handle}@{dom}>"


def render_email(it, body: str):
    m = re.match(r"\s*主题[:：]\s*(.+?)\n(.*)", body, re.S)
    if not m:
        return None, "no subject"
    subj, text = m.group(1).strip(), m.group(2).strip()
    em = it["email"]
    ts = datetime.fromisoformat(it.get("content_time") or it["t"])
    head = [f"发件人：{addr(em['from'], em['personal'])}", "收件人：" + "; ".join(addr(p, em["personal"]) for p in em["to"])]
    if em["cc"]:
        head.append("抄送：" + "; ".join(addr(p, em["personal"]) for p in em["cc"]))
    head += [f"日期：{ts.strftime('%Y-%m-%d %H:%M')}", f"主题：{subj}"]
    return {"text": "\n".join(head) + "\n\n" + text, "subject": subj}, None


def fix_email_direction(text: str, owner_name: str = "江予安") -> str:
    """The model sometimes writes the body as the owner although the plan made someone else the sender (the
    body is signed by the owner and addresses the planned sender). Make the header match the body: the owner
    becomes the sender and the planned sender a recipient. Also rewrites legacy "pid.family.given@" handles."""
    text = re.sub(r"pid\.([a-z]+)\.([a-z]+)@", lambda m: f"{m.group(2)}.{m.group(1)}@", text)
    head, sep, body = text.partition("\n\n")
    lines = head.split("\n")
    if not sep or not lines[0].startswith("发件人："):
        return text
    frm = lines[0][len("发件人："):]
    tail = [l.strip() for l in body.strip().split("\n") if l.strip()][-3:]
    if frm.startswith(owner_name) or owner_name not in tail:
        return text
    ti = next((i for i, l in enumerate(lines) if l.startswith("收件人：")), None)
    if ti is None:
        return text
    tos = lines[ti][len("收件人："):].split("; ")
    mine = [a for a in tos if a.startswith(owner_name + " <")]
    if not mine:
        return text
    lines[0] = "发件人：" + mine[0]
    lines[ti] = "收件人：" + "; ".join([frm] + [a for a in tos if a != mine[0]])
    return "\n".join(lines) + sep + body


def parse_json_obj(s: str):
    s = clean(s)
    a, b = s.find("{"), s.rfind("}")
    if a < 0 or b < 0:
        return None
    try:
        return json.loads(s[a:b + 1])
    except json.JSONDecodeError:
        return None


def render_shot(it, raw: str):
    style = it["style"]
    if style == "chat":
        body, spans = split_spans(raw)
        lines = [l for l in body.splitlines() if l.strip()]
        title = it.get("title", "")
        msgs = []
        cast = it["cast_s"] or [["jiang_yuan", "我"]]
        names = {i + 1: s for i, (p, s) in enumerate(cast)}
        for l in lines:
            if l.startswith("标题|"):
                title = l.split("|", 1)[1].strip()
                continue
            m = re.match(r"^\s*S(\d+)\s*[|｜]\s*(\d{1,2}:\d{2})\s*[|｜]\s*(.+)$", l)
            if m and int(m.group(1)) in names:
                msgs.append({"sender": names[int(m.group(1))], "time": m.group(2), "text": m.group(3).strip()})
                continue
            m = re.match(r"^\s*([^|｜]{1,14})\s*[|｜]\s*(\d{1,2}:\d{2})\s*[|｜]\s*(.+)$", l)
            if m and name_index(cast, m.group(1)):
                msgs.append({"sender": names[name_index(cast, m.group(1))], "time": m.group(2), "text": m.group(3).strip()})
        if len(msgs) < 2:
            return None, "too few messages", []
        self_name = next((s for p, s in cast if p == OWNER), "我")
        spec = {"style": "generic_im", "chat_title": title, "self_sender": self_name, "messages": msgs}
        return spec, None, spans
    obj = parse_json_obj(raw)
    if not obj:
        return None, "bad json", []
    spec = {"style": {"table": "generic_table", "card": "generic_card", "design": "generic_design"}[style]}
    spec.update(obj)
    if style == "table" and not (obj.get("columns") and obj.get("rows")):
        return None, "table without rows", []
    if style == "card" and not obj.get("fields"):
        return None, "card without fields", []
    if style == "design" and not obj.get("blocks"):
        return None, "design without blocks", []
    return spec, None, []


def image_text(spec: dict) -> str:
    """Standard reading of a rendered screenshot (what a correct reader should extract)."""
    st = spec.get("style")
    if st == "generic_im":
        return "\n".join(f"{m['sender']} {m.get('time', '')}：{m['text']}" for m in spec["messages"])
    out = [str(spec.get("title", ""))]
    if spec.get("subtitle"):
        out.append(str(spec["subtitle"]))
    if st == "generic_table":
        out.append(" | ".join(map(str, spec.get("columns", []))))
        for r in spec.get("rows", []):
            out.append(" | ".join(map(str, r)))
    if st == "generic_card":
        for f in spec.get("fields", []):
            if isinstance(f, (list, tuple)) and len(f) >= 2:
                out.append(f"{f[0]}：{f[1]}")
        if spec.get("body"):
            out.append(str(spec["body"]))
    if st == "generic_design":
        for b in spec.get("blocks", []):
            if isinstance(b, dict):
                out.append(f"{b.get('label', '')}：{b.get('text', '')}")
        for a in spec.get("annotations", []):
            out.append(f"批注：{a}")
    if spec.get("note"):
        out.append(str(spec["note"]))
    if spec.get("footer"):
        out.append(str(spec["footer"]))
    return "\n".join(x for x in out if x)


CUES = {"E01": ["小澄", "小程", "小成", "导购", "灰度", "恢复", "全量", "Go/NoGo", "够不够", "对话卡片", "PRD"], "E02": ["会员频道", "等级", "积分商城", "兑换"],
        "E03": ["入口", "搜索", "AB", "曹磊", "老曹", "磊哥"], "E04": ["故障", "INC", "重复扣", "资损", "补偿", "复盘", "服盘", "定级", "对账", "演练", "幂等"],
        "E05": ["4471", "缓存", "余额", "回归", "待到账", "文案"], "E06": ["接口", "抵现", "提测", "沈之恒", "老沈", "孙浩", "排期"],
        "E07": ["合规", "LGL", "脱敏", "魏婷", "方可", "留存", "未成年"], "E08": ["标注", "评测", "禾数", "黄莉", "Lily Huang", "一致率", "可用率", "报价", "合同"],
        "E09": ["沟通会", "演示", "彩排", "推文", "杨可欣", "Cindy"], "E10": ["OKR", "OK啊", "KR", "Q4"], "E11": ["HC", "蒋文", "邱宇", "候选人", "面试"],
        "E12": ["绩效", "校准", "初评", "吴迪", "病假", "改进计划"], "E13": ["晋升", "进身", "答辩", "述职", "L8"], "E14": ["栖木", "七木", "期木", "田野", "周屹", "王蕊", "作业", "期权"],
        "E15": ["鹭洲", "路洲", "陆洲", "陈可", "宋文博", "王振东", "孟佳", "彭越", "RSU", "签字费"], "E16": ["房贷", "走不走", "留下", "去留", "对比", "程远", "孔维"],
        "E17": ["脚本", "CSV", "Codex", "时区", "清洗"], "E18": ["分享", "学习小组", "金牧", "大纲"], "E19": ["结节", "B超", "B 超", "复查", "刘医生", "医院", "候补", "体检"],
        "E20": ["团建", "剧本杀", "徒步", "礼盒", "投票"], "E21": ["竞品", "拾味", "比邻购", "青橙"]}
SENT_RE = re.compile(r"[^。！？!?\n；;]+[。！？!?；;]?")


STRICT = {"E02": ["会员频道", "等级卡", "积分商城"], "E03": ["搜索框", "问问小澄", "曹磊", "AB 实验", "AB实验"],
          "E04": ["INC", "重复扣", "资损"], "E05": ["4471", "余额不一致", "待到账"], "E06": ["积分抵现"],
          "E07": ["LGL", "魏婷", "合规评审"], "E08": ["标注", "禾数", "黄莉", "评测集"], "E09": ["沟通会", "彩排", "推文"],
          "E10": ["OKR", "OK啊"], "E11": ["HC-2026", "蒋文", "邱宇", "候选人"], "E12": ["绩效", "校准", "初评", "病假"],
          "E13": ["晋升", "进身", "答辩", "述职", "L8"], "E14": ["栖木", "七木", "期木", "田野", "周屹", "王蕊", "叶知秋"],
          "E15": ["鹭洲", "陆洲", "路洲", "宋文博", "王振东", "孟佳", "彭越", "陈可"], "E16": ["房贷", "去留", "18600", "18,600"],
          "E17": ["清洗脚本", "clean_xc", "CSV"], "E18": ["学习小组", "金牧"], "E19": ["结节", "B超", "B 超", "甲乳", "刘医生"],
          "E20": ["团建", "剧本杀", "礼盒"], "E21": ["竞品", "拾味", "比邻购", "青橙"]}


def allowed_text(ctx: Ctx, it) -> str:
    return " ".join([ctx.facts[r["fact_id"]]["text"] for r in it.get("fact_refs", [])] + [ANCHOR[m["event"]] for m in it["matters"]]
                    + [x for _, x in it["cast_s"] + it["named_s"]] + [EXTRA.get(it["key"], "")])


def offplan(ctx: Ctx, it, content: str, prompt_text: str) -> list[str]:
    """Events whose distinctive words appear in the text but not in the item's plan (nor in its prompt)."""
    planned = {m["event"] for m in it["matters"]}
    if "E16" in planned:
        planned |= {"E14", "E15", "E13"}
    out = []
    for e, cues in STRICT.items():
        if e in planned:
            continue
        hits = [c for c in cues if c in content and c not in prompt_text]
        if hits:
            out.append(e)
    return out


def find_quote(ctx, content: str, m: dict):
    best, score = None, 0
    for sm in SENT_RE.finditer(content):
        sent = sm.group(0).strip()
        if len(sent) < 4:
            continue
        sc = 0
        for fid in m["facts"]:
            if fact_matches(ctx.facts[fid]["keys"], sent):
                sc += 3
        sc += sum(1 for c in CUES.get(m["event"], []) if c in sent)
        if sc > score:
            best, score = sent, sc
    if best and len(best) > 80:
        best = best[:80]
    return best


def process(ctx: Ctx, it, raw: str, rnd: random.Random) -> tuple[dict | None, list[str]]:
    fmt = it["fmt"]
    problems = []
    res = {"key": it["key"]}
    head = raw.strip()[:200]
    if re.search(r"cannot be fulfilled|I can't|I cannot|I'm sorry|As an AI|无法满足|无法完成|我不能|抱歉，我", head) or \
            (fmt not in ("codex_result",) and sum(1 for ch in head if "\u4e00" <= ch <= "\u9fff") < 5 and len(head) > 60):
        return None, ["refusal or non-Chinese output"]
    if it["noise"]:
        txt = clean(raw)
        res["text"] = txt
        extra = offplan(ctx, it, txt, "")
        if extra:
            res["offplan_events"] = extra
            problems.append("offplan noise " + ",".join(extra))
        return res, problems
    if fmt == "screenshot":
        spec, err, spans = render_shot(it, raw)
        if err:
            return None, [err]
        res["image"] = spec
        res["reading"] = image_text(spec)
        content = res["reading"]
    else:
        body, spans = split_spans(clean(raw))
        if fmt.endswith("transcript"):
            out, err = render_transcript(it, body, rnd)
            if err:
                return None, [err]
            short = sum(1 for x in out["turns"] if len(x[2]) <= 6)
            if short / len(out["turns"]) > 0.25 or len(out["text"]) > it["length"][1] * 1.6:
                return None, ["degenerate transcript (loops or runaway length)"]
            res.update(out)
            content = res["text"]
        elif fmt == "chat_paste":
            out, err = render_chat(it, body, rnd)
            if err:
                return None, [err]
            res.update(out)
            content = res["text"]
        elif fmt == "email":
            out, err = render_email(it, body)
            if err:
                return None, [err]
            res.update(out)
            content = res["text"]
        else:
            txt = body
            if it.get("export_return"):
                exp = export_text(ctx, it).splitlines()
                txt = "以下是背景：\n" + "\n".join(exp[:4]) + "\n……\n\n" + body
            res["text"] = txt
            content = txt
        if fmt == "pdf":
            res["reading"] = content
    # span quotes -> event segments
    segs = []
    for k, q in spans:
        if 1 <= k <= len(it["matters"]) and q and q in content:
            segs.append({"event_id": it["matters"][k - 1]["event"], "quote": q})
    have = {x["event_id"] for x in segs}
    for m in it["matters"]:
        if m["event"] not in have and len(it["matters"]) >= 2:
            q = find_quote(ctx, content, m)
            if q:
                segs.append({"event_id": m["event"], "quote": q, "located": "auto"})
    res["segments"] = segs
    if len(it["matters"]) >= 2:
        missing = {m["event"] for m in it["matters"]} - {s["event_id"] for s in segs}
        if missing:
            problems.append("spans missing for " + ",".join(sorted(missing)))
    # fact keys
    norm = normalize_text(content)
    kept, dropped = [], []
    for r in it["fact_refs"]:
        f = ctx.facts[r["fact_id"]]
        ok = fact_matches(f["keys"], content)
        if ok:
            kept.append(r)
        else:
            dropped.append(r)
    res["fact_refs_ok"] = kept
    res["fact_refs_missing"] = dropped
    hard_missing = [r["fact_id"] for r in dropped if r["role"] == "new"]
    if hard_missing:
        problems.append("new facts missing keys: " + ",".join(hard_missing))
    # people surfaces
    present = []
    for pid, s in it["cast_s"] + it["named_s"]:
        if pid == OWNER or (s and s in content):
            present.append([pid, s])
    res["people_present"] = present
    res["_norm_len"] = len(norm)
    extra = offplan(ctx, it, content, it.get("_prompt", ""))
    if extra:
        res["offplan_events"] = extra
        problems.append("offplan " + ",".join(extra))
    return res, problems


# ------------------------------------------------------------------------------------------ endpoints and scheduling
class Endpoint:
    def __init__(self, spec: str):
        self.name, self.url, self.model, conc = spec.split("=")
        self.sem = threading.Semaphore(int(conc))
        self.conc = int(conc)
        self.inflight = 0
        self.lock = threading.Lock()
        self.tokens = 0
        self.busy_secs = 0.0
        self.calls = 0
        self.first = None
        self.last = None
        self.fail = 0

    def chat(self, system: str, user: str, max_tokens: int, temperature: float) -> tuple[str, dict]:
        body = {"model": self.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "temperature": temperature, "top_p": 0.95, "max_tokens": max_tokens, "frequency_penalty": 0.3,
                "chat_template_kwargs": {"enable_thinking": False}}
        req = urllib.request.Request(self.url.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=900) as r:
            data = json.loads(r.read())
        dt = time.time() - t0
        usage = data.get("usage") or {}
        with self.lock:
            self.tokens += usage.get("completion_tokens", 0)
            self.busy_secs += dt
            self.calls += 1
            self.first = self.first or t0
            self.last = time.time()
        msg = data["choices"][0]["message"]
        return msg.get("content") or "", {"completion_tokens": usage.get("completion_tokens"), "prompt_tokens": usage.get("prompt_tokens"),
                                          "secs": round(dt, 2), "finish": data["choices"][0].get("finish_reason")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--endpoint", action="append", required=True)
    ap.add_argument("--long-only", default="", help="comma list of endpoint names allowed for long jobs (default: all)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", default="", help="comma list of key prefixes")
    ap.add_argument("--temperature", type=float, default=0.75)
    ap.add_argument("--stats", default="")
    args = ap.parse_args(argv)
    plan = json.load(open(args.plan, encoding="utf-8"))
    ctx = Ctx(plan)
    for it in ctx.items:
        it["with_summary"] = it["fmt"] == "feishu_transcript" and random.Random(it["key"] + "s").random() < 0.5
    done = {}
    if os.path.exists(args.out):
        for line in open(args.out, encoding="utf-8"):
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("ok"):
                done[r["key"]] = r
    todo = [it for it in ctx.items if it["key"] not in done and not it.get("copy_of")]
    if args.only:
        pre = tuple(args.only.split(","))
        todo = [it for it in todo if it["key"].startswith(pre)]
    if args.limit:
        todo = todo[:args.limit]
    eps = [Endpoint(s) for s in args.endpoint]
    long_ok = set(args.long_only.split(",")) if args.long_only else {e.name for e in eps}
    # continuity: up to two earlier short items of the same first event, captured >= 12h before
    by_event = defaultdict(list)
    for it in ctx.items:
        if len(it["matters"]) == 1 and not it["fmt"].endswith("transcript") and it["fmt"] not in ("pdf", "screenshot") \
                and not it.get("copy_of") and not it["noise"]:
            by_event[it["matters"][0]["event"]].append(it)
    deps = {}
    for it in todo:
        if len(it["matters"]) != 1 or it["noise"] or it["fmt"].endswith("transcript"):
            deps[it["key"]] = []
            continue
        t = datetime.fromisoformat(it["t"])
        prev = [p for p in by_event[it["matters"][0]["event"]] if datetime.fromisoformat(p["t"]) <= t - timedelta(hours=12)]
        deps[it["key"]] = [p["key"] for p in prev[-2:]]
    results = dict(done)
    out_lock = threading.Lock()
    fh = open(args.out, "a", encoding="utf-8")
    cond = threading.Condition()
    pending = {it["key"]: it for it in todo}
    started = set()
    ep_rr = [0]

    def pick_ep(long_job: bool) -> Endpoint:
        cands = [e for e in eps if (not long_job or e.name in long_ok)]
        cands.sort(key=lambda e: e.inflight / e.conc)
        return cands[0]

    def run(it):
        rnd = random.Random(it["key"])
        prior = []
        for k in deps.get(it["key"], []):
            r = results.get(k)
            if r and r.get("text"):
                prior.append(r["text"])
        user, max_tok, long_job = build_prompt(ctx, it, prior)
        it["_prompt"] = allowed_text(ctx, it)
        rec = None
        best = None
        for attempt in range(3):
            ep = pick_ep(long_job)
            with ep.lock:
                ep.inflight += 1
            ep.sem.acquire()
            try:
                temp = (0.65 if long_job else args.temperature) if attempt == 0 else 0.6
                raw, meta = ep.chat(SYSTEM, user, max_tok, temp)
            except Exception as ex:  # noqa: BLE001
                with ep.lock:
                    ep.fail += 1
                meta, raw = {"error": repr(ex)[:300]}, ""
            finally:
                ep.sem.release()
                with ep.lock:
                    ep.inflight -= 1
            if not raw:
                rec = {"key": it["key"], "ok": False, "node": ep.name, "attempt": attempt, "meta": meta, "problems": ["empty"]}
                time.sleep(2)
                continue
            res, problems = process(ctx, it, raw, rnd)
            rec = {"key": it["key"], "node": ep.name, "model": ep.model, "attempt": attempt, "meta": meta, "raw": raw,
                   "problems": problems, "ok": res is not None and not any(p.startswith(("new facts", "too few", "bad json", "no subject", "table", "card", "design", "refusal"))
                                                    or (p.startswith("offplan") and not long_job) for p in problems)}
            if res:
                rec.update(res)
            if rec["ok"]:
                break
            if res is not None and (best is None or len(problems) < len(best["problems"])):
                best = rec
        if not rec["ok"] and best is not None:
            best["ok"] = True
            best["accepted_with_problems"] = True
            rec = best
        with out_lock:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
        with cond:
            results[it["key"]] = rec
            cond.notify_all()
        return rec

    total_conc = sum(e.conc for e in eps)
    todo_keys = {i["key"] for i in todo}
    t_start = time.time()
    n_done = [0]
    with ThreadPoolExecutor(max_workers=total_conc + 2) as pool:
        futs = []
        while pending:
            with cond:
                ready = [k for k in pending if all(d not in todo_keys or d in results for d in deps[k])]
                slots = total_conc + 4 - (len(started) - sum(1 for k in started if k in results))
                if not ready or slots <= 0:
                    cond.wait(timeout=2)
                    continue
                # long jobs first so they do not trail at the end
                ready.sort(key=lambda k: (0 if pending[k]["fmt"].endswith("transcript") or pending[k]["fmt"] == "pdf" else 1, pending[k]["t"]))
                for k in ready[:slots]:
                    it = pending.pop(k)
                    started.add(k)
                    futs.append(pool.submit(run, it))
            finished = sum(1 for k in started if k in results)
            if finished // 50 > n_done[0]:
                n_done[0] = finished // 50
                el = time.time() - t_start
                print(f"[{el:6.0f}s] {finished}/{len(todo)} done; " + " ".join(f"{e.name}:{e.tokens}tok/{e.calls}c/f{e.fail}" for e in eps), file=sys.stderr, flush=True)
        for f in futs:
            f.result()
    el = time.time() - t_start
    stats = {"wall_secs": round(el, 1), "items": len(todo), "nodes": {}}
    for e in eps:
        span = (e.last - e.first) if e.first and e.last else 0
        stats["nodes"][e.name] = {"model": e.model, "calls": e.calls, "failures": e.fail, "completion_tokens": e.tokens,
                                  "active_secs": round(span, 1), "agg_tok_per_s": round(e.tokens / span, 1) if span else None,
                                  "concurrency": e.conc}
    stats["total_completion_tokens"] = sum(e.tokens for e in eps)
    stats["agg_tok_per_s"] = round(stats["total_completion_tokens"] / el, 1) if el else None
    print(json.dumps(stats, ensure_ascii=False, indent=1), file=sys.stderr)
    if args.stats:
        json.dump(stats, open(args.stats, "w"), ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
