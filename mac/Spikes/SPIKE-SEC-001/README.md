# SPIKE-SEC-001：加密存储、密钥与恢复

该 Spike 比较两条仍未冻结的候选路径：

- SQLCipher 4.16.0 页级数据库加密；
- CryptoKit AES-GCM data key envelope，由临时 macOS Keychain 中的 master key 包装。

`script/run_security_storage_probe.sh` 只接受与 `config/dependencies.json` 中大小和 SHA-256 完全一致的官方 SQLCipher XCFramework。二进制解包到忽略 Git 的 `Artifacts/`，不会进入仓库或 App target。

矩阵覆盖静态明文扫描、正确/错误密钥、在线备份、事务 migration 回滚、损坏检测、未提交事务进程崩溃恢复、AEAD 篡改、原子 envelope 替换和 Keychain 丢失。结果写入 `artifacts/evidence/SPIKE-SEC-001/`。

该 Spike 的 `conditional` 结论不接受 ADR-0002；GRDB+SQLCipher 集成、规模化 FTS、XPC 和签名/公证仍须单独通过。
