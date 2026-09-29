# bestASR 产品重构调研与验收对齐（内部来源报告）

> 调研日期：2026-08-29
> 状态：产品与技术调研基线；2026-08-29 已用正式安装包复核核心口述、原音播放和恢复交互，并同步当前分阶段 ASR 实测结论
> 目的：把既有完整需求重新组织为用户价值、参考产品、技术选择与可验收交付，避免再把代码存在、测试脚手架或页面数量当成产品完成度

## 1. 执行结论

bestASR 不是“本地转写器”，也不是“Typeless 的离线复制品”。它的第一性原理定义是：

> **把用户从任意来源听到或说出的语音，可靠地保存为可回放的事实证据，再转成可搜索、可纠错、按人物和事件组织、可继续使用的本地长期记忆。**

完整价值链只有一条：

`所有语音来源 → 不丢原音 → 实时/最终识别 → 人物与事件记忆 → 搜索/回放/整理 → 输入、导出或行动`

当前工程已经实现了很多协议、数据结构、页面和局部链路，但用户的核心体验没有达到可用标准。正确状态不是“功能基本完成、只剩验收”，而是：

- 工程能力覆盖较广；
- 安装包可以运行，部分真实链路通过；
- 但核心任务仍然割裂、信息架构过于工程化、关键交互密度过高；
- 模型结论仍主要是 alpha 候选，不是完整产品质量选型；
- 因此目前属于**功能型集成候选**，不是可日常使用的产品。

后续必须同时重做产品结构、交互、模型选型与真实验收，不能继续在旧界面上堆按钮。

## 2. 调研范围与边界

本轮调研覆盖：

- 全局口述、线下麦克风、指定 App/全 Mac 音频、媒体导入；
- 首次启动、权限、全局快捷键、菜单栏和悬浮状态；
- 实时/句末/最终 ASR、强制对齐、词典和本地润色；
- 会话说话人、跨记录人物、声纹纠错；
- 历史、播放、逐字稿编辑、来源证据、搜索；
- 跨记录事件、摘要、章节、结论和待办；
- 模型管理、存储、恢复、隐私、导出和发行。

约束保持不变：

- 模型安装后，核心链路完全本地；
- 原音、逐字稿、词典、人物声纹、事件和 App/窗口来源元数据不上传；
- 原音是事实证据，默认保留，任何重算和整理不得覆盖来源；
- 声纹只用于本地人物归类，不用于认证；
- V1 不增加账号、云同步、iPhone、Windows 或云端转写；
- 本轮只使用公开、通用信息进行外部调研，没有把任何用户音频、逐字稿、人物数据或内部私密内容发送给外部服务。

## 3. 第一性原理需求

### 3.1 获取：所有语音都能成为输入

用户只需要表达“现在要记录什么”，不需要理解底层捕获方式。

1. 口述：在任意 App、任意焦点状态下用系统级快捷键开始和结束，结果准确插入原目标一次。
2. 线下录音：选择麦克风、看见真实电平、长时间记录、暂停/继续、实时文字、结束后重算。
3. 电脑内录：选择一个真实 App 或整个 Mac，可选麦克风分轨；明确边界，不能暗中录到其他 App。
4. 文件导入：拖放或选择音视频，排队、进度、暂停/恢复、失败恢复，进入与现场录音相同的处理链。

### 3.2 保存：录音优先于推理

- 捕获开始后立即增量落盘；
- ASR、LLM、说话人模型慢、缺失或崩溃时仍保留可恢复原音；
- 暂停只形成时间轴间隔，不结束会话；
- 结束封存并触发最终处理；取消只删除用户明确放弃的当前临时会话；
- 休眠、设备切换、来源退出、磁盘压力和 App 崩溃都必须给出可理解状态与恢复入口。

### 3.3 理解：实时可见，最终可信

- 流式草稿服务于“正在发生什么”；
- 句末重算服务于“这一句最终是什么”；
- 会后重算服务于长上下文、时间戳、去重、分段和说话人一致性；
- 润色只生成派生版本，数字、日期、金额、人名、否定和责任人不允许被改写；
- 原始识别、当前修订和整理结果同时可见、可追溯、可恢复。

### 3.4 记忆：知道是谁、属于什么事

- 四种入口共用 `SessionSpeaker → SpeakerOccurrence → Person`；
- 未知人物也是稳定人物，可搜索、命名、合并、拆分、确认“不是同一人”和撤销；
- 同一人物按近场、远场、会议压缩和导入来源保留多个特征中心；
- 事件不是文件夹，而是根据语义、时间、人物和来源提出的跨记录组织建议；
- 自动人物合并和事件归类都以保守、可审查、可撤销为原则；
- 人物与事件始终能跳回具体记录、具体时间和原音。

### 3.5 找回与使用：不是把文字塞进列表

- 一个统一资料库覆盖口述、录音、电脑内录和导入；
- 支持精确词、自然语言、日期、来源、人物、事件和状态组合搜索；
- 记录详情以播放器和逐字稿为核心：播放时高亮当前句，点击句子跳转音频；
- 可以内联纠正文字和说话人，纠正形成新修订并改善词典/人物记忆；
- 摘要、章节、结论、待办都带来源引用；
- 支持复制、重新识别、重新整理、原音/文字/字幕导出和加密迁移。

## 4. 每个模块参考谁，以及只参考什么

| 模块 | 最佳参考 | 要吸收的部分 | 不照搬的部分 |
|---|---|---|---|
| 全局口述 | Typeless、Wispr Flow、Superwhisper | 一次快捷键、非抢焦点悬浮条、按住说话/免手持、即时状态、历史重试、词典和按 App 行为 | 它们的云端处理或弱来源证据 |
| 本地一体化 | talat | 会议、口述、导入使用同一管线；实时草稿+句末高质量 pass；双轨、播放、说话人和本地整理 | 其产品边界和商业策略；不能以厂商自报质量代替实测 |
| 会议过程 | Granola | 无机器人录制、低干扰状态、实时稿、暂停/恢复、原始笔记引导、整理结果可回看来源 | 云端处理、账号与协作依赖，以及桌面端仅按音轨区分“我/对方”而没有完整多人分段 |
| 原音证据与找回 | Apple Voice Memos | 录音中/录音后逐字稿、暂停/继续、标题与逐字稿搜索、选择命中文字即定位播放头 | 仅按单条录音管理，缺少跨来源人物和事件记忆 |
| 转写编辑与播放 | Descript | 文字与媒体时间轴绑定、内联纠错、说话人修正、词级跳转、非破坏式修订 | 复杂音视频剪辑器范围 |
| 文件与专业转写 | MacWhisper | 拖放导入、格式覆盖、批处理、字幕、成熟播放/导出 | 把技术模型和复杂选项直接推给普通用户 |
| 人物 | Apple Photos 的 People & Pets | 自动聚类、命名、代表样本、合并、确认更多、明确“不是此人” | 把声纹当作可靠身份认证 |
| 跨记录记忆 | Granola、早期 Rewind 的产品思想 | 从过去记录找开放事项、按人/时间/主题找回、从来源生成工作材料 | 云端邮箱/日历抓取和无边界生活监控 |
| 导出与说话人 | Plaud | 在逐字稿内命名、全局应用标签、导出时选择时间戳和说话人 | 云端同步和不可逆标签行为 |
| macOS 形态 | Apple HIG | 原生菜单、独立设置窗口、可隐藏侧栏、键盘优先、清晰反馈、错误可恢复 | 自绘大面板、调试状态和无层级按钮墙 |

关键结论：竞品是“模块参考库”，没有任何一个产品应被整套临摹。

## 5. 目标信息架构和交互

### 5.1 两种产品形态

1. **菜单栏 + 非激活悬浮条**：负责随时开始、暂停、结束、取消和显示状态；不抢键盘焦点。
2. **主窗口**：负责记录、回放、纠错、搜索、人物、事件和设置，不承担“必须打开才能口述”的责任。

### 5.2 主窗口

- **今天**：唯一主按钮“开始记录”，可展开四种来源；显示正在处理、需要恢复、最近记录和待确认人物/事件。统计数字降为次要信息。
- **资料库**：统一搜索和记录列表。筛选是可见的轻量 chips，不是首先铺开的大表单。
- **记录详情**：顶部固定播放器；中央为与音频同步的逐字稿；右侧检查器显示人物、事件、来源和整理。高级重算、导出、版本历史放入工具栏或更多菜单。
- **人物**：图库式集合。进入人物后首先看到代表片段、最近出现、相关事件和记录；纠错操作就地完成。
- **事件**：时间线/集合视图。优先呈现“最近发生、仍在推进、待确认归类”，而不是空白 CRUD 表单。
- **词典与设置**：词典可作为资料库的一种管理面；设置保持标准 macOS 独立窗口，按通用、快捷键、录音、模型、存储与隐私分区。

### 5.3 四条必须顺滑的用户旅程

1. **口述**：按快捷键 → 悬浮条监听 → 再按结束 → 显示处理中 → 只向原目标插入一次 → 悬浮条消失 → 历史可重放/重试。
2. **录音**：选择来源和确认电平 → 开始 → 实时稿/人物状态 → 暂停/继续 → 结束 → 自动进入记录详情并显示最终处理进度。
3. **导入**：拖入文件 → 立即出现在任务队列 → 显示真实进度和剩余阶段 → 完成后直接打开同一种记录详情。
4. **找回**：输入一句话、人物或事件 → 得到带命中片段的结果 → 点击即从对应时间播放 → 查看或修正来源，再复制/导出/生成行动项。

## 6. 底层技术和模型重新选型

### 6.1 捕获

- 麦克风使用 Apple 音频捕获能力；
- 指定进程优先使用 macOS 14.2 的 Core Audio Process Tap；
- 需要系统集成选择器或显示/窗口范围时使用 ScreenCaptureKit；
- 系统音频和麦克风保持独立轨道；
- App 选择器按面向用户的 App 聚合 helper 进程，并明确 Chrome 的边界是整个 App、不是单标签页；
- 捕获状态永远有清晰可见指示，来源失败时保留已录数据。

### 6.2 ASR 必须分层，不再让一个模型承担所有阶段

候选横评而非预设赢家：

| 阶段 | 候选方向 | 决策重点 |
|---|---|---|
| 实时草稿 | Paraformer streaming（通过可分发的 sherpa-onnx/原生适配）、Qwen3-ASR streaming、现有 SenseVoice 分块基线 | 首字延迟、修订抖动、长时间连续性、中英混输 |
| 句末/最终 | SenseVoice、Paraformer、Qwen3-ASR 0.6B/1.7B、Cohere Transcribe、Whisper large-v3-turbo | 中文 CER、英文 WER、混输 MER、实体/数字/否定、远场、噪声、RTF |
| 强制对齐 | Qwen3 ForcedAligner、Whisper/其他时间戳方案 | 字词时间戳稳定性和原生可分发性 |

截至 2026-08-29，产品候选已经从“一个 SenseVoice 包打天下”改成自动分阶段路由：SenseVoice 只负责低延迟草稿、语言证据和真正中英混输；明确普通话终稿交给固定 Paraformer int8；明确英语终稿交给固定 Parakeet Unified int8。公开 FLEURS 真人调优集上，SenseVoice 组合 profile 明确失败；Paraformer 普通话 profile 在修复 FP32 CPU/GPU 前处理后以 9.17% CER 通过（旧 CPU-only 路径为 14.96%），Parakeet 英语 profile 以 7.80% WER 通过，危险 token 错误均为 0。这个结论只冻结当前终稿候选，不等于发布资格，也不替代独立 holdout、混输、流式抖动、强制对齐、远场和会议语料。

普通用户不选择模型或语言。产品只显示“自动、本地、已准备”；模型 ID、路由证据和回退原因只进入高级诊断。Whisper、Qwen3-ASR、Cohere Transcribe 和真正流式的 Paraformer/Parakeet EOU 继续作为同语料挑战者，只有实机胜出才允许替换当前阶段。

统一横评必须使用同一批真实本地语料，覆盖近场口述、远场会议、系统会议压缩、导入媒体、中英文句内切换、专名、数字、否定、自我纠正和长静音；同时记录 CER/WER/MER、实体错误、首字/句末延迟、RTF、峰值内存、功耗、失败率和分发许可。

### 6.3 说话人与人物

- 实时阶段只显示暂定 A/B/C 和低置信状态；
- 会后离线分段/聚类才决定稳定会话说话人；
- 当前 FluidAudio 是可用候选，不因已接入就自动成为最终质量赢家；
- 横评 FluidAudio、可原生化的 pyannote 方案、WeSpeaker/3D-Speaker 嵌入候选；
- 使用 DER/JER、碎片率、跨入口命中率、陌生人拒绝率和错误合并率；
- 自动人物合并以零/极低误合并为先，低置信保持未知。

### 6.4 本地文本、搜索和事件

- 润色、摘要、章节、结论、待办使用结构化输出并逐条引用来源 segment；
- 继续评估 Qwen 1.7B/4B 等本地模型，但事实门失败即退回原文/确定性标点；
- 搜索采用 SQLite FTS5 的精确/前缀/BM25 与本地语义向量混合检索；
- 当前事件相似度实现使用 Apple `NLEmbedding.sentenceEmbedding`，不可用时退回确定性词法重叠。Apple 明确把该 API 定位于句子相似度和文本检索，但这仍不足以证明中英文跨记录事件质量；
- `multilingual-e5-small` 与 `Qwen3-Embedding-0.6B` 只作为下一轮本地挑战者。前者更小、支持 100 种语言，后者支持更长上下文、检索/聚类和可变维度；两者都必须先在 bestASR 的双语人物/事件语料上胜过 `NLEmbedding + lexical`，不能因模型卡排名直接进入产品；
- 事件聚类结合语义、时间、人物和来源，只产生建议，不直接重写用户组织；
- 可选把用户允许的内容写入 Core Spotlight 的本机私有索引，但它不是资料库的唯一索引，也不得泄露声纹或敏感内容。

## 7. P0/P1 验收合同

### P0：先把产品变成真正可用的完整闭环

1. **产品壳与首次启动**：安装后只有一个 App 身份；权限状态与系统一致；模型下载有真实进度、暂停/重试和错误解释；完成一个安全的真实口述练习后进入主界面。
2. **全局口述**：快捷键不依赖窗口或输入框焦点；悬浮条不抢焦点；开始/结束/暂停/取消可预测；在 TextEdit、Chrome、Codex、VS Code、Word 等真实目标只插入一次；失败保留历史且不写错窗口。
3. **线下录音**：设备、电平、开始、实时稿、暂定说话人、暂停、继续、结束、最终稿和播放全部在同一连续流程中可用。
4. **电脑内录**：App/全 Mac 选择、helper 聚合、可选麦克风分轨、实时状态、暂停/继续、来源退出和最终播放可用，且不录入未选 App。
5. **文件导入**：拖放、格式识别、队列、真实进度、暂停/继续、失败恢复、最终播放和统一处理可用。
6. **资料库和记录详情**：统一搜索；记录列表清楚；原音可播放；播放/逐字稿双向跳转；内联文字和说话人纠正；原始/当前修订不覆盖；复制、重算和删除无卡死。
7. **人物记忆**：四入口统一人物；未知人物可见；命名、改名、合并、拆分、不是同一人、撤销和删声纹不删历史全部可用。
8. **事件记忆**：建议、人工建立、移入/移出、合并、拆分、撤销、人物/记录互跳和来源引用可用。
9. **整理与使用**：摘要、章节、结论、待办可编辑、可重算、可回源；词典真实影响后续识别；文字、字幕和原音导出完整。
10. **可信赖性**：全链断网运行；无默认遥测；录音中崩溃/休眠/模型失败不丢已录内容；明确录音指示；所有错误给出下一步而不是调试术语。
11. **整体交互**：正常用户完成上述任务时不需要理解模型、数据库、revision、job、Bundle ID 或工程状态；无按钮墙、无深层表单、无卡死、无重复测试窗口。

P0 不是“各页面各有按钮”，而是上述旅程用正式安装包连续完成。

### P1：P0 之后完成全部既有明确要求

1. 按住说话、每 App 清理/格式策略和更多安全快捷键组合；
2. 更丰富导入格式、批量任务、自动/批量导出和词典 CSV/JSON；
3. 加密 `.bestasrarchive` 全量迁移、模型回滚、存储管理和细粒度保留策略；
4. 更完整的会议来源元数据适配，但不把它当作人物姓名真相；
5. 无障碍、键盘导航、Reduced Motion/VoiceOver 和窗口恢复；
6. 最后再做最低 16 GB 设备、两小时热状态、磁盘压力和全故障矩阵；
7. Developer ID 签名、公证、staple、Gatekeeper 和拖拽安装 DMG。

不在 V1：云同步、账号、iPhone、Windows、云端转写、浏览器单标签页精确隔离，以及未明确要求的团队协作系统。

## 8. 当前真实差距

### 已经存在且应保留

- 原生 macOS 工程、稳定安装身份和外置构建缓存；
- 增量 AudioJournal、会话/修订/人物/事件/作业等领域模型；
- 系统级快捷键、部分跨 App 插入、麦克风录音、Process Tap、导入和历史链路；
- 原音保留、回放基础、原始/最终修订、词典、人物和事件基础操作；
- SenseVoice + 本地 Qwen 的 alpha 路径、FluidAudio 说话人候选；
- 多项局部回归与真实安装包探针。

2026-08-29 的正式安装包基线进一步确认：在外部 fixture 始终保持前台的情况下，全局开始/结束与暂停/继续都不依赖 bestASR 或输入框聚焦；英语暂停段没有被采集，最终文本只插入一次；资料库保留原音可真实播放并推进时间；历史复制不再冻结；两段合成验收记录和取消中的临时记录均通过产品 UI 删除，用户原有记录未被改动。该基线证明这些窄链路当前可运行，但不把完整产品标记为完成。

### 不能再视为完成

- 首页仍把权限卡、模型卡、状态、按钮、来源、统计和最近记录堆在一个长页面里；
- 历史详情同时暴露播放器、修订、重算、词典、四种整理、导出、人物、来源、时间线等大量控件，缺少明确主任务；
- 人物和事件更接近数据库管理页，尚未形成自然的长期记忆浏览体验；
- 流式/最终识别和人物模型的“已接入”不等于已经选到最佳产品组合；
- 状态账本中的 `[x]` 多数表示实现存在或局部证据存在，不代表用户已经接受完整交互；
- 完整正式 UI 自动化仍受宿主机 Automation Mode 阻塞；现场会议、最低设备和发行仍未完成；
- 用户已明确报告过崩溃、权限误判、快捷键、复制卡死和播放问题，因此这些链路必须从真实安装包重新作为一个整体验收，不能引用旧测试结论跳过。
- 当前真实冷启动仍不可接受：这次首次普通话终稿完成约需 64 秒，随后的英语热运行约 16 秒。公开回放到物理麦克风不能作为准确率证据，但足以暴露专用终稿模型直到“结束”才冷加载的问题；模型预热必须与录音并行，且永远不能阻塞原音落盘。

## 9. 实施顺序

1. 冻结本对齐合同，并同步重写 PRD 的信息架构/体验验收、技术设计的模型横评方案和状态账本的“实现存在/产品可用”口径。
2. 重构产品壳、首次启动、权限、菜单栏、悬浮条和四种输入入口。
3. 打通四种输入到同一个实时记录工作区和同一个资料库详情。
4. 重做播放、逐字稿、修订、说话人纠错、搜索和来源跳转。
5. 把人物与事件从管理表单重做成可浏览、可纠错、可回源的记忆体验。
6. 在统一真实语料上完成 ASR、强制对齐、说话人、人物和本地文本/embedding 横评，并接入获胜组合。
7. 完成整理、词典、导出、存储、恢复和完全离线边界。
8. 所有 P0/P1 实现结束后，用一个正式安装包执行最小但完整的端到端验收；失败只修受影响链路并重跑该链路。
9. 最后处理 16 GB、两小时、完整故障矩阵和签名公证发行。

任何阶段都不得再以 fixture、数据库表、协议、页面出现或单元测试数量宣布产品完成。

## 10. 限制与待验证事项

- 公开竞品资料只能证明产品宣称和交互结构，不能替代统一实机横评；
- 厂商公布的 WER/CER/DER/速度不能跨语料直接比较；
- Qwen3-ASR、Cohere Transcribe、Paraformer、Whisper、FluidAudio、WeSpeaker/3D-Speaker 等候选必须在 Apple Silicon 的可分发原生路径上验证；
- 部分产品为云端实现，本文只借用其交互范式，不改变 bestASR 的本地隐私边界；
- Rewind 仅作为早期“可搜索个人记忆”概念参考，不作为当前产品或商业状态依据；
- 本报告确认后，正式需求编号仍以 PRD 为准，不能在同步更新时丢失或重编号。

## 11. 来源账本

### 口述与本地产品

- [Typeless：Dictate](https://www.typeless.com/help/quickstart/dictate)
- [Typeless：History and Dictionary](https://www.typeless.com/help/quickstart/history-and-dictionary)
- [Typeless：Data Controls](https://www.typeless.com/data-controls)
- [Wispr Flow：What is Flow](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)
- [Wispr Flow：Context Awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness)
- [Wispr Flow：Desktop navigation and Flow Bar](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)
- [Superwhisper：Voice models](https://superwhisper.com/docs/models/voice)
- [Superwhisper：Changelog](https://superwhisper.com/changelog)
- [talat：Capabilities](https://talat.app/capabilities)
- [talat：Dictation](https://talat.app/docs/dictation)
- [talat：Transcription settings](https://talat.app/docs/settings/transcription)
- [MacWhisper](https://www.macwhisper.com/)

### 会议、编辑、人物与记忆

- [Granola：Transcription](https://docs.granola.ai/help-center/taking-notes/transcription)
- [Granola：AI enhanced notes and source links](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Granola：Pre-meeting briefs](https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs)
- [Granola：People and Companies](https://docs.granola.ai/help-center/people-and-companies)
- [Granola：Chatting with your meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings)
- [Apple Voice Memos：查看、搜索并从逐字稿定位原音](https://support.apple.com/guide/voice-memos/view-a-transcription-of-a-recording-vm4a03609f0d/mac)
- [Descript：Edit like a doc](https://help.descript.com/hc/en-us/articles/10164808475149-Inline-notes)
- [Descript：Correct your transcript](https://help.descript.com/hc/en-us/articles/23054692507661-Unable-to-toggle-capitalization-or-punctuation-on-Windows)
- [Plaud：Export files](https://support.plaud.ai/hc/en-us/articles/50835453223705-Export-files)
- [Plaud：Auto speaker labeling](https://support.plaud.ai/hc/en-us/articles/54027338385177-Auto-speaker-labeling)
- [Apple Photos：People & Pets](https://support.apple.com/en-ie/guide/photos/-phtad9d981ab/mac)
- [Apple Photos：Search](https://support.apple.com/en-gb/guide/photos/pht64de33e5a/mac)
- [Rewind launch concept](https://proxy.rewind.ai/blog/launching-rewind)
- [Limitless privacy](https://www.limitless.ai/privacy)

### macOS 平台与交互

- [Apple：Core Audio Process Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple：ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)
- [Apple：Accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple HIG：Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple HIG：Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [Apple HIG：Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy/)
- [Apple HIG：Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Apple HIG：Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 模型、评测和搜索

- [OpenAI Whisper](https://github.com/openai/whisper)
- [FunAudioLLM SenseVoice](https://github.com/FunAudioLLM/SenseVoice)
- [FunASR Paraformer streaming](https://huggingface.co/funasr/paraformer-zh-streaming)
- [sherpa-onnx Swift package](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift)
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)
- [Cohere Transcribe model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [FluidAudio：模型与实时/离线职责](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)
- [FluidAudio diarization guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
- [pyannote.metrics](https://github.com/pyannote/pyannote-metrics)
- [WeSpeaker](https://github.com/wenet-e2e/wespeaker)
- [3D-Speaker](https://github.com/modelscope/3D-Speaker)
- [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- [multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)
- [Apple Natural Language：NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)
- [Apple Natural Language：句子相似度与文本检索](https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [SQLite FTS5](https://sqlite.org/fts5.html)
- [Apple Core Spotlight](https://developer.apple.com/documentation/CoreSpotlight)

## 12. 结论—来源核对账本

| 决策性结论 | 公开依据 | 本地依据 | 仍未证明的部分 |
|---|---|---|---|
| 全局口述必须是一键开始/结束、非抢焦点、失败可从历史恢复 | Typeless Dictate、Settings、History；VoiceInk README | 正式安装包外部前台 fixture 的开始/暂停/继续/结束/取消/单次插入基线 | 更广泛的富文本和受保护输入兼容矩阵 |
| 原音播放器与可定位逐字稿是记录详情的事实核心 | Apple Voice Memos；Descript 非破坏编辑 | 正式安装包 36 秒保留原音实际播放并推进到 25 秒 | 波形/逐字稿双向同步的所有格式和长文件 |
| 人物必须是跨记录、可确认/拒绝/合并/撤销的长期对象 | Apple Photos People & Pets；Pixel Recorder 的说话人修正范式 | PRD 的统一 `SessionSpeaker → SpeakerOccurrence → Person` 与现有本地人物库 | 真实跨近场/远场/会议压缩的陌生人拒绝率和误合并率 |
| 事件必须是可回源、可撤销的跨记录语义组织，而不是文件夹或自动摘要 | Granola 的 People/Company 范围与跨会议查询；Apple Photos 语义/人物检索 | 现有 `EventCandidate`、来源引用和本地操作图 | 双语真实语料上的聚类精度、时间/人物/来源权重和长期漂移 |
| ASR 应按实时、终稿、混输职责自动路由，不把模型暴露给普通用户 | FluidAudio 模型职责；Typeless 的无模型选择交互 | 固定 FLEURS 调优证据：Paraformer 中文通过、Parakeet 英文通过、SenseVoice 组合失败 | 独立 release holdout、真实混输、流式 churn、对齐与会议远场 |
| 语义检索先使用系统本地能力，外部 embedding 只有实测胜出才替换 | Apple NLEmbedding；E5 与 Qwen3 Embedding 模型卡 | 当前 `LocalEventOrganizer` 的 NLEmbedding + lexical fail-closed | 同一双语事件语料上的准确率、延迟、内存和磁盘横评 |

调研先按任务范式检索一线产品和 Apple/模型官方资料，再以“跨记录人物、事件、证据回放、离线模型职责”做缺口检索。第二轮没有发现能够整体照搬且同时满足四种输入、原音保留、全局声纹人物、语义事件和完全本地边界的现成产品；新增资料只继续强化上述组合式设计，因此在结论不再发生实质变化时停止扩散搜索。公开资料只支持交互范式和候选能力，任何模型质量结论仍以仓库的固定本地语料为准。
