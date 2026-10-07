#!/usr/bin/env python3
"""Builds the search evaluation set on the synthetic demo library (B4 §4.1).

200 queries, 10 categories x 20, each with the records that should come back,
judged from the library's own text and the scenario's labels, never from the
search engine. Synthetic data only: the demo library is the lab scenario
(`<spark repo>/eval/scenarios/scale-lab`, invented people and
words, dates shifted by +7 days); the set holds queries and opaque record IDs,
no record text.

    make_demo_set.py --db <clone>/history.sqlite \
        --scenario <spark repo>/eval/scenarios/scale-lab/scenario.json \
        --out Corpus/product-synthetic/search-demo-v1.json

Run it on a clone (cp -c -R) of the demo root, never on a real library: it
refuses a database without the SYNTHETIC_DATA_ROOT marker next to it.

Categories (query -> what counts as a hit):
  exact      a word as written                -> records containing it
  two_char   a two-character word             -> records containing it
  spaced     a word with a space inside       -> records containing the word
  variant    traditional / full-width / case  -> records containing the plain word
  homophone  a homophone typo (pinyin; some also in the dictionary)
                                              -> records containing the right word
  mixed      Chinese and English together     -> records containing both
  person     a person (and a word)            -> records with that person and the word
  source     a source (and a word)            -> records from that source (with the word)
  time       a time (and a word)              -> records of that time (with the word)
  question   a question in plain words        -> records containing its content words
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import unicodedata

NOW = "2026-10-02T12:00:00+08:00"
SG = datetime.timezone(datetime.timedelta(hours=8))
SHIFT_DAYS = 7

EXACT = ["推荐信", "补充材料", "匿名代码", "中期考核", "读书会", "差旅", "研讨会", "力传感器", "排卡", "黑客松",
         "腰疼", "理疗", "助教", "开放日", "审稿人", "显存", "标注", "组委会", "答辩", "大修"]
TWO = ["实习", "面试", "续约", "房租", "批改", "签证", "机票", "酒店", "参会", "投稿",
       "房东", "押金", "合同", "发票", "入职", "海报", "教务", "医院", "康复", "报价"]
SPACED = [("推荐 信", "推荐信"), ("补充 材料", "补充材料"), ("中期 考核", "中期考核"), ("读 书会", "读书会"),
          ("力 传感器", "力传感器"), ("黑客 松", "黑客松"), ("开放 日", "开放日"), ("审稿 人", "审稿人"),
          ("数据 集", "数据集"), ("组委 会", "组委会"), ("叠 衣服", "叠衣服"), ("真 机", "真机"),
          ("仿 真", "仿真"), ("触 觉", "触觉"), ("夹 爪", "夹爪"), ("显 存", "显存"), ("匿名 代码", "匿名代码"),
          ("Grip Diff", "gripdiff"), ("Robo Prior", "roboprior"), ("Neur Con", "neurcon")]
VARIANT = [("推薦信", "推荐信"), ("補充材料", "补充材料"), ("匿名代碼", "匿名代码"), ("讀書會", "读书会"),
           ("研討會", "研讨会"), ("開放日", "开放日"), ("審稿人", "审稿人"), ("數據集", "数据集"),
           ("組委會", "组委会"), ("答辯", "答辩"), ("報價", "报价"), ("發票", "发票"), ("實習", "实习"),
           ("面試", "面试"), ("機票", "机票"), ("ＧｒｉｐＤｉｆｆ", "gripdiff"), ("ＣｏＲＡ", "cora"),
           ("GRIPDIFF", "gripdiff"), ("roboprior", "roboprior"), ("NEURCON", "neurcon")]
# (typo, the right word, also in the synthetic dictionary as how it was heard)
HOMOPHONE = [("推见信", "推荐信", False), ("补冲材料", "补充材料", False), ("中期考合", "中期考核", False),
             ("读书汇", "读书会", True), ("研讨汇", "研讨会", False), ("力传感气", "力传感器", False),
             ("黑克松", "黑客松", True), ("腰腾", "腰疼", False), ("理聊", "理疗", False),
             ("助叫", "助教", False), ("开方日", "开放日", True), ("审搞人", "审稿人", False),
             ("显村", "显存", False), ("标住", "标注", False), ("组委汇", "组委会", False),
             ("答变", "答辩", True), ("续月", "续约", False), ("久店", "酒店", False),
             ("签正", "签证", False), ("发漂", "发票", True)]
MIXED = [("GripDiff 消融", ["gripdiff", "消融"]), ("Twin-7叠衣服", ["twin-7", "叠衣服"]),
         ("RoboPrior 返修", ["roboprior", "返修"]), ("NeurCon摘要", ["neurcon", "摘要"]),
         ("CoRA rebuttal", ["cora", "rebuttal"]), ("A800 排卡", ["a800", "排卡"]),
         ("Spark 基线", ["spark", "基线"]), ("SkillKnit补充材料", ["skillknit", "补充材料"]),
         ("TG-2 夹爪", ["tg-2", "夹爪"]), ("VLA-7B 显存", ["vla-7b", "显存"]),
         ("TouchFold 数据集", ["touchfold", "数据集"]), ("FlowPolicy 基线", ["flowpolicy", "基线"]),
         ("B203 预约", ["b203", "预约"]), ("OOM 显存", ["oom", "显存"]), ("AoE 截止", ["aoe", "截止"]),
         ("baseline 消融", ["baseline", "消融"]), ("checkpoint 仓库", ["checkpoint", "仓库"]),
         ("BenchNote 黑客松", ["benchnote", "黑客松"]), ("PG-80 报价", ["pg-80", "报价"]),
         ("Twin-7 真机", ["twin-7", "真机"])]
# (query, person display name, word or None)
PERSON = [("孟凡 叠衣服", "孟凡", "叠衣服"), ("孟工 Twin-7", "孟凡", "twin-7"), ("宋雨桐 叠衣服", "宋雨桐", "叠衣服"),
          ("高原 基线", "高原", "基线"), ("周明澜 投稿", "周明澜", "投稿"), ("刘慧 报销", "刘慧", "报销"),
          ("陆思成 三面", "陆思成", "三面"), ("程远舟 触觉", "程远舟", "触觉"), ("江屿 深衡", "江屿", "深衡"),
          ("许嘉禾 标注", "许嘉禾", "标注"), ("何静 中期考核", "何静", "中期考核"), ("欧阳 黑客松", "欧阳蕾", "黑客松"),
          ("韩策 Twin-7", "韩策", "twin-7"), ("宋雨桐 rebuttal", "宋雨桐", "rebuttal"),
          ("高原 Spark", "高原", "spark"), ("孟凡", "孟凡", None), ("陆思成", "陆思成", None),
          ("程远舟", "程远舟", None), ("许嘉禾", "许嘉禾", None), ("何静", "何静", None)]
# (query, source names, scenario kind or None, word or None)
SOURCE = [("微信 报价", ["微信"], None, "报价"), ("邮件 推荐信", ["邮件"], None, "推荐信"),
          ("腾讯会议 基线", ["腾讯会议"], None, "基线"), ("口述 叠衣服", ["Fn 口述"], "dictation", "叠衣服"),
          ("Claude rebuttal", ["Claude"], None, "rebuttal"), ("Codex 显存", ["Codex"], None, "显存"),
          ("飞书 黑客松", ["飞书", "飞书妙记"], None, "黑客松"), ("企业微信 报销", ["企业微信"], None, "报销"),
          ("终端 OOM", ["终端"], None, "oom"), ("飞书妙记 触觉", ["飞书妙记"], None, "触觉"),
          ("Zoom rebuttal", ["Zoom"], None, "rebuttal"), ("邮件 offer", ["邮件"], None, "offer"),
          ("微信里的房东", ["微信"], None, "房东"), ("口述 实习", ["Fn 口述"], "dictation", "实习"),
          ("微信", ["微信"], None, None), ("腾讯会议", ["腾讯会议"], None, None), ("邮件", ["邮件"], None, None),
          ("口述", ["Fn 口述"], "dictation", None), ("Claude", ["Claude"], None, None), ("飞书妙记", ["飞书妙记"], None, None)]
# (query, start day, end day (exclusive), word or None); now = 2026-10-02
TIME = [("上周", "2026-09-21", "2026-09-28", None), ("上上周", "2026-09-14", "2026-09-21", None),
        ("9月25日", "2026-09-25", "2026-09-26", None), ("9月10号", "2026-09-10", "2026-09-11", None),
        ("8月", "2026-08-01", "2026-09-01", None), ("上周三", "2026-09-23", "2026-09-24", None),
        ("上周 报价", "2026-09-21", "2026-09-28", "报价"), ("上周 叠衣服", "2026-09-21", "2026-09-28", "叠衣服"),
        ("上上周 rebuttal", "2026-09-14", "2026-09-21", "rebuttal"), ("8月 报销", "2026-08-01", "2026-09-01", "报销"),
        ("9月 推荐信", "2026-09-01", "2026-10-01", "推荐信"), ("最近两周 基线", "2026-09-19", "2026-10-03", "基线"),
        ("上周五 组会", "2026-09-25", "2026-09-26", "组会"), ("9月18日 投稿", "2026-09-18", "2026-09-19", "投稿"),
        ("9月 开放日", "2026-09-01", "2026-10-01", "开放日"), ("上周 腰疼", "2026-09-21", "2026-09-28", "腰疼"),
        ("8月 读书会", "2026-08-01", "2026-09-01", "读书会"), ("九月 黑客松", "2026-09-01", "2026-10-01", "黑客松"),
        ("上上周 Twin-7", "2026-09-14", "2026-09-21", "twin-7"), ("最近一周 rebuttal", "2026-09-26", "2026-10-03", "rebuttal")]
QUESTION = [("实习什么时候入职", ["实习", "入职"]), ("推荐信是谁写的", ["推荐信"]),
            ("腰疼在哪个医院看的", ["腰疼", "医院"]), ("读书会我领读哪篇", ["读书会", "领读"]),
            ("中期考核什么时候答辩", ["中期考核", "答辩"]), ("续约的合同签了吗", ["续约", "合同"]),
            ("差旅报销交给谁", ["差旅", "报销"]), ("黑客松的海报做好了没有", ["黑客松", "海报"]),
            ("开放日要演示什么", ["开放日", "演示"]), ("返修的审稿意见有哪些", ["返修", "审稿意见"]),
            ("力传感器的报价多少", ["力传感器", "报价"]), ("A800排卡排到几号", ["a800", "排卡"]),
            ("匿名代码传了吗", ["匿名代码"]), ("叠衣服的成功率多少", ["叠衣服", "成功率"]),
            ("助教作业怎么批改", ["作业", "批改"]), ("显存不够怎么办", ["显存"]),
            ("签证材料准备了吗", ["签证", "材料"]), ("理疗约在哪天", ["理疗"]),
            ("组委会说的截止是几号", ["组委会", "截止"]), ("基线跑完了吗", ["基线"])]


def norm(text):
    return unicodedata.normalize("NFKC", text or "").lower()


def day(text):
    return datetime.datetime.fromisoformat(text).replace(tzinfo=SG).timestamp()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    root = os.path.dirname(os.path.abspath(args.db))
    if not os.path.exists(os.path.join(root, "SYNTHETIC_DATA_ROOT")):
        sys.exit("refusing: no SYNTHETIC_DATA_ROOT next to the database")
    if any(f"Application Support/{name}/" in os.path.abspath(args.db) for name in ("Mindloom", "bestASR")):
        sys.exit("refusing: that is a real library")

    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rows = db.execute("""
        SELECT s.id, s.created_at, COALESCE(m.source_display_name, ''),
               COALESCE((SELECT content FROM transcript_revisions tr WHERE tr.session_id = s.id
                         ORDER BY CASE WHEN tr.kind IN ('final','userEdit') THEN 1 ELSE 0 END DESC,
                                  tr.created_at DESC LIMIT 1), '')
               || ' ' || COALESCE((SELECT group_concat(output_text, ' ') FROM derived_text_revisions dt
                                   WHERE dt.session_id = s.id AND dt.state = 'current'), ''),
               COALESCE(m.title, '')
        FROM sessions s JOIN dictation_snapshots d ON d.session_id = s.id
        LEFT JOIN session_metadata m ON m.session_id = s.id
        LEFT JOIN user_item_details u ON u.session_id = s.id
        WHERE d.phase <> 'cancelled' AND u.parent_session_id IS NULL""").fetchall()
    records = [{"id": r[0].upper(), "t": r[1], "source": r[2], "text": norm(r[3])} for r in rows]

    # Scenario labels by time (+7 days), the text breaking ties.
    scenario = json.load(open(args.scenario))
    people = {p["person_id"]: p for p in scenario["people"]}
    by_time = {}
    for record in records:
        by_time.setdefault(round(record["t"]), []).append(record)
    for item in scenario["items"]:
        t = round(datetime.datetime.fromisoformat(item["t"]).timestamp() + SHIFT_DAYS * 86400)
        candidates = by_time.get(t, [])
        if len(candidates) > 1:
            head = norm(item.get("text") or "")[:24]
            candidates = [c for c in candidates if c["text"].startswith(head)] or candidates[:0]
        if len(candidates) == 1:
            candidates[0]["persons"] = {people[p]["display_name"] for p in item.get("persons", [])}
            candidates[0]["kind"] = item.get("kind")

    # Person spellings as the library knows them (the organizer's people).
    spellings = {}
    for (payload,) in db.execute("SELECT CAST(payload_json AS TEXT) FROM remote_organizer_persons"):
        person = json.loads(payload)
        name = person.get("display_name") or ""
        spellings.setdefault(name, set()).update([name] + list(person.get("aliases") or []))

    def having(*words):
        return [r["id"] for r in records if all(norm(w) in r["text"] for w in words)]

    queries = []

    def add(category, query, relevant, note=None):
        relevant = sorted(set(relevant))
        if not relevant:
            sys.exit(f"no relevant records for {category} 「{query}」")
        entry = {"id": f"{category}-{sum(q['category'] == category for q in queries) + 1:02d}",
                 "category": category, "query": query, "relevant": relevant}
        if note:
            entry["note"] = note
        queries.append(entry)

    for word in EXACT:
        add("exact", word, having(word))
    for word in TWO:
        add("two_char", word, having(word))
    for query, word in SPACED:
        add("spaced", query, having(word))
    for query, word in VARIANT:
        add("variant", query, having(word))
    for typo, word, _ in HOMOPHONE:
        add("homophone", typo, having(word) + having(typo))
    for query, words in MIXED:
        add("mixed", query, having(*words))
    for query, name, word in PERSON:
        names = [norm(s) for s in spellings.get(name, {name}) if len(s) >= 2]
        relevant = [r["id"] for r in records
                    if (name in r.get("persons", set()) or any(n in r["text"] for n in names))
                    and (word is None or norm(word) in r["text"])]
        add("person", query, relevant)
    for query, names, kind, word in SOURCE:
        relevant = [r["id"] for r in records
                    if (r["source"] in names or (kind and r.get("kind") == kind))
                    and (word is None or norm(word) in r["text"])]
        add("source", query, relevant)
    for query, start, end, word in TIME:
        a, b = day(start), day(end)
        relevant = [r["id"] for r in records
                    if a <= r["t"] < b and (word is None or norm(word) in r["text"])]
        add("time", query, relevant)
    for query, words in QUESTION:
        add("question", query, having(*words))

    out = {
        "version": 1,
        "library": "mindloom-demo v11 preview-root: synthetic lab scenario, dates shifted +7 days",
        "library_records": len(records),
        "now": NOW,
        "time_zone": "Asia/Singapore",
        "owner_names": [scenario["people"][0]["display_name"]] + scenario["people"][0].get("aliases", [])[:4],
        "lexicon": [{"canonical": word, "spoken": [typo]} for typo, word, listed in HOMOPHONE if listed],
        "metrics": "recall@10 = relevant in the top 10 / min(10, relevant); MRR = 1 / rank of the first relevant (0 past 100)",
        "queries": queries,
    }
    counts = {}
    for q in queries:
        counts[q["category"]] = counts.get(q["category"], 0) + 1
    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{len(queries)} queries over {len(records)} records: {counts}")


if __name__ == "__main__":
    main()
