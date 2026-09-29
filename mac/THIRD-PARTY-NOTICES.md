# Third-Party Notices

The bestASR executable statically links or bundles the runtime libraries identified below.
SenseVoice, Paraformer, Fluid speaker-diarization, and Qwen model weights are not bundled in the current app; users may
install only the exact-pinned local artifacts after accepting their licenses.
Probe-only and build-only dependencies are explicitly marked.

## XcodeGen 2.45.3

- Use: development-only Xcode project generation; not included in the app or distribution.
- Source: <https://github.com/yonaskolb/XcodeGen/tree/2.45.3>
- License: MIT
- Attribution: Copyright (c) 2016 Kyle Fuller

The exact version, local artifact digest, runtime/network behavior, and distribution impact are recorded in `config/dependencies.json`.

## GRDB.swift 7.10.0

- Use: production local SQLite/WAL persistence, migrations, recovery, history, dictionary storage, and FTS.
- Source: <https://github.com/groue/GRDB.swift/tree/v7.10.0>
- License: MIT
- Attribution: Copyright (C) 2015-2025 Gwendal Roué

The exact tag, revision, source-tree digest, runtime/network behavior, and shipping status are recorded in `config/dependencies.json` and `Packages/BestASRCore/Package.resolved`.

## SQLCipher.swift 4.16.0

- Use: isolated `SPIKE-SEC-001` encrypted-database probe; not currently linked into the app or distribution.
- Source: <https://github.com/sqlcipher/SQLCipher.swift/tree/4.16.0>
- License: BSD-3-Clause-style Community Edition license; bundled SQLite is public domain.
- Attribution: Copyright (c) 2025, ZETETIC LLC. All rights reserved.

The exact tag, official binary checksum and size, minimum OS, runtime/network behavior, and current non-shipping status are recorded in `config/dependencies.json` and `Packages/BestASRCore/Package.resolved`.

## CMake 4.4.0

- Use: development-only generator for the external sherpa-onnx probe; not required by the app or on a user's Mac.
- Source: <https://github.com/Kitware/CMake/tree/v4.4.0>
- License: BSD-3-Clause
- Attribution: Copyright 2000-2026 Kitware, Inc. and Contributors

The locally used arm64 development binary digest and non-shipping status are recorded in `config/dependencies.json`.

## FluidAudio 0.15.5

- Use: production Swift/Core ML ASR, offline diarization, and speaker-embedding runtime plus external evidence probes at commit `19600a485baa4998812e4654b70d2bab8f2c9949`.
- Source: <https://github.com/FluidInference/FluidAudio/tree/19600a485baa4998812e4654b70d2bab8f2c9949>
- License: Apache-2.0
- Runtime license text: `Legal/FluidAudio-LICENSE-Apache-2.0.txt`
- ASR model: `SenseVoiceSmall_int8` from `FluidInference/sensevoice-small-coreml` at revision `0e0bf30bfc6836f182ccd1d89984df919c949e26`.
- Mandarin ASR candidate: `Paraformer-large` int8 from `FluidInference/paraformer-large-zh-coreml` at revision `5dd557bd06342a3cd07ceccb909d8a45e48b053a`.
- English ASR candidate: `Parakeet Unified EN 0.6B` int8 from `FluidInference/parakeet-unified-en-0.6b-coreml` at revision `4252711f6f060f9a2f91e5f081a806d7f45eebd8`, CC BY 4.0. Attribution and modification status are retained in `Legal/Fluid-Parakeet-Unified-MODEL-NOTICE-CC-BY-4.0.txt`.
- ASR model license: `LicenseRef-FunASR-Model-1.1`, pinned from the official FunASR repository at commit `d1007c323068d0c5aaa8e0f198668aaebc1a4fc2`. The complete bilingual text is retained in `Legal/FunASR-MODEL-LICENSE-1.1.txt`.
- ASR attribution: SenseVoice and Paraformer / FunASR model source and author, Alibaba Group. Both model names must be retained.
- Speaker model: `FluidInference/speaker-diarization-coreml` at `1ed7a662fdc7109e36d822db793ee6eebdaf8594`, CC-BY-4.0, based on `pyannote/speaker-diarization-community-1`.
- Speaker-model attribution and modification notice: `Legal/Fluid-Speaker-Diarization-MODEL-NOTICE-CC-BY-4.0.txt`.
- Speaker-model source and license URI: <https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/1ed7a662fdc7109e36d822db793ee6eebdaf8594> and <https://creativecommons.org/licenses/by/4.0/>.

The runtime source revision and license digests, every production model file size and SHA-256, deny-network behavior, model-tree digests, and current non-bundled status are recorded in `config/dependencies.json`, `config/model-artifacts.json`, the candidate registries, and their evaluation summaries. SenseVoice int8 is the dictation ASR default; the Fluid offline diarizer is the single local speaker pipeline for every input mode. Real-corpus quality, recommended-memory, and signing/notarization gates remain release requirements.

## MLX Swift 0.31.3

- Use: local tensor, neural-network, CPU, and Metal execution for transcript polish.
- Source revision: `61b9e011e09a62b489f6bd647958f1555bdf2896`.
- License: MIT; local text: `Legal/mlx-swift-LICENSE-MIT.txt`.
- Attribution: Copyright (c) 2023 ml-explore.

## MLX Swift LM 3.31.3

- Use: exact-pinned local Qwen model construction and bounded generation.
- Source revision: `1c05248bb0899e2a7a4962b84d319cf12f4e12aa`.
- License: MIT; local text: `Legal/mlx-swift-lm-LICENSE-MIT.txt`.
- Attribution: Copyright (c) 2024 ml-explore.
- Model: Qwen3 1.7B MLX 4-bit at `21457c6f51ed54a7c16e988c0844db973815c137`, Apache-2.0, Copyright 2024 Alibaba Cloud. The normalized license snapshot is `Legal/Qwen3-LICENSE-Apache-2.0.txt`.

The Qwen artifact is user-provisioned and verified file-by-file. Real generation was evaluated with outbound networking denied; the selected hybrid pipeline produced 0 factual failures, 0 generation failures, and 0 deterministic-repeat mismatches across 24 invocations.

## Swift Transformers 1.3.3

- Use: local Qwen tokenizer JSON, BPE vocabulary, merge table, and chat-template loading.
- Source revision: `2fa33e1f5e7131a7fc64c28e6d161dcec0d24820`.
- License: Apache-2.0; local text: `Legal/swift-transformers-jinja-LICENSE-Apache-2.0.txt`.
- Privacy note: its `Tokenizers` target links a network-capable Hub closure. bestASR accepts only a model-manager-verified local URL and never invokes a Hub download API; this is covered by deny-network evidence.

## Swift Numerics 1.1.1

- Use: numeric primitives used by MLX.
- Source revision: `0c0290ff6b24942dadb83a929ffaaa1481df04a2`.
- License: Apache-2.0; local text: `Legal/Apple-Swift-LICENSE-Apache-2.0.txt`.

## Swift Jinja 2.4.2

- Use: renders the pinned local Qwen chat template.
- Source revision: `7d0b8880ef8e567dd4e0089f8b99fb354129017c`.
- License: Apache-2.0; local text: `Legal/swift-transformers-jinja-LICENSE-Apache-2.0.txt`.

## Swift Hugging Face 0.9.0

- Use: statically linked through Tokenizers; no repository client is instantiated by bestASR.
- Source revision: `b721959445b617d0bf03910b2b4aced345fd93bf`.
- License: Apache-2.0; local text: `Legal/swift-huggingface-LICENSE-Apache-2.0.txt`.

## Swift Collections 1.6.0

- Use: ordered/deque collections in the tokenizer closure.
- Source revision: `a0cb0954ecb21e4e31b0070e6ed5674e8556685a`.
- License: Apache-2.0; local text: `Legal/Apple-Swift-LICENSE-Apache-2.0.txt`.

## Swift Crypto 4.5.1

- Use: hashing support in the tokenizer Hub target.
- Source revision: `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6`.
- License: Apache-2.0; local text: `Legal/swift-crypto-nio-LICENSE-Apache-2.0.txt`.
- Required bundled-source notices: `Legal/swift-crypto-NOTICE.txt`.

## yyjson 0.12.0

- Use: local tokenizer JSON parsing.
- Source revision: `8b4a38dc994a110abaec8a400615567bd996105f`.
- License: MIT; local text: `Legal/yyjson-LICENSE-MIT.txt`.
- Attribution: Copyright (c) 2020 YaoYuan.

## EventSource 1.4.1

- Use: network-capable transitive type code linked by Swift Hugging Face; no bestASR call site instantiates it.
- Source revision: `a3a85a85214caf642abaa96ae664e4c772a59f6e`.
- License: MIT; local text: `Legal/EventSource-LICENSE-MIT.txt`.
- Attribution: Copyright 2025 Mattt.

## SwiftNIO 2.101.3

- Use: transitive EventSource support; bestASR creates no event loop, channel, socket, or client.
- Source revision: `0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b`.
- License: Apache-2.0; local text: `Legal/swift-crypto-nio-LICENSE-Apache-2.0.txt`.
- Required third-party notices: `Legal/swift-nio-NOTICE.txt`.

## Swift Atomics 1.3.1

- Use: atomic primitives in the transitive SwiftNIO closure.
- Source revision: `0442cb5a3f98ab802acb777929fdb446bda11a34`.
- License: Apache-2.0; local text: `Legal/Apple-Swift-LICENSE-Apache-2.0.txt`.

## Swift ASN.1 1.7.1

- Use: exact-resolved cryptography source; not linked into the current bestASR target graph.
- Source revision: `a9a5efd40eaf558a2bcd48d64b1d1646be686008`.
- License: Apache-2.0; local text: `Legal/swift-asn1-LICENSE-Apache-2.0.txt`.
- Required third-party notices: `Legal/swift-asn1-NOTICE.txt`.

## Swift System 1.7.5

- Use: exact-resolved transitive source; not linked into the current bestASR target graph.
- Source revision: `50688cacbd41d547e9eb9f7a213542340b7c442b`.
- License: Apache-2.0; local text: `Legal/swift-system-LICENSE-Apache-2.0.txt`.

## SwiftSyntax 600.0.1

- Use: build-time macro dependency resolved by MLX Swift LM; not embedded in the app.
- Source revision: `0687f71944021d616d34d922343dcef086855920`.
- License: Apache-2.0; local text: `Legal/Apple-Swift-LICENSE-Apache-2.0.txt`.

## Swift Compatibility Span Runtime 6.2

- Use: Swift `Span` back deployment from the app's macOS 14.2 deployment target.
- Toolchain identity: Apple Swift 6.4 in Xcode 27.0 (27A266a), embedding the Swift 6.2 compatibility runtime.
- Upstream source reference: Swift 6.2 release commit `1ff1cc1170617ab23ab74aa8b741c8daca1903f6`.
- License: Apache-2.0 with Swift Runtime Library Exception; normalized local text: `Legal/Apple-Swift-LICENSE-Apache-2.0.txt`.
- Distribution: Xcode copies and signs `Contents/Frameworks/libswiftCompatibilitySpan.dylib`; the pristine toolchain and final packaged digests are checked separately.

The Runtime Library Exception waives the usual binary-product attribution requirements. The notice and license remain here to make the packaged runtime explicit and auditable.

## MLX Audio Swift — Qwen3 local speech runtime

- Source: `https://github.com/Blaizzy/mlx-audio-swift`, exact revision `cae704f53bc32a3d0b606823828fbc5bedaaf388`.
- License: MIT, Copyright (c) 2025 Prince Canuma. Retain `Legal/MLX-Audio-Swift-LICENSE-MIT.txt` for the SDK, adapted in-memory tokenizer/model loader and greedy decoding implementation.
- Runtime / minimum OS: native Swift 6.2, MLX Metal on Apple Silicon; upstream declares macOS 14 / iOS 17. bestASR remains macOS 14.2+, and its pinned MLX 0.31.3, MLX Swift LM 3.31.3 and Transformers 1.3.3 must not change for this comparison.
- Scope / distribution: the native `BestASRQwenRuntime` boundary and developer `AlphaASREvalCLI` link `MLXAudioSTT` and its Core/Codecs/VAD modules. The App's final-ASR candidate uses actor-owned, bounded, cancellation-aware public forward calls, not an SDK detached streaming producer. Source and build output use the existing external SwiftPM root; no Python, Homebrew or command-line runtime is introduced into the App. Weights are separately installed, not embedded in the App. Integration does not establish release eligibility.
- Privacy: load only ModelManager-verified local files, construct the tokenizer in memory, never call the SDK's Hub/pretrained download entry points, and validate inference under a parent deny-all-network sandbox. The SDK's general-purpose downloader and logging paths are not authorized to upload audio, text, dictionary or identity data. Normal operation has no remote inference or telemetry.
- Candidate weights/tokenizer: `mlx-community/Qwen3-ASR-1.7B-8bit`, revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`, converted from Qwen3-ASR-1.7B by mlx-audio 0.3.1; Apache-2.0 according to that exact model card. The existing standard Apache-2.0 license text is retained at `Legal/Qwen3-LICENSE-Apache-2.0.txt`. Development models and redownloadable caches stay external; activated user models stay in the local managed-model store.
- Alignment candidate: `mlx-community/Qwen3-ForcedAligner-0.6B-8bit`, exact revision `0e1a68e91d815300c7c9754b2a7639378b23db15`, Apache-2.0 according to its pinned model card; same native SDK, license text and offline loading boundary. Public AMI comparison is against automatically aligned timing references, not human phonetic boundaries; see `Legal/AMI-Corpus-NOTICE-CC-BY-4.0.txt`. No private audio or speaker data is downloaded or uploaded.

## Argmax OSS / WhisperKit 1.0.0

- Use: developer-only Swift/Core ML ASR evaluation and the earlier external SpeakerKit probes at commit `25c62997041c134b03ca82731ce2f6fd2cae1eb9`; only `AlphaASREvalCLI` links WhisperKit/ArgmaxCore, not the app or distribution.
- Source: <https://github.com/argmaxinc/argmax-oss-swift/tree/v1.0.0>
- License: MIT
- Attribution: Copyright (c) 2024 argmax, inc.
- Developer ASR comparison: Core ML `openai_whisper-large-v3-v20240930_626MB` from `argmaxinc/whisperkit-coreml` revision `0f63a7800b00dd0226abd051b906c246e1907482` is MIT-licensed by the pinned model card; retain `Legal/Argmax-WhisperKit-LICENSE-MIT.txt`. Its separate `openai/whisper-large-v3` tokenizer at `06f233fe06e710322aca913c1bc4249a0d71fce1` is Apache-2.0 according to its pinned OpenAI model card. The standard Apache-2.0 text is already retained in `Legal/Qwen3-LICENSE-Apache-2.0.txt`; that filename does not attribute the Whisper tokenizer to Qwen. Both file sets are verified in `config/whisper-asr-evaluation-models.json`, remain external, and are not App-shipping selections.
- Speaker model: `argmaxinc/speakerkit-coreml` at `86ec9c929b52208b6656eb6a6361ed0d822a1f78`; the pinned model repository provides no license field or license file, so redistribution is prohibited pending an authoritative license.

The locally built probe binary digest, pinned ASR/model/tokenizer and SpeakerKit tree digests, deny-network behavior, and current non-shipping status are recorded in the candidate registries and recommended-memory smoke evidence.

## sherpa-onnx 1.13.2

- Use: external static ONNX Runtime CPU ASR, speaker diarization, and speaker embedding probes at commit `13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24`; not linked into the app or distribution.
- Source: <https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.2>
- License: Apache-2.0; linked transitive license/NOTICE inventory remains a release blocker.
- Provider note: the pinned runtime reported that the requested Core ML provider fell back to CPU, so no Core ML acceleration is claimed.
- Speaker models: the pyannote segmentation archive includes an MIT notice; the standalone 3D-Speaker embedding ONNX file has no adjacent authoritative license or notice, so redistribution is prohibited pending audit.

The locally rebuilt macOS 14.2 arm64 probe digests, model archive/tree digests, deny-network behavior, and current non-shipping status are recorded in the candidate registries and recommended-memory smoke evidence. The downloaded prebuilt ONNX Runtime archive did not contain its license text; distribution remains prohibited until the authoritative license/NOTICE set is captured and verified.
