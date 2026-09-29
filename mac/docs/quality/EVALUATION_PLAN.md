# 本地模型与软件质量评估计划

> 目标：用同一套可重复数据选择实现，并把模型升级变成可回归的软件变更。

## 1. 评估对象

- 流式 ASR、句末 ASR、最终 ASR/forced alignment。
- VAD、在线 diarization、离线 diarization、speaker embedding/全局人物匹配。
- 口述润色、标题、摘要、章节、决策与待办。
- 捕获边界、AudioJournal、文本插入、搜索、迁移、资源与隐私网络。

## 2. 语料分层

| 层 | 内容 | 用途 |
|---|---|---|
| `public` | 许可明确的普通话、英语、会议/diarization 数据 | 候选初筛与可复现基线 |
| `product-synthetic` | 数字、金额、日期、否定、邮箱、URL、代码术语、词典词的脚本录音/合成扰动 | 精确验证危险 token 与格式 |
| `device-lab` | 同一脚本经近场、远场、Mac 扬声器、Chrome/会议压缩、不同麦克风重放 | 跨通道与捕获链验证 |
| `private-consented` | 明确同意、只留本机的真实口述/会议样本 | 最终产品相关性；绝不提交音频到 Git |
| `adversarial` | 重叠、相似声音、长静音、噪声、回声、断流、设备切换 | 失败降级和误合并防护 |

人物语料必须包含同一脚本和同一批已授权说话人经口述、线下麦克风、系统音频与导入媒体四条入口处理的配对样本。口述子集同时覆盖 1/2/3 人、快速轮流、短发言、重叠和背景人声，不能用“口述入口”作为只测单人的筛选条件。

Git 只保存 corpus manifest、许可、脚本、不可逆摘要与聚合指标。私人音频路径、文本和声纹不进入仓库。

## 3. Manifest 最小字段

- corpus/version/license/source/consent class；
- sample UUID、语言、场景、通道、设备、人数、重叠比例、时长；
- 音频 SHA-256、本机相对别名，不保存私人绝对路径；
- ground truth 版本、标注规范、标注者一致性或合成来源；
- train/tune/release-holdout 分割；
- 禁止用 release holdout 调阈值。

## 4. ASR 指标

- 普通话 CER、英语 WER、中英文混输 MER；
- 人名/公司/产品/技术术语实体错误率；
- 数字、金额、日期、否定、邮箱、URL exact match；
- 词典命中收益与非词典误伤；
- first partial、first stable、endpoint→refined 延迟 P50/P95；
- 流式 revision churn：稳定前每字符被改写次数与回改跨度；
- 最终 RTF、峰值 RSS、swap、CPU/GPU/ANE 时间和热状态；
- 时间戳绝对误差与点击回放可用性；
- 空白/音乐/噪声幻觉率。

公开 benchmark 只做候选参考；默认模型以本地 product-weighted score 和所有硬门槛共同决定，不能用加权平均掩盖危险 token 或延迟失败。

### 4.1 版本化计算口径

`BestASRBenchmark`/`BenchCLI score` 使用 v1 输入与输出 contract：输入记录实现 revision、协议版本、artifact digest、完整配置、corpus split 和硬件环境；输出只保留聚合指标与失败 sample UUID，并记录对排序键规范化 JSON 计算的 SHA-256 `configHash`。

- CER 对 NFC 后、去空白的扩展字素计算 Levenshtein 距离；WER 对 Unicode 字母/数字词元计算；MER 把每个 Han 字与连续字母/数字词分别作为词元。
- dangerous-token errors 按数字、日期、否定、人名和行动责任人类别分别对标注序列计算编辑距离，不能被平均质量分数抵消。
- 聚合结果同时输出 `dangerous-token-errors` 总数与 `.number`、`.date`、`.negation`、`.person`、`.action-owner` 五个分类指标；任一分类失败均可单独触发硬门槛。
- DER 先按最大重叠执行全局一对一 speaker mapping，再以 `(miss + false alarm + confusion) / reference speaker-time` 计算；JER 是每个 reference speaker 的 `1 - intersection / union` 后取均值。
- false merge/split 使用 occurrence pair 统计，false reject 只以证据充分但返回 unknown 的 occurrence 为分母。
- latency P50/P95 使用 nearest-rank；RTF 为总推理时长除以总音频时长；峰值 RSS 与 backlog 取 run 内最大值。

手算 golden 输入位于 `Tests/Fixtures/Benchmark/golden-run.json`，结果同时受 `benchmark-run.schema.json` 与 `benchmark-result.schema.json` 约束。

### 4.2 候选 adapter contract probe

`config/inference-candidates.json` 固定 FluidAudio/SenseVoice、Argmax OSS/WhisperKit 与 sherpa-onnx 的候选 runtime 版本、来源 revision、许可状态、能力和网络策略。所有 adapter 只接受 ModelManager 已校验的 artifact，禁止依赖 SDK 的隐式下载路径。`script/run_candidate_adapter_probe.sh` 用同一组十个无音频、纯合成 contract fixtures 覆盖 `ASR-001..010` 的请求/响应语义，包括中英/混说路由、词典上下文、单调时间戳、有界长会话上下文和 replace-range 修订关系。

该 probe 的 digest 只覆盖提交的 contract fixture，`executionMode` 明确为 `contract-fixture-runtime`，不能当作真实模型识别质量、速度、内存或许可放行证据。真实 model artifact digest、供应链复核、16 GB 最低设备及推荐内存设备的同 corpus matrix 均属于后续硬门槛；在此之前 registry 必须保持无默认候选且 `releaseEligible: false`。

### 4.3 推荐内存机器真实运行时冒烟

固定版本的 FluidAudio 0.15.5、Argmax OSS/WhisperKit 1.0.0 与 sherpa-onnx 1.13.2 已在一台 Apple M4 Pro / 48 GB 机器上，用三个本地合成的普通话、英语和混说样本完成断网真实推理。模型树、运行时 commit、语料 manifest 和每份聚合结果都用 SHA-256 串联；仓库不保存音频、逐字参考、候选原文、模型文件或绝对路径。

| 候选 | CER | WER | MER | 危险 token 错误 | P95 | RTF | 峰值 RSS | 实际 provider |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Fluid/SenseVoice | 0.0052 | 0.0250 | 0.0116 | 0 | 1620 ms | 0.1788 | 66,764,800 B | Core ML CPU+NE |
| WhisperKit tiny | 0.4794 | 0.5750 | 0.5116 | 6 | 660 ms | 0.0695 | 101,416,960 B | Core ML CPU+NE |
| sherpa bilingual Zipformer | 0.7371 | 0.4500 | 0.1512 | 2 | 910 ms | 0.1073 | 814,579,712 B | ONNX Runtime CPU |

sherpa 的 Core ML provider 探针由固定运行时明确回退至 CPU，因此不得宣称 Core ML 加速。上述样本数太小，且没有 16 GB、release holdout、热降级、长会话、流式 revision churn、时间戳和噪声/静音数据；它只完成任务 6.4 的真实 artifact/运行时佐证与任务 6.5 的推荐内存冒烟子集，不能用于选择默认模型。完整状态见 `artifacts/evidence/SPIKE-ASR-001/recommended-memory-smoke-summary.json`。

### 4.4 公开真人 FLEURS 分阶段调优

`config/fleurs-asr-evaluation.json` 固定 Google FLEURS revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`、CC BY 4.0 许可、下载文件大小与 SHA-256、确定性的性别/时长分层选择及本地输出边界。调优集含 24 条普通话真人、24 条英语真人和原有 16 条产品合成危险语义/静音样本。仓库中的 `Corpus/public/fleurs-asr-tuning-manifest.json` 不含路径、音频或文字；内容与逐条诊断只能写入外置本地根。

组合 profile 使 SenseVoice 的真实局限显现：CER 47.36%、WER 83.79%、MER 35.12%，英语真人中 15/24 为空，因此拒绝它作为全语言终稿默认。普通话 profile 上 Paraformer int8 以 CER 14.96% 通过；英语 profile 上 Parakeet Unified int8 以 WER 7.80% 通过。两者危险 token 错误均为 0、没有 runtime failure，聚合证据位于 `artifacts/evidence/SPIKE-ASR-002/`。App 的候选路由必须满足：用户不选模型或语言；明确单语终稿使用相应通过模型；真正句内混输保留多语模型；无语音仍为空且保留原音；任一专用模型不可用时回退；最终 provenance 记录实际模型。该调优集没有独立 release holdout 标记，所以只允许候选集成，不允许将 `releaseEligible` 改为 true。

## 5. 说话人与人物指标

- DER、JER、speaker confusion、miss、false alarm；
- identity fragmentation、错误合并、错误拆分、重叠语音表现；
- 同人跨近场/远场/压缩/设备的 true accept；不同人的 false accept；
- 自动高置信、中置信候选、低置信未知分别报告 precision/coverage；
- 用户完成一次纠错所需操作与受影响记录数；
- release holdout 要求自动高置信合并零已知错合，宁可降低覆盖率；
- 四类入口分别报告同一组 DER/JER、分段、未知/候选/匹配和全局人物指标；单人只是人数为 1 的样本，不另设宽松身份语义；
- 口述必须单列 1/2/3 人、快速轮流、短片段、重叠和背景声结果，并验证每个稳定说话人都产生可检索的 `SpeakerOccurrence`；
- 同一人物跨四类入口的全局 Person 一致率，以及不同人物被错误跨入口合并的比例；
- 等价证据经不同入口路由后，人物关系、置信分层和人工纠错结果的语义一致性；
- 默认口述插入必须保持无说话人标签、只发生一次且不等待全局匹配，同时历史最终保留完整说话人片段和人物关系。

### 5.1 推荐内存机器真实运行时合成冒烟

固定版本的 FluidAudio 0.15.5、Argmax OSS/SpeakerKit 1.0.0 与 sherpa-onnx 1.13.2 已在 Apple M4 Pro / 48 GB 机器上，对独立的九样本说话人 manifest 完成断网真实推理。语料覆盖四类入口、口述 1/2/3 人、快速短轮次、重叠/背景声、跨入口/跨会话同人与未知人；另以 6 个 enrollment 和 16 个 query 对四类入口执行 enrollment-only 保守阈值验证。音频、RTTM、逐条 identity manifest 和 embedding 均留在本机外部存储，Git 只保存不可逆 manifest 摘要和聚合结果。

自动估计说话人数的主结果如下；oracle 人数仅用于诊断，不参与候选选择。

| 候选 | DER | JER | 已知人正确/总数 | 已知错认 | 未知拒绝/总数 | P95 | RTF | 峰值 RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Fluid | 0.3493 | 0.4080 | 6/12 | 0 | 4/4 | 340 ms | 0.0142 | 177,504,256 B |
| Argmax | 0.3769 | 0.4269 | 6/12 | 0 | 4/4 | 290 ms | 0.0128 | 147,881,984 B |
| sherpa | 0.2573 | 0.3222 | 9/12 | 0 | 4/4 | 6890 ms | 0.2244 | 283,344,896 B |

三者在这组保守阈值 smoke 中均为零已知错合、零错误拆分并拒绝全部陌生人；代价是 Fluid/Argmax 各拒绝 6 个已知 query，sherpa 拒绝 3 个。sherpa 在该合成集上 DER/JER 和已知人覆盖较好，但延迟与资源明显更高。该样本是合成 TTS，不是 16 GB、授权真人、device-lab、private-consented 或 release-holdout 数据；Argmax 模型许可、sherpa embedding/ONNX Runtime notice、Fluid attribution 包装复核也未放行，所以不得选默认模型或把这些数值写成发布阈值。完整引用见 `artifacts/evidence/SPIKE-SPK-001/recommended-memory-synthetic-smoke-summary.json`。

### 5.2 公开真人 AMI 调优与独立留出

固定 FluidAudio 0.15.5 与 `fluid-speaker-diarization-coreml` revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594` 后，使用 CC BY 4.0 的 AMI Meeting Corpus 1.6.2 公开真人会议完成了两阶段断网评估。`ES2004a` 只用于注册与阈值调优；阈值 `0.5489600933809491` 仅由注册样本的最大冒名相似度加 `0.03` 安全边际得到。通过调优门槛后才读取独立留出：`ES2004c` 检验同一批人物的跨会话匹配，`ES2005a` 检验未注册人物拒绝。调优进程由 macOS sandbox 禁止读取留出根，留出进程禁止读取调优根，两者都禁止网络。

| 分区 | DER | JER | miss | false alarm | confusion | 已知正确/总数 | 已知错认 | 未知拒绝/总数 | RTF | 峰值 RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tuning / ES2004a | 0.3371 | 0.3806 | 0.3032 | 0.0116 | 0.0223 | 14/16 | 0 | 0/0 | 0.0061 | 519,012,352 B |
| release holdout / ES2004c + ES2005a | 0.2493 | 0.3178 | 0.1987 | 0.0299 | 0.0207 | 15/16 | 0 | 16/16 | 0.0056 | 711,704,576 B |

留出分区通过既定门槛：四种统一人物入口语义均有 query、已知人物零错认、零错误合并、正确覆盖率不低于预设下限、未知人物全部拒绝、speaker confusion 不高于 5%、RTF 不高于 1 且峰值 RSS 不高于 2 GiB。四种入口在本次模型评估中由 headset、array、mix 三类真实信号路由，证明的是同一嵌入空间和判定语义，不代替口述、线下录音、电脑内录、导入媒体各自的已安装 App 集成验收。该结果来自 48 GB M4 Pro；16 GB 最低设备和真实产品入口矩阵仍是发布硬门槛。聚合证据位于 `artifacts/evidence/SPIKE-SPK-001/fluid-ami-*.json`，原始音频、RTTM、逐条诊断、冻结声纹和模型文件均留在外置本地存储。

## 6. 本地 LLM 指标

- 事实敏感 token 保真：数字、否定、日期、金额、姓名、所有者；
- 润色语义蕴含/矛盾人工或规则复核；
- 摘要/决策/待办引用 precision、无引用断言率、结构化 schema 成功率；
- 首 token、tokens/s、峰值内存、长文本分块一致性；
- 相同输入/配置的可重复性与失败恢复；
- 拒绝把不确定内容写成确定事实。

任何事实保真硬门槛失败，即使文本“更好看”也不能成为默认模型。

本地文本 contract fixtures 分别覆盖 rewrite、structured summary、action item、低置信谨慎措辞、未知引用拒绝、runtime failure 和同输入重算。contract 通过只证明双输出、lineage 与失败关闭语义；模型事实保真排序必须继续经过 `SPIKE-LLM-001` 的危险 token hard-fail suite。

`SPIKE-LLM-001` 对数字、日期、否定、人名和行动责任人逐类执行零容忍 gate。类别错误分别计数，任一类别超过硬上限即令候选 `hardGateEligible = false`；style preference 只作为旁路指标记录，不能进入抵消公式。提交的 planted fixture 刻意让事实错误候选获得更高 style score，并要求它仍被拒绝，同时事实保留候选继续可用且 source fixture byte lineage 不变。

## 7. 软件系统指标

### 捕获

- 指定 App 的泄漏/漏捕、helper 加入延迟、来源列表更新、设备切换 gap、2 小时积压。

### 持久性

- 随机 kill 后损失块数、恢复时间、孤立块修复、磁盘满安全停止、迁移成功率。
- 原始音频 export digest/格式保持；完整归档吞吐、峰值额外空间、跨用户恢复、无明文 staging、错误口令/篡改/截断/空间不足的原子拒绝。

### 插入

- 成功率、重复插入、错误目标、密码框违规、剪贴板破坏、用户输入冲突。

### 搜索/历史

- 规模 fixture 下首屏 P50/P95、索引重建、人物关系更新后可见延迟。

### 资源降级

- `SPIKE-RES-001` 用相同 controller contract 注入 memory warning/critical、thermal serious/critical、backlog full 与组合压力，要求决策顺序始终为 capture/journal > live ASR > final ASR > speaker/local text。
- warning 可节流 live ASR，critical 或 backlog 满可持久化延后推理，重模型可卸载；任何压力都不得停止 AudioJournal 提交。恢复为 normal 后必须产生可观察的 `recovered` transition 并恢复 deferred work。
- probe 在每个决策前后提交音频块并重新打开 journal；attempted、committed、recovered readable 数必须相等且 gap 为 0。确定性注入只验证策略与持久性，真实峰值 RSS、swap、CPU/GPU/ANE 和 thermal 表现仍由 16 GB/推荐内存硬件矩阵验证。

### 隐私

- 断网完整功能；网络 allowlist；抓包中零用户内容；日志/诊断/临时文件扫描；删除后资产与索引一致。

## 8. 硬件矩阵

- 参考：M4 Pro / 48 GB（PRD 性能目标）。
- 最低候选：Apple Silicon / 16 GB。
- 8 GB 仅作发现性测试，不属于 V1 发布支持矩阵，也不能改变 16 GB 最低配置。
- 至少一个较旧芯片档与一个当前芯片档；外接 USB、蓝牙和内置麦克风。

## 9. 报告与回归

- 每次 run 写 JSON + Markdown 摘要：Git commit、OS/Xcode、硬件、模型 artifact digest、参数、corpus version、指标和失败样本 UUID。
- 报告不含私人音频/文本；失败样本通过本机 UUID 定位。
- 模型、prompt、阈值、重采样、分块或 SDK 版本变化都视为可回归变更。
- 候选或实现状态变更必须链接本次证据文件；没有机器结果的“已优化”不算完成。

### 9.1 Release holdout 隔离

调参 payload root 与 release-holdout payload root 必须是两个互不包含的真实目录。`IsolatedCorpusStore` 在读取任何 manifest 字节前解析 symlink 并检查授权 root；tuning/smoke mode 不持有 release 读取权限，同时在解码后再次拒绝 `releaseHoldout=true` 或 `tier=release-holdout`。Release evaluation 使用单独 mode，只接受 release root 中同时带两项 holdout 标记的 manifest。任何候选选择都必须引用独立 release run，不能复用 tuning result。
