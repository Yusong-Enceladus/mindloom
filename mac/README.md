# bestASR：织机 Mindloom 的 Mac 客户端

> 这是 [织机 Mindloom](../README.md) 的 Mac 客户端。代码、工程名和 Bundle ID（`com.bestasr.app`）沿用开发代号 bestASR；整体介绍、架构和评测见仓库根目录的 README。

本地运行的 macOS 语音输入 App：按住 Fn 说话，松手后把识别并整理好的文字写进当前光标处。识别、整理、翻译都在本机完成；录音、声纹和词典永不出设备（你主动拖进来的其他文件不超过 25 MiB 时原样发送，见根目录的 [docs/PRIVACY.md](../docs/PRIVACY.md)）。只有在用户明确开启、可随时撤销的 SSH 加密链路后，逐字稿和用户提供的资料才会发到用户自己的 DGX Spark 做整理（见 PRD §0.3），没有云端路径。

## v8 整合（2026-10-01）

v8 的入口、实验室 infra、共享空间收尾和对抗复查的修复合进 `hackathon/base`（整理设备那边合进 `main`）。在一个全新的整合版整理设备实例上重跑：隐私 68/68、手机 67/67、共享空间 57/57、团队 infra 53/53、成员 Mac 自己的连接 13/13、经真实 sshd 的门 19/19、两位成员互相隔离 31/31、合同 C 29/29、Agent 的 MCP 43/43、Chrome 扩展经本机通信通过。需求编号见 PRD §0.3 第 15 条（新增 SPACE-019、INFRA-010），设计见 `docs/architecture/TECHNICAL_DESIGN.md` 的“v8 集成”，结果见 `IMPLEMENTATION_STATUS.md`。

## v8 实验室的 infra：团队与整理设备（2026-10-01）

一台整理设备可以给整个实验室用（需求 INFRA-、SPACE-013–016，见 PRD §12.13 与 §12.11）。在 **设置 → 团队与整理设备**：

- **每个人用自己的钥匙进门。** 队友不再用整理设备主人的账号：管理员点「邀请队友」，生成一个一次性邀请码（可以连同一个共享空间的邀请）；队友在自己 Mac 的同一页粘贴邀请码，Mac 生成自己的钥匙和凭证，只能进共享空间的门，进不了主人的账号。「加一台我的 Mac」给自己的另一台 Mac 发邀请。「断开」后那台 Mac 的钥匙从整理设备上删除，之后在待办里把它从空间移除（会换钥匙）。
- **管理员看得到的：** 整理设备状态（整理器、模型、GPU 和内存、磁盘，只有数字）、成员和设备与角色、组织管理员和钥匙托管、可以读织机的 Agent（可收回）、审计记录（只有编号和动作，没有内容）、每人在每个空间的存储用量。
- **交接：** 共享空间里一件事的「交接…」：整理设备上的模型写交接包（每一句标出处），可以导出 Markdown、作为快照分享进空间，再把负责人交给别人。
- **备份：** 每个空间可以每天或每周加密备份到这台 Mac 或移动硬盘，也可以手动备份和恢复；备份只有空间成员打得开。
- **钥匙托管：** 组织空间的钥匙另外托管给几位组织管理员，丢了一位管理员的电脑，另一位能接管。
- **共享面板：** 录音片段可以勾「附上这段原音」（默认不勾；只有成员能听，整理设备打不开；整段录音永不共享）；新增「一份摘要（冻结）」；断网时的共享先存在这台 Mac 上，连上后发出，不会重复。

设计见 `docs/architecture/TECHNICAL_DESIGN.md` 的“v8 实验室 infra”一节，测试与结果见 `IMPLEMENTATION_STATUS.md`。

## v8 入口：兼容一切（2026-10-01）

除了粘贴和拖入，内容还能从下面这些地方进织机。每个入口都走和粘贴、拖入相同的规则，记下来源和时间；链接只记下、从不打开；收进来的东西和其他条目一样，号码遮住、截图涂掉后才送去整理。每个入口都在 **设置 → 入口** 里有自己的开关；会在后台自动收东西的入口，和别的程序很容易调用的入口（服务菜单、命令行），默认关闭（需求 ENTRY-，见 PRD §12.12）。

| 入口 | 怎么用 | 默认 | 收进什么 | 从不做什么 |
|---|---|---|---|---|
| 分享菜单「收进织机」 | Safari、邮件、备忘录、访达等的「分享」 | 开 | 文字、链接、文件、图片；来源是分享时的 App | 不打开链接；扩展只能写织机的分享文件夹 |
| 服务菜单「收进织机」 | 选中文字 → App 菜单 → 服务 | 关（这台 Mac 上任何 App 都能用程序调用服务菜单项，复查 V8R-17） | 选中的文字；来源是那个 App | — |
| Chrome 扩展「收进织机」 | 网页上右键，或点工具栏的织机按钮（在设置里打开后，按 `integrations/chrome-extension/README.md` 装扩展） | 关 | 选中的文字连同网页标题和链接、网页链接、网页上的链接；来源「Chrome」 | 不联网：扩展没有网站权限、禁止联网；链接不打开；只在你点的时候读选中的文字 |
| 快捷指令 | 「添加到织机」「织机：今天到期」 | 开 | 文字、文件、链接；到期清单只读 | 到期清单不改任何东西、不出 Mac |
| 命令行 `mindloom` | `mindloom add "…"`、`--file`、管道；`mindloom due` | 关 | 来源「命令行」，算你自己收进的 | 打开后以你身份运行的程序（包括终端里的 Agent）也能用，设置里写明 |
| 文件夹 | 选文件夹（截图、下载……），可设排除、大小上限、暂停 | 关 | 之后新出现的文件；来源「文件夹 · 名字」 | 打开前和暂停期间的文件不收；子文件夹和链接不跟 |
| 日历 | 选要读的日历（需要系统权限） | 关 | 日程的标题、时间、参与人姓名、备注；来源「日历」 | 从不写日历；不读邮箱 |
| 提醒事项 | 事件页「线索」右侧「下一步」下的按钮 | 开 | 点一次写一条提醒 | 不会自动写 |
| Git 仓库 | 选本机仓库和分支（也适用于 Overleaf 的 git） | 关 | 新提交的标题、说明、作者、改动的文件名和个数 | 从不读文件内容 |
| Zotero | Zotero 7 开放本地接口后 | 关 | 新文献、笔记、批注，附引用 | 只连这台 Mac 上的 Zotero，不读附件 |

Safari 不需要单独的扩展：用分享菜单收网页链接，用服务菜单收选中的文字。设计见 `docs/architecture/TECHNICAL_DESIGN.md` 的“v8 入口”一节，测试与结果见 `IMPLEMENTATION_STATUS.md`。

## v7（2026-10-01 整合）

- **线索图**：事件页默认显示“线索”——一件事分成几股线，线上打结（进展、决定、问题、承诺、截止），每个结都能点开看出处原话；另有结构、网、文本三个看法。首页多了按绳、按截止、按人。图和绳由整理设备画（需求 MAP-、LINK-）。
- **Agent 读取织机**：App 自带本机 MCP 连接程序 `mindloom-mcp`，加 Claude Code 插件和 Claude Desktop 扩展；第一次读取要你同意，范围、期限、号码遮挡都由你定，每次读取都有不含内容的记录。用法见 [docs/AGENTS.md](docs/AGENTS.md)（需求 AGENT-）。
- **共享空间**：照 GitHub 的逻辑和别人共享事情（小组空间、实验室的组织空间）；钥匙只在成员的 Mac 上，整理设备只见到签过名的操作记录、密文和整理需要的遮挡文字；声纹、词典和整段录音永远不进空间（需求 SPACE-；v8 起录音片段可以附上只有成员能听的原音，见上）。
- 合并记录与测试结果见 `IMPLEMENTATION_STATUS.md` 最上面一节。

## 先读这些

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 仓库规则：隐私不变量、工程约束、质量门槛（人和 AI 都要遵守） |
| [PRODUCT_REQUIREMENTS.md](PRODUCT_REQUIREMENTS.md) | 需求与验收场景 |
| [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) | 当前做到哪、实测证据 |
| [DICTATION_ARCHITECTURE.md](DICTATION_ARCHITECTURE.md) | 口述链路（录音 → 识别 → 整理 → 投递）的现行设计 |
| [docs/architecture/TECHNICAL_DESIGN.md](docs/architecture/TECHNICAL_DESIGN.md) | 整体技术设计与 ADR |

## 来源

本目录是公开仓库 `mindloom` 的 Mac 客户端部分（去掉了个人数据工具、设备与签名信息）。仓库根目录的 README 说明整体项目。

## 环境要求

- Apple Silicon Mac，macOS 14.2 或更新，内存 16 GB 以上；可用磁盘建议 40 GB 以上（模型约 5 GB，构建缓存另算）。
- **Xcode 27.0**（Swift 6.4）。`script/bootstrap.sh` 会精确校验这个版本。
- XcodeGen 2.45.3：只在改 `project.yml` 或跑完整检查时需要（`BestASR.xcodeproj` 已提交）。从 <https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.3> 下载，或 `brew install xcodegen` 后确认版本。
- 用户机器上不需要 Python、Homebrew 或命令行运行时；这些只用于开发期脚本。

## 一次性配置

```bash
# 1. 选中 Xcode 27.0，并完成许可与首次组件安装
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain   # MLX 需要编译 Metal 着色器

# 2. 创建构建卷。构建脚本只把产物写到指定构建卷（默认 /Volumes/BestASRBuild）；未挂载时直接报错
hdiutil create -size 80g -type SPARSEBUNDLE -fs APFS -volname BestASRBuild ~/BestASRBuild.sparsebundle
hdiutil attach -nobrowse ~/BestASRBuild.sparsebundle

# 3. 环境自检（Xcode/Swift/XcodeGen 版本、许可、Metal Toolchain、磁盘空间）
script/bootstrap.sh
```

重启后构建卷会卸载，需要重新 `hdiutil attach -nobrowse ~/BestASRBuild.sparsebundle`。也可以用任意已挂载的卷：`export BESTASR_BUILD_VOLUME=/Volumes/<卷名>`。细节见 [docs/development/EXTERNAL_BUILD_STORAGE.md](docs/development/EXTERNAL_BUILD_STORAGE.md)。

不要直接跑 `swift build`、`swift test` 或 `xcodebuild`，用下面的脚本，它们会把缓存和产物路径显式指到构建卷。

## 构建与运行

```bash
script/build_and_run.sh              # Debug 构建（ad-hoc 签名）并启动
script/build_and_run.sh --build-only # 只构建
script/check.sh                      # 完整检查：自检、工程漂移、静态检查、包测试、构建、单元/UI 测试、隐私扫描
```

装成日常使用的正式版（放到 `~/Applications/bestASR.app`）：

```bash
script/build_release.sh     # 需要干净的工作区和一个 “Apple Development” 签名身份（Xcode → Settings → Accounts 登录 Apple ID 即可生成）
script/install_local_app.sh # 校验签名后原子替换已安装版本，并保留上一版用于回滚
```

用稳定签名身份是为了让 macOS 的麦克风、辅助功能授权在每次重装后仍然有效。

## 首次启动

1. 首页点 **“下载并开始使用”**。App 从 Hugging Face 按固定 revision 下载模型（Qwen3-ASR 1.7B 8-bit 等，约 5 GB），校验大小与摘要后装到 `~/Library/Application Support/bestASR/`。
2. 按提示授权 **麦克风**（录音）和 **辅助功能**（监听 Fn、把文字粘贴进其他 App）。
3. 在任意输入框里按住 Fn 说话、松手即写入。Fn+Shift 翻译后写入；Fn+空格 把口述当指令（改写选中文字或直接生成）。翻译用系统 Translation 框架，语言包在设置里下载。

“个人整理模型”是用本机用户自己的口述训练出来的，属于个人数据，不随仓库分发也不会下载；没有它时 App 走通用整理路径，功能照常可用。

## 协作约定

- 模型、语料、含用户音频的评测结果、签名材料、构建产物一律不进 Git（见 `.gitignore`）。
- 日志里不能出现音频、完整转写、词典内容或说话人数据。
- 改动需求或行为时，PRD、IMPLEMENTATION_STATUS 与技术设计一起更新，保留需求编号。
- 修 bug 要附回归测试或可复现的夹具。
