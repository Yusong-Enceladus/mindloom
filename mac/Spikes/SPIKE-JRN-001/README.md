# SPIKE-JRN-001：双轨 crash-safe AudioJournal

## 问题

验证短块 AudioJournal 是否只在 chunk 与 manifest 都耐久提交后发布 inference range，并在真实 `SIGKILL` 落在随机写入点后保留全部已提交块、隔离未提交尾部且不把损坏会话标记完整。

## 运行

```sh
script/run_audio_journal_probe.sh
```

探针仅写入临时目录中的合成 PCM bytes。子进程会按固定 seed 在 partial staging、staging fsync、chunk rename 或 manifest commit 后向自身发送 `SIGKILL`；父进程随后重新打开同一 journal 并执行恢复。

## 矩阵

- 正常双轨 finalize 与 durable inference publication。
- 截断块、digest 损坏、重复 sequence、缺块与 orphan 文件。
- 12 个版本化 seed 的真实 kill/restart，覆盖四个写入边界。
- 每个 seed 断言全部 manifest-committed chunk 可读、gap 不被伪造为完整、未提交损失不超过正在写入的一个短块。

## 结论

当前结论为 `conditional`。原子 rename、文件/目录同步和恢复语义已通过合成故障矩阵；最终编码、块长、物理磁盘满、两小时录音与 sleep/wake 仍待后续设备矩阵。

机器可读证据：

- `artifacts/evidence/SPIKE-JRN-001/summary.json`
- `artifacts/evidence/SPIKE-JRN-001/matrix.json`
