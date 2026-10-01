# ADR-0007：手机端 SSH 投递用 apple/swift-nio-ssh + Network.framework

- 状态：Accepted（手机端 v6，PHONE-CONTRACT §1、§5）
- 日期：2026-09-30
- 范围：只有 iOS App「织机」链接这些依赖（`Packages/MindloomPhoneKit` 的 `MindloomInboxSSH` 目标）。键盘扩展、分享扩展和 Mac App 都不链接；Mac 端只用 `Packages/MindloomLink`（仅 CryptoKit + Foundation，无第三方依赖）。

## 决策

手机把封好的收件箱条目（`mlseal1.`）经 SSH 送到用户自己的 Spark，执行 `zhiji-inbox add --sealed --id <entry_id> --json`，stdin 是 wire 字符串。实现用：

| 包 | 精确版本 | 修订 | 许可证 | 用途 |
|---|---|---|---|---|
| apple/swift-nio-ssh | 0.15.0 | `3ec281496f28a3b6581afd946b759e2642f5cd8d` | Apache-2.0 | SSH 客户端协议（密钥交换、主机密钥校验、公钥认证、session/exec、direct-tcpip） |
| apple/swift-nio-transport-services | 1.28.0 | `67787bb645a5e67d2edcdfbe48a216cc549222d5` | Apache-2.0 | 用 Network.framework 建 TCP 连接 |
| apple/swift-nio | 2.103.0 | `21de5f08c1a166a6dd293d0e587ad977bf8dac5d` | Apache-2.0 | 事件循环与 Channel（NIOPosix 只在测试里用来起进程内服务器） |
| apple/swift-crypto | 4.5.2 | `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | Apache-2.0 | 在 Apple 平台上直接转用 CryptoKit（ed25519 密钥类型） |
| 传递依赖：swift-atomics 1.3.1、swift-collections 1.7.1、swift-system 1.8.1、swift-asn1 1.7.3 | 见 `Packages/MindloomPhoneKit/Package.resolved` | | Apache-2.0 | NIO 内部 |

直接依赖都在 `Package.swift` 里 `exact:` 固定，完整解析结果（含传递依赖的修订）在 `Packages/MindloomPhoneKit/Package.resolved`。iOS 工程通过本地包引用它们，Xcode 不另写 Package.resolved；2026-09-30 核对 Xcode 的 `workspace-state.json`，解析出的 8 个包与上表版本、修订完全一致。传递依赖只能在 NIO 允许的范围内浮动，升级任何一个都要重跑本 ADR 的验证。

跳板机（relay）不靠库：先连 relay（校验 relay 的固定主机密钥，用手机密钥认证），开一个 `direct-tcpip` 通道到 `spark.host:spark.port`，再在这个通道里跑第二个完整的 SSH 客户端（校验 Spark 的固定主机密钥，再认证）。relay 只看到加密的 SSH 字节流。实现约 40 行（`InboxSSHSender.openSparkThroughRelay`）。

## 候选方案对比

| | apple/swift-nio-ssh（选用） | Citadel 0.12.1（orlandos-nl） |
|---|---|---|
| 许可证 | Apache-2.0 | MIT |
| 维护 | Apple SwiftNIO 团队；0.15.0 发布于 2026-07-28，仓库 2026-09-25 仍有提交 | 个人维护；0.12.1 发布于 2026-04-04，最后提交 2026-06-12 |
| SSH 核心 | 就是它本身 | 依赖**第三方个人 fork** `Wellz26/swift-nio-ssh` 0.3.x，而非 Apple 上游 |
| 额外依赖 | swift-nio、swift-crypto、swift-atomics（均为 Apple） | 另加 BigInt、swift-log、ColorizeSwift（示例用但会被解析）、C 语言 bcrypt 目标、`_CryptoExtras`（RSA） |
| 跳板机 | 无现成 API；用 `direct-tcpip` + 嵌套 `NIOSSHHandler` 自己接（与 Citadel 的 `jump(to:)` 同一做法） | `SSHClient.jump(to:)`，内部同样是 direct-tcpip + 嵌套 handler |
| ed25519 用户密钥 | `NIOSSHPrivateKey(ed25519Key:)` | 支持 |
| 固定主机密钥 | `NIOSSHClientServerAuthenticationDelegate` 直接比对 | `SSHHostKeyValidator.custom` 可做 |
| 进程内测试服务器 | 同一个库的 server 角色 | 有 SSHServer，但同样基于那个 fork |

结论：Citadel 唯一省事的地方（跳板机）在上游 NIO SSH 上也只是几十行；为此引入一个个人维护的 SSH 核心 fork 和四个用不到的包（SFTP、RSA、TTY、服务端）不值得。上游 NIO SSH 的供应链更短、全部来自 Apple。

## 运行时行为

- **只有 App 进程联网**，只在投递时：App 变为活跃、每次键盘出字之后（语音会话让 App 在后台活着）、`BGAppRefreshTask`。键盘扩展和分享扩展只写 App Group 里的 outbox，不含任何网络代码。
- 只连配对码里的主机和端口（relay 或 Spark），没有其他网络请求，没有遥测、崩溃上报或更新检查。
- 用 Network.framework（NIO Transport Services）建连：在 iOS 上它能唤起蜂窝网络和按需 VPN，BSD socket 不能。`waitForActivity = false`：没有网络路径或被拒绝时立刻失败，条目留在 outbox，下次触发再送；不在 `.waiting` 里挂到超时。
- 超时：每跳 TCP 连接 15 秒、握手加认证 20 秒；每条 `add` 30 秒加每 MiB 2 秒。超时就关掉连接，所有挂起的 promise 随之失败。
- 算法（NIO SSH 0.15.0）：密钥交换 `curve25519-sha256`（及 `@libssh.org`）、`ecdh-sha2-nistp256/384/521`；传输加密只有 `aes128-gcm@openssh.com` / `aes256-gcm@openssh.com`；主机和用户密钥为 ed25519 或 ECDSA，**不支持 RSA**。Spark 上默认的 OpenSSH（Ubuntu）都支持；Mac 端生成配对码时必须取 ed25519（或 ECDSA）主机密钥行，`SSHHostKey` 会拒绝 `ssh-rsa`。
- 一条连接可连送多条；每条一个 session 通道。stdout 最多读 64 KiB、stderr 4 KiB。stdin 最大为 `MindloomSeal.maximumWireBytes`（48,000,008 字节）。
- 回复解析：接受 `{"ok":true,"id":…}` 和现有 Spark 的 `{"ok":true,"inbox_id":…,"duplicate":…}`；重复 id 算成功；回复里的 id 与条目不符算协议错误，不算送达。

## 最低系统

- 上游：swift-nio-ssh iOS 13 / macOS 10.15；NIO Transport Services iOS 12 / macOS 10.14。
- 本项目：iOS App 与扩展 iOS 26.0（SpeechAnalyzer 所需）；包同时声明 macOS 14，只为在 Mac 上 `swift test`。

## 分发影响

- 全部是源码，Release 构建静态链进 App 可执行文件。实测（Xcode 27.0，Release，arm64，未签名未 strip）：App 可执行文件 9.34 MB，键盘和分享扩展各约 0.54 MB（它们同样含 MindloomLink/MindloomPhoneKit，但不含 SSH）。据此 SSH 这一套约占 App 可执行文件 8.8 MB 的上限，App Store 瘦身和压缩后会更小。
- Apache-2.0 要求随 App 附带许可证和 NOTICE：App 阶段在「隐私/关于」页或 Settings bundle 里加致谢，文本取自各包仓库的 `LICENSE.txt` / `NOTICE.txt`。Mac App 的 `THIRD-PARTY-NOTICES.md` 和 `config/dependencies.json` 不变（Mac 不链接这些包）。
- NIO SSH 仍是 0.x：小版本可能改 API，所以精确固定，升级要重跑 `MindloomInboxSSHTests`。

## 隐私行为

- 手机的 ed25519 私钥只在连接期间从 Keychain 读进内存（配对存储见 PHONE-CONTRACT §4），不写日志，`PairingPayload` 的 `description`/`debugDescription`/`dump` 都把它遮掉。
- 主机密钥只认配对码里固定的那把：不匹配就在密钥交换阶段断开，手机密钥根本不会被提交，什么也不发送。没有首次信任（TOFU），也不读任何 known_hosts。
- Spark 上 `authorized_keys` 把手机密钥限制为 `zhiji-inbox gate`；relay 上只允许转发到 Spark 的端口。手机端也只会发出一种命令：两个可变部分（gate 路径、小写 UUID）都先校验，不会带入 shell 语法。
- 送出的内容永远是 `mlseal1.` 密文：relay 只见 SSH 加密流，Spark 只见封好的 blob，只有 Mac 的私钥能打开。错误只记录不含内容的类别（`DeliveryErrorCategory`）和简短技术说明。

## 验证

- `MindloomInboxSSHTests`（21 个，macOS `swift test` 与 iOS 26.5 模拟器 `xcodebuild test` 都通过）：进程内 NIO SSH「Spark」模拟 `zhiji-inbox gate`（exec + stdin + 退出码），进程内「relay」只允许 direct-tcpip 到指定目标。覆盖：wire 原样送达、同一连接多条、重复 id 算成功、现有回复格式、Spark/relay 主机密钥不符都被拒（手机密钥未提交、Spark 未被连接）、手机密钥未授权、relay 拒绝目标、gate 拒绝单条后连接仍可用、exec 被拒、非 JSON 与错 id 回复、静默 gate 超时、无人监听立即失败、25 MiB 文档经 relay 两层 SSH 完整送达、outbox → relay → Spark 端到端且 Spark 上只有密文（明文哨兵检查）。
