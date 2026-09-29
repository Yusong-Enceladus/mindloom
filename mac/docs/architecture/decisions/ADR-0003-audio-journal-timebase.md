# ADR-0003：分轨、单调时间与 crash-safe AudioJournal

- 状态：Proposed（综合结论为 conditional）
- 日期：2026-07-23

## 决策

麦克风、系统音频和任何派生混音使用独立 track。每个音频块保存单调 host time、帧范围、源格式、连续序号、摘要与不连续原因。录音以短块原子提交，最终文件是派生资产，不能覆盖已提交原块。

## 理由

- 双轨来源、暂停、设备切换与崩溃恢复都要求比单一 M4A 文件更明确的时间语义。
- 单调时间不受墙钟和时区变化影响。
- 短块使 kill、磁盘满和容器损坏的损失上界可测。

## 待验证

- PCM、CAF/ALAC 或其他格式的恢复性、磁盘和 CPU 取舍。
- 目标块长（初始上限 2 秒）与 `fsync` 策略。
- Process Tap 与麦克风跨时钟 drift、aggregate device 和重采样策略。

## 当前证据

`SPIKE-CAP-001` 的已解锁实机矩阵为 `pass`：8/8 场景通过。选中 App 水印可检出，非选中 App 水印保持在阈值以下；同 bundle helper、来源退出重启和静音均不中断边界。显式 opt-in 的真实 HDMI 默认输出切换产生两次监听通知，切换前与第二输出期间均检出 15.3 kHz 水印，303,616 个捕获帧无丢帧，随后恢复原默认输出；探针不读取或保存设备名称、UID 与对象 ID。独立签名 bundle 的真实 TCC 拒绝也通过：macOS 26.5.2 在拒绝后允许 I/O 回调继续运行，但 94 次回调的 48,000 帧全部为精确数字零，RMS 与 18.3 kHz 水印振幅均为 0。探针结束后 tap 与 aggregate device 增量均为 0。

`SPIKE-TIM-001` 的确定性双轨 fixture 已验证：每块保留 source track、sequence、原始 host time、单调纳秒、采样率、帧数和 SHA-256；合成脉冲在 44.1/48 kHz 两个独立时钟域中以 host time 对齐，最大绝对误差 9,956 ns，已知 -50 ppm drift 的测量误差低于 0.001 ppm；采样率变化和 150 ms 设备 gap 均创建显式 segment boundary。

`SPIKE-JRN-001` 已验证两轨短块的 staging fsync → atomic rename → manifest fsync/rename 顺序：只有 manifest durable commit 后才发布 inference range。截断、digest 损坏、重复 sequence 与缺块均进入 gap/recovery-required；12 个固定 seed 以真实 `SIGKILL` 覆盖 partial write、staging sync、chunk rename 和 manifest commit 四个边界以及两条轨，所有已提交块可读，最大未提交损失 190.375 ms，且没有损坏会话被标记 complete。

同一 Spike 的 2 小时合成双轨耐久矩阵为 `pass`：实测 7,200,005,241,250 ns，提交并最终重开校验 7,199 个块，dropped frame 为 0；注入一次麦克风断开/重连后记录 1 个显式 gap，系统轨继续提交；峰值常驻内存 157,171,712 bytes、CPU 123.334815 秒、最大 thermal state 为 nominal。该结果证明 journal/恢复与资源采样可以连续运行两小时，但合成源不能替代真实麦克风 + Process Tap 同采、物理设备切换或 16 GB 机器门禁。

`SPIKE-WRK-001` 的有界实时队列/持久化 lease 矩阵为 `pass`：队列容量 2，高水位 2；溢出的 8 个实时请求进入 degraded-live，但 10 个源块与 durable catch-up job 全部保留；worker lease 过期后由新 owner 恢复同一 job，崩溃期间第 11 个源块继续提交；重复响应只产生一个 transcript commit，重连后 10 个作业全部幂等完成。

综合结论：`conditional`。因此本 ADR 不进入 Accepted，依赖“实机捕获已完全成立”的承诺不得放行。安装版麦克风与 Process Tap 分轨同采以及通用默认输出切换已经通过；物理采样率/输入设备切换、16 GB 机器资源门禁和剩余真实会议生命周期仍由后续实机任务完成。

以下 canonical SHA-256 将本次裁决绑定到具体证据内容。规范化只移除每次运行必然变化的 `runID` 和 `generatedAt`，其余状态、场景和指标全部参与摘要；任何语义证据变化都必须同步更新本表并重新执行交叉检查。

| 证据 | SHA-256 | 记录结论 |
|---|---|---|
| `artifacts/evidence/SPIKE-CAP-001/summary.json` | `539998837b27ad06c35bcb7111cd1ccb532fdc7936e4d721987ae04c7b02aa25` | pass |
| `artifacts/evidence/SPIKE-CAP-001/matrix.json` | `32ef95e09648d22ef0c986cbce0b5c620aa7802e7d366e611a2d9bb1da22f20b` | matrix |
| `artifacts/evidence/SPIKE-CAP-001/tcc-denial.json` | `6b466eef3dddc54b99b583973c0df269e1104a443e589c8ade1d40f5c438bbd1` | pass |
| `artifacts/evidence/SPIKE-TIM-001/summary.json` | `2aa0f0d85044f4af314d6b407f891b19bfd2a415f554966cdd376ce65d3cb9c8` | conditional |
| `artifacts/evidence/SPIKE-TIM-001/matrix.json` | `a18a916d63632dee391673e7cb64488243e4678acddcca0f6ede83bf512df022` | matrix |
| `artifacts/evidence/SPIKE-JRN-001/summary.json` | `3e4c4852bbaaa8b849d2ce38f584f646a7038888f9fac3b3d598b1542f546ac4` | conditional |
| `artifacts/evidence/SPIKE-JRN-001/matrix.json` | `191bbd7f60f7c3ce4585e992b79ad921c4ba1eb460c1bc877d33682372cf99b8` | matrix |
| `artifacts/evidence/SPIKE-JRN-001/long-recording.json` | `945b47c77f1f52f6998f128737a10504e060e0fe801cd1e3ef01ba91e11c9e32` | pass |
| `artifacts/evidence/SPIKE-WRK-001/summary.json` | `86827bd60db6d36cdb1d7114b631d823d9ecb86b3dd3e81b945028ef20ea3e57` | pass |
| `artifacts/evidence/SPIKE-WRK-001/matrix.json` | `bc5ac9929909817ee23c7b7a12e7e870a18fb586a727a7d136cfec658882465b` | matrix |

证据路径：

- `artifacts/evidence/SPIKE-CAP-001/summary.json`
- `artifacts/evidence/SPIKE-CAP-001/matrix.json`
- `artifacts/evidence/SPIKE-CAP-001/tcc-denial.json`
- `artifacts/evidence/SPIKE-TIM-001/summary.json`
- `artifacts/evidence/SPIKE-TIM-001/matrix.json`
- `artifacts/evidence/SPIKE-JRN-001/summary.json`
- `artifacts/evidence/SPIKE-JRN-001/matrix.json`
- `artifacts/evidence/SPIKE-JRN-001/long-recording.json`
- `artifacts/evidence/SPIKE-WRK-001/summary.json`
- `artifacts/evidence/SPIKE-WRK-001/matrix.json`

## 后果

- 需要 manifest/compaction/recovery 代码和更多小文件治理。
- 导出与播放器必须能透明读取分块逻辑资产。
