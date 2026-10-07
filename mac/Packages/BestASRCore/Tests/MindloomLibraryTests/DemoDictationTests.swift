import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRMacUI
import BestASRPersistence
import Foundation
import XCTest

@testable import MindloomLibrary

/// ALIGNMENT 根-10: a dictation made in demo mode is typed in but not kept.
/// Its capture is never made eligible for the organizing device, and once
/// its words reached the owner (or at the next launch, after a crash, when
/// they had) its records and audio leave the demo library; a take whose
/// words did not reach the owner stays with its audio (review v12-B #1);
/// everything else in the library stays.
final class DemoDictationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("demo-dictation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func record(
    _ id: UUID, keep: Bool, repository: GRDBDictationStore, journal: ProductionAudioJournal
  ) async throws {
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(),
      capture: OneChunkCapture(),
      journal: journal,
      repository: repository,
      grantsRemoteEligibility: keep)
    _ = try await coordinator.start(sessionID: SessionID(id), target: nil)
    _ = try await coordinator.end()
  }

  private func audioFolder(_ id: UUID) -> URL {
    root.appendingPathComponent("assets/sessions/\(id.uuidString.lowercased())", isDirectory: true)
  }

  func testADemoDictationLeavesNothingBehind() async throws {
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite"))
    try await repository.enableRemoteLink(at: Date(timeIntervalSince1970: 1_000))
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let ledger = DemoDictationLedger(dataRoot: root)

    // An ordinary take that belongs to the library.
    let kept = UUID()
    try await record(kept, keep: true, repository: repository, journal: journal)
    // The demo dictation: on the ledger before its session exists.
    let demo = UUID()
    try ledger.add(demo)
    try await record(demo, keep: false, repository: repository, journal: journal)
    let eligible = try await repository.isRemoteEligible(sessionID: SessionID(demo))
    XCTAssertFalse(eligible)
    let made = try await repository.load(sessionID: SessionID(demo))
    XCTAssertNotNil(made)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFolder(demo).path))

    let removed = await DemoDictationRemoval.remove(
      SessionID(demo), ledger: ledger, journal: journal, repository: repository)
    XCTAssertTrue(removed)
    let gone = try await repository.load(sessionID: SessionID(demo))
    XCTAssertNil(gone)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioFolder(demo).path))
    XCTAssertEqual(ledger.pending(), [])
    // The library's own take is untouched.
    let stays = try await repository.load(sessionID: SessionID(kept))
    XCTAssertNotNil(stays)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFolder(kept).path))
    try await repository.checkpointAndClose()
  }

  /// Review v12-B #1 (regression): a demo take an earlier run left behind
  /// is removed at launch only when its words were typed in. One that was
  /// still listening or failed stays with its audio (a crash is never
  /// permission to delete what was said); one that never got a session only
  /// leaves the ledger.
  func testLeftoversAreRemovedOnlyWhenTheirWordsWereTypedIn() async throws {
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite"))
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let ledger = DemoDictationLedger(dataRoot: root)
    let interrupted = UUID()
    let typedIn = UUID()
    let neverStarted = UUID()
    try ledger.add(interrupted)
    try ledger.add(typedIn)
    try ledger.add(neverStarted)
    try await record(interrupted, keep: false, repository: repository, journal: journal)
    try await record(typedIn, keep: false, repository: repository, journal: journal)
    let stored = try await repository.load(sessionID: SessionID(interrupted))
    XCTAssertFalse(
      DemoDictationKeeping.wordsReachedOwner(try XCTUnwrap(stored), copiedFinalWords: false))

    let typedInID = SessionID(typedIn)
    let left = await DemoDictationRemoval.removeLeftovers(
      ledger: ledger, journal: journal, repository: repository,
      wordsReachedOwner: { $0.sessionID == typedInID })
    XCTAssertEqual(left, 0)
    XCTAssertEqual(ledger.pending(), [])
    // Still listening when the run stopped: kept, audio and all.
    let kept = try await repository.load(sessionID: SessionID(interrupted))
    XCTAssertNotNil(kept)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFolder(interrupted).path))
    // Typed in before the run stopped: gone.
    let gone = try await repository.load(sessionID: typedInID)
    XCTAssertNil(gone)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioFolder(typedIn).path))
    try await repository.checkpointAndClose()
  }

  /// Review v12-B #1 (regression): the processing-failure path in demo mode.
  /// The take failed, so its words did not reach the owner: the HUD says
  /// 「没能转成文字，录音已保存，可以在历史里重试」, and that is true — the take
  /// leaves the ledger (the App's `keepDemoDictation`) and its record and
  /// audio are still there at the next launch. Before the fix the App
  /// removed both while the HUD said they were kept.
  func testAFailedDemoTakeIsKeptAndTheHUDSaysSo() async throws {
    let repository = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite"))
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let ledger = DemoDictationLedger(dataRoot: root)
    let demo = UUID()
    try ledger.add(demo)
    try await record(demo, keep: false, repository: repository, journal: journal)

    let failed = DictationSessionSnapshot(
      sessionID: SessionID(demo), revision: 3, phase: .failedRecoverable,
      failure: try DictationFailure(
        stage: .recognition, category: .transientRuntime, code: "recognition.engine-failed",
        retryable: true, recoveryPhase: .recognizing))
    let reached = DemoDictationKeeping.wordsReachedOwner(failed, copiedFinalWords: false)
    XCTAssertFalse(reached)
    let notice = try XCTUnwrap(
      FnHUDPresentation.Notice.ending(
        for: failed, facts: FnHUDTakeFacts(leavesLibrary: reached)))
    XCTAssertEqual(notice.kind, .failed)
    XCTAssertEqual(notice.text, "无法转写，录音已保存。可以在“历史”中重试")
    // Even a draft copied on the way out does not make it leave.
    XCTAssertFalse(DemoDictationKeeping.wordsReachedOwner(failed, copiedFinalWords: true))

    // Kept: off the ledger, so the next launch leaves it alone.
    ledger.remove(demo)
    await DemoDictationRemoval.removeLeftovers(
      ledger: ledger, journal: journal, repository: repository)
    let stays = try await repository.load(sessionID: SessionID(demo))
    XCTAssertNotNil(stays)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFolder(demo).path))
    let eligible = try await repository.isRemoteEligible(sessionID: SessionID(demo))
    XCTAssertFalse(eligible, "a kept demo take still never reaches a DGX Spark")
    try await repository.checkpointAndClose()
  }

  /// When a demo take's words reached the owner (and only then) it leaves.
  func testWordsReachedTheOwnerOnlyWhenTypedInOrCopiedWhole() throws {
    let id = SessionID(UUID())
    func completed(inserted: Bool) throws -> DictationSessionSnapshot {
      DictationSessionSnapshot(
        sessionID: id, revision: 4, phase: .completed,
        transcript: DictationTranscriptResult(
          revisionID: TranscriptRevisionID(), segmentIDs: [], text: "好", modelArtifactID: "f"),
        insertion: DictationInsertionResult(
          idempotencyKey: try DictationIdempotencyKey("demo-\(inserted)"),
          method: inserted ? .clipboardPaste : .retainedForCopy, inserted: inserted,
          failureReason: inserted ? nil : .nowhere))
    }
    XCTAssertTrue(
      DemoDictationKeeping.wordsReachedOwner(try completed(inserted: true), copiedFinalWords: false)
    )
    XCTAssertTrue(
      DemoDictationKeeping.wordsReachedOwner(try completed(inserted: false), copiedFinalWords: true)
    )
    XCTAssertFalse(
      DemoDictationKeeping.wordsReachedOwner(
        try completed(inserted: false), copiedFinalWords: false))
    for phase in [DictationPhase.recording, .recognizing, .finalizing] {
      XCTAssertFalse(
        DemoDictationKeeping.wordsReachedOwner(
          DictationSessionSnapshot(sessionID: id, revision: 2, phase: phase),
          copiedFinalWords: true), "\(phase)")
    }
  }
}

/// A microphone that delivers one short chunk of synthetic samples.
private actor OneChunkCapture: MicrophoneCapturePort {
  private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
  private var stream: AsyncStream<CapturedPCMChunk>?

  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
    let pair = AsyncStream.makeStream(of: CapturedPCMChunk.self, bufferingPolicy: .unbounded)
    stream = pair.stream
    continuation = pair.continuation
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID, deviceUID: "synthetic", sampleRateHertz: 48_000, channelCount: 1,
      encoding: .float32LittleEndian, interleaved: true)
  }

  func start() async throws {
    let samples: [Float] = [0.25, -0.25]
    continuation?.yield(
      CapturedPCMChunk(
        sequence: 0, monotonicStartNanoseconds: 0, frameCount: 2, sampleRateHertz: 48_000,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true,
        bytes: samples.withUnsafeBytes { Data($0) }))
  }

  func chunks() async -> AsyncStream<CapturedPCMChunk> { stream ?? AsyncStream { $0.finish() } }
  func pause() async throws {}
  func resume() async throws {}
  func stop() async throws { continuation?.finish() }
  func cancel() async { continuation?.finish() }
  func terminalFailure() async -> DictationFailure? { nil }
}
