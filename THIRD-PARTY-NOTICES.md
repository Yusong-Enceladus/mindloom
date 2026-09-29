# Third-Party Notices

织机 Mindloom本身以 Apache-2.0 发布（见 [LICENSE](LICENSE)）。本文件汇总仓库两部分用到的第三方代码、模型和数据。

- **Mac 客户端**的完整清单（每个依赖的版本、revision、用途、是否随 App 分发）在 [mac/THIRD-PARTY-NOTICES.md](mac/THIRD-PARTY-NOTICES.md)，许可证全文和 NOTICE 文件在 [mac/Legal/](mac/Legal/)。它们必须随代码一起分发，不要删除。
- **仓库不包含任何模型权重、音频或语料音频。** 模型都由使用者在接受各自许可后自行下载：Mac 端由 App 在首次启动时按固定 revision 从 Hugging Face 下载并校验大小与摘要；Spark 端由部署者自行下载。本项目不再分发任何模型。

## 模型

| 模型 | 用途 | 运行位置 | 获取方式 | 许可（按仓库记录） |
|---|---|---|---|---|
| Qwen3-ASR 1.7B 8-bit（`mlx-community/Qwen3-ASR-1.7B-8bit`，MLX 转换） | 口述与会议识别 | Mac | App 运行时下载，不再分发 | Apache-2.0（固定 revision 的模型卡；`mac/Legal/Qwen3-LICENSE-Apache-2.0.txt`） |
| Qwen3-ForcedAligner 0.6B 8-bit（`mlx-community`） | 字级时间对齐 | Mac | App 运行时下载，不再分发 | Apache-2.0 |
| Qwen3 1.7B MLX 4-bit | 本机文本润色 / 指令 | Mac | App 运行时下载，不再分发 | Apache-2.0，Copyright 2024 Alibaba Cloud |
| SenseVoice-Small int8（FluidInference Core ML 转换），Paraformer-large（候选） | 实时字幕 / 中文识别候选 | Mac | App 运行时下载，不再分发 | FunASR Model License 1.1（`mac/Legal/FunASR-MODEL-LICENSE-1.1.txt`；须署名 Alibaba / FunASR 并保留模型名） |
| Fluid speaker-diarization Core ML（基于 pyannote community-1） | 说话人分离与声纹 | Mac | App 运行时下载，不再分发 | CC-BY-4.0（`mac/Legal/Fluid-Speaker-Diarization-MODEL-NOTICE-CC-BY-4.0.txt`） |
| Parakeet Unified EN 0.6B Core ML | 英文识别候选 | Mac | 运行时下载，不再分发 | CC-BY-4.0（`mac/Legal/Fluid-Parakeet-Unified-MODEL-NOTICE-CC-BY-4.0.txt`） |
| 个人口述整理模型（Qwen3 小模型 LoRA） | 可选的口述清理 | Mac | 用使用者本人数据在本机训练；**不公开、不分发** | 基座 Apache-2.0 |
| Qwen3.6-35B-A3B NVFP4 | 整理主力模型 | DGX Spark | 部署者自行下载，不再分发 | 仓库未记录，使用前以其模型卡为准 |
| Qwen3.6-35B-A3B Q8_0（GGUF） | 对照模型 | DGX Spark | 部署者自行下载，不再分发 | 仓库未记录，以模型卡为准 |
| Qwen3-Embedding-0.6B | 候选检索向量 | DGX Spark | 部署者自行下载，不再分发 | 仓库未记录，以模型卡为准（<https://huggingface.co/Qwen/Qwen3-Embedding-0.6B>） |
| DeepSeek-V4-Flash | 对照模型（双机 TP2） | DGX Spark | 部署者自行下载，不再分发 | 仓库未记录，以模型卡为准 |
| Step3-VL-10B（StepFun）Q8_0 | 读截图对照 | DGX Spark | 部署者自行下载，不再分发 | 仓库未记录，以模型卡为准 |

评测专用（不随 App）：WhisperKit large-v3 Core ML（MIT）与 `openai/whisper-large-v3` tokenizer（Apache-2.0），见 `mac/THIRD-PARTY-NOTICES.md`。以下模型没有核实到许可，**不得再分发**，仓库里只有标识和摘要：`argmaxinc/speakerkit-coreml`、独立的 3D-Speaker embedding ONNX、预编译 ONNX Runtime 包。

## Mac 客户端代码依赖（摘要）

随 App 静态链接：GRDB.swift 7.10.0（MIT）、FluidAudio 0.15.5（Apache-2.0）、MLX Swift 0.31.3（MIT）、MLX Swift LM 3.31.3（MIT）、MLX Audio Swift `cae704f`（MIT，Copyright (c) 2025 Prince Canuma；`AlphaASREvalCLI/QwenASRFileTranscriber.swift` 中有据此改写的加载代码）、Swift Transformers 1.3.3 与 Swift Jinja 2.4.2（Apache-2.0）、Swift Hugging Face 0.9.0（Apache-2.0）、Swift Numerics / Collections / Atomics（Apache-2.0）、Swift Crypto 4.5.1（Apache-2.0 + NOTICE）、SwiftNIO 2.101.3（Apache-2.0 + NOTICE）、EventSource 1.4.1（MIT）、yyjson 0.12.0（MIT）、Swift Compatibility Span 运行时（Apache-2.0 with Runtime Library Exception）。

仅开发或探针使用、不随 App：XcodeGen 2.45.3（MIT）、SwiftSyntax 600.0.1、swift-asn1、swift-system（Apache-2.0）、CMake 4.4.0（BSD-3-Clause）、SQLCipher.swift 4.16.0（BSD 风格社区版，仅 SPIKE-SEC-001）、sherpa-onnx 1.13.2（Apache-2.0，传递依赖 NOTICE 清单尚未完成，仅外部探针）、Argmax OSS / WhisperKit 1.0.0（MIT，仅评测）。

## Spark 端整理服务依赖

在 `spark/pyproject.toml` 中声明，安装时从 PyPI 获取，不随仓库分发：FastAPI（MIT）、Uvicorn（BSD-3-Clause）、Pydantic（MIT）、HTTPX（BSD-3-Clause）、PyYAML（MIT）、pytest（MIT，仅测试）、Pillow（MIT-CMU / HPND，仅评测截图工具）。

推理引擎单独运行、不随仓库分发：vLLM（Apache-2.0）、llama.cpp（MIT）。

## 数据

- `eval/scenarios/` 的全部场景、人名、对话和 8 张聊天截图都是为本项目虚构的合成数据。截图由 `eval/tools/render_screenshots.py` 渲染，渲染时优先使用系统的 PingFang 字体，缺失时用 Noto Sans CJK（SIL OFL-1.1）；仓库只含渲染出的图片，不含字体文件。
- Mac 端公开语料只以清单和摘要引用，不含音频或文本：AMI Meeting Corpus（CC-BY-4.0）、Google FLEURS（CC-BY-4.0），署名见 `mac/Legal/`。

## 商标

NVIDIA、DGX Spark、Apple、Qwen、DeepSeek、StepFun、腾讯会议、微信、Typeless 等名称只用于说明兼容性或做指称性比较，不表示任何背书。
