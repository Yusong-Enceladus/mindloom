# 评测汇总与补充测量（2026-09-29）

仓库根目录 README 和 `docs/EVALUATION.md` 里评测数字的机器可读来源。全部是合成数据，或 Mac 端识别评测的聚合数字；这里没有任何素材正文、音频或真人数据。

| 文件 | 内容 |
|---|---|
| `eval.json` | 全部数字：规模场景、SKILL.md 正文消融、技能自带用例、整理模型对比（含每次运行明细）、每个技能的时延和 token、item-split 在规模数据上的拆分质量、读图、向量、读文件 33 种格式、System One、Mac 端识别和说话人、隐私出网统计 |
| `data/org/<模型>/<运行>/` | 在同一份代码 2e532bc 上新跑的整理评测：Qwen3.6 同代码重跑（`qwen36-ref`，留出集和 dev 各两次）、Muse Glimmer-30B、Gemma 4 26B-A4B、GLM-4.7-Flash、Mistral Small 4。每次运行有 `score.json` / `score.md`（`eval/score.py` 的输出）、`stats.json`、`meta.json` |
| `data/org-extra/qwen36-workers4/` | 整理器开 4 个 worker 时的留出集运行 |
| `data/org_notes.json`、`data/gpt-oss-partial.txt`、`data/partial_run.py` | 没跑完或没跑起来的模型和原因；gpt-oss-120b 跑到一半时按检查点打的分 |
| `data/runner/` | 在 Spark 上起 vLLM、跑整理评测的脚本：`v5org.sh`；`budget_wrap.py`（给 gpt-oss 加推理额度）；`nokwargs_wrap.py`（Mistral 的 tokenizer 不接受 `chat_template_kwargs`）；`shim/sitecustomize.py`（只给 Mistral 进程补上 transformers 5 改名的两个 Pixtral 函数，不改共用的 venv） |
| `data/skill-evals-main-n3.json` | `eval/run_skill_evals.py --n 3`：各技能 `evals/evals.json` 里 30 个可执行用例，每个 3 次 |
| `data/ledger_latency.py` → `data/ledger_latency.json` | 三个规模场景 Spark 上的调用记录（21,542 次调用）统计出的时延、token 和吞吐 |
| `data/split_boundary.py` → `data/split-{lab,startup,pm}.json` | item-split 在规模数据上实际切出的段对照分段真值 |
| `data/run_multiformat.py` → `data/multiformat-*.json` | `eval/files-multiformat` 测试集 115 个文件经整理器真实读文件路径的结果（两次运行和只解析的对照） |
| `data/egress.py`、`data/exiftags.py` → `data/egress.json` | 三个规模场景 Spark 实际收到的内容：条数、字节、音视频文件头、浮点向量、EXIF 标签（只输出汇总） |
| `data/build_eval.py`、`data/org_table.py`、`data/make_charts.py` | 汇总成 `eval.json`、生成模型对比表、画 `docs/img/eval-01..06.png` |

说明：

- 规模场景的数据库、调用记录原文和场景素材留在 Spark 上，没有入库（素材量大，只有合成数据）。所以 `ledger_latency.py`、`split_boundary.py`、`egress.py` 在这里不能直接重跑，脚本里的 `<scale-runs>`、`<demo>`、`<organizer-repo>` 是这些私有目录的占位符；它们的输出在本目录。
- 节点名统一写成 `spark-n1` 这样的编号；`src` 字段里的 `v5/data/…` 就是本目录的 `data/…`。
- 用 `python3 data/make_charts.py` 可以从 `eval.json` 重画六张图（需要 matplotlib；图写到 `charts/`）。
