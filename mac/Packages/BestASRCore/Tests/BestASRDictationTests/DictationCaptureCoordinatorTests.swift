import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import XCTest

final class DictationCaptureCoordinatorTests: XCTestCase {
  func testProcessingCompletionAllowsASecondCaptureWithoutRelaunch() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 70)),
      capture: FixtureMicrophoneCapture(chunkCount: 1),
      journal: try ProductionAudioJournal(
        assetRootURL: root.appendingPathComponent("assets")
      ),
      repository: repository
    )
    let firstID = SessionID(testUUID(892))
    _ = try await coordinator.start(sessionID: firstID, target: testTarget())
    let first = try await coordinator.end()
    let completed = DictationSessionSnapshot(
      sessionID: firstID,
      revision: first.snapshot.revision + 1,
      phase: .completed,
      target: first.snapshot.target,
      timeline: first.snapshot.timeline
    )
    try await coordinator.synchronizeProcessingSnapshot(completed)

    let secondID = SessionID(testUUID(893))
    let secondRecording = try await coordinator.start(
      sessionID: secondID,
      target: testTarget()
    )
    let second = try await coordinator.end()

    XCTAssertEqual(secondRecording.phase, .recording)
    XCTAssertEqual(second.snapshot.sessionID, secondID)
    XCTAssertEqual(second.snapshot.phase, .recognizing)
    XCTAssertEqual(second.audio.count, 1)
    try await repository.checkpointAndClose()
  }

  func testMicrophoneStartsBeforePersistenceWithoutLosingEarlyChunks() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(testUUID(894))
    let capture = PersistenceOrderProbeCapture(
      base: FixtureMicrophoneCapture(chunkCount: 6),
      repository: repository,
      sessionID: sessionID
    )
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 71)),
      capture: capture,
      journal: try ProductionAudioJournal(
        assetRootURL: root.appendingPathComponent("assets")
      ),
      repository: repository
    )

    let recording = try await coordinator.start(sessionID: sessionID, target: testTarget())
    let ended = try await coordinator.end()

    let sessionExistedAtMicrophoneStart = await capture.sessionExistedAtStart()
    XCTAssertEqual(sessionExistedAtMicrophoneStart, false)
    XCTAssertEqual(recording.phase, .recording)
    XCTAssertEqual(ended.audio.count, 6, "Chunks captured before the journal existed were kept")
    try await repository.checkpointAndClose()
  }

  func testMicrophoneStartFailureCreatesNoSession() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(testUUID(895))
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 72)),
      capture: FailingStartCapture(),
      journal: try ProductionAudioJournal(
        assetRootURL: root.appendingPathComponent("assets")
      ),
      repository: repository
    )

    do {
      _ = try await coordinator.start(sessionID: sessionID, target: testTarget())
      XCTFail("Expected the microphone start failure")
    } catch is FailingStartCapture.Failure {}
    let stored = try await repository.load(sessionID: sessionID)
    XCTAssertNil(stored)
    try await repository.checkpointAndClose()
  }

  func testPauseAndResumeNotifyCommittedAudioObserverInOrder() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(894))
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let observer = RecordingCommittedChunkObserver()
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 80)),
      capture: FixtureMicrophoneCapture(chunkCount: 1),
      journal: try ProductionAudioJournal(
        assetRootURL: root.appendingPathComponent("assets")
      ),
      repository: repository,
      committedChunkObserver: observer
    )

    _ = try await coordinator.start(sessionID: sessionID, target: testTarget())
    _ = try await coordinator.pause()
    _ = try await coordinator.resume()
    _ = try await coordinator.end()

    let events = await observer.events()
    XCTAssertTrue(events.contains(.committed))
    XCTAssertEqual(events.filter { $0 != .committed }, [.sentence, .resumed, .final])
    try await repository.checkpointAndClose()
  }

  func testCancelRemovesEphemeralRepositoryAndJournalState() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(895))
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets")
    )
    let journalRoot = await journal.journalRootURL(sessionID: sessionID)
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 90)),
      capture: FixtureMicrophoneCapture(chunkCount: 2),
      journal: journal,
      repository: repository
    )

    _ = try await coordinator.start(sessionID: sessionID, target: testTarget())
    let cancelled = try await coordinator.cancel()
    let removedSnapshot = try await repository.load(sessionID: sessionID)

    XCTAssertEqual(cancelled.phase, .cancelled)
    XCTAssertNil(removedSnapshot)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journalRoot.path))
    try await repository.checkpointAndClose()
  }

  func testCaptureCommitsAllChunksWhileUnrelatedASRIsSlowAndCrashes() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(900))
    let repositoryURL = root.appendingPathComponent("history.sqlite")
    let repository = try GRDBDictationStore(databaseURL: repositoryURL)
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets")
    )
    let capture = FixtureMicrophoneCapture(chunkCount: 6)
    let state = DictationSessionActor(clock: FixedDictationClock(value: 100))
    let coordinator = DictationCaptureCoordinator(
      sessionActor: state,
      capture: capture,
      journal: journal,
      repository: repository
    )
    let unrelatedInference = Task {
      try await SlowCrashingASR().recognize(
        DictationASRRequest(
          sessionID: sessionID,
          inputRevision: 1,
          audio: [],
          dictionaryTerms: []
        )
      )
    }

    let recording = try await coordinator.start(
      sessionID: sessionID,
      target: testTarget()
    )
    XCTAssertEqual(recording.phase, .recording)
    let paused = try await coordinator.pause()
    XCTAssertEqual(paused.phase, .paused)
    let resumed = try await coordinator.resume()
    XCTAssertEqual(resumed.phase, .recording)
    let finalized = try await coordinator.end()

    XCTAssertEqual(finalized.snapshot.phase, .recognizing)
    XCTAssertEqual(finalized.audio.count, 6)
    let recovery = try await journal.recover(sessionID: sessionID)
    XCTAssertEqual(recovery.readableCommittedChunkCount, 6)
    XCTAssertEqual(recovery.issueCount, 0)
    do {
      _ = try await unrelatedInference.value
      XCTFail("Expected unrelated inference failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .transientRuntime)
    }
    try await repository.checkpointAndClose()

    let reopened = try GRDBDictationStore(databaseURL: repositoryURL)
    let durable = try await reopened.load(sessionID: sessionID)
    XCTAssertEqual(durable?.phase, .recognizing)
    XCTAssertEqual(durable?.sessionID, sessionID)
    try await reopened.checkpointAndClose()
  }

  func testTerminalCaptureFailurePreservesJournalAndPersistsRecoverableState() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(910))
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets")
    )
    let failure = try DictationFailure(
      stage: .capture,
      category: .resourcePressure,
      code: "microphone-buffer-overflow",
      retryable: true,
      recoveryPhase: .recording
    )
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(clock: FixedDictationClock(value: 200)),
      capture: FixtureMicrophoneCapture(chunkCount: 2, terminalFailure: failure),
      journal: journal,
      repository: repository
    )
    _ = try await coordinator.start(sessionID: sessionID, target: testTarget())
    do {
      _ = try await coordinator.end()
      XCTFail("Expected terminal capture failure")
    } catch let error as DictationCaptureCoordinatorError {
      XCTAssertEqual(error, .captureTerminated(failure))
    }
    let stored = try await repository.load(sessionID: sessionID)
    XCTAssertEqual(stored?.phase, .failedRecoverable)
    XCTAssertEqual(stored?.failure, failure)
    let recovery = try await journal.recover(sessionID: sessionID)
    XCTAssertEqual(recovery.readableCommittedChunkCount, 2)
    try await repository.checkpointAndClose()
  }

  func testStartupRecoveryReopensIncompleteCaptureWithoutFalseCompletion() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(920))
    let repositoryURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets")
    let firstRepository = try GRDBDictationStore(databaseURL: repositoryURL)
    let firstJournal = try ProductionAudioJournal(assetRootURL: assetRoot)
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 300))
    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: testTarget())
    )
    try await firstRepository.create(preparing)
    try await firstJournal.create(
      sessionID: sessionID,
      descriptor: captureDescriptor(sessionID: sessionID)
    )
    let recording = try await actor.handle(.preparationSucceeded)
    try await firstRepository.save(recording)
    try await firstJournal.append(
      sessionID: sessionID,
      chunk: captureChunk(sequence: 0)
    )
    try await firstRepository.checkpointAndClose()

    let restartedRepository = try GRDBDictationStore(databaseURL: repositoryURL)
    let restartedJournal = try ProductionAudioJournal(assetRootURL: assetRoot)
    let recovery = DictationStartupRecovery(
      repository: restartedRepository,
      journal: restartedJournal
    )
    let candidates = try await recovery.scan()

    XCTAssertEqual(candidates.count, 1)
    XCTAssertEqual(candidates[0].snapshot.phase, .recording)
    XCTAssertEqual(candidates[0].disposition, .readyToFinalize)
    XCTAssertEqual(candidates[0].journal?.committedChunkCount, 1)
    XCTAssertEqual(candidates[0].journal?.sealed, false)
    let reopenedSnapshot = try await restartedRepository.load(sessionID: sessionID)
    XCTAssertEqual(reopenedSnapshot?.phase, .recording)
    try await restartedRepository.checkpointAndClose()
  }

  func testStartupRecoveryFinishesInterruptedCancellationCleanup() async throws {
    let root = try captureTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(testUUID(930))
    let repositoryURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets")
    let firstRepository = try GRDBDictationStore(databaseURL: repositoryURL)
    let firstJournal = try ProductionAudioJournal(assetRootURL: assetRoot)
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 400))
    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: testTarget())
    )
    try await firstRepository.create(preparing)
    try await firstJournal.create(
      sessionID: sessionID,
      descriptor: captureDescriptor(sessionID: sessionID)
    )
    let recording = try await actor.handle(.preparationSucceeded)
    try await firstRepository.save(recording)
    let cancelling = try await actor.handle(.cancel)
    try await firstRepository.save(cancelling)
    let journalRoot = await firstJournal.journalRootURL(sessionID: sessionID)
    try await firstRepository.checkpointAndClose()

    let restartedRepository = try GRDBDictationStore(databaseURL: repositoryURL)
    let recovery = DictationStartupRecovery(
      repository: restartedRepository,
      journal: try ProductionAudioJournal(assetRootURL: assetRoot)
    )
    let candidates = try await recovery.scan()
    let removedSnapshot = try await restartedRepository.load(sessionID: sessionID)

    XCTAssertEqual(candidates.count, 1)
    XCTAssertEqual(candidates[0].snapshot.phase, .cancelling)
    XCTAssertEqual(candidates[0].disposition, .cleanupCompleted)
    XCTAssertNil(removedSnapshot)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journalRoot.path))
    try await restartedRepository.checkpointAndClose()
  }
}

private actor RecordingCommittedChunkObserver: DictationCommittedChunkObserver {
  enum Event: Equatable {
    case committed
    case sentence
    case resumed
    case final
  }

  private var recordedEvents: [Event] = []

  func didCommit(sessionID: SessionID, chunk: CapturedPCMChunk) async {
    recordedEvents.append(.committed)
  }

  func didReachBoundary(
    sessionID: SessionID,
    kind: TranscriptRevisionKind
  ) async {
    recordedEvents.append(kind == .final ? .final : .sentence)
  }

  func didResume(sessionID: SessionID) async {
    recordedEvents.append(.resumed)
  }

  func events() -> [Event] {
    recordedEvents
  }
}

private actor FixtureMicrophoneCapture: MicrophoneCapturePort {
  private let chunkCount: Int
  private let configuredFailure: DictationFailure?
  private var stream: AsyncStream<CapturedPCMChunk>?
  private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
  private var sessionID: SessionID?

  init(chunkCount: Int, terminalFailure: DictationFailure? = nil) {
    self.chunkCount = chunkCount
    configuredFailure = terminalFailure
  }

  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
    self.sessionID = sessionID
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(16)
    )
    stream = pair.stream
    continuation = pair.continuation
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "builtin-fixture",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
  }

  func start() async throws {
    for sequence in 0..<chunkCount {
      let samples = [Float(sequence), Float(sequence) + 0.5]
      let bytes = samples.withUnsafeBytes { Data($0) }
      continuation?.yield(
        CapturedPCMChunk(
          sequence: UInt64(sequence),
          monotonicStartNanoseconds: UInt64(sequence) * 1_000,
          frameCount: 2,
          sampleRateHertz: 48_000,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: bytes
        )
      )
    }
  }

  func chunks() async -> AsyncStream<CapturedPCMChunk> {
    stream ?? AsyncStream { $0.finish() }
  }
  func pause() async throws {}
  func resume() async throws {}
  func stop() async throws { continuation?.finish() }
  func cancel() async { continuation?.finish() }
  func terminalFailure() async -> DictationFailure? { configuredFailure }
}

private actor PersistenceOrderProbeCapture: MicrophoneCapturePort {
  private let base: FixtureMicrophoneCapture
  private let repository: GRDBDictationStore
  private let sessionID: SessionID
  private var existedAtStart: Bool?

  init(base: FixtureMicrophoneCapture, repository: GRDBDictationStore, sessionID: SessionID) {
    self.base = base
    self.repository = repository
    self.sessionID = sessionID
  }

  func sessionExistedAtStart() -> Bool? { existedAtStart }

  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
    try await base.prepare(sessionID: sessionID)
  }
  func start() async throws {
    existedAtStart = (try? await repository.load(sessionID: sessionID)) != nil
    try await base.start()
  }
  func chunks() async -> AsyncStream<CapturedPCMChunk> { await base.chunks() }
  func pause() async throws { try await base.pause() }
  func resume() async throws { try await base.resume() }
  func stop() async throws { try await base.stop() }
  func cancel() async { await base.cancel() }
  func terminalFailure() async -> DictationFailure? { await base.terminalFailure() }
}

private actor FailingStartCapture: MicrophoneCapturePort {
  struct Failure: Error {}

  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
    MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "builtin-fixture",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
  }
  func start() async throws { throw Failure() }
  func chunks() async -> AsyncStream<CapturedPCMChunk> { AsyncStream { $0.finish() } }
  func pause() async throws {}
  func resume() async throws {}
  func stop() async throws {}
  func cancel() async {}
  func terminalFailure() async -> DictationFailure? { nil }
}

private struct SlowCrashingASR: DictationASRPort {
  func recognize(_ request: DictationASRRequest) async throws
    -> DictationTranscriptResult
  {
    try await Task.sleep(for: .milliseconds(25))
    throw InferenceEngineError(
      category: .transientRuntime,
      code: "fixture-crash",
      retryable: true
    )
  }
}

private func captureTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func captureDescriptor(sessionID: SessionID) -> MicrophoneCaptureDescriptor {
  MicrophoneCaptureDescriptor(
    sessionID: sessionID,
    deviceUID: "builtin-fixture",
    sampleRateHertz: 48_000,
    channelCount: 1,
    encoding: .float32LittleEndian,
    interleaved: true
  )
}

private func captureChunk(sequence: UInt64) -> CapturedPCMChunk {
  let samples: [Float] = [0.25, -0.25]
  return CapturedPCMChunk(
    sequence: sequence,
    monotonicStartNanoseconds: sequence * 1_000,
    frameCount: UInt64(samples.count),
    sampleRateHertz: 48_000,
    channelCount: 1,
    encoding: .float32LittleEndian,
    interleaved: true,
    bytes: samples.withUnsafeBytes { Data($0) }
  )
}
