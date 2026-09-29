# ADR-0002：SQLite/GRDB 本地存储

- 状态：Proposed
- 日期：2026-07-22

## 建议决策

以 SQLite + GRDB 作为本地事实库，启用显式 schema migration、WAL、FTS5、durable jobs、audit/change log 和 tombstones。音频作为受 manifest 管理的分块资产，数据库保存稳定 UUID、相对引用、摘要和时间轴。

在接受此 ADR 前，必须证明 GRDB + SQLCipher、FTS5、XPC/多进程访问、崩溃恢复和 11,000+ 记录规模满足要求。

## 当前证据

- 2026-07-23：exact-pinned GRDB.swift 7.10.0 + 系统 SQLite probe 通过 WAL、外键、N-1→N、重复迁移幂等和事务中断回滚。
- 迁移前保留 byte-verified backup；注入中断后原 N-1 数据仍可读，恢复副本可在新路径打开。
- 结构化结果见 `artifacts/evidence/persistence/migration-summary.json`，版本化 schema contract 见 `Tests/Fixtures/Persistence/schema-fixture.json`。
- 2026-07-23：`SPIKE-SEC-001` 使用 exact-pinned SQLCipher.swift 4.16.0 Community XCFramework，运行时报告 `4.16.0 community`；官方归档大小 50,207,727 bytes，SHA-256 `510fd00fa51fb017909a159bb1cc233b012e8ce18dc9c2f09014fe47f557c1a6`。
- SQLCipher 页级探针通过静态明文扫描、正确/错误 key、不同 backup key 的 online backup、事务 migration rollback、单字节损坏检测，以及子进程在未提交事务中退出后的 WAL 恢复。已提交数据保持可读，未提交行没有出现。
- CryptoKit AES-GCM envelope 使用独立 data key、master-key wrapping 和 authenticated metadata；临时 macOS Keychain 探针通过 store/load/delete、错误 master key、ciphertext 篡改、文件备份、commit 前故障与无 staging 残留。Keychain 项丢失返回显式错误，未静默删除或重建加密数据。
- 10 个场景的结构化证据见 `artifacts/evidence/SPIKE-SEC-001/summary.json` 与 `matrix.json`；结论为 `conditional`，不是 ADR 接受。

该结果只支持继续评估，不接受本 ADR。尚未完成的冻结门槛是：让 GRDB 7.10.0 实际链接 SQLCipher 而非系统 SQLite、10,000 条口述 + 1,000 小时元数据的 FTS5 规模结果、XPC 多进程访问，以及携带 SQLCipher XCFramework 的 Hardened Runtime/签名/公证验证。临时测试 Keychain 使用已弃用的独立 `SecKeychain` API 以避免污染登录 Keychain；生产实现必须用现代 `SecItem` 访问控制重新验证，不收编测试容器代码。

## 理由

- 产品需要精确事务、全文搜索、复杂人物关系、可撤销操作和大量可重建派生数据。
- 显式 change log 适合未来 CKSyncEngine 或产品后端，而不把 V1 领域层绑定到某种账号。
- GRDB 同时支持 macOS/iOS、迁移、WAL、FTS5 和 SQLCipher 路径。

## 替代方案

- Core Data + `NSPersistentCloudKitContainer`：未来 iCloud 同步接入更快，但提前绑定 CloudKit/Core Data，对显式 FTS、复杂人物操作和可替换同步后端控制较弱。
- SwiftData：API 简洁，但当前项目更需要成熟迁移、显式 SQL/FTS 与精细故障注入。
- 裸 SQLite：依赖最少，但重复实现并发、迁移和类型安全会降低质量。

## 后果

- 未来同步需要实现映射层，不会自动获得 CloudKit mirroring。
- 必须维护 schema fixture、迁移回滚、完整性检查和加密恢复测试。
