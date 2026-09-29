# bestASR

本地运行的 macOS 语音输入 App：按住 Fn 说话，松手后把识别并整理好的文字写进当前光标处。识别、整理、翻译都在本机完成；音频、声纹和词典永不出设备。只有在用户明确开启、可随时撤销的 SSH 加密链路后，逐字稿和用户提供的资料才会发到用户自己的 DGX Spark 做整理（见 PRD §0.3），没有云端路径。

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
