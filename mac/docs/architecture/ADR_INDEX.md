# Architecture Decision Records

| ADR | 状态 | 决策 |
|---|---|---|
| [ADR-0001](decisions/ADR-0001-native-modular-runtime.md) | Accepted | 原生模块化运行时；口述优先 MVP 复用完整 V1 核心 |
| [ADR-0002](decisions/ADR-0002-sqlite-grdb-storage.md) | Proposed | SQLite/GRDB、FTS5 与显式迁移/change log |
| [ADR-0003](decisions/ADR-0003-audio-journal-timebase.md) | Proposed / Conditional | 分轨、单调时间与短块 crash-safe journal；真实双源/物理设备矩阵完成前不接受 |
| [ADR-0004](decisions/ADR-0004-benchmark-gated-inference.md) | Accepted | 模型适配层、四入口统一人物语义与基准门槛先于具体模型冻结 |
| [ADR-0005](decisions/ADR-0005-sync-ready-local-first.md) | Accepted | V1 本地优先，未来同步通过稳定变更协议接入 |
| [ADR-0006](decisions/ADR-0006-export-and-portable-archive.md) | Accepted（参数待 Spike） | 原始音频导出、完整加密迁移归档与未来云同步分离 |
| [ADR-0007](decisions/ADR-0007-phone-ssh-delivery.md) | Accepted | 手机端经 apple/swift-nio-ssh + Network.framework 投递封好的收件箱条目；跳板机用 direct-tcpip 自行嵌套，主机密钥只认配对码 |
| [ADR-0008](decisions/ADR-0008-agent-mcp-hand-rolled.md) | Accepted | Agent 读取织机用自写的 MCP（JSON-RPC 2.0，stdio + 本机 Unix 套接字），不引入 SDK；helper 随 App 分发，不存数据 |

状态含义：`Accepted` 冻结原则；`Proposed` 仍需 Spike 证据；具体模型、版本、阈值和编码不会因为原则 ADR 被提前冻结。
