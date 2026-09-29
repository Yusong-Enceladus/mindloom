# SPIKE-WRK-001：有界实时队列与 durable worker lease

## 问题

验证推理变慢、队列满、worker 崩溃与重连时，捕获和 AudioJournal 是否继续提交，durable job 是否能够通过过期 lease 恢复，并以幂等键避免重复 transcript commit。

## 运行

```sh
script/run_inference_queue_probe.sh
```

## 已验证

- 实时队列容量固定为 2，高水位不会超过容量；溢出进入 `degraded-live`，而不是分配无界内存。
- 10 个源 chunk 全部先提交 AudioJournal，再创建 10 个 durable catch-up job；队列拒绝不会丢源音频。
- worker 持有 lease 后“崩溃”期间继续提交第 11 个源 chunk；store 重开并越过 lease deadline 后由新 owner 领取同一 job。
- 重复 worker 响应只生成一个以 `job type + input revision + model version + config hash` 标识的结果提交。
- 重连后剩余 backlog 全部成功且没有重复 transcript commit。

机器可读证据：

- `artifacts/evidence/SPIKE-WRK-001/summary.json`
- `artifacts/evidence/SPIKE-WRK-001/matrix.json`
