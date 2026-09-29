# SPIKE-CAP-001：Core Audio Process Tap 捕获边界

## 问题

验证 macOS Core Audio Process Tap 是否能够只捕获用户选中的 App，并在同一 App 的 helper/子进程新增、来源退出重启和静音期间维持明确、可恢复的生命周期。

## 实现边界

- Swift 控制面枚举 HAL audio process，并按 bundle identity 聚合为应用。
- 私有 `CATapDescription` 和私有 aggregate device 只存在于探针进程生命周期内。
- 实时 IO 回调位于预分配 C++ 缓冲，不在回调中分配、记录日志或运行推理。
- 两个独立签名的合成播放器 App 注入不同高频水印；证据只保存幅度、计数和合成生命周期，不保存音频或本机 App 身份。

HAL 生命周期参考 Apple 官方样例 [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)。本次核对的官方样例包 SHA-512 为：

`02fe64305fe77d8ba7cd5549cb2b7a5f8dfcbc078cf9b0bcff69adb6ee21f754e4f835161f532b39e58bb051a76a5b65b4c1db99e0d56cda3fb20e7c68c20d80`

## 运行

```sh
script/run_process_tap_probe.sh
```

首次运行会由 macOS 请求系统音频录制权限。探针的 usage description 明确限定为它自己启动的合成播放器。

经操作者明确授权后，可执行真实默认输出切换矩阵：

```sh
script/run_process_tap_probe.sh --allow-output-device-switch
```

该模式只选择第二个存活的非虚拟、非 aggregate 输出；在水印捕获期间切换，监听 Core Audio 默认输出事件，然后在场景结束或错误退出时恢复原默认输出。证据只记录计数和布尔结果，不保存设备名称、UID 或对象 ID。

当前实机已用该 opt-in 参数在内置输出与 HDMI 物理输出之间完成真实切换：监听到切换与恢复两次通知，跨切换水印连续可读、丢帧为 0，且场景结束后恢复原默认输出。探针不再把受权限限制而不可读的设备名称、UID 或可选 `DeviceIsAlive` 诊断误判成“无物理输出”；选择仍要求 HAL 设备列表中的非空输出 stream，并明确排除 virtual 与 aggregate 端点。

真实 TCC 拒绝使用独立签名 bundle，避免重置或污染已授权的主探针：

```sh
script/build_process_tap_tcc_denial_probe.sh
```

构建不会请求权限。操作者必须从 LaunchServices 启动输出的 `.app`，在探针窗口点击开始，并在首次出现的 macOS 系统弹窗中亲自选择“不允许”；同一 bundle 已被拒绝后，系统不会重复弹窗。Apple 的权限提示发生在包含 tap 的 aggregate device 开始录制时，而不是创建 tap 时。探针因此按官方顺序创建临时 tap/aggregate、尝试启动 I/O，并接受两种失败关闭语义：I/O 启动直接被拒绝，或 I/O 回调继续运行但固定合成水印被系统替换为精确数字零。macOS 26.5.2 的实测路径为后者：94 次回调、48,000 帧、RMS 与 18.3 kHz 水印振幅均为 0。两条路径都要求 tap/aggregate 计数恢复到运行前值。探针只启动同目录的签名合成水印播放器，不落盘音频，并把尚未确认的聚合测量写到 `/private/tmp/bestasr-process-tap-tcc-denial.json`。操作者明确确认确实点击“不允许”后，才可执行：

```sh
script/confirm_process_tap_tcc_denial.sh --operator-confirmed-denial
script/run_process_tap_probe.sh \
  --allow-output-device-switch \
  --tcc-denial-evidence artifacts/evidence/SPIKE-CAP-001/tcc-denial.json
```

确认脚本无法替代人的系统弹窗动作，也不会运行 `tccutil reset`。若操作者误点允许、固定合成水印仍可读取、来源不是固定合成 App，或任一 HAL 计数变化，证据失败关闭。

## 当前裁决规则

自动矩阵验证选中/非选中水印、同 bundle 子进程、来源重启、静音等待、真实第二输出切换与恢复、拒绝授权阻止音频内容读取和 HAL 对象清理。默认命令不会修改用户的音频路由；带显式 opt-in 参数时才执行并恢复真实第二输出切换。只有全部场景通过、真实物理切换完成且使用已确认的真实 TCC 拒绝证据时，本 Spike 才裁决为 `pass`。Chrome/Tencent 的产品路径、长时资源矩阵和麦克风同采由各自安装包证据承担；Zoom、真实会议生命周期和 16 GB 最低设备门禁仍独立保持未完成。
