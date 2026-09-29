# SPIKE-XPC-001：版本化推理 XPC 边界

## 问题

验证嵌入主 App 的 XPC 推理服务能否执行显式协议版本协商、取消和超时，在 worker 强制退出后重启并重放 durable job，同时不阻断主进程 AudioJournal 或产生重复结果提交。

## 运行

```sh
script/run_xpc_probe.sh
```

探针只传递合成 job 元数据、音频 range digest 和结果 digest；不通过 XPC 传递音频、逐字稿、人物或窗口数据。

## 矩阵

- 当前版本 health check 与不兼容版本拒绝。
- 取消后无 result digest，超时后连接失效且晚到结果不提交。
- worker 调用 `_exit(86)`，主进程继续提交 AudioJournal；新 XPC 进程健康检查通过并重放同一 job。
- 同一 idempotency key 的两个响应只产生一个逻辑提交。
- 同一 32 MiB touched-allocation “model load” workload 运行 5 次，比较同进程与 XPC worker 的 P50、峰值/释放后 RSS、IPC overhead、崩溃域和实际 ad-hoc code object 验证。

机器可读证据：

- `artifacts/evidence/SPIKE-XPC-001/summary.json`
- `artifacts/evidence/SPIKE-XPC-001/matrix.json`
- `artifacts/evidence/SPIKE-XPC-001/comparison.json`
