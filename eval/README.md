# 评测使用说明

全部评测数字的汇总见仓库的 `docs/EVALUATION.md`（公开仓库）和本目录的 [`results-2026-09-29/`](results-2026-09-29/README.md)。本文件说明场景、驱动和评分指标。

## 现在用的场景

| 场景 | 规模 | 用途 |
|---|---|---|
| `scenarios/holdout-week-v2` | 46 条、7 个事件（2 个难干扰）、6 个检查点 | 留出集：由没看过技能的代理盲写，`FROZEN.sha256` 冻结；各 Skill `BENCHMARK.md` 的「最终版本」和模型对比都用它 |
| `scenarios/dev-week-v1` | 82 条、9 个事件、4 个检查点 | 开发集 |
| `scale-lab` / `scale-startup` / `scale-pm` | 1,510 / 1,600 / 1,600 条 | 规模场景，结果见 [`scale/README.md`](scale/README.md)（场景素材没有放进公开快照） |
| `scenarios/split-dev` | 51 条 | item-split 的调参集 |
| `files/`（files-v1） | 60 个文件、20 类模板 | file-read 的评测集，说明见 [`files/README.md`](files/README.md) |
| `files-multiformat/` | 33 种格式 165 个文件、595 道问答 | 多格式读取，说明见 [`files-multiformat/README.md`](files-multiformat/README.md)；测试集结果见 `results-2026-09-29/` |
| `multimodal/`（mm-v1） | 98 张测试图 | 读图，见 [`multimodal/BENCHMARK.md`](multimodal/BENCHMARK.md) |
| `scenarios/holdout-week-v1` | 32 条、5 个事件 | **已污染**，只作参考（见下文） |

截图已经随仓库提供，评测不需要生成真人声音或连接第三方模型服务。

## 驱动

- **`run_eval.py`**（现在用的）：各 Skill `BENCHMARK.md`、模型对比和 `results-2026-09-29/` 的数字都来自它。`--condition skills | without-skills | bare | baseline`，用法见文件头。例如在留出集上：

```bash
H=eval/scenarios/holdout-week-v2/scenario.json
python eval/run_eval.py --scenario $H --condition skills --out /tmp/h2-skills \
  --llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8002/v1
python eval/run_eval.py --scenario $H --condition baseline --embed hash --out /tmp/h2-baseline   # 不调模型的词法基线
```

- **`run_skill_evals.py --n 3`**：跑 `skills/*/evals/evals.json` 里可执行的用例。
- **`score.py`**：评分器；`--snapshots` 可以对已入库的快照重算分数。
- **`run_eval_overnight.py`**（历史）：2026-09-26 第一次夜间评测用的驱动，消融口径和 `run_eval.py` 不同，数字不能混比。下面的「执行」一节保留它的用法。

## 执行

以下是 2026-09-26 夜间评测（当时的内部报告，未公开）所用的驱动 `run_eval_overnight.py`。各 Skill `BENCHMARK.md` 的数字来自另一个驱动 `run_eval.py`（`--condition skills|bare|baseline`、`--oracle-assign`），两者的消融口径不同，数字不能混比。

在仓库根目录、包含项目依赖和 Pillow 的 Python 环境中运行：

```bash
python eval/run_eval_overnight.py eval/scenarios/dev-week-v1/scenario.json \
  --llm-url http://127.0.0.1:8000/v1 \
  --embed-url http://127.0.0.1:8002/v1 \
  --out /tmp/memory-dev-with-skills-new

python eval/run_eval_overnight.py eval/scenarios/dev-week-v1/scenario.json \
  --llm-url http://127.0.0.1:8000/v1 \
  --embed-url http://127.0.0.1:8002/v1 \
  --mode without-skills --out /tmp/memory-dev-without-skills-new
```

**`holdout-week-v1` 已污染**：质量分支的代理在写技能之前读过它的全部素材和金标准，部分措辞进入过技能（已移除）。它的结果只作参考；要报告未见测试集的数字，需要由没看过技能的人另写一个冻结的新留出集。

每次创建新输出目录，拒绝覆盖旧结果。默认单线程逐条处理，不自动回答模型向用户提出的问题。不要拿 holdout 反复调提示词后再称作未见测试集。本次实验不会根据 holdout 分数修改技能。

### 2026-09-27 起的口径

- 两个驱动都用整理器的回放时钟（`--clock replay`，默认）：历史素材不会拿今天的日期去判断，`--clock wall` 只用于复现 9 月 26 日夜间评测的条件。
- `run_eval_overnight.py --rank item|checkpoint`：默认仍在每条素材后排序（dev 82 次），`checkpoint` 与 `run_eval.py` 一样只在检查点排序。
- `--answer-questions gold`：每条素材后用金标准回答未答的 `same_event` 问题。必须和不回答的结果一起报告。
- `run_eval.py --replay-cache DIR` 按完整请求记录/复用模型输出，用于重算分数和定位分歧，不能用来报告新模型的质量；`--rank-gold` 在每个有首页金标准的检查点单独对金标准事件排序一次（`stats.json` 的 `rank_gold`），和归事件的误差分开。
- `run_eval.py --condition without-skills` 与 `run_eval_overnight.py --mode without-skills` 用同一个函数（`eval_common.strip_skill_text`）去掉 SKILL.md 正文和 references，保留全局规则、schema、校验、重试和输出预算；要和有技能的结果比，请用同一个驱动。
- `runs.jsonl` / `runs.json` 记录每次调用的 `as_of` 和完整用户消息（只允许合成数据）。
- `eval/run_skill_evals.py --n 3`：跑 `skills/*/evals/evals.json` 里可执行的用例（均来自 dev 或虚构，绝不放 holdout 素材）。
- 场景新增首页金标准（`home_rubric` + 检查点 `home.grades`，0–3，依据场景自身的日期和利害写成；holdout 的标注只看场景文本、在任何 holdout 输出之前写好并冻结）和每条事实的进度状态 `state`。
- `score.py` 新增：噪声三分（未归档 / 单条事件 / 混进真实事件）、`false_unfiled`、`unfiled_precision`、干扰事件"种子"是否分开、被吞掉的事件、提问数量/每天最多/有用率、`plan_as_done`（计划写成完成不算召回）、卡片里无依据的"已…"和相对日期、首页 NDCG@5 / top-3 / 3 级召回 / 严重倒序 / 噪声卡片（对照只按时间排序）、标题和状态长度。
- 技能版本变了（event-assign 2.0.0、event-brief 1.1.0、home-rank 1.1.0），提示哈希随之变化：旧的数字（F1 0.711/0.733、事实召回 19/52 等）不能与新运行直接比较，需要在 dev 上重跑基线；holdout 只在最后评一次。

## 如何读结果

- `runtime.json`：是否完整跑完、素材处理时间、技能运行数、失败数、模型返回的 token 用量。
- `runs.json`：实际模型、输入摘要哈希、输出、校验失败和重试、耗时。用量是服务器报告值，不是云服务账单。
- `snapshots/`：每个检查点的完整状态，不把最终状态冒充所有历史检查点。
- `score.json` / `score.md`：原仓库评分器的输出，保留其口径；未修改指标来提高分数。
- `data/`：该次独立 SQLite 数据库，不上传 GitHub。

B³ F1 衡量事件分组，Link F1 通过一对一匹配事件再衡量素材关联。事实召回默认只看首页的一句话状态，因此它与“整个事件事实库是否保留全部事实”不同。过期事实率依据合成标注和关键词规则计算，不等于经过人工审阅的事实准确率。人物指标可能使用事件级姓名匹配退化口径，应在报告中注明。

`without-skills` 保留全局规则、JSON schema、业务校验器、候选检索和同一模型，只替换技能说明。它隔离的是技能说明文本的作用，不能用来宣称完整 Skills 架构相对无约束大模型或纯向量系统的全面优势。不调模型的检索基线由 `run_eval.py --condition baseline` 提供（`--embed url` 为向量、`--embed hash` 为词法）：留出集 B³ F1 分别是 0.336 和 0.463（见 `skills/event-assign/BENCHMARK.md`）。

## 已知能力边界

当前整理器每条素材只关联一个事件，标注集允许多事件；噪声可以留在“未归档”，但判断仍由模型给出，可能误判。每次归类最多看 5 个候选，每个候选展示固定对象 anchor、最早一条和最近两条素材；归类新素材截断至 1500 字符，简介只看最新 30 条、每条 600 字符。长文件和早期事实可能遗漏。这些都是待评估的产品限制，不能仅靠增加模型上下文长度解决。

`probe_models.py` 的四道判断题及一张截图用于接口和基本行为检查，样本很小，不能称为通用准确率。截图 schema 通过后仍需与原图逐条核对发言人、时间、原文。
