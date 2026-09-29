# bestASR 前期准备与就绪审计

> 审计日期：2026-07-22  
> 评估视角：由 Codex 持续实现、验证和维护，而不是按人类团队工时或仪式评估。

## 1. 当前结论

- **可以产出并维护技术方案**：通过。架构边界、数据语义、风险验证和质量门槛已经形成文档基线。
- **可以直接开始全功能实现**：暂不通过。工具链前置条件已通过，但工程构建入口、核心捕获、模型与加密仍没有实机证据。
- **可以开始 Spike**：通过。Xcode 许可、首次组件、active developer directory、Swift/SDK 和起始磁盘水位均已验证；应从 `SPIKE-ENV-001` 的最小工程与一键检查开始。
- **交付跟踪方式**：PRD 定义产品与验收，技术方案和 ADR 定义架构，`IMPLEMENTATION_STATUS.md` 只记录当前真实状态和下一批未完成结果。

## 2. AI 开发能力底座

| 能力 | 状态 | 对开发质量的实际提升 |
|---|---|---|
| Git repository | 已初始化并同步 Private GitHub repository | 允许精确 diff、远端备份、回归定位和可恢复变更 |
| `AGENTS.md` | 已配置 | 每个后续任务自动继承隐私、架构和质量硬约束 |
| `IMPLEMENTATION_STATUS.md` | 已建立 | 直接记录用户可见现状、剩余 P0/P1 与真实阻塞，不引入额外变更工作流 |
| Build macOS Apps plugin | 已安装 | 提供 SwiftUI/AppKit、build/debug、测试分诊、签名、公证、DMG 和本地 Logger 工作流 |
| Codex Security plugin | 已安装 | 为权限、音频边界、持久化、模型更新和未来同步提供 threat model、diff scan、finding 验证与发布前扫描 |
| OpenAI Developer Docs MCP | 已添加 | 后续任务可直接查 Codex/OpenAI 官方资料，减少陈旧配置判断 |
| Browser / Computer Use / Playwright | 已可用 | 以后可做真实 UI、权限、安装与目标 App 交互验证 |
| XcodeGen 2.45.3 | 已存在 | 可生成/审计工程，但不能替代完整 Xcode SDK 与签名工具 |

macOS/Security plugin 和 Developer Docs MCP 在需要时于新 Codex 任务中加载；不需要重复安装。

## 3. 不建议额外安装的 plugin

当前没有必要安装 Notion、Google Drive、Slack、Teams、SharePoint、Box 或日历类 plugin。产品资料与代码都在本地仓库，这些连接器不会改善音频捕获、Swift 构建、模型基准或发布质量，反而扩大数据访问面。

只有在用户明确把 PRD/设计稿/任务源迁移到相应服务时，再安装对应 connector。Figma 也应等到有实际设计文件或需要设计到 SwiftUI 的交付时再使用，不能替代当前技术 Spike。

## 4. 本机环境审计

| 项目 | 当前值 | 判断 |
|---|---|---|
| OS | macOS 26.5.2, arm64 | 支持 Xcode 26.6 |
| Swift CLI | Swift 6.3.3 | 可跑纯 Swift 工具；不足以构建完整 App/Metal 依赖 |
| 完整 Xcode | Xcode 26.6（17F113）；active path 为 `/Applications/Xcode.app/Contents/Developer`；macOS SDK 26.5 | `xcodebuild -license check` 与 `-checkFirstLaunchStatus` 均返回 0；工具链前置条件通过，App 构建证据仍待 `SPIKE-ENV-001` |
| 当前可用磁盘 | 约 111 GiB | 达到建议起始水位；仍须设置模型、语料、DerivedData 与长录音软/硬水位 |
| Git | 2.50.1 | 通过 |
| Codex CLI | 0.145.0-alpha.30 | 当前可用；后续以新任务加载新增能力 |

下一步从环境 Spike 开始：

1. 生成最小 macOS App、Swift package、XPC、unit/UI test target 和一键脚本。
2. 从空 DerivedData 执行 SwiftPM、App 和测试 smoke，并保存机器可读环境证据。
3. 建立磁盘软/硬水位并在下载模型、语料或生成长录音前执行空间预检。

在最小工程、磁盘水位和下载清单尚未落地前，不自动下载多套模型或公开语料。

## 5. 文档与需求就绪度

| 文档 | 状态 | 作用 |
|---|---|---|
| [PRODUCT_REQUIREMENTS.md](../../PRODUCT_REQUIREMENTS.md) V1.3 | 产品边界已收敛 | 产品能力、统一人物语义、MVP/V1 边界、优先级、验收、永久音频、迁移和未来同步方向 |
| [COMPETITIVE_ANALYSIS.md](../../COMPETITIVE_ANALYSIS.md) V1.3 | 已同步产品基线 | 竞争证据与需实机验证的差异化 |
| [TECHNICAL_DESIGN.md](../architecture/TECHNICAL_DESIGN.md) 0.4 | 已建立 | 系统结构、统一人物管线、MVP/V1 数据边界、隐私、恢复和同步边界 |
| [ADR_INDEX.md](../architecture/ADR_INDEX.md) | 已建立 | 冻结长期原则，防止后续实现反复漂移 |
| [SPIKE_PLAN.md](../spikes/SPIKE_PLAN.md) | 已建立 | 把最大未知变成 pass/fail 证据 |
| [EVALUATION_PLAN.md](../quality/EVALUATION_PLAN.md) | 已建立 | 模型和软件质量的统一测量方法 |
| [THREAT_MODEL.md](../security/THREAT_MODEL.md) | 已建立 | 数据分级、信任边界、威胁、控制与验证证据 |
| [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) | 已建立 | 只保留真正改变产品/架构的用户决策 |
| [IMPLEMENTATION_STATUS.md](../../IMPLEMENTATION_STATUS.md) | 已建立 | 当前真实可用切片、剩余 P0/P1、工程阻塞与完成规则 |

## 6. 进入实现前的硬门槛

### Gate A：工具链

- `xcodebuild`, `swift test`, UI test host、Core Audio sample 和空白 DMG build 可运行。
- 项目一条命令 `script/check.sh` 能格式化检查、构建和测试。

### Gate B：风险 Spike

- Process Tap 的 App 边界、helper、新 PID、设备切换和 2 小时稳定性有保存结果。
- 双轨时间 drift、AudioJournal kill-test 与恢复损失上界通过。
- AX/剪贴板兼容矩阵覆盖 PRD 指定 App。
- 至少两套 ASR、两套说话人方案和两套 LLM runtime 在相同语料上比较。
- 加密数据库/音频资产、FTS 与密钥恢复通过。
- 原始音频非破坏导出，以及 `.bestasrarchive` 在无来源 Keychain 的另一测试用户中完整、原子恢复通过。

### Gate C：产品选择

- **已通过**：V1 最低 16 GB。
- **已通过**：所有原始音频默认永久保留，用户明确删除除外。
- **已通过**：V1 P1 包含完整加密 `.bestasrarchive`；原始音频导出和未来云同步使用独立链路。
- **已通过**：四类音频入口使用等价的多人分段与全局人物语义；默认纯文字插入不减少应用内人物证据。
- **已通过**：MVP 口述优先，但核心协议、领域、持久化、durable jobs、模型与未来同步边界从第一天按完整 V1 设计。

### Gate D：依赖与供应链

- 每个 SDK/模型的版本、摘要、许可证、NOTICE、来源和发布权利入清单。
- 无 token、Python、Homebrew 或联网推理的全新安装烟测通过。

## 7. 面向 Codex 的完成定义

Codex 只有在以下证据齐全时才可把一个实现任务声明为完成：

- PRD ID 与相应 test/probe/evidence 可追踪；
- happy path、拒绝权限、失败、取消、重试和崩溃恢复按适用范围有测试；
- 性能/准确率/资源/网络边界有机器输出，而不是主观描述；
- 文档、schema migration、许可和回滚同步更新；
- `script/check.sh` 通过且没有用跳过测试掩盖失败；
- 用户内容没有进入 Git、日志或默认诊断包。

这套准备工作会直接提升代理的判断能力、修改一致性、故障恢复质量、隐私可靠性和未来可维护性；它不是为了增加流程本身。
