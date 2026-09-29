# SPIKE-MIG-001：非破坏音频导出与可移植加密归档

## 问题

验证 bestASR 是否能够在不改写保留源音频的前提下导出整段或无损区间，并使用不依赖来源 Mac Keychain 的用户秘密，把版本化、认证加密的 `.bestasrarchive` 恢复到独立本地密钥身份。

## 运行

```sh
swift run \
  --package-path Packages/BestASRCore \
  --scratch-path .build/SwiftPM \
  PortableMigrationProbeCLI \
  --summary artifacts/evidence/SPIKE-MIG-001/summary.json \
  --matrix artifacts/evidence/SPIKE-MIG-001/matrix.json
```

探针只创建隔离的临时 Keychain，并在退出时销毁。所有 fixture 都是确定性的合成数据，不含真实用户音频、逐字稿、词典、人物或声纹数据。

## 已验证

- 导入原文件、本机捕获音轨整段导出与源数据字节一致。
- PCM16 WAV 时间范围导出生成有效无损片段，且源 digest 不变。
- PBKDF2-HMAC-SHA256（100,000 次）与 AES-256-GCM 容器不暴露 fixture 明文；目标端使用自己的本地主密钥重新封装导入资产。
- 无来源 Keychain 的独立身份恢复保留 UUID、revision、tombstone、人物操作、词典、整理结果、设置和音频 digest。
- 错误秘密、篡改、截断、空间不足、取消和模拟 kill 均不产生部分提交或明文 staging。
- 重复导入幂等，N-1 schema 可迁移到当前 schema。

## 结论

当前结论为 `conditional`。探针足以确认 ADR-0006 的归档边界和失败语义可实现，但 PBKDF2 参数不等同于生产口令 KDF 决策。发布前还需冻结内存困难 KDF/口令恢复体验，并补充多 GB 流式、真实磁盘满、真实第二 macOS 用户和全部发布音频格式矩阵。

机器可读证据：

- `artifacts/evidence/SPIKE-MIG-001/summary.json`
- `artifacts/evidence/SPIKE-MIG-001/matrix.json`
