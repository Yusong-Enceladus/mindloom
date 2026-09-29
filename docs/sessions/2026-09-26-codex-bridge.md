# 会话笔记：Codex 接手 Mac↔Spark 整理桥接（2026-09-26）

> 会话结束后整理的摘要。本会话之后的审查在这条链路上确认了几处隐私和持久性问题，修复进展见 Mac 端的 [IMPLEMENTATION_STATUS](../../mac/IMPLEMENTATION_STATUS.md)；现状以 [README](../../README.md) 为准。

## 会话与时间

- 工具：Codex 桌面版（不是 Claude），单个会话，中途有一次上下文压缩。
- 时间：2026-09-26 13:06–14:27 UTC（北京时间 21:06–22:27），约 80 分钟。
- 涉及两个仓库：主仓库 `bestASR`（Mac App），以及 Spark 端仓库（DGX Spark 上的整理服务和 Skill，公开时并入本仓库）。

## 目标

1. 先盘点 bestASR 参加 DGX Spark 黑客松准备到了哪一步。
2. 负责人确认后，接手已经和 Claude 对齐过的 **Mac↔Spark 整理桥接**：Mac 收进素材，经可撤销的 SSH 链路送到用户自己的 Spark，由 Skill 整理出事件和进度，再把结果拉回 Mac 展示。全程只用合成数据。

## 关键决定（产品与技术）

- **先做闭环，再做别的。** 首要交付是一条能重复演示的链路：合成素材 → Spark 整理 → Mac 展示。首页、素材入口、真实模型评测和参赛材料排在后面。会话里提议的分工是 Codex 负责桥接和验收，Claude 回来后负责界面、品牌和演示素材，避免两边改同一条链路。
- **隐私边界照 PRD §0.3 执行。**
  - Spark 开关默认关闭。开启后只发送新完成的最终逐字稿或用户编辑稿、分段和人物标签、来源 App 字段，以及用户在事件页做的整理决定。
  - 音频、声纹、词典和窗口标题留在 Mac。
  - 开启时不会把旧记录悄悄补发出去。关闭开关会立刻停止发送并断开隧道，但已经送到 Spark 的内容仍留在 Spark 上。
  - Debug 构建一律不从常规资料库发送。跨端验证用单独的临时合成 SQLite 库。
- **传输层加固。**
  - HTTP 客户端只访问本机回环地址，并拒绝 HTTP 重定向，防止内容被带离回环。
  - App 的 ATS 配置里只加了本地网络许可。
- **幂等与顺序。**
  - Mac 端用持久的待发队列（outbox）发送条目、决定和问题回答，失败按指数退避重试，上限 300 秒。
  - 本地还没送达的决定优先于从 Spark 拉回的状态，避免用户刚做的操作被短暂覆盖。
  - Spark 端给每个决定一个稳定的 `decision_id`，并保存回执（ID + 内容摘要）。同一决定重发时返回原结果，ID 被别的内容复用时拒绝。这条规则已写进技术设计的 v1 接口说明。
- **删除语义。** 在 Mac 上显式删除会话，会清掉它还没发出的队列项。冻结的 v1 协议没有「删除 Spark 上已收到的源条目」接口，这一点作为已知缺口写进了文档，没有当作已完成。

## 做了什么与产出

**盘点结论（会话开始时）**

- `hackathon/base` 分支已推送，包含 Xcode 27 迁移和口述链路修复。
- 比赛仓库里已有整理服务、4 个主要 Skill 和合成场景。
- Mac 客户端、素材入口和「回忆」首页都还没做，真实模型评测也还没有结果。
- 开始时 SSH 超时。复查后确认 Spark 本身一直可以连，真正的问题是整理服务没有启动。

**Spark 端（分支 `codex/spark-service-integration`，提交 `85c820b`）**

- 用 `spark/deploy.sh`、`setup_venv.sh`、`ctl.sh` 把整理服务部署到 Spark 并启动。服务只监听 Spark 的 `127.0.0.1:8765`。
- 健康检查结果：模型为 `qwen3.6-35b-a3b-nvfp4`，Skill 有 event-assign、event-brief、home-rank、screenshot-read，以及可选的 recall。
- 这个提交加了决定去重和回归测试，改动集中在 `spark/organizer/{api,decisions,schemas,store}.py` 和 `spark/tests/`，另外把 `ctl.sh` 设为可执行。

**Mac 端（`bestASR`，分支 `codex/spark-organizer-bridge`，提交 `1b8ee66`，20 个文件，约 +1724 行）**

在独立的 worktree 里开发。新增文件：

- `BestASRDomain/RemoteOrganizer.swift`
- `BestASRPersistence/GRDBRemoteOrganizerStore.swift`
- `App/RemoteOrganizerRuntime.swift`，负责 SSH 子进程、隧道和持久发送
- `App/DictationAppModel+RemoteOrganizer.swift`
- 测试 `RemoteOrganizerPersistenceTests.swift` 和 `RemoteOrganizerRuntimeTests.swift`

主要改动：

- **数据库迁移：** `v19-remote-organizer`（user_version 19）新增待发队列、决定、事件投影、人物、问题和游标这几张表。
- **设置页：** 新增「我的 DGX Spark 整理」开关和链路状态显示。
- **事件页：** 新增单独标注的 Spark 区块，显示拉回的事件和待确认问题。
- **文档：** 同步更新了 `IMPLEMENTATION_STATUS.md` 和 `docs/architecture/TECHNICAL_DESIGN.md`。
- **Release 构建修复：** 构建时 Xcode 会额外编译一份 x86_64，而仓库原有的 SenseVoice `Float16` 快速路径只适用于 Apple Silicon。这里给它加了架构条件，arm64 的推理路径不变。

两个提交在会话结束时都还只在本地，之后已推到远端同名分支。

## 实测数字

- Spark 服务端测试：会话开始时 43 项通过（用的是模拟模型），加了去重测试后 45 项通过。
- 手动冒烟测试：经 SSH 隧道送出一条虚构口述（一家虚构咖啡馆的开业筹备）。真实 Qwen 模型返回了事件标题和进度，来源记录里带有 Skill 版本和 prompt 哈希。
- 同一个合成纠正决定连续发送两次：两次都返回成功，但只应用了一次。
- 端到端测试：托管 App 测试用临时合成库，自己开 SSH 隧道，送出条目，再从 `/v1/state` 拉回事件投影，耗时约 6.2 秒。测试结束后本地转发端口已关闭。
- Mac 持久化测试 57 项通过。迁移测试覆盖旧版本 12–18，共 6 项通过。
- Debug 和 Release 构建都通过。
- 隐私扫描和权限检查通过：3 项能力、2 条用途说明，entitlements 保持最小。
- 新增的桥接文件通过严格格式检查。仓库整体仍有 618 条原有格式诊断。
- 会话结束时的 Spark 健康状态：4 个条目（全部是合成数据）、1 个事件、队列为 0。

## 遗留问题与下一步

- **Spark 端缺删除接口。** 目前不能删除 Spark 上已收到的源条目，在普通私人资料库上使用之前必须补上。
- **素材入口和首页还没做。** 缺粘贴/拖入文字、截图、PDF 等文档的入口，也缺「回忆」首页和事件导出。
- **完整门禁没跑完。** `script/check.sh` 在预检阶段就停了：构建盘剩余空间约 17 GiB，而仓库要求至少 25 GiB。需要腾出空间后重跑，还要处理原有的格式问题。UI 测试也还没跑。
- **还没做安装版验收。** 没有安装新版 App；真实断网、重连、撤销等场景还要在安装后的 Release 版上验证。
- **真实模型的 Skill 评测**还没有结果。现有测试不能当作模型效果的证据。
- **参赛材料**：README、演示视频、征文都还没有。比赛仓库目前是私有的，需要公开。截止时间是北京时间 9 月 29 日 23:59。
- **公开前统一提交作者信息**（公开时使用干净快照）。
