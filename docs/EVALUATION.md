# 评测汇总

全部为合成数据。这里只汇总和指路；每个数字的来源、命令、提示哈希和每次运行明细都在各 Skill 的 `BENCHMARK.md`：最上面的「最终版本（提交用）」一节是对外引用的数字，更早的版本都保留并标成「历史」。原始结果（`score.json`、`stats.json`、`meta.json`，早期运行还有检查点快照）在 [eval/runs/](../eval/runs/)，最终评测的汇总是 `eval/runs/final-summary.json`。含完整输入的逐次调用日志 `runs.jsonl` 和数据库没有入库。

| 文档 | 内容 |
|---|---|
| [skills/event-assign/BENCHMARK.md](../skills/event-assign/BENCHMARK.md) | 最终版本（留出集第二次评测 + dev）、留出集第一次评测、过拟合审计、端到端消融、各版本归事件结果（event-brief、home-rank 两份的公共小节相同） |
| [skills/event-brief/BENCHMARK.md](../skills/event-brief/BENCHMARK.md) | 标题 / 现在到哪一步 / 事实的召回与校验；无出处日期、决定不等于办完（1.4.0） |
| [skills/home-rank/BENCHMARK.md](../skills/home-rank/BENCHMARK.md) | 首页 NDCG@5 与只按时间排序的对照 |
| [skills/image-read/BENCHMARK.md](../skills/image-read/BENCHMARK.md) | 读图片（image-read 取代 screenshot-read；screenshot-read 的数字在其「历史」一节）：最终评测里的读取重新计分；Qwen NVFP4 / Q8_0 / Step3-VL-10B 对照 |
| [skills/recall/BENCHMARK.md](../skills/recall/BENCHMARK.md) | 未测（占位） |
| [EVALUATION_20260926.md](EVALUATION_20260926.md)、[FINAL_EVALUATION_20260927.md](FINAL_EVALUATION_20260927.md) | 队友的首轮与三组完整评测（另一个驱动 `run_eval_overnight.py`，口径不同，不能与上面直接混比） |
| [eval/README.md](../eval/README.md) | 场景、驱动、评分指标的定义和读法 |
| [eval/scale/README.md](../eval/scale/README.md) | 三个规模场景（lab / startup / pm，各 1,500–1,600 条）的分数、基线、诊断和 lab 合并前后 |
| [eval/system_one/RESULTS.md](../eval/system_one/RESULTS.md) | System One：快速、带校准置信度的判断模型（数据、训练、校准、服务、结果） |
| [MODELS.md](MODELS.md) | 每个功能用什么模型、为什么，以及最新模型对比 |
| [skills/file-read/BENCHMARK.md](../skills/file-read/BENCHMARK.md)、[skills/item-split/BENCHMARK.md](../skills/item-split/BENCHMARK.md) | 读文件、长素材切段 |

## 场景

| 场景 | 规模 | 状态 |
|---|---|---|
| `dev-week-v1` | 82 条素材、9 个事件、4 条噪声、4 个检查点 | 开发集，用来改技能 |
| `holdout-week-v1` | 32 条、5 个事件、2 个检查点 | **已污染**：写技能的代理在写之前读过它的素材和金标准，只作参考 |
| `scale-lab` / `scale-startup` / `scale-pm` | 1,510 / 1,600 / 1,600 条，22 / 20 / 21 个事件 | 大模型在多台 Spark 上生成，金标准来自确定性计划；startup 是留出集，lab 和 pm 是开发集；每个只跑一次 |
| `holdout-week-v2` | 46 条、7 个事件（2 个难干扰）、4 条噪声、42 条事实、6 个检查点 | 由没看过技能的代理盲写，`FROZEN.sha256` 冻结，从未用于调参；评过两次：3c65a4a 的第一次一次性评测、最终代码 13c3ae1 的第二次评测。第一次的结果在之后的开发中看得到 |

## 关键结论（最终版本：event-assign 2.1.0、event-brief 1.4.0、home-rank 1.3.0、screenshot-read 1.0.0；每个条件 n = 2）

1. **留出集（最终代码的第二次评测）上**，有技能 B³ F1 0.782（两次相同），无技能正文 0.612（0.575 / 0.649），向量 / 词法基线 0.336 / 0.463。技能正文的增益 +0.17，第一次评测是 +0.08（0.730 对 0.653），dev 上 +0.075（0.748 对 0.673）；增益几乎全部来自召回，没有技能正文时事件被过度拆分。n = 2，差异要谨慎看。
2. **难干扰没有解决**：有技能两次都把三季度退税并进 PO-2611 出货、把 Peggy 的报价和索赔合并（泄漏 0.25）。
3. **卡片**：卡片事实召回 0.511 对 0.431（dev 0.750 对 0.644）；卡片里素材没给的日期从第一次评测的 18 / 22 降到 0（来自 1.4.0 的日期换算和校验，无技能正文也是 0）；状态行收成首页一行（宽度中位 13–13.5，第一次评测 25–27）。
4. **代价**：最终版在留出集上的卡片事实召回低于第一次评测（0.511 对 0.575），只看状态行的冻结口径从 0.368 降到 0.161；严格校验在重试后仍拒绝 26–37% 的 event-brief 调用，卡片滞后。
5. **首页**：home-rank 在留出集上比同一批卡片只按时间排序多约 0.04（0.923 对 0.886）；在 dev 上不稳定（r1 0.597 低于只按时间的 0.661）。
6. **提问**：留出集上 6.5 / 8.7 次/百条，有用率 0.25–0.33；4 条噪声里 3 条留在未归档。
7. **读截图**：有技能发送者 1.000、原文完全一致 0.941、时间 0.647（无技能正文 0.912 / 0.941 / 0.529），与第一次评测相同。
8. **过拟合审计（历史）**：2.0.0 / 1.1.0 的提示里混入了 dev 原话、dev 金标准标题和 holdout 措辞，首页规则与标注共用阈值（那时 dev 0.787、已污染的 holdout-v1 0.856）。换成虚构领域的例子和一般规则后，dev F1 从 0.787 降到 0.740、首页 NDCG 从 0.85 降到 0.76；这些是如实记录的代价。
9. **可靠性（历史）**：第一版在同样 400 token 预算下，裸提示 47% 的输出被截断作废，技能首次合规 100%；给足预算时两者归事件准确率打平。

## 三个规模场景（n = 1）

| | lab | startup | pm |
|---|---|---|---|
| B³ F1（无模型基线） | 0.642（0.179） | 0.584（0.266） | 0.606（0.299） |
| Link F1（基线） | 0.630（0.136） | 0.582（0.116） | 0.563（0.186） |
| 事件数：预测 / 真值 | 242 / 22 | 348 / 20 | 227 / 21 |
| 卡片事实召回 | 0.489 | 0.583 | 0.652 |
| 吞吐（条/分钟） | 4.00 | 3.85 | 3.71 |

最大的弱点是碎片化（预测事件数是真值的 11–17 倍），其次是人物关联（0.23–0.26）。lab 上的离线合并实验把 B³ F1 从 0.642 提到 0.660、事件数从 242 降到 184，碎片化只缓解了一部分。完整表格和诊断见 [eval/scale/README.md](../eval/scale/README.md)。

## System One（只做评测，默认关闭）

TEST 共 1,953 个判断（scale-lab 1,907 + holdout-week-v2 46），τ 在 VALIDATION 上按 ≥ 97% 精确率选定后冻结：

| 模型 | TEST 准确率 | ECE | 快路径覆盖 | 快路径精确率 |
|---|---|---|---|---|
| 只取检索第一名 | 77.3% | 0.227 | 0.0% | – |
| 25 维检索特征逻辑回归 | 84.0% | 0.038 | 65.6% | 97.3% |
| Laya 零样本 / 微调 | 4.2% / 14.1% | 0.132 / 0.005 | 1.0% / 1.7% | 30.0% / 20.6% |
| Qwen3-Reranker-0.6B 微调（按 VALIDATION 选出，已服务） | 76.9% | 0.021 | 46.6% | 97.4% |

在同样的 300 个 TEST 判断上，LLM 直接作答 83.0%（p50 1330 ms），完整的 event-assign 技能 79.7%（p50 13955 ms），reranker 快路径 p50 419 ms。详见 [eval/system_one/RESULTS.md](../eval/system_one/RESULTS.md)。

## 最新模型对比

读图、整理和向量三类的最新候选模型对比（包括 Qwen3.8-27B-FP8、DeepSeek-V4-Flash、Nemotron 等，以及没能在 vLLM 0.30.0 上跑起来的模型和原因）见 [MODELS.md](MODELS.md)。

## 模型服务实测（DGX Spark）

| 模型 / 服务 | 实测 |
|---|---|
| Qwen3.6-35B-A3B NVFP4，vLLM + MTP（默认） | 单流输出约 100 token/s；读入 5.7k–7.2k token/s；event-assign 单次 p50 3.74 s（首轮，dev）；最终评测 4 个运行并发时留出集上 event-assign p50 4.4–4.6 s、event-brief 10.7–11.0 s |
| Qwen3.6-35B-A3B Q8_0，llama.cpp | 读截图与 NVFP4 同样全对（4 张图、38 条消息） |
| DeepSeek-V4-Flash，vLLM TP2 跨两台 Spark | 输出约 34 token/s，读入 1.4k–2.3k token/s；必须关闭思考；归事件 dev B³ F1 0.741（n = 2），单次 p50 5.49 s（经 SSH 隧道） |
| Step3-VL-10B Q8_0，llama.cpp | 原生接口适配后单张截图 70.17 s → 19.16 s；读截图 p50 16.94 s，原文完全一致 0.842，一处事实错误 |
| Qwen3-Embedding-0.6B，vLLM pooling | 演示实例 `EMBED_GPU_UTIL=0.05` 时约 1.1 GiB 权重 + 4.2 GiB KV cache（[DEPLOY_DEMO](DEPLOY_DEMO.md)；`spark/serve_embed.sh` 默认 0.06） |

延迟都是在与其他负载共享的服务器上测的，只能粗比。
