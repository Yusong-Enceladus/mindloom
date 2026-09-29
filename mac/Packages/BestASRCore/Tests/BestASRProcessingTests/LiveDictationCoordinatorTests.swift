import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRProcessing
import Foundation
import XCTest

final class LiveDictationCoordinatorTests: XCTestCase {
  func testCadenceStartsAtFirstCommittedAudioAndCoalescesToOnePendingRequest() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 150_000_000)
    let sessionID = SessionID(processingUUID(501))

    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0.1)
    )
    let initialValue = await fixture.coordinator.schedulingSnapshot(sessionID: sessionID)
    let initial = try XCTUnwrap(initialValue)
    XCTAssertFalse(initial.inFlight)
    XCTAssertEqual(initial.requestRevision, 0)
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0.1)
    )
    try await waitUntil { await fixture.asr.callCount() == 1 }
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 2, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 3, value: 0.1)
    )
    let snapshotValue = await fixture.coordinator.schedulingSnapshot(sessionID: sessionID)
    let snapshot = try XCTUnwrap(snapshotValue)
    XCTAssertTrue(snapshot.inFlight)
    XCTAssertEqual(snapshot.pendingRequestCount, 1)

    try await waitUntil { await fixture.asr.callCount() == 2 }
    try await waitUntil { await fixture.repository.commits().count == 2 }
    let maximumConcurrentCalls = await fixture.asr.maximumConcurrentCalls()
    let dictionaryHints = await fixture.asr.receivedDictionaryHints()
    XCTAssertEqual(maximumConcurrentCalls, 1)
    XCTAssertEqual(
      dictionaryHints.first,
      [
        ASRDictionaryHint(
          canonicalForm: "bestASR",
          spokenForms: ["best A S R"]
        )
      ]
    )
  }

  func testFinalBoundaryRejectsLateResultAndClearsPendingWork() async throws {
    let fixture = try LiveCoordinatorFixture(
      delayNanoseconds: 250_000_000,
      ignoresCancellation: true
    )
    let sessionID = SessionID(processingUUID(502))
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0.1)
    )
    try await waitUntil { await fixture.asr.callCount() == 1 }
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .final)
    await fixture.coordinator.awaitFinalizationBarrier(sessionID: sessionID)

    let snapshotValue = await fixture.coordinator.schedulingSnapshot(sessionID: sessionID)
    let snapshot = try XCTUnwrap(snapshotValue)
    XCTAssertTrue(snapshot.finalized)
    XCTAssertFalse(snapshot.inFlight)
    let commits = await fixture.repository.commits()
    let calls = await fixture.asr.callCount()
    XCTAssertTrue(commits.isEmpty)
    XCTAssertEqual(calls, 1)
  }

  func testPauseSuppressesBufferedCommitsUntilResume() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 0)
    let sessionID = SessionID(processingUUID(506))
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0.1)
    )
    try await waitUntil { await fixture.repository.commits().count == 1 }
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .sentence)
    try await waitUntil { await fixture.repository.commits().count == 2 }

    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 2, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 3, value: 0.1)
    )
    try await Task.sleep(for: .milliseconds(50))
    let pausedCallCount = await fixture.asr.callCount()
    XCTAssertEqual(pausedCallCount, 2)

    await fixture.audio.setRanges([
      liveRange(sessionID: sessionID, end: 800_000_000)
    ])
    await fixture.coordinator.didResume(sessionID: sessionID)
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 4, value: 0.1)
    )
    try await waitUntil { await fixture.asr.callCount() == 3 }
  }

  func testSilenceDoesNotPersistEmptyStreamingRevisions() async throws {
    let events = LiveEventRecorder()
    let fixture = try LiveCoordinatorFixture(
      delayNanoseconds: 0,
      emptyResponses: true,
      eventHandler: { event in events.record(event) }
    )
    let sessionID = SessionID(processingUUID(507))

    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0)
    )
    try await waitUntil { await fixture.asr.callCount() == 1 }
    try await Task.sleep(for: .milliseconds(50))

    let commits = await fixture.repository.commits()
    XCTAssertTrue(commits.isEmpty)
    XCTAssertTrue(events.snapshot().isEmpty)
  }

  func testContinuousSpeechDrainsOldestWindowsWithoutDiscardingEarlierWords() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 0)
    let sessionID = SessionID(processingUUID(508))
    let ranges = (0..<5).map { index in
      liveRange(
        sessionID: sessionID, end: UInt64(index + 1) * 400_000_000,
        start: UInt64(index) * 400_000_000)
    }
    await fixture.audio.setRanges(Array(ranges.reversed()))
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 0, value: 0.1))
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 1, value: 0.1))
    try await waitUntil { await fixture.repository.commits().count == 3 }

    let received = await fixture.asr.receivedAudioRanges()
    XCTAssertEqual(received.flatMap { $0 }, ranges)
    XCTAssertEqual(received.map(\.count), [2, 2, 1])
    let modes = await fixture.asr.requestedModes()
    XCTAssertEqual(modes, [.final, .final, .streaming])
    let commits = await fixture.repository.commits()
    XCTAssertEqual(
      commits.map(\.transcript.text), ["draft-1", "draft-1 draft-2", "draft-1 draft-2 draft-3"])
    XCTAssertEqual(
      commits[2].transcript.provenance?.parentRevisionID, commits[1].transcript.revisionID)
  }

  func testPausedBoundaryDrainsItsLastShortWindowPrecisely() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 0)
    let sessionID = SessionID(processingUUID(509))
    await fixture.audio.setRanges(
      (0..<5).map { index in
        liveRange(
          sessionID: sessionID, end: UInt64(index + 1) * 400_000_000,
          start: UInt64(index) * 400_000_000)
      })
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 0, value: 0.1))
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .sentence)
    try await waitUntil { await fixture.repository.commits().count == 3 }

    let modes = await fixture.asr.requestedModes()
    XCTAssertEqual(modes, [.final, .final, .final])
    let commits = await fixture.repository.commits()
    XCTAssertEqual(commits.last?.transcript.text, "draft-1 draft-2 draft-3")
    XCTAssertTrue(commits.allSatisfy { $0.transcript.provenance?.kind == .sentence })
  }

  func testQuietWindowsAreConsumedWithoutEmptyRevisionsOrStarvingSpeech() async throws {
    let events = LiveEventRecorder()
    let fixture = try LiveCoordinatorFixture(
      delayNanoseconds: 0, emptyFirstResponses: 2, eventHandler: { events.record($0) })
    let sessionID = SessionID(processingUUID(510))
    await fixture.audio.setRanges(
      (0..<5).map { index in
        liveRange(
          sessionID: sessionID, end: UInt64(index + 1) * 400_000_000,
          start: UInt64(index) * 400_000_000)
      })
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 0, value: 0.1))
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 1, value: 0.1))
    try await waitUntil { await fixture.repository.commits().count == 1 }

    let received = await fixture.asr.receivedAudioRanges()
    XCTAssertEqual(received.map(\.count), [2, 2, 1])
    let commits = await fixture.repository.commits()
    XCTAssertEqual(commits[0].transcript.text, "draft-3")
    XCTAssertNil(commits[0].transcript.provenance?.parentRevisionID)
    XCTAssertEqual(events.snapshot().map(\.text), ["draft-3"])
  }

  func testWindowProgressRetainsEveryRangeFromUnequalTracks() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 0)
    let sessionID = SessionID(processingUUID(511))
    var ranges: [AudioRangeInput] = []
    for index in 0..<3 {
      let ordinal = UInt64(index)
      ranges.append(
        liveRange(
          sessionID: sessionID, end: (ordinal + 1) * 400_000_000,
          start: ordinal * 400_000_000))
      ranges.append(
        liveRange(
          sessionID: sessionID, end: (ordinal + 1) * 500_000_000,
          start: ordinal * 500_000_000, trackID: processingUUID(801)))
    }
    await fixture.audio.setRanges(ranges)
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 0, value: 0.1))
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .sentence)
    try await waitUntil { await fixture.repository.commits().count == 2 }
    let consumed = await fixture.asr.receivedAudioRanges().flatMap { $0 }
    XCTAssertEqual(consumed.count, ranges.count)
    for range in ranges {
      XCTAssertEqual(consumed.filter { $0 == range }.count, 1)
    }
  }

  func testFinalBoundarySuppressesLateFailureFeedback() async throws {
    let events = LiveEventRecorder()
    let fixture = try LiveCoordinatorFixture(
      delayNanoseconds: 250_000_000, failuresBeforeSuccess: 1,
      ignoresCancellation: true, eventHandler: { events.record($0) })
    let sessionID = SessionID(processingUUID(512))
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 0, value: 0.1))
    await fixture.coordinator.didCommit(
      sessionID: sessionID, chunk: liveChunk(sequence: 1, value: 0.1))
    try await waitUntil { await fixture.asr.callCount() == 1 }
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .final)
    await fixture.coordinator.awaitFinalizationBarrier(sessionID: sessionID)
    XCTAssertTrue(events.snapshot().isEmpty)
  }
}

final class LiveTranscriptRevisionIntegrationTests: XCTestCase {
  func testSentenceRevisionParentsStreamingRevisionAndRetainsExactRanges() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 0)
    let sessionID = SessionID(processingUUID(503))
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0.1)
    )
    try await waitUntil { await fixture.repository.commits().count == 1 }
    await fixture.audio.setRanges([liveRange(sessionID: sessionID, end: 400_000_000)])
    await fixture.coordinator.didReachBoundary(sessionID: sessionID, kind: .sentence)
    try await waitUntil { await fixture.repository.commits().count == 2 }

    let commits = await fixture.repository.commits()
    XCTAssertEqual(commits.map(\.transcript.provenance?.kind), [.streaming, .sentence])
    let requestedModes = await fixture.asr.requestedModes()
    XCTAssertEqual(requestedModes, [.streaming, .final])
    XCTAssertEqual(
      commits[1].transcript.provenance?.parentRevisionID,
      commits[0].transcript.revisionID
    )
    XCTAssertEqual(
      commits[1].transcript.provenance?.audioRanges,
      [liveRange(sessionID: sessionID, end: 400_000_000)]
    )
    XCTAssertEqual(commits.map(\.inputRevision), [1, 2])
  }
}

final class CaptureFirstLiveInferenceTests: XCTestCase {
  func testSlowLiveInferenceDoesNotDelayCommittedChunkNotification() async throws {
    let fixture = try LiveCoordinatorFixture(delayNanoseconds: 300_000_000)
    let sessionID = SessionID(processingUUID(504))
    let start = ContinuousClock.now
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 0, value: 0.1)
    )
    await fixture.coordinator.didCommit(
      sessionID: sessionID,
      chunk: liveChunk(sequence: 1, value: 0.1)
    )
    let elapsed = start.duration(to: .now)

    XCTAssertLessThan(elapsed, .milliseconds(100))
    try await waitUntil { await fixture.repository.commits().count == 1 }
  }

  func testLiveFailureIsBoundedAndLaterCommittedAudioCanRetry() async throws {
    let events = LiveEventRecorder()
    let fixture = try LiveCoordinatorFixture(
      delayNanoseconds: 0,
      failuresBeforeSuccess: 1,
      eventHandler: { event in events.record(event) }
    )
    let sessionID = SessionID(processingUUID(505))
    for sequence in 0..<4 {
      await fixture.coordinator.didCommit(
        sessionID: sessionID,
        chunk: liveChunk(sequence: UInt64(sequence), value: 0.1)
      )
      try await Task.sleep(for: .milliseconds(20))
    }
    try await waitUntil { events.snapshot().contains { $0.state == .unavailable } }
    try await waitUntil { await fixture.repository.commits().count == 1 }
  }
}

private struct LiveCoordinatorFixture {
  let audio: LiveAudioFixture
  let asr: LiveASRFixture
  let repository: LiveRepositoryFixture
  let coordinator: LiveDictationCoordinator

  init(
    delayNanoseconds: UInt64,
    failuresBeforeSuccess: Int = 0,
    ignoresCancellation: Bool = false,
    emptyResponses: Bool = false,
    emptyFirstResponses: UInt64 = 0,
    eventHandler: @escaping LiveDictationCoordinator.EventHandler = { _ in }
  ) throws {
    let sessionID = SessionID(processingUUID(500))
    audio = LiveAudioFixture(ranges: [liveRange(sessionID: sessionID, end: 400_000_000)])
    asr = LiveASRFixture(
      delayNanoseconds: delayNanoseconds,
      failuresBeforeSuccess: failuresBeforeSuccess,
      ignoresCancellation: ignoresCancellation,
      emptyResponses: emptyResponses,
      emptyFirstResponses: emptyFirstResponses
    )
    repository = LiveRepositoryFixture()
    coordinator = LiveDictationCoordinator(
      audio: audio,
      asr: asr,
      repository: repository,
      contextProvider: {
        LiveDictationContext(
          dictionaryTerms: ["bestASR"],
          dictionaryHints: [
            ASRDictionaryHint(
              canonicalForm: "bestASR",
              spokenForms: ["best A S R"]
            )
          ],
          configHash: try processingDigest("c")
        )
      },
      policy: try LiveDictationPolicy(
        minimumCadenceNanoseconds: 200_000_000,
        maximumContextNanoseconds: 1_000_000_000
      ),
      silenceConfiguration: try DictationSilenceConfiguration(
        minimumSpeechNanoseconds: 100_000_000,
        sentenceSilenceNanoseconds: 500_000_000
      ),
      eventHandler: eventHandler
    )
  }
}

private actor LiveAudioFixture: DictationCommittedAudioPort {
  private var ranges: [AudioRangeInput]
  init(ranges: [AudioRangeInput]) { self.ranges = ranges }
  func setRanges(_ ranges: [AudioRangeInput]) { self.ranges = ranges }
  func committedAudioSnapshot(sessionID: SessionID) async throws -> [AudioRangeInput] {
    ranges.map {
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: $0.trackID,
        assetReference: $0.assetReference,
        contentDigest: $0.contentDigest,
        monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
        monotonicEndNanoseconds: $0.monotonicEndNanoseconds,
        sampleRateHertz: $0.sampleRateHertz,
        channelCount: $0.channelCount
      )
    }
  }
}

private actor LiveASRFixture: VersionedDictationASRPort {
  enum Failure: Error { case simulated }
  private let delayNanoseconds: UInt64
  private let ignoresCancellation: Bool
  private let emptyResponses: Bool
  private let emptyFirstResponses: UInt64
  private var failuresRemaining: Int
  private var calls = 0
  private var activeCalls = 0
  private var maximumCalls = 0
  private var modes: [ASRMode] = []
  private var dictionaryHints: [[ASRDictionaryHint]] = []
  private var audioRanges: [[AudioRangeInput]] = []

  init(
    delayNanoseconds: UInt64,
    failuresBeforeSuccess: Int,
    ignoresCancellation: Bool,
    emptyResponses: Bool,
    emptyFirstResponses: UInt64
  ) {
    self.delayNanoseconds = delayNanoseconds
    failuresRemaining = failuresBeforeSuccess
    self.ignoresCancellation = ignoresCancellation
    self.emptyResponses = emptyResponses
    self.emptyFirstResponses = emptyFirstResponses
  }

  func recognize(_ request: DictationASRRequest) async throws -> DictationTranscriptResult {
    try await recognize(
      VersionedDictationASRRequest(
        request: request,
        mode: .streaming,
        languageHints: ["en-US"],
        supersedesRevisionID: nil
      )
    )
  }

  func recognize(
    _ versioned: VersionedDictationASRRequest
  ) async throws -> DictationTranscriptResult {
    calls += 1
    modes.append(versioned.mode)
    dictionaryHints.append(versioned.request.dictionaryHints)
    audioRanges.append(versioned.request.audio)
    activeCalls += 1
    maximumCalls = max(maximumCalls, activeCalls)
    defer { activeCalls -= 1 }
    if delayNanoseconds > 0 {
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch is CancellationError where ignoresCancellation {
        // Simulates a backend that cannot cancel once inference has started.
      }
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw Failure.simulated
    }
    let request = versioned.request
    let revisionID = TranscriptRevisionID(processingUUID(600 + request.inputRevision))
    return DictationTranscriptResult(
      revisionID: revisionID,
      segmentIDs: [processingUUID(700 + request.inputRevision)],
      text: emptyResponses || request.inputRevision <= emptyFirstResponses
        ? "" : "draft-\(request.inputRevision)",
      modelArtifactID: "fixture-live-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: versioned.supersedesRevisionID,
        kind: .streaming,
        languageHints: versioned.languageHints,
        audioRanges: request.audio,
        segments: []
      )
    )
  }

  func callCount() -> Int { calls }
  func maximumConcurrentCalls() -> Int { maximumCalls }
  func requestedModes() -> [ASRMode] { modes }
  func receivedDictionaryHints() -> [[ASRDictionaryHint]] { dictionaryHints }
  func receivedAudioRanges() -> [[AudioRangeInput]] { audioRanges }
}

private actor LiveRepositoryFixture: DictationTranscriptRevisionRepositoryPort {
  private var values: [DictationTranscriptRevisionCommit] = []
  func commitTranscriptRevision(_ commit: DictationTranscriptRevisionCommit) async throws {
    values.append(commit)
  }
  func commits() -> [DictationTranscriptRevisionCommit] { values }
}

private final class LiveEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [LiveDictationEvent] = []
  func record(_ event: LiveDictationEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
  func snapshot() -> [LiveDictationEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

private func liveChunk(sequence: UInt64, value: Float) -> CapturedPCMChunk {
  let samples = [Float](repeating: value, count: 1_600)
  return CapturedPCMChunk(
    sequence: sequence,
    monotonicStartNanoseconds: sequence * 100_000_000,
    frameCount: UInt64(samples.count),
    sampleRateHertz: 16_000,
    channelCount: 1,
    encoding: .float32LittleEndian,
    interleaved: true,
    bytes: samples.withUnsafeBytes { Data($0) }
  )
}

private func liveRange(
  sessionID: SessionID, end: UInt64, start: UInt64 = 0,
  trackID: UUID = processingUUID(800)
) -> AudioRangeInput {
  AudioRangeInput(
    sourceID: sessionID.rawValue,
    trackID: trackID,
    assetReference: "sessions/live/\(trackID.uuidString)-\(start).pcm",
    contentDigest: String(repeating: "d", count: 64),
    monotonicStartNanoseconds: start,
    monotonicEndNanoseconds: end,
    sampleRateHertz: 16_000,
    channelCount: 1
  )
}

private func waitUntil(
  timeout: Duration = .seconds(2),
  _ predicate: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("Timed out waiting for live coordinator condition")
}
