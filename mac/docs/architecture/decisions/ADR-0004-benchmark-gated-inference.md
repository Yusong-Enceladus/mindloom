# ADR-0004：模型由基准门槛选择

- 状态：Accepted
- 日期：2026-07-22

## 决策

ASR、VAD、diarization、speaker embedding 和 LLM 都通过版本化 Swift 协议接入。任何具体 SDK/模型进入默认 release manifest 前，必须在相同设备、相同语料和相同指标上比较，并通过许可、包体、离线、崩溃恢复和签名测试。

Speaker adapter 对口述、线下麦克风、系统音频和导入媒体输出同一种 `SessionSpeaker`、`SpeakerOccurrence` 与全局 `Person` 语义；单人只是一簇。评估语料必须以同一批说话人覆盖四类入口及 1/2/3 人口述，入口可采用不同调度预算，但不得使用不同身份空间、置信门槛或纠错规则。默认纯文字插入是独立呈现测试，不得用它省略内部人物证据。

## 理由

- 公开榜单不能代表中英文句内混输、App 内录、远场会议和事实保真。
- 2026 年原生候选快速变化，提前绑定会使产品逻辑和历史数据被某个模型污染。
- 模型输出必须带 artifact ID 和输入 revision，才能重算与审计。

## 后果

- 第一批工程产物必须包括 BenchCLI、语料 manifest、聚合报告和回归阈值。
- 说话人报告必须包含跨入口 Person 一致率、错误合并/拆分/拒绝、口述多人分段和 label-free insertion 与最终人物证据解耦结果。
- UI 不显示技术模型选择；内部可按硬件档自动选已验证组合。
- ASR 与 speaker candidate registry、fixture/model digest 及 ASR/speaker/LLM/resource report 由 `validate_inference_evidence.sh` 交叉校验。三套固定版本真实 ASR runtime/model 已完成断网三样本冒烟；三套 speaker runtime/model 也已完成断网九样本 diarization 与 22 样本 identity 合成冒烟并保存聚合证据。后者三者均零已知错认且拒绝全部陌生人，但覆盖率/延迟取舍明显，且仍缺 16 GB、授权真人、device-lab、完整 corpus/release holdout、热/长会话、许可和包装矩阵。因此两个 registry 都保持无默认项、所有候选 `releaseEligible: false`；这是一项阻断结论，不是默认候选选择。
