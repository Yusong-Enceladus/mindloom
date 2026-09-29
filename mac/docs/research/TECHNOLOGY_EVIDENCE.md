# 技术证据与候选清单

> 核验日期：2026-07-22  
> 原则：只用官方文档、官方仓库或项目自身资料支撑技术事实；推断与最终选择单独标注。

## 平台与捕获

| 证据 | 可确认事实 | 对 bestASR 的含义 |
|---|---|---|
| [Apple：Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) | macOS 14.2+ 可用 `CATapDescription` 和 `AudioHardwareCreateProcessTap` 捕获一个或一组进程输出；tap 可加入 aggregate device；需要 `NSAudioCaptureUsageDescription` 与系统音频录制授权 | Process Tap 是指定 App/系统音频的首选起点，但 helper 归组、设备切换和长时稳定性仍需实测 |
| [Apple：Core Audio](https://developer.apple.com/documentation/coreaudio/) | `AudioHardwareProcess`、`AudioHardwareTap` 与 aggregate device 是正式 API | 不需要强制虚拟声卡；仍需自行处理生命周期和时钟 |
| [Apple：ScreenCaptureKit capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio) | ScreenCaptureKit 可捕获音频并排除当前进程声音 | 可作为故障对照/回退研究，不代表能满足同样的进程边界 |
| [Apple：AXUIElement](https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication) | Accessibility API 可访问应用 UI 元素；需先获得 trusted 状态 | 跨 App 插入必须单独做兼容矩阵 |
| [Apple：Secure text field subrole](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole) | 安全输入框具有明确 subrole | 插入前必须拒绝受保护字段 |
| [Apple：NSPasteboard changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) | change count 可判断 App 是否仍拥有 pasteboard | 可构建不覆盖用户新复制内容的恢复策略 |

## 本地语音与说话人

| 候选 | 官方事实 | 当前判断 |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Swift/Core ML、ANE、本地 ASR、VAD、在线/离线 diarization、speaker embeddings；提供普通话 SenseVoice/Paraformer；Apache-2.0 | 首批候选。原生程度高，但中英文句内混输、模型逐项许可和长会稳定性必须测 |
| [Argmax OSS / WhisperKit / SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) | macOS 14+、Swift/Core ML、Whisper ASR 与 SpeakerKit；MIT；CLI 支持流式麦克风和离线 diarization | 首批 ASR 对照。开源实时多人边界与低延迟中文要测 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apache-2.0；macOS/iOS arm64 和 Swift；支持流式/离线 ASR、VAD、speaker diarization/identification/verification | 可移植后备候选；评估包体、能效与 Apple 加速情况 |
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | Apache-2.0；0.6B/1.7B；支持普通话、英语、22 种中文方言，流式/离线统一；官方高性能路径是 Python/vLLM/CUDA | 高质量离线对照。未证明可以直接作为无 Python 的原生 Mac 发布后端 |
| [WeSpeaker](https://github.com/wenet-e2e/wespeaker) | 提供 speaker embedding、similarity、verification 与 diarization | 用于评估全局人物模型和校准，不直接等于产品级身份系统 |

## 本地文本模型

### 2026-08-30 说话人聚类单位复现

相同模型文件和 SDK `19600a48`，父进程禁用全部网络，不指定真实人数。两条输入是本机生成的两人合成音频，以及它经 QuickTime 指定 App 内录后导出的保留原音；不是用户录音或独立发布语料。

| 输入 / 控制 | 原配置 0.6 | 修正实参 0.82 | 变化 |
|---|---:|---:|---:|
| 原始 12.505 秒合成文件 | 2 人 / 5 段 | 2 人 / 5 段 | 不变 |
| 15.424 秒内录原音 | 1 人 / 5 段 | 2 人 / 5 段 | 恢复第二人 |
| AMI tuning：17.49 分钟近讲混合轨，无人数提示 | 4 人 / 94 段 | 4 人 / 94 段 | 人数不变 |
| AMI tuning：同场远场阵列轨，无人数提示 | 2 人 / 83 段 | 4 人 / 97 段 | 恢复另外两人 |
| FBank CPU 与 CPU/GPU 控制 | 79,840 个特征 | 最大绝对差 0.00005937；相对 L2 0.000001909 | 不支持替换前处理策略 |

1. 观察：只有阈值单位转换改变了内录聚类数；两条输入的各自语音总时长不变。解释：[固定 SDK 的 AHC](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/Diarizer/Offline/Clustering/AHCClustering.swift) 按余弦相似度转换阈值，而 [pyannote 的 VBx 前置聚类](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/pipelines/clustering.py) 对单位向量使用欧氏距离。适配层应传 `1 - distance² / 2`。
2. 两条合成输入不能证明整体准确率；补充同场 AMI tuning 的近讲/远场轨，仍不传人数。原来远场少分两人，修正后两轨均为四人。FBank 数值控制不足以支持修改算子策略，故保持原配置；冷预测时间不能当暖运行基准。
3. 旧 AMI 回归的 `1...4` 上限会触发 SDK 的固定四簇回退，掩盖聚类差别。因此评估器改为与 App 最终处理相同的无人数提示，并增加禁止人数提示的回归。固定既有全局人物阈值 `0.5489600933809491` 后，重用留出集检查：说话人混淆率 2.2136%，错误身份/错误合并均为 0，既有门槛通过；完整 DER 25.1138%、JER 34.0834% 仍原样报告。这是历史留出集的回归，不是新的未见语料选型，也不能与旧有四人上限的 24.9312% DER 直接归因比较。原报告及有上限的中间结果均保留。
4. 下一步是安装版的保留原音重处理、播放和人物关系检查；不把诊断通过当成交付。私人声纹和音频不进入报告。

| 候选 | 官方事实 | 当前判断 |
|---|---|---|
| [MLX Swift](https://github.com/ml-explore/mlx-swift) / [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | Apple Silicon 的 Swift MLX；官方示例在 iOS/macOS 运行 LLM；MIT | 首选验证对象，尤其利于未来 iPhone 共用；需测试最低 OS、Metal 构建、内存与模型覆盖 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Apple Silicon 是一等平台，使用 ARM NEON、Accelerate、Metal，支持多种量化 | 成熟后备；需要 Swift/XPC 封装、签名与内存测试 |
| [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | Apache-2.0，支持 macOS/iOS CPU/GPU；Swift API 在 2026 年仍为 early preview | 值得保持适配层候选，暂不作为首个冻结后端 |
| [Qwen3.5-4B model card](https://huggingface.co/Qwen/Qwen3.5-4B) | 4B 后训练权重，Apache-2.0 | 可进入事实保真/内存候选集；不因模型卡宣称直接采用 |

## 存储、同步与安全

| 证据 | 可确认事实 | 对 bestASR 的含义 |
|---|---|---|
| [GRDB](https://github.com/groue/GRDB.swift) | Swift 6/macOS/iOS；SQLite 事务、WAL 并发、迁移、FTS5、SQLCipher 文档；MIT | 适合显式数据模型、搜索、测试和未来自定义同步 change log |
| [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine) | 管理本地与 CloudKit record 同步，要求 App 提供待发送变更并持久化 engine state | 未来可置于本地 repository 之上，不要求 V1 先采用 Core Data |
| [NSPersistentCloudKitContainer](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer) | 可把 Core Data store 镜像到 CloudKit private database | 是替代方案；自动同步便利，但对显式 FTS/操作日志和复杂人物冲突控制较弱 |
| [CloudKit encryptedValues](https://developer.apple.com/documentation/CloudKit/CKRecord/encryptedValues) | 字段在设备端加密；CKAsset 默认加密；加密字段不能服务端索引 | 未来同步高敏感数据有平台路径，但查询和密钥恢复必须设计 |
| [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services/) | Keychain 是加密的小型秘密存储 | 用于数据库/资产主密钥，不用于存放大数据 |
| [CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm) | 提供认证加密与完整性校验 | 可用于音频/备份分块加密，仍需正确 nonce/密钥生命周期设计 |

## 分发与开发环境

| 证据 | 可确认事实 | 对 bestASR 的含义 |
|---|---|---|
| [Apple：Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) | 公证 macOS App 必须启用 Hardened Runtime | 发布硬门槛；只打开必要例外 |
| [Apple：Preparing your app for distribution](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution) | DMG/站外公证要求 Hardened Runtime，App Sandbox 可选；App Store 才强制 Sandbox | 可根据 AX/捕获实测决定是否 sandbox，不影响 DMG 方向 |
| [Sparkle 2](https://sparkle-project.org/documentation/) | 支持 SPM 与 EdDSA 签名更新包 | App 更新候选，必须与公证和隐私网络策略一起验证 |
| [Apple：Xcode 26.6](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes) | 当前稳定 Xcode 26.6 包含 Swift 6.3 和 macOS 26.5 SDK；可向下部署 | 当前机器已安装并选中 Xcode 26.6；许可与首次组件检查均通过，下一证据是最小工程和一键构建测试 |

## Codex 开发环境

| 证据 | 可确认事实 | 对项目的配置 |
|---|---|---|
| [Codex Config Reference](https://developers.openai.com/codex/config-reference) | trusted project 可使用 `.codex/config.toml`；`shell_environment_policy.set` 向子进程注入显式环境变量 | 已设置 `DO_NOT_TRACK=1`，产品范围与完成状态分别由 PRD 和 `IMPLEMENTATION_STATUS.md` 管理 |

## 研究结论

1. 原生 macOS 技术路径成立，不需要虚拟声卡或用户安装运行时。
2. 目前没有证据允许直接冻结单一 ASR/说话人/LLM 组合；必须由统一基准选择。
3. 候选模型提供 diarization/embedding 能力，不提供可直接采用的产品身份语义；口述、线下麦克风、系统音频和导入媒体必须由 bestASR 的统一领域层输出同一种会话说话人、出现记录与全局 Person 关系，并用四入口配对语料及 1/2/3 人口述验证。
4. SQLite/GRDB + 显式 change log 能兼顾 V1 本地质量与未来同步，但加密和多进程访问仍是必测项。
5. 未来 iPhone/Mac 同步不要求现在实现云端，却要求现在正确设计稳定 ID、删除墓碑、人物操作和资产引用。
6. Xcode 许可与首次组件前置条件已通过；当前最大准备缺口是最小工程/一键检查和真实捕获、模型、加密证据。约 111 GiB 已达到建议起始空间，但动态磁盘水位仍需落地。缺口不是额外安装更多通用插件。
