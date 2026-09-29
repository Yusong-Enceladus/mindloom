# ADR-0001：原生、模块化 macOS 运行时

- 状态：Accepted（原生模块化运行时）；Inference XPC：Proposed / Conditional
- 日期：2026-07-23

## 决策

V1 使用 Swift 6、SwiftUI、必要的 AppKit/Accessibility/Core Audio 互操作，构建原生 Apple Silicon macOS App。纯领域、存储接口、模型接口和基准代码放入本地 Swift Packages；App、XPC、UI Test、资源、entitlements 与发布配置由 Xcode workspace 管理。

捕获和持久化保留在可靠主进程；推理通过 `InferenceService` 协议隔离。`SPIKE-XPC-001` 支持继续采用嵌入式 XPC 作为 V1 候选边界，但该选择在真实模型、16 GB 内存压力、Developer ID 签名与公证通过前保持 Conditional，不视为冻结。

MVP 先交付口述用户闭环，但不建立独立运行时或领域分支。首个切片就使用 V1 的会话、音频 journal、修订、人物、持久化、durable job、模型 artifact 与未来同步协议；线下录音、系统音频和导入媒体通过来源适配器逐步接入同一核心。

## 理由

- Process Tap、Accessibility、菜单栏、多窗口、签名与公证都是 macOS 原生能力。
- Swift 模块可在未来 iPhone 端复用领域、存储、模型与同步协议。
- 显式协议和 CLI probe 让代理能独立构建、测试和定位边界问题。

## SPIKE-XPC-001 证据与裁决

- 相同的 32 MiB touched-allocation workload 各执行五次：同进程 P50 为 22,856,708 ns，XPC worker P50 为 22,969,542 ns；一次测得的 XPC 协议/往返开销为 100,125 ns。
- 同进程分配的峰值与保留 RSS 增量均为 33,587,200 bytes。XPC worker 的峰值/退出前保留增量约 33.65 MB；强制 worker 退出被观测，随后健康检查恢复，主进程在退出前后 RSS 仅变化 16,384 bytes。
- 同进程 SIGABRT fixture 会终止承载进程；XPC worker 强制退出不终止主 App，连接恢复后可继续执行作业。
- 嵌入式 XPC 增加第二个签名 code object；本地 ad-hoc App 与 XPC 签名均通过 Security.framework 有效性检查，但这不能替代 Developer ID、公证与发布包验证。
- 四个比较场景全部通过，综合结论为 `conditional`。证据：`artifacts/evidence/SPIKE-XPC-001/comparison.json`（SHA-256 `fbfb0c561644a1ee83819639f60189e564a4e7c20d1fd104ff1a302460d1ccdc`）。

冻结 XPC 前必须用实际 ASR、说话人和 LLM 模型重复延迟、模型文件共享与 16 GB 内存压力测试，并通过 Developer ID/公证门槛。若任一发布门槛失败，保持同一 `InferenceService`、取消/超时、durable job 与幂等结果语义，把 scheduler adapter 切回同进程 actor。

## 未选择

- Electron/Tauri：跨平台不是 V1 目标，且增加音频/AX 桥接与分发层。
- Python 运行时：违反零依赖安装边界。
- 单一巨大 App target：会让模型 SDK、UI、数据库和音频生命周期耦合，降低可测试性。

## 后果

- 必须安装完整 Xcode 并维护签名/entitlement 测试。
- AppKit/Core Audio 的 unsafe 边界需集中封装、单独测试。
- 若 XPC 不可行，仍保持同一协议和幂等作业语义，不把模型类型泄漏到领域层。
- 不允许用 MVP 专用人物类型、数据库 schema 或一次性任务队列换取短期口述进度；功能按阶段开放不等于核心架构按阶段重写。
