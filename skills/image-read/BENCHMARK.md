# image-read benchmark

## image-read 1.0.0 · mm-v1（代码 92f4305，2026-09-29）

image-read 取代 screenshot-read：先判断图片类型（7 类 + other），再按该类型的 schema 抽取（文字行、关键字段、数字、聊天消息的发送者和时间）和一句 gist；
校验器拒绝图上找不到的字段和数字，重试一次后仍不合格的值被清空。这里测的是整理器里真实的那条路径（`organizer.image_read.read_image`：
同一套技能文件、harness、引导解码、校验和重试），不是 benchmark 的中性提示。

- **数据**：`eval/multimodal` 的 mm-v1 合成集，dev 42 张 / test 98 张（7 类各 6 / 14 张）。只在 dev 上调；test 只跑了一次评测（两次重复运行），看过 test 之后没有改任何提示、代码或参数。
- **模型**：Qwen3.6-35B-A3B NVFP4，vLLM 0.30.0，spark-C `127.0.0.1:30102`（与 `eval/multimodal/BENCHMARK.md` 的独占副本相同的权重、venv 和参数），thinking 关，temperature 0。
  所有类型都走这一个模型（benchmark 的推荐；每类可用 `ORGANIZER_IMAGE_ROUTES` 改到别的端点，这次没用）。
- **请求**：每张图两步，同一个系统提示、图片在前，所以第二步复用图片的前缀缓存。输入只有图片和固定的上下文（无来源 App）。
- **条件**：有技能 = 发布的 SKILL.md；无技能正文 = `eval_common.strip_skill_text`（SKILL.md 正文换成一行任务名，全局规则、schema 引导解码、校验器、重试都保留）。
  提示哈希：有技能 `40a4c917ce1dea3e`，无技能正文 `397bce015f501ebc`。
- **计分**：`eval/multimodal/imgread/score_imgread.py`，抽取部分直接用 benchmark 的 `bench/score_vlm.py`（未改）。类型判错的图按判出的类型的格式计分（用户实际拿到的就是这个）。
- **延迟**：test 为单路（并发 1），服务上没有其他客户端（`results/load/spark-C-30102.tsv`：整个 test 期间在跑请求数 ≤ 1）。dev 为并发 4，延迟不可比。

### test（98 张，两次运行；按类型宏平均）

| 条件 · 运行 | 类型判对 | CER ↓ | 关键字段 EM ↑ | QA 可答 ↑ | 编造数字（不含 gist）↓ | 无出处字段 ↓ | 首次合规（两步都一次过） | 重试后仍不合格 | p50 / p90（整次读图） | 输出 token |
|---|---|---|---|---|---|---|---|---|---|---|
| **有技能 · r1** | 96/98（98.0%） | 2.6% | 96.2% | 99.3% | 0.9% | 0.2% | 95/98 | 1 | 4.09 / 6.58 s | 486 |
| **有技能 · r2** | 98/98（100%） | 0.5% | 98.8% | 99.3% | 0.5% | 0.2% | 96/98 | 0 | 3.87 / 6.32 s | 485 |
| 无技能正文 · r1 | 83/98（84.7%） | 21.2% | 65.7% | 92.7% | 4.5% | 9.3% | 75/98 | 5 | 4.38 / 10.86 s | 954 |
| 无技能正文 · r2 | 81/98（82.7%） | 25.0% | 59.4% | 91.7% | 4.5% | 9.8% | 70/98 | 13 | 4.32 / 13.08 s | 1117 |
| 参照：benchmark 中性提示（类型直接给定，NVFP4） | — | 0.3% | 98.6% | 99.7% | 0.1% | 0.0% | — | — | 2.64 / 5.13 s | 411 |

- 有技能时两步各自的 p50：判类型 1.03 / 0.76 s，抽取 3.19 / 3.18 s。比 benchmark 慢约 1.2 s：多了一次判类型，系统提示也更长（两步合计输入约 9.6k token，其中第二步的系统提示和图片命中前缀缓存）。
- **r1 的 2 张白板照片（board-07、board-16）被判成幻灯片**，按幻灯片格式抽取，手写一类的分数因此掉下来（r1 手写 CER 15.1%，r2 0.3%）；r2 全部判对。vLLM 在 temperature 0 下也不完全可复现（见 `eval/multimodal/BENCHMARK.md`），所以类型判断在边界图上会抖动。
- 无技能正文时，类型判断错得最多的是标签/面单/标牌（14 张里 13–14 张被判成小票或扫描件），字段命名约定也没有了（标签字段 EM 3%），校验失败和重试也多得多。

按类型（test，有技能两次运行的均值；括号里是无技能正文）：

| 类型 | CER | 关键字段 EM | 专项 | p50 |
|---|---|---|---|---|
| 聊天截图 | 0.1%（1.2%） | 98.8%（65.0%） | 发送者 97.4%（86.5%），时间 100%（37.2%），条数 100%（78.6%） | 4.0 s |
| 图表/看板 | 0.0%（18.1%） | 100%（73.9%） | 数据点 100%（80.4%），KPI 100%（34.4%），趋势 100%（70.0%） | 3.7 s |
| 幻灯片 | 0.0%（12.8%） | 100%（96.4%） | 要点召回/精确 100%（87.8/88.9%），层级 100%（78.5%） | 3.6 s |
| 手写/白板 | 7.7%（26.2%）；r2 0.3% | 87.2%（66.0%）；r2 95.7% | 行完全一致 90.7%（67.5%），r2 97.7%；划掉召回 83.3%（66.7%） | 3.7 s |
| 小票/销售单 | 2.8%（7.0%） | 100%（86.6%） | 明细 F1 100%（78.6%），日期 100% | 6.4 s |
| 扫描件 | 0.0%（43.0%） | 100%（47.0%） | 表格单元格 100%（43.1%） | 5.7 s |
| 标签/面单/标牌 | 0.1%（53.1%） | 96.5%（3.0%） | 字段值严格一致 95.8%（2.8%），包含 97.7%；benchmark 中性提示为 91.5% | 4.2 s |

### 数字与 gist

- **抽取出来的字段**（不含 gist）里被计为"编造"的数字，逐条看过都是读错的手写或门牌数字，和 benchmark 里 NVFP4 的错法相同：board-08 "21→27"、board-15 "142→148"、label-11 "155→755"
  （两次运行都有），以及 r1 里被判成幻灯片的两张白板（幻灯片格式的要点层级 `level: 0` 被计分器当成数字 "0"）。
- **gist**：共约 395 个数字，计分器标出 13–14 个"图里没有"。逐条看过：除 board-08 的 "27"（同上，读错的数字被带进 gist）外，都是把英文月份写成了数字
  （"Sep 10" → "9 月 10 日"，"Apr–Sep" → "4 月至 9 月"），不是凭空的数。技能要求保留英文月份的写法，dev 上这类从 6 个降到 4 个，但没有消失；校验器把英文月份当作对应的数字接受。
- 校验器在 test 上拦下的都是 gist 里的数字（例：slide-07 第一次的 gist 里有图上没有的 "183"，图上写的是 "$1.83M"），重试后都改对了；r1 有 1 张（label-01）两次都不合格，gist 被清空，字段照常保留。
- 已知问题：receipt-16 两次运行的 `lines` 里都混进了 `<!-- 3 -->` 这样的注释串（计为 2 个无出处字段），校验器目前不检查 `lines` 本身。board-12 的划掉线渲染得像下划线，所有模型都读不出来（划掉召回上限 83.3%，见 mm-v1 BENCHMARK）。

### dev（42 张，调参用，并发 4）

| 版本 | 类型判对 | CER | 关键字段 EM | QA | 首次合规 | 重试后仍不合格 | 改了什么 |
|---|---|---|---|---|---|---|---|
| s1 | 97.6% | 3.7% | 95.5% | 99.2% | 37/42 | 4 | 初版 |
| s2 | 100% | 0.5% | 99.2% | 99.2% | 41/42 | 0 | 校验器不把趋势的枚举值 "none" 当占位词；英文月份算作数字；判类型：标题为发票/Invoice 的整页也是小票；标签：一行"说明 + 值"时说明写进 label |
| s3 | 100% | 0.5% | 99.3% | 100% | 41/42 | 0 | 图表趋势必须和数据点一致（校验器，清理时按数据点改正）；英文日期换算的校验；记录每次尝试的错误 |
| **s4（= 92f4305）** | 100% | 0.5% | 99.3% | 100% | 41/42 | 0 | gist 保留图上日期写法 |
| 无技能正文（92f4305） | 88.1% | 23.3% | 59.2% | 91.5% | 29/42 | 5 | — |

s1–s3 的原始输出也在 `results/raw/`（它们是用当时的代码跑的）。技能里的例子都是虚构的，没有抄 dev 图里的内容。

### 复现

```bash
# 在 Spark 上（回环地址调用服务；只用合成图）
python3 eval/multimodal/imgread/run_imgread.py --split test --url http://127.0.0.1:30102/v1 \
    --condition skills --out out/test-skills.r1.jsonl          # --condition without-skills 为消融
python3 eval/multimodal/imgread/score_imgread.py --gt-root eval/multimodal --split test \
    --run skills.r1=out/test-skills.r1.jsonl --out out/test.json
```

结果：`eval/multimodal/imgread/results/`（`raw/` 每次运行的输出与 `.meta.json`，`scores/test.json`、`scores/dev-final.json`、`scores/dev-tuning.json`，`load/` 服务负载）。


## 历史 · screenshot-read 1.0.0 最终版本：代码 13c3ae1，holdout-week-v2 第二次评测 + dev-week-v1（2026-09-28）

> screenshot-read 是 image-read 的前身（只读聊天截图）。这一节是它在提交版本里的数字；下面各节更早：holdout-week-v2 的第一次评测，以及 1.0.0 首轮（其中的 holdout 截图来自已污染的 holdout-week-v1）。

- 版本：screenshot-read 1.0.0，技能文件和提示与第一次评测相同（有技能 `f64ffa03fbcf5abe`，无技能正文 `6ed5ddfc9ecd5297`）。代码 13c3ae1。
- 没有额外调用模型：重新计分的是最终评测 8 次端到端运行里已经发生的截图读取（`eval/runs/final-{h2,dev}-*`，见 event-assign 等 BENCHMARK 的"最终版本（提交用）"一节；
  运行前后没有改任何代码、技能、提示、评分器或场景，holdout-week-v2 启动前用 `FROZEN.sha256` 校验过）。
- 留出集标注：最终代码，holdout-v2 第二次评测（holdout 从未用于调参；第一次一次性评测在 3c65a4a）。第一次评测的结果在之后的开发中已经入库、可以看到。
- 做法与"历史 · holdout-week-v2 第一次一次性评测"一节相同：从各次运行的 `runs.jsonl` 按素材编号取出 `screenshot_read` 的输出
  （spark-F `~/hack/claude-final/shots_from_runs.py`，与 `~/hack/claude-holdout2/shots_from_runs.py` 相同），再交给 `eval/tools/screenshot_eval.py --rescore` 计分。
- 模型 Qwen3.6-35B-A3B NVFP4（spark-F :8000，与其他负载共享，每个集 4 个运行同时进行，thinking 关，temperature 0）。

| 条件 · 集 | n（读取次数） | 首次合规 | 发送者 | is_self | 原文完全一致 | 原文相似度 | 时间 | p50 / 最大 | 输入 / 输出 token（均值） |
|---|---|---|---|---|---|---|---|---|---|
| **有技能 1.0.0 · holdout-v2**（4 张图 × 2 次，34 条消息） | 8 | 8/8 | 1.000 | 1.000 | 0.941 | 0.998 | 0.647 | 7.59 / 9.34 s | 2485 / 400 |
| **无技能正文 · holdout-v2** | 8 | 7/8 | 0.912 | 1.000 | 0.941 | 0.998 | 0.529 | 8.00 / 15.67 s | 1961 / 456 |
| 有技能 1.0.0 · dev（3 张图 × 2 次，30 条消息） | 6 | 6/6 | 1.000 | 1.000 | 1.000 | 1.000 | 0.667 | 9.40 / 11.04 s | 2638 / 445 |
| 无技能正文 · dev | 6 | 6/6 | 1.000 | 1.000 | 1.000 | 1.000 | 0.667 | 8.90 / 10.96 s | 1847 / 438 |
| 参照：有技能 · holdout-v2 第一次评测（8ee22d7） | 8 | 8/8 | 1.000 | 1.000 | 0.941 | 0.998 | 0.647 | 7.76 / 8.41 s | 2485 / 401 |
| 参照：无技能正文 · holdout-v2 第一次评测 | 8 | 7/8 | 0.912 | 1.000 | 0.941 | 0.998 | 0.529 | 8.40 / 15.52 s | 1960 / 455 |

- 留出集上的准确率与第一次评测逐项相同：发送者和原文仍接近全对，原文不完全一致的 2 条都在 d1-04 上；时间字段仍是最弱的一项（d1-04、d1-06、d3-02 每张 4 条里只对 2 条）。
- 技能正文的差别只在留出集上看得到：无技能正文 r1 的 d1-04 需要重试一次，4 个发送者只对 1 个（发送者 0.912 对 1.000）；时间 0.529 对 0.647。dev 的 3 张图两个条件没有差别。样本很小。
- 读到的文字、逐条消息和一句摘要由整理服务经 `/v1/state` 的 `readings` 发回 Mac（摘要是单独的 `summary` 字段）；event-brief 只把摘要当作看懂截图的提示（`reading_summary`），
  不能当作原话（quote）或日期出处。
- 仍未测：模糊图、截图里的注入文字、文档 / 网页截图、长群聊（见"历史 · 1.0.0 首轮"里的"待补"）。

结果：`eval/runs/final-h2-screenshots-{skills,noskill}.json`、`eval/runs/final-dev-screenshots-{skills,noskill}.json`（`summary` + 每次读取的原始输出与逐项得分）。

## 历史 · screenshot-read · holdout-week-v2 第一次一次性评测（代码 8ee22d7，2026-09-28）

> **历史记录。** 最终代码在同一留出集上的第二次评测见最上面"最终版本（提交用）"一节。
>
> 这是 screenshot-read 在未见测试集上的数字。下表"结果"一节里的 holdout 截图来自 `holdout-week-v1`，已污染（写技能的代理事先读过它的素材和金标准），只作参考。

- 没有额外调用模型。这里重新计分的是 event-assign 等技能的 holdout-v2 端到端运行里已经发生的截图读取（`eval/runs/holdout2-*`，代码 8ee22d7，技能与提示均未改，场景已用 `FROZEN.sha256` 校验）。
  每个条件 2 次运行 × 4 张合成聊天截图 = 8 次读取，共 34 条金标准消息。
- 做法：把各次运行 `runs.jsonl` 里 `screenshot_read` 的输出按素材编号取出，再交给 `eval/tools/screenshot_eval.py --rescore` 计分，口径与下表相同。
  结果在 `eval/runs/holdout2-screenshots-{skills,noskill}.json`；取数脚本在 spark-F `~/hack/claude-holdout2/shots_from_runs.py`。
- "无技能正文"是 `--condition without-skills`：去掉 SKILL.md 正文和 references，保留全局规则、schema（引导解码）、校验和一次重试。它与下表的"无技能（裸提示）"不同，裸提示没有 schema。
- 模型 Qwen3.6-35B-A3B NVFP4（spark-F :8000，与其他负载共享，4 个运行同时进行）；提示哈希：有技能 `f64ffa03fbcf5abe`，无技能正文 `6ed5ddfc9ecd5297`。

| 条件 | n（读取次数） | 首次合规 | 发送者 | is_self | 原文完全一致 | 原文相似度 | 时间 | p50 / 最大 | 输入 / 输出 token |
|---|---|---|---|---|---|---|---|---|---|
| 有技能 1.0.0 · holdout-v2 | 8 | 8/8 | 1.000 | 1.000 | 0.941 | 0.998 | 0.647 | 7.76 / 8.41 s | 2485 / 401 |
| 无技能正文 · holdout-v2 | 8 | 7/8 | 0.912 | 1.000 | 0.941 | 0.998 | 0.529 | 8.40 / 15.52 s | 1960 / 455 |

- 发送者和原文在新图上仍然接近全对。原文不完全一致的 2 条（每次运行 1 条）都在 d1-04 上，两个条件相同。
- 时间字段是最弱的一项，这与 1.0.0 的结论一致。有技能时 d1-04、d1-06、d3-02 每张 4 条里都只对 2 条，d5-04 全对，两次运行结果相同。
- 技能正文的差别：无技能正文 r1 的 d1-04 需要重试一次，而且 4 个发送者只对 1 个（发送者 0.912 对 1.000）；时间 0.529 对 0.647。
  这只是 4 张图、各 2 次读取的结果，样本很小。

## 历史 · screenshot-read 1.0.0 首轮（2026-09-26/27；holdout 截图来自已污染的 holdout-v1）

> 首轮实测，2026-09-26 22:28 – 09-27 00:30（北京时间），全部为合成数据（`eval/scenarios/*/assets/*.png`，通用聊天界面样式，带"合成数据"标记）。
> 没跑的写"未测"。

| Field | Value |
|---|---|
| Skill version | 1.0.0 |
| Model | 主：Qwen3.6-35B-A3B NVFP4（`qwen3.6-35b-a3b-nvfp4`，vLLM 0.30.0，spark-F `127.0.0.1:8000`，thinking 关）；对照：Qwen3.6-35B-A3B Q8_0（llama.cpp，spark-A `127.0.0.1:30000`）、Step3-VL-10B Q8_0（llama.cpp，spark-A `127.0.0.1:30001`，`/completion` 预填空的 `<think></think>`） |
| Prompt hash | `f64ffa03fbcf5abe` |
| Eval set | 4 张聊天截图（dev 3 张、holdout-v1 1 张〔已污染〕，共 38 条消息），每张读 2 次 = 8 次。`evals/evals.json` 的 6 条（文档截图、注入文字、模糊图、非截图照片等）是文字描述，没有对应图片：未测 |
| Pass rate | evals.json：未测 |
| Median / p95 latency | Qwen NVFP4 5.1 s（最大 6.6 s） |
| Schema-valid on first attempt | 三个模型都是 8/8；整理流程里所有有技能的运行（共 28 次截图读取，DeepSeek 运行里的截图也由 Qwen 读）也都是首次合规 |

### 结果（`eval/tools/screenshot_eval.py`；按顺序逐条对齐 38 条消息）

发送者：右侧气泡须写"我"；时间：只对截图上真正画出来的时间标签计分（渲染器 5 分钟内不重复画时间，没画的应为空）。

| 模型 | 条件 | 首次合规 | 发送者 | is_self | 原文完全一致 | 原文相似度 | 时间 | p50 / 最大 | 输入 / 输出 token |
|---|---|---|---|---|---|---|---|---|---|
| Qwen3.6 NVFP4（vLLM） | 有技能 | 8/8 | 1.000 | 1.000 | 1.000 | 1.000 | 0.816 | 5.10 / 6.64 s | 2579 / 419 |
| Qwen3.6 NVFP4（vLLM） | 无技能（裸提示） | 8/8 可解析 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 3.80 / 4.81 s | 1258 / 429 |
| Qwen3.6 Q8_0（llama.cpp） | 有技能 | 8/8 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 5.83 / 8.20 s | 2579 / 406 |
| Step3-VL-10B Q8_0（llama.cpp，不思考） | 有技能 | 8/8 | 1.000 | 1.000 | 0.842 | 0.995 | 0.789 | 16.94 / 19.96 s | 1982 / 387 |

### 结论

- 这 4 张干净的合成聊天截图对 Qwen 太容易：三种 Qwen 配置的发送者、原文都全对。**技能在这组图上没有可测的准确率收益**；裸提示更快、输入 token 少一半。
- 唯一差别在时间字段：有技能的 NVFP4 在 8 次里有 3 次把上方的时间标签抄给后面的消息，或写出图上没有的时间（08:57、09:47）。同一张图、同一提示的两次读取结果不同，说明 vLLM 在 temperature 0 下也不完全确定。
- Step3-VL-10B：发送者全对；38 条里有 6 条原文不完全一致，多是小错字（"周日日""看看"），但有一处改了事实（"借了辆面包车"读成"借了两辆面包车"）；会编造没画出的时间（09:47、11:15）；比 Qwen NVFP4 慢约 3.3 倍。本轮不建议用它替换 Qwen 读截图。
- DeepSeek-V4-Flash 是纯文本模型，收到图片返回 HTTP 400。修复前整理服务会把这当成可重试错误，重试 3 次后放弃，这条截图就永远不会归到任何事件；现在改为不带文字继续整理（`spark/organizer/organizer.py`，回归测试 `spark/tests/test_eval_regressions.py`）。评测里 DeepSeek 的截图请求转给 Qwen（`run_eval.py --vision-llm-url`）。

### 待补（未测）

要测出技能的价值，需要更难的图：模糊图（应写"[看不清]"）、截图里的注入文字、文档/网页截图（`kind` 与 `messages` 为空）、更长的群聊、贴近真实 IM 的布局。它们在 `evals/evals.json` 里有描述，但还没有图片和金标准。

### 复现

```bash
S="--scenario eval/scenarios/dev-week-v1/scenario.json --scenario eval/scenarios/holdout-week-v1/scenario.json --repeat 2"
python3 eval/tools/screenshot_eval.py $S --backend openai --url http://127.0.0.1:8000/v1 --out eval/runs/shots-qwen-nvfp4.json
python3 eval/tools/screenshot_eval.py $S --backend openai --url http://127.0.0.1:8000/v1 --bare --out eval/runs/shots-qwen-nvfp4-bare.json
python3 eval/tools/screenshot_eval.py $S --backend openai --url http://127.0.0.1:30000/v1 --out eval/runs/shots-qwen-q8.json        # 在 spark-A 上，或经隧道
python3 eval/tools/screenshot_eval.py $S --backend step3-raw --url http://127.0.0.1:30001 --out eval/runs/shots-step3vl.json       # 同上
python3 eval/tools/screenshot_eval.py $S --rescore eval/runs/shots-step3vl.json --out eval/runs/shots-step3vl.json                # 只重算分数
```

本轮 spark-A 的两个端口经 Mac 端 SSH 隧道映射到 spark-F 的 `127.0.0.1:18130/18131`，所以那两行的延迟含隧道开销。结果：`eval/runs/shots-*.json`（`summary` + 每次读取的原始输出）。
