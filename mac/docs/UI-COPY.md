# Mindloom 界面文字规范（zh-Hans）

适用于 Mac App、它的扩展（分享、服务菜单、Chrome 扩展、命令行 `mindloom`）、iPhone App（键盘、分享、实时活动）以及 Info.plist 里的用途说明。
同一个概念，用 Apple 在 macOS 27 / iOS 27 系统界面里的说法。下面的对照来自这台 Mac（macOS 27.0.1，26A434）系统 App 和框架自带的 `zh_CN` 本地化表（`*.loctable`），每条注明出处。

`CopyStyleGuardTests`（`Packages/BestASRCore/Tests/BestASRMemoryUITests/`）按本规范扫描所有界面字符串；第 6 节列出的写法一出现，测试就失败。

## 1. 原则

1. **名字**：产品名一律写 Mindloom。“织机”只在“关于”里作副名出现。
2. **说它做什么**：写这个功能做什么、你能做什么。不写安抚或保证的话（“不会……”“从不……”“只……”“安全地……”“放心”）。隐私说明写数据去哪里、谁能看到，用陈述句。
3. **书面、简洁**：用系统设置、照片、备忘录那样的书面语。不用语气词（吧、呢、啦、哦、呀）和口头说法（东西、弄、搞、看看、一下、忘掉、没连上、打不开）。
4. **不造新词**：只用用户凭直觉懂的词。`VocabularyGuardTests` 的词表仍然有效：绳、结、线、股、线索、交叉、牵制等不出现在界面上。
5. **按钮是动词**：按钮、菜单项写动作（删除、添加、拷贝、重新命名、允许、停止共享）。打开下一层窗口或需要再确认的项目以“…”结尾。
6. **报错说两件事**：发生了什么，你能做什么。格式：`无法……。请……。` 或 `未能……。` 不写内部原因和技术词。
7. **不写技术词**：SSH、ProxyJump、known_hosts、组件、XPC、tools/call、defaults write、端口、进程号这类词不出现在界面上。模型统一叫“模型”（识别模型、整理模型）。DGX Spark 是设备名，可以出现。
8. **标点**：中文引号用 “ ”（Apple 系统界面不用「」）。系统 App 和设置面板的名称加引号：`打开“系统设置”`、`打开“设备控制和数据访问”设置`、`打开“键盘”设置`。路径写成 `“系统设置”>“隐私与安全”>“麦克风”`，不写“系统设置 → 键盘”。省略号用“…”。
9. **同一个东西用同一个词**：同一个按钮开始和停止用同一个动词（`检查音量` / `停止检查音量`）；状态栏和浮窗说同一个地方（文字保存在“历史”中）。

## 2. 常用词对照（Apple 原文 → 系统里的 zh-Hans）

| 概念 | 用这个 | 不用 | Apple 出处（英文 → 中文） |
|---|---|---|---|
| Copy / Copied | 拷贝 / 已拷贝 | 复制 / 已复制 | Podcasts、Books、Photos、Mail 等：Copy → 拷贝；Calculator：Copied → 已拷贝 |
| Paste | 粘贴 | | Podcasts、Books 等：Paste → 粘贴 |
| Delete / Delete… | 删除 / 删除… | 删掉 | Podcasts、Maps：Delete → 删除 |
| Remove | 移除 | 去掉 | 多处：Remove → 移除 |
| Rename | 重新命名 | 重命名、改名 | Finder、Photos：Rename → 重新命名；Rename this Person → 给此人重新命名 |
| Name this Person / Add Name | 给此人命名 / 添加姓名 | 起个名 | Photos：Name this Person → 给此人命名；Add Name → 添加姓名 |
| Add to … / Added | 添加到… / 已添加 | 收进…、收好了 | Photos：Add to Album → 添加到相簿；Added to Library → 已添加到资料库 |
| Import… / Export… | 导入… / 导出… | | Import… → 导入…；Export… → 导出… |
| Share / Stop Sharing | 共享 / 停止共享 | 分享（macOS 菜单项） | Share Menu → 共享菜单；Stop Sharing → 停止共享（iOS 分享表单仍叫“分享…”） |
| Allow / Don’t Allow | 允许 / 不允许 | | TCC：Allow → 允许；Don’t Allow → 不允许 |
| Allow Changes / Read Only / Read & Write | 允许更改 / 只读 / 读与写 | 也可以改 | Screen Time：Allow Changes → 允许更改；Sharing、Calendar：Read Only → 只读，Read & Write → 读与写 |
| Connected / Not Connected / Connecting… | 已连接 / 未连接 / 正在连接… | 连上了、没连上、连接中 | 多处 |
| Disconnect / Reconnect | 断开连接 / 重新连接 | 断开 | Disconnect → 断开连接；Reconnect → 重新连接 |
| Couldn’t Connect | 无法连接 | 连不上 | Couldn’t Connect → 无法连接 |
| Try again later. | 请稍后再试。 | 稍后再试一下 | Try again later. → 请稍后再试。 |
| Not Now | 以后 | 以后再说 | Not Now → 以后（96 处） |
| Learn More… | 进一步了解… | 看看、详细说明 | Learn More… → 进一步了解… |
| Show Details / Details | 显示详细信息 / 详细信息 | | Show Details → 显示详细信息 |
| Expand / Collapse | 展开 / 折叠 | 收起 | Expand → 展开；Collapse → 折叠 |
| Hide / Show | 隐藏 / 显示 | 遮住、原样 | Hide → 隐藏 |
| Undo | 撤销 | | Undo → 撤销 |
| Merge | 合并 | | Photos：Merge → 合并 |
| Mark as Completed | 标记为完成 | 标完成 | Mark as Completed → 标记为完成 |
| Saved / Paused / Downloading… | 已保存 / 已暂停 / 正在下载… | | 多处 |
| Listening / Recording | 正在聆听 / 正在录制 | 正在听 | Accessibility 设置：Siri “聆听语音输入”；Recording → 正在录制 |
| Transcribe | 转写 | 转成文字、转好 | Voice Memos：Couldn’t Transcribe Audio → 无法转写音频 |
| Storage | 储存空间 | 存储空间 | “系统设置”中释放Mac储存空间 |
| Untitled / Unknown | 未命名 / 未知 | 没起名 | Untitled → 未命名；Unknown → 未知 |
| Recently Added | 最近添加 | 刚收进来 | Maps：Recently Added → 最近添加 |
| Show in Finder | 在访达中显示 | 在 Finder 中显示 | Font Book：Show in Finder → 在访达中显示 |
| Keychain | 不在界面上点名；写“这台 Mac 上” | 安全存储、钥匙串 | 钥匙串是 Apple 的词，但 VOCABULARY 不许“钥匙”出现在界面上 |
| Live Captions | 实时字幕 | | Live Captions → 实时字幕 |
| Accessibility（“隐私与安全”里的权限） | 设备控制和数据访问 | 无障碍、辅助功能 | SecurityPrivacyExtension `Localizable.loctable`：键 `ACCESSIBILITY`，en “Device Control and Data Access” → zh_CN “设备控制和数据访问”；TCC：“已添加设备控制和数据访问”。“无障碍”是另一个设置面板（VoiceOver 等，AccessibilitySettingsExtension 的显示名），不是这个权限 |
| Privacy & Security | 隐私与安全 | 隐私与安全性 | System Settings：Privacy & Security → 隐私与安全 |
| Screen & System Audio Recording | 录屏与系统录音 | 屏幕与系统音频录制 | SecurityPrivacyExtension：→ 录屏与系统录音 |
| Login Items & Extensions | 登录项与扩展 | | GeneralSettings：→ 登录项与扩展 |
| Press 🌐︎ key to / Do Nothing | 按下🌐︎键时 / 不执行任何操作 | | KeyboardSettings：→ 按下🌐︎键时；Do Nothing → 不执行任何操作 |
| Open System Settings | 打开“系统设置” | 去设置 | Open Settings → 打开“设置”；Go to System Settings… → 前往“系统设置”… |

## 3. 固定句式

- **权限请求（用途说明）**：一句话，说 Mindloom 用它做什么。`Mindloom 使用麦克风录制你开始的口述和会议。`
- **去系统设置开权限**：`请在“系统设置”>“隐私与安全”>“麦克风”中允许 Mindloom。` 输入文字和 fn 键用的权限：`请在“系统设置”>“隐私与安全”>“设备控制和数据访问”中允许 Mindloom。`（行名单独出现时也写“设备控制和数据访问”，不写“无障碍”。）
- **删除确认**：标题问句 `删除这条记录？`；正文写删除什么、保留什么，用陈述句，可以加 `此操作无法撤销。`（Apple：You can’t undo this action. → 此操作无法撤销。）；按钮写动作和对象（`删除录音，保留文字`、`删除记录`）+ `取消`。
- **说明保留了什么**：写“会保留”“保持不变”，不写“不会删除”“不会改变”。
- **报错**：`无法连接 DGX Spark。请检查网络后重试。` 先说发生了什么，再说你能做什么；说不出你能做什么时，只说发生了什么。
- **状态**：`正在……` / `已……` / `未……`。不写过程细节。
- **隐私说明**：`储存在这台 Mac 上：录音、声音样本、词典。` `发送到你的 DGX Spark：转写的文字和截图中的文字。发送前隐藏手机号和证件号。`
- **Apple Watch 录音的备份提示（iPhone，一次）**：第一次在首页看到 Apple Watch 的录音时出现，只出现这一次，以后不再出现（2026-10-06 用户裁决；`WatchRecordingInbox.BackupNotice`，`WatchHandoffTests` 检查）。标题 `备份 Apple Watch 录音`；正文 `来自 Apple Watch 的录音，其原件在备份之前仅存放于这台 iPhone。可在“设置”中打开“iCloud 云备份”，或使用电脑进行加密备份。iPhone 丢失或更换后，未备份的录音无法恢复。`；按钮 `好`。说清原件在哪里、可以怎么做、不备份会怎样；不承诺、不催促，也不用“只在”“只保存”。
- **次要说明**：主标签下一行，写结果，不超过一句。例如同意卡的 `允许更改` 下面写 `可以添加内容、更改归属、重新命名和标记为完成。所有更改都可以在“设置”中撤销。`

## 4. 名字

- 菜单、窗口标题、通知、快捷指令、服务菜单、分享扩展、导出文件名、报错里都写 Mindloom。2026-10-06 起 App 的身份也是 Mindloom 的（`app.mindloom`）：可执行文件、资料库文件夹（`~/Library/Application Support/Mindloom`）、钥匙串条目的名字和服务都写 Mindloom，用户能看到的地方不再出现 bestASR。只有说到换装前的 App 时才写 bestASR，例如欢迎窗口在换装后第一次打开时的 `从 bestASR 换到 Mindloom 后，需要重新允许下面两项。`（`WelcomeCopy.permissionsTextAfterBestASR`），以及 bestASR 还在运行、占着 fn 或资料库时的报错 `bestASR 正在使用你的资料库。请退出 bestASR，然后重新打开 Mindloom。`，资料库还在 bestASR 的文件夹中（换装之前，或回退之后）时的 `你的资料库还在 bestASR 的文件夹中，Mindloom 没有打开它。请继续使用 bestASR。`
- “关于”里写 `Mindloom` 和副名 `织机`；欢迎窗口只写 Mindloom。
- 标语：不是一句固定的话，是中文、英文两套轮换的句子（2026-10-06 用户裁决），每 6 小时换一句（产品时区的 0 点、6 点、12 点、18 点），跟着界面语言走；规则、位置和全部句子见 `docs/TAGLINES.md`，数据在 `taglines.json`。用在欢迎窗口第一屏的标志下面（新装后第一句是“编织你的史诗。”）和主窗口边栏底部“设置”上面。句子原样使用，不改字、不加引号；引文在下面一行用小字写出处（“——韩愈《进学解》”）。标语是品牌文字：§1.3 的书面要求和 §1.4 的词表不适用于它，标点仍按 §1.8（`MindloomTaglinesTests` 检查）。
- 给外部 Agent 的说明（MCP 服务说明）可以提到“织机”，让 Agent 认得用户的说法；那不是界面。

## 5. 不在范围内的字符串

这些不是界面文字，测试不扫：标语数据 `taglines.json`（品牌文字，按 `docs/TAGLINES.md` 写，`MindloomTaglinesTests` 检查）、发给模型的提示词、给外部 Agent 模型读的工具说明和读出的资料、搜索和口述指令解析用的词表（昨天、微信……）、隐去号码时的规则和占位符、合成演示数据（`App/LiveShots.swift`、`iOS/App/Debug/`）、开发用命令行工具、测试替身。清单在 `CopyStyleGuardTests.notUserVisible`，每项写了原因。外部 Agent 会转述给你的那几句（`AgentCopy`）和工具标题仍按本规范写。

## 6. 测试检查什么

`CopyStyleGuardTests` 扫描 `VocabularyGuardTests` 同样的源文件夹里每个含汉字的字符串（含多行字符串；多行字符串也按 `VocabularyGuardTests` 的词表查），Info.plist、`InfoPlist.xcstrings` 的用途说明，以及 `integrations/` 下扩展和插件的 JSON 清单与 JS 里的字符串（Chrome 扩展、Claude Desktop 扩展、Claude Code 插件），和 Claude Code 插件里技能与命令 `.md` 开头的 `description:` 行（命令说明显示在 Claude Code 的“/”菜单里）：

| 规则 | 拒绝的写法 |
|---|---|
| 名字 | “织机”（“关于”和第 4 节的例外除外）；“Mindloom（织机）”这种括号副名在哪里都不行。插件技能的说明里出现“织机”时，要先写 Mindloom，并写“回答主人时写 Mindloom” |
| 保证 | 不会、从不、绝不、永不、永远不、放心、担心、安全（“隐私与安全”除外）、只在、只会、只用、只发、只送、只留、只存、只给、只记、只从、只看到、只连、只保存、只保留、只录、只收、只把、只读：、不上传、不离开、不连接网络、不联网、由你删除、只由你 |
| 口语和旧说法 | 也可以改、吧、呢、啦、哦、呀、嘛、东西、看看、一下、忘掉、没连上、连不上、连上、打不开、看不懂、没看懂、没能、弄、搞、啥、咋、起个名、删掉、去掉、以后再说、去设置、留着、不见了、装好、收进、收好、复制 |
| 技术词 | SSH、ProxyJump、known_hosts、组件、XPC、tools/call、defaults write、stderr、launchd |
| 系统名称 | 无障碍、辅助功能、隐私与安全性、屏幕与系统音频录制、屏幕录制；不带引号的“系统设置”；含“设置”的“ → ”路径 |
| 标点 | 「」（列举标点字符的集合除外：上一行写 `// copy-guard: characters`，只对全是标点、没有文字的字面量生效） |
| 需要人工复核 | 仅录制、仅保存、仅用于：说明范围可以，换个字的保证不行。每处复核过的写在 `CopyStyleGuardTests.reviewedScope`，写明理由；新出现的一处先复核再加进去 |
| 英文用途说明和名称 | never、only、safe、secure（Info.plist 里的英文） |

新写界面文字时先查第 2 节；第 2 节没有的概念，在系统 App 的 `zh_CN` 表里找同一个英文词的译法（`plutil -convert json` 读 `*.loctable`）。
