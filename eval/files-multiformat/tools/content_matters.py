"""Hand-authored, fully invented lab week (清屿大学 视觉智能实验室, 2026-10-12 .. 10-17).

Six matters (events), 43 files across all 33 file types, 7 chat pastes. Every name, company, number,
e-mail address (example.* domains) and phone number (555 exchange) is invented.
dev matters: ev_talk, ev_annot (+ the canteen menu); test matters: ev_paper, ev_gpu, ev_defense, ev_collab.
"""

from __future__ import annotations


def q(question, answer, match="contains", accept=None, tol=None, derived=False):
    """One QA pair. derived=True: the answer is counted/inferred from the file rather than written in it."""
    d = {"q": question, "a": answer, "match": match}
    if accept:
        d["accept"] = accept
    if tol is not None:
        d["tol"] = tol
    if derived:
        d["derived"] = True
    return d


LAB = "清屿大学计算机学院 视觉智能实验室"

PEOPLE = [
    {"person_id": "p_owner", "display_name": "沈知遥", "is_owner": True, "role": "视觉智能实验室负责人、副教授（本人）",
     "aliases": ["我", "沈老师", "知遥", "Zhiyao", "Zhiyao Shen", "Prof. Shen"]},
    {"person_id": "p_he", "display_name": "贺一鸣", "role": "博士三年级，LoomNet 论文一作", "aliases": ["一鸣", "Yiming"]},
    {"person_id": "p_lin", "display_name": "林晓棠", "role": "硕士二年级", "aliases": ["晓棠", "小林"]},
    {"person_id": "p_gu", "display_name": "顾青", "role": "实验室秘书（采购、报销）", "aliases": ["顾老师", "青姐"]},
    {"person_id": "p_tao", "display_name": "陶然", "role": "博士后，管理 GPU 集群", "aliases": ["陶博"]},
    {"person_id": "p_ma", "display_name": "马骏", "role": "澄川科技 项目经理", "aliases": ["马经理", "马总"]},
    {"person_id": "p_park", "display_name": "Elena Park", "role": "Northbridge University 教授，来访讲者",
     "aliases": ["Elena", "Prof. Park", "Park 教授"]},
    {"person_id": "p_zhou", "display_name": "周蔓", "role": "数芽标注 客户经理", "aliases": ["周经理", "蔓蔓"]},
    {"person_id": "p_xu", "display_name": "许卫东", "role": "教授，开题答辩委员会主席", "aliases": ["许老师"]},
    {"person_id": "p_fang", "display_name": "方敏", "role": "副教授，开题答辩委员", "aliases": ["方老师"]},
    {"person_id": "p_qian", "display_name": "钱立", "role": "恒算科技 销售经理", "aliases": ["钱经理"]},
    {"person_id": "p_song", "display_name": "宋雨桐", "role": "学院科研办，讲座接待", "aliases": ["雨桐", "宋老师"]},
]

EVENTS = [
    {"event_id": "ev_paper", "kind": "main", "title": "LoomNet 论文投稿 ICVL 2027",
     "summary": "贺一鸣一作的 LoomNet 投 ICVL 2027：摘要 10/16、全文 10/23 截止，run42 平均准确率 78.4。", "split": "test"},
    {"event_id": "ev_gpu", "kind": "main", "title": "8 卡 GPU 服务器采购（2 台）",
     "summary": "向恒算科技采购 2 台 HS-G8820，总价 119.6 万，合同 HS-2026-1017，第一台 10/16 到货，第二台 10/23。", "split": "test"},
    {"event_id": "ev_defense", "kind": "main", "title": "林晓棠硕士开题答辩",
     "summary": "原定 10/14 14:00 B312，因许卫东有课改到 10/15 14:00；结论通过，修改稿 10/25 前交。", "split": "test"},
    {"event_id": "ev_collab", "kind": "main", "title": "澄川科技横向项目（产线缺陷检测）",
     "summary": "合同 36 万分三期；v1.2 mAP 0.873；10/20 在苏州工厂中期验收，之后付第二期 18 万。", "split": "test"},
    {"event_id": "ev_talk", "kind": "main", "title": "Elena Park 教授来访讲座",
     "summary": "10/16 15:00 A101 讲座；10/15 晚到（航班延误到 22:40）；酒店确认号 QYH-88213。", "split": "dev"},
    {"event_id": "ev_annot", "kind": "main", "title": "数芽标注外包（KitchenQA 视频问答）",
     "summary": "2 万条 × 1.8 元 = 3.6 万，4 批；第 1 批合格率 96.2% 验收通过付 9000 元；第 2 批 10/22 交。", "split": "dev"},
]

# ---------------------------------------------------------------------------------------------- files
# Each spec: key, type, filename, t (capture time), source_app, persons, events, split (from event), content, truth.

FILES: list[dict] = []


def F(**kw):
    FILES.append(kw)


# ============================== ev_paper (test) =================================================
F(key="paper_todo", type="md", filename="LoomNet投稿TODO.md", t="2026-10-12T09:20:00+08:00", source_app="Finder",
  persons=["p_he", "p_tao", "p_owner"], events=["ev_paper"],
  doc={"title": "LoomNet 投稿 TODO（ICVL 2027）", "lang": "zh",
       "front_matter": {"project": "LoomNet", "updated": "2026-10-12", "owner": "贺一鸣"},
       "blocks": [("h", "关键日期"),
                  ("kv", [("摘要截止", "2026年10月16日 23:59 AoE"), ("全文截止", "2026年10月23日 23:59 AoE"),
                          ("补充材料截止", "2026年10月30日"), ("页数限制", "正文 8 页（不含参考文献）")]),
                  ("h", "任务"),
                  ("ul", ["[ ] 贺一鸣：补完 memory_slots 消融（32/64/128），10月14日前",
                          "[ ] 陶然：预留 16 张卡跑最终实验（10月13日—10月20日）",
                          "[ ] 沈知遥：改写引言和相关工作，10月18日前",
                          "[x] 贺一鸣：LongVid-QA 主实验 run37（平均 76.9）"]),
                  ("h", "备注"),
                  ("p", "目标：在 LongVid-QA 上超过 baseline（75.3）至少 2 个点；本次投稿算力预算 2,000 GPU·时。")]},
  truth={"key_fields": {"摘要截止": "2026-10-16", "全文截止": "2026-10-23", "补充材料截止": "2026-10-30", "页数限制": "8页"},
         "numbers": [{"value": 8, "label": "页数限制"}, {"value": 75.3, "label": "baseline"}, {"value": 2000, "label": "算力预算 GPU·时"}],
         "qa": [q("全文截止日期是哪天？", "10月23日", accept=["2026-10-23", "10/23", "10-23"]),
                q("正文页数限制是多少页？", 8, "number"),
                q("谁负责改写引言和相关工作？", "沈知遥"),
                q("算力预算是多少 GPU·时？", 2000, "number")]})

_main = {"name": "主结果", "title": "LongVid-QA 主结果（run37）", "group_header": [(1, 3, "准确率 (%)")],
         "columns": ["方法", "短视频", "长视频", "平均", "参数量(M)"],
         "rows": [["Baseline-TR", 79.8, 70.8, {"f": "=AVERAGE(B4:C4)", "v": 75.3}, 312],
                  ["LoomNet (run37)", 81.2, 72.6, {"f": "=AVERAGE(B5:C5)", "v": 76.9}, 298],
                  ["LoomNet w/o memory", 78.6, 69.6, {"f": "=AVERAGE(B6:C6)", "v": 74.1}, 285]],
         "formats": {1: "dec1", 2: "dec1", 3: "dec1"}, "col_widths": [22, 10, 10, 10, 12]}
_abl = {"name": "消融", "columns": ["memory_slots", "准确率(%)", "显存(GB)", "相对 baseline"],
        "rows": [[32, 75.9, 38, {"f": "=B2-'主结果'!D4", "v": 0.6}],
                 [64, 76.9, 44, {"f": "=B3-'主结果'!D4", "v": 1.6}],
                 [128, 76.5, 57, {"f": "=B4-'主结果'!D4", "v": 1.2}]],
        "formats": {1: "dec1", 3: "dec1"}, "col_widths": [14, 12, 10, 14]}
_gpu = {"name": "算力统计", "title": "GPU·时统计（预算 2,000）", "columns": ["阶段", "实验", "卡数", "小时", "GPU·时"],
        "rows": [["调试", "run35 预实验", 8, 36, {"f": "=C3*D3", "v": 288}],
                 ["调试", "run36 调参", 8, 42, {"f": "=C4*D4", "v": 336}],
                 ["正式", "run37 主实验", 16, 48, {"f": "=C5*D5", "v": 768}],
                 ["正式", "消融 32/64/128", 8, 22, {"f": "=C6*D6", "v": 176}],
                 ["合计", "", None, None, {"f": "=SUM(E3:E6)", "v": 1568}],
                 ["剩余预算", "", None, None, {"f": "=2000-E7", "v": 432}]],
        "vmerge": [(0, 0, 1), (0, 2, 3)], "formats": {4: "num"}, "col_widths": [10, 18, 8, 8, 10]}
F(key="paper_xlsx", type="xlsx", filename="LoomNet消融实验_v3.xlsx", t="2026-10-12T14:05:00+08:00", source_app="微信",
  persons=["p_he"], events=["ev_paper"], sheets=[_main, _abl, _gpu], title="LoomNet 消融实验 v3",
  truth={"key_fields": {"baseline_avg": 75.3, "run37_avg": 76.9, "best_memory_slots": 64, "gpu_hours_used": 1568,
                        "gpu_hours_left": 432},
         "numbers": [{"value": 75.3, "label": "Baseline-TR 平均"}, {"value": 76.9, "label": "run37 平均"},
                     {"value": 74.1, "label": "w/o memory 平均"}, {"value": 1568, "label": "已用 GPU·时"},
                     {"value": 432, "label": "剩余预算"}],
         "qa": [q("run37 的平均准确率是多少？", 76.9, "number"),
                q("消融里 memory_slots 取多少最好？", 64, "number"),
                q("已经用了多少 GPU·时？", 1568, "number"),
                q("剩余预算还有多少 GPU·时？", 432, "number")],
         "notes": "3 个工作表；主结果有合并的“准确率 (%)”分组表头；平均、相对 baseline（跨表引用）、GPU·时 均为带缓存值的公式；算力统计的“阶段”列纵向合并。"})

F(key="paper_pptx", type="pptx", filename="组会汇报_1013_贺一鸣.pptx", t="2026-10-13T10:00:00+08:00", source_app="Finder",
  persons=["p_he", "p_owner", "p_tao"], events=["ev_paper", "ev_gpu"], tags=["multi_label"], title="LoomNet 进展汇报",
  slides=[{"title": "LoomNet 进展汇报", "subtitle": "贺一鸣 · 组会 2026-10-13"},
          {"title": "本周进展", "bullets": ["run37 主实验完成：LongVid-QA 平均 76.9%",
                                        "memory_slots 消融：64 最优（76.9%），128 显存 57GB",
                                        "run42 已启动：学习率 3e-4，预计 10月14日出结果"],
           "notes": "run42 用 cosine 学习率，warmup 2k 步"},
          {"title": "主结果对比", "image": True,
           "table": {"columns": ["方法", "平均准确率(%)"],
                     "rows": [["Baseline-TR", 75.3], ["LoomNet run37", 76.9], ["LoomNet w/o memory", 74.1]]}},
          {"title": "算力安排", "bullets": ["陶然预留 16 卡：10月13日—10月20日",
                                        "新服务器第一台预计 10月16日到货，用于补充材料实验",
                                        "已用 1,568 GPU·时，剩余 432"]},
          {"title": "风险与求助", "image": True,
           "bullets": ["长视频评测脚本偶发 OOM（batch 256 时）", "需要沈老师 10月18日前改完引言", "摘要提交截止 10月16日"]}],
  truth={"key_fields": {"run42_lr": "3e-4", "new_server_eta": "2026-10-16", "reserved_gpus": 16},
         "numbers": [{"value": 76.9, "label": "run37 平均"}, {"value": 1568, "label": "已用 GPU·时"}, {"value": 432, "label": "剩余"}],
         "qa": [q("run42 的学习率是多少？", "3e-4", "exact", accept=["0.0003", "3×10^-4"]),
                q("新服务器第一台预计哪天到货？", "10月16日", accept=["10/16", "2026-10-16"]),
                q("风险页里 OOM 出现在多大的 batch？", 256, "number"),
                q("主结果对比图里 w/o memory 的平均准确率是多少？", 74.1, "number")],
         "notes": "第 3、5 页是整页图片（无文本框），答案只在图里；第 2 页有演讲者备注。"})

F(key="paper_png", type="png", filename="loss曲线_run42.png", t="2026-10-13T16:40:00+08:00", source_app="微信",
  persons=["p_he"], events=["ev_paper"],
  visual={"style": "chart", "title": "run42 训练/验证 loss（LoomNet）", "kind": "line", "xlabels": ["2k", "6k", "10k", "14k", "18k"],
          "series": {"train": [1.84, 1.02, 0.71, 0.52, 0.44], "val": [1.91, 1.10, 0.76, 0.55, 0.412]},
          "notes": ["best val @ 18k: 0.412", "lr 3e-4 · cosine"], "ylabel": "loss"},
  truth={"key_fields": {"best_val_loss": 0.412, "best_step": "18k", "lr": "3e-4"},
         "numbers": [{"value": 0.412, "label": "最佳验证 loss"}],
         "qa": [q("最佳验证 loss 是多少？", 0.412, "number"), q("最佳验证 loss 出现在第几步？", "18k", accept=["18000", "1.8万"]),
                q("图里标注的学习率是多少？", "3e-4", accept=["0.0003"])]})

F(key="paper_json", type="json", filename="run42_result.json", t="2026-10-14T21:00:00+08:00", source_app="微信",
  persons=["p_he"], events=["ev_paper"],
  record={"run_id": "run42", "model": "LoomNet", "dataset": "LongVid-QA",
          "config": {"lr": 3e-4, "batch_size": 256, "memory_slots": 64, "schedule": "cosine", "warmup_steps": 2000,
                     "seed": 42, "gpus": 16},
          "results": {"test": {"short": 82.6, "long": 74.2, "avg": 78.4}, "baseline_avg": 75.3, "delta": 3.1},
          "gpu_hours": 352, "finished_at": "2026-10-14T20:37:00+08:00", "note": "合成数据"},
  truth={"key_fields": {"test_avg": 78.4, "delta": 3.1, "seed": 42, "gpu_hours": 352},
         "numbers": [{"value": 78.4, "label": "test avg"}, {"value": 3.1, "label": "delta"}, {"value": 352, "label": "GPU·时"}],
         "qa": [q("run42 在 test 上的平均准确率是多少？", 78.4, "number"), q("比 baseline 高多少个点？", 3.1, "number"),
                q("随机种子是多少？", 42, "number"), q("这次训练用了多少 GPU·时？", 352, "number")]})

F(key="paper_pdf", type="pdf", filename="LoomNet_draft_v5.pdf", t="2026-10-15T20:30:00+08:00", source_app="Finder",
  persons=["p_he", "p_owner"], events=["ev_paper"],
  doc={"title": "LoomNet: Weaving Memory for Long-Video Question Answering", "lang": "en", "author": "Anonymous",
       "subtitle": "Anonymous ICVL 2027 submission · Paper ID 4127 · Draft v5",
       "blocks": [("h", "Abstract"),
                  ("p", "Long videos overwhelm fixed-length context windows. We present LoomNet, a video question answering "
                        "model that weaves a small set of memory slots through the whole video. LoomNet reaches 78.4% average "
                        "accuracy on LongVid-QA, 3.1 points above the strongest baseline (75.3%), with 298M parameters."),
                  ("h", "1 Introduction"),
                  ("p", "Questions about long videos often depend on events that happened tens of minutes earlier. Existing "
                        "models either subsample frames or truncate the context. LoomNet instead keeps 64 memory slots that "
                        "are read and rewritten at every segment."),
                  ("p", "Our contributions are threefold: (i) a slot memory that is written once per segment and read by every "
                        "question token, (ii) a curriculum that grows the video length from 2 to 60 minutes, and (iii) a careful "
                        "ablation of memory size on LongVid-QA."),
                  ("h", "2 Related Work"),
                  ("p", "Long-video models fall into three families. Sampling methods keep a fixed number of frames and lose rare "
                        "events. Streaming methods compress past frames into a recurrent state, which drifts over long horizons. "
                        "Retrieval methods store every clip and fetch a few at question time, which is accurate but slow."),
                  ("p", "Memory-augmented transformers have been explored for text and for short clips. LoomNet differs in that "
                        "its slots are rewritten at every segment and are shared across all questions about the same video."),
                  ("h", "3 Method"),
                  ("p", "A video is cut into 10-second segments. Each segment is encoded by a frozen image encoder followed by a "
                        "4-layer temporal transformer. The memory holds 64 slots of width 1024; a gated cross-attention writes the "
                        "segment into the slots, and a second cross-attention lets question tokens read them."),
                  ("p", "Training minimises the answer cross-entropy plus a small slot-diversity penalty (weight 0.01). We train "
                        "for 18k steps with batch size 256, a cosine schedule, 2k warm-up steps and learning rate 3e-4."),
                  ("p", "At inference the memory is updated online, so answering a question about minute 55 costs the same as "
                        "answering one about minute 5. Peak memory stays at 44 GB for 60-minute videos."),
                  ("h", "4 Experiments"),
                  ("p", "LongVid-QA contains short (under 10 minutes) and long (10 to 60 minutes) videos with multiple-choice "
                        "questions. We report accuracy on the official test split."),
                  ("table", {"caption": "Table 1: Main results on LongVid-QA (accuracy, %).",
                             "columns": ["Method", "Short", "Long", "Avg"],
                             "rows": [["Baseline-TR", 79.8, 70.8, 75.3], ["LoomNet w/o memory", 78.6, 69.6, 74.1],
                                      ["LoomNet (ours)", 82.6, 74.2, 78.4]]}),
                  ("p", "Training used 16 GPUs for 22 hours (352 GPU-hours) with a cosine schedule and learning rate 3e-4."),
                  ("p", "Removing the memory costs 4.3 points on average, and most of the loss is on long videos (74.2 to 69.6)."),
                  ("h", "5 Conclusion"),
                  ("p", "A small, rewritable slot memory is enough to answer questions about hour-long videos at constant cost. "
                        "Future work will test LoomNet on egocentric recordings."),
                  ("p", "Synthetic document for evaluation only.")]},
  truth={"key_fields": {"paper_id": "4127", "avg_accuracy": 78.4, "params": "298M", "dataset": "LongVid-QA"},
         "numbers": [{"value": 4127, "label": "Paper ID"}, {"value": 78.4, "label": "avg"}, {"value": 298, "label": "params (M)"},
                     {"value": 352, "label": "GPU-hours"}],
         "qa": [q("What is the paper ID?", 4127, "number"), q("What average accuracy does LoomNet reach?", 78.4, "number"),
                q("How many parameters does LoomNet have (millions)?", 298, "number"),
                q("On which dataset is it evaluated?", "LongVid-QA"),
                q("In Table 1, what is the average accuracy of LoomNet w/o memory?", 74.1, "number")],
         "notes": "两页；Table 1 在第 2 页。"})

F(key="paper_mp4", type="mp4", filename="LoomNet进展_1016.mp4", t="2026-10-16T18:00:00+08:00", source_app="微信",
  persons=["p_he"], events=["ev_paper"], seconds=[3, 3, 3],
  slides=[{"title": "摘要已提交", "bullets": ["ICVL 2027 Paper ID #4127", "提交时间：10月15日 10:42"]},
          {"title": "主结果", "big": "78.4%", "bullets": ["比 baseline 高 3.1 个点", "run42 · memory_slots 64"]},
          {"title": "下一步", "bullets": ["全文截止 10月23日（AoE）", "补充材料 10月30日", "新服务器到货后跑长视频扩展实验"]}],
  truth={"key_fields": {"paper_id": "4127", "abstract_submitted": "2026-10-15 10:42", "full_deadline": "2026-10-23"},
         "numbers": [{"value": 4127, "label": "Paper ID"}, {"value": 78.4, "label": "主结果"}],
         "qa": [q("Paper ID 是多少？", 4127, "number"), q("摘要是几点提交的？", "10:42"),
                q("全文截止是哪天？", "10月23日", accept=["10/23", "2026-10-23"])],
         "notes": "无音轨；3 张幻灯片各 3 秒。"})

# ============================== ev_gpu (test) ===================================================
F(key="gpu_quote", type="docx", filename="恒算科技_GPU服务器报价单.docx", t="2026-10-12T10:30:00+08:00", source_app="邮件",
  persons=["p_qian", "p_owner"], events=["ev_gpu"],
  doc={"title": "GPU 服务器报价单", "lang": "zh", "letterhead": "恒算科技有限公司 · 报价编号 HQ-20261012-07",
       "blocks": [("kv", [("报价编号", "HQ-20261012-07"), ("客户", "清屿大学计算机学院 视觉智能实验室（沈知遥老师）"),
                          ("报价日期", "2026年10月12日"), ("联系人", "钱立 销售经理 · qianli@example.com")]),
                  ("h", "一、报价明细"),
                  ("table", {"columns": ["序号", "名称/配置", "数量", "单价（元）", "金额（元）"],
                             "rows": [[1, "HS-G8820 服务器（8×H20 96GB，2×64核CPU，1TB内存）", 2, 598000, 1196000],
                                      [2, "上门安装调试", 1, 0, 0], ["", "合计", "", "", 1196000]]}),
                  ("p", "合计人民币壹佰壹拾玖万陆仟元整（¥1,196,000），含13%增值税。"),
                  ("h", "二、商务条款"),
                  ("ul", ["质保：整机三年原厂保修，7×24小时响应",
                          "交货期：合同签订后分两批交付，第一台约10月16日，第二台约10月23日",
                          "付款方式：合同签订后预付30%，到货验收后付60%，质保金10%一年后支付",
                          "报价有效期：至2026年10月31日"])],
       "signature": "恒算科技有限公司 销售部"},
  truth={"key_fields": {"报价编号": "HQ-20261012-07", "单价": 598000, "合计": 1196000, "质保": "三年", "有效期": "2026-10-31"},
         "numbers": [{"value": 598000, "label": "单价"}, {"value": 1196000, "label": "合计"}],
         "qa": [q("单台报价多少元？", 598000, "number"), q("两台合计多少元？", 1196000, "number"),
                q("质保几年？", "三年", accept=["3年", "3 年"]), q("报价有效期到哪天？", "10月31日", accept=["2026-10-31"])]})

_cmp = {"name": "比价", "title": "8卡 GPU 服务器比价（2台）", "group_header": [(1, 2, "价格（元）"), (3, 4, "服务")],
        "columns": ["供应商", "单台报价", "2台合计", "保修（年）", "交货（工作日）"],
        "rows": [["恒算科技", 598000, {"f": "=B4*2", "v": 1196000}, 3, 15],
                 ["云岭数据", 624000, {"f": "=B5*2", "v": 1248000}, 3, 20],
                 ["北辰信息", 586000, {"f": "=B6*2", "v": 1172000}, 1, 10],
                 ["最低价", {"f": "=MIN(B4:B6)", "v": 586000}, {"f": "=MIN(C4:C6)", "v": 1172000}, None, None]],
        "formats": {1: "num", 2: "num"}, "col_widths": [12, 12, 14, 10, 14]}
_score = {"name": "评分", "columns": ["供应商", "价格分(40)", "服务分(40)", "交货分(20)", "总分"],
          "rows": [["恒算科技", 38, 38, 16, {"f": "=SUM(B2:D2)", "v": 92}],
                   ["云岭数据", 36, 36, 12, {"f": "=SUM(B3:D3)", "v": 84}],
                   ["北辰信息", 40, 20, 18, {"f": "=SUM(B4:D4)", "v": 78}]]}
_concl = {"name": "结论", "columns": ["项目", "内容"],
          "rows": [["推荐供应商", "恒算科技"], ["理由", "总分最高（92），三年保修"], ["经办", "顾青"],
                   ["最高分", {"f": "=MAX('评分'!E2:E4)", "v": 92}]]}
F(key="gpu_ods", type="ods", filename="GPU服务器三家比价.ods", t="2026-10-12T16:20:00+08:00", source_app="Finder",
  persons=["p_gu", "p_owner"], events=["ev_gpu"], sheets=[_cmp, _score, _concl], title="GPU 服务器三家比价",
  truth={"key_fields": {"推荐供应商": "恒算科技", "恒算总分": 92, "北辰单台": 586000, "云岭2台": 1248000},
         "numbers": [{"value": 1196000, "label": "恒算2台"}, {"value": 1248000, "label": "云岭2台"}, {"value": 586000, "label": "北辰单台"},
                     {"value": 92, "label": "恒算总分"}],
         "qa": [q("推荐哪家供应商？", "恒算科技"), q("北辰信息单台报价多少？", 586000, "number"),
                q("恒算科技总分多少？", 92, "number"), q("云岭数据两台合计多少元？", 1248000, "number")],
         "notes": "3 个工作表；合并的标题行和“价格/服务”分组表头；合计、MIN、SUM、跨表 MAX 均为带缓存值的公式。"})

F(key="gpu_odt", type="odt", filename="设备采购申请表_视觉智能实验室.odt", t="2026-10-13T09:40:00+08:00", source_app="Finder",
  persons=["p_owner", "p_gu"], events=["ev_gpu"],
  doc={"title": "清屿大学 大型仪器设备采购申请表", "lang": "zh",
       "blocks": [("kv", [("申请单位", "计算机学院 视觉智能实验室"), ("申请人", "沈知遥"), ("经办人", "顾青"),
                          ("申请日期", "2026年10月13日"), ("经费卡号", "KY-2026-0371"), ("设备名称", "8卡 GPU 服务器（HS-G8820）"),
                          ("数量", "2台"), ("预算金额", "1,196,000元"), ("采购方式", "三家比价后定点采购（附比价表）")]),
                  ("h", "用途说明"),
                  ("p", "用于长视频理解与多模态记忆方向的模型训练，支撑实验室论文投稿与横向项目实验。现有集群 16 卡长期满载。"),
                  ("h", "审批意见"), ("p", "（待学院审批）")]},
  truth={"key_fields": {"经费卡号": "KY-2026-0371", "预算金额": 1196000, "申请日期": "2026-10-13", "数量": 2},
         "numbers": [{"value": 1196000, "label": "预算金额"}, {"value": 2, "label": "数量"}],
         "qa": [q("经费卡号是什么？", "KY-2026-0371", "exact"), q("预算金额多少元？", 1196000, "number"),
                q("申请日期是哪天？", "10月13日", accept=["2026-10-13"]), q("申请采购几台？", 2, "number")]})

F(key="gpu_contract", type="pdf_scanned", filename="采购合同_盖章扫描件.pdf", t="2026-10-14T15:00:00+08:00", source_app="Finder",
  persons=["p_qian", "p_owner"], events=["ev_gpu"],
  doc={"title": "设备采购合同", "lang": "zh",
       "blocks": [("kv", [("合同编号", "HS-2026-1017"), ("甲方（买方）", "清屿大学"), ("乙方（卖方）", "恒算科技有限公司"),
                          ("签订日期", "2026年10月14日")]),
                  ("h", "第一条 标的"),
                  ("table", {"columns": ["名称", "型号", "数量", "单价（元）", "总价（元）"],
                             "rows": [["GPU服务器", "HS-G8820", 2, 598000, 1196000]]}),
                  ("h", "第二条 交付"),
                  ("p", "乙方分两批交付：第一台于2026年10月16日前送达甲方计算机楼机房，第二台于2026年10月23日前送达。"),
                  ("h", "第三条 付款"),
                  ("p", "合同签订后7日内甲方预付30%（358,800元）；每台到货验收合格后支付该台价款的60%；剩余10%作为质保金，验收满一年后支付。"),
                  ("h", "第四条 质保"), ("p", "整机质保三年，自验收合格之日起计算。质保期内乙方提供7×24小时电话支持，硬件故障4小时内响应、48小时内到场。"),
                  ("h", "第五条 验收"),
                  ("p", "每台设备到货后，甲方在5个工作日内完成开箱检查与72小时满载测试；测试通过即视为该台验收合格，双方签署验收单。"),
                  ("pagebreak",),
                  ("h", "第六条 违约责任"),
                  ("p", "乙方逾期交货的，每逾期一日按合同总价的0.05%（即598元）向甲方支付违约金，累计不超过合同总价的5%。"
                        "甲方逾期付款的，每逾期一日按应付未付金额的0.05%支付违约金。"),
                  ("h", "第七条 争议解决"),
                  ("p", "因本合同发生的争议，双方应友好协商；协商不成的，提交甲方所在地人民法院诉讼解决。"),
                  ("h", "第八条 其他"),
                  ("p", "本合同一式四份，甲方执三份，乙方执一份，自双方签字盖章之日起生效。附件：技术配置清单、报价单HQ-20261012-07。")],
       "signature": "乙方：恒算科技有限公司（盖章）", "stamp": "恒算科技"},
  truth={"key_fields": {"合同编号": "HS-2026-1017", "总价": 1196000, "预付款": 358800, "第一台": "2026-10-16", "第二台": "2026-10-23"},
         "numbers": [{"value": 1196000, "label": "总价"}, {"value": 358800, "label": "预付款"}],
         "qa": [q("合同编号是多少？", "HS-2026-1017", "exact"), q("预付款是多少元？", 358800, "number"),
                q("第二台最晚哪天送达？", "10月23日", accept=["2026-10-23"]), q("质保几年？", "三年", accept=["3年"]),
                q("乙方逾期交货每天的违约金是多少元？", 598, "number")],
         "notes": "纯图片 PDF（无文本层），两页，页面有倾斜、噪点和红色公章；违约条款与盖章在第 2 页。"})

_invoice_doc = {"title": "增值税专用发票（电子）", "lang": "zh",
                "blocks": [("kv", [("发票号码", "04417726"), ("开票日期", "2026年10月15日"), ("购买方", "清屿大学"),
                                   ("销售方", "恒算科技有限公司")]),
                           ("table", {"columns": ["货物名称", "规格型号", "数量", "金额（元）", "税率", "税额（元）"],
                                      "rows": [["GPU服务器", "HS-G8820", 1, "529,203.54", "13%", "68,796.46"]]}),
                           ("kv", [("价税合计（小写）", "¥598,000.00"), ("价税合计（大写）", "伍拾玖万捌仟元整")])]}
F(key="gpu_eml", type="eml", filename="Re_第一台服务器发货及发票.eml", t="2026-10-15T17:20:00+08:00", source_app="邮件",
  persons=["p_qian", "p_owner", "p_gu"], events=["ev_gpu"],
  email={"from": ("钱立", "qianli@example.com"), "to": [("沈知遥", "shenzy@example.org")],
         "cc": [("顾青", "guqing@example.org")], "date": "2026-10-15T17:20:00+08:00",
         "subject": "Re: 第一台服务器发货及发票", "message_id": "<hs-20261015-1720@example.com>",
         "body": "沈老师您好：\n\n第一台 HS-G8820 已于今天下午从苏州仓发出，物流单号 SF-HS-7730215，预计明天（10月16日）上午11点前送到计算机楼B1机房，请安排老师签收。\n\n"
                 "第一台的增值税专用发票已开具，发票号码 04417726，金额 598,000.00 元（含税），电子版见附件。第二台按合同10月23日前送达。\n\n"
                 "恒算科技 钱立\n（合成数据）\n\n> 在 2026年10月15日 09:05，沈知遥 写道：\n> 钱经理，第一台什么时候能到？发票请抄送顾青老师。",
         "attachments": [{"filename": "发票_04417726.pdf", "kind": "pdf", "doc": _invoice_doc}]},
  truth={"key_fields": {"物流单号": "SF-HS-7730215", "送达": "2026-10-16 11:00前", "发票号码": "04417726", "税额": 68796.46},
         "numbers": [{"value": 598000, "label": "发票金额"}, {"value": 68796.46, "label": "税额"}],
         "qa": [q("物流单号是多少？", "SF-HS-7730215", "exact"), q("预计哪天送到？", "10月16日", accept=["10/16", "2026-10-16", "明天"]),
                q("发票号码是多少？", "04417726", "exact"), q("发票税额是多少元？", 68796.46, "number", tol=0.01)],
         "notes": "税额只在附件 PDF 里。"})

F(key="gpu_jpg", type="jpg", filename="到货签收单.jpg", t="2026-10-16T11:05:00+08:00", source_app="微信",
  persons=["p_tao"], events=["ev_gpu"],
  visual={"style": "card", "photo": True, "title": "恒算科技 货物签收单", "w": 900,
          "lines": ["第1批 / 共2批"],
          "fields": [("签收单号", "QS-1016-0093"), ("客户", "清屿大学计算机学院"), ("货物", "HS-G8820 GPU 服务器"),
                     ("数量", "1 台"), ("序列号", "HSG8820-A7731"), ("送达时间", "2026-10-16 10:48"), ("签收人", "陶然"),
                     ("外观检查", "完好")]},
  truth={"key_fields": {"签收人": "陶然", "序列号": "HSG8820-A7731", "送达时间": "2026-10-16 10:48", "数量": 1},
         "numbers": [{"value": 1, "label": "数量"}],
         "qa": [q("签收人是谁？", "陶然"), q("序列号是多少？", "HSG8820-A7731", "exact"),
                q("几点送达的？", "10:48"), q("这次送了几台？", 1, "number")],
         "notes": "手机拍的纸质签收单：倾斜、阴影、暖色光。"})

F(key="gpu_heic", type="heic", filename="机器铭牌.heic", t="2026-10-16T11:10:00+08:00", source_app="照片",
  persons=[], events=["ev_gpu"],
  visual={"style": "card", "photo": True, "title": "HS-G8820", "w": 820, "bg": (58, 62, 70), "accent": (230, 230, 235),
          "fg": (235, 236, 240), "lines": ["GPU Server · 8×H20 96GB"],
          "fields": [("型号 Model", "HS-G8820"), ("S/N", "HSG8820-A7731"), ("额定电源", "4×3000W 200-240V~"),
                     ("生产日期", "2026-09"), ("制造商", "恒算科技有限公司")]},
  truth={"key_fields": {"型号": "HS-G8820", "S/N": "HSG8820-A7731", "电源": "4×3000W", "生产日期": "2026-09"},
         "numbers": [{"value": 3000, "label": "电源功率 W"}],
         "qa": [q("铭牌上的序列号是多少？", "HSG8820-A7731", "exact"), q("额定电源是多少瓦？", "3000W", accept=["4×3000W", "3000 W"]),
                q("生产日期是？", "2026-09", accept=["2026年9月"])]})

# ============================== ev_defense (test) ===============================================
F(key="def_ics", type="ics", filename="开题答辩邀请.ics", t="2026-10-12T11:00:00+08:00", source_app="邮件",
  persons=["p_lin", "p_xu", "p_fang", "p_owner"], events=["ev_defense"],
  calendar={"name": "开题答辩", "events": [
      {"uid": "defense-lin-20261014@example.org", "summary": "林晓棠 硕士开题答辩", "start": "20261014T140000",
       "end": "20261014T160000", "location": "计算机楼 B312",
       "organizer": ("林晓棠", "lin.xt@example.org"),
       "attendees": [("许卫东", "xuwd@example.org"), ("方敏", "fangmin@example.org"), ("沈知遥", "shenzy@example.org")],
       "description": "题目：基于多模态记忆的课堂视频摘要方法研究\n答辩委员会：许卫东（主席）、方敏、沈知遥\n汇报20分钟，提问15分钟。（合成数据）",
       "alarm": "-PT30M"}]},
  truth={"key_fields": {"地点": "计算机楼 B312", "开始": "2026-10-14 14:00", "主席": "许卫东"},
         "numbers": [{"value": 20, "label": "汇报分钟"}],
         "qa": [q("答辩在哪里？", "B312"), q("几点开始？", "14:00", accept=["下午2点", "下午两点", "14点"]),
                q("答辩委员会主席是谁？", "许卫东"), q("论文题目是什么？", "基于多模态记忆的课堂视频摘要方法研究")]})

F(key="def_doc", type="doc", filename="开题报告_林晓棠_v2.doc", t="2026-10-12T20:30:00+08:00", source_app="微信",
  persons=["p_lin", "p_owner"], events=["ev_defense"],
  doc={"title": "硕士学位论文开题报告", "lang": "zh",
       "blocks": [("kv", [("论文题目", "基于多模态记忆的课堂视频摘要方法研究"), ("学生", "林晓棠（2025级硕士）"),
                          ("导师", "沈知遥 副教授"), ("专业", "计算机科学与技术")]),
                  ("h", "一、研究背景"),
                  ("p", "高校课堂录像时长普遍在45至90分钟之间，学生复习时难以快速定位重点。现有视频摘要方法多面向新闻与体育，忽略了板书和幻灯片上的文字。"),
                  ("h", "二、研究内容"),
                  ("ul", ["构建融合语音转写、板书识别与关键帧的多模态课堂表示", "设计跨片段的主题记忆模块", "建立课堂摘要评测数据集与评价指标"]),
                  ("h", "三、技术路线"),
                  ("p", "以记忆增强的视频编码器为基础，每10分钟切分一个片段，片段间通过记忆模块传递主题信息，最终生成带时间戳的5分钟摘要。"),
                  ("h", "四、进度安排"),
                  ("table", {"columns": ["阶段", "时间", "内容"],
                             "rows": [["开题", "2026年10月", "完成开题答辩"], ["数据", "2026年11月—12月", "采集并标注 120 节课堂视频"],
                                      ["实验", "2027年1月—3月", "完成主实验与消融"], ["论文", "2027年4月—6月", "撰写论文并准备答辩"]]}),
                  ("h", "五、预期成果"),
                  ("p", "发表 1 篇 CCF-B 类以上会议论文，公开课堂摘要数据集 ClassSum-120。")]},
  truth={"key_fields": {"题目": "基于多模态记忆的课堂视频摘要方法研究", "导师": "沈知遥", "数据集": "ClassSum-120"},
         "numbers": [{"value": 120, "label": "课堂视频节数"}, {"value": 5, "label": "摘要分钟"}],
         "qa": [q("计划标注多少节课堂视频？", 120, "number"), q("要公开的数据集叫什么？", "ClassSum-120", "exact"),
                q("导师是谁？", "沈知遥"), q("实验阶段在什么时间？", "2027年1月", accept=["2027年1月—3月", "2027.01"])],
         "notes": "由 docx 经 macOS textutil 转成 Word 97 .doc。"})

F(key="def_odp", type="odp", filename="开题答辩PPT_林晓棠.odp", t="2026-10-13T15:00:00+08:00", source_app="微信",
  persons=["p_lin", "p_owner"], events=["ev_defense"], title="开题答辩 林晓棠",
  slides=[{"title": "基于多模态记忆的课堂视频摘要方法研究", "subtitle": "林晓棠 · 指导教师：沈知遥"},
          {"title": "研究问题", "bullets": ["课堂视频平均时长 72 分钟，重点分散", "现有摘要方法忽略板书与 PPT 文字",
                                        "目标：生成带时间戳的 5 分钟摘要"]},
          {"title": "技术路线", "bullets": ["三路输入：语音转写 / 板书 OCR / 画面关键帧", "记忆模块保留跨段主题", "评测：ROUGE-L 与人工打分"]},
          {"title": "初步结果", "image": True,
           "table": {"columns": ["方法", "ROUGE-L"], "rows": [["抽取式基线", 0.312], ["本文初版", 0.357]]}},
          {"title": "时间安排", "bullets": ["2026.11–12 数据标注（120 节）", "2027.01–03 实验", "2027.04–06 论文"]}],
  truth={"key_fields": {"平均时长": "72分钟", "摘要长度": "5分钟", "初版ROUGE-L": 0.357},
         "numbers": [{"value": 72, "label": "平均时长"}, {"value": 0.357, "label": "ROUGE-L"}],
         "qa": [q("课堂视频平均多长？", 72, "number"), q("目标摘要多长（分钟）？", 5, "number"),
                q("本文初版的 ROUGE-L 是多少？", 0.357, "number")],
         "notes": "第 4 页为整页图片，ROUGE-L 只在图里。"})

F(key="def_vcf", type="vcf", filename="答辩委员会联系人.vcf", t="2026-10-13T15:30:00+08:00", source_app="通讯录",
  persons=["p_xu", "p_fang", "p_lin"], events=["ev_defense"],
  contacts=[{"fn": "许卫东", "family": "许", "given": "卫东", "org": "清屿大学计算机学院", "title": "教授（开题答辩委员会主席）",
             "tel": "+86-10-5550-0101", "email": "xuwd@example.org", "note": "周三下午有课"},
            {"fn": "方敏", "family": "方", "given": "敏", "org": "清屿大学计算机学院", "title": "副教授",
             "tel": "+86-10-5550-0102", "email": "fangmin@example.org"},
            {"fn": "林晓棠", "family": "林", "given": "晓棠", "org": "清屿大学计算机学院 视觉智能实验室", "title": "硕士研究生",
             "tel": "+86-10-5550-0103", "email": "lin.xt@example.org"}],
  truth={"key_fields": {"许卫东电话": "+86-10-5550-0101", "方敏职称": "副教授", "许卫东备注": "周三下午有课"},
         "numbers": [],
         "qa": [q("许卫东的电话是多少？", "5550-0101", accept=["+86-10-5550-0101"]), q("方敏是什么职称？", "副教授"),
                q("许卫东的备注写了什么？", "周三下午有课")]})

F(key="def_mov", type="mov", filename="答辩预演录屏.mov", t="2026-10-14T20:00:00+08:00", source_app="Finder",
  persons=["p_lin"], events=["ev_defense"], seconds=[3, 3, 3], silent_audio=True,
  slides=[{"title": "开题预演（第2版）", "bullets": ["汇报时长：19分30秒（限20分钟）", "林晓棠 · 视觉智能实验室"]},
          {"title": "研究问题", "bullets": ["课堂视频平均时长 72 分钟", "目标：带时间戳的 5 分钟摘要"]},
          {"title": "修改记录", "bullets": ["根据预演意见：删去相关工作 2 页", "补充 ClassSum-120 标注规范", "答辩时间：10月15日 14:00（已改期）"]}],
  truth={"key_fields": {"汇报时长": "19分30秒", "删去页数": 2, "答辩时间": "2026-10-15 14:00"},
         "numbers": [{"value": 2, "label": "删去页数"}],
         "qa": [q("预演汇报用了多长时间？", "19分30秒"), q("删去了相关工作几页？", 2, "number"),
                q("改期后的答辩时间是？", "10月15日", accept=["10/15", "2026-10-15"])],
         "notes": "带静音 AAC 音轨的 QuickTime 录屏。"})

_rec1 = {"title": "研究生开题答辩记录表", "lang": "zh",
         "blocks": [("kv", [("学生", "林晓棠"), ("答辩日期", "2026年10月15日"), ("地点", "计算机楼B312"),
                            ("委员会", "许卫东（主席）、方敏、沈知遥")]),
                    ("h", "答辩结论"), ("p", "表决结果：3票同意，0票反对。结论：通过。"),
                    ("h", "修改意见"),
                    ("ul", ["1. 明确 ClassSum-120 的标注一致性指标（Kappa ≥ 0.75）", "2. 增加与商用会议摘要工具的对比",
                            "3. 缩减技术路线中的多任务部分"])],
         "signature": "主席签字：许卫东    2026年10月15日"}
_rec2 = {"title": "附：委员个人意见", "lang": "zh",
         "blocks": [("p", "方敏：数据集规模合理，建议提前准备标注手册，并记录每节课的学科与时长分布。"),
                    ("p", "沈知遥：同意通过，修改稿请于10月25日前提交导师。")]}
F(key="def_tiff", type="tiff", filename="开题答辩记录表_签字.tiff", t="2026-10-15T17:30:00+08:00", source_app="扫描仪",
  persons=["p_lin", "p_xu", "p_fang", "p_owner"], events=["ev_defense"], pages=[_rec1, _rec2],
  truth={"key_fields": {"结论": "通过", "同意票": 3, "Kappa": 0.75, "答辩日期": "2026-10-15"},
         "numbers": [{"value": 3, "label": "同意票"}, {"value": 0.75, "label": "Kappa 阈值"}],
         "qa": [q("答辩结论是什么？", "通过"), q("几票同意？", 3, "number"), q("标注一致性 Kappa 至少多少？", 0.75, "number"),
                q("修改稿什么时候前交？", "10月25日", accept=["2026-10-25"])],
         "notes": "两页 TIFF 扫描件（灰度、倾斜、噪点），第二页是委员个人意见。"})

F(key="def_txt", type="txt", filename="答辩意见整理.txt", t="2026-10-15T19:00:00+08:00", source_app="备忘录",
  persons=["p_lin", "p_owner", "p_xu", "p_fang"], events=["ev_defense"], encoding="gb18030",
  text="开题答辩意见整理（林晓棠）\n2026-10-15 晚\n\n结论：通过（3票同意）。\n\n需要修改：\n"
       "1. 标注一致性：ClassSum-120 双人标注，Kappa 不低于 0.75；\n2. 增加对比：至少 2 个商用会议摘要工具；\n"
       "3. 技术路线：去掉多任务部分，集中在记忆模块。\n\n时间：修改稿 10月25日前发给沈老师，11月1日开始标注。\n—— 合成数据\n",
  truth={"key_fields": {"修改稿截止": "2026-10-25", "开始标注": "2026-11-01", "对比工具数": 2},
         "numbers": [{"value": 0.75, "label": "Kappa"}, {"value": 2, "label": "对比工具数"}],
         "qa": [q("修改稿什么时候前交？", "10月25日", accept=["2026-10-25"]), q("哪天开始标注？", "11月1日", accept=["2026-11-01"]),
                q("至少对比几个商用工具？", 2, "number")],
         "notes": "GB18030 编码（不是 UTF-8）。"})

# ============================== ev_collab (test) ================================================
F(key="col_rtf", type="rtf", filename="合作备忘录_澄川科技.rtf", t="2026-10-12T15:30:00+08:00", source_app="邮件",
  persons=["p_ma", "p_owner"], events=["ev_collab"],
  doc={"title": "澄川科技—清屿大学视觉智能实验室 合作备忘录", "lang": "zh",
       "blocks": [("kv", [("项目名称", "产线表面缺陷检测模型研发"), ("甲方", "澄川科技（苏州）有限公司"), ("乙方", "清屿大学视觉智能实验室"),
                          ("项目负责人", "甲方 马骏；乙方 沈知遥"), ("合同金额", "360,000元"), ("项目周期", "2026年8月1日至2027年1月31日")]),
                  ("h", "一、交付内容"),
                  ("ul", ["缺陷检测模型（划痕、凹坑、污渍三类），测试集 mAP 不低于 0.85", "部署包与技术文档", "2次现场培训"]),
                  ("h", "二、付款安排"),
                  ("p", "按里程碑分三期支付：签约后支付30%（108,000元），中期验收通过后支付50%（180,000元），结题验收后支付20%（72,000元）。"),
                  ("h", "三、保密"), ("p", "双方对项目数据与模型负有保密义务，期限三年。")]},
  truth={"key_fields": {"合同金额": 360000, "mAP要求": 0.85, "中期款": 180000, "结束日期": "2027-01-31"},
         "numbers": [{"value": 360000, "label": "合同金额"}, {"value": 108000, "label": "首期"}, {"value": 180000, "label": "中期"},
                     {"value": 72000, "label": "尾款"}],
         "qa": [q("合同金额多少元？", 360000, "number"), q("测试集 mAP 至少要多少？", 0.85, "number"),
                q("中期验收后付多少元？", 180000, "number"), q("项目到哪天结束？", "2027年1月31日", accept=["2027-01-31"])],
         "notes": "HTML 经 macOS textutil 转成 RTF，中文是 \\u 转义。"})

F(key="col_csv", type="csv", filename="澄川项目_里程碑与付款.csv", t="2026-10-13T11:20:00+08:00", source_app="微信",
  persons=["p_ma"], events=["ev_collab"],
  csv={"columns": ["期次", "里程碑", "计划日期", "比例", "金额（元）", "状态"],
       "rows": [["1", "签约", "2026-08-01", "30%", "108000", "已到账"], ["2", "中期验收（模型 v1.2）", "2026-10-20", "50%", "180000", "待验收"],
                ["3", "结题验收", "2027-01-31", "20%", "72000", "未开始"], ["合计", "", "", "100%", "360000", ""]],
       "encoding": "utf-8-sig"},
  truth={"key_fields": {"中期验收日期": "2026-10-20", "已到账": 108000, "结题款": 72000},
         "numbers": [{"value": 108000, "label": "首期"}, {"value": 180000, "label": "中期"}, {"value": 72000, "label": "结题"},
                     {"value": 360000, "label": "合计"}],
         "qa": [q("中期验收计划在哪天？", "2026-10-20", accept=["10月20日", "10/20"]), q("已经到账多少元？", 108000, "number"),
                q("结题验收款多少元？", 72000, "number")],
         "notes": "UTF-8 带 BOM，CRLF 换行。"})

F(key="col_mbox", type="mbox", filename="澄川项目往来邮件.mbox", t="2026-10-14T09:00:00+08:00", source_app="邮件",
  persons=["p_ma", "p_owner", "p_he"], events=["ev_collab"],
  messages=[{"from": ("马骏", "majun@example.com"), "to": [("沈知遥", "shenzy@example.org")],
             "date": "2026-10-12T18:05:00+08:00", "subject": "中期验收时间", "message_id": "<cc-001@example.com>",
             "body": "沈老师好，我们这边希望10月20日（周二）在苏州工厂做中期验收，现场跑一遍v1.2模型。您看时间方便吗？需要的话我们安排车。\n\n马骏\n澄川科技（合成数据）"},
            {"from": ("沈知遥", "shenzy@example.org"), "to": [("马骏", "majun@example.com")],
             "cc": [("贺一鸣", "heym@example.org")], "date": "2026-10-13T09:12:00+08:00", "subject": "Re: 中期验收时间",
             "message_id": "<qy-002@example.org>", "in_reply_to": "<cc-001@example.com>", "cte": "base64",
             "body": "马经理好，10月20日可以。我和贺一鸣上午9点到，带部署包和测试报告。请准备一台带GPU的工控机。\n\n沈知遥"},
            {"from": ("马骏", "majun@example.com"), "to": [("沈知遥", "shenzy@example.org")],
             "date": "2026-10-13T17:40:00+08:00", "subject": "Re: Re: 中期验收时间", "message_id": "<cc-003@example.com>",
             "in_reply_to": "<qy-002@example.org>", "cte": "quoted-printable",
             "body": "好的，10月20日上午9:30在苏州工厂3号楼会议室，我们这边质量部的赵工参加。工控机已备好（RTX 4000 Ada）。第二期款在验收签字后走流程。\n\n马骏"}],
  truth={"key_fields": {"验收日期": "2026-10-20", "验收时间": "9:30", "地点": "苏州工厂3号楼会议室", "显卡": "RTX 4000 Ada"},
         "numbers": [],
         "qa": [q("中期验收在哪里？", "3号楼会议室", accept=["苏州工厂3号楼会议室", "苏州工厂3号楼"]), q("验收几点开始？", "9:30", accept=["09:30", "上午9:30"]),
                q("工控机是什么显卡？", "RTX 4000 Ada"), q("沈老师和谁一起去？", "贺一鸣")],
         "notes": "3 封邮件的线程；第 2 封正文 base64，第 3 封 quoted-printable。"})

F(key="col_xml", type="xml", filename="交付清单_v1.2.xml", t="2026-10-14T16:45:00+08:00", source_app="Finder",
  persons=["p_he"], events=["ev_collab"],
  xml="""<?xml version="1.0" encoding="UTF-8"?>
<!-- 合成数据 · synthetic data -->
<delivery xmlns="urn:example:delivery:1" project="CC-DEFECT-2026" version="1.2" date="2026-10-14">
  <client>澄川科技（苏州）有限公司</client>
  <supplier>清屿大学视觉智能实验室</supplier>
  <artifacts>
    <artifact name="defect_det_v1.2.onnx" type="model" size_mb="87.4" sha256="3f1c9a0d7e5b2c4a8f6e1d0b9c7a5e3f2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a"/>
    <artifact name="deploy_guide.pdf" type="doc" pages="14"/>
    <artifact name="test_report_v1.2.pdf" type="doc" pages="9"/>
  </artifacts>
  <metrics dataset="澄川测试集 v3" images="2400">
    <metric name="mAP@0.5" value="0.873"/>
    <metric name="recall_scratch" value="0.91"/>
    <metric name="latency_ms" value="23"/>
  </metrics>
  <classes>
    <class id="1">划痕</class>
    <class id="2">凹坑</class>
    <class id="3">污渍</class>
  </classes>
  <acceptance date="2026-10-20" place="苏州工厂"/>
</delivery>
""",
  truth={"key_fields": {"mAP": 0.873, "测试集图片": 2400, "延迟ms": 23, "模型大小MB": 87.4},
         "numbers": [{"value": 0.873, "label": "mAP"}, {"value": 2400, "label": "images"}, {"value": 23, "label": "latency"},
                     {"value": 87.4, "label": "size_mb"}],
         "qa": [q("v1.2 的 mAP 是多少？", 0.873, "number"), q("测试集有多少张图？", 2400, "number"),
                q("推理延迟多少毫秒？", 23, "number"), q("模型文件多大（MB）？", 87.4, "number")]})

F(key="col_zip", type="zip", filename="中期交付物_v1.2.zip", t="2026-10-15T22:00:00+08:00", source_app="Finder",
  persons=["p_he"], events=["ev_collab"],
  members=[{"name": "README.txt", "kind": "text",
            "text": "澄川缺陷检测项目 中期交付物 v1.2\n\n包含：\n- metrics.csv  各类别 AP\n- 部署说明.md  环境与运行命令\n- 样例结果.zip  样例图片与检测结果\n\n中期验收：2026年10月20日，苏州工厂。\n合成数据\n"},
           {"name": "metrics.csv", "kind": "csv", "columns": ["类别", "AP@0.5", "样本数"],
            "rows": [["划痕", "0.902", "820"], ["凹坑", "0.861", "790"], ["污渍", "0.856", "790"], ["平均", "0.873", "2400"]]},
           {"name": "部署说明.md", "kind": "text",
            "text": "# 部署说明（v1.2）\n\n- 系统：Ubuntu 22.04\n- CUDA：12.4\n- 推理：单张 23 ms（RTX 4000 Ada）\n\n```bash\n./run_infer.sh --model defect_det_v1.2.onnx --input ./images\n```\n\n> 合成数据\n"},
           {"name": "样例结果.zip", "kind": "zip", "members": [
               {"name": "sample_0417.png", "kind": "image", "visual_ref": "detect"},
               {"name": "sample_0417.json", "kind": "json",
                "record": {"image": "sample_0417.png", "model": "v1.2",
                           "detections": [{"label": "划痕", "score": 0.94, "box": [112, 80, 342, 128]},
                                          {"label": "凹坑", "score": 0.81, "box": [410, 230, 470, 290]}],
                           "note": "合成数据"}}]}],
  truth={"key_fields": {"凹坑AP": 0.861, "CUDA": "12.4", "嵌套样例类别": ["划痕", "凹坑"], "顶层文件数": 4},
         "numbers": [{"value": 0.861, "label": "凹坑 AP"}, {"value": 0.873, "label": "平均 AP"}, {"value": 23, "label": "ms"}],
         "qa": [q("凹坑类的 AP 是多少？", 0.861, "number"), q("部署要求的 CUDA 版本？", "12.4"),
                q("嵌套压缩包里样例图的最高分检测类别是什么？", "划痕"), q("压缩包顶层有几个文件？", 4, "number", derived=True)],
         "notes": "zip 里有嵌套的“样例结果.zip”（含 PNG 与 JSON）。"})

F(key="col_html", type="html", filename="澄川项目周报_第11周.html", t="2026-10-16T09:30:00+08:00", source_app="浏览器",
  persons=["p_he", "p_ma", "p_tao"], events=["ev_collab"],
  doc={"title": "澄川缺陷检测项目 周报（第11周，10月12日—10月16日）", "lang": "zh", "site": "项目协作空间",
       "blocks": [("kv", [("整体进度", "85%"), ("本周负责人", "贺一鸣")]),
                  ("h", "本周完成"),
                  ("ul", ["v1.2 模型在澄川测试集 v3 上 mAP 0.873（目标 0.85）", "部署包打包完成（中期交付物_v1.2.zip）",
                          "与马骏确认中期验收：10月20日 9:30，苏州工厂"]),
                  ("h", "风险"), ("ul", ["污渍类 AP 0.856，接近下限，需补充 300 张样本"]),
                  ("h", "下周计划"), ("ul", ["10月20日 中期验收", "验收后申请第二期款 180,000 元"]),
                  ("table", {"caption": "本周工时", "columns": ["成员", "工时（小时）"], "rows": [["贺一鸣", 22], ["陶然", 8]]})]},
  truth={"key_fields": {"整体进度": "85%", "补充样本": 300, "污渍AP": 0.856},
         "numbers": [{"value": 85, "label": "进度%"}, {"value": 300, "label": "补充样本"}, {"value": 0.856, "label": "污渍 AP"},
                     {"value": 22, "label": "贺一鸣工时"}],
         "qa": [q("整体进度是多少？", 85, "number"), q("污渍类需要补充多少张样本？", 300, "number"),
                q("污渍类 AP 是多少？", 0.856, "number")]})

F(key="col_bmp", type="bmp", filename="缺陷检测样例_划痕.bmp", t="2026-10-16T10:10:00+08:00", source_app="微信",
  persons=["p_he"], events=["ev_collab"],
  visual={"style": "detect", "header": "澄川测试集 v3 · 样例 #0417 · 模型 v1.2",
          "boxes": [("划痕 0.94", (112, 80, 342, 128)), ("凹坑 0.81", (410, 230, 470, 290))]},
  truth={"key_fields": {"样例编号": "#0417", "划痕置信度": 0.94, "凹坑置信度": 0.81},
         "numbers": [{"value": 0.94, "label": "划痕"}, {"value": 0.81, "label": "凹坑"}],
         "qa": [q("划痕的置信度是多少？", 0.94, "number"), q("这是第几号样例？", "0417", accept=["#0417"]),
                q("检测到几类缺陷？", 2, "number", derived=True)]})

# ============================== ev_talk (dev) ===================================================
F(key="talk_eml", type="eml", filename="Visit_to_Qingyu_travel_details.eml", t="2026-10-12T08:15:00+08:00", source_app="邮件", lang="en",
  persons=["p_park", "p_owner", "p_song"], events=["ev_talk"],
  email={"from": ("Elena Park", "elena.park@example.org"), "to": [("Zhiyao Shen", "shenzy@example.org")],
         "cc": [("宋雨桐", "songyt@example.org")], "date": "2026-10-12T08:15:00+08:00",
         "subject": "Visit to Qingyu — travel details and talk abstract", "message_id": "<ep-1012@example.org>",
         "html_alt": True,
         "body": "Dear Zhiyao,\n\nThank you again for the invitation. Here are my travel details:\n\n"
                 "- Arrival: flight ZY 5718, departing Singapore at 13:25 on Thursday, October 15, arriving at Qingyu Airport at 19:10 local time.\n"
                 "- Departure: Saturday, October 17, flight ZY 5723 at 11:40.\n\n"
                 "My talk title is \"Memory Structures for Embodied Agents\". I would prefer a 60-minute talk plus 30 minutes of Q&A. "
                 "The abstract and a short bio are attached.\n\nDietary note: I am vegetarian.\n\nBest regards,\nElena\n\n-- \n"
                 "Elena Park, Professor of Computer Science, Northbridge University\n(synthetic data · 合成数据)",
         "attachments": [{"filename": "talk_abstract.txt", "kind": "text",
                          "text": "Memory Structures for Embodied Agents\nElena Park, Northbridge University\n\n"
                                  "Abstract: Embodied agents must remember what they saw, what they know and how to act. This talk "
                                  "compares three memory types (episodic, semantic and procedural) across 4 benchmark suites and "
                                  "argues that agents need all three, with explicit rules for forgetting.\n\n(synthetic data)\n"},
                         {"filename": "bio_ElenaPark.docx", "kind": "docx",
                          "doc": {"title": "Short Bio — Elena Park", "lang": "en",
                                  "blocks": [("p", "Elena Park is a Professor of Computer Science at Northbridge University, where she leads the Embodied Memory Group (12 members)."),
                                             ("p", "She received her PhD in 2014 and has published more than 60 papers on robot learning and memory.")]}}]},
  truth={"key_fields": {"arrival_flight": "ZY 5718", "arrival_time": "2026-10-15 19:10", "departure": "2026-10-17 ZY 5723 11:40",
                        "talk_title": "Memory Structures for Embodied Agents", "talk_minutes": 60, "diet": "vegetarian"},
         "numbers": [{"value": 60, "label": "talk minutes"}, {"value": 30, "label": "Q&A minutes"}, {"value": 12, "label": "group size"}],
         "qa": [q("When does Elena arrive (local time)?", "19:10"), q("What is the arrival flight number?", "ZY 5718", "exact", accept=["ZY5718"]),
                q("How long should the talk be (minutes)?", 60, "number"), q("Any dietary requirement?", "vegetarian", accept=["素食"]),
                ],
         "notes": "multipart/alternative（纯文本 + HTML）加两个附件：txt 摘要与 docx 简介。"})

F(key="talk_webarchive", type="webarchive", filename="清屿会堂酒店 - 预订确认.webarchive", t="2026-10-12T17:00:00+08:00", source_app="Safari",
  persons=["p_park", "p_song"], events=["ev_talk"], url="https://booking.qingyuhall.example.com/confirm/QYH-88213",
  doc={"title": "预订确认 · 清屿会堂酒店", "lang": "zh", "site": "清屿会堂酒店在线预订",
       "blocks": [("p", "您的预订已确认，确认邮件已发送至 songyt@example.org。"),
                  ("kv", [("确认号", "QYH-88213"), ("入住人", "Elena Park"), ("入住", "2026年10月15日（周四）14:00后"),
                          ("离店", "2026年10月17日（周六）12:00前"), ("房型", "高级大床房（无烟）"), ("晚数", "2晚"),
                          ("房价", "680元/晚（含早）"), ("总价", "1,360元"), ("预订人", "宋雨桐（清屿大学计算机学院）")]),
                  ("p", "如需延迟入住（22:00以后），请提前致电前台 +86-10-5550-0199。")]},
  truth={"key_fields": {"确认号": "QYH-88213", "入住": "2026-10-15", "离店": "2026-10-17", "总价": 1360, "房型": "高级大床房（无烟）"},
         "numbers": [{"value": 680, "label": "房价"}, {"value": 1360, "label": "总价"}],
         "qa": [q("酒店确认号是多少？", "QYH-88213", "exact"), q("总价多少元？", 1360, "number"),
                q("订的什么房型？", "高级大床房"), q("前台电话是多少？", "5550-0199", accept=["+86-10-5550-0199"])],
         "notes": "Safari 网页归档（二进制 plist），含一个 PNG 子资源。"})

F(key="talk_ics", type="ics", filename="Talk_ElenaPark.ics", t="2026-10-13T09:00:00+08:00", source_app="日历",
  persons=["p_park", "p_song", "p_owner"], events=["ev_talk"],
  calendar={"name": "学院讲座", "events": [
      {"uid": "talk-park-20261016@example.org", "summary": "学术讲座：Memory Structures for Embodied Agents（Elena Park）",
       "start": "20261016T150000", "end": "20261016T163000", "location": "计算机楼 A101 报告厅",
       "organizer": ("宋雨桐", "songyt@example.org"),
       "description": "主讲：Elena Park 教授（Northbridge University）\n主持：沈知遥\n讲座60分钟，问答30分钟。\n合成数据",
       "alarm": "-PT1H"},
      {"uid": "dinner-park-20261016@example.org", "summary": "欢迎晚宴（素食）", "start": "20261016T180000",
       "end": "20261016T200000", "location": "清屿会堂 二楼 竹厅", "organizer": ("宋雨桐", "songyt@example.org"),
       "description": "参加：Elena Park、沈知遥、宋雨桐 等 6 人"}]},
  truth={"key_fields": {"讲座时间": "2026-10-16 15:00-16:30", "地点": "计算机楼 A101 报告厅", "晚宴": "18:00 清屿会堂 二楼 竹厅", "主持": "沈知遥"},
         "numbers": [{"value": 6, "label": "晚宴人数"}],
         "qa": [q("讲座在哪个报告厅？", "A101"), q("讲座几点开始？", "15:00", accept=["下午3点", "下午三点"]),
                q("晚宴在哪？", "竹厅", accept=["清屿会堂 二楼 竹厅"]), q("主持人是谁？", "沈知遥")]})

F(key="talk_svg", type="svg", filename="讲座海报_ElenaPark.svg", t="2026-10-13T14:00:00+08:00", source_app="微信",
  persons=["p_park", "p_owner"], events=["ev_talk"],
  svg={"lines": [("清屿大学计算机学院 学术讲座", 30, "#f5d58a"), ("Memory Structures for Embodied Agents", 44, "#ffffff"),
                 ("主讲人：Elena Park 教授 · Northbridge University", 28, "#ffffff"),
                 ("时间：2026年10月16日（周五）15:00–16:30", 28, "#ffffff"), ("地点：计算机楼 A101 报告厅", 28, "#ffffff"),
                 ("主持人：沈知遥 副教授", 26, "#dfe6f5"), ("欢迎全校师生参加", 26, "#f5d58a")], "bg": "#1f3b63"},
  truth={"key_fields": {"时间": "2026-10-16 15:00-16:30", "地点": "计算机楼 A101 报告厅", "主讲人单位": "Northbridge University"},
         "numbers": [],
         "qa": [q("讲座哪天几点？", "10月16日", accept=["2026年10月16日", "10/16"]), q("讲座地点？", "A101"),
                q("主讲人来自哪所大学？", "Northbridge University")]})

F(key="talk_gif", type="gif", filename="讲座预告.gif", t="2026-10-14T10:00:00+08:00", source_app="微信",
  persons=["p_park"], events=["ev_talk"],
  frames=[{"title": "本周五 学术讲座", "bullets": ["Memory Structures for Embodied Agents"]},
          {"title": "10月16日 15:00", "bullets": ["计算机楼 A101 报告厅"]},
          {"title": "主讲：Elena Park 教授", "bullets": ["现场前50名赠送讲义（Lecture Notes）"]}],
  truth={"key_fields": {"赠送名额": 50, "时间": "2026-10-16 15:00", "地点": "A101"},
         "numbers": [{"value": 50, "label": "前50名"}],
         "qa": [q("前多少名赠送讲义？", 50, "number"), q("讲座几点？", "15:00"), q("在哪个报告厅？", "A101")],
         "notes": "动图 3 帧，每帧文字不同；只看第一帧会漏掉时间和赠品。"})

F(key="talk_epub", type="epub", filename="Lecture_Notes_Memory_Structures.epub", t="2026-10-14T13:30:00+08:00", source_app="邮件",
  persons=["p_park"], events=["ev_talk"],
  book={"title": "Lecture Notes: Memory Structures for Embodied Agents", "author": "Elena Park", "lang": "en",
        "identifier": "urn:uuid:5a1d7c52-8f0e-4b8e-9f51-2f7c2a0e6c11",
        "chapters": [{"title": "1. Three Kinds of Memory", "blocks": [
            ("p", "Episodic memory stores what happened and when. Semantic memory stores what is true regardless of when it was learned. Procedural memory stores how to act."),
            ("table", {"columns": ["Memory type", "Typical store", "Example"],
                       "rows": [["episodic", "event log", "the cup was on the left shelf at 10:02"],
                                ["semantic", "knowledge graph", "cups are kept in the kitchen"],
                                ["procedural", "policy", "open the drawer before reaching in"]]})]},
                     {"title": "2. Benchmarks", "blocks": [
                         ("p", "We compare agents on 4 benchmark suites: HomeTidy, ShelfQA, DoorNav and ToolUse-12 (all fictional, invented for these notes)."),
                         ("table", {"columns": ["Suite", "Episodes", "Best success rate"],
                                    "rows": [["HomeTidy", "1,200", "64.5%"], ["ShelfQA", "800", "71.2%"], ["DoorNav", "2,000", "88.0%"],
                                             ["ToolUse-12", "600", "42.7%"]]})]},
                     {"title": "3. Open Problems", "blocks": [
                         ("ul", ["When should an agent forget?", "How to merge episodic traces into semantic facts",
                                 "Evaluating memory without leaking test episodes"]),
                         ("p", "Synthetic lecture notes for evaluation only.")]}]},
  truth={"key_fields": {"benchmark_suites": 4, "ShelfQA_best": "71.2%", "memory_types": ["episodic", "semantic", "procedural"]},
         "numbers": [{"value": 4, "label": "suites"}, {"value": 71.2, "label": "ShelfQA"}, {"value": 42.7, "label": "ToolUse-12"}],
         "qa": [q("How many benchmark suites are compared?", 4, "number"), q("What is the best success rate on ShelfQA?", 71.2, "number"),
                q("Name the memory type that stores how to act.", "procedural")]})

F(key="talk_png", type="png", filename="报告厅预约成功截图.png", t="2026-10-14T16:10:00+08:00", source_app="微信",
  persons=["p_song", "p_park"], events=["ev_talk"],
  visual={"style": "window", "app": "学院场地预约系统", "badge": "已通过",
          "lines": ["预约成功", "您的场地预约已通过审核。"],
          "fields": [("预约号", "RB-20261016-032"), ("场地", "计算机楼 A101 报告厅（容纳 180 人）"), ("使用时间", "2026-10-16 14:30–17:00"),
                     ("用途", "学术讲座（Elena Park）"), ("申请人", "宋雨桐"), ("设备", "投影、无线麦克风×2、同传耳机")]},
  truth={"key_fields": {"预约号": "RB-20261016-032", "容纳": 180, "使用时间": "2026-10-16 14:30-17:00"},
         "numbers": [{"value": 180, "label": "容纳人数"}],
         "qa": [q("预约号是多少？", "RB-20261016-032", "exact"), q("报告厅能容纳多少人？", 180, "number"),
                q("场地几点开始可以用？", "14:30")]})

# ============================== ev_annot (dev) ==================================================
F(key="ann_json", type="json", filename="标注规范_v2.json", t="2026-10-12T13:00:00+08:00", source_app="微信",
  persons=["p_zhou", "p_he"], events=["ev_annot"],
  record={"schema_version": "2.0", "project": "KitchenQA 视频问答标注", "vendor": "数芽标注", "contact": "周蔓",
          "total_clips": 20000, "clip_length_sec": {"min": 60, "max": 600},
          "question_types": [{"id": "temporal", "name": "时序", "min_per_clip": 1},
                             {"id": "causal", "name": "因果", "min_per_clip": 1},
                             {"id": "counting", "name": "计数", "min_per_clip": 1}],
          "answer_format": {"type": "multiple_choice", "options": 4, "distractor_rule": "干扰项须来自同一视频"},
          "qc": {"sample_rate": 0.1, "pass_threshold": 0.95, "double_annotation": True}, "batches": 4, "note": "合成数据"},
  truth={"key_fields": {"pass_threshold": 0.95, "total_clips": 20000, "options": 4, "sample_rate": 0.1},
         "numbers": [{"value": 0.95, "label": "合格线"}, {"value": 20000, "label": "总条数"}, {"value": 4, "label": "选项数"}],
         "qa": [q("质检合格线是多少？", 0.95, "number", accept=["95%"]), q("总共多少条视频？", 20000, "number"),
                q("每题几个选项？", 4, "number"), q("抽检比例是多少？", 0.1, "number", accept=["10%"])]})

F(key="ann_pdf", type="pdf", filename="数据标注服务合同_数芽.pdf", t="2026-10-12T18:00:00+08:00", source_app="邮件",
  persons=["p_zhou", "p_owner"], events=["ev_annot"],
  doc={"title": "数据标注服务合同", "lang": "zh", "letterhead": "合同编号 SY-2026-0918",
       "blocks": [("kv", [("合同编号", "SY-2026-0918"), ("委托方", "清屿大学视觉智能实验室"), ("服务方", "杭州数芽标注科技有限公司"),
                          ("签订日期", "2026年10月12日")]),
                  ("h", "第一条 服务内容"),
                  ("p", "服务方为委托方完成 KitchenQA 视频问答数据集的标注，共 20,000 条视频片段，每条至少 3 个问答对。"),
                  ("h", "第二条 价格"),
                  ("table", {"columns": ["项目", "数量（条）", "单价（元/条）", "金额（元）"], "rows": [["视频问答标注", "20,000", "1.8", "36,000"]]}),
                  ("p", "合同总价 36,000 元（含税）。"),
                  ("h", "第三条 交付与验收"),
                  ("p", "分 4 批交付，每批 5,000 条；委托方抽检 10%，合格率不低于 95% 视为该批验收通过，否则服务方须在 5 个工作日内返工。"),
                  ("table", {"columns": ["批次", "交付日期"], "rows": [["第1批", "2026年10月14日"], ["第2批", "2026年10月22日"],
                                                                 ["第3批", "2026年10月30日"], ["第4批", "2026年11月6日"]]}),
                  ("h", "第四条 付款"), ("p", "每批验收通过后 7 个工作日内支付该批费用 9,000 元。")]},
  truth={"key_fields": {"合同编号": "SY-2026-0918", "单价": 1.8, "总价": 36000, "每批费用": 9000, "第3批": "2026-10-30"},
         "numbers": [{"value": 20000, "label": "条数"}, {"value": 1.8, "label": "单价"}, {"value": 36000, "label": "总价"},
                     {"value": 9000, "label": "每批"}],
         "qa": [q("合同编号是多少？", "SY-2026-0918", "exact"), q("单价每条多少元？", 1.8, "number"),
                q("每批费用多少元？", 9000, "number"), q("第3批哪天交付？", "10月30日", accept=["2026-10-30"]),
                ]})

_quote = {"name": "报价", "title": "KitchenQA 标注报价（数芽标注）", "group_header": [(1, 3, "计价")],
          "columns": ["服务项", "数量(条)", "单价(元)", "金额(元)", "备注"],
          "rows": [["视频问答标注", 20000, 1.8, {"f": "=B4*C4", "v": 36000}, "每条≥3个问答对"],
                   ["加急费", 0, 0.3, {"f": "=B5*C5", "v": 0}, "未启用"],
                   ["合计", None, None, {"f": "=SUM(D4:D5)", "v": 36000}, "含税"]],
          "formats": {1: "num", 3: "num"}, "col_widths": [16, 10, 10, 12, 18]}
_settle = {"name": "结算", "columns": ["批次", "交付条数", "抽检合格率", "应付(元)", "状态"],
           "rows": [["第1批", 5000, 0.962, {"f": "=B2*1.8", "v": 9000}, "已验收"],
                    ["第2批", 5000, None, {"f": "=B3*1.8", "v": 9000}, "进行中"],
                    ["第3批", 5000, None, {"f": "=B4*1.8", "v": 9000}, "未开始"],
                    ["第4批", 5000, None, {"f": "=B5*1.8", "v": 9000}, "未开始"],
                    ["合计", {"f": "=SUM(B2:B5)", "v": 20000}, None, {"f": "=SUM(D2:D5)", "v": 36000}, ""]],
           "vmerge": [(4, 2, 3)], "formats": {1: "num", 2: "pct", 3: "num"}}
_contact = {"name": "联系人", "columns": ["角色", "姓名", "联系方式"],
            "rows": [["客户经理", "周蔓", "zhouman@example.com"], ["实验室财务", "顾青", "guqing@example.org"]]}
F(key="ann_xlsx", type="xlsx", filename="数芽报价与结算.xlsx", t="2026-10-13T13:30:00+08:00", source_app="邮件",
  persons=["p_zhou", "p_gu"], events=["ev_annot"], sheets=[_quote, _settle, _contact], title="数芽报价与结算",
  truth={"key_fields": {"第1批合格率": 0.962, "合计": 36000, "加急单价": 0.3, "客户经理": "周蔓"},
         "numbers": [{"value": 36000, "label": "合计"}, {"value": 0.962, "label": "第1批合格率"}, {"value": 9000, "label": "每批"}],
         "qa": [q("第1批抽检合格率是多少？", 96.2, "number", accept=["96.2%", "0.962"], tol=0.05),
                q("合计金额多少元？", 36000, "number"), q("加急费单价多少？", 0.3, "number"), q("客户经理是谁？", "周蔓")],
         "notes": "3 个工作表；合并标题、分组表头、纵向合并的状态列；金额和合计是带缓存值的公式；合格率是百分比格式的 0.962。"})

F(key="ann_csv", type="csv", filename="第1批质检报告.csv", t="2026-10-14T17:00:00+08:00", source_app="邮件",
  persons=["p_zhou"], events=["ev_annot"],
  csv={"columns": ["标注员ID", "交付条数", "抽检条数", "合格条数", "合格率"],
       "rows": [["A01", "1200", "120", "117", "97.5%"], ["A02", "1000", "100", "95", "95.0%"], ["A03", "1300", "130", "126", "96.9%"],
                ["A04", "1500", "150", "143", "95.3%"], ["合计", "5000", "500", "481", "96.2%"]],
       "encoding": "gb18030", "comment": "# 数芽标注 KitchenQA 第1批质检报告 2026-10-14（合成数据）"},
  truth={"key_fields": {"总体合格率": "96.2%", "最低": "A02", "抽检条数": 500, "合格条数": 481},
         "numbers": [{"value": 96.2, "label": "总体合格率"}, {"value": 500, "label": "抽检"}, {"value": 481, "label": "合格"}],
         "qa": [q("第1批总体合格率是多少？", 96.2, "number", accept=["96.2%"]), q("合格率最低的标注员是谁？", "A02", "exact"),
                q("一共抽检了多少条？", 500, "number")],
         "notes": "GB18030 编码，首行是注释行。"})

F(key="ann_docx", type="docx", filename="KitchenQA_第1批验收报告.docx", t="2026-10-15T10:00:00+08:00", source_app="微信",
  persons=["p_owner", "p_zhou", "p_he"], events=["ev_annot"],
  doc={"title": "KitchenQA 标注 第1批验收报告", "lang": "zh",
       "blocks": [("kv", [("合同编号", "SY-2026-0918"), ("批次", "第1批（5,000条）"), ("验收日期", "2026年10月15日"), ("验收人", "贺一鸣、沈知遥")]),
                  ("h", "抽检结果"), ("p", "抽检 500 条，合格 481 条，合格率 96.2%，高于合同约定的 95%。"),
                  ("h", "主要问题"), ("ul", ["计数类问题有 11 条答案错误（多数为遮挡导致漏数）", "8 条干扰项与正确答案语义重复"]),
                  ("h", "结论"), ("p", "第1批验收通过，同意支付第1批费用 9,000 元。第2批请于10月22日前交付，并对计数类问题增加复核。")]},
  truth={"key_fields": {"结论": "通过", "计数错误": 11, "支付": 9000, "第2批": "2026-10-22"},
         "numbers": [{"value": 96.2, "label": "合格率"}, {"value": 11, "label": "计数错误"}, {"value": 9000, "label": "支付"}],
         "qa": [q("第1批验收结论？", "通过"), q("计数类错了几条？", 11, "number"), q("同意支付多少元？", 9000, "number"),
                q("第2批什么时候前交？", "10月22日", accept=["2026-10-22"])]})

F(key="ann_webp", type="webp", filename="标注平台进度截图.webp", t="2026-10-16T15:20:00+08:00", source_app="微信",
  persons=["p_zhou"], events=["ev_annot"],
  visual={"style": "window", "app": "数芽标注平台 · 项目看板", "badge": "进行中",
          "lines": ["KitchenQA 视频问答标注", "项目进度总览（截至 2026-10-16 15:00）"],
          "table": {"columns": ["批次", "进度", "状态", "截止"],
                    "rows": [["第1批", "5,000/5,000", "已验收", "10-14"], ["第2批", "1,240/5,000", "标注中", "10-22"],
                             ["第3批", "0/5,000", "未开始", "10-30"], ["第4批", "0/5,000", "未开始", "11-06"]]}},
  truth={"key_fields": {"第2批进度": "1240/5000", "第2批截止": "10-22", "第4批截止": "11-06"},
         "numbers": [{"value": 1240, "label": "第2批已完成"}],
         "qa": [q("第2批完成了多少条？", 1240, "number"), q("第2批截止日期？", "10-22", accept=["10月22日"]),
                q("第4批截止日期？", "11-06", accept=["11月6日"])]})

# ============================== noise ==========================================================
F(key="noise_menu", type="jpg", filename="食堂本周菜单.jpg", t="2026-10-13T12:10:00+08:00", source_app="微信",
  persons=[], events=[], split="dev", tags=["noise"],
  visual={"style": "card", "photo": True, "title": "第二食堂 本周特色菜（10月12日—10月18日）", "w": 900,
          "lines": ["营业时间 11:00–13:30，17:00–19:00"],
          "table": {"columns": ["日期", "午餐特色", "价格"],
                    "rows": [["周一", "番茄牛腩饭", "16元"], ["周二", "酸菜鱼", "18元"], ["周三", "宫保鸡丁", "14元"],
                             ["周四", "清蒸鲈鱼", "22元"], ["周五", "素食自助", "12元"]]}},
  truth={"key_fields": {"周四": "清蒸鲈鱼", "素食自助": "12元"},
         "numbers": [{"value": 12, "label": "素食自助价"}],
         "qa": [q("周四的特色菜是什么？", "清蒸鲈鱼"), q("素食自助多少钱？", 12, "number"), q("午餐几点结束？", "13:30")]})

F(key="noise_gym", type="pdf", filename="健身中心团课时间表.pdf", t="2026-10-14T08:00:00+08:00", source_app="邮件",
  persons=[], events=[], split="test", tags=["noise"],
  doc={"title": "校健身中心 10月团课时间表", "lang": "zh",
       "blocks": [("table", {"columns": ["课程", "时间", "教练", "教室"],
                             "rows": [["瑜伽", "周一 19:00", "严老师", "操房1"], ["动感单车", "周二 18:30", "韩教练", "单车房"],
                                      ["普拉提", "周四 19:30", "严老师", "操房2"], ["搏击操", "周六 10:00", "韩教练", "操房1"]]}),
                  ("p", "每节课限 20 人，需提前一天在小程序预约。")]},
  truth={"key_fields": {"普拉提": "周四 19:30", "限额": 20},
         "numbers": [{"value": 20, "label": "每节限额"}],
         "qa": [q("普拉提在什么时间？", "周四 19:30"), q("每节课限多少人？", 20, "number"), q("动感单车的教练是谁？", "韩教练")]})

# ---------------------------------------------------------------------------------------------- chat pastes
CHATS = [
    {"key": "chat_he_run42", "t": "2026-10-14T21:10:00+08:00", "source_app": "微信", "persons": ["p_he"], "events": ["ev_paper"],
     "text": "贺一鸣：沈老师，run42 在 test 上平均 78.4，比 baseline 75.3 高 3.1 个点，结果 json 发群里了。摘要我周四（10月15日）上午提交可以吗？"},
    {"key": "chat_gu_invoice", "t": "2026-10-16T14:30:00+08:00", "source_app": "微信", "persons": ["p_gu"], "events": ["ev_gpu"],
     "text": "顾青：沈老师，第一台服务器的发票收到了，598000元，我下周一（10月19日）去财务报销；第二台23号到。"},
    {"key": "chat_lin_move", "t": "2026-10-13T18:20:00+08:00", "source_app": "微信", "persons": ["p_lin", "p_xu", "p_fang"],
     "events": ["ev_defense"],
     "text": "林晓棠：沈老师，许老师周三下午有课，答辩改到10月15日（周四）下午两点，地点还是B312，我已经跟方老师确认了。"},
    {"key": "chat_ma_pay", "t": "2026-10-16T16:00:00+08:00", "source_app": "微信", "persons": ["p_ma"], "events": ["ev_collab"],
     "text": "马骏：沈老师，20号验收我们质量部赵工和我都在，第二期18万等验收签字后走流程，大概月底到账。"},
    {"key": "chat_park_delay", "t": "2026-10-15T16:40:00+08:00", "source_app": "微信", "persons": ["p_park"], "events": ["ev_talk"],
     "text": "Elena Park: Zhiyao, quick update: ZY 5718 is delayed. New arrival time is 22:40 instead of 19:10. Could you let the driver and the hotel know? Sorry for the late night!"},
    {"key": "chat_zhou_batch", "t": "2026-10-15T11:30:00+08:00", "source_app": "微信", "persons": ["p_zhou", "p_gu"], "events": ["ev_annot"],
     "text": "周蔓：沈老师好～第1批验收报告收到啦，9000元的请款单我今天发给顾老师。第2批22号前交，计数题我们加一道复核。"},
    {"key": "chat_parcel", "t": "2026-10-15T09:00:00+08:00", "source_app": "短信", "persons": [], "events": [], "split": "test",
     "tags": ["noise"], "text": "【快递】您的包裹已由计算机楼驿站代收，取件码 6-2-3107，请于3日内领取。"},
]

# ---------------------------------------------------------------------------------------------- facts
FACTS = [
    ("f_paper_ddl", "ev_paper", "全文截止10月23日", ["10月23日"], "paper_todo", None, "planned", "2026-10-23"),
    ("f_paper_res_1", "ev_paper", "run37 平均准确率76.9", ["76.9"], "paper_xlsx", "f_paper_res_2", "info", None),
    ("f_paper_res_2", "ev_paper", "run42 平均准确率78.4，比baseline高3.1", ["78.4"], "chat_he_run42", None, "info", None),
    ("f_paper_abs", "ev_paper", "摘要已提交（Paper ID 4127）", ["4127"], "paper_pdf", None, "done", None),
    ("f_gpu_vendor", "ev_gpu", "选定恒算科技，2台共119.6万", ["恒算", "1196000"], "gpu_ods", None, "info", None),
    ("f_gpu_contract", "ev_gpu", "合同HS-2026-1017已签", ["HS-2026-1017"], "gpu_contract", None, "done", None),
    ("f_gpu_arrive1", "ev_gpu", "第一台10月16日到货签收", ["10月16日"], "gpu_jpg", None, "done", None),
    ("f_gpu_second", "ev_gpu", "第二台10月23日到", ["10月23日"], "gpu_contract", None, "planned", "2026-10-23"),
    ("f_def_date_1", "ev_defense", "答辩10月14日14:00在B312", ["10月14日"], "def_ics", "f_def_date_2", "planned", "2026-10-14"),
    ("f_def_date_2", "ev_defense", "答辩改到10月15日14:00", ["10月15日"], "chat_lin_move", "f_def_pass", "planned", "2026-10-15"),
    ("f_def_pass", "ev_defense", "开题答辩通过", ["通过"], "def_tiff", None, "done", None),
    ("f_def_revise", "ev_defense", "修改稿10月25日前交", ["10月25日"], "def_txt", None, "planned", "2026-10-25"),
    ("f_col_accept", "ev_collab", "中期验收10月20日在苏州工厂", ["10月20日"], "col_csv", None, "planned", "2026-10-20"),
    ("f_col_pay2", "ev_collab", "验收后付第二期18万", ["180000"], "col_csv", None, "planned", None),
    ("f_col_map", "ev_collab", "v1.2 mAP 0.873", ["0.873"], "col_xml", None, "info", None),
    ("f_talk_time", "ev_talk", "讲座10月16日15:00在A101", ["10月16日", "A101"], "talk_ics", None, "planned", "2026-10-16"),
    ("f_talk_arr_1", "ev_talk", "10月15日19:10到达", ["19:10"], "talk_eml", "f_talk_arr_2", "planned", "2026-10-15"),
    ("f_talk_arr_2", "ev_talk", "航班延误，22:40到达", ["22:40"], "chat_park_delay", None, "planned", "2026-10-15"),
    ("f_talk_hotel", "ev_talk", "酒店确认号QYH-88213", ["QYH-88213"], "talk_webarchive", None, "info", None),
    ("f_ann_price", "ev_annot", "2万条×1.8元共3.6万", ["36000"], "ann_pdf", None, "info", None),
    ("f_ann_b1", "ev_annot", "第1批合格率96.2%验收通过", ["96.2"], "ann_docx", None, "done", None),
    ("f_ann_b2", "ev_annot", "第2批10月22日前交", ["10月22日"], "ann_pdf", None, "planned", "2026-10-22"),
]

# checkpoint: (id, label, after key, {event: [fact ids]})
CHECKPOINTS = [
    ("cp-mid", "10月14日晚", "chat_he_run42",
     {"ev_paper": ["f_paper_ddl", "f_paper_res_2"], "ev_gpu": ["f_gpu_vendor", "f_gpu_contract"],
      "ev_defense": ["f_def_date_2"], "ev_collab": ["f_col_accept", "f_col_map"],
      "ev_talk": ["f_talk_time", "f_talk_arr_1"], "ev_annot": ["f_ann_price"]}),
    ("cp-final", "10月16日晚（最终）", None,
     {"ev_paper": ["f_paper_ddl", "f_paper_res_2", "f_paper_abs"], "ev_gpu": ["f_gpu_arrive1", "f_gpu_second"],
      "ev_defense": ["f_def_pass", "f_def_revise"], "ev_collab": ["f_col_accept", "f_col_pay2"],
      "ev_talk": ["f_talk_time", "f_talk_arr_2"], "ev_annot": ["f_ann_b1", "f_ann_b2"]}),
]
