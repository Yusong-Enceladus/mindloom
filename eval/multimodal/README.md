# 多模态评测集 mm-v1（合成数据）

用来给"读图"类功能打分：用户拖进来的截图、照片、扫描件，整理器要把里面的文字和关键信息读对。140 张图、7 种承载信息的图片，每张一个金标准 JSON。所有人名、店名、公司、地址、单号、金额都是虚构的，每张图角上有一个小的"合成数据"标记（不属于金标准）。可以发到用户自己的 Spark 上跑，不含任何真实用户数据。

| 类型 `type` | 编号 | 内容 | 主要金标准 |
|---|---|---|---|
| `chat_screenshot` | chat-00…19 | 通用即时通讯界面截图（群聊/单聊，浅色/深色/低对比，语音/图片/文件气泡） | 每条消息 `sender` / `is_self` / `time` / `text` / `kind` |
| `chart_dashboard` | chart-00…19 | matplotlib 柱状、折线、分组柱、饼图、横向柱、KPI 看板 | 标题、类别、每个数据点的数值（图上都有数据标签）、趋势、KPI |
| `slide` | slide-00…19 | 16:9 幻灯片导出图，5 张是投影幕布的手机照片 | 标题、副标题、要点（含层级）、KPI 面板、页脚、页码 |
| `whiteboard_handwriting` | board-00…19 | 白板、黑板、横线本、便利贴上的手写体照片 | 每行文字、是否划掉 `struck`、是否打勾 `checked` |
| `receipt_invoice` | receipt-00…19 | 热敏小票和销售单/Invoice 的桌面照片 | 商家、日期、单号、明细（数量、单价、金额）、小计、优惠、税、合计、支付方式、人民币大写 |
| `scanned_document` | scan-00…19 | reportlab 排版的 A4 PDF → pdfium 栅格化 → 扫描退化（倾斜、淡墨、模糊、灰尘、盖板阴影） | 标题、抬头字段、按阅读顺序的段落/列表/表格、`full_text` |
| `form_label_sign` | label-00…19 | 快递面单、设备铭牌、价签、会议室门牌、营业时间牌、手写报修单、库位标签的照片 | `fields`（`key` 英文固定名、`label` 印刷的字段名、`value`） |

中文为主，44 张英文，2 张中英混排（另有不少中文图里夹英文词和单位）。

## 划分

每种类型 6 张 dev、14 张 test，共 **dev 42 / test 98**。划分在 `manifest.json` 和每个金标准的 `split` 字段里。

- **dev**：可以用来写提示词、调流程、看失败案例。
- **test**：只用来报告数字，不能看着 test 的结果改提示词或参数。改了东西之后要报告 test，就在 dev 上定好再跑一次 test，并注明第几次。

划分是分层选的：每种类型内贪心挑 6 张，让每个难例标签和语言大约 30% 在 dev、其余在 test（标签只有 2 张时各一张）。各标签的 dev/test 数量见 `manifest.json` 的 `counts.by_hard_tag`。

## 难例标签 `hard`

`small_text`（缩小转发、远拍、9pt 正文）、`low_contrast`（淡墨、褪色小票、低对比主题）、`similar_names`（同一张图里有 王晓林/王晓琳、李明/李鸣、Chen Wei/Chen Wen 这类近似名字）、`similar_items`（拿铁大杯/中杯、云南水洗/日晒）、`units`（至少两处带单位的数字，如 1.44㎡、2.35kg、¥19.97/L、0.38%）、`dated_time`（"昨天 21:03""9月24日 14:05""Tue 3:49 PM"）、`non_text_bubbles`、`handwriting`、`cursive`（行楷）、`struck_items`（划掉的旧价格/任务）、`two_prices`（原价+促销价）、`table`、`dense`、`photo`、`perspective`、`glare`、`shadow`、`blur`、`rotation`（≥2.5°）、`similar_colors`、`many_points`。

## 文件

```
eval/multimodal/
  generate.py        生成器（固定种子，同样的字体和库版本得到逐字节相同的输出）
  mmgen/             各类型的渲染和退化代码
  images/<id>.png|jpg
  gt/<id>.json       金标准
  manifest.json      条目列表（id、type、split、lang、hard、宽高、sha256）、计数、生成环境、字体
  requirements.txt   生成器依赖
  bench/             读图模型评测（提示、运行、计分、汇总）
  results/           评测的原始输出、得分和表格
  BENCHMARK.md       读图模型评测结果（Qwen3.6 NVFP4 / Q8、Step3-VL-10B、Qwen3-VL-8B）
```

每个 `gt/<id>.json` 都有：`gt`（上表的结构化答案）、`text_lines`（图中所有承载信息的文字，按阅读顺序，不含界面按钮和"合成数据"标记）、`qa`（2–5 个问题，`match` 为 `exact` / `contains` / `number` / `date` / `trend`）、`render`（字体、主题、退化参数）、`variant`（生成参数）、`image_sha256`。

几条约定：

- 聊天截图：右侧气泡是用户本人，`sender` 为"我"（英文图为"Me"）、`is_self` 为 true。`time` 是该消息上方**实际画出来的**时间标签，没有就是空字符串（和 `eval/tools/screenshot_eval.py` 口径一致）。单聊里对方名字不画在气泡上方，金标准写会话标题并带 `sender_shown: false`，读成"对方"也应算对。语音、图片、文件气泡按 `screenshot-read` 的写法记为 `[语音 N秒]`、`[图片]`、`[文件 名称]`，同时给出 `kind`。`chat_title` 不含群人数"(N)"。
- 图表：数值以图上数据标签为准（`labels` 是印出来的字符串，`values` 是数值）。`trend` 只给有顺序的横轴（时间、版本），取值 `up` / `down` / `flat` / `rise_then_fall` / `fall_then_rise`，由构造保证并复核；区域、部门、饼图没有趋势。
- 小票和销售单：每行金额 = 数量 × 单价（四舍五入到分），小计、优惠、税、合计都由明细重算，生成时校验自洽。
- 扫描件：`full_text` 以段落为单位换行，段内的自动折行不算。
- 手写体里缺字形的符号（个别字体没有 ㎡、→、全角标点）会换成人会写的替代写法，金标准和问答里用的是替换后的文字。

## 建议的评分口径

比较前统一做：NFKC、去掉空白、全半角标点视为相同、从模型输出里删去"合成数据"四个字。

| 功能 | 指标 |
|---|---|
| 通用文字读取（所有类型） | `text_lines` 拼接后的字符错误率 CER；数字召回（金标准中的每个数字是否出现在输出里）；**编造数字率**（输出里出现、但图中没有的数字占比） |
| 问答 / 关键信息 | `qa` 准确率：`exact` 规范化后相等；`contains` 回答里包含金标准答案；`number` 答案里的所有数字都对（单位可缺省）；`date` 按日期解析后相等；`trend` 类别相等 |
| 聊天截图 | 消息条数是否一致；按顺序对齐后 sender、is_self、time 的准确率；text 的 CER；`similar_names` 子集单独报 sender 准确率 |
| 图表 | 标题 CER；数据点数值精确匹配率（逐点）；趋势准确率；KPI 精确匹配率 |
| 幻灯片 | 标题精确/CER；要点召回和精确率（CER ≤ 0.1 视为匹配）；层级准确率 |
| 手写 | 行级 CER；`struck` / `checked` 准确率（被划掉的内容不能当成现状） |
| 小票和销售单 | 商家、日期、单号、合计精确匹配；明细 F1（名称 + 金额同时对才算）；读出的明细与合计是否自洽 |
| 扫描件 | `full_text` 的页级 CER；表格单元格准确率；`qa` 准确率 |
| 表单、标签、标牌 | 每个 `fields.value` 的规范化精确匹配率（按 key 汇总） |
| 运行 | 每张图耗时（中位数、p90）、失败/超时次数、输出 token；模型、量化、服务参数一起记录 |

每个数字都按 dev/test 分开报，并附上按类型和按难例标签的分项。

## 重新生成

```bash
python3 -m venv /tmp/mmgen && /tmp/mmgen/bin/pip install -r eval/multimodal/requirements.txt
/tmp/mmgen/bin/python eval/multimodal/generate.py --out /tmp/mm-check   # 与仓库里的 manifest.json 比较 sha256
```

需要 macOS 自带字体（冬青黑体、华文黑体、宋体、Helvetica、Menlo 等）和系统可下载的中文字体资产（楷体、翩翩体、手札体、娃娃体、行楷、圆体）；找不到时用 `EVAL_FONT_<KEY>=/path/to/font[:index]` 指定。图表用 matplotlib 按名字找"Hiragino Sans GB"，英文扫描件用 PDF 标准字体（由 pdfium 内置字体渲染）。字体或库版本不同会改变像素，所以仓库里的图片和金标准才是基准；改了渲染器才重新生成，并且不能在看过 test 结果之后为了分数重新生成。
