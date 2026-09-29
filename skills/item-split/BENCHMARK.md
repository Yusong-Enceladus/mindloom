# item-split benchmark

## 1.1.1：去掉来自 split-dev 的措辞后（代码 592da22，2026-09-29，只在 dev 集上评）

> split-dev 是 item-split 的调参集（`eval/scenarios/split-dev`），不是留出集；这里的数字都偏乐观。item-split 还没有在任何留出集上评过。

改动：1.1.0 的 SKILL.md 里有几处例子直接来自 split-dev（一条笔记的标题、一句"不用跟进的念头"的原话、续租和婚礼两个话题的说法）。
1.1.1 把它们换成与所有场景无关的虚构例子，规则本身不变。同时 `organizer/transcripts.py` 改为与 Mac 端 `MemoryTranscriptText` 逐条相同的规则（见 README）。

模型 Qwen3.6-35B-A3B NVFP4（spark-a :8000，thinking 关，temperature 0）；检索 Qwen3-Embedding-0.6B（:8013）；回放时钟；不回答问题；串行（`--workers 1`）。

**只看切分**（`eval/tools/split_eval.py`，split-dev 51 条 × 3 次，不归事件）：

| 版本 | 切不切判断对 | 段数完全对 | 段 P / R / F1 | 单件事被切开 ↓ | 多件事没切 ↓ | 两次不合格后裁短 gist |
|---|---|---|---|---|---|---|
| **1.1.1**（`116cc81338c06f19`） | 1.000 | 0.817 | 0.936 / 0.938 / 0.937 | 0 | 0 | 3 |
| 1.1.0（`8a546d04ce1a40aa`，含 split-dev 措辞） | 1.000 | 0.797 | 0.940 / 0.962 / 0.951 | 0 | 0 | 0 |

**端到端**（`eval/run_eval.py --owner-aliases scenario`，n = 1，每行一次运行）：

| 场景 · 版本 | B³ P / R / F1 | Link F1 | 段 Link P / R / F1 | 按段归档的素材（真：2 件以上 39） | 预测事件（真） | 难干扰泄漏 ↓ | 真实素材留在未归档 ↓ | 人物关联 |
|---|---|---|---|---|---|---|---|---|
| **split-dev · 1.1.1** | 0.951 / 0.537 / 0.686 | 0.745 | 0.752 / 0.667 / 0.707 | 35 | 21（11） | 0.262 | 4 | 0.870 |
| split-dev · 1.1.0（b3c4678） | 0.947 / 0.499 / 0.654 | 0.675 | 0.675 / 0.614 / 0.643 | 35 | 28（11） | 0.167 | 4 | 0.870 |
| **dev-week-v1 · 1.1.1**（回归） | 0.951 / 0.673 / 0.788 | 0.821 | 不适用 | 1（dev 无分段标注） | 12（9） | 0.083 | 0 | 0.306 |
| dev-week-v1 · 1.1.0（b3c4678） | 0.956 / 0.633 / 0.762 | 0.786 | 不适用 | 1（同一条） | 14（9） | 0.000 | 0 | 0.306 |
| 参照：dev-week-v1 最终版 13c3ae1（event-assign BENCHMARK） | 0.95 / 0.64；0.94 / 0.60 → 0.763 / 0.733 | 0.798 / 0.740 | 不适用 | — | 14、15 | 0 / 0.119 | 0 / 0 | — |

- 去掉 split-dev 措辞后，只看切分的段 F1 从 0.951 降到 0.937（召回 0.962 → 0.938），切不切的判断仍然全对，没有把单件事切开。
- 端到端的差别在 n = 1 的波动范围内（dev 上最终版两次之间就差 0.03）：split-dev 的 B³ F1 0.654 → 0.686、难干扰泄漏 0.167 → 0.262；
  dev 的 B³ F1 0.788，不低于最终版的两次（0.763 / 0.733），切分没有伤到 dev。
- dev 上两个版本都只切开了同一条素材：同一个项目的两件子任务（技能说这种情况不该切）。两段都归进同一事件，对分数没有影响；Mac 上显示为同一事件里的两段。
- split-dev 的主要损失在召回：预测事件 21 个对真实 11 个，说明切出来的段常常新建事件而没归进已有的同一件事。
- 用时（共享 vLLM，与其他负载并发）：split-dev 1405 秒（2.18 条/分），dev 842 秒（5.84 条/分）；item-split 首次合规 41 / 44 次。

**吞吐**（`eval/tools/throughput.py`，40 条虚构素材：26 条口述、10 条粘贴文字/笔记、4 条会议转写；一次全部排队后清空队列；spark-a，vLLM 当时没有其他请求）：

| `ORGANIZER_WORKERS` | 用时 | 条/分 | 模型调用（assign / brief / rank / split） | 事件数 |
|---|---|---|---|---|
| 1（串行） | 262 秒 | 9.15 | 45 / 45 / 5 / 4 | 12 |
| 4（流水线，lag 2） | 186 秒 | 12.88 | 45 / 45 / 5 / 4 | 12 |

- 流水线快约 1.4 倍：归事件（event-assign）仍按队列顺序逐条进行，是这条流上的瓶颈；简介、首页排序、切分和向量才能并发。
- 这批素材很短；真实混合的素材更长、简介更重（dev 串行 2.2–5.8 条/分，取决于 vLLM 负载）。

结果文件：`eval/runs/split-eval-sf-v1.1.1-n3.json`、`eval/runs/split-eval-v1.1.0-n3.json`、`eval/runs/sf-split-dev-skills-r1/`、`eval/runs/sf-split-dev-v1.1.0-r1/`、
`eval/runs/sf-dev-skills-r1/`、`eval/runs/sf-dev-v1.1.0-r1/`、`eval/runs/throughput-sf/summary.json`（快照、`runs.jsonl` 和数据库留在 spark-a `~/hack/claude-scalefeat/out` 与 `~/hack/claude-scale/out`）。

复现（spark-a，工作树 rsync 到 `~/hack/claude-scalefeat/repo`，自己的 venv，`EVAL_GIT_REV=592da22`）：

```bash
L="--llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8013/v1"
python3 eval/tools/split_eval.py eval/scenarios/split-dev/scenario.json --llm-url http://127.0.0.1:8000/v1 --out ../out/split-eval-v1.1.1-n3.json --n 3 --threads 6
python3 eval/run_eval.py --scenario eval/scenarios/dev-week-v1/scenario.json --condition skills $L --keep-db --out ../out/dev-sf-r1
python3 eval/run_eval.py --scenario eval/scenarios/split-dev/scenario.json --condition skills $L --owner-aliases scenario --keep-db --out ../out/sd-sf-r1
python3 eval/tools/throughput.py $L --items 40 --workers 1 4 --out ../out/throughput
```
