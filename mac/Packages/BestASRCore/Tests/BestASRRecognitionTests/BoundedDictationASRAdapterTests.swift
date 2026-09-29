import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRRecognition
import Foundation
import XCTest

final class BoundedDictationASRAdapterTests: XCTestCase {
  func testSealedJournalMaterializesBoundedAudioForFinalRecognition() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(uuid(1))
    let sourceSamples = (0..<4_800).map { index in
      Float(sin(Double(index) * 0.01) * 0.25)
    }
    let sourceBytes = float32Data(sourceSamples)
    let journal = try ProductionAudioJournal(
      assetRootURL: root,
      inferenceWindowNanoseconds: 1_000_000_000
    )
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID,
        deviceUID: "builtin-fixture",
        sampleRateHertz: 48_000,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true
      )
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: CapturedPCMChunk(
        sequence: 0,
        monotonicStartNanoseconds: 10_000,
        frameCount: 4_800,
        sampleRateHertz: 48_000,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: sourceBytes
      )
    )
    let sourceRanges = try await journal.seal(sessionID: sessionID)
    let engine = FixtureASREngine()
    let adapter = try makeAdapter(engine: engine, audio: journal)

    let first = try await adapter.recognize(
      baseRequest(sessionID: sessionID, audio: sourceRanges)
    )
    let second = try await adapter.recognize(
      baseRequest(sessionID: sessionID, audio: sourceRanges)
    )
    let engineRequests = await engine.requests()
    let prepared = try XCTUnwrap(engineRequests.first?.audio)
    let preparedURL = root.appendingPathComponent(prepared.assetReference)

    XCTAssertEqual(first, second, "same durable input must replay identically")
    XCTAssertEqual(first.provenance?.audioRanges, sourceRanges)
    XCTAssertEqual(first.provenance?.kind, .final)
    XCTAssertEqual(first.provenance?.segments.map(\.id), first.segmentIDs)
    XCTAssertEqual(prepared.sampleRateHertz, 16_000)
    XCTAssertEqual(prepared.channelCount, 1)
    XCTAssertTrue(prepared.assetReference.contains("/inference/"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: preparedURL.path),
      "reproducible inference scratch must be released after recognition"
    )
    XCTAssertEqual(
      try Data(
        contentsOf: root.appendingPathComponent(sourceRanges[0].assetReference)
      ),
      sourceBytes,
      "inference derivation must not mutate retained source audio"
    )
  }

  func testDraftThenFinalCreatesParentLinkedReplacementRevision() async throws {
    let source = [range(reference: "source.raw", start: 100, end: 200)]
    let prepared = [range(reference: "prepared.f32le", start: 100, end: 200)]
    let audio = FixtureInferenceAudio(output: prepared)
    let engine = FixtureASREngine()
    let adapter = try makeAdapter(engine: engine, audio: audio)
    let base = baseRequest(sessionID: SessionID(uuid(10)), audio: source)

    let draft = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: base,
        mode: .streaming,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: nil
      )
    )
    let final = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: base,
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: draft.revisionID
      )
    )

    XCTAssertNotEqual(draft.revisionID, final.revisionID)
    XCTAssertEqual(draft.provenance?.kind, .streaming)
    XCTAssertEqual(final.provenance?.kind, .final)
    XCTAssertEqual(final.provenance?.parentRevisionID, draft.revisionID)
    XCTAssertEqual(draft.text, "draft-0")
    XCTAssertEqual(final.text, "final-0")
    let calls = await engine.requests()
    XCTAssertEqual(calls[1].supersedesRevisionID, draft.revisionID.rawValue)
    let discardCount = await audio.discardCount()
    XCTAssertEqual(discardCount, 2)
  }

  func testDetectedLanguageReplacesBroadRequestedHints() async throws {
    let source = [range(reference: "source.raw", start: 100, end: 200)]
    let prepared = [range(reference: "prepared.f32le", start: 100, end: 200)]
    let adapter = try makeAdapter(
      engine: FixtureASREngine(
        texts: ["这是中文。"],
        detectedLanguage: "zh-CN"
      ),
      audio: FixtureInferenceAudio(output: prepared)
    )

    let result = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: baseRequest(sessionID: SessionID(uuid(14)), audio: source),
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: nil
      )
    )

    XCTAssertEqual(result.provenance?.languageHints, ["zh-CN"])
  }

  func testSilenceDraftIsTransientButSilenceFinalIsRecoverableFailure()
    async throws
  {
    let source = [range(reference: "source.raw", start: 100, end: 200)]
    let prepared = [range(reference: "prepared.f32le", start: 100, end: 200)]
    let base = baseRequest(sessionID: SessionID(uuid(11)), audio: source)
    let adapter = try makeAdapter(
      engine: FixtureASREngine(texts: ["", ""]),
      audio: FixtureInferenceAudio(output: prepared)
    )

    let draft = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: base,
        mode: .streaming,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: nil
      )
    )
    XCTAssertTrue(draft.text.isEmpty)
    XCTAssertTrue(draft.segmentIDs.isEmpty)

    await assertFailure(
      category: .invalidRequest,
      code: "dictation-asr-no-speech-detected",
      retryable: true
    ) {
      _ = try await adapter.recognize(
        VersionedDictationASRRequest(
          request: base,
          mode: .final,
          languageHints: ["zh-CN", "en-US"],
          supersedesRevisionID: draft.revisionID
        )
      )
    }
  }

  func testEmptyFinalCanBeReturnedForHigherLevelLiveReconciliation() async throws {
    let source = [range(reference: "source.raw", start: 100, end: 200)]
    let prepared = [range(reference: "prepared.f32le", start: 100, end: 200)]
    let base = baseRequest(sessionID: SessionID(uuid(12)), audio: source)
    let adapter = BoundedDictationASRAdapter(
      engine: FixtureASREngine(texts: [""]),
      audio: FixtureInferenceAudio(output: prepared),
      configHash: try BestASRDomain.SHA256Digest(
        String(repeating: "c", count: 64)
      ),
      policy: try BoundedDictationASRPolicy(
        permitsEmptyFinalResultForReconciliation: true
      )
    )

    let final = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: base,
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: TranscriptRevisionID(uuid(13))
      )
    )

    XCTAssertTrue(final.text.isEmpty)
    XCTAssertTrue(final.segmentIDs.isEmpty)
    XCTAssertEqual(final.provenance?.kind, .final)
    XCTAssertEqual(final.provenance?.audioRanges, source)
  }

  func testMultipleWindowsCarryBoundedContextAndMapTimestamps() async throws {
    let source = [range(reference: "source.raw", start: 0, end: 2_000)]
    let prepared = [
      range(reference: "prepared-0.f32le", start: 0, end: 1_000),
      range(reference: "prepared-1.f32le", start: 1_000, end: 2_000),
    ]
    let engine = FixtureASREngine(texts: ["hello", "world"])
    let adapter = try makeAdapter(
      engine: engine,
      audio: FixtureInferenceAudio(output: prepared)
    )
    let request = DictationASRRequest(
      sessionID: SessionID(uuid(20)),
      inputRevision: 2,
      audio: source,
      dictionaryTerms: (0..<100).map { "term-\($0)" },
      dictionaryHints: (0..<100).map { index in
        ASRDictionaryHint(
          canonicalForm: "canonical-\(index)",
          spokenForms: (0..<40).map { "spoken-\(index)-\($0)" }
        )
      }
    )

    let result = try await adapter.recognize(request)
    let calls = await engine.requests()

    XCTAssertEqual(result.text, "hello world")
    XCTAssertEqual(result.provenance?.segments.count, 2)
    XCTAssertEqual(
      result.provenance?.segments.map(\.monotonicStartNanoseconds),
      [0, 1_000]
    )
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[0].recognitionContext.dictionaryTerms.count, 64)
    XCTAssertEqual(calls[0].recognitionContext.dictionaryHints.count, 64)
    XCTAssertEqual(
      calls[0].recognitionContext.dictionaryHints.first?.spokenForms.count,
      32
    )
    XCTAssertEqual(calls[1].recognitionContext.priorStableSegments.map(\.text), ["hello"])
  }

  func testFinalEnglishPhrasesKeepSentenceSpacingAndSeparateSourceRanges() async throws {
    let source = [range(reference: "source.raw", start: 0, end: 2_000)]
    let prepared = [
      range(reference: "prepared-0.f32le", start: 0, end: 1_000),
      range(reference: "prepared-1.f32le", start: 1_000, end: 2_000),
    ]
    let adapter = try makeAdapter(
      engine: FixtureASREngine(texts: ["First sentence.", "Second sentence."]),
      audio: FixtureInferenceAudio(output: prepared))
    let result = try await adapter.recognize(
      baseRequest(sessionID: SessionID(uuid(21)), audio: source))
    XCTAssertEqual(result.text, "First sentence. Second sentence.")
    XCTAssertEqual(
      result.provenance?.segments.map(\.text), ["First sentence.", "Second sentence."])
    XCTAssertEqual(result.provenance?.segments.map(\.monotonicStartNanoseconds), [0, 1_000])
  }

  func testOverlappingIndependentTracksKeepSeparateContextAndMergeByTimeline()
    async throws
  {
    let firstTrack = uuid(201)
    let secondTrack = uuid(202)
    let source = [
      range(
        reference: "source-a-0.raw",
        start: 0,
        end: 1_000,
        trackID: firstTrack
      ),
      range(
        reference: "source-b-0.raw",
        start: 0,
        end: 1_000,
        trackID: secondTrack
      ),
      range(
        reference: "source-a-1.raw",
        start: 1_000,
        end: 2_000,
        trackID: firstTrack
      ),
      range(
        reference: "source-b-1.raw",
        start: 1_000,
        end: 2_000,
        trackID: secondTrack
      ),
    ]
    let prepared = [
      range(
        reference: "prepared-a-0.f32le",
        start: 0,
        end: 1_000,
        trackID: firstTrack
      ),
      range(
        reference: "prepared-b-0.f32le",
        start: 0,
        end: 1_000,
        trackID: secondTrack
      ),
      range(
        reference: "prepared-a-1.f32le",
        start: 1_000,
        end: 2_000,
        trackID: firstTrack
      ),
      range(
        reference: "prepared-b-1.f32le",
        start: 1_000,
        end: 2_000,
        trackID: secondTrack
      ),
    ]
    let engine = FixtureASREngine(texts: ["a0", "b0", "a1", "b1"])
    let adapter = try makeAdapter(
      engine: engine,
      audio: FixtureInferenceAudio(output: prepared)
    )

    let result = try await adapter.recognize(
      baseRequest(sessionID: SessionID(uuid(200)), audio: source)
    )
    let calls = await engine.requests()

    XCTAssertEqual(result.text, "a0 b0 a1 b1")
    XCTAssertEqual(calls.count, 4)
    XCTAssertEqual(calls[0].recognitionContext.priorStableSegments, [])
    XCTAssertEqual(calls[1].recognitionContext.priorStableSegments, [])
    XCTAssertEqual(
      calls[2].recognitionContext.priorStableSegments.map(\.text),
      ["a0"]
    )
    XCTAssertEqual(
      calls[3].recognitionContext.priorStableSegments.map(\.text),
      ["b0"]
    )
  }

  func testPreparedRangeCannotBorrowCoverageFromAnotherTrack() async throws {
    let firstTrack = uuid(211)
    let secondTrack = uuid(212)
    let source = [
      range(
        reference: "source-a.raw",
        start: 0,
        end: 1_500_000,
        trackID: firstTrack
      ),
      range(
        reference: "source-b.raw",
        start: 1_000_000,
        end: 2_000_000,
        trackID: secondTrack
      ),
    ]
    let prepared = [
      range(
        reference: "prepared-b.f32le",
        start: 0,
        end: 1_500_000,
        trackID: secondTrack
      )
    ]
    let adapter = try makeAdapter(
      engine: FixtureASREngine(),
      audio: FixtureInferenceAudio(output: prepared)
    )

    await assertFailure(
      category: .invalidRequest,
      code: "dictation-asr-source-range-mapping-invalid"
    ) {
      _ = try await adapter.recognize(
        self.baseRequest(
          sessionID: SessionID(self.uuid(210)),
          audio: source
        )
      )
    }
  }

  func testResamplingRoundingIsClampedToContiguousSourceEvidence() async throws {
    let source = [
      range(reference: "source-0.raw", start: 0, end: 1_000_000),
      range(
        reference: "source-1.raw",
        start: 1_000_000,
        end: 2_000_000
      ),
    ]
    let prepared = [
      range(
        reference: "prepared.f32le",
        start: 0,
        end: 2_000_001
      )
    ]
    let adapter = try makeAdapter(
      engine: FixtureASREngine(),
      audio: FixtureInferenceAudio(output: prepared)
    )

    let result = try await adapter.recognize(
      baseRequest(sessionID: SessionID(uuid(25)), audio: source)
    )

    XCTAssertEqual(
      result.provenance?.segments.map(\.monotonicStartNanoseconds),
      [0]
    )
    XCTAssertEqual(
      result.provenance?.segments.map(\.monotonicEndNanoseconds),
      [2_000_000]
    )
    XCTAssertEqual(result.provenance?.audioRanges, source)
  }

  func testPreparedWindowCannotBridgeARealSourceGap() async throws {
    let source = [
      range(reference: "source-0.raw", start: 0, end: 1_000_000),
      range(
        reference: "source-1.raw",
        start: 2_000_000,
        end: 3_000_000
      ),
    ]
    let prepared = [
      range(reference: "prepared.f32le", start: 0, end: 3_000_000)
    ]
    let adapter = try makeAdapter(
      engine: FixtureASREngine(),
      audio: FixtureInferenceAudio(output: prepared)
    )

    await assertFailure(
      category: .invalidRequest,
      code: "dictation-asr-source-range-mapping-invalid"
    ) {
      _ = try await adapter.recognize(
        self.baseRequest(
          sessionID: SessionID(self.uuid(26)),
          audio: source
        )
      )
    }
  }

  func testMalformedPreparedRangesFailBeforeRuntime() async throws {
    let malformed = [
      range(reference: "one.f32le", start: 0, end: 100),
      range(reference: "two.f32le", start: 50, end: 150),
    ]
    let engine = FixtureASREngine()
    let audio = FixtureInferenceAudio(output: malformed)
    let adapter = try makeAdapter(
      engine: engine,
      audio: audio
    )

    await assertFailure(
      category: .invalidRequest,
      code: "dictation-asr-prepared-range-invalid"
    ) {
      _ = try await adapter.recognize(
        self.baseRequest(
          sessionID: SessionID(self.uuid(30)),
          audio: [self.range(reference: "source.raw", start: 0, end: 150)]
        )
      )
    }
    let callCount = await engine.callCount()
    XCTAssertEqual(callCount, 0)
    let discardCount = await audio.discardCount()
    XCTAssertEqual(discardCount, 1)
  }

  func testTimeoutCancelsCooperativeRuntimeAndIsRetryable() async throws {
    let prepared = [range(reference: "prepared.f32le", start: 0, end: 100)]
    let engine = FixtureASREngine(delayNanoseconds: 5_000_000_000)
    let policy = try BoundedDictationASRPolicy(timeoutNanoseconds: 5_000_000)
    let adapter = BoundedDictationASRAdapter(
      engine: engine,
      audio: FixtureInferenceAudio(output: prepared),
      configHash: try BestASRDomain.SHA256Digest(String(repeating: "c", count: 64)),
      policy: policy
    )

    await assertFailure(
      category: .transientRuntime,
      code: "dictation-asr-timeout",
      retryable: true
    ) {
      _ = try await adapter.recognize(
        self.baseRequest(
          sessionID: SessionID(self.uuid(40)),
          audio: [self.range(reference: "source.raw", start: 0, end: 100)]
        )
      )
    }
    let timeoutCancelled = await engine.wasCancelled()
    XCTAssertTrue(timeoutCancelled)
  }

  func testCallerCancellationPropagates() async throws {
    let prepared = [range(reference: "prepared.f32le", start: 0, end: 100)]
    let engine = FixtureASREngine(delayNanoseconds: 5_000_000_000)
    let adapter = try makeAdapter(
      engine: engine,
      audio: FixtureInferenceAudio(output: prepared)
    )
    let request = baseRequest(
      sessionID: SessionID(uuid(50)),
      audio: [range(reference: "source.raw", start: 0, end: 100)]
    )
    let task = Task {
      try await adapter.recognize(request)
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .cancelled)
    }
    let callerCancelled = await engine.wasCancelled()
    XCTAssertTrue(callerCancelled)
  }

  private func makeAdapter(
    engine: any ASREngine,
    audio: any DictationInferenceAudioPort
  ) throws -> BoundedDictationASRAdapter {
    BoundedDictationASRAdapter(
      engine: engine,
      audio: audio,
      configHash: try BestASRDomain.SHA256Digest(String(repeating: "c", count: 64)),
      policy: try BoundedDictationASRPolicy()
    )
  }

  private func baseRequest(
    sessionID: SessionID,
    audio: [AudioRangeInput]
  ) -> DictationASRRequest {
    DictationASRRequest(
      sessionID: sessionID,
      inputRevision: 1,
      audio: audio,
      dictionaryTerms: ["bestASR"]
    )
  }

  private func range(
    reference: String,
    start: UInt64,
    end: UInt64,
    sourceID: UUID? = nil,
    trackID: UUID? = nil
  ) -> AudioRangeInput {
    AudioRangeInput(
      sourceID: sourceID ?? uuid(90),
      trackID: trackID ?? uuid(91),
      assetReference: reference,
      contentDigest: String(repeating: "d", count: 64),
      monotonicStartNanoseconds: start,
      monotonicEndNanoseconds: end,
      sampleRateHertz: 16_000,
      channelCount: 1
    )
  }

  private func assertFailure(
    category: InferenceFailureCategory,
    code: String,
    retryable: Bool? = nil,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected ASR failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, category)
      XCTAssertEqual(error.code, code)
      if let retryable { XCTAssertEqual(error.retryable, retryable) }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-recognition-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }
}

private actor FixtureInferenceAudio: DictationInferenceAudioPort {
  private let output: [AudioRangeInput]
  private var discarded: [[AudioRangeInput]] = []

  init(output: [AudioRangeInput]) { self.output = output }

  func prepareInferenceAudio(
    sessionID: SessionID,
    sourceAudio: [AudioRangeInput]
  ) -> [AudioRangeInput] {
    output
  }

  func discardInferenceAudio(
    sessionID _: SessionID,
    preparedAudio: [AudioRangeInput]
  ) {
    discarded.append(preparedAudio)
  }

  func discardCount() -> Int { discarded.count }
}

private actor FixtureASREngine: ASREngine {
  private let texts: [String]
  private let delayNanoseconds: UInt64
  private let detectedLanguage: String?
  private var captured: [ASRRequest] = []
  private var cancelled = false

  init(
    texts: [String] = [],
    delayNanoseconds: UInt64 = 0,
    detectedLanguage: String? = nil
  ) {
    self.texts = texts
    self.delayNanoseconds = delayNanoseconds
    self.detectedLanguage = detectedLanguage
  }

  func descriptor() -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(
      artifact: ModelArtifactDescriptor(
        artifactID: "fixture-asr-model",
        version: "1.0.0",
        sha256: String(repeating: "a", count: 64),
        runtimeID: InferenceRuntimeID("fixture.asr"),
        capabilities: [.asrBatch, .asrStreaming, .asrRevisioned, .asrTimestamps],
        minimumOS: InferenceOSVersion(major: 14, minor: 2),
        supportedArchitectures: ["arm64"],
        minimumUnifiedMemoryBytes: 1,
        licenseIdentifier: "Fixture",
        networkRequired: false
      )
    )
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    let index = captured.count
    captured.append(request)
    if delayNanoseconds > 0 {
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        cancelled = true
        throw error
      }
    }
    try InferenceCancellation.check()
    let text =
      index < texts.count
      ? texts[index]
      : "\(request.mode == .streaming ? "draft" : "final")-0"
    let segments =
      text.isEmpty
      ? []
      : [
        ASRSegment(
          segmentID: request.metadata.jobID,
          monotonicStartNanoseconds: request.audio.monotonicStartNanoseconds,
          monotonicEndNanoseconds: request.audio.monotonicEndNanoseconds,
          text: text,
          confidence: 0.9
        )
      ]
    return ASRResult(
      modelArtifactID: request.metadata.modelArtifactID,
      segments: segments,
      detectedLanguage: detectedLanguage,
      revision: ASRRevisionMetadata(
        revisionID: request.metadata.jobID,
        supersedesRevisionID: request.supersedesRevisionID,
        mode: request.mode,
        monotonicStartNanoseconds: request.audio.monotonicStartNanoseconds,
        monotonicEndNanoseconds: request.audio.monotonicEndNanoseconds
      )
    )
  }

  func requests() -> [ASRRequest] { captured }
  func callCount() -> Int { captured.count }
  func wasCancelled() -> Bool { cancelled }
}
