"""Gold fact table for scale-pm, derived from source/bible.json (arc facts).

Partial supersessions in the bible (E01-f1, E04-f9, E11-f4, E14-f8's parts) are split into sub-facts so each
fact has at most one successor. keys = what a correct one-line status must contain (score.py normalisation).
first = key of the plan item that first conveys the fact (see fixed.py). resolved = a later fact that makes a
planned fact no longer pending (not a supersession: the plan came true).
"""

# (fact_id, event, date, time, state, text, keys, due, superseded_by, resolved_by, first_item_key, sensitive)
F = [
    # E01 小澄
    ("E01-f1a", "E01", "08-10", "state", "planned", "部门周会定节奏：8/18 提测", ["8月18日"], "08-18", "E01-f3", None, "M:dept_0810", None),
    ("E01-f1b", "E01", "08-10", "", "planned", "8/24 灰度 5%", ["8月24日"], "08-24", None, "E01-f6", "M:dept_0810", None),
    ("E01-f1c", "E01", "08-10", "", "planned", "9/10 全量", ["9月10日"], "09-10", "E01-f9", None, "M:dept_0810", None),
    ("E01-f2", "E01", "08-12", "", "done", "PRD v2.1 评审通过；跨店比价砍到 v1.1，v1.0 只做问答导购 + 一键加购", ["v2.1|比价"], None, None, None, "M:prd_review_0812", None),
    ("E01-f3", "E01", "08-17", "", "planned", "前端对话卡片没做完，提测从 8/18 推到 8/19", ["8月19日"], "08-19", None, "E01-f4", "C:0817_luo_card", None),
    ("E01-f4", "E01", "08-19", "", "done", "提测完成，唐雨桐确认进入测试", ["提测"], None, None, None, "C:0819_tang_test", None),
    ("E01-f5", "E01", "08-21", "", "done", "PRD v2.3 发出：加 AI 生成标识、对话日志留存 30 天、未成年人模式隐藏入口", ["v2.3"], None, None, None, "P:prd23", None),
    ("E01-f6", "E01", "08-24", "", "done", "灰度 5% 上线（安卓 + iOS 16 以上，约 38 万用户）", ["5%"], None, None, None, "C:0824_warroom_gray5", None),
    ("E01-f7", "E01", "08-26", "", "in_progress", "22:40 因积分重复扣减故障暂停小澄灰度，并关闭积分一键抵扣开关", ["暂停"], None, None, None, "C:0826_inc_forward", None),
    ("E01-f8", "E01", "08-31", "", "in_progress", "修复后恢复 5% 灰度，积分一键抵扣继续关着", ["恢复"], None, None, None, "M:dept_0831", None),
    ("E01-f9", "E01", "09-02", "", "planned", "全量从 9/10 推到 9/17；条件是合规脱敏验证完成 + 对账有临时方案", ["9月17日"], "09-17", None, "E01-f13", "M:biweekly_0902", None),
    ("E01-f10", "E01", "09-07", "", "done", "灰度扩到 30%", ["30%"], None, None, None, "S:dash_gray30", None),
    ("E01-f11", "E01", "09-11", "", "planned", "第二次 Go/NoGo 通过：9/17 上午 10 点全量，积分一键抵扣随全量重新打开", ["9月17日", "10点|10:00"], "09-17", None, "E01-f13", "M:gonogo_0911", None),
    ("E01-f12", "E01", "09-14", "", "done", "灰度扩到 60%", ["60%"], None, None, None, "M:standup_0914", None),
    ("E01-f13", "E01", "09-17", "", "done", "9/17 10:00 全量上线", ["全量"], None, None, None, "C:0917_warroom_full", None),
    ("E01-f14", "E01", "09-18", "", "done", "首日数据：使用率 4.2%，导购转化率比对照组高 11%，无 P1/P2 告警", ["4.2%"], None, None, None, "S:dash_day1", None),
    ("E01-f14b", "E01", "09-18", "", "planned", "上线一周数据报告 9/24 交周启明", ["9月24日"], "09-24", None, None, "C:0918_week_report", None),
    # E02 会员频道 3.0
    ("E02-f1", "E02", "08-10", "", "planned", "会员频道 3.0 目标 8/31 上线", ["8月31日"], "08-31", "E02-f5", None, "M:dept_0810", None),
    ("E02-f2", "E02", "08-13", "", "in_progress", "设计评审 v1 被打回：等级卡太像信用卡，苏蔓 8/20 出 v2", ["信用卡"], "08-20", None, "E02-f3", "S:design_card_v1", None),
    ("E02-f3", "E02", "08-20", "", "done", "设计 v2 通过，两处小改：等级进度条、兑换按钮颜色", ["v2"], None, None, None, "M:design_0820", None),
    ("E02-f4", "E02", "08-24", "", "in_progress", "开始联调；积分商城依赖支付积分抵现 v2 接口，接口还没提测", ["联调"], None, None, None, "M:dept_0824", None),
    ("E02-f5", "E02", "08-26", "", "planned", "会员频道上线从 8/31 推到 9/8", ["9月8日"], "09-08", None, "E02-f7", "M:member_0826", None),
    ("E02-f6", "E02", "09-07", "", "done", "与支付联调通过", ["联调"], None, None, None, "C:0907_member_joint", None),
    ("E02-f7", "E02", "09-08", "", "done", "会员频道灰度 10%", ["10%"], None, None, None, "C:0908_member_gray", None),
    ("E02-f8", "E02", "09-11", "", "done", "会员频道全量上线", ["全量"], None, None, None, "C:0911_member_full", None),
    ("E02-f9", "E02", "09-15", "", "done", "首周积分兑换率 +18%，客诉 7 起（多是待到账积分看不懂）", ["18%"], None, None, None, "C:0915_qin_week1", None),
    ("E02-f10", "E02", "09-16", "", "planned", "陆小蕾排好中秋积分翻倍活动，9/20–9/27", ["9月20日"], "09-20", None, None, "C:0916_lily_double", None),
    # E03 搜索入口 AB
    ("E03-f1", "E03", "08-19", "", "planned", "向曹磊申请首页搜索框下方的问问小澄入口", ["入口"], None, None, None, "C:0819_cao_ask", None),
    ("E03-f2", "E03", "08-25", "", "in_progress", "曹磊只肯给二级入口（搜索结果页底部），担心分走搜索 GMV", ["结果页|二级"], None, "E03-f3", None, "C:0825_cao_second", None),
    ("E03-f3", "E03", "09-02", "", "planned", "周启明拍板：做 AB 实验，首页入口 vs 结果页入口 50/50，跑两周", ["ab"], None, None, "E03-f4", "M:biweekly_0902", None),
    ("E03-f4", "E03", "09-10", "", "in_progress", "AB 实验上线，秦朗配实验、罗一鸣开发", ["上线"], None, None, None, "C:0910_ab_live", None),
    ("E03-f5", "E03", "09-18", "", "in_progress", "跑了 8 天：首页入口点击率 3.1% vs 结果页 1.2%；搜索 GMV -0.4%（不显著）", ["3.1%"], None, None, None, "S:dash_ab", None),
    ("E03-f6", "E03", "09-18", "", "planned", "9/24 实验满两周，秦朗出报告，周启明定是否固化首页入口", ["9月24日"], "09-24", None, None, "C:0918_qin_ab_report", None),
    # E04 故障
    ("E04-f1", "E04", "08-26", "", "in_progress", "21:52 告警：积分扣减接口重试导致部分订单重复扣积分；林澈拉群 INC-0826", ["重复扣"], None, None, None, "S:alert_0826", None),
    ("E04-f2", "E04", "08-26", "", "done", "22:40 止血：关闭小澄积分一键抵扣开关、暂停小澄灰度", ["止血|关闭|关掉|关了"], None, None, None, "C:0826_inc_forward", None),
    ("E04-f3", "E04", "08-27", "", "done", "影响 1,284 名用户，多扣积分合计 367,400（约合 3,674 元）", ["1284"], None, None, None, "S:dash_loss", "资损"),
    ("E04-f4", "E04", "08-27", "", "planned", "林澈按涉及资损先定 P1", ["p1"], None, "E04-f8", None, "C:0827_inc_p1", None),
    ("E04-f5", "E04", "08-27", "", "planned", "补偿：原路退回 + 每人补 50 积分致歉；白露出客服话术", ["50"], None, None, "E04-f6", "M:emergency_0827", None),
    ("E04-f6", "E04", "08-28", "", "done", "补偿执行完（贺子轩脚本），客服话术上线", ["补偿"], None, None, None, "C:0828_cs_comp_done", None),
    ("E04-f7", "E04", "08-28", "", "done", "根因：支付回调超时触发重试，积分服务幂等键没带订单子号；幂等修复 8/30 上线", ["幂等"], None, None, None, "M:retro_0828", None),
    ("E04-f8", "E04", "09-02", "", "done", "稳定性委员会改定级 P2（资损低于 5,000 元门槛）", ["p2"], None, None, None, "M:biweekly_0902", None),
    ("E04-f9a", "E04", "09-05", "", "planned", "改进项：对账告警（孙浩）9/15", ["对账", "9月15日"], "09-15", "E04-f12", None, "P:retro_report", None),
    ("E04-f9b", "E04", "09-05", "", "planned", "改进项：开关演练（林澈）9/9", ["演练", "9月9日"], "09-09", None, "E04-f10", "P:retro_report", None),
    ("E04-f9c", "E04", "09-05", "", "planned", "改进项：灰度期资损看板（秦朗）9/12", ["看板", "9月12日"], "09-12", None, "E04-f11", "P:retro_report", None),
    ("E04-f10", "E04", "09-09", "", "done", "开关演练完成", ["演练"], None, None, None, "C:0909_linche_drill", None),
    ("E04-f11", "E04", "09-12", "", "done", "灰度期资损看板上线", ["看板"], None, None, None, "S:dash_loss_board", None),
    ("E04-f12", "E04", "09-15", "", "planned", "对账告警延期到 9/30（孙浩被中秋活动需求占住）", ["9月30日"], "09-30", None, None, "K:0915_recon_delay", None),
    # E05 BUG-4471
    ("E05-f1", "E05", "08-20", "", "in_progress", "唐雨桐在测试环境提 BUG-4471，P2 缺陷：积分商城页余额和我的页不一致", ["4471"], None, None, None, "S:bug_4471", None),
    ("E05-f2", "E05", "08-22", "", "in_progress", "贺子轩定位：积分商城页读缓存，TTL 10 分钟", ["缓存"], None, None, None, "C:0822_he_cache", None),
    ("E05-f3", "E05", "08-25", "", "done", "第一次修复上测试环境", ["修复"], None, "E05-f4", None, "D:0825_bug_export", None),
    ("E05-f4", "E05", "08-27", "", "in_progress", "回归复现、重新打开：兑换完立刻返回就不一致", ["重新打开|重开|reopen"], None, None, None, "C:0827_member_reopen", None),
    ("E05-f5", "E05", "09-02", "", "in_progress", "第二次修复：兑换成功后主动让缓存失效", ["失效"], None, None, None, "M:member_0902", None),
    ("E05-f6", "E05", "09-03", "", "done", "回归通过，9/4 关单", ["关单"], None, None, None, "D:0903_bug_export", None),
    ("E05-f7", "E05", "09-13", "", "in_progress", "全量后客服转来 3 起余额对不上，查明是待到账积分没显示，不是缺陷复发", ["待到账"], None, None, None, "C:0913_cs_balance", None),
    ("E05-f8", "E05", "09-16", "", "done", "文案改为 可用 xx（另有 xx 待到账）并上线", ["文案"], None, None, None, "C:0916_member_copy", None),
    # E06 支付接口
    ("E06-f1", "E06", "08-14", "", "planned", "给沈之恒提需求：积分抵现 v2 接口，希望 8/24 前提测", ["8月24日"], "08-24", "E06-f4", None, "E:0814_req_shen", None),
    ("E06-f2", "E06", "08-18", "", "in_progress", "沈之恒回复：Q3 排满，最早 10 月", ["10月"], None, None, None, "E:0818_shen_reply", None),
    ("E06-f3", "E06", "08-21", "", "in_progress", "抄送韩立峰、周启明升级", ["升级"], None, None, None, "E:0821_escalate", None),
    ("E06-f4", "E06", "08-25", "", "planned", "对齐会：支付同意插队，9/1 提测", ["9月1日"], "09-01", "E06-f5", None, "M:pay_align_0825", None),
    ("E06-f5", "E06", "09-01", "", "planned", "孙浩：人被故障修复占了，提测延到 9/4", ["9月4日"], "09-04", None, "E06-f6", "C:0901_sunhao_delay", None),
    ("E06-f6", "E06", "09-04", "", "done", "积分抵现 v2 接口提测", ["提测"], None, None, None, "C:0904_member_api", None),
    ("E06-f7", "E06", "09-07", "", "done", "积分抵现接口联调通过", ["联调"], None, None, None, "C:0907_member_joint", None),
    # E07 合规
    ("E07-f1", "E07", "08-13", "", "in_progress", "梁晨提交合规评审单 LGL-2026-117", ["117"], None, None, None, "E:0813_lgl_submit", None),
    ("E07-f2", "E07", "08-19", "", "in_progress", "首轮不通过，魏婷三条：回答标 AI 生成；日志留存 180 天降到 30 天；未成年人模式下关闭小澄", ["不通过"], None, "E07-f5", None, "P:compliance_opinion", None),
    ("E07-f3", "E07", "08-21", "", "done", "三条合规意见都写进 PRD v2.3", ["v2.3"], None, None, None, "P:prd23", None),
    ("E07-f4", "E07", "08-27", "", "in_progress", "二轮评审：方可要求补日志脱敏方案", ["脱敏"], None, None, None, "M:compliance_0827", None),
    ("E07-f5", "E07", "09-03", "", "planned", "有条件通过：上线前完成日志脱敏验证", ["有条件"], None, "E07-f6", None, "E:0903_lgl_conditional", None),
    ("E07-f6", "E07", "09-10", "", "done", "方可验证脱敏完成，合规正式通过", ["正式通过"], None, None, None, "C:0910_fangke_pass", None),
    # E08 标注
    ("E08-f1", "E08", "08-11", "", "planned", "马骁要 2,000 条真实意图评测 query，找外包标注", ["2000"], None, None, None, "M:xc_0811", None),
    ("E08-f2", "E08", "08-17", "", "in_progress", "黄莉报价 96,000 元（48 元/条）", ["96000"], None, "E08-f3", None, "P:label_quote", None),
    ("E08-f3", "E08", "08-20", "", "planned", "谈到 72,000 元（36 元/条），郑启批了预算", ["72000"], None, None, None, "C:0820_huangli_price", None),
    ("E08-f4", "E08", "08-28", "", "done", "第一批 800 条交付，抽检一致率 88%", ["88%"], None, None, None, "P:label_delivery1", None),
    ("E08-f5", "E08", "09-04", "", "done", "标注合同盖章（比开工晚一周多）", ["盖章|盖了"], None, None, None, "K:0904_contract_seal", None),
    ("E08-f6", "E08", "09-07", "", "done", "2,000 条全部交付", ["2000"], None, None, None, "M:zoom_label_0907", None),
    ("E08-f7", "E08", "09-09", "", "in_progress", "马骁首轮评测：回答可用率 81%；把竞品报告里的 30 个 query 补进评测集", ["81%"], None, None, None, "C:0909_maxiao_eval", None),
    ("E08-f8", "E08", "09-14", "", "done", "调 prompt 后可用率 87%", ["87%"], None, None, None, "C:0914_maxiao_87", None),
    # E09 沟通会演示
    ("E09-f1", "E09", "08-18", "", "planned", "9/16 秋季沟通会给小澄 5 分钟演示", ["5分钟"], "09-16", "E09-f3", None, "E:0818_rundown", None),
    ("E09-f2", "E09", "09-04", "", "in_progress", "演示脚本 v1（Claude 改过一版）", ["脚本"], None, None, None, "A:0904_demo_script", None),
    ("E09-f3", "E09", "09-09", "", "planned", "周启明：演示压到 3 分钟，不提比价，由江予安上台", ["3分钟"], "09-16", None, "E09-f6", "S:chat_zhou_demo", None),
    ("E09-f4", "E09", "09-14", "", "in_progress", "彩排一：演示账号网络卡，准备录屏兜底", ["录屏"], None, None, None, "M:rehearsal_0914", None),
    ("E09-f5", "E09", "09-15", "", "done", "彩排二通过", ["彩排"], None, None, None, "K:0915_rehearsal2", None),
    ("E09-f6", "E09", "09-16", "", "done", "沟通会演示完成（现场实时演示，没切录屏）", ["完成|顺利|讲完"], None, None, None, "K:0916_demo_done", None),
    ("E09-f7", "E09", "09-17", "", "done", "推文随全量发出", ["推文"], None, None, None, "C:0917_kexin_post", None),
    # E10 OKR
    ("E10-f1", "E10", "08-31", "", "planned", "Q4 OKR 草案 9/19 前交韩立峰", ["9月19日"], "09-19", None, "E10-f5", "M:dept_0831", None),
    ("E10-f2", "E10", "09-07", "", "in_progress", "OKR v1：4 个 O、11 个 KR", ["11个kr"], None, "E10-f3", None, "D:0907_okr_comments", None),
    ("E10-f3", "E10", "09-12", "", "in_progress", "OKR v2：砍到 3 个 O、8 个 KR（会员活跃并进小澄渗透）", ["8个kr"], None, None, None, "K:0912_okr_v2", None),
    ("E10-f4", "E10", "09-15", "", "in_progress", "郑启给积分成本上限：每季度 420 万元", ["4200000"], None, None, None, "E:0915_zhengqi_cap", None),
    ("E10-f5", "E10", "09-19", "", "done", "OKR v3 提交给韩立峰", ["v3"], None, None, None, "E:0919_okr_v3", None),
    # E11 招聘（江予安是面试官）
    ("E11-f1", "E11", "08-12", "", "in_progress", "顾南发布 JD：HC-2026-031", ["hc-2026-031|jd"], None, None, None, "E:0812_jd", None),
    ("E11-f2", "E11", "08-20", "", "done", "候选人蒋文一面通过", ["蒋文"], None, None, None, "M:hc_jiangwen_0820", "面评"),
    ("E11-f3", "E11", "08-27", "", "done", "候选人邱宇一面不通过", ["邱宇"], None, None, None, "K:0827_qiuyu_review", "面评"),
    ("E11-f4a", "E11", "09-03", "", "done", "蒋文二面（韩立峰）通过", ["二面"], None, None, None, "C:0903_gunan_2nd", "面评"),
    ("E11-f4b", "E11", "09-03", "", "planned", "蒋文 HR 面原定 9/15", ["9月15日"], "09-15", "E11-f5", None, "C:0903_gunan_2nd", None),
    ("E11-f5", "E11", "09-10", "", "cancelled", "Q4 冻结 HC，这个 HC 取消，9/15 的 HR 面不做了", ["冻结"], None, None, None, "S:chat_zhou_hcfreeze", None),
    ("E11-f6", "E11", "09-14", "", "done", "顾南给蒋文发了婉拒", ["婉拒"], None, None, None, "C:0914_gunan_decline", None),
    # E12 团队绩效
    ("E12-f1", "E12", "08-17", "", "planned", "年中绩效：自评 8/28 截止、主管初评 9/2、校准会 9/4、结果 9/11 提交", ["校准"], "09-04", None, "E12-f4", "E:0817_perf_kickoff", None),
    ("E12-f2", "E12", "08-31", "", "in_progress", "吴迪急性胃肠炎住院两天，8/31–9/2 请病假", ["病假"], None, None, None, "C:0831_wudi_sick", "健康"),
    ("E12-f3", "E12", "09-01", "", "in_progress", "初评：赵一帆 A、梁晨 B+、吴迪 C", ["b+"], None, "E12-f4", None, "K:0901_perf_draft", "绩效"),
    ("E12-f4", "E12", "09-04", "", "done", "校准会：梁晨 B+ 调成 B；赵一帆保住 A；吴迪维持 C", ["校准"], None, None, None, "K:0904_calibration", "绩效"),
    ("E12-f5", "E12", "09-08", "", "done", "和吴迪 1:1 反馈，他情绪低，提到想转去做数据产品", ["数据产品"], None, None, None, "M:oo_wudi_0908", "绩效"),
    ("E12-f6", "E12", "09-11", "", "done", "绩效结果提交", ["提交"], None, None, None, "E:0911_perf_submit", "绩效"),
    ("E12-f7", "E12", "09-15", "", "planned", "吴迪改进计划 3 项，10/15 复盘", ["10月15日"], "10-15", None, None, "D:0915_wudi_plan", "绩效"),
    # E13 我的晋升
    ("E13-f1", "E13", "08-14", "", "planned", "韩立峰提名 L7→L8，答辩 9/9", ["9月9日"], "09-09", None, "E13-f4", "M:oo_han_0814", None),
    ("E13-f2", "E13", "08-25", "", "in_progress", "述职材料 v1（20 页）", ["20页"], None, "E13-f3", None, "P:promo_v1", None),
    ("E13-f3", "E13", "09-02", "", "in_progress", "预答辩：韩立峰让砍到 12 页，主线讲小澄", ["12页"], None, None, None, "M:prepromo_0902", None),
    ("E13-f4", "E13", "09-09", "", "done", "晋升答辩完成（评委周启明 + 两位其他部门总监）", ["答辩"], None, None, None, "K:0909_defense_done", None),
    ("E13-f5", "E13", "09-18", "", "done", "晋升通过，升 L8，调薪 15%，10/1 生效", ["15%"], None, None, None, "E:0918_promo_result", "薪酬"),
    # E14 栖木
    ("E14-f1", "E14", "08-11", "", "in_progress", "叶知秋内推栖木智能 AI Agent 产品总监", ["内推"], None, None, None, "C:0811_ye_referral", None),
    ("E14-f2", "E14", "08-14", "", "done", "栖木一面：田野（CTO），Zoom，晚 19:30", ["一面"], None, None, None, "K:0814_qimu_1st", None),
    ("E14-f3", "E14", "08-21", "", "done", "栖木二面：周屹（CEO），线下，公司楼下咖啡馆", ["二面"], None, None, None, "K:0821_qimu_2nd", None),
    ("E14-f4", "E14", "08-24", "", "planned", "案例作业《企业 AI Agent 的商业化路径》，9/1 前交", ["9月1日"], "09-01", None, "E14-f5", "E:0824_qimu_case", None),
    ("E14-f5", "E14", "09-01", "", "done", "案例作业已提交", ["作业"], None, None, None, "E:0901_case_submit", None),
    ("E14-f6", "E14", "09-04", "", "done", "栖木三面：作业汇报，周屹 + 田野，Zoom", ["三面"], None, None, None, "K:0904_qimu_3rd", None),
    ("E14-f7", "E14", "09-08", "", "done", "栖木 HR 面：王蕊电话，问期望薪资与到岗时间", ["hr面"], None, None, None, "K:0908_qimu_hr", "薪酬"),
    ("E14-f8", "E14", "09-11", "", "planned", "栖木口头 offer：base 75,000×14，期权 0.15%（4 年成熟），总监职级", ["75000"], None, "E14-f11", None, "K:0911_qimu_verbal", "薪酬"),
    ("E14-f9", "E14", "09-15", "", "planned", "栖木书面 offer：入职 10/19，9/25 前答复", ["9月25日"], "09-25", None, None, "P:qimu_offer", "薪酬"),
    ("E14-f10", "E14", "09-18", "", "in_progress", "王蕊要两个背调联系人；给了孔维和一位前同事，不留现公司的人", ["背调"], None, None, None, "C:0918_wangrui_ref", "背调"),
    ("E14-f11", "E14", "09-19", "", "planned", "还价后王蕊同意 base 78,000×14，期权不变；答复截止仍 9/25", ["78000"], "09-25", None, None, "C:0919_wangrui_78", "薪酬"),
    # E15 鹭洲
    ("E15-f1", "E15", "08-13", "", "in_progress", "猎头陈可（远岫人才）推鹭洲集团电商增长高级产品专家", ["陈可|猎头"], None, None, None, "C:0813_chenke_intro", None),
    ("E15-f2", "E15", "08-19", "", "done", "鹭洲一面：宋文博，腾讯会议视频，晚 20:00", ["一面"], None, None, None, "K:0819_luzhou_1st", None),
    ("E15-f3", "E15", "08-24", "", "planned", "鹭洲二面约在 8/26 晚 20:00（王振东）", ["8月26日"], "08-26", "E15-f4", None, "C:0824_chenke_2nd", None),
    ("E15-f4", "E15", "08-26", "", "planned", "故障走不开，鹭洲二面改到 8/28 晚 20:00", ["8月28日"], "08-28", None, "E15-f5", "K:0826_night_dump", None),
    ("E15-f5", "E15", "08-28", "", "done", "鹭洲二面完成", ["二面"], None, None, None, "K:0828_luzhou_2nd_done", None),
    ("E15-f6", "E15", "09-02", "", "done", "鹭洲三面交叉面：彭越", ["三面|交叉面"], None, None, None, "K:0902_luzhou_3rd", None),
    ("E15-f7", "E15", "09-09", "", "done", "鹭洲 HR 孟佳谈薪，报期望 base 80,000", ["80000"], None, None, None, "K:0909_luzhou_hr", "薪酬"),
    ("E15-f8", "E15", "09-12", "", "in_progress", "孟佳：部门 HC 调整，鹭洲流程暂停", ["暂停"], None, "E15-f9", None, "C:0912_mengjia_pause", None),
    ("E15-f9", "E15", "09-16", "", "in_progress", "鹭洲流程恢复", ["恢复"], None, None, None, "C:0916_chenke_resume", None),
    ("E15-f10", "E15", "09-18", "", "planned", "鹭洲 offer：base 68,000×16 + 签字费 100,000 + RSU 400,000（4 年）", ["68000"], None, None, None, "S:offer_luzhou", "薪酬"),
    ("E15-f11", "E15", "09-20", "", "cancelled", "电话告诉陈可，婉拒鹭洲", ["婉拒"], None, None, None, "K:0920_decline_luzhou", None),
    # E16 去留
    ("E16-f1", "E16", "08-16", "", "in_progress", "和程远聊：去创业公司的话房贷月供 18,600 能不能扛；程远说先面着看", ["18600"], None, None, None, "C:0816_chengyuan_mortgage", "家庭财务"),
    ("E16-f2", "E16", "09-06", "", "in_progress", "孔维建议：创业公司期权按 0 算，只比现金；看 CEO 的融资节奏", ["期权"], None, None, None, "K:0906_kongwei_advice", "薪酬"),
    ("E16-f3", "E16", "09-13", "", "in_progress", "三方对比表 v1（现职按 base 58,000×15 + 年终 3 个月算）", ["58000"], None, "E16-f4", None, "A:0913_compare_v1", "薪酬"),
    ("E16-f4", "E16", "09-18", "", "in_progress", "晋升后对比表 v2：留下 base 约 66,700×15", ["66700"], None, None, None, "A:0918_compare_v2", "薪酬"),
    ("E16-f5", "E16", "09-19", "", "in_progress", "程远支持去栖木，条件是年底前别再天天 11 点下班", ["支持"], None, None, None, "C:0919_chengyuan_support", None),
    ("E16-f6", "E16", "09-20", "", "planned", "倾向栖木；9/22 找韩立峰谈；9/25 前答复栖木", ["9月22日", "9月25日"], "09-22", None, None, "K:0920_decision", None),
    # E17 Codex 脚本
    ("E17-f1", "E17", "08-22", "", "planned", "秦朗吐槽小澄埋点 CSV 太脏，决定用 Codex 写清洗脚本", ["脚本"], None, None, None, "C:0822_qin_csv", None),
    ("E17-f2", "E17", "08-23", "", "done", "清洗脚本 v1 跑通样例", ["v1"], None, "E17-f3", None, "A:0823_codex_v1", None),
    ("E17-f3", "E17", "08-29", "", "done", "清洗脚本 v2：修了会话断点和时区（UTC 被当成本地时间）", ["v2"], None, None, None, "A:0829_codex_v2", None),
    ("E17-f4", "E17", "09-05", "", "done", "秦朗开始用，周报取数从 2 小时缩到 10 分钟", ["10分钟"], None, None, None, "C:0905_qin_uses", None),
    ("E17-f5", "E17", "09-12", "", "done", "清洗脚本 v3：加小澄灰度分桶字段", ["v3"], None, None, None, "A:0912_codex_v3", None),
    # E18 AI 分享
    ("E18-f1", "E18", "08-20", "", "planned", "金牧邀请在 AI 学习小组分享", ["分享"], None, None, None, "C:0820_jinmu_invite", None),
    ("E18-f2", "E18", "08-27", "", "planned", "定题《产品经理怎么用 Claude 和 Codex》，9/10 周四 16:00，45 分钟", ["45分钟"], "09-10", "E18-f4", None, "C:0827_jinmu_topic", None),
    ("E18-f3", "E18", "09-05", "", "in_progress", "分享大纲 v1", ["大纲"], None, None, None, "K:0905_share_outline", None),
    ("E18-f4", "E18", "09-08", "", "in_progress", "金牧要求加 Codex 实操（拿埋点清洗脚本当例子），时长加到 60 分钟", ["60分钟"], "09-10", None, "E18-f5", "C:0908_jinmu_60", None),
    ("E18-f5", "E18", "09-10", "", "done", "分享完成，到场 63 人", ["63"], None, None, None, "M:share_0910", None),
    ("E18-f6", "E18", "09-11", "", "done", "分享反馈 4.7/5；金牧约 10 月再讲一次（日期未定）", ["4.7"], None, None, None, "S:survey", None),
    # E19 复查
    ("E19-f1", "E19", "08-12", "", "in_progress", "体检：甲状腺右叶结节约 0.6 cm，TI-RADS 3 类，建议 3–6 个月内复查", ["3类|三类"], None, None, None, "P:checkup", "健康"),
    ("E19-f2", "E19", "08-18", "", "planned", "想挂刘医生 8/29 的号，已约满，先排候补", ["候补"], None, "E19-f2b", None, "K:0818_waitlist", "健康"),
    ("E19-f2b", "E19", "08-19", "", "planned", "候补到了：9/5（周六）上午 9:30 甲乳外科刘医生 B 超复查", ["9月5日"], "09-05", None, "E19-f3", "S:sms_hospital", "健康"),
    ("E19-f3", "E19", "09-05", "", "done", "复查 0.6×0.5 cm，无变化，仍 3 类", ["无变化"], None, None, None, "P:ultrasound", "健康"),
    ("E19-f4", "E19", "09-05", "", "planned", "下次复查 2027 年 3 月", ["2027年3月"], "2027-03-01", None, None, "K:0905_next_checkup", "健康"),
    # E20 团建
    ("E20-f1", "E20", "09-01", "", "planned", "陶然发起团建投票：剧本杀 / 徒步 / 烧烤，定在 9/19 周六", ["9月19日"], "09-19", None, "E20-f5", "C:0901_tao_vote", None),
    ("E20-f2", "E20", "09-04", "", "planned", "团建投票结果：徒步 6 票", ["徒步"], None, "E20-f4", None, "S:vote", None),
    ("E20-f3", "E20", "09-09", "", "planned", "团建预算人均 300 元，8 人", ["300"], None, None, None, "C:0909_tao_budget", None),
    ("E20-f4", "E20", "09-15", "", "planned", "周六有雨，团建改成室内剧本杀", ["剧本杀"], "09-19", None, "E20-f5", "C:0915_team_rain", None),
    ("E20-f5", "E20", "09-19", "", "done", "团建完成（吴迪也来了）", ["团建"], None, None, None, "K:0919_teambuild_done", None),
    ("E20-f6", "E20", "09-19", "", "planned", "中秋礼盒 9/22 发", ["9月22日"], "09-22", None, None, "C:0919_tao_gift", None),
    # E21 竞品报告
    ("E21-f1", "E21", "08-12", "", "planned", "给陶然布置竞品体验报告，8/21 交", ["8月21日"], "08-21", None, "E21-f2", "C:0812_tao_assign", None),
    ("E21-f2", "E21", "08-21", "", "done", "竞品报告 v1：偏截图罗列，结论浅", ["v1"], None, "E21-f4", None, "P:comp_v1", None),
    ("E21-f3", "E21", "08-25", "", "in_progress", "反馈：要 query 级对比，至少 30 个 query", ["30"], None, None, None, "M:comp_review_0825", None),
    ("E21-f4", "E21", "09-02", "", "done", "竞品报告 v2：30 个 query 逐条对比", ["v2"], None, None, None, "P:comp_v2", None),
    ("E21-f5", "E21", "09-09", "", "done", "马骁把 v2 的 30 个 query 补进评测集", ["评测集"], None, None, None, "C:0909_maxiao_eval", None),
]

FIELDS = ("fact_id", "event_id", "date", "_t", "state", "text", "keys", "due", "superseded_by", "resolved_by", "first", "sensitive")


def facts() -> list[dict]:
    out = []
    for row in F:
        d = dict(zip(FIELDS, row))
        d.pop("_t")
        d["date"] = "2026-" + d["date"]
        if d["due"]:
            d["due"] = d["due"] if d["due"].startswith("20") else "2026-" + d["due"]
        out.append(d)
    return out
