# bestASR 竞品调研与竞争分析报告

> 文档版本：V1.3
> 首次调研：2026-07-21；增补核验：2026-07-22  
> 对应需求：[PRODUCT_REQUIREMENTS.md](./PRODUCT_REQUIREMENTS.md) 当前 V1.3（已冻结四入口统一人物语义、口述优先 MVP/V1 架构边界、未来同步、16 GB、永久音频与加密迁移边界）
> 状态：新版需求差异调研已补充；竞品实机横评待执行  
> 工作名称：bestASR

V1.3 对齐最新产品基线：口述、线下会议、系统音频与导入媒体都必须支持一人或多人内容，并等价进入同一全局人物体系；口述默认向外部目标插入纯文字，但应用内仍保留全部说话人证据。MVP 口述优先而核心架构按完整 V1 建立。V1 不交付在线同步，但人物与历史的数据结构需支持未来迁移及 iPhone↔Mac 同账号同步。本次只同步产品比较口径，没有新增竞品外部事实；公开证据日期仍以 2026-07-22 为准。

## 1. 执行摘要

### 1.1 结论

市场上已经存在多款做出来、可以下载或使用的同类产品。bestASR 不是在开辟一个没有竞品的空白市场，而是进入一个已经被验证、且在 2026 年快速拥挤的“本地语音工作台”市场。

按当前公开能力，结论如下：

- **Talat 仍是最接近 bestASR 完整产品形态的直接竞品**：它已经把全局口述、麦克风会议、系统音频、文件导入、本地说话人、跨会议声纹、人物页、本地总结、历史搜索和时间戳回放放进同一个产品；但其“恢复已结束会议”和“导入不能暂停”不符合新版 PRD 对暂停、结束和继续的严格区分。
- **MacWhisper 是成熟度和功能广度最强的 macOS 基准**：文件转写、App 音频、会议、口述、说话人、历史与字幕导出都较成熟，但整体更像专业转写工具，模型和配置也更显性。
- **Muesli 是最值得研究的开源技术对照**：它与本项目一样面向 Apple Silicon/macOS 14.2+，采用原生 Swift，并公开使用 Core Audio Process Tap；v0.8.0 已支持录音暂停/继续，但全模式控制一致性、线下多人说话人、全局人物库和本地会议整理仍有明显缺口。
- **OpenWhispr 是功能面很宽的开源直接竞品**：已有双音轨会议、说话人、跨会议声纹、口述和本地模型，但 Electron 跨平台形态、云端产品层以及“会议实时转写是否完全离线”的官方资料不一致，使它没有完全满足 bestASR 的边界。
- **Superwhisper 是口述体验的强基准，而不是完整等价物**：口述、模式化润色、本地模型和中文支持较强，但离线实时会议、说话人整合和精确 App 内录不是其公开能力重点。
- **Dictara 是跨模式声纹最值得关注的早期竞品**：Voice ID 明确同时从用户口述和会议中的同事声音学习，加上无账号、模型随包和按秒落盘恢复，与新版 PRD 高度重叠；但当前只公开支持 6 种欧洲语言，且未证明精确系统音频捕获和完整人物治理界面。
- **Synopsule 是新增的“本地人物库”专项直接竞品**：它在 macOS/iPhone 上提供跨录音说话人目录、本地声纹、全局改名、人物搜索和“合并或忘记声音”；它不覆盖全局口述，但必须成为新版 PRD 人物页和全局身份体验的对照。
- **OpenTranscribe 与 Loreo 应分别作为技术实现和云端体验标杆**：前者已公开全局说话人档案、回溯匹配、置信建议与合并 UI，后者提供可复用人物档案、跨会议搜索与会话记忆；二者都不满足 bestASR 的原生、完全本地、零配置整体边界。

截至调研日，**没有一家竞品通过公开资料同时证明已经满足 bestASR 的全部 P0 硬要求**。最主要的未被完整证明的组合是：

1. 中文、英文和中英文句内混输的可量化高质量；
2. 真正按 App 隔离的 Core Audio 捕获，包括 helper 进程归组、录制中新 PID 自动加入和设备切换稳定性；
3. “流式草稿 → 句末重算 → 会后全局重算”的完整三阶段 ASR；
4. 口述、线下录音、电脑内录和导入处理使用同一套暂停/继续语义，并严格区分暂停、结束和取消；
5. 口述、线下会议、系统音频和导入媒体都采用等价的多人分段/最终聚类语义，并具有可量化的 DER/JER 和身份碎片率；
6. 同一次多人口述及其他来源的说话人进入同一稳定全局人物身份，并具有置信分层、多个场景特征中心和回溯匹配；
7. 人物命名、合并、拆分、撤销，以及“仅删除声纹”与“删除历史内容”分离的完整治理闭环；
8. 无账号、无额外依赖、普通用户不选技术模型，同时离线完成转写、润色、摘要、结论、待办和章节；
9. 增量落盘、崩溃恢复、可检索历史、音频定位、重新处理和完整字幕导出的统一闭环。

因此，项目仍有成立空间，但差异化不能停留在“本地”“隐私”或“支持口述和会议”。这些已经逐渐成为品类基础能力。bestASR 应把竞争位置收敛为：

> **面向中文与中英文混输，在 macOS 上提供可靠单 App 内录、长会议说话人一致性、统一录制控制和可纠错全局人物记忆的零配置本地语音工作台。**

### 1.2 对产品决策的直接回答

| 问题 | 判断 |
|---|---|
| 有没有已经做出来的竞品？ | 有，至少 6 款与核心范围明显重叠，另有多款人物库、口述和音频捕获专项竞品。 |
| 是否已有一款公开证明完全覆盖新版 PRD？ | 尚未发现。Talat 整体最接近，但没有一家同时证明全模式暂停语义和跨四类输入的全局人物治理。 |
| 是否需要因为竞品存在而改变方向？ | 不需要取消方向，但必须从“功能集合”转向“可测量质量与可靠性”。 |
| 最大竞争风险是什么？ | Talat 等产品已经非常接近一体化形态；本地 ASR 和说话人能力也在开源商品化。 |
| 最大机会是什么？ | 中文混输、稳定单 App 隔离、长会一致性、全模式可恢复控制和跨模式人物记忆仍缺少公开证明充分的一体化产品。 |
| 当前调研是否充分？ | 公开资料层面已足以更新定位和工程优先级；质量、误合并率、暂停数据边界和真实可用性仍必须实机横评。 |

## 2. 调研范围与证据口径

### 2.1 范围

本报告以 bestASR V1.0 PRD 的 P0/P1 能力为基线，覆盖：

- 全局口述输入；
- 线下麦克风会议；
- 指定 App/整个 Mac 的系统音频捕获；
- 音视频文件导入；
- 口述、录音和导入任务的暂停、继续、结束与取消语义；
- 实时与最终 ASR；
- 四类入口的一人/多人说话人分段、跨模式全局身份和长期本地声纹；
- 人物目录、稳定未知身份、回溯匹配、命名、合并、拆分、撤销和删除边界；
- 本地润色与会议整理；
- 历史、搜索、回放、恢复和导出；
- 安装、账号、隐私、平台与价格。

核心竞品为 Talat、MacWhisper、Muesli、OpenWhispr 和 Superwhisper；补充评估 Dictara 与 Synopsule。VoiceInk、SaidVault 与 AudioPiper 用于专项能力比较；OpenTranscribe 用作全局人物系统的开源技术对照，Loreo 用作云端人物档案与会话记忆的体验对照。云端会议机器人和云端口述产品不纳入整体能力评分。

### 2.2 资料来源

优先使用竞品官方网站、官方文档、官方更新日志、官方 GitHub 仓库和官方价格页。原报告资料核验于 2026-07-21；统一控制和全局人物系统相关资料增补核验于 2026-07-22。版本、价格和产品状态之后可能变化。

本轮没有安装所有付费竞品，也没有在统一硬件和音频集上完成实机测试。因此：

- 本报告可以判断“公开宣称或记录了什么”；
- 不能仅凭宣传材料判断真实 CER/WER、延迟、DER、稳定性或中文混输质量；
- “未找到公开证据”不等于产品一定没有该功能；
- 凡涉及宣传性数字，均视为厂商自报，不能替代独立验证。

### 2.3 能力标记

| 标记 | 含义 |
|---|---|
| ✅ | 官方公开资料明确确认，且大体符合该项定义。 |
| ◐ | 部分支持、需要额外配置、范围较窄，或证据存在条件/冲突。 |
| ? | 未找到足以确认或否定的公开证据。 |
| ❌ | 官方资料明确显示当前不支持，或实现与该项硬边界直接冲突。 |

能力矩阵比较的是公开可验证程度，不是最终产品质量排名。

## 3. bestASR 的竞争基线

PRD 不是普通的本地转写工具需求，而是把下列能力强制组合在一起：

1. Apple Silicon、macOS 14.2+、可安装、签名公证、无 Python/Homebrew/虚拟声卡；
2. 无产品账号，模型就绪后默认完全断网可用；
3. 口述、线下会议、电脑内录和音视频导入四类输入缺一不可；
4. 指定 App 或整个 Mac 的系统音频，且 App 隔离需要处理 helper 归组和 PID 变化；
5. 麦克风和远端系统音频分轨；
6. 流式草稿、句末重算、会后全局重算三阶段识别；
7. 普通话、英语与同一句中英文自然切换；
8. 口述、线下录音、电脑内录和导入处理统一支持暂停/继续，且暂停、结束、取消具有不同数据语义；
9. 本地实时说话人、会后全局聚类，以及覆盖四类输入的长期全局人物身份；
10. 稳定未知人物、置信分层、多场景声纹中心、历史回溯匹配和不阻塞实时输入的后台关联；
11. 人物命名、合并、拆分、撤销、搜索，以及声纹与历史内容分离删除；
12. 本地润色、摘要、章节、结论和待办，且结果可追溯原文时间戳；
13. 增量落盘、崩溃恢复、全文搜索、音频回放、时间戳跳转、重新处理和 TXT/MD/SRT/VTT 导出；
14. 技术模型由产品自动选择，不把模型理解成本转嫁给普通用户；
15. 默认无内容上传、无产品遥测。

竞争判断的关键不是某个竞品是否有其中一项，而是是否把这些硬边界以可用、稳定、低摩擦的方式同时实现。

## 4. 市场地图

### 4.1 直接竞品

| 产品 | 当前公开状态 | 平台/形态 | 本地与账号边界 | 调研日公开价格 | 与 bestASR 的重叠度 |
|---|---|---|---|---|---|
| [Talat](https://talat.app/) | [v1.3.0，2026-07-20](https://talat.app/changelog) | macOS 15+ Apple Silicon、Windows 10+ | 核心转写与内置整理可在设备上运行；可不注册开始使用 | 10 小时免费；$9/月、$89/年、$189 买断 | **最高**：四类输入、说话人、声纹、历史和本地整理都已出现 |
| [MacWhisper](https://www.macwhisper.com/) | [销售页显示 14.2](https://goodsnooze.gumroad.com/l/macwhisper) | macOS 14+；M 系列推荐 | 本地 ASR 和本地数据；云端 AI 为可选 | 免费版；Pro €64 买断并含终身更新 | **很高**：成熟转写、会议、App Audio、口述、说话人与完整导出 |
| [Muesli](https://github.com/Muesli-HQ/muesli) | [v0.8.0，2026-07-15](https://github.com/Muesli-HQ/muesli/releases) | 原生 Swift；macOS 14.2+ Apple Silicon | MIT 开源；本地 ASR；总结可选 Ollama 或云端 | 免费开源 | **很高/技术型**：平台、Process Tap、口述和会议链路高度接近 |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) | v1.7.6，2026-07-18；Electron 开源桌面端 | macOS、Windows、Linux | 本地处理为默认之一；同时经营云端与账号方案 | 本地免费；Pro 约 $6.67/月（年付）；Business 约 $16.67/月 | **很高**：口述、会议、双通道、说话人和跨会议声纹 |
| [Superwhisper](https://superwhisper.com/) | 持续更新的商业产品 | macOS、Windows、iOS | macOS 可用本地语音与本地语言模型；部分实时能力依赖云端 | $8.49/月、$84.99/年、$249.99 买断 | **中高**：强口述与会议模式，但会议和 App 隔离闭环较弱 |
| [Dictara](https://dictara.ai/) | Early Access | Apple Silicon，macOS 12+；模型随 2.4 GB 安装包提供 | 无账号、默认离线；可选让用户自己的外部 AI 读取本地日记 | 早期访问免费；计划约 €149/台买断 | **中高/早期**：口述、会议、说话人、声纹、日记和恢复高度重叠 |
| [Synopsule](https://synopsule.com/) | 已公开销售 | macOS 15+ Apple Silicon、iPhone | 无账号；转写、说话人分段和声纹在设备上处理；默认存在可关闭的产品分析 | 官网当前显示 $1.99 一次性购买 | **专项很高**：跨录音人物目录、声纹、全局搜索和改名；不覆盖全局口述 |

### 4.2 邻近竞品与替代方案

| 类别 | 产品 | 对本项目的意义 |
|---|---|---|
| 本地口述 | [VoiceInk](https://tryvoiceink.com/) | 证明“本地、开源、全局快捷键、App 级规则、词典”的口述产品可以以低至 $25 买断销售；它是口述摩擦和价格的直接基准。 |
| 本地转写库 | [SaidVault](https://saidvault.com/) | 文件、URL、语音笔记、剪贴板口述、系统音频、历史搜索、手工说话人和 TXT/MD/PDF/SRT/VTT 已形成低价产品；自动说话人和会议智能则明确缺失。 |
| 专项音频工具 | [AudioPiper](https://modelpiper.com/audiopiper) | 使用 macOS 14.2+ Core Audio Taps 做逐 App、多源捕获，说明技术路径可行；但它不是完整转写和知识管理产品。 |
| 全局人物技术对照 | [OpenTranscribe](https://github.com/attevon-llc/OpenTranscribe) | 自托管 Web/Docker 产品，已有跨全部转写的说话人档案、声纹、置信建议、历史回溯匹配、合并 UI、人物搜索和录音暂停/继续；不符合原生 Mac 与零依赖边界。 |
| 云端人物体验对照 | [Loreo](https://getloreo.com/) | 可复用 speaker profiles、改名/合并、跨会议人物搜索、系统音频与文件上传以及 conversation memory，可作为人物页和长期会话记忆的 UX 基准；云端处理与账号边界不符合 PRD。 |
| 云端体验基准 | Typeless、Granola、Otter、Fireflies 等 | 用于比较口述低摩擦、会议笔记呈现和协作体验；由于账号、云处理或机器人路径不符合 PRD 默认离线边界，本报告不把它们列为直接等价竞品。 |
| 观察名单 | [Hyprnote/Char](https://github.com/fastrepl/hyprnote) | 本地优先会议笔记方向与本项目相邻，但品牌和文档处于迁移状态，当前不纳入能力评分，发布前应重新核验。 |

## 5. 核心能力矩阵

### 5.1 输入、捕获、识别与部署

| bestASR 关键要求 | Talat | MacWhisper | Muesli | OpenWhispr | Superwhisper | Dictara |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| 任意 App 全局口述、自动落入目标文本区 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 线下麦克风录音/会议 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 系统音频/线上会议捕获 | ✅ | ✅ | ✅ | ✅ | ✅ | ? |
| 精确单 App 隔离 + helper 归组 + 新 PID 自动加入 | ? | ◐ | ◐ | ? | ? | ? |
| 麦克风与系统输出独立通道/音轨 | ✅ | ◐ | ✅ | ✅ | ◐ | ? |
| 完全断网的会议实时文字 | ✅ | ◐ | ✅ | ◐ | ❌ | ? |
| 句末使用完整句音频高质量重算 | ✅ | ? | ? | ? | ? | ? |
| 会后完整音频的全局 ASR 重算 | ? | ? | ? | ? | ? | ? |
| 中文、英文和句内中英文混输 | ◐ | ◐ | ◐ | ◐ | ◐ | ❌ |
| 默认自动选模型，不要求普通用户理解模型名 | ✅ | ◐ | ❌ | ◐ | ◐ | ✅ |
| 无账号即可使用全部本地核心能力 | ✅ | ✅ | ✅ | ◐ | ◐ | ✅ |
| 覆盖 macOS 14.2 | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |

说明：

- MacWhisper 已公开“App Audio”能力，但没有找到 helper 进程归组、录制中新 PID 加入和本项目来源选择器行为的完整证据，因此精确 App 隔离只记为部分支持。
- Muesli 已确认使用 Core Audio Process Tap，技术基础高度相关，但公开资料仍不足以确认 PRD 要求的完整 App 聚合与异常恢复 UX。
- Talat 可以按指定会议 App 限制自动检测/启动录制，也能选择系统音频输出设备；但公开文档没有证明它只捕获所选 App 的音频输出，因此没有把“按 App 自动录制”误当作“按 App 音频隔离”。
- OpenWhispr 的仓库/更新资料出现本地实时预览描述，但当前会议指南又把集成实时会议转写写为云端流式服务，因此“完全断网实时会议”只能记为部分支持。
- Superwhisper 官方文档明确指出 Realtime 当前使用 Nova 云端模型，因此不满足“断网实时会议文字”。本地模型仍可用于非实时处理。
- 除 Dictara 明确只列出 EN/DE/FR/IT/ES/PL 外，其余产品大多证明了“多语言”或“支持中文”，但没有发布统一的中英文句内混输实测数据，因此都不能记为完全满足 bestASR 质量目标。

### 5.2 暂停、继续、结束与取消

新版 PRD 要求的不只是“有暂停按钮”，而是四类输入共享同一套状态模型：暂停不采集音频、不结束会话；继续沿用会话、来源和人物状态；结束触发最终处理且不能恢复；取消不等于删除历史源文件。公开资料核验结果如下：

| bestASR 控制要求 | Talat | Muesli | OpenWhispr | MacWhisper | Superwhisper | Synopsule | OpenTranscribe |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 录音可暂停并继续同一会话 | ◐ | ✅ | ◐ | ? | ? | ? | ✅ |
| 全局口述可暂停/继续而非只能结束或取消 | ? | ? | ? | ? | ? | ❌ | ❌ |
| 导入处理可暂停/继续 | ❌ | ? | ? | ? | ? | ? | ? |
| 四类输入使用统一控制模型 | ❌ | ? | ? | ? | ? | ❌ | ❌ |
| 暂停与结束严格分离，结束后不能恢复 | ❌ | ? | ? | ? | ? | ? | ? |
| 暂停期间不采集并保留明确时间轴区间 | ? | ? | ? | ? | ? | ? | ? |
| 继续后保留音源、说话人状态和全局人物映射 | ? | ? | ? | ? | ? | ? | ? |

说明：

- Talat 的[更新日志](https://talat.app/changelog)支持“恢复此前已结束的会议并继续录音”，因此有恢复能力，但与 bestASR“结束不可恢复”的数据语义冲突；其[文件导入说明](https://talat.app/blog/how-to-transcribe-an-audio-file)明确写明导入不能暂停/继续。
- Muesli [v0.8.0 发布说明](https://github.com/Muesli-HQ/muesli/releases)明确包含暂停/继续录音和继续既有会议，是最清楚的原生 Mac 对照；尚未证明口述、会议和导入共用同一状态机。
- OpenWhispr 的更新资料出现 stop/resume 以及跨恢复保留逐条设置，但尚未发现暂停区间、结束封存和全局人物状态的完整公开定义。
- MacWhisper、Superwhisper 与 Synopsule 的公开文档主要描述开始/停止，未找到足以确认新版 PRD 控制语义的资料。“?”不代表一定没有，必须在实机横评中操作确认。
- OpenTranscribe 支持浏览器麦克风录音暂停/继续，但它没有全局口述、原生系统音频和四模式统一控制，因此只作为具体交互与数据实现对照。

### 5.3 跨模式全局人物、声纹与治理

旧版“是否有跨会议 Voice ID”已经不足以区分新版需求。真正的比较对象是：人物是否跨输入模式长期存在、未知人物是否稳定、系统是否允许回溯重算，以及用户能否安全修复误合并。

| bestASR 全局人物要求 | Talat | MacWhisper | OpenWhispr | Dictara | Synopsule | Loreo | OpenTranscribe |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 跨记录复用说话人/声纹档案 | ✅ | ? | ✅ | ✅ | ✅ | ✅ | ✅ |
| 全局口述也参与人物识别 | ? | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |
| 同一次口述内多人分段并进入全局人物 | ? | ❌ | ? | ? | ❌ | ❌ | ❌ |
| 会议、系统音频和导入共享人物 | ◐ | ? | ◐ | ? | ◐ | ✅ | ✅ |
| 稳定未知人物目录与人物搜索 | ✅ | ? | ◐ | ? | ✅ | ◐ | ✅ |
| 高/中/低置信或人工确认分层 | ? | ? | ◐ | ? | ◐ | ? | ✅ |
| 同一人物保存多个设备/通道/场景中心 | ? | ? | ? | ? | ? | ? | ? |
| 新证据触发历史回溯匹配 | ✅ | ? | ✅ | ? | ? | ? | ✅ |
| 一次改名传播到相关历史 | ✅ | ◐ | ◐ | ✅ | ✅ | ✅ | ✅ |
| 全局人物合并与拆分 | ✅ | ◐ | ? | ? | ◐ | ◐ | ◐ |
| 合并、拆分和命名可撤销 | ? | ? | ? | ? | ? | ? | ? |
| 可分离删除声纹特征与历史音频/记录 | ? | ? | ? | ? | ? | ? | ? |
| 全局身份核心链路可完全本地运行 | ✅ | ◐ | ✅ | ✅ | ✅ | ❌ | ✅ |
| 默认无产品遥测 | ◐ | ? | ? | ? | ❌ | ? | ? |

说明：

- Talat 的 People 页面支持跨会议人物、扫描既有会议、合并和拆分；合并还会携带 voice references。它在会议人物治理上最完整，但未公开证明同次口述中的一人或多人、导入文件和会议共用一个人物身份空间，也没有找到撤销与分离删除语义。
- [MacWhisper 说话人文档](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper)明确表示 Dictation 不支持说话人识别，并假定口述只有一人；逐字稿内改名/合并不能等同于全局声纹人物库。
- [OpenWhispr 本地说话人说明](https://openwhispr.com/blog/local-speaker-diarization)提供本地 centroid 与跨会议匹配，也有新 profile 回溯映射既有笔记的能力；麦克风来源默认标为“you”不足以满足 bestASR V1.3，因为它没有证明同一次口述中的多名说话人会被分段并进入与其他来源相同的全局人物库。
- [Dictara](https://dictara.ai/)明确表示 Voice ID 从用户口述学习本人，并在同事被命名后跨会议识别，是现有公开资料中最接近“口述也进入全局人物系统”的产品。
- [Synopsule](https://synopsule.com/)提供跨录音 speakers directory、全局改名、`speaker:` 搜索、声纹严格度调整以及合并或忘记声音；但没有系统级口述、拆分/撤销、多中心声纹和历史回溯重算的公开证据。其[隐私政策](https://synopsule.com/privacy/)说明产品分析默认启用、用户可退出，因此不满足“默认无遥测”。
- [Loreo](https://getloreo.com/)的可复用 speaker profiles、人物合并、跨会议搜索和 conversation memory 是体验标杆，但其账号和云处理边界不能作为本地实现等价证据。
- [OpenTranscribe](https://github.com/attevon-llc/OpenTranscribe)已经公开全局说话人档案、置信建议、回溯匹配、人物合并和按人物筛选，是最接近新版数据模型的技术参照；但它是自托管 Web/Docker 产品，未公开人物拆分、撤销和分离删除。
- Muesli 与 Superwhisper 未列入本表，是因为截至本轮核验没有找到长期全局人物实体的充分公开证据，而不是断言产品永远不会提供该能力。

### 5.4 说话人、会议智能、历史与可靠性

| bestASR 关键要求 | Talat | MacWhisper | Muesli | OpenWhispr | Superwhisper | Dictara |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| 本地自动说话人分段 | ✅ | ◐ | ◐ | ✅ | ◐ | ✅ |
| 实时显示说话人标签 | ✅ | ❌ | ◐ | ✅ | ◐ | ? |
| 线下共享麦克风多人分段 | ✅ | ✅ | ? | ◐ | ◐ | ✅ |
| 会后全局修正身份漂移 | ✅ | ◐ | ◐ | ✅ | ◐ | ◐ |
| 跨会议本地声纹/Voice ID | ✅ | ? | ? | ✅ | ? | ✅ |
| 手动重命名并统一应用 | ✅ | ✅ | ◐ | ✅ | ◐ | ✅ |
| 内置或可配置的本地文本润色 | ✅ | ◐ | ◐ | ◐ | ✅ | ❌ |
| 本地摘要、结论、待办、章节并回链时间戳 | ✅ | ◐ | ◐ | ◐ | ◐ | ❌ |
| 历史全文搜索 + 音频回放 + 时间戳跳转 | ✅ | ✅ | ◐ | ✅ | ◐ | ◐ |
| 录音增量落盘和崩溃恢复有明确证据 | ◐ | ? | ? | ? | ? | ✅ |
| 音视频文件导入 | ✅ | ✅ | ◐ | ✅ | ✅ | ? |
| TXT/MD/SRT/VTT 等 P0 导出 | ◐ | ✅ | ◐ | ◐ | ◐ | ? |
| 本地词典/术语/替换 | ✅ | ◐ | ✅ | ✅ | ✅ | ✅ |

说明：

- MacWhisper 的自动说话人识别是在录制/转写完成后运行；当前公开文档没有证明实时说话人标签和跨会议声纹匹配。
- Muesli 当前公开重点是对远端/系统音频做说话人分段，未找到共享房间麦克风多人分段的明确证明。
- Talat 的本地会议智能最接近 PRD，但其文档也提示内置 Qwen3.5-4B 对约 30 分钟以上会议采取更保守的总结策略。
- Dictara 明确宣称音频每秒落盘并能在崩溃、休眠或断电后恢复，是当前公开资料中对这一点描述最清晰的竞品；其“Insights”需要用户自己的 Claude/Codex 等外部工具，不能算作产品内置、默认离线的本地会议整理。

## 6. 核心竞品详析

### 6.1 Talat：最接近完整愿景的直接竞品

**定位与状态**

Talat 主打本地、无会议机器人、会议与口述合一。官方[能力页](https://talat.app/capabilities)和[更新日志](https://talat.app/changelog)显示，v1.3.0 已覆盖 macOS 与 Windows；macOS 要求 15+ 和 Apple Silicon。当前[价格页/首页](https://talat.app/)显示 10 小时免费，以及 $9/月、$89/年、$189 买断。

**已确认优势**

- 同一个 App 内包含会议、口述和文件导入；
- 麦克风与系统声音分通道记录，实时转写，并在短语结束后运行更高质量识别；
- 全局快捷键支持切换/按住说话、自动粘贴、`Esc` 取消和按 App 的整理策略；
- 麦克风与系统音频均有本地说话人分段，结束后聚类；
- 支持跨会议声纹和结合日历参会者做姓名映射；People 页面可扫描既有会议、合并和拆分人物；
- 可恢复此前已结束的会议并继续录音，说明底层具备跨录制段延续会话的能力；
- 原始与整理后的口述历史可搜索；会议支持时间戳播放、恢复、保留策略；
- 本地生成摘要、章节和行动项，并保留时间引用；
- 内置 Qwen3.5-4B 作为默认本地整理模型，也允许云端或 Ollama 作为可选项；
- 文件导入覆盖 WAV、MP3、M4A、MP4、FLAC、OGG、AAC，官方文章还列出 MOV/MKV。

**相对 bestASR 的缺口或未证实点**

- macOS 15+ 不覆盖本项目要求的 macOS 14.2；
- 未找到“选定单个 App 并严格排除其他 App”以及 helper 归组、新 PID 自动加入的明确公开证明；
- 公开的是短语结束后的高质量 pass，没有明确说明会后对完整音频执行全局 ASR 重解码；
- 文件导入目前不能暂停/继续，取消会丢弃该次未完成结果；录音的“恢复已结束会议”也不符合 bestASR“暂停可继续、结束不可恢复”的严格状态语义；
- 未公开证明同一次口述中的一名或多名说话人会进入与会议、导入相同的全局人物库；
- 虽有人物合并、拆分和跨历史改名，仍未找到人物操作撤销、多个场景声纹中心，以及“仅删声纹/同时删历史内容”分离控制的证据；
- 公开导出重点为 Markdown、PDF 和 webhook，未证明 SRT/VTT/JSON；
- 没有中文与中英文混输的公开基准；
- 内置小型模型对长会议总结质量有官方承认的边界；
- [隐私政策](https://talat.app/privacy)说明没有第三方分析、行为跟踪或会议内容上传，但 App 仍会在启动、周期运行和若干关键事件发送小型诊断 ping；这不等同于 PRD 的严格“默认无产品遥测”。

**竞争判断**

Talat 已使“离线 + 口述 + 会议 + 声纹 + 本地整理”本身不再构成独特卖点。bestASR 必须在中文质量、真正的 App 隔离、长会全局重算、崩溃恢复和完整历史/导出上形成可测量优势。

主要资料：[首页](https://talat.app/) · [Capabilities](https://talat.app/capabilities) · [Changelog](https://talat.app/changelog) · [首次启动](https://talat.app/docs/getting-started/first-launch) · [Transcription 设置](https://talat.app/docs/settings/transcription) · [Summaries 设置](https://talat.app/docs/settings/summaries) · [文件导入说明](https://talat.app/blog/how-to-transcribe-an-audio-file) · [隐私政策](https://talat.app/privacy) · [FAQ](https://talat.app/faq)

### 6.2 MacWhisper：成熟度与专业转写能力基准

**定位与状态**

MacWhisper 是 macOS 专用本地转写产品。官方[主页](https://www.macwhisper.com/)当前提供免费版与 €64 Pro 买断；[销售页](https://goodsnooze.gumroad.com/l/macwhisper)显示版本 14.2、支持 macOS 14+，并自报约 50 万份销量，说明其成熟度和用户规模明显高于多数新竞品。

**已确认优势**

- 支持本地 Whisper/WhisperKit/Parakeet 等模型和大量语言；
- 支持文件导入、麦克风录音、会议录制和从任意 App 捕获音频；
- 全局口述可写入任意文本框，并有[按 App 提示词](https://docs.macwhisper.com/article/31-app-specific-dictation-prompts)；
- 自动说话人识别可在完成后运行，支持逐字稿内重命名、合并；
- 本地保存数据，提供跨逐字稿/说话人的搜索、同步音频播放和时间定位；
- 导出格式非常完整，包括 TXT、Markdown、SRT、VTT、PDF、HTML、DOCX 等；
- 可通过 Ollama 或 LM Studio 使用本地 LLM，也可选择云端提供商；
- [查找替换](https://docs.macwhisper.com/article/37-find-and-replace-in-transcriptions)可用于术语标准化。

**相对 bestASR 的缺口或未证实点**

- 产品显著暴露模型选择和高级技术配置，不符合 bestASR“普通用户不理解模型名”的强原则；
- 当前[会议文档](https://docs.macwhisper.com/article/30-record-meetings)仍把自动会议录制标为 beta，并提示少数情况下可能丢失数据；
- 说话人识别以会后处理为主，没有证明实时 A/B/C、在线聚类和跨会议声纹；
- 官方说话人文档明确表示 Dictation 不支持说话人识别并假定只有一名说话者，因此不能把口述纳入跨模式人物记忆；
- 没有证明稳定未知人物目录、跨逐字稿声纹档案、回溯匹配和全局人物治理；
- 本地 AI 需要另装和配置 Ollama/LM Studio，不是随产品零配置提供的默认组件；
- 未找到流式草稿、句末重算、会后全局 ASR 重算三阶段闭环的明确证明；
- App Audio 已存在，但 helper 进程归组、录制中新进程与输出设备切换的稳定性仍需实测；
- 支持中文不等于已经证明句内中英文混输质量。

**竞争判断**

MacWhisper 是文件导入、编辑、搜索、播放和导出的最低成熟度基准。bestASR 即使在 ASR 或会议上更强，如果历史详情、编辑器和导出明显更弱，也会被用户视为不完整。

主要资料：[主页](https://www.macwhisper.com/) · [当前销售页](https://goodsnooze.gumroad.com/l/macwhisper) · [14.0 更新](https://goodsnooze.gumroad.com/p/macwhisper-14-0-new-editor-improved-performance-and-what-s-next) · [会议录制](https://docs.macwhisper.com/article/30-record-meetings) · [自动说话人](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper) · [口述](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature) · [隐私](https://docs.macwhisper.com/article/52-keeping-transcriptions-private) · [本地文件位置](https://docs.macwhisper.com/article/54-file-locations)

### 6.3 Muesli：最有价值的开源技术参照

**定位与状态**

Muesli 是 MIT 许可的原生 Swift/AppKit/SwiftUI 项目，明确要求 Apple Silicon 和 macOS 14.2+。官方仓库和[发布页](https://github.com/Muesli-HQ/muesli/releases)显示 v0.8.0 已提供签名、公证、staple 的 DMG。

**已确认优势**

- 全局按住说话和免手持口述，结束后自动粘贴；
- 麦克风与系统音频分别捕获；
- 默认使用 Core Audio Process Tap，ScreenCaptureKit 作为回退；
- 可选本地实时字幕，结束后使用所选会议模型处理；
- v0.8.0 已加入录音暂停/继续和继续既有会议；
- 使用 FluidAudio/pyannote CoreML 对远端系统音频做本地说话人分段；
- 支持 M4A、MP4、WAV、MP3 文件导入；
- 有历史、词典、模型管理和 SQLite 存储；
- v0.8 已加入本地文本清理模型；会议总结可使用 Ollama，也可选择 OpenAI/OpenRouter/ChatGPT；
- [会议笔记页](https://muesli.works/meeting-notes)展示了总结与行动项，并可导出 PDF/Markdown。

**相对 bestASR 的缺口或未证实点**

- 没有明确证明共享房间麦克风的多人分段；公开重点是远端/系统音频；
- 未证明跨会议声纹、全局姓名空间或长会议 DER/JER 目标；
- 未证明口述、会议、文件导入共用同一套暂停/继续状态，也未说明结束与暂停的数据边界；
- 虽采用 Process Tap，但未证明 bestASR 规定的“正在使用音频”选择器、App/bundle/helper 聚合和新 PID 自动加入；
- 用户仍需从 Parakeet、Whisper、Qwen 等技术模型中选择，违反零配置原则；
- 会议总结的完全本地路径通常要求用户另装 Ollama；
- 文件类型和导出格式少于 PRD，未证明 SRT/VTT/JSON；
- 未发布中文混输、长期内存稳定性和崩溃恢复证据；
- v0.8 发布说明提到 error telemetry 仍可用，但没有在该说明中交代默认状态和字段范围，严格“默认无产品遥测”需要抓包与设置核验。

**竞争判断**

Muesli 证明本项目核心技术路径不是空想，也会降低后来者的实现门槛。它适合作为技术实现、权限、Process Tap 和本地模型集成的研究对象，但不能替代 bestASR 自己的质量与可靠性验证。

主要资料：[GitHub 仓库](https://github.com/Muesli-HQ/muesli) · [Releases](https://github.com/Muesli-HQ/muesli/releases) · [Meeting Notes](https://muesli.works/meeting-notes)

### 6.4 OpenWhispr：跨平台开源的一体化竞品

**定位与状态**

OpenWhispr 是 MIT 开源 Electron 桌面应用，覆盖 macOS、Windows 和 Linux。官方仓库截至调研日显示 v1.7.6；产品同时提供免费本地方案以及 Pro/Business 云端方案。

**已确认优势**

- 全局口述自动粘贴、自定义词典、文件导入、笔记与历史搜索；
- 本地可使用 Whisper、Parakeet、Nemotron 等模型，也允许 BYOK/云端；
- 会议支持麦克风与系统音频双通道、自动会议检测和播放历史；
- 本地说话人分段、实时标签、会后改进；
- 支持跨会议 Voice Fingerprint、保存在本地 SQLite 的声音中心、日历参会者辅助，以及新档案对部分既有记录的回溯映射；
- 本地或云端 AI 可用于文本整理。

**相对 bestASR 的缺口或未证实点**

- Electron 跨平台形态不符合 bestASR 的原生 macOS 产品目标；
- [当前会议指南](https://docs.openwhispr.com/guides/meeting-transcription)把集成实时会议转写描述为 OpenAI Realtime、AssemblyAI 或 Deepgram 等云端流式服务，而仓库/更新资料又出现本地 live preview，离线完整性需要实机验证；
- 价格与团队功能强化账号和云端层，增加了隐私边界与产品复杂度；
- 未找到单 App 精确隔离、helper 归组和新 PID 加入的公开证明；
- 当前公开实现主要对系统音频做 diarization，麦克风通道默认标为“you”；尚未证明该口述身份会进入完整的全局人物库；
- 没有公开完整的人物目录、拆分/撤销、多场景声纹中心或声纹与历史内容分离删除语义；
- 没有明确三阶段 ASR 全局重算或中文混输基准；
- [价格页](https://openwhispr.com/pricing)把部分说话人功能放在较高方案中，开源自建与商业发行版的实际功能边界需分别核验。

**竞争判断**

OpenWhispr 说明“开源 + 本地模型 + 会议声纹”也不再稀缺。bestASR 应以原生低摩擦、边界清楚的完全离线默认值和 macOS 专项可靠性来拉开差距。

主要资料：[GitHub 仓库](https://github.com/OpenWhispr/openwhispr) · [Changelog](https://openwhispr.com/changelog) · [Meeting Guide](https://docs.openwhispr.com/guides/meeting-transcription) · [Local Speaker Diarization](https://openwhispr.com/blog/local-speaker-diarization) · [Pricing](https://openwhispr.com/pricing) · [Terms](https://openwhispr.com/terms)

### 6.5 Superwhisper：口述体验和模式化整理基准

**定位与状态**

Superwhisper 是成熟的商业口述产品，已扩展到会议、系统音频和文件。官方[价格文档](https://superwhisper.com/docs/get-started/sw-pro)列出 $8.49/月、$84.99/年和 $249.99 买断。

**已确认优势**

- 全局口述、可配置模式、词汇/替换、历史搜索和重新处理；
- macOS 支持本地 Whisper/Parakeet 和本地语言模型；
- 有专门的本地中文 Whisper 模型；
- 会议模式可记录系统音频与麦克风，也支持文件导入；
- 提供说话人分离会议工作流和 AI 总结。

**相对 bestASR 的缺口或未证实点**

- [Realtime 文档](https://superwhisper.com/docs/common-issues/realtime)明确写明实时能力当前只使用 Nova 云端模型，不满足断网实时；
- [Meeting Mode](https://superwhisper.com/docs/modes/meeting)默认不会把说话人完整分离，标签也不会自然进入 AI 摘要和行动项；
- [Speaker-separated Meetings](https://superwhisper.com/docs/modes/speaker-separated-meetings)属于较高级、多步骤工作流，不是 PRD 要求的一键默认闭环；
- 未找到精确单 App 系统音频隔离和 Process Tap 稳定性证据；
- 用户需要理解和配置 voice model、language model 与 mode；
- 中文模型存在，但没有公开的中英文句内混输或长会议说话人指标。

**竞争判断**

Superwhisper 是口述快捷键、浮层反馈、模式模板和目标 App 写入体验的重要人工对照。bestASR 需要达到类似低摩擦，同时把完全离线实时和会议闭环做得更完整。

主要资料：[Modes](https://superwhisper.com/docs/modes/modes) · [Meeting Mode](https://superwhisper.com/docs/modes/meeting) · [Realtime](https://superwhisper.com/docs/common-issues/realtime) · [History](https://superwhisper.com/docs/get-started/interface-history) · [Speaker-separated Meetings](https://superwhisper.com/docs/modes/speaker-separated-meetings) · [Voice Models](https://superwhisper.com/docs/models/voice) · [Sensitive Data](https://superwhisper.com/docs/security/sensitive-data) · [Pricing](https://superwhisper.com/docs/get-started/sw-pro)

### 6.6 Dictara：隐私、声纹和可靠性方向的早期威胁

**定位与状态**

Dictara 是 Apple Silicon/macOS 12+ 的早期访问产品。2.4 GB DMG 内含本地识别模型，无账号、无首次模型下载；目前免费，计划约 €149/台买断。

**已确认优势**

- 右 Option 键在任意 App 口述并直接写入当前光标；
- 超过一分钟的录音自动判断是否为会话并本地分离说话人；
- Voice ID 从用户口述学习本人声音，其他人命名一次后可跨会议识别；
- 专有词修正规则；
- 每日 Markdown 日记、日历、全文搜索和按 App 统计；
- 音频每秒写盘，明确宣称崩溃、断电、休眠后自动恢复；
- 模型随安装包提供，普通用户不需要选择模型。

**相对 bestASR 的缺口或未证实点**

- 只公开支持英语、德语、法语、意大利语、西班牙语和波兰语，明确不覆盖中文；
- 没有证明指定 App/整个系统的音频捕获、远端与麦克风分轨或 helper 进程隔离；
- 未证明实时逐字稿、句末重算与会后全局 ASR 重算；
- “Insights”依赖用户自己的 Claude Cowork 或 Codex，不属于 App 内置本地语言模型；调用外部 AI 时还需按对应服务的数据边界单独评估；
- 未证明音频回放时间跳转、字幕导出和完整会议结构化结果。

**竞争判断**

Dictara 当前语言范围限制明显，但它是本轮唯一明确把“用户口述中的本人声音”与“会议中的同事声音”纳入同一 Voice ID 叙述的原生 Mac 产品。其“模型随包、无账号、声纹、Markdown 数据所有权、按秒恢复”与本项目原则高度一致，应提升为全局人物能力的重点实机对象，而不只是早期观察名单。

主要资料：[官网与功能/价格](https://dictara.ai/) · [面向 ChatGPT 的使用说明](https://dictara.ai/voice-to-chatgpt)

### 6.7 Synopsule：本地人物目录与跨录音声纹基准

**定位与状态**

[Synopsule](https://synopsule.com/)是 macOS 15+ Apple Silicon 和 iPhone 上的本地录音转写产品。官网当前显示 $1.99 一次性购买，无需账号；语音识别、说话人分段和声纹均在设备上运行。

**已确认优势**

- 麦克风与系统音频使用独立音轨，适合在线会议和桌面内容记录；
- speakers directory 跨多条逐字稿维护人物，人物改名会传播到逐字稿、搜索和导出；
- 声纹可以识别再次出现的人物，用户纠正后会继续学习；
- 支持调节识别严格度，以及合并或忘记声音；
- 支持 `speaker:` 全局搜索、完整音频回放，以及 Word/PDF/Markdown/HTML/SRT/VTT 导出；
- 无账号且核心语音内容在本机处理，产品边界较容易理解。

**相对 bestASR 的缺口或未证实点**

- 没有把语音写入任意光标位置的全局口述模式，因此无法验证口述人物身份；
- 没有找到录音暂停/继续、四类输入统一控制或导入任务恢复的公开证据；
- 捕获的是麦克风和系统音频，未证明精确到单 App、helper 归组和新 PID 自动加入；
- 未证明人物拆分、操作撤销、多场景声纹中心、置信分层或新证据触发历史回溯匹配；
- [隐私政策](https://synopsule.com/privacy/)说明 Mixpanel 产品分析默认启用、用户可选择退出，不符合 bestASR 默认无产品遥测的边界；
- 官网说明原始捕获可在转写后删除，同时保留用于回放的副本；其存储对象和删除语义需要实机确认；
- 没有公开中文混输、长会议 DER/JER 或跨通道误合并率；未来跨设备同步还需另做校准。

**竞争判断**

Synopsule 不是 bestASR 的完整替代品，却是新版人物页最直接的低价产品基准。它证明“本地人物目录 + 跨录音声纹 + 全局人物搜索”已经可以作为普通消费级功能出售；bestASR 的人物系统必须在跨口述/会议/导入的一致性、误合并修复、撤销和隐私控制上明显更完整。

主要资料：[官网](https://synopsule.com/) · [隐私政策](https://synopsule.com/privacy/)

## 7. 邻近产品详析

### 7.1 VoiceInk

[VoiceInk](https://tryvoiceink.com/)是开源、本地优先的 macOS 口述产品，支持全局快捷键、按住说话、模式、App 级触发/提示、词典和替换，也可导入音视频。当前[价格](https://tryvoiceink.com/pricing)为 1 台 Mac $25、2 台 $39、3 台 $49 买断，要求 Apple Silicon 与 macOS 14.4+。

它没有公开证明线下会议、系统音频、自动说话人和会议智能，因此不是完整等价竞品；但它把“本地口述”的价格和体验门槛压得很低。bestASR 不能只靠口述模块支撑高溢价。

### 7.2 SaidVault

[SaidVault](https://saidvault.com/)面向本地专业转写，支持 MP3、MP4、M4A、WAV、MOV、WEBM、OGG、AVI、媒体 URL、语音笔记、剪贴板口述和系统音频。它提供搜索、点击时间戳播放、手工说话人、PDF/TXT/Markdown/SRT/VTT，并以 $29.99 一次性授权去除长度上限。

官方 FAQ 明确说明当前没有自动说话人分段，也没有内置 AI 会议整理。它不是一体化会议竞品，却是文件格式、编辑、证据元数据、字幕导出和低价本地隐私产品的基准。

### 7.3 AudioPiper

[AudioPiper](https://modelpiper.com/audiopiper)是多源音频混合与录制工具。官方资料明确使用 macOS 14.2+ 的 Core Audio Taps，可逐 App 选择音源，不需要虚拟驱动，并能把音频流送入实时转写管线。

它不是 ASR 工作台，但证明“逐 App Core Audio Tap”会被独立工具商品化。bestASR 的壁垒不能只是调用 Process Tap API，而应是活动音频发现、bundle/helper 聚合、录制中新进程跟随、设备切换、异常恢复和用户能理解的选择器。

### 7.4 Loreo

[Loreo](https://getloreo.com/)是云端会议记忆与逐字稿产品，支持系统音频和麦克风录制、文件上传、可复用 speaker profiles、人物改名/合并、跨会议搜索和 conversation memory。

它不满足 bestASR 的无账号、完全本地和原生 Mac 边界，因此不应进入整体能力排名；但其人物档案、跨会议搜索以及“人物—对话—长期记忆”的信息架构，适合作为人物详情页和历史关联体验的对照。实机设计研究应特别观察人物改名后如何传播、搜索如何表达人物参与关系，以及合并后的历史如何呈现。

### 7.5 OpenTranscribe

[OpenTranscribe](https://github.com/attevon-llc/OpenTranscribe)是自托管的 Web/Docker 转写系统，不是原生消费级 Mac App。它支持文件导入、浏览器麦克风录音暂停/继续、全局说话人档案、跨转写 voice fingerprints、置信建议、回溯说话人匹配、人物合并、人物筛选和分析。

它的价值不在于直接争夺同一用户，而在于证明新版 PRD 的主要数据关系已经有公开实现参照：全局 person ID、跨记录声纹、候选匹配、历史重算和合并 UI。其不足同样清楚：部署和模型依赖复杂，未覆盖系统级口述和精确单 App 捕获，也未公开人物拆分、撤销、多中心特征和声纹/历史内容分离删除。因此应把它当作技术与交互研究对象，而不是产品形态模板。

## 8. 尚未被竞品公开证明完整解决的市场空白

### 8.1 中文和中英文混输不是“支持中文”复选框

多个竞品依赖 Whisper 或其他多语言模型，因此可以列出中文；但调研未发现它们发布以下统一数据：

- 同一句中英自然切换的 CER/WER；
- 中文标点与断句；
- 人名、公司名、产品名、代码、缩写；
- 数字、金额、日期、否定词和邮箱；
- 口述自我纠正后的事实保真；
- 近场口述、远场会议和系统内录之间的质量差异。

如果 bestASR 能用固定测试集持续公开这些结果，这会比“使用某某模型”更有说服力。

### 8.2 真正可靠的单 App 内录仍缺少产品级证明

已有产品已经证明系统音频和 Process Tap 可用，但公开资料很少覆盖：

- 只录腾讯会议/Zoom，不录 Slack 通知；
- Chrome helper 归组，且清楚说明捕获的是整个 Chrome 而非单标签页；
- 录制中新 helper/PID 自动加入；
- 来源静音数分钟后保持等待；
- App 退出、重开、最小化或切换输出设备；
- 耳机、蓝牙和扬声器切换；
- 排除本 App 音效，避免回路；
- 来源失败时保留已录数据。

这里的差异化是可靠性和边界透明，不是底层 API 独占。

### 8.3 三阶段 ASR 仍是明确差异点

Talat 已明确有实时结果和短语结束后的高质量 pass；若 bestASR 只做这两层，差异很小。PRD 规定的会后完整音频全局重算应真正统一修正：

- 断句、时间戳和重复；
- 语言状态与专有名词；
- 说话人标签；
- 长距离上下文中的身份和术语；
- 流式、句末、最终稿之间的版本关系。

只有全局结果明显优于实时结果，且用户能回溯修改，三阶段设计才构成价值而非架构复杂度。

### 8.4 长会议说话人“一致”需要指标

声称有 diarization 的产品越来越多，Talat、OpenWhispr 和 Dictara 甚至已有跨会议 Voice ID。bestASR 的差异必须来自可验证表现：

- 2–4 人、60–120 分钟会议的 DER/JER；
- 同一人被拆成多个身份的碎片率；
- 一人沉默很久后再次发言的身份恢复；
- 线上远端混音与线下共享麦克风分别测量；
- 重叠发言和低置信回退；
- 真实姓名误映射率，而不是只报告覆盖率。

PRD 中“最终说话人混淆时间不高于有效语音 5%”是有价值的竞争标准，应保留并通过测试集落实。

### 8.5 跨模式全局人物仍没有完整等价物

Talat、OpenWhispr、Dictara、Synopsule、Loreo 和 OpenTranscribe 都已经证明跨记录人物档案或声纹不是遥远概念，但没有一家通过公开资料同时证明：

- 口述、线下录音、电脑内录和导入文件共用一个稳定 person ID；
- 同一次口述中的一名或多名说话人都能异步进入全局人物，而不阻塞默认纯文字写入；
- 同一人物拥有近场、远场、会议软件压缩等多个特征中心；
- 高、中、低置信采取不同自动化策略，并以误合并率优先；
- 新记录、人工确认、模型升级和人物拆分可触发历史回溯；
- 命名、合并、拆分可撤销，声纹删除与历史内容删除相互独立。

这构成新版 PRD 最清晰的功能空白，也构成最大的技术和隐私风险。V1.3 明确不再允许口述成为单人特例：1/2/3 人口述与其他入口必须使用相同人物语义，同时默认外部插入仍保持低摩擦纯文字。竞争焦点因此扩展为四入口人物质量、跨入口误合并控制，以及异步身份作业能否与低延迟插入安全解耦。

### 8.6 暂停不是按钮，而是数据状态

Muesli 和 OpenTranscribe 已证明录音暂停/继续并不稀缺，Talat 也能延续已经结束的会议。真正仍未被公开证明完整解决的是四类输入的统一语义：暂停时不采集、继续沿用同一来源与人物状态、结束后封存且不可恢复、取消不删除源文件，并在历史时间轴中保留墙钟时间与实际录音时间。

如果 bestASR 只是在不同页面各放一个行为不同的“暂停”按钮，这项 P0 不会形成优势。它只有在长会议不中断身份、导入任务可恢复、快捷键一致和异常恢复可预测时才具有产品价值。

### 8.7 零配置本地智能仍有空间

MacWhisper、Muesli 和 OpenWhispr 可以接 Ollama/LM Studio，但这与“安装后自动选择合适组件、普通用户不看模型名”不是同一体验。Talat 已在这一方向走得最远，Dictara 则把模型直接打包。

bestASR 的机会是：根据芯片、内存和磁盘自动安装、加载、降级、更新和回滚，同时始终把逐字稿与 AI 结果分开，并把结论/待办链接回原文时间戳。

### 8.8 可靠性是被低估的产品壁垒

Dictara 已把“每秒落盘和崩溃恢复”写成卖点，MacWhisper 的会议文档则仍提示 beta 数据丢失风险。长会议中，恢复、磁盘不足、安全停止、来源退出、休眠和旧历史兼容，比再增加一个摘要模板更能形成信任。

同样，不能从“本地转写”直接推导出“零网络、零遥测”。Talat 明确有不含会议内容的小型诊断 ping，Muesli 发布说明提到 error telemetry；其他竞品也需在实机横评中阻断网络并检查连接目标、触发时机和发送字段。

## 9. 竞争风险与应对

| 风险 | 级别 | 原因 | 建议应对 |
|---|---:|---|---|
| Talat 继续快速补齐导出、App 隔离和长会能力 | 高 | 它已最接近完整一体化形态，且更新频繁 | 不以功能数量竞争；尽快产出中文、App 捕获和长会指标 |
| 开源组件使本地 ASR/说话人快速商品化 | 高 | Muesli、OpenWhispr 已公开完整实现路径和多模型集成 | 壁垒放在数据集、自动策略、可靠性、UX 和回归体系 |
| MacWhisper 继续扩展实时会议 | 高 | 它有成熟用户基础、编辑器、导出和品牌认知 | 历史与导出至少达到其可用基线，并突出零配置和全局一致性 |
| 低价买断产品压低用户价格预期 | 中高 | Synopsule 官网当前 $1.99，VoiceInk $25、SaidVault $29.99、MacWhisper €64 | 跟踪 $1.99 是否为启动定价；高价必须由跨模式闭环、可靠隔离、中文质量和本地智能支撑 |
| 全局人物误合并破坏用户信任 | 高 | 跨通道、压缩、噪声和短语音会产生相似度误差，未来跨设备后风险更高，且错误会传播到全部历史 | 自动合并以精度优先；保留未知人物、证据、撤销、拆分和索引重建 |
| PRD 范围过宽导致每项都“能用但不够好” | 高 | 四类输入、统一暂停、三阶段、全局人物、LLM、历史和恢复同时进入 V1 | 按技术与用户价值风险顺序验证；跨场景人物匹配先做原型与实测，在线同步留到后续版本 |
| 云端产品增加端侧模式 | 中 | 云端厂商拥有成熟协作与分发 | 坚持无需账号、数据边界清楚和敏感场景可信，避免复制云协作 |

## 10. 产品与工程建议

### 10.1 定位建议

不建议把首页主张写成“本地版 MacWhisper”或“更隐私的会议笔记”。更有辨识度的表达是：

> **中文与中英文混输优先的本地语音工作台：在任意 App 口述，可靠隔离并记录指定 Mac App，并把口述、会议和导入中的同一个人归入可纠错、可搜索的本地人物记忆。**

第二层再强调无账号、全本地、无虚拟声卡和模型自动配置。

### 10.2 必须领先的七件事

1. **中文混输质量**：以真实口述和会议测试集领先，不只更换模型名。
2. **App 捕获可靠性**：把 helper、PID、设备切换、静音等待和来源退出做成自动行为。
3. **跨模式人物一致性**：同一人物跨口述、会议、系统音频和导入保持稳定，未知人物也可搜索。
4. **人物纠错安全性**：误合并可拆分、所有操作可撤销，删除声纹不默认删除历史内容。
5. **统一控制与不丢状态**：四类输入的暂停/继续行为一致，继续后不重置音源、会话和人物映射。
6. **长会最终稿与数据可靠性**：全局 ASR/说话人聚类可见地修正实时稿，同时短块落盘、失败可重试、旧历史可读。
7. **零配置**：一键下载用户可理解的组件，自动选择模型组合，断网后所有核心能力可用。

### 10.3 不能作为主要壁垒的能力

- “使用 Whisper/Parakeet/Qwen”；
- “100% local”单一口号；
- 全局快捷键口述；
- 基础系统音频捕获；
- 基础说话人 A/B/C；
- 仅在会议之间复用一个声纹；
- 普通摘要和行动项；
- 一次性买断。

这些都已有多款竞品实现。它们仍是必备项，但不是足以赢得选择的理由。

### 10.4 价格信号

当前公开市场形成了较宽价格带：

- 本地人物目录产品已经出现 $1.99 一次性价格；该价格可能具有启动期属性，但显著降低了单一“跨录音声纹”功能的定价支撑；
- 轻量本地口述/转写买断约 $25–$29.99，或 €64；
- 完整商业产品订阅约 $6.67–$9/月；
- 一体化或高端买断约 €149，或 $189–$249.99；
- 开源免费产品持续压低纯功能价值。

这不是最终定价建议，但说明 bestASR 若进入高价区间，必须让用户直接感知到单 App 隔离、中文质量、长会一致性、恢复能力和本地会议智能，而不能只依赖隐私叙事。

## 11. 下一阶段实机横评计划

公开资料调研已经足以支持方向判断，但以下结论必须通过统一横评才能获得：谁的中文更准、谁的延迟更低、谁的 App 隔离更可靠、谁的暂停状态不丢数据，以及谁的跨模式人物误合并率更低。

建议优先安装 Talat、MacWhisper、Muesli、OpenWhispr、Superwhisper、Dictara 和 Synopsule，在同一台 M4 Pro/48 GB Mac 上执行；OpenTranscribe 可单独部署用于人物数据模型和治理流程对照：

| 场景 | 样本与操作 | 主要指标 |
|---|---|---|
| 中文/英文/混输口述 | Codex、TextEdit、Chrome、富文本各 10 段；包含代码、数字、否定和自我纠正 | CER/WER、实体准确率、数字/否定保真、首字与最终延迟、插入成功率 |
| 1/2/3 人同次口述 | 单人、两三人轮流、快速短句、少量重叠和背景声；默认向目标 App 插入纯文字 | DER/JER、人物片段完整性、跨入口 Person 一致率、误合并率、是否只插入一次且不被人物作业阻塞 |
| 线下 2/4 人会议 | 30、60、120 分钟；轮流、长沉默、打断和少量重叠 | DER、JER、身份碎片率、错名率、内存曲线、最终稿处理 RTF |
| 桌面会议 | 腾讯会议、Zoom；系统输出与麦克风分轨 | 自己/远端分离、实时积压、说话人质量、来源退出恢复 |
| Chrome 边界 | 会议标签页和另一个播放标签页同时出声 | 是否诚实以 Chrome 为边界、污染比例、提示清晰度 |
| 单 App 稳定性 | helper 新建/退出、App 更新、静音 5 分钟、切换耳机/扬声器 | 丢帧、误录、恢复时间、音量预览刷新 |
| 四类输入暂停/继续 | 分别在口述、线下录音、电脑内录和文件导入中暂停、等待、继续、暂停时结束 | 暂停期是否采集、会话 ID/音源/人物是否保留、时间轴、最终处理触发、快捷键一致性 |
| 跨模式人物匹配 | 同一人分别做近场口述、远场会议、会议软件压缩音频和文件导入；加入两个相似声线的不同人物 | 错误合并率、漏匹配率、身份碎片率、最短有效样本、后台关联延迟 |
| 人物治理 | 对已命名/未知人物执行改名、合并、拆分、撤销、移除关联、删声纹和删历史 | 传播完整性、可逆性、误删保护、重建结果、搜索一致性 |
| 完全断网 | 模型准备后阻断网络，运行四类输入、人物匹配、总结、搜索、重处理、导出 | 网络依赖、失败行为、是否上传或阻塞 |
| 故障恢复 | 录音中强制退出、休眠、撤销权限、制造低磁盘空间 | 最长数据损失、会话可恢复性、错误可理解性 |
| 历史和导出 | 建立大量短口述和长会议，搜索、回放、重算、导出 | 搜索延迟、时间跳转精度、格式完整性、原始数据可追溯性 |

横评时必须记录产品版本、模型、硬件、语言设置、是否联网和原始音频；禁止用不同模型或不同音频得出产品级优劣结论。

## 12. 新版 PRD 对竞争判断的影响

当前 PRD 是本报告的需求基线，本次不修改它。新增需求不推翻原竞争方向，但要求重新排序竞品和差异化：

- “现有产品通常无法同时满足”仍然成立；不应写成“市场上没有同类产品”。
- Talat 已覆盖大部分表层功能，因此验收必须强调质量和可靠性指标，而不是页面上是否有按钮。
- Talat 仍是整体形态最接近的竞品；Synopsule、Dictara 和 OpenWhispr 则分别在人物目录、口述声纹和本地跨会议档案上更值得专项比较。
- Muesli 和 AudioPiper 证明 Core Audio Process Tap 技术可行；实现阶段的真正问题是边界、稳定性和产品化。
- OpenWhispr、Talat、Dictara、Synopsule、Loreo 和 OpenTranscribe 已使跨记录人物档案成为现实竞品能力；新版 PRD 的 P0 优势必须来自跨四类输入、误合并控制和完整治理，而不是“拥有声纹”。
- Muesli、Talat 和 OpenTranscribe 已展示不同形式的恢复/暂停能力，但没有竞品公开证明满足新版 PRD 的四模式统一语义。
- V1 四类入口使用等价的多人分段与全局人物语义；口述必须增加 1/2/3 人、快速轮流与重叠的验证，同时把默认纯文字插入与异步人物最终处理解耦。
- 未来历史迁移与 iPhone↔Mac 同账号同步会改变身份、删除、资产和加密边界，但不应被提前塞进 V1 在线链路；V1 只需把稳定 ID、版本与可移植资产布局做好。
- MacWhisper 的导入、编辑、播放和导出构成成熟基线，历史模块不能在 V1 被做成简单文本列表。
- Dictara 的按秒恢复说明可靠性可以被用户理解并形成卖点，PRD 的增量落盘要求应保持 P0。
- 中文混输、三阶段全局重算、可量化说话人一致性、统一暂停状态和可纠错全局人物是最值得保留并验证的差异化要求。

## 13. 最终判断

bestASR 面对的不是“有没有竞品”，而是“是否能在一个已被验证的品类里，把最难且最有价值的几件事做得明显更好”。

Talat 已经证明一体化本地语音工作台能够成为产品；MacWhisper 证明专业本地转写可以成熟商业化；Muesli 和 OpenWhispr 证明关键能力会快速开源；Superwhisper 和 VoiceInk 证明口述体验竞争激烈；Dictara 证明口述声纹和崩溃恢复会成为卖点；Synopsule 则证明本地人物目录与跨录音声纹已经能以极低门槛面向普通用户销售。

项目仍值得继续，但成功条件已经清楚：

> **不能只“拥有所有功能”，必须在中文混输、单 App 捕获可靠性、全模式不丢状态、长会说话人一致性、跨模式人物纠错、全局最终稿和零配置本地体验上提供可重复、可测量、可演示的优势。**

## 14. 官方资料索引

原报告链接核验于 2026-07-21；暂停/继续和全局人物相关链接增补核验于 2026-07-22。

### Talat

- [Homepage](https://talat.app/)
- [Capabilities](https://talat.app/capabilities)
- [Changelog](https://talat.app/changelog)
- [First launch](https://talat.app/docs/getting-started/first-launch)
- [Transcription settings](https://talat.app/docs/settings/transcription)
- [Summaries settings](https://talat.app/docs/settings/summaries)
- [Audio file import](https://talat.app/blog/how-to-transcribe-an-audio-file)
- [Privacy policy](https://talat.app/privacy)
- [FAQ](https://talat.app/faq)

### MacWhisper

- [Homepage](https://www.macwhisper.com/)
- [Current product and pricing page](https://goodsnooze.gumroad.com/l/macwhisper)
- [MacWhisper 14.0 update](https://goodsnooze.gumroad.com/p/macwhisper-14-0-new-editor-improved-performance-and-what-s-next)
- [Record meetings](https://docs.macwhisper.com/article/30-record-meetings)
- [Automatic speaker recognition](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper)
- [Dictation](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature)
- [App-specific dictation prompts](https://docs.macwhisper.com/article/31-app-specific-dictation-prompts)
- [Keeping transcriptions private](https://docs.macwhisper.com/article/52-keeping-transcriptions-private)
- [Find and replace](https://docs.macwhisper.com/article/37-find-and-replace-in-transcriptions)
- [File locations](https://docs.macwhisper.com/article/54-file-locations)

### Muesli

- [GitHub repository](https://github.com/Muesli-HQ/muesli)
- [Releases](https://github.com/Muesli-HQ/muesli/releases)
- [Meeting Notes](https://muesli.works/meeting-notes)

### OpenWhispr

- [GitHub repository](https://github.com/OpenWhispr/openwhispr)
- [Releases](https://github.com/OpenWhispr/openwhispr/releases)
- [Changelog](https://openwhispr.com/changelog)
- [Meeting transcription guide](https://docs.openwhispr.com/guides/meeting-transcription)
- [Local speaker diarization](https://openwhispr.com/blog/local-speaker-diarization)
- [Pricing](https://openwhispr.com/pricing)
- [Terms](https://openwhispr.com/terms)

### Superwhisper

- [Modes](https://superwhisper.com/docs/modes/modes)
- [Meeting Mode](https://superwhisper.com/docs/modes/meeting)
- [Realtime](https://superwhisper.com/docs/common-issues/realtime)
- [History](https://superwhisper.com/docs/get-started/interface-history)
- [Speaker-separated Meetings](https://superwhisper.com/docs/modes/speaker-separated-meetings)
- [Voice Models](https://superwhisper.com/docs/models/voice)
- [Sensitive Data](https://superwhisper.com/docs/security/sensitive-data)
- [Pricing](https://superwhisper.com/docs/get-started/sw-pro)

### Synopsule

- [Homepage and product capabilities](https://synopsule.com/)
- [Privacy policy](https://synopsule.com/privacy/)

### 全局人物与声纹专项对照

- [Dictara](https://dictara.ai/)
- [OpenTranscribe repository](https://github.com/attevon-llc/OpenTranscribe)
- [Loreo](https://getloreo.com/)

### 其他产品

- [Dictara voice input guide](https://dictara.ai/voice-to-chatgpt)
- [VoiceInk](https://tryvoiceink.com/)
- [VoiceInk pricing](https://tryvoiceink.com/pricing)
- [VoiceInk privacy](https://tryvoiceink.com/privacy)
- [SaidVault](https://saidvault.com/)
- [AudioPiper](https://modelpiper.com/audiopiper)
- [Core Audio Taps technical article from ModelPiper](https://modelpiper.com/blog/capture-app-audio-mac-no-drivers)
- [Hyprnote/Char repository](https://github.com/fastrepl/hyprnote)
