# 评测汇总（v6，2026-09-30）

公开仓库 README 和 `docs/EVALUATION.md` 里 v6 评测数字的机器可读来源。全部是合成数据（手机端到端用的是 iOS 模拟器里的合成素材），或 Mac 端识别评测的聚合数字；这里没有任何素材正文、音频或真人数据。截止时（2026-09-29）的评测在 [`../results-2026-09-29/`](../results-2026-09-29/README.md)，v6 没有重测的部分照抄自那里（`eval.json` 的 `v5_carried_over`）。

| 文件 | 内容 |
|---|---|
| `eval.json` | v6 的全部数字，每节带 `src`：规模场景加了事件合并（event-consolidate）之后、事件数对真值、小留出集按代码和条件拆开、item-split 1.3.0 的过度拆分、人物整理（person-resolve）、留出场景完整运行的前后对比、合并和人物整理的成本、新技能的可执行用例、遮号对整理效果的影响、号码遮得全不全、截图涂抹、Spark 上的存储、手机端到端、各分支的测试 |
| `integration.json` | 三条分支合进 `main`（整理器）和 `hackathon/base`（Mac 客户端）之后在整合版上做的检查：两边的测试、隐私端到端 68/68、手机端到端 67/67（前三次没全过的原因和修法）、遮号规范第 3 版的共享向量 |
| `data/make_charts.py` | 从 `eval.json` 画 11 张图（浅色、深色各一版，1920×1080）；公开仓库 `docs/img/eval-v6/` 里是浅色版 |

说明：

- 每组数字在各自的分支上测得（事件合并和人物在 `claude/quality-v6`，隐私在两边的 `claude/privacy-v6`，手机在 `claude/phone-v6` / `claude/phone-link-v6`），`eval.json` 的 `meta.code` 写了具体提交。**合并后的整体版本没有在规模场景上重跑**；整合版上做过的是 `integration.json` 里的测试和两条端到端。
- `src` 字段里的 `v6/…`、`v5/…`、`quality/…`、`privacy/…`、`phone/…`、`review/…`、`mask/…` 是评测资料目录里的报告（规模场景的状态库、调用记录原文和运行日志留在 Spark 上，没有入库）；`skills/…`、`eval/…`、`spark/…` 是本仓库的路径，`Packages/…`、`iOS/…` 是 Mac 客户端（公开仓库的 `mac/`）的路径。
- 遮号评测的工具在 [`../privacy/`](../privacy/)（号码压力集、遮号开关对照、成对调用、相似度），存储测量的结果是 [`../privacy/storage-lab.json`](../privacy/storage-lab.json)。
- 重画图：`python3 data/make_charts.py`（需要 matplotlib；图写到 `charts/`，不带 PNG 文字元数据）。
