# ADR-0008：Agent 读取织机用自写的 MCP（JSON-RPC 2.0），不引入 SDK

- 状态：Accepted（v7 Agent 读取，AGENT-CONTRACT §1）
- 日期：2026-09-30
- 范围：Mac App 与随 App 分发的 `mindloom-mcp`（`Contents/Helpers/`）。包内新增目标 `MindloomAgentProtocol`（协议、工具定义、套接字）、`BestASRAgentAccess`（App 一侧的服务）、可执行 `mindloom-mcp`，以及只给测试用的 `MindloomAgentTestHost`。iPhone App 不涉及。

## 决策

MCP 在这里只用到很小的一块：stdio 上逐行的 JSON-RPC 2.0，方法只有 `initialize`、`ping`、`tools/list`、`tools/call`、`resources/list`、`resources/read`、`resources/templates/list` 和两三个通知；服务端不向客户端发请求（不用 sampling、elicitation、roots、进度、订阅），也不走 HTTP。这一块自己写，只用 Foundation 和 Darwin：

- `JSONValue`：解析用 `JSONSerialization`（区分整数、布尔、浮点，请求 id 原样送回），输出自己写：键排序、非 ASCII 原样、控制字符与 U+2028/2029 转义，保证一条消息一行。
- `MCPMessage`：请求、通知、响应、错误响应、无效消息；不接受批量（MCP 2025-06-18 已去掉）、不接受 null id。
- 协议版本：回应客户端请求的版本（2025-11-25、2025-06-18、2025-03-26、2024-11-05 之一），否则回最新的那个，由客户端决定是否继续。没有握手就直接调用也照常处理。
- 工具的 JSON Schema 写在代码里，同时存一份在 `schemas/agent/mindloom-mcp-tools.json`，测试断言两者相同。

## 候选方案

| | 自写（选用） | 官方 Swift SDK（modelcontextprotocol/swift-sdk） |
|---|---|---|
| 许可证 | 本仓库 | MIT |
| 额外依赖 | 无 | swift-log、swift-system，以及 HTTP 传输带来的 swift-nio 等（按所选产品） |
| 最低系统 | macOS 14（与 App 相同） | macOS 13 起，但 SDK 自身快速迭代，0.x 版本，API 常变 |
| 我们要的部分 | 约 900 行（协议、工具定义、套接字、离线应答），全部有测试 | 需要再包一层：SDK 的 Server 默认直接读写 stdio，而我们的服务端在 App 里，stdio 在另一个进程（helper），中间是 Unix 套接字；授权、审计、遮挡都要插在每个调用上 |
| 协议升级 | 改一个版本列表；新方法按需加 | 跟随 SDK 升级，可能牵连 API 变化 |
| 供应链与审计 | 没有新的第三方代码进入 App 和 helper | helper 会链接第三方代码，它运行在 Agent 的进程树里，处理的是主人的资料 |

结论：需要的协议面很窄，而且安全关键的部分（每次调用的授权、范围、遮挡、审计、套接字对端检查）无论用不用 SDK 都得自己写。自写避免给 App 和 helper 增加任何第三方依赖，也不必跟一个 0.x SDK 的变化。以后如果需要 HTTP 传输、服务端发起的请求或 MCP 扩展（Tasks、Apps），再评估 SDK。

## 运行时行为

- **helper（`mindloom-mcp`）**：由 Agent 以 stdio 启动；不存资料、不带密钥、不联网。它只连 `<数据目录>/agent/mindloom.sock`：连之前检查文件夹是本用户的且权限 0700、套接字是本用户的且 0600，连上后用内核的对端凭据（`LOCAL_PEERCRED`、`LOCAL_PEERPID`）加 libproc（`proc_pidinfo`）确认在听的进程属于本用户。数据目录默认是账户数据库里的主目录下的 `Library/Application Support/bestASR`，开发版可用 `MINDLOOM_DATA_ROOT` 指到别的绝对路径。App 不在时，它自己回答握手和工具列表，每个工具调用返回“织机没有在运行，请先打开织机”；App 中途退出时，正在进行的调用也这样回答；App 回来后下一次调用自动重连，并把客户端原来的握手重放一次。stderr 只写连接出了什么事，不写内容。
- **App 一侧（`AgentSocketServer` + `AgentAccessService`）**：在私有文件夹里监听（绑定时收紧 umask，套接字 0600；已有的文件夹若不是 0700 就改成 0700，不是本用户的就不监听）。每个连接先做同样的对端检查，不通过就直接断开、不读一个字节。客户端身份 = MCP `clientInfo.name` + App 自己用 libproc 查到的 helper 父进程的可执行文件路径（版本号文件夹折叠成 `*`）。
- 每次 `tools/call` 和资源读取都当场查授权（撤销、到期在下一次调用生效），在范围内作答，号码默认按遮挡规范 v3 换成占位符（每个授权一把占位符钥匙：`HMAC-SHA256(授权密钥, "mindloom-agent-mask-v1")`），并写一行审计（不含内容）。
- 授权：`agent_grants` 行只存范围，外加用授权密钥做的 `HMAC-SHA256` 校验；密钥是 32 字节随机数，存在登录钥匙串（service `com.bestasr.agent-grant`，account = 数据目录身份 hash + 授权 id，`AfterFirstUnlockThisDeviceOnly`，不同步）。测试和端到端运行用 0600 文件（只允许带 `SYNTHETIC_DATA_ROOT` 标记、且不在真实资料库里的目录）。“这一次”的授权只在内存里，随连接结束。

## 最低系统

macOS 14（App 的部署目标）。用到的系统接口：`LOCAL_PEERCRED`/`LOCAL_PEERPID`（macOS 10.8 起）、libproc、Security（钥匙串）、UserNotifications（通知，macOS 10.14 起）。

## 分发影响

- `mindloom-mcp` 是 App 里的一个 Mach-O 工具（arm64），随 App 一起签名；源码与 SwiftPM 产品 `mindloom-mcp` 相同（XcodeGen 目标 `MindloomMCP` 直接编译 `Packages/BestASRCore/Sources/MindloomMCPHelper`），只链接 `MindloomAgentProtocol`。Debug 构建约 0.5 MB。
- 没有新的第三方许可证；`THIRD-PARTY-NOTICES.md` 不变。
- Claude Code 插件（`integrations/claude-code-plugin`）和 Claude Desktop 扩展清单（`integrations/claude-desktop`）只是配置和说明文字，不含代码依赖；扩展里的 `server/mindloom-mcp.sh` 只是找到并 `exec` App 里的 helper。

## 隐私行为

- 没有云端入口，也不监听任何网络端口；只有本机、本用户的 Unix 套接字。
- Agent 读到的内容会由 Agent 背后的服务处理，离开这台 Mac：这是用户在同意窗口里明确选择的（PRD §0.3 第 11 条），窗口和设置页都写明。音频、声纹、个人词典永远不给；给的只有文字。
- 审计只记客户端、时间、工具、结果、返回的事 id、字节数；不记查询词、标题或任何正文。Agent 收件箱里的建议在主人决定前保存正文，决定后删除正文（收下的成为一条来源为 `agent:<名字>` 的资料）。
- 这些表都是本机表（schema v25），不进可移植归档，也从不发往整理设备。
