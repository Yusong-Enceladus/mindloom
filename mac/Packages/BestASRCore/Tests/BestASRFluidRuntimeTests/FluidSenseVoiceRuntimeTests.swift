import BestASRBenchmark
import BestASRCandidateAdapters
import BestASRInference
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import XCTest

@testable import BestASRFluidRuntime

final class FluidSenseVoiceRuntimeTests: XCTestCase {
  func testCTCDecoderHonorsPaddedFloat16AndFloat32Rows() throws {
    for dataType in [MLMultiArrayDataType.float16, .float32] {
      let storage = UnsafeMutableRawPointer.allocate(byteCount: 32 * 4, alignment: 16)
      let logits = try MLMultiArray(
        dataPointer: storage, shape: [1, 4, 3], dataType: dataType,
        strides: [32, 8, 1], deallocator: { $0.deallocate() }
      )
      if dataType == .float16 {
        storage.bindMemory(to: Float16.self, capacity: 32).initialize(repeating: 30_000, count: 32)
      } else {
        storage.bindMemory(to: Float.self, capacity: 32).initialize(repeating: 30_000, count: 32)
      }
      let rows: [[Float]] = [[0, 3, 1], [0, 4, 1], [5, 0, 1], [0, 3, 1]]
      for (frame, row) in rows.enumerated() {
        for (token, value) in row.enumerated() {
          logits[[0, NSNumber(value: frame), NSNumber(value: token)]] = NSNumber(value: value)
        }
      }
      XCTAssertEqual(SenseVoiceCTCDecoder.tokenIDs(logits: logits, validFrames: 4), [1, 1])
      XCTAssertEqual(SenseVoiceCTCDecoder.tokenIDs(logits: logits, validFrames: 3), [1])
      XCTAssertEqual(SenseVoiceCTCDecoder.tokenIDs(logits: logits, validFrames: 0), [])
    }
  }

  func testASRComputePolicySeparatesFP32PreprocessingFromANEInference() {
    let preprocessing = FluidASRModelLoader.preprocessorConfiguration()
    XCTAssertEqual(preprocessing.computeUnits, .cpuAndGPU)
    XCTAssertFalse(preprocessing.allowLowPrecisionAccumulationOnGPU)
    XCTAssertEqual(FluidASRModelLoader.inferenceConfiguration().computeUnits, .cpuAndNeuralEngine)
  }

  func testInstalledPreprocessorsPreserveCommonSpeechAcrossInputLengths() throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let audioPath = environment["BESTASR_LANGUAGE_ACCEPTANCE_AUDIO"],
      let senseVoicePath = environment["BESTASR_SENSEVOICE_MODEL_DIRECTORY"],
      let paraformerPath = environment["BESTASR_PARAFORMER_MODEL_DIRECTORY"]
    else { throw XCTSkip("installed synthetic preprocessing fixture not configured") }
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(
      URL(fileURLWithPath: audioPath))
    XCTAssertGreaterThan(samples.count, 84_160)
    for (name, path) in [
      ("SenseVoicePreprocessor", senseVoicePath),
      ("ParaformerPreprocessor", paraformerPath),
    ] {
      let model = try FluidASRModelLoader.preprocessor(
        named: name, from: URL(fileURLWithPath: path))
      var reference: [Float] = []
      // Appending 20 ms of the same source must not rewrite its first 4.8 s.
      // The CPU-only artifact path changed thousands of these values and
      // produced empty or unstable transcripts for the 83,520-sample input.
      for length in [83_200, 83_520, 84_160, samples.count, 83_520] {
        let waveform = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float32)
        let pointer = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<length { pointer[index] = samples[index] * 32_768 }
        let output = try model.prediction(
          from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform])
        )
        let features = try XCTUnwrap(output.featureValue(for: "features")?.multiArrayValue)
        XCTAssertEqual(features.dataType, .float32)
        XCTAssertGreaterThanOrEqual(features.shape[1].intValue, 80)
        let prefix = (0..<(80 * 560)).map { index in
          features[[0, NSNumber(value: index / 560), NSNumber(value: index % 560)]].floatValue
        }
        XCTAssertTrue(prefix.allSatisfy(\.isFinite))
        if reference.isEmpty {
          reference = prefix
        } else {
          let maximumDifference = zip(reference, prefix).map { abs($0 - $1) }.max() ?? 0
          XCTAssertLessThanOrEqual(maximumDifference, 0.0001, "\(name): length \(length)")
        }
      }
    }
  }

  func testInstalledChineseAcceptanceFixtureReportsChineseLanguage() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let audioPath = environment["BESTASR_LANGUAGE_ACCEPTANCE_AUDIO"],
      let modelPath = environment["BESTASR_SENSEVOICE_MODEL_DIRECTORY"]
    else {
      throw XCTSkip("installed SenseVoice acceptance fixture not configured")
    }
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(
      URL(fileURLWithPath: audioPath)
    )
    let backend = try FluidSenseVoiceBackend(
      verifiedModelDirectory: URL(fileURLWithPath: modelPath)
    )
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: FixtureAudioLoader(samples: samples),
      backend: backend
    )
    let result = try await runtime.transcribe(
      makeRequest(),
      candidateID: "fluid-sensevoice"
    )

    XCTAssertEqual(result.detectedLanguage, "zh-CN")
    XCTAssertEqual(result.segments.count, 2)
    XCTAssertTrue(
      result.segments.allSatisfy { segment in
        segment.text.unicodeScalars.contains {
          (0x4E00...0x9FFF).contains(Int($0.value))
        }
      }
    )
  }

  func testInstalledMandarinFinalMeetsExistingCERGateAndPhraseTiming() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let audioPath = environment["BESTASR_LANGUAGE_ACCEPTANCE_AUDIO"],
      let modelPath = environment["BESTASR_PARAFORMER_MODEL_DIRECTORY"]
    else {
      throw XCTSkip("installed Paraformer acceptance fixture not configured")
    }
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(
      URL(fileURLWithPath: audioPath)
    )
    let runtime = FluidMonolingualASRRuntime(
      candidateID: FluidParaformerPinnedArtifact.candidateID,
      audioLoader: FixtureAudioLoader(samples: samples),
      backend: try FluidParaformerBackend(
        verifiedModelDirectory: URL(fileURLWithPath: modelPath)
      )
    )
    let result = try await runtime.transcribe(
      makeRequest(modelArtifactID: FluidParaformerPinnedArtifact.artifactID),
      candidateID: FluidParaformerPinnedArtifact.candidateID
    )
    let text = result.segments.map(\.text).joined()
    XCTAssertEqual(result.detectedLanguage, "zh-CN")
    XCTAssertEqual(result.segments.count, 2)
    // Use the existing corpus CER ceiling, not a new zero-error requirement
    // for a homophone. This fixture still has ordinary recognition errors;
    // the regression must reject dropped speech, wrong language, or collapse.
    // Score the raw lexical ASR stage; punctuation is added by local polish.
    let reference =
      "这是导入音频功能的第一位说话人我们正在验证本地转写"
      + "这是第二位说话人请确认原音可以播放时间戳可以定位"
    XCTAssertLessThanOrEqual(
      TranscriptScorer.score(reference: reference, hypothesis: text).character.rate, 0.15)
    for requiredTerm in ["第一", "第二", "本地", "播放", "时间", "定位"] {
      XCTAssertTrue(
        text.contains(requiredTerm), "missing synthetic reference term: \(requiredTerm)")
    }
    let repeated = try await runtime.transcribe(
      makeRequest(modelArtifactID: FluidParaformerPinnedArtifact.artifactID),
      candidateID: FluidParaformerPinnedArtifact.candidateID
    )
    XCTAssertEqual(repeated.segments, result.segments)
  }

  func testRawTranscriptionKeepsDetectedLanguageOutsideVisibleText() {
    XCTAssertEqual(
      SenseVoiceRawTranscriptionParser.parse(
        "<|zh|><|NEUTRAL|><|Speech|><|woitn|>这是测试。"
      ),
      SenseVoiceTranscription(
        text: "这是测试。",
        detectedLanguage: "zh-CN"
      )
    )
    XCTAssertEqual(
      SenseVoiceRawTranscriptionParser.parse(
        "<|en|><|HAPPY|><|Speech|><|woitn|>Hello."
      ),
      SenseVoiceTranscription(
        text: "Hello.",
        detectedLanguage: "en-US"
      )
    )
  }

  func testRuntimePropagatesDetailedDetectedLanguage() async throws {
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: FixtureAudioLoader(samples: [0.25, -0.25, 0]),
      backend: DetailedFixtureBackend(
        transcription: SenseVoiceTranscription(
          text: "这是中文。",
          detectedLanguage: "zh-CN"
        )
      ),
      activitySegmenter: fixtureActivitySegmenter
    )

    let output = try await runtime.transcribe(
      makeRequest(),
      candidateID: "fluid-sensevoice"
    )

    XCTAssertEqual(output.detectedLanguage, "zh-CN")
    XCTAssertEqual(output.segments.map(\.text), ["这是中文。"])
  }

  func testPinnedArtifactMatchesSupplyChainManifest() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/model-artifacts.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let models = try XCTUnwrap(root["models"] as? [[String: Any]])
    let model = try XCTUnwrap(
      models.first {
        $0["id"] as? String == FluidSenseVoicePinnedArtifact.artifactID
      }
    )

    XCTAssertEqual(
      model["exactVersion"] as? String,
      FluidSenseVoicePinnedArtifact.sourceRevision
    )
    XCTAssertEqual(
      model["treeSHA256"] as? String,
      FluidSenseVoicePinnedArtifact.treeSHA256
    )
    XCTAssertEqual(
      model["license"] as? String,
      FluidSenseVoicePinnedArtifact.descriptor.licenseIdentifier
    )
    XCTAssertEqual(model["totalSizeBytes"] as? Int, 239_918_735)
    XCTAssertEqual(
      model["treeDigestAlgorithm"] as? String,
      "sha256-shasum-path-list-v1"
    )
    let files = try XCTUnwrap(model["files"] as? [[String: Any]])
    XCTAssertEqual(files.count, 10)
    let paths = Set(files.compactMap { $0["relativePath"] as? String })
    XCTAssertTrue(
      paths.contains("SenseVoicePreprocessor.mlmodelc/model.mil")
    )
    XCTAssertFalse(paths.contains { $0.contains("SenseVoiceSmall_preprocessor") })
    XCTAssertFalse(FluidSenseVoicePinnedArtifact.descriptor.networkRequired)
  }

  func testProductionArtifactFlowsThroughCandidateAdapter() async throws {
    let loader = FixtureAudioLoader(samples: [0.25, -0.25, 0])
    let backend = FixtureBackend(text: "  你好 world  ")
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: loader,
      backend: backend,
      activitySegmenter: fixtureActivitySegmenter
    )
    let candidate = try fluidCandidate()
    let adapter = try FluidSenseVoiceASRAdapter(
      candidate: candidate,
      runtime: runtime,
      artifact: FluidSenseVoicePinnedArtifact.descriptor
    )
    let superseded = uuid(1)
    let request = makeRequest(supersedesRevisionID: superseded)

    let first = try await adapter.transcribe(request)
    let second = try await adapter.transcribe(request)
    let descriptor = await adapter.descriptor()
    let loadCount = await loader.loadCount()
    let capturedSamples = await backend.capturedSamples()
    let networkPolicy = await runtime.networkPolicy()

    XCTAssertEqual(
      descriptor.artifact,
      FluidSenseVoicePinnedArtifact.descriptor
    )
    XCTAssertEqual(first.modelArtifactID, FluidSenseVoicePinnedArtifact.artifactID)
    XCTAssertEqual(first.segments.map(\.text), ["你好 world"])
    XCTAssertEqual(first.segments.first?.monotonicStartNanoseconds, 1_000)
    XCTAssertEqual(first.segments.first?.monotonicEndNanoseconds, 2_000)
    XCTAssertEqual(first.revision?.supersedesRevisionID, superseded)
    XCTAssertEqual(first.revision?.operation, .replaceAudioRange)
    XCTAssertEqual(first, second, "replaying one durable job must be deterministic")
    XCTAssertEqual(loadCount, 2)
    XCTAssertEqual(capturedSamples, [0.25, -0.25, 0])
    XCTAssertEqual(networkPolicy, .modelManagerVerifiedArtifactsOnly)
  }

  func testLanguageSpecializedArtifactsMatchSupplyChainManifest() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/model-artifacts.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let models = try XCTUnwrap(root["models"] as? [[String: Any]])

    let paraformer = try XCTUnwrap(
      models.first {
        $0["id"] as? String == FluidParaformerPinnedArtifact.artifactID
      }
    )
    XCTAssertEqual(
      paraformer["exactVersion"] as? String,
      FluidParaformerPinnedArtifact.sourceRevision
    )
    XCTAssertEqual(
      paraformer["treeSHA256"] as? String,
      FluidParaformerPinnedArtifact.treeSHA256
    )
    XCTAssertEqual(paraformer["totalSizeBytes"] as? Int, 222_139_557)

    let parakeet = try XCTUnwrap(
      models.first {
        $0["id"] as? String == FluidParakeetUnifiedPinnedArtifact.artifactID
      }
    )
    XCTAssertEqual(
      parakeet["exactVersion"] as? String,
      FluidParakeetUnifiedPinnedArtifact.sourceRevision
    )
    XCTAssertEqual(
      parakeet["treeSHA256"] as? String,
      FluidParakeetUnifiedPinnedArtifact.treeSHA256
    )
    XCTAssertEqual(parakeet["totalSizeBytes"] as? Int, 614_086_243)
    XCTAssertFalse(FluidParaformerPinnedArtifact.descriptor.networkRequired)
    XCTAssertFalse(
      FluidParakeetUnifiedPinnedArtifact.descriptor.networkRequired
    )
  }

  func testMonolingualRuntimeUsesSharedOfflineAdapterBoundary() async throws {
    let loader = FixtureAudioLoader(
      samples: [Float](repeating: 0.25, count: 320)
    )
    let backend = FixtureBackend(text: "  hello world  ")
    let runtime = FluidMonolingualASRRuntime(
      candidateID: FluidParakeetUnifiedPinnedArtifact.candidateID,
      audioLoader: loader,
      backend: backend,
      activitySegmenter: fixtureActivitySegmenter
    )
    let adapter = PinnedOfflineASRAdapter(
      candidateID: FluidParakeetUnifiedPinnedArtifact.candidateID,
      capabilities: [.asrBatch, .asrRevisioned, .asrTimestamps],
      runtime: runtime,
      artifact: FluidParakeetUnifiedPinnedArtifact.descriptor
    )
    let request = makeRequest(
      modelArtifactID: FluidParakeetUnifiedPinnedArtifact.artifactID
    )

    let first = try await adapter.transcribe(request)
    let second = try await adapter.transcribe(request)
    let networkPolicy = await runtime.networkPolicy()
    let loadCount = await loader.loadCount()

    XCTAssertEqual(
      first.modelArtifactID,
      FluidParakeetUnifiedPinnedArtifact.artifactID
    )
    XCTAssertEqual(first.segments.map(\.text), ["hello world"])
    XCTAssertEqual(first, second)
    XCTAssertEqual(networkPolicy, .modelManagerVerifiedArtifactsOnly)
    XCTAssertEqual(loadCount, 2)
  }

  func testRuntimeRejectsWrongCandidateAndAudioFormatBeforeInference() async {
    let loader = FixtureAudioLoader(samples: [0])
    let backend = FixtureBackend(text: "ignored")
    let runtime = FluidSenseVoiceRuntime(audioLoader: loader, backend: backend)

    await assertFailure(
      category: .incompatibleArtifact,
      code: "sensevoice-candidate-id-mismatch"
    ) {
      _ = try await runtime.transcribe(
        self.makeRequest(),
        candidateID: "other"
      )
    }

    await assertFailure(
      category: .invalidRequest,
      code: "sensevoice-requires-16khz-mono"
    ) {
      let request = self.makeRequest(sampleRate: 48_000, channels: 2)
      _ = try await runtime.transcribe(
        request,
        candidateID: "fluid-sensevoice"
      )
    }
    let loadCount = await loader.loadCount()
    let backendCallCount = await backend.callCount()
    XCTAssertEqual(loadCount, 0)
    XCTAssertEqual(backendCallCount, 0)
  }

  func testBackendFailureIsCategorizedWithoutLeakingMessage() async {
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: FixtureAudioLoader(samples: [0.25]),
      backend: FailingBackend(),
      activitySegmenter: fixtureActivitySegmenter
    )
    await assertFailure(
      category: .transientRuntime,
      code: "sensevoice-runtime-failed"
    ) {
      _ = try await runtime.transcribe(
        self.makeRequest(),
        candidateID: "fluid-sensevoice"
      )
    }
  }

  func testFloat32LoaderVerifiesDigestPathFormatAndBounds() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-fluid-runtime-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporary,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporary) }

    let data = float32Data([0.5, -1, 1])
    let file = temporary.appendingPathComponent("range.f32le")
    try data.write(to: file, options: .atomic)
    let digest = sha256(data)
    let loader = try Float32PCMFileLoader(
      rootDirectory: temporary,
      maximumSamples: 3
    )
    let valid = audioInput(reference: "range.f32le", digest: digest)

    let loadedSamples = try await loader.loadSamples(for: valid)
    XCTAssertEqual(loadedSamples, [0.5, -1, 1])

    await assertFailure(
      category: .corruptInput,
      code: "sensevoice-audio-digest-mismatch"
    ) {
      _ = try await loader.loadSamples(
        for: self.audioInput(
          reference: "range.f32le",
          digest: String(repeating: "0", count: 64)
        )
      )
    }
    await assertFailure(
      category: .corruptInput,
      code: "sensevoice-unsafe-audio-reference"
    ) {
      _ = try await loader.loadSamples(
        for: self.audioInput(reference: "../range.f32le", digest: digest)
      )
    }

    let oversized = temporary.appendingPathComponent("oversized.f32le")
    let oversizedData = float32Data([0, 0, 0, 0])
    try oversizedData.write(to: oversized, options: .atomic)
    await assertFailure(
      category: .resourcePressure,
      code: "sensevoice-audio-range-too-large"
    ) {
      _ = try await loader.loadSamples(
        for: self.audioInput(
          reference: "oversized.f32le",
          digest: self.sha256(oversizedData)
        )
      )
    }
  }

  func testProductionSourceCannotCallAutomaticDownloadEntryPoints() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Packages/BestASRCore/Sources/BestASRFluidRuntime/FluidSenseVoiceRuntime.swift"
      ),
      encoding: .utf8
    )
    XCTAssertFalse(source.contains("SenseVoiceModels.download"))
    XCTAssertFalse(source.contains("SenseVoiceModels.downloadAndLoad"))
    XCTAssertFalse(source.contains("SenseVoiceManager.load("))
    XCTAssertTrue(source.contains("FluidASRModelLoader.senseVoice("))
    let loader = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Packages/BestASRCore/Sources/BestASRFluidRuntime/FluidASRModelLoader.swift"
      ),
      encoding: .utf8
    )
    XCTAssertFalse(loader.contains("download"))
    XCTAssertFalse(loader.contains("URLSession"))
    XCTAssertTrue(loader.contains("contentsOf: directory.appendingPathComponent"))
  }

  func testSpeakerRuntimeLoadsVerifiedModelsWithoutModelHubDownload() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Packages/BestASRCore/Sources/BestASRFluidRuntime/FluidSpeakerRuntime.swift"
      ),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("OfflineDiarizerModels.load("))
    XCTAssertFalse(source.contains("ModelHub.loadModels("))
    XCTAssertTrue(source.contains("ModelHub.offlineMode = true"))
    XCTAssertTrue(source.contains("try MLModel("))
    XCTAssertTrue(source.contains("contentsOf: directory.appendingPathComponent"))
  }

  func testSpeakerRuntimeClassifiesNoSpeechAsDeterministicInputOutcome() {
    let failure = FluidSpeakerRuntime.failure(for: .noSpeechDetected)

    XCTAssertEqual(failure.category, .corruptInput)
    XCTAssertEqual(failure.code, "fluid-speaker-no-speech-detected")
    XCTAssertFalse(failure.retryable)
  }

  func testActivitySegmenterPreservesPhraseTimingAndSuppressesLowNoise() throws {
    let segmenter = SenseVoiceActivitySegmenter()
    let speech = [Float](repeating: 0.1, count: 16_000)
    let silence = [Float](repeating: 0, count: 16_000)
    let ranges = segmenter.speechRanges(in: speech + silence + speech)

    XCTAssertEqual(ranges.count, 2)
    XCTAssertLessThan(
      try XCTUnwrap(ranges.first?.upperBound), try XCTUnwrap(ranges.last?.lowerBound))
    XCTAssertTrue(
      segmenter.speechRanges(
        in: [Float](repeating: 0.008, count: 64_000)
      ).isEmpty
    )
  }

  func testDictionaryNormalizerCorrectsOnlyBoundedExplicitTerms() {
    let normalizer = SenseVoiceDictionaryNormalizer()
    let result = normalizer.normalize(
      "声明负责 open a i，alllis owns best a s r",
      dictionaryTerms: ["张明", "OpenAI", "Alice", "bestASR"]
    )

    XCTAssertEqual(result, "张明负责 OpenAI，Alice owns bestASR")
    XCTAssertEqual(
      normalizer.normalize("unrelated words", dictionaryTerms: ["Alice"]),
      "unrelated words"
    )
    XCTAssertEqual(
      normalizer.normalize("use me o s fourteen", dictionaryTerms: ["macOS"]),
      "use macOS fourteen"
    )
  }

  func testExplicitSpokenFormsRewriteEveryOccurrenceWithoutCascading() {
    let normalizer = SenseVoiceDictionaryNormalizer()
    let hints = [
      ASRDictionaryHint(
        canonicalForm: "bestASR",
        spokenForms: ["best A S R", "best ar"]
      )
    ]

    XCTAssertEqual(
      normalizer.normalize(
        "这是 best a s r 测试，产品名字必须写成 best a s r。",
        dictionaryTerms: ["bestASR"],
        dictionaryHints: hints
      ),
      "这是 bestASR 测试，产品名字必须写成 bestASR。"
    )
    XCTAssertEqual(
      normalizer.normalize(
        "best ar and best a s r",
        dictionaryTerms: [],
        dictionaryHints: hints
      ),
      "bestASR and bestASR"
    )
  }

  func testAmbiguousSpokenFormFailsClosed() {
    let result = SenseVoiceDictionaryNormalizer().normalize(
      "use shared name",
      dictionaryTerms: [],
      dictionaryHints: [
        ASRDictionaryHint(
          canonicalForm: "FirstName",
          spokenForms: ["shared name"]
        ),
        ASRDictionaryHint(
          canonicalForm: "SecondName",
          spokenForms: ["shared name"]
        ),
      ]
    )

    XCTAssertEqual(result, "use shared name")
  }

  func testRuntimeAppliesSpokenDictionaryMappingFromRecognitionContext()
    async throws
  {
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: FixtureAudioLoader(samples: [Float](repeating: 0.25, count: 320)),
      backend: FixtureBackend(text: "best a s r and best ar"),
      activitySegmenter: fixtureActivitySegmenter
    )
    let request = makeRequest(
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: ["bestASR"],
        dictionaryHints: [
          ASRDictionaryHint(
            canonicalForm: "bestASR",
            spokenForms: ["best A S R", "best ar"]
          )
        ]
      )
    )

    let output = try await runtime.transcribe(
      request,
      candidateID: "fluid-sensevoice"
    )

    XCTAssertEqual(output.segments.map(\.text), ["bestASR and bestASR"])
  }

  func testRuntimeSkipsBackendForLowEnergyInput() async throws {
    let backend = FixtureBackend(text: "hallucination")
    let runtime = FluidSenseVoiceRuntime(
      audioLoader: FixtureAudioLoader(
        samples: [Float](repeating: 0.008, count: 64_000)
      ),
      backend: backend
    )

    let output = try await runtime.transcribe(
      makeRequest(),
      candidateID: "fluid-sensevoice"
    )

    XCTAssertTrue(output.segments.isEmpty)
    let backendCallCount = await backend.callCount()
    XCTAssertEqual(backendCallCount, 0)
  }

  private func assertFailure(
    category: InferenceFailureCategory,
    code: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected inference failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, category)
      XCTAssertEqual(error.code, code)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private var fixtureActivitySegmenter: SenseVoiceActivitySegmenter {
    SenseVoiceActivitySegmenter(
      frameDurationMilliseconds: 20,
      splitSilenceMilliseconds: 20,
      paddingMilliseconds: 0,
      minimumActiveMilliseconds: 20
    )
  }

  private func makeRequest(
    sampleRate: UInt32 = 16_000,
    channels: UInt16 = 1,
    modelArtifactID: String = FluidSenseVoicePinnedArtifact.artifactID,
    recognitionContext: ASRRecognitionContext = ASRRecognitionContext(),
    supersedesRevisionID: UUID? = nil
  ) -> ASRRequest {
    ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: uuid(2),
        inputRevision: 3,
        modelArtifactID: modelArtifactID,
        configHash: String(repeating: "c", count: 64)
      ),
      audio: AudioRangeInput(
        sourceID: uuid(3),
        trackID: uuid(4),
        assetReference: "range.f32le",
        contentDigest: String(repeating: "d", count: 64),
        monotonicStartNanoseconds: 1_000,
        monotonicEndNanoseconds: 2_000,
        sampleRateHertz: sampleRate,
        channelCount: channels
      ),
      mode: .final,
      languageHints: ["zh-CN", "en-US"],
      recognitionContext: recognitionContext,
      supersedesRevisionID: supersedesRevisionID
    )
  }

  private func audioInput(reference: String, digest: String) -> AudioRangeInput {
    AudioRangeInput(
      sourceID: uuid(5),
      trackID: uuid(6),
      assetReference: reference,
      contentDigest: digest,
      monotonicStartNanoseconds: 1,
      monotonicEndNanoseconds: 2,
      sampleRateHertz: 16_000,
      channelCount: 1
    )
  }

  private func fluidCandidate() throws -> ASRCandidateRecord {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/inference-candidates.json"
      )
    )
    return try XCTUnwrap(
      ASRCandidateManifest.decode(data).candidates.first {
        $0.candidateID == "fluid-sensevoice"
      }
    )
  }

  private func float32Data(_ samples: [Float]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 4)
    for sample in samples {
      var bits = sample.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private actor FixtureAudioLoader: SenseVoiceAudioSampleLoading {
  private let samples: [Float]
  private var count = 0

  init(samples: [Float]) { self.samples = samples }

  func loadSamples(for input: AudioRangeInput) -> [Float] {
    count += 1
    return samples
  }

  func loadCount() -> Int { count }
}

private actor FixtureBackend: SenseVoiceTranscribing,
  FluidASRSampleTranscribing
{
  private let text: String
  private var samples: [Float] = []
  private var count = 0

  init(text: String) { self.text = text }

  func transcribe(samples: [Float]) -> String {
    self.samples = samples
    count += 1
    return text
  }

  func capturedSamples() -> [Float] { samples }
  func callCount() -> Int { count }
}

private actor DetailedFixtureBackend: SenseVoiceDetailedTranscribing {
  private let transcription: SenseVoiceTranscription

  init(transcription: SenseVoiceTranscription) {
    self.transcription = transcription
  }

  func transcribe(samples: [Float]) -> String {
    transcription.text
  }

  func transcribeDetailed(samples: [Float]) -> SenseVoiceTranscription {
    transcription
  }
}

private struct FailingBackend: SenseVoiceTranscribing {
  func transcribe(samples: [Float]) async throws -> String {
    throw NSError(domain: "private-runtime-detail", code: 1)
  }
}
