# SPIKE-TIM-001：双轨 host-time 时间线

## 问题

验证麦克风与系统音频是否可以保留为两个独立 source track，并以单调 host time 对齐，同时把采样率变化、设备断开与 gap 表达为显式 segment boundary。

## 运行

```sh
script/run_audio_timeline_probe.sh
```

探针仅生成确定性合成脉冲和摘要，不申请麦克风权限、不捕获设备音频，也不保存真实设备身份。

## 已验证

- 两条独立时钟域、8 个 chunk 均记录 track、segment、sequence、host time、单调纳秒、采样率、帧数和 SHA-256。
- 44.1/48 kHz 合成脉冲的最大单轨误差为 9,956 ns，最大跨轨 skew 为 6,681 ns。
- 1,000 秒、-50 ppm 的已知 drift fixture 测量误差低于 0.001 ppm。
- 48→44.1 kHz 变化必须创建新 segment；静默改变采样率会被 validator 拒绝。
- 150 ms 麦克风热插拔 gap 创建明确边界并保留原 source track identity。

## 结论

当前结论为 `conditional`。它确认 ADR-0003 的字段和边界语义可实现，但不能替代真实麦克风与 Process Tap 同时采集、物理设备热插拔和两小时稳定性矩阵。

机器可读证据：

- `artifacts/evidence/SPIKE-TIM-001/summary.json`
- `artifacts/evidence/SPIKE-TIM-001/matrix.json`
