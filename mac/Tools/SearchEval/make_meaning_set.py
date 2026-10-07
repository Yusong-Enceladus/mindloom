#!/usr/bin/env python3
"""Builds the meaning search set on the synthetic demo library (v12 search, B4 §4.1).

Queries that describe a matter in other words, the way someone half remembers
it (「房子到期续租涨价」 for the rent renewal), with the records that should come
back taken from the scenario's own labels (every item of that matter), never
from a search engine. Plus queries about things the library does not hold:
nothing should be shown for them.

Synthetic data only (the lab scenario, invented people and words, dates shifted
by +7 days); the set holds queries and opaque record IDs, no record text.

    make_meaning_set.py --db <clone>/history.sqlite \
        --scenario <spark repo>/eval/scenarios/scale-lab/scenario.json \
        --out Corpus/product-synthetic/search-meaning-v1.json

Categories:
  paraphrase  a matter in other words            -> the matter's records
  mixed       the same, Chinese and English mixed -> the matter's records
  none        something the library never mentions -> nothing
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import unicodedata

NOW = "2026-10-02T12:00:00+08:00"
SHIFT_DAYS = 7

# (query, matter) — written without the matter's own key words where a person
# would plausibly not remember them.
PARAPHRASE = [
    ("双臂长时程操作那篇稿子交上去没有", "E01"),
    ("会议论文全文提交的截止", "E01"),
    ("期刊让大改的那篇回复写到哪了", "E02"),
    ("审稿人第二轮意见谁来答", "E02"),
    ("反驳审稿意见有字数限制", "E03"),
    ("抓取扩散那篇被录用了吗", "E03"),
    ("机器人折衣服做了多少次成功", "E04"),
    ("毛巾和袋子的真机结果", "E04"),
    ("带触感的手抓鸡蛋和草莓", "E05"),
    ("借来的样机装在移动底盘上做对比", "E05"),
    ("四台机器上跑对比方法的结果表", "E06"),
    ("三个随机种子的基准测试", "E06"),
    ("和外校老师合作采数据的协议盖章", "E07"),
    ("一千条带触觉的演示采了多少", "E07"),
    ("周四晚上论文分享我讲的那次", "E08"),
    ("下一轮谁来讲论文", "E08"),
    ("出差的钱报下来没有", "E09"),
    ("深圳开会的高铁和住宿", "E09"),
    ("买机械手和测力的东西花了多少钱", "E10"),
    ("采购的东西到了没有，付款的单子交给谁", "E10"),
    ("显卡怎么分配，每人一次能用多久", "E11"),
    ("十月份的计算资源要提前登记", "E11"),
    ("比赛做的那个离线记实验的小工具", "E12"),
    ("复赛要去杭州现场", "E12"),
    ("上海那边的研究实习要不要去", "E13"),
    ("实习去报到的日子改了", "E13"),
    ("\u5E08\u5144公司让我去兼职做算法", "E14"),
    ("暑假去另一家公司实习和上海那个冲突", "E14"),
    ("腰不舒服去医院拍片子", "E15"),
    ("每周两次的康复治疗", "E15"),
    ("房子到期续租涨价", "E16"),
    ("房东在外地签合同改了日子", "E16"),
    ("给本科生的课出作业和改作业", "E17"),
    ("自动打分的脚本", "E17"),
    ("博士阶段的考核汇报材料", "E18"),
    ("考核答辩推迟到哪天", "E18"),
    ("代码去掉作者信息再上传", "E19"),
    ("真机视频和附录打包", "E19"),
    ("给来参观的本科生做展示", "E20"),
    ("学院开放那天现场叠衣服", "E20"),
    ("带的那个本科生要推荐信", "E21"),
    ("新来的学生开门禁和集群账号", "E21"),
    ("去新加坡开会的注册费", "E22"),
    ("出国开会学校审批和资助", "E22"),
]
MIXED = [
    ("NeurCon 那篇 paper 的 deadline", "E01"),
    ("TES major revision 回复信", "E02"),
    ("rebuttal 窗口什么时候关", "E03"),
    ("folding 实验 success rate", "E04"),
    ("tactile gripper 抓鸡蛋", "E05"),
    ("baseline 结果 table", "E06"),
    ("data agreement 盖章", "E07"),
    ("reading group 我 present 的那篇", "E08"),
    ("travel reimbursement 到账", "E09"),
    ("GPU 排期 sheet", "E11"),
    ("hackathon demo video", "E12"),
    ("internship offer 回复", "E13"),
    ("lower back pain 理疗", "E15"),
    ("rent 续签 deposit", "E16"),
    ("TA 作业 grading", "E17"),
    ("supplementary material upload", "E19"),
    ("open day demo poster", "E20"),
    ("camera ready 和 early bird", "E22"),
]
NONE = ["滑雪装备买哪个牌子", "猫咪打疫苗", "股票分红到账", "婚礼请柬设计", "厨房装修瓷砖",
        "钢琴考级曲目", "高考志愿填报", "健身房年卡退费", "咖啡机除垢", "驾照科目二预约"]


def norm(text):
    return unicodedata.normalize("NFKC", text or "").lower()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    root = os.path.dirname(os.path.abspath(args.db))
    if not os.path.exists(os.path.join(root, "SYNTHETIC_DATA_ROOT")):
        sys.exit("refusing: no SYNTHETIC_DATA_ROOT next to the database")
    if any(f"Application Support/{name}" in os.path.abspath(args.db) for name in ("Mindloom", "bestASR")):
        sys.exit("refusing: that is a real library")

    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rows = db.execute("""
        SELECT s.id, s.created_at,
               COALESCE((SELECT content FROM transcript_revisions tr WHERE tr.session_id = s.id
                         ORDER BY CASE WHEN tr.kind IN ('final','userEdit') THEN 1 ELSE 0 END DESC,
                                  tr.created_at DESC LIMIT 1), '')
        FROM sessions s JOIN dictation_snapshots d ON d.session_id = s.id
        LEFT JOIN user_item_details u ON u.session_id = s.id
        WHERE d.phase <> 'cancelled' AND u.parent_session_id IS NULL""").fetchall()
    records = [{"id": r[0].upper(), "t": r[1], "text": norm(r[2])} for r in rows]

    # Scenario labels by time (+7 days), the text breaking ties (as make_demo_set.py).
    scenario = json.load(open(args.scenario))
    by_time = {}
    for record in records:
        by_time.setdefault(round(record["t"]), []).append(record)
    matched = 0
    for item in scenario["items"]:
        t = round(datetime.datetime.fromisoformat(item["t"]).timestamp() + SHIFT_DAYS * 86400)
        candidates = by_time.get(t, [])
        if len(candidates) > 1:
            head = norm(item.get("text") or "")[:24]
            candidates = [c for c in candidates if c["text"].startswith(head)] or candidates[:0]
        if len(candidates) == 1:
            candidates[0]["events"] = set(item.get("events") or [])
            matched += 1

    queries = []

    def add(category, query, event):
        relevant = sorted(r["id"] for r in records if event in r.get("events", set()))
        if event and not relevant:
            sys.exit(f"no records for {event}")
        queries.append({"id": f"{category}-{sum(q['category'] == category for q in queries) + 1:02d}",
                        "category": category, "query": query, "relevant": relevant})

    for query, event in PARAPHRASE:
        add("paraphrase", query, event)
    for query, event in MIXED:
        add("mixed", query, event)
    for query in NONE:
        add("none", query, None)

    out = {
        "version": 1,
        "library": "mindloom-demo v11 preview-root: synthetic lab scenario, dates shifted +7 days",
        "library_records": len(records),
        "labelled_records": matched,
        "now": NOW,
        "time_zone": "Asia/Singapore",
        "owner_names": [scenario["people"][0]["display_name"]] + scenario["people"][0].get("aliases", [])[:4],
        "metrics": "relevant = every record of the matter (scenario labels); recall@10 = relevant in the top 10 / min(10, relevant); none: nothing should be shown",
        "queries": queries,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{len(queries)} queries over {len(records)} records ({matched} labelled)")


if __name__ == "__main__":
    main()
