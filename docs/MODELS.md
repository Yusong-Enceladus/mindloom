# 模型清单：每个功能用什么模型、在哪跑、为什么

这份文档按产品功能列出所用的模型、运行位置（Mac 或用户自己的 DGX Spark）、选型理由（和哪些备选比过），以及实测数字。

口径：

- **每个数字都给出处**，链到已提交的文件。本仓库里的文件用相对链接；其他分支和 bestASR（Mac 端）仓库里的文件，链到固定提交的 GitHub 地址。没有文件支撑的写"未测"。
- **日期**按提交时间写（Mac 本地时区 UTC−7）。部分 BENCHMARK 标题用的是北京时间，会比这里晚一天，说的是同一次测量。
- Spark 上的评测全部用合成数据。Mac 端的识别和整理评测用的是用户自己的口述，本文只引用聚合数字，不含任何内容。
- 有技能 / 无技能正文、dev / 留出集这些条件，以各 BENCHMARK 里的定义为准。n 都很小（通常每个条件 2 次），相差几个点的结论不稳。

## 总表

| 功能 | 模型 | 在哪跑 | 为什么选它（和什么比过） | 关键实测（日期 · 出处） | 注意 |
|---|---|---|---|---|---|
| 口述识别 · 实时稿 | SenseVoice small int8（FluidAudio，Core ML） | Mac | 延迟最低，能处理同一句里中英混说；只出草稿，终稿交给 Qwen3-ASR | 解码中位 150 ms，CER 5.75%（240 条口述，同一口径，2026-09-20 · [DICTATION_ARCHITECTURE §5.1][da]） | 公开 FLEURS 组合门槛没过，所以不当终稿用（[IMPLEMENTATION_STATUS][is]） |
| 口述识别 · 终稿 | Qwen3-ASR 1.7B 8-bit（MLX）＋停顿时预解码＋用户确认的 41 条词表 | Mac | 对比 Fun-ASR-Nano 4.69%、SenseVoice 5.75%、FireRedASR2（中文更好，但英文弱且没有 MLX 移植）；中英混说时英文召回决定选型；8-bit 和 bf16 差距在噪声内 | CER 3.74%，英文词召回 30/41，解码中位 939 ms（2026-09-20 · [§5.1][da]）；松手到插入 P50 545 ms / P90 635 ms（24 次真实口述 · [§2][da]） | 口述时常驻 5.17 GB，空闲释放后 0.93 GB（[§4][da]）；个人数据上做 ASR 微调和自动选词都测过，都让结果变差，已否决 |
| 口述整理 | 确定性规则整理＋个人整理模型 Qwen3-0.6B 8-bit（LoRA）＋忠实度护栏 | Mac | 对比 1.7B 4-bit 和 0.6B 4-bit：0.6B 8-bit 在每一项上都不差于 1.7B；通用 1.7B 润色在校对稿上更差（4.7% 对 4.1%），默认关闭 | 与最终文字距离 31.77，对校对稿精确率 98.12%，生成中位 193 ms，630 MB（2026-09-20 · [§5.2][da]） | 模型只存在用户自己的 Mac 上，不打包、不下载、不上传；护栏拒绝新增字超过 1% 的输出；插入最多等 250 ms（[IMPLEMENTATION_STATUS][is]） |
| 说话人 / 人物 | FluidAudio 0.15.5＋`fluid-speaker-diarization-coreml` | Mac | Argmax SpeakerKit、sherpa-onnx 只做过冒烟对比（[speaker-candidates.json][spk]）；公开 AMI 真人留出集只对 Fluid 跑过，并且通过 | 说话人混淆 2.07%，已知人误认 0，错误合并 0，已知查询 15/16，未知拒绝 16/16，RTF 0.0056，峰值 RSS 0.71 GB（2026-08-28 · [IMPLEMENTATION_STATUS][is]） | DER 24.93% / JER 31.78% 记为局限；声纹永不离开 Mac；16 GB 机型的发布门槛未测 |
| 翻译（Fn+⇧） | macOS 系统翻译（Translation 框架，端上运行） | Mac | 本机 1.7B 改了四轮提示词，流畅和完整始终不能兼得（[§11][da]）；系统引擎不占 App 的磁盘和内存 | 质量和时延：未测（换系统引擎之前 1.7B 为 179–316 ms · [§9.3][da]） | 2026-09-22 起改用系统引擎（[AppleTranslation.swift][atr]）；语言包由用户通过系统提示下载 |
| 语音指令（Fn+空格） | Qwen3-1.7B MLX 4-bit | Mac | 改写、翻译、代写这类"变换"任务又快又稳 | 10 条探针对 8 条，119–316 ms，首次加载 701 ms（2026-09-21 · [§9.3][da]） | 算术和单位换算会自信地答错；4B 已在代码里定义，但没有下载路径 |
| 事件归类 event-assign 2.1.0 | Qwen3.6-35B-A3B NVFP4（vLLM）＋Qwen3-Embedding-0.6B 候选检索 | Spark | DeepSeek-V4-Flash 质量相当（dev B³ F1 0.741 对 0.733），但单次 p50 慢约 1.5 倍、要占两台 Spark、不能读图（[event-assign 历史 1.0.0](../skills/event-assign/BENCHMARK.md)） | 最终版本（13c3ae1，还没有 item-split）留出集 B³ F1 0.782（无技能正文 0.612，向量 / 词法基线 0.336 / 0.463），dev 0.748；单次 p50 4.4–4.6 s（2026-09-28 · [event-assign](../skills/event-assign/BENCHMARK.md)）。当前代码 2e532bc 上同一模型留出集两次 0.771 / 0.706，均值 0.738（2026-09-29 · [results-2026-09-29](../eval/results-2026-09-29/README.md)） | 难干扰事件仍会被并到一起；n = 2，同代码两次就差 0.065 |
| 事件卡片 event-brief 1.4.0 | 同上 | Spark | 同上 | 留出集卡片事实召回 0.511（无技能正文 0.431），卡片里素材没给的日期 0；单次 p50 约 11 s（2026-09-28 · [event-brief](../skills/event-brief/BENCHMARK.md)） | 严格校验在重试后仍拒绝 26–37% 的调用，卡片因此会滞后 |
| 首页排序 home-rank 1.3.0 | 同上 | Spark | 同上 | 留出集 NDCG@5 0.932 / 0.914，只按时间排为 0.886（2026-09-28 · [home-rank](../skills/home-rank/BENCHMARK.md)） | dev 上不稳定（0.597 / 0.705，只按时间 0.661 / 0.532） |
| 多事拆分 item-split（代码 1.2.0；评测的是 1.1.1） | 同上 | Spark | 同上 | 1.1.1 在 split-dev 上切不切的判断 1.000，段 F1 0.937（2026-09-28 · [item-split][isb]）；1.2.0 只在 split-dev 上和 1.1.1 比过。规模场景实际切出的段：只讲一件事的素材有 22.4–32.8% 被切开（[results-2026-09-29](../eval/results-2026-09-29/README.md)） | split-dev 是调参集，数字偏乐观；规模数据上明显过度拆分 |
| 读图 image-read 1.0.0 | Qwen3.6-35B-A3B NVFP4（vLLM，同一个模型读图） | Spark | 四个本地 VLM 比过：Q8_0 同样准但慢一倍；Step3-VL-10B 读图表差（数据点 89.7%）且最慢；Qwen3-VL-8B 会给聊天补上图里没画的时间（85.9%） | mm-v1 test 98 张：类型判对 98% / 100%，关键字段 EM 96.2% / 98.8%（无技能正文 65.7% / 59.4%），p50 4.09 / 3.87 s（2026-09-28 · [image-read](../skills/image-read/BENCHMARK.md)，[VLM benchmark](../eval/multimodal/BENCHMARK.md)） | 合成图比真实照片干净；vLLM 在 temperature 0 下也不完全确定，边界图的类型判断会抖 |
| 读文件 file-read 1.0.0 | 解析：确定性代码（沙箱子进程，无模型）；文件里的图片：Qwen3.6-35B-A3B NVFP4（image-read）；概要和关键字段：同一个 Qwen3.6 | Spark | 文字靠解析器逐字读出（不让模型转写），模型只写一句概要和票据类字段，校验器要求其中的数字和值都能在文字里找到；有技能 / 无技能正文比过 | files-v1 test 40 个文件（20 类模板）：类型 40/40，解析文字召回 100%，图片部分召回 100% / 100%（无技能正文 93.8% / 91.7%），概要首次合规 36/38（无技能正文 1–2/38），p50 7.4 / 7.8 s（共用服务）（2026-09-29 · [file-read](../skills/file-read/BENCHMARK.md)，[FILE_READ](FILE_READ.md)） | 合成文件比真实文件干净；.msg 没有真实样本；n = 2 |
| 候选检索向量 | Qwen3-Embedding-0.6B（vLLM pooling） | Spark | 4B 的 R@5 只高 0–1.4 个点，代价是时延 1.6–3.2 倍、预留内存约 3 倍；词法基线在大候选池里只有 76.0% | R@5：dev 98.6%，留出集 100%，压力池 98.1%；单条 p50 25 ms（2026-09-28 · [eval/retrieval](../eval/retrieval/README.md)） | 嵌入服务挂掉时整理器退回不用向量的模式，压力池 R@5 掉到 59.6% |
| 合成数据生成 | Qwen3.6-35B-A3B NVFP4（3–4 台 Spark）＋DeepSeek-V4-Flash（两台 Spark TP2） | Spark | 用手上所有已部署的服务并行写；金标准来自确定性计划，不来自模型 | 三个场景各约 1,500–1,600 条；scale-lab 里单节点忙时 140–250 tok/s（Qwen）、40–47 tok/s（DeepSeek）（2026-09-28 · `throughput.json`（生成运行记录，含大量合成素材，未放进公开快照），其余见"合成数据生成"） | 吞吐受计划依赖、校验重试和共享节点限制，不代表服务上限 |
| 演示视频旁白 | Cartesia 公开演示的 TTS，预设音色 | 云端（只合成视频旁白稿，不接触任何产品数据） | 不克隆真人 | 未测 | 只用于演示视频，不属于产品；Spark 上部署过 Qwen3-TTS，但成片没有用它，也没有测量 |

下面按功能给细节。

## Mac 端（bestASR）

Mac 负责采集、识别、插入、搜索和声纹匹配，是源事实。所有模型只加载经过模型管理器校验的本地文件（[model-artifacts.json][ma]）。

### 口述识别

- **实时稿**：SenseVoice small int8，同时承担同一句里的中英混说。录音、导入等模式的终稿按语言路由：明确的普通话交给 Paraformer-large int8，明确的英语交给 Parakeet Unified int8（公开 FLEURS 调参 profile：普通话 CER 9.17%，英语 WER 7.80%，危险 token 错误 0 · [IMPLEMENTATION_STATUS][is]）。口述路径上这两个模型已被 Qwen3-ASR 取代，只作备用语种（[§4][da]）。
- **终稿**：Qwen3-ASR 1.7B 8-bit。同一套 240 条口述（其中 48 条用户逐字校对），用 `score_recognizers.py` 同一口径重算（[§5.1][da]，2026-09-20）：

  | 识别器 | CER | 5 秒以下 | 英文词召回（校对） | 解码中位 |
  |---|---|---|---|---|
  | **Qwen3-ASR 1.7B 8-bit＋41 词表（现用）** | **3.74%** | 8.17% | **30/41** | 939 ms |
  | 同模型 bf16（H100） | 3.78% | 8.17% | 29/41 | 710 ms |
  | Fun-ASR-Nano-2512 | 4.69% | 6.25% | 27/41 | 396 ms |
  | SenseVoice small | 5.75% | 8.65% | 24/41 | 150 ms |
  | FireRedASR2-AED（75 条子集） | 4.07% | 5.77% | 6/10 | 1367 ms |

  另一组测量：修掉 MLX 端特征提取的 bug 之后，CER 从 3.20% 降到 2.71%，英文词召回从 68% 升到 76%（以 40 条校对稿为真值，2026-09-19 · [IMPLEMENTATION_STATUS Round 7][is]）。两组的真值条数不同，不能直接相比。
- **时延**：停顿 150 ms 就在说话期间预解码，松手时通常整段命中。松手到插入 P50 545 ms / P90 635 ms（[§2][da]）。短句中间没有停顿时，松手后才从头解码，这是 P50 的主要成分。
- **词级对齐**：Qwen3-ForcedAligner 0.6B 8-bit，只服务历史回放。关键路径上平均 45 ms（[§13.5][da]）；AMI 调参集边界偏差中位 30 ms、P95 590 ms（[TECHNICAL_DESIGN][td]）。
- **否决过的方向**：用个人历史做 ASR LoRA，CER 从 2.57% 升到 8.43%；自动选词表比用户手选差（4.06% 对 3.74%）（[§5.1][da]）。

### 口述整理

先做确定性规则整理（去掉嗯/呃、单句不加句号）。个人整理模型在停顿时就开始算，插入最多等它 250 ms，25 字以下不等；护栏不通过就用规则整理的结果（[IMPLEMENTATION_STATUS][is]）。同一套数据训的三个版本，各按实际部署的位宽评测（[§5.2][da]）：

| 版本 | 与最终文字距离 ↓ | 对校对稿精确率 | 生成中位 | 体积 |
|---|---|---|---|---|
| 1.7B 4-bit | 32.28 | 98.01% | 241 ms | 948 MB |
| 0.6B 4-bit | 32.75 | 97.94% | 166 ms | 346 MB |
| **0.6B 8-bit（现用）** | **31.77** | **98.12%** | **193 ms** | **630 MB** |

小模型对量化更敏感：bf16 时 0.6B 更好，4-bit 时反而更差。

### 说话人与人物

FluidAudio 离线说话人分离，全局人物匹配。公开 AMI 真人留出集的数字见总表。在本机校准后，自动匹配阈值定为 0.70：原来的 0.93 这个模型根本达不到，结果一个人被拆成几十个陌生人（[§4.5][da]）。

### 翻译与语音指令

- 翻译走 macOS 系统翻译，没有退回本机模型：译错的一句写进别人的聊天框，比原话更糟。语言没装时按原话插入，并弹出系统的下载提示（[AppleTranslation.swift][atr]）。
- 语音指令走本机 Qwen3-1.7B 4-bit。1.7B 即使被要求不思考也会输出 `<think>`；在用户轮末尾加 `/no_think` 后，中英混合那条从 2103 ms 降到 179 ms，译文也变对了（[§9.4][da]）。

### 本机的其他模型

- 截图在 Mac 上用 Apple Vision 读字（简体中文和英文），结果只进本机搜索和导出，**不发送**（[IMPLEMENTATION_STATUS][is]、[TECHNICAL_DESIGN][td]）。准确率：未测。
- 链路关闭时，事件页用本机的 Apple NaturalLanguage 句向量加词法回退来整理（[TECHNICAL_DESIGN][td]）。准确率：未测。

## Spark 端（整理器）

整理服务只产出派生结果：事件归类、卡片、首页排序、拆分、读图。所有技能共用同一台 Spark 上的一个 Qwen3.6-35B-A3B NVFP4，外加一个 Qwen3-Embedding-0.6B。

### 为什么整理器用 Qwen3.6-35B-A3B NVFP4

- **对 DeepSeek-V4-Flash**：首轮（event-assign 1.0.0，dev）B³ F1 0.741 对 0.733，在同条件重复的波动范围内；DeepSeek 单次 p50 5.49 s 对 3.74 s（经 SSH 隧道，含网络开销）（[event-assign 历史 1.0.0](../skills/event-assign/BENCHMARK.md)）。DeepSeek 是纯文本模型，收到图片返回 HTTP 400（[image-read 历史](../skills/image-read/BENCHMARK.md)），而且要用 TP2 占两台 Spark。
- **对同模型的 Q8_0（llama.cpp）**：质量相同，单流约 70 tok/s 对约 100 tok/s（团队内部测量记录，未公开），读图时单路慢一倍（[VLM benchmark](../eval/multimodal/BENCHMARK.md)）。
- 一台 Spark 就放得下，而且同一个模型既做文字也读图。

### 文字技能（最终版本，2026-09-28）

驱动 `eval/run_eval.py`，留出集是 holdout-week-v2（46 条、7 个事件；第二次使用），每个条件 2 次。完整表格和独立性说明见 [event-assign](../skills/event-assign/BENCHMARK.md)（三个技能的最终一节相同）。

| 指标（留出集） | 有技能 | 无技能正文 | 出处 |
|---|---|---|---|
| 归事件 B³ F1 | 0.782 / 0.782 | 0.575 / 0.649 | [event-assign](../skills/event-assign/BENCHMARK.md) |
| 难干扰泄漏 ↓ | 0.250 / 0.250 | 0.083 / 0 | 同上 |
| 卡片事实召回 | 0.517 / 0.506 | 0.402 / 0.460 | [event-brief](../skills/event-brief/BENCHMARK.md) |
| 卡片里素材没给的日期 ↓ | 0 / 0 | 0 / 0 | 同上 |
| 首页 NDCG@5（只按时间排） | 0.932 / 0.914（0.886） | 0.814 / 0.797 | [home-rank](../skills/home-rank/BENCHMARK.md) |
| 单次 p50：assign / brief | 4.4 / 11.0 s；4.6 / 10.7 s | 5.0 / 12.7 s；4.9 / 13.0 s | [event-assign](../skills/event-assign/BENCHMARK.md) |

item-split 1.1.1 只在调参集上评过（[item-split BENCHMARK][isb]）：split-dev 51 条 × 3 次，切不切判断 1.000，段 P / R / F1 0.936 / 0.938 / 0.937，单件事被切开 0。吞吐测试里 40 条短素材，串行 9.15 条/分，流水线（4 个 worker）12.88 条/分。

### 读图（image-read）

先判类型（7 类加 other），再按该类型的 schema 抽取，最后由校验器拒绝图上找不到的字段和数字，重试一次仍不合格的值被清空。所有类型都走同一个 Qwen3.6 NVFP4；`ORGANIZER_IMAGE_ROUTES` 可以把某一类改到别的端点，现在没用。

**模型选型**（mm-v1 test 98 张，中性提示、类型直接给定、每个模型两次单路，2026-09-28 · [eval/multimodal/BENCHMARK.md](../eval/multimodal/BENCHMARK.md)）：

| 模型 | CER | 关键字段 EM | 有编造的图 | 聊天 发送者 / 时间 | 图表 数据点 / KPI | 单路 p50 / p90 | 并发 4 | 内存 |
|---|---|---|---|---|---|---|---|---|
| **Qwen3.6-35B-A3B NVFP4（vLLM）** | 0.3% | 98.6% | 0.5% | 98.7 / 100 | 100 / 100 | 2.64 / 5.13 s | 34.3 张/分 | 49.9 GiB（按 0.45 预留） |
| Qwen3.6-35B-A3B Q8_0（llama.cpp） | 0.5% | 98.6% | 1.5% | 100 / 100 | 100 / 100 | 5.43 / 10.2 s | 10.9 张/分（2 槽） | 40.8 GiB |
| Step3-VL-10B Q8_0（llama.cpp） | 1.2% | 96.6% | 2.0% | 100 / 96.2 | 89.7 / 100 | 12.55 / 25.07 s | 8.3 张/分 | 16.6 GiB |
| Qwen3-VL-8B-Instruct Q8_0（llama.cpp） | 1.0% | 95.9% | 2.0% | 97.4 / 85.9 | 100 / 100 | 10.0 / 20.62 s | 11.1 张/分 | 19.2 GiB |

逐条看过被计为"编造"的数字，都是把手写或门牌上的数字读错（21→27、155→755 这类），不是凭空写出来的内容。

**整理器里的真实路径**（image-read 1.0.0，代码在 92f4305 冻结后才跑 test，每个条件 2 次 · [skills/image-read/BENCHMARK.md](../skills/image-read/BENCHMARK.md)）：

| 条件 | 类型判对 | CER | 关键字段 EM | QA 可答 | 编造数字（不含 gist） | p50 / p90 |
|---|---|---|---|---|---|---|
| 有技能 r1 / r2 | 98.0% / 100% | 2.6% / 0.5% | 96.2% / 98.8% | 99.3% / 99.3% | 0.9% / 0.5% | 4.09 / 6.58 s；3.87 / 6.32 s |
| 无技能正文 r1 / r2 | 84.7% / 82.7% | 21.2% / 25.0% | 65.7% / 59.4% | 92.7% / 91.7% | 4.5% / 4.5% | 4.38 / 10.86 s；4.32 / 13.08 s |

r1 有 2 张白板照片被判成幻灯片，手写一类的分数因此掉了下来。比 benchmark 慢约 1.2 s，因为多了一步判类型，系统提示也更长。

### 候选检索向量

event-assign 只在检索出的前 5 个候选里选，所以 R@5 是归事件准确率的上限（2026-09-28 · [eval/retrieval/README.md](../eval/retrieval/README.md)，提交 0b8fd34，即变基前的 e3f596f）：

| 向量 | R@5 dev / 留出集 / 压力池 | 只看相似度 R@1（压力池） | 单条 p50 | 预留内存 |
|---|---|---|---|---|
| Qwen3-Embedding-4B | 100 / 100 / 99.0 | 93.3 | 43 ms | 18.7 GiB |
| **Qwen3-Embedding-0.6B（现用）** | **98.6 / 100 / 98.1** | **89.4** | **25 ms** | **5.9 GiB** |
| 字二元组哈希（词法） | 92.8 / 97.1 / 76.0 | 51.9 | 0.03 ms | 0 |
| 不用向量 | 78.3 / 88.6 / 59.6 | — | — | — |

漏掉的主要原因是融合分数里的时间和来源项，不是向量本身。要不要调权重或把 k 提到 8，需要在 dev 上另做实验，这次没改。

## Spark 服务

所有服务只监听 `127.0.0.1`，从 Mac 经 SSH 隧道访问。Spark 是 GB10、121 GiB 统一内存。

| 引擎 · 模型 | 节点 | 参数 | 实测（出处） |
|---|---|---|---|
| vLLM 0.30.0 · Qwen3.6-35B-A3B NVFP4＋MTP | spark-F（整理器主模型）、spark-B、spark-E；读图评测另在 spark-C 起了独占副本 | MTP×3 投机解码，fp8 KV，262k ctx；读图副本 max-num-seqs 4、util 0.45 | 单流约 100 tok/s，读入 5.7k–7.2k tok/s（2026-09-25 · 团队内部测量记录（未公开））；读图输出单路 124.3 tok/s，并发 4 时 240.5 tok/s，预留 49.9 GiB（2026-09-28 · [VLM benchmark](../eval/multimodal/BENCHMARK.md)） |
| llama.cpp d834d44 · Qwen3.6-35B-A3B Q8_0＋MTP 草稿 | spark-A | -np 2，ctx 131072 | 约 70 tok/s（团队内部测量记录，未公开）；读图单路 60.2 tok/s，并发 4 为 73.3 tok/s（[VLM benchmark](../eval/multimodal/BENCHMARK.md)） |
| llama.cpp · Step3-VL-10B / Qwen3-VL-8B Q8_0 | spark-A / spark-C | 预填空 `<think></think>`（Step3） | 读图并发 4：50.5 / 57.6 tok/s（[VLM benchmark](../eval/multimodal/BENCHMARK.md)）；只用于对照。Step3-VL 改走 llama.cpp 原生 `/completion` 并预填空的思考块后，`eval/probe_models.py` 的四道小题从 2/4 到 4/4，同一张截图 70.17 s → 19.16 s（2026-09-26 首轮评测，报告未公开） |
| vLLM 0.30.0 TP2 · DeepSeek-V4-Flash | spark-D＋spark-G | 必须关闭思考，否则输出预算全被推理用完 | 输出约 34 tok/s，读入 1.4k–2.3k tok/s，JSON 结构化输出约 2–3 s（团队内部测量记录，未公开） |
| vLLM pooling · Qwen3-Embedding-0.6B | 与整理器同卡 | max-model-len 8192，max-num-seqs 16 | 16 条一批 224 条/秒，预留 5.9 GiB（[eval/retrieval](../eval/retrieval/README.md)） |

单节点 8 路并发的聚合吞吐还没有入库文件，本文不引用，入库后再补。上面的数字大多是在共享节点上测的，只能粗比。

## 合成数据生成

三个规模场景都由确定性计划决定金标准，模型只负责写正文（关闭思考）。下面的吞吐都是 completion token，并且受计划依赖（按周分批、前情作上下文）、校验重试和同节点其他负载的限制，**不代表服务能跑到的上限**。

| 生成器 | 产出 | 节点 · 模型 · 吞吐 | 出处 |
|---|---|---|---|
| scale-lab | 首轮 1,488 条，3,590 s | Qwen NVFP4：spark-B 140.0、spark-E 141.9、spark-F 33.0 tok/s（spark-F 同时在服务别的评测）；DeepSeek：spark-D 40.9 tok/s；合计 350.3 tok/s。补跑两轮：spark-B 250.4 / 195.0 tok/s，DeepSeek 47.2 / 39.7 tok/s | `throughput.json`（生成运行记录，含大量合成素材，未放进公开快照） |
| scale-startup | 第 1–3 轮 1,489 条（计数器在写出前中断）；采用：Qwen 1,453 条，DeepSeek 97 条 | 第 4 轮（重写 61 条）：Qwen spark-E 185.4 tok/s | `throughput_summary.json`（生成运行记录，含大量合成素材，未放进公开快照） |
| scale-pm | 首轮 966 条，2,487 s；采用：Qwen 1,393 条，DeepSeek 203 条 | 并发 8 的两台 Qwen NVFP4 各 42.9 / 38.7 tok/s，节点 spark-A 上的 `qwen3.6-35b-a3b`（并发 2）34.0，DeepSeek（并发 3）11.4；合计 131.2 tok/s | `scenario.json `generation``（生成运行记录，含大量合成素材，未放进公开快照） |

scale-pm 首轮的单节点速率远低于 scale-lab，文件没有记录原因，所以这些数字不能当作服务速度。选 DeepSeek 作为第二个写手的理由也没有写进文件。

**演示视频旁白**：成片用的是 Cartesia 公开演示的 TTS 和一个预设音色（不克隆真人），只合成视频旁白稿，不接触任何产品数据，也不属于产品。Spark 上部署过 Qwen3-TTS（[VLM benchmark 测量条件](../eval/multimodal/BENCHMARK.md)），但成片没有用它，模型规格、合成质量和速度都没有测量。

## 多模态支持范围

原则（[TECHNICAL_DESIGN，2026-09-26 远程整理器一节][td]）：**音频按设计只在 Mac 上处理**；Spark 收到的是逐字稿、用户放进来的文字、截图字节和从文档提取的文字，而且只发往用户自己的 Spark，走可以随时关闭的 SSH 链路。声纹、说话人向量、词典永不发送。

| 输入 | 现在支持 | 在哪处理 | 还不支持 |
|---|---|---|---|
| 语音：口述、会议、电脑内录、导入的音视频 | 识别、说话人分离、人物匹配 | 只在 Mac。Spark 只收逐字稿和分段（时间、人物 ID、用户起的名字） | 音频发往 Spark：按设计不做 |
| 视频 | 音轨走导入管线；最多 12 张关键帧作为带 `parent_item_id` 的图片素材发往 Spark，由 image-read 读，跟随视频所在的事件（合约 2026-09-29） | 音轨只在 Mac；关键帧在用户的 Spark | 关键帧的读图质量：未单独评测 |
| 图片：PNG / TIFF / JPEG / HEIC | Mac 用 Apple Vision 读字供本机搜索；再发一份 ≤2560 px、≤12 MB、去掉 EXIF 的 PNG/JPEG 副本（`image_b64`），由 image-read 按 7 类读（聊天截图、图表看板、幻灯片、手写白板、小票发票、扫描件、标签面单标牌），其他归为 other | Mac（本机读字）＋用户的 Spark（image-read） | 多图、长截图、真实照片、图中的提示词注入：都还没有评测集，未测 |
| 文档和其他文件：Office（含 97–2003）、OpenDocument、PDF（含扫描件）、邮件、日程、名片、电子书、压缩包、网页存档、文本 / 代码 / 数据、iWork 预览 | 原始字节 ≤ 25 MiB 按 `kind=file` 发送，Spark 在沙箱子进程里解析；扫描页和文档里的图片交给 image-read；file-read 写概要和关键字段（[FILE_READ](FILE_READ.md)）。更大的文件发 Mac 提取的文字（`kind=text`） | 解析和整理在用户的 Spark；Mac 另外提取 `local_text` 兜底 | 真实文件的评测集、.msg 真实样本、图表和页眉页脚：未做 |
| 粘贴的文字、聊天记录 | 按 `kind=text` 发送；"名：…"格式会变成人物 | Spark | — |

出处：Mac 端收进来的类型、图片副本和不发送的内容见 [IMPLEMENTATION_STATUS][is]；Spark 端接受的类型和图片限制见 [`spark/organizer/schemas.py`](../spark/organizer/schemas.py)；读图的七个类型见 [`skills/image-read/SKILL.md`](../skills/image-read/SKILL.md)。

## 候选模型对比（2026-09 最新版本）

2026-09-28 晚到 09-29 凌晨（PDT），把能放进一台或两台 Spark 的最新开源模型挨个试了一遍，看能不能替换现在的读图、整理和向量模型。结果文件在 [`eval/models-v2/`](../eval/models-v2/)，每个模型一个目录（只入库了汇总、打分、服务参数和失败原因，逐条输出和权重留在 Spark 上）。

口径：

- 全部是合成数据。每个模型、每个条件只跑 **1 次**，n = 1，相差几个点的结论不稳。
- 引擎都是 vLLM 0.30.0，GB10（SM121），121 GiB 统一内存。除特别注明外，一个模型独占一台 Spark，只监听 127.0.0.1，关闭思考。NVFP4 模型按各自模型卡的 Spark 说明用 `VLLM_NVFP4_GEMM_BACKEND=marlin`。批处理脚本见 [`vbatch.sh`](../eval/models-v2/vbatch.sh)。
- **读图**：mm-v1 **test** 98 张，与上面"读图 · 模型选型"同一套 `bench/run_vlm.py` 和中性提示（类型直接给定，测的是读，不测分类）。准确率来自单路（并发 1），吞吐来自 28 张子集的并发 4。
- **整理**：`eval/run_eval.py --condition skills`，代码 2e532bc，技能提示哈希与 Qwen3.6 参考运行一致；dev-week-v1（82 条）/ holdout-week-v2（46 条）。检索都用 Qwen3-Embedding-0.6B。
- **向量**：item 级检索（每条素材作查询，同一事件的其他素材为相关项），dev 78 条 / 留出集 42 条。这个口径比上面"候选检索向量"一节的候选事件 R@5 严格得多，两边数字不能直接比。

### 试过的模型

| 模型 | 系列 | 发布 | 规模 · 量化 | 怎么跑的 | 测了什么 | 结果 |
|---|---|---|---|---|---|---|
| Qwen3.8-27B-FP8 | Qwen | 2026-08-05（FP8 08-13） | 27.8B 稠密，原生 VLM | 一台 Spark | 读图＋整理 | 完成 |
| Muse Glimmer-30B NVFP4 | Meta Muse | 2026-08-09（NVFP4 08-27） | 29.6B 稠密＋ViT | 一台 Spark，fp8 KV | 读图＋整理 | 完成 |
| Nemotron-3-Nano-Omni-30B-A3B NVFP4 | NVIDIA Nemotron VL | 2026-04-24 | 30B MoE，3B 激活 | 一台 Spark，fp8 KV，marlin | 读图＋整理 | 完成 |
| MiniCPM-V-4.6 | OpenBMB | 2026-05-11 | 1.3B | 一台 Spark，util 0.3 | 读图 | 完成 |
| GLM-OCR | 智谱 GLM | 2026-01-30 | 1.3B | 一台 Spark | 读图 | 完成 |
| PaddleOCR-VL-1.6 | 百度 PaddleOCR | 2026-05-27 | 0.96B | 一台 Spark | 读图 | 完成 |
| DeepSeek-V4-Flash | DeepSeek | 2026 | 304B MoE | **两台 Spark TP2**，MTP 1 | 整理（纯文本；读图仍交给 Qwen3.6） | 完成 |
| Nemotron-3-Super-120B-A12B NVFP4 | NVIDIA Nemotron | 2026-03-10 | 120B Mamba/注意力混合 MoE，12B 激活 | 一台 Spark | 整理 | 完成 |
| gpt-oss-120b | OpenAI gpt-oss | 2025-08-05 | 117B MoE，5.1B 激活，MXFP4 | 一台 Spark，reasoning low | 整理 | **中止**：671 s 只处理了 dev 82 条里的 10 条；44 个回答里 41 个撞到长度上限（[metrics-at-abort.txt](../eval/models-v2/gpt-oss-120b/metrics-at-abort.txt)） |
| Gemma 4 31B-it QAT（w4a16） | Google Gemma | 2026-04-02（QAT 06-04） | 31B 稠密 | 一台 Spark，fp8 KV 和不开 fp8 KV 各试一次 | 读图 | **不可用**：服务能起来，但所有请求（包括纯文本）只输出 token 0，98 张全部 HTTP 500；判断是 W4A16 compressed-tensors 的 Gemma 4 路径在 SM121 / vLLM 0.30.0 上 logits 退化（[NOTE.txt](../eval/models-v2/gemma4-31b-qat/retry/NOTE.txt)） |
| Mistral Small 4 119B NVFP4 | Mistral | 2026-03 | 119B MoE，6.5B 激活 | 一台 Spark | 整理（图片交给 Qwen3.6） | 第一次**起不来**：`PixtralForConditionalGeneration` 导入失败，装的 transformers 里没有 `PixtralRotaryEmbedding`（[failstart.txt](../eval/models-v2/mistral-small4/failstart.txt)）；09-29 只在这个进程里补上两个改名的函数、去掉 `chat_template_kwargs` 后跑通，整理完成 |
| Gemma 4 26B-A4B-it | Google Gemma | 未核对 | 26B MoE，4B 激活，bf16 | 一台 Spark | 整理（自己读图） | 完成（留出集两次） |
| GLM-4.7-Flash | 智谱 GLM | 未核对 | 30B MoE，3B 激活，bf16 | 一台 Spark | 整理（图片交给 Qwen3.6） | 完成（留出集两次） |
| Phi-4-reasoning-vision-15B | Microsoft Phi | 2026-01 | 15B 稠密 | 一台 Spark | 读图 | **起不来**：图像预处理配置读不了，装的 transformers 的 siglip2 里没有 `filter_out_non_signature_kwargs`（[failstart.txt](../eval/models-v2/phi4-rv-15b/failstart.txt)） |
| DeepSeek-OCR-2 | DeepSeek | 2026-01-27 | 3.4B MoE | 一台 Spark；vLLM 和原生提示各试一次 | 读图 | **起不来**：启动时 Triton kernel 编译失败（`LOG2E` 不是 constexpr）（[failstart.txt](../eval/models-v2/deepseek-ocr-2/failstart.txt)） |
| Keye-VL-2.0-30B-A3B | 快手 Keye | 2026-05-25 | 31B MoE，3B 激活 | 一台 Spark | 读图 | **起不来**：vLLM 0.30.0 不支持 `KeyeVL2MoeForConditionalGeneration`，模型代码还要 `fast_hadamard_transform` |
| ERNIE-4.5-VL-28B-A3B-Thinking | 百度 ERNIE | 2025-11 | 28B MoE，3B 激活 | 一台 Spark | 读图 | **起不来**：模型代码依赖的 `decord` 没装 |
| Nemotron-3.5-Lightning-30B-A3B NVFP4 | NVIDIA Nemotron | 2026-08-11 | 30B 混合 MoE，3B 激活 | 一台 Spark | 整理 | **起不来**：tokenizer 实例化失败 |
| Qwen3-VL-Embedding-8B | Qwen | 2026-01-07 | 8.1B，4096 维 | 一台 Spark，vLLM pooling | 向量 | 完成 |
| Nemotron-3-Embed-8B | NVIDIA Nemotron | 2026-07-14 | 8B，4096 维 | 一台 Spark，vLLM pooling | 向量 | 完成 |

Keye、ERNIE、Nemotron-3.5-Lightning 的启动日志留在 Spark 上，没有入库。缺的都是依赖或引擎支持，今晚没有为此改动 Spark 上共用的 venv。发布日期来自当晚核对过的模型卡；DeepSeek-V4-Flash 是之前就部署着的版本，记录里没有它的具体发布日。

### 读图（mm-v1 test，98 张）

| 模型 | JSON 合规 | CER ↓ | 关键字段 EM | QA 可答 | 编造数字 ↓ | 单路 p50 / p90 | 并发 4 | 内存（单进程峰值） |
|---|---|---|---|---|---|---|---|---|
| Qwen3.6-35B-A3B NVFP4（现用，2026-09-28 参考） | — | 0.3% | 98.6% | — | 0.5% | 2.64 / 5.13 s | 34.3 张/分 | 49.9 GiB（按 0.45 预留） |
| **Qwen3.8-27B-FP8** | 100% | **0.4%** | **98.8%** | **99.7%** | 0.5% | 10.97 / 21.41 s | 14.3 张/分 | 50.6 GiB |
| Muse Glimmer-30B NVFP4 | 100% | 0.6% | 97.6% | 99.3% | 0.0% | 17.81 / 34.85 s | 11.9 张/分 | 58.2 GiB |
| Nemotron-3-Nano-Omni NVFP4 | 98.0% | 2.6% | 87.8% | 95.1% | 0.7% | 4.68 / 9.69 s | 25.3 张/分 | 54.3 GiB |
| MiniCPM-V-4.6 | 88.8% | 21.3% | 58.1% | 72.6% | 5.2% | 3.18 / 36.77 s | 31.1 张/分 | 29.3 GiB |
| GLM-OCR | 55.1% | 53.6% | 19.1% | 52.9% | 0.3% | 4.13 / 35.88 s | 9.3 张/分 | 35.9 GiB |
| PaddleOCR-VL-1.6 | 10.2% | 97.6% | 0.9% | 3.3% | 0.0% | 21.30 / 21.36 s | 11.9 张/分 | 34.9 GiB |
| Gemma 4 31B QAT | 0 / 98 可用（全部 HTTP 500） | | | | | | | 58.4 GiB |

出处：各模型目录下的 `summary.json` / `vlm-score.json`，例如 [qwen3.8-27b-fp8](../eval/models-v2/qwen3.8-27b-fp8/summary.json)；Qwen3.6 参考行来自 [eval/multimodal/BENCHMARK.md](../eval/multimodal/BENCHMARK.md)（同一套图和提示，"—"表示那份报告没有这一列）。

三个 OCR 专用小模型（MiniCPM、GLM-OCR、PaddleOCR）在这套"按 schema 输出 JSON"的任务上不合格：它们习惯输出整页文字，JSON 合规率低，分数主要是格式问题，不代表它们认字差。按各自模型卡提示再跑一次的脚本是 [`ocr_after.sh`](../eval/models-v2/ocr_after.sh)，结果没有入库，本文不引用。

### 整理（dev-week-v1 / holdout-week-v2）

| 模型 | 怎么跑 | B³ F1 | Link F1 | 卡片事实召回 | 状态行事实召回 | 难干扰泄漏 ↓ | 首页 NDCG@5 | 卡片通过校验 | 事件数 预测/金标准 | 秒/条 |
|---|---|---|---|---|---|---|---|---|---|---|
| Qwen3.6-35B-A3B NVFP4（现用；旧代码 13c3ae1，r1 / r2） | 一台 Spark | 0.763 / 0.733；0.782 / 0.782 | 0.798 / 0.740；0.686 / 0.686 | 0.808 / 0.692；0.517 / 0.506 | 0.385 / 0.346；0.184 / 0.138 | —；0.25 | — | —；27/43、32/43 | — | 13.2 / 13.6；15.9 / 15.8 |
| Qwen3.6-35B-A3B NVFP4（现用；同代码 2e532bc 重跑，r1 / r2） | 一台 Spark | 0.774 / 0.759；0.771 / 0.706 | 0.798 / 0.775；0.710 / 0.722 | 0.808 / 0.712；0.494 / 0.598 | 0.462 / 0.346；0.184 / 0.218 | 0 / 0；0.167 / 0 | 0.623 / 0.556；0.890 / 0.859 | 63/79、64/79；33/50、29/50 | 14/9、12/9；9/7、13/7 | 6.3 / 6.1；8.5 / 9.5 |
| **Qwen3.8-27B-FP8** | 一台 Spark | **0.837 / 0.834** | **0.860 / 0.815** | **0.846 / 0.644** | 0.308 / 0.172 | **0 / 0** | 0.855 / —* | 68/78 / 34/49 | 12/9 / 7/7 | 36.5 / 52.2 |
| Muse Glimmer-30B NVFP4 | 一台 Spark | 0.672 / 0.832 | 0.705 / 0.844 | 0.692 / 0.644 | 0.288 / 0.299 | 0.083 / 0 | 0.703 / 0.911 | 49/81 / 15/50 | 19/9 / 10/7 | 38.1 / 56.6 |
| Gemma 4 26B-A4B-it（bf16，只跑了留出集，r1 / r2） | 一台 Spark | 0.786 / 0.786 | 0.826 / 0.826 | 0.690 / 0.678 | 0.368 / 0.368 | 0 / 0 | 0.966 / 0.983 | 32/50、32/50 | 10/7、10/7 | 37.3 / 37.4 |
| GLM-4.7-Flash（bf16，只跑了留出集，r1 / r2） | 一台 Spark | 0.746 / 0.755 | 0.660 / 0.660 | 0.437 / 0.414 | 0.195 / 0.184 | 0.333 / 0.417 | 0.719 / 0.742 | 15/54、16/54 | 12/7、11/7 | 39.3 / 39.7 |
| Mistral Small 4 119B NVFP4（只跑了留出集） | 一台 Spark | 0.480 | 0.453 | 0.310 | 0.218 | 0.215 | 0.723 | 13/53 | 19/7 | 32.8 |
| DeepSeek-V4-Flash | 两台 Spark TP2 | 0.784 / 0.735 | 0.809 / 0.710 | 0.731 / 0.609 | 0.365 / 0.287 | 0 / 0.417 | 0.797 / 0.960 | 61/79 / 24/50 | 15/9 / 9/7 | 15.9 / 24.3 |
| Nemotron-3-Super-120B NVFP4 | 一台 Spark | 0.764 / 0.728 | 0.821 / 0.623 | 0.788 / 0.322 | **0.423** / 0.126 | 0.071 / 0.778 | 0.692 / 0.762 | 47/81 / 12/51 | 12/9 / 7/7 | 31.5 / 44.0 |
| Nemotron-3-Nano-Omni NVFP4 | 一台 Spark | 0.365 / 0.395 | 0.382 / 0.354 | 0.423 / 0.207 | 0.192 / 0.080 | 0.095 / 0 | 0.309 / 0.537 | 47/86 / 18/59 | 47/9 / 34/7 | 11.2 / 19.0 |
| gpt-oss-120b | 一台 Spark | 中止，见上表 | | | | | | | | |

\* 这一格的 NDCG@5 超过了 1，说明留出集上那次首页打分有缺陷，已删去不用。

出处：[qwen3.8-27b-fp8/summary.json](../eval/models-v2/qwen3.8-27b-fp8/summary.json)、[deepseek-v4-flash/result.md](../eval/models-v2/deepseek-v4-flash/result.md)（含 Qwen3.6 参考行，[scores.json](../eval/models-v2/deepseek-v4-flash/scores.json)）、[nemotron-3-super…/summary.json](../eval/models-v2/nemotron-3-super-120b-a12b-nvfp4/summary.json)、[nano-omni-org/org/*/score.json](../eval/models-v2/nano-omni-org/org/)。卡片通过校验 = event-brief 在一次重试后通过的调用数 / 总调用数。

- 第一行 Qwen3.6 参考用的是较早的代码（没有 item-split，读图用旧的 screenshot-read），只能粗比；第二行是 2026-09-29 在 2e532bc 上的同代码重跑，和其余各行可以直接比。新加的 Muse Glimmer、Gemma 4、GLM-4.7-Flash、Mistral Small 4 的运行文件在 [eval/results-2026-09-29/data/org/](../eval/results-2026-09-29/data/org/)。Mistral Small 4 第三次才跑通：只在这个进程里补上 transformers 5 改名的两个 Pixtral 函数，再去掉请求里的 `chat_template_kwargs`（脚本在 [data/runner/](../eval/results-2026-09-29/data/runner/)）。gpt-oss-120b 用 reasoning low、每次调用多给 2048 token 输出额度重试，80 个请求都正常结束，但每条 125 秒，跑到留出集 24/46 条时停下（[gpt-oss-partial.txt](../eval/results-2026-09-29/data/gpt-oss-partial.txt)）。
- Nano-Omni 读图还可以，但当整理器会把事情切得很碎（dev 47 个事件对金标准 9 个），分组分数只有其他模型的一半。
- Muse Glimmer 的留出集结果和 Qwen3.8 一样高（0.832），但 dev 只有 0.672，留出集卡片只有 15/50 通过校验，不稳定。

### 向量（item 级检索，dev / 留出集）

| 模型 | 维度 | Recall@5 | MRR | NDCG@10 |
|---|---|---|---|---|
| **Qwen3-VL-Embedding-8B** | 4096 | **0.868** / 0.854 | 0.987 / 0.965 | **0.802** / 0.799 |
| Nemotron-3-Embed-8B | 4096 | 0.795 / 0.835 | 0.987 / **0.978** | 0.747 / **0.809** |
| Qwen3-Embedding-0.6B（现用） | 1024 | 0.798 / 0.839 | 0.964 / 0.966 | 0.733 / 0.776 |

出处：[eval/models-v2/embeddings/](../eval/models-v2/embeddings/)。

### 每个功能谁赢、为什么

- **读图：Qwen3.8-27B-FP8 最准**（CER 0.4%、关键字段 EM 98.8%、QA 99.7%），但比现用的 Qwen3.6 NVFP4 只高 0.2 个点（98.8% 对 98.6%），单路 p50 慢约 4 倍（10.97 s 对 2.64 s），并发 4 吞吐不到一半（14.3 对 34.3 张/分）。Muse Glimmer 紧随其后，是唯一没有编造数字的高分模型，但更慢。Nano-Omni 是新模型里最快的（p50 4.68 s），关键字段 EM 87.8%，不够当默认。
- **整理：Qwen3.8-27B-FP8 最好。** 两个场景的 B³ F1 都最高（0.837 / 0.834），难干扰泄漏都是 0。代价是速度：每条 36.5 / 52.2 s，是同代码上现用 Qwen3.6（6.1–9.5 s）的约 6 倍。Gemma 4 26B-A4B 留出集两次都是 0.786、卡片事实召回最高，每条 37 s，是最值得跟进的新模型。DeepSeek-V4-Flash 快一些，但要占两台 Spark，留出集泄漏 0.417。Nemotron-3-Super 状态行事实召回在 dev 最高，但留出集泄漏 0.778，卡片只有 12/51 通过校验。
- **向量：Qwen3-VL-Embedding-8B 在 dev 上最好**（R@5 0.868），在留出集上三者接近（Nemotron 的 MRR 和 NDCG@10 在那里最高）。换成 4096 维要重建全部索引，预留内存也会从约 6 GiB 涨到一个 8B 模型的量级；而上面"候选检索向量"一节已经表明，归事件准确率的瓶颈在融合分数里的时间和来源项，不在向量本身。

### 默认用什么

- **默认不变：Qwen3.6-35B-A3B NVFP4（读图＋整理）＋Qwen3-Embedding-0.6B。** 理由是速度：整理器是边收边整理的后台服务，三个 1,500–1,600 条的规模场景用 Qwen3.6 每分钟约 4 条、各要 6.3–7.2 h（[eval/scale/README.md](../eval/scale/README.md)），换成每条 52–57 s 的模型，串行处理 1,600 条要 23–25 h；读图的准确率差距只有 0.2 个点。一台 Spark 放一个模型就能同时做文字和读图，这点也保持不变。
- **质量选项：Qwen3.8-27B-FP8。** 同一台 Spark 放得下（读图时单进程约 51 GiB），同一个模型既读图也整理，接口相同（OpenAI 兼容，关闭思考）。适合不在乎等待、只关心分组和卡片质量的用户，或者夜间重整理。同一代码上它在留出集领先默认模型（B³ 0.834 对两次均值 0.738），但只跑了一次；改成默认之前要再跑一次并在规模场景上验证。
- **不采用**：DeepSeek-V4-Flash（两台 Spark，质量没有稳定优势）；Nemotron-3-Super、Nano-Omni、gpt-oss-120b（整理质量或完成度不够）；OCR 专用小模型（这套 JSON 读图任务不合格）；8B 向量模型（留出集差距小，成本高）。

## 未测和缺口

- Mac：16 GB 最低配置上的识别、说话人和内存门槛；系统翻译的质量和时延；Apple Vision 本机读字的准确率。
- Spark：item-split 1.2.0 没有规模或留出结果（规模场景上较早的版本明显过度拆分）；读图只有合成图；单节点 8 路并发吞吐还没入库。
- 所有 Spark 评测每个条件只有 n = 2，而且 vLLM 在 temperature 0 下也不完全可复现。

[da]: ../mac/DICTATION_ARCHITECTURE.md
[is]: ../mac/IMPLEMENTATION_STATUS.md
[td]: ../mac/docs/architecture/TECHNICAL_DESIGN.md
[ma]: ../mac/config/model-artifacts.json
[spk]: ../mac/config/speaker-candidates.json
[atr]: ../mac/App/AppleTranslation.swift
[isb]: ../skills/item-split/BENCHMARK.md
