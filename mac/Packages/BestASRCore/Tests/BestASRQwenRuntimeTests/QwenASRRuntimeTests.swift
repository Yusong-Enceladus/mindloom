import AVFoundation
import BestASRCandidateAdapters
import BestASRFluidRuntime
import BestASRInference
@testable import BestASRQwenRuntime
import BestASRRecognition
import Foundation
import XCTest

final class QwenASRRuntimeTests: XCTestCase {
  func testNonFileModelAndTokenizerLocationsFailBeforeAnyLoading() async throws {
    let url = try XCTUnwrap(URL(string: "https://example.invalid/model"))
    XCTAssertThrowsError(try QwenLocalTokenizer.load(from: url))
    let backend = QwenASRBackend(verifiedModelDirectory: url)
    do {
      try await backend.prepare()
      XCTFail("remote model URL must be rejected")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "qwen-model-local-files-required")
    }
  }
  func testRawHeaderIsParsedWithoutExposingModelControlText() throws {
    let result = try QwenASRBackend.parse("language Chinese<asr_text>今天 use Codex。")
    XCTAssertEqual(result.text, "今天 use Codex。")
    XCTAssertEqual(result.language, "Chinese")
    XCTAssertTrue(try QwenASRBackend.parse("language None<asr_text>").text.isEmpty)
    XCTAssertThrowsError(try QwenASRBackend.parse("language Chinese"))
    XCTAssertThrowsError(try QwenASRBackend.parse("language English<asr_text><|im_start|>"))
  }

  func testPinnedDescriptorCarriesBothModelIdentitiesWithoutNetworkOrStreamingClaim() {
    let descriptor = QwenASRPinnedArtifact.descriptor
    XCTAssertEqual(
      descriptor.metadata["alignmentArtifactID"], QwenAlignmentPinnedArtifact.artifactID)
    XCTAssertEqual(
      descriptor.metadata["alignmentTreeSHA256"], QwenAlignmentPinnedArtifact.treeSHA256)
    XCTAssertFalse(descriptor.networkRequired)
    XCTAssertFalse(descriptor.capabilities.contains(.asrStreaming))
    XCTAssertTrue(descriptor.capabilities.contains(.asrTimestamps))
  }

  func testSharedFinalRuntimeKeepsDictionaryTextAndMonotonicSourceMapping() async throws {
    let backend = StubQwenASR(text: "use code x.")
    let aligner = StubQwenAligner(words: [
      word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
    ])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: 32_000)),
      backend: backend, aligner: aligner)
    let request = makeRequest()
    let first = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)
    let second = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.segments.map(\.text), ["use Codex."])
    XCTAssertEqual(first.segments.first?.monotonicStartNanoseconds, 10_200_000_000)
    XCTAssertEqual(first.segments.first?.monotonicEndNanoseconds, 11_000_000_000)
    let hints = await backend.contexts()
    XCTAssertTrue(hints.allSatisfy { $0 == ["Codex"] })
  }

  func testSpeculatedPrefixFollowedOnlyByQuietIsReusedOnce() async throws {
    // A speculation starts after a pause, so its audio ends quietly.
    let speech =
      tone(24_000, step: 0.3, amplitude: 0.2)
      + tone(6_000, step: 0.5, amplitude: 0.002)
    let quietTail = tone(8_000, step: 0.5, amplitude: 0.004)
    let backend = StubQwenASR(text: "use code x.")
    let aligner = StubQwenAligner(words: [
      word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
    ])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: speech + quietTail),
      backend: backend, aligner: aligner, speculation: QwenSpeculativeDecodeCache())

    await runtime.speculate(samples: speech, dictionaryTerms: ["Codex"])
    let request = makeRequest()
    let reused = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)
    let decodedAgain = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)

    XCTAssertEqual(reused, decodedAgain, "Reuse must produce the ordinary result")
    let decodes = await backend.contexts().count
    let alignments = await aligner.calls()
    XCTAssertEqual(decodes, 2, "One speculative and one ordinary decode; the hit is used once")
    XCTAssertEqual(alignments, 2)
  }

  func testSpeechAfterTheSpeculationOrOtherTermsDecodeAgain() async throws {
    let speech =
      tone(24_000, step: 0.3, amplitude: 0.2)
      + tone(6_000, step: 0.5, amplitude: 0.002)
    let backend = StubQwenASR(text: "use code x.")
    let aligner = StubQwenAligner(words: [
      word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
    ])
    let moreSpeech = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: speech + speech),
      backend: backend, aligner: aligner, speculation: QwenSpeculativeDecodeCache())
    await moreSpeech.speculate(samples: speech, dictionaryTerms: ["Codex"])
    _ = try await moreSpeech.transcribe(makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)

    let otherTerms = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: speech),
      backend: backend, aligner: aligner, speculation: QwenSpeculativeDecodeCache())
    await otherTerms.speculate(samples: speech, dictionaryTerms: ["Claude"])
    _ = try await otherTerms.transcribe(makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)

    let decodes = await backend.contexts().count
    XCTAssertEqual(decodes, 4, "Both finals decode again after their speculation")
  }

  func testCompletedWindowIsReusedEvenAfterThePauseDecodeIsDropped() async throws {
    let window = tone(30_000, step: 0.3, amplitude: 0.2)
    let backend = StubQwenASR(text: "use code x.")
    let aligner = StubQwenAligner(words: [
      word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
    ])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: window),
      backend: backend, aligner: aligner, speculation: QwenSpeculativeDecodeCache())

    await runtime.precomputeWindow(samples: window, dictionaryTerms: ["Codex"])
    await runtime.clearPauseSpeculation()  // speech resumed: windows must survive
    _ = try await runtime.transcribe(makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)

    let decodes = await backend.contexts().count
    let alignments = await aligner.calls()
    XCTAssertEqual(decodes, 1, "The final window reuses its precomputed decode")
    XCTAssertEqual(alignments, 1)
  }

  func testQuietTailCheckRejectsAnyChangedPrefixSample() {
    let speech =
      tone(24_000, step: 0.3, amplitude: 0.2)
      + tone(6_000, step: 0.5, amplitude: 0.002)
    var changed = speech
    changed[100] += 0.0001
    XCTAssertTrue(QwenSpeculativeDecodeCache.extendsOnlyWithQuiet(prefix: speech, full: speech))
    XCTAssertFalse(QwenSpeculativeDecodeCache.extendsOnlyWithQuiet(prefix: speech, full: changed))
    XCTAssertFalse(
      QwenSpeculativeDecodeCache.extendsOnlyWithQuiet(prefix: Array(speech.prefix(100)), full: speech),
      "Too short to be worth reusing")
  }

  func testASoftWordAfterAQuietPauseIsNotTreatedAsSilence() {
    // A quiet speaker: room at RMS ~0.0014, speech around 0.007.
    let prefix =
      tone(24_000, step: 0.3, amplitude: 0.01)
      + tone(6_000, step: 0.5, amplitude: 0.002)
    let softWord = tone(3_200, step: 0.3, amplitude: 0.008)
    let roomOnly = tone(8_000, step: 0.7, amplitude: 0.002)
    XCTAssertTrue(
      QwenSpeculativeDecodeCache.extendsOnlyWithQuiet(prefix: prefix, full: prefix + roomOnly))
    XCTAssertFalse(
      QwenSpeculativeDecodeCache.extendsOnlyWithQuiet(
        prefix: prefix, full: prefix + roomOnly + softWord + roomOnly))
  }

  func testSilenceDoesNotInvokeGenerativeASROrAlignment() async throws {
    let backend = StubQwenASR(text: "must not appear")
    let aligner = StubQwenAligner(words: [])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0, count: 32_000)),
      backend: backend, aligner: aligner)
    let result = try await runtime.transcribe(
      makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
    XCTAssertTrue(result.segments.isEmpty)
    let calls = await backend.contexts()
    let alignments = await aligner.calls()
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(alignments, 0)
  }

  func testQuietNonzeroInputIsNotDiscardedByAnAbsoluteVolumeThreshold() async throws {
    let backend = StubQwenASR(text: "quiet speech.")
    let aligner = StubQwenAligner(words: [word("quiet", 0.2, 0.4), word("speech", 0.4, 1.0)])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0.001, count: 32_000)),
      backend: backend, aligner: aligner)
    let result = try await runtime.transcribe(
      makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
    XCTAssertEqual(result.segments.map(\.text), ["quiet speech."])
    let calls = await backend.contexts()
    XCTAssertEqual(calls.count, 1)
  }

  func testInvalidAlignmentNeverReturnsPartialFinalText() async throws {
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: 32_000)),
      backend: StubQwenASR(text: "two words"),
      aligner: StubQwenAligner(words: [word("two", 0.2, 0.4)]))
    do {
      _ = try await runtime.transcribe(
        makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
      XCTFail("incomplete alignment must be rejected")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "qwen-final-alignment-invalid")
    }
  }

  func testInvalidAudioDoesNotReachTheModel() async throws {
    let backend = StubQwenASR(text: "unused")
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: [.nan]),
      backend: backend, aligner: StubQwenAligner(words: []))
    do {
      _ = try await runtime.transcribe(
        makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
      XCTFail("nonfinite audio must be rejected")
    } catch let error as InferenceEngineError { XCTAssertEqual(error.category, .corruptInput) }
    let calls = await backend.contexts()
    XCTAssertTrue(calls.isEmpty)
  }

  func testBackendCancellationPropagatesWithoutAlignment() async throws {
    let aligner = StubQwenAligner(words: [])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: 32_000)),
      backend: StubQwenASR(text: "unused", failure: .cancelled), aligner: aligner)
    do {
      _ = try await runtime.transcribe(
        makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
      XCTFail("cancellation must propagate")
    } catch let error as InferenceEngineError { XCTAssertEqual(error.category, .cancelled) }
    let calls = await aligner.calls()
    XCTAssertEqual(calls, 0)
  }

  func testPreparedNativeModelCancellationAndReuse() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["BESTASR_QWEN_ASR_MODEL_DIRECTORY"],
      let path = environment["BESTASR_QWEN_CANCELLATION_AUDIO"]
    else {
      throw XCTSkip("native Qwen cancellation fixture not configured")
    }
    // SwiftPM does not compile this dependency's Metal sources. Reuse the
    // canonical Xcode-built resource without copying a second large cache.
    // Cmlx searches loaded bundles' Resources, not their parent directories.
    let testBundle = Bundle(for: Self.self)
    let sharedResources = testBundle.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("mlx-swift_Cmlx.bundle", isDirectory: true)
    let testResources = try XCTUnwrap(testBundle.resourceURL)
    let resourceLink = testResources.appendingPathComponent("mlx-swift_Cmlx.bundle")
    let fileManager = FileManager.default
    guard
      fileManager.fileExists(
        atPath: sharedResources.appendingPathComponent("Contents/Resources/default.metallib").path)
    else { return XCTFail("canonical MLX Metal resources are missing") }
    let createdLink = !fileManager.fileExists(atPath: resourceLink.path)
    if createdLink {
      try fileManager.createDirectory(at: testResources, withIntermediateDirectories: true)
      try fileManager.createSymbolicLink(at: resourceLink, withDestinationURL: sharedResources)
    }
    defer { if createdLink { try? fileManager.removeItem(at: resourceLink) } }
    let file = try AVAudioFile(
      forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
      file.length > 16_000, file.length <= 30 * 16_000,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { return XCTFail("fixture must be bounded mono 16 kHz") }
    try file.read(into: buffer)
    let pointer = try XCTUnwrap(buffer.floatChannelData?[0])
    let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    let backend = QwenASRBackend(verifiedModelDirectory: URL(fileURLWithPath: directory))
    try await backend.prepare()
    let task = Task { try await backend.transcribe(samples: samples, dictionaryTerms: []) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let cancellationStart = ProcessInfo.processInfo.systemUptime
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("native inference completed without observing cancellation")
    } catch let error as InferenceEngineError { XCTAssertEqual(error.category, .cancelled) }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancellationStart, 5)
    let result = try await backend.transcribe(samples: samples, dictionaryTerms: [])
    XCTAssertFalse(result.text.isEmpty)
  }

  private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptAlignmentWord {
    TranscriptAlignmentWord(text: text, startSeconds: start, endSeconds: end)
  }

  private func makeRequest() -> ASRRequest {
    ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: UUID(), inputRevision: 1,
        modelArtifactID: QwenASRPinnedArtifact.artifactID,
        configHash: String(repeating: "a", count: 64)),
      audio: AudioRangeInput(
        sourceID: UUID(), trackID: UUID(), assetReference: "test.raw",
        contentDigest: String(repeating: "b", count: 64), monotonicStartNanoseconds: 10_000_000_000,
        monotonicEndNanoseconds: 12_000_000_000, sampleRateHertz: 16_000, channelCount: 1),
      mode: .final, languageHints: ["zh-CN", "en-US"],
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: ["Codex"],
        dictionaryHints: [ASRDictionaryHint(canonicalForm: "Codex", spokenForms: ["code x"])]))
  }
}

private struct SamplesLoader: SenseVoiceAudioSampleLoading {
  let samples: [Float]
  func loadSamples(for input: AudioRangeInput) -> [Float] { samples }
}

private actor StubQwenASR: QwenASRSampleTranscribing {
  let text: String
  let failure: InferenceEngineError?
  private var received: [[String]] = []
  init(text: String, failure: InferenceEngineError? = nil) {
    self.text = text
    self.failure = failure
  }
  func release() {}

  func transcribe(samples: [Float], dictionaryTerms: [String]) throws -> QwenRecognizedText {
    received.append(dictionaryTerms)
    if let failure { throw failure }
    return QwenRecognizedText(text: text, language: "English")
  }
  func contexts() -> [[String]] { received }
}

private actor StubQwenAligner: QwenWordsAligning {
  let words: [TranscriptAlignmentWord]
  private var count = 0
  init(words: [TranscriptAlignmentWord]) { self.words = words }
  func prepare() {}

  func release() {}

  func align(samples: [Float], text: String, language: String?) -> [TranscriptAlignmentWord] {
    count += 1
    return words
  }
  func calls() -> Int { count }
}

private func tone(_ count: Int, step: Double, amplitude: Float) -> [Float] {
  (0..<count).map { Float(sin(Double($0) * step)) * amplitude }
}

/// Exercises the real recognizer's release-and-reload path, which is what an
/// idle App now does to give back its memory. Set
/// BESTASR_QWEN_ASR_MODEL to the installed model directory to run it.
final class QwenASRBackendReloadTests: XCTestCase {
  func testReleasingTheModelDoesNotBreakTheNextDictation() async throws {
    guard let path = ProcessInfo.processInfo.environment["BESTASR_QWEN_ASR_MODEL"] else {
      throw XCTSkip("set BESTASR_QWEN_ASR_MODEL to the model directory to run this")
    }
    let backend = QwenASRBackend(
      verifiedModelDirectory: URL(fileURLWithPath: path, isDirectory: true))
    let samples = tone(16_000, step: 0.02, amplitude: 0.05)
    let first = try await backend.transcribe(samples: samples, dictionaryTerms: [])
    await backend.release()
    let afterRelease = try await backend.transcribe(samples: samples, dictionaryTerms: [])
    XCTAssertEqual(first.text, afterRelease.text)
  }
}
