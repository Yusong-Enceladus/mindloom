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

  /// The App's runtime never passes earlier text to the recognizer; only an
  /// evaluation runtime that asks for it does (previous-utterance context
  /// experiment, DICTATION_ARCHITECTURE §15).
  func testPriorTextReachesTheRecognizerOnlyWhenAskedFor() async throws {
    let request = ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: UUID(), inputRevision: 1, modelArtifactID: QwenASRPinnedArtifact.artifactID,
        configHash: String(repeating: "a", count: 64)),
      audio: AudioRangeInput(
        sourceID: UUID(), trackID: UUID(), assetReference: "test.raw",
        contentDigest: String(repeating: "b", count: 64), monotonicStartNanoseconds: 0,
        monotonicEndNanoseconds: 2_000_000_000, sampleRateHertz: 16_000, channelCount: 1),
      mode: .final, languageHints: [],
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: ["Codex"],
        priorStableSegments: [ASRContextSegment(text: "上一句", monotonicEndNanoseconds: 1)]))
    for asked in [false, true] {
      let backend = PriorRecordingQwenASR()
      let runtime = QwenASRRuntime(
        audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: 32_000)),
        backend: backend, aligner: StubQwenAligner(words: [word("好", 0.2, 0.6)]),
        usesPriorContext: asked)
      _ = try await runtime.transcribe(request, candidateID: QwenASRPinnedArtifact.candidateID)
      let priors = await backend.priors
      XCTAssertEqual(priors, [asked ? "上一句" : ""])
    }
  }

  /// Dictionary terms reach the prompt only for short audio (2026-10-06:
  /// in every prompt they made the model write dictionary words that were
  /// not said); spoken-form replacements still apply to long audio.
  func testDictionaryTermsReachThePromptOnlyForShortAudio() async throws {
    XCTAssertEqual(
      QwenASRRuntime.promptTerms(["Codex"], sampleCount: 79_999, maximumSamples: 80_000),
      ["Codex"])
    XCTAssertEqual(
      QwenASRRuntime.promptTerms(["Codex"], sampleCount: 80_000, maximumSamples: 80_000), [])
    XCTAssertEqual(
      QwenASRRuntime.promptTerms(["Codex"], sampleCount: 999_999, maximumSamples: nil), ["Codex"])
    XCTAssertEqual(QwenASRPinnedArtifact.dictionaryPromptMaximumSamples, 80_000)
    for (count, expected) in [(32_000, ["Codex"]), (96_000, [String]())] {
      let backend = StubQwenASR(text: "use code x.")
      let runtime = QwenASRRuntime(
        audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: count)),
        backend: backend,
        aligner: StubQwenAligner(words: [
          word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
        ]), dictionaryPromptMaximumSamples: 80_000)
      let output = try await runtime.transcribe(
        makeRequest(), candidateID: QwenASRPinnedArtifact.candidateID)
      let contexts = await backend.contexts()
      XCTAssertEqual(contexts, [expected])
      XCTAssertEqual(output.segments.map(\.text), ["use Codex."])
    }
  }

  /// Regression (review 2026-10-06): an evaluation run without the length
  /// flags measured the old "dictionary everywhere" rule, not what ships.
  func testAnEvaluationWithoutLengthFlagsUsesTheAppsLimit() throws {
    XCTAssertEqual(
      try QwenASRPinnedArtifact.dictionaryLimitSamples(argument: nil),
      QwenASRPinnedArtifact.dictionaryPromptMaximumSamples)
    XCTAssertNil(try QwenASRPinnedArtifact.dictionaryLimitSamples(argument: "none"))
    XCTAssertEqual(try QwenASRPinnedArtifact.dictionaryLimitSamples(argument: "2.5"), 40_000)
    XCTAssertThrowsError(try QwenASRPinnedArtifact.dictionaryLimitSamples(argument: "five"))
    XCTAssertThrowsError(try QwenASRPinnedArtifact.dictionaryLimitSamples(argument: "0"))
  }

  /// Near-match rewriting follows its own length limit; the entries'
  /// spoken forms apply at every length.
  func testNearMatchesApplyOnlyToShortAudio() async throws {
    for (count, expected) in [(32_000, "张明负责 Codex。"), (96_000, "声明负责 Codex。")] {
      let backend = StubQwenASR(text: "声明负责 code x。")
      let runtime = QwenASRRuntime(
        audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: count)),
        backend: backend,
        aligner: StubQwenAligner(words: [
          word("声明负责", 0.2, 0.6), word("code", 0.6, 0.8), word("x", 0.8, 1.0),
        ]), dictionaryNearMatchMaximumSamples: 80_000)
      let output = try await runtime.transcribe(
        makeRequest(terms: ["张明", "Codex"]), candidateID: QwenASRPinnedArtifact.candidateID)
      XCTAssertEqual(output.segments.map(\.text).joined(), expected)
    }
  }

  /// Dictation (ALIGNMENT recommendation 1, 2026-10-06): the text now, its
  /// sentences' timings later. The aligner is not asked; the window comes
  /// back as one segment, marked pending, spanning it.
  func testDictationGetsItsTextWithoutTheAligner() async throws {
    let aligner = StubQwenAligner(words: [
      word("use", 0.2, 0.4), word("code", 0.4, 0.7), word("x", 0.7, 1.0),
    ])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: Array(repeating: 0.1, count: 32_000)),
      backend: StubQwenASR(text: "use code x."), aligner: aligner)
    let request = makeRequest(defersWords: true)
    let output = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)
    let again = try await runtime.transcribe(
      request, candidateID: QwenASRPinnedArtifact.candidateID)
    XCTAssertEqual(output, again)
    XCTAssertEqual(output.segments.map(\.text), ["use Codex."])
    let segment = try XCTUnwrap(output.segments.first)
    XCTAssertTrue(DeferredWordAlignment.isPending(segment.segmentID))
    XCTAssertEqual(segment.monotonicStartNanoseconds, 10_000_000_000)
    XCTAssertEqual(segment.monotonicEndNanoseconds, 12_000_000_000)
    let alignments = await aligner.calls()
    XCTAssertEqual(alignments, 0)
  }

  /// A pause decode runs while the user speaks: text only, and a dictation
  /// that takes it never aligns.
  func testAPauseDecodeIsTextOnly() async throws {
    let speech =
      tone(24_000, step: 0.3, amplitude: 0.2)
      + tone(6_000, step: 0.5, amplitude: 0.002)
    let quietTail = tone(8_000, step: 0.5, amplitude: 0.004)
    let backend = StubQwenASR(text: "use code x.")
    let aligner = StubQwenAligner(words: [])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: speech + quietTail),
      backend: backend, aligner: aligner, speculation: QwenSpeculativeDecodeCache())
    await runtime.speculate(samples: speech, dictionaryTerms: ["Codex"])
    let output = try await runtime.transcribe(
      makeRequest(defersWords: true), candidateID: QwenASRPinnedArtifact.candidateID)
    XCTAssertEqual(output.segments.map(\.text), ["use Codex."])
    let decodes = await backend.contexts().count
    let alignments = await aligner.calls()
    XCTAssertEqual(decodes, 1, "the pause decode is reused")
    XCTAssertEqual(alignments, 0)
  }

  /// Later, with the aligner alone: the window's sentences, timed on its
  /// range, with their own (not pending) IDs.
  func testADeferredWindowIsTimedIntoSentencesLater() async throws {
    let aligner = StubQwenAligner(words: [
      word("今天开会", 0.1, 0.9), word("Then", 1.0, 1.2), word("ship", 1.2, 1.5),
      word("it", 1.5, 1.8),
    ])
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: []), backend: StubQwenASR(text: "unused"),
      aligner: aligner)
    let pending = DeferredWordAlignment.pendingSegmentID(seed: "window")
    let sentences = try await runtime.timeDeferredWindow(
      samples: Array(repeating: 0.1, count: 32_000), text: "今天开会。 Then ship it.",
      language: nil, replacing: pending, startNanoseconds: 10_000_000_000,
      endNanoseconds: 12_000_000_000)
    XCTAssertEqual(sentences.map(\.text), ["今天开会。", "Then ship it."])
    XCTAssertEqual(sentences.first?.monotonicStartNanoseconds, 10_100_000_000)
    XCTAssertEqual(sentences.last?.monotonicEndNanoseconds, 11_800_000_000)
    XCTAssertTrue(sentences.allSatisfy { !DeferredWordAlignment.isPending($0.segmentID) })
    let again = try await runtime.timeDeferredWindow(
      samples: Array(repeating: 0.1, count: 32_000), text: "今天开会。 Then ship it.",
      language: nil, replacing: pending, startNanoseconds: 10_000_000_000,
      endNanoseconds: 12_000_000_000)
    XCTAssertEqual(again, sentences, "the same window gives the same rows")
  }

  func testAWindowTheAlignerCannotCoverIsRefused() async throws {
    let runtime = QwenASRRuntime(
      audioLoader: SamplesLoader(samples: []), backend: StubQwenASR(text: "unused"),
      aligner: StubQwenAligner(words: [word("two", 0.2, 0.4)]))
    do {
      _ = try await runtime.timeDeferredWindow(
        samples: Array(repeating: 0.1, count: 32_000), text: "two words", language: "English",
        replacing: DeferredWordAlignment.pendingSegmentID(seed: "w"),
        startNanoseconds: 1, endNanoseconds: 2_000_000_001)
      XCTFail("an alignment that does not cover the text must be refused")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "qwen-deferred-alignment-invalid")
    }
  }

  private func makeRequest(terms: [String] = ["Codex"], defersWords: Bool = false) -> ASRRequest {
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
        dictionaryTerms: terms,
        dictionaryHints: [ASRDictionaryHint(canonicalForm: "Codex", spokenForms: ["code x"])],
        deferWordAlignment: defersWords))
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

private actor PriorRecordingQwenASR: QwenASRSampleTranscribing {
  private(set) var priors: [String] = []
  func release() {}
  func transcribe(samples: [Float], dictionaryTerms: [String]) throws -> QwenRecognizedText {
    try transcribe(samples: samples, dictionaryTerms: dictionaryTerms, priorText: "")
  }
  func transcribe(samples: [Float], dictionaryTerms: [String], priorText: String) throws
    -> QwenRecognizedText
  {
    priors.append(priorText)
    return QwenRecognizedText(text: "好", language: "Chinese")
  }
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
