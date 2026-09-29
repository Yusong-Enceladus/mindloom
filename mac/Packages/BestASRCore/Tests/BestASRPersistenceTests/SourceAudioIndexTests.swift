import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

final class SourceAudioIndexTests: XCTestCase {
  func testEveryModeIndexesSourceAtSealWithoutAnyTranscript() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets"), sourceIndex: store
    )
    let roles: [SessionInputMode: SourceTrackRole] = [
      .dictation: .microphoneLocal, .roomMicrophone: .roomMicrophone,
      .systemAudio: .systemRemote, .importedMedia: .importedSource,
    ]
    // Every audio mode; a pasted or dragged item is never a capture.
    for mode in SessionInputMode.allCases where mode != .userItem {
      let sessionID = SessionID()
      let track = track(role: try XCTUnwrap(roles[mode]), rate: 48_000)
      try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: mode)
      try await journal.create(
        sessionID: sessionID, descriptor: descriptor(sessionID, tracks: [track]))
      for (sequence, start) in [UInt64(10), 11, 40].enumerated() {
        try await journal.append(
          sessionID: sessionID,
          chunk: captured(track, sequence: UInt64(sequence), start: start * 1_000_000_000)
        )
      }
      let before = try await store.loadHistory()
      XCTAssertNil(before.first { $0.sessionID == sessionID }?.durationNanoseconds)
      let ranges = try await journal.seal(sessionID: sessionID)
      let source = try Data(
        contentsOf: root.appendingPathComponent("assets/" + ranges[0].assetReference))
      _ = try await journal.seal(sessionID: sessionID)
      let after = try await store.loadHistory()
      let item = try XCTUnwrap(after.first { $0.sessionID == sessionID })
      XCTAssertNil(item.rawText, "Duration must not require a successful ASR job.")
      XCTAssertEqual(
        item.durationNanoseconds, 3_000_000_000, "Paused wall time is not source audio.")
      XCTAssertEqual(item.revision, 1, "Adding the projection must not revise the user's record.")
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("assets/" + ranges[0].assetReference)),
        source
      )
    }
    let usage = try await store.historyUsageStatistics()
    XCTAssertEqual(usage.recordedDurationNanoseconds, 12_000_000_000)
    XCTAssertEqual(usage.sessionCount, 4)
    XCTAssertEqual(usage.currentTextCharacterCount, 0)
    let activity = try await store.dictationActivityRecords()
    XCTAssertEqual(activity.map(\.speechNanoseconds), [3_000_000_000], "Home counts dictation only.")
    XCTAssertEqual(activity.first?.text, "")
    try await store.checkpointAndClose()
  }

  func testRecoveryBackfillsLegacyPrefixAndSealAddsOnlyNewBlocks() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID()
    let track = track(role: .roomMicrophone, rate: 44_100)
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .roomMicrophone)
    let assets = root.appendingPathComponent("assets")
    let legacy = try ProductionAudioJournal(assetRootURL: assets)
    try await legacy.create(
      sessionID: sessionID, descriptor: descriptor(sessionID, tracks: [track]))
    try await legacy.append(
      sessionID: sessionID, chunk: captured(track, sequence: 0, start: 10_000_000_000))
    try await store.save(
      DictationSessionSnapshot(
        sessionID: sessionID, revision: 2, phase: .failedRecoverable, target: nil, timeline: [],
        failure: try DictationFailure(
          stage: .recognition, category: .modelUnavailable,
          code: "fixture-interrupted-before-index", retryable: true, recoveryPhase: .recognizing
        )
      )
    )
    let missing = try await store.sessionsMissingSourceAudioIndex()
    XCTAssertEqual(missing, [sessionID])
    let restarted = try ProductionAudioJournal(assetRootURL: assets, sourceIndex: store)
    let recovery = try await restarted.recoveryStatus(sessionID: sessionID)
    XCTAssertFalse(recovery.sealed)
    XCTAssertEqual(recovery.committedChunkCount, 1)
    let indexed = try await store.sessionsMissingSourceAudioIndex()
    XCTAssertTrue(indexed.isEmpty)
    try await restarted.append(
      sessionID: sessionID, chunk: captured(track, sequence: 1, start: 40_000_000_000))
    _ = try await restarted.seal(sessionID: sessionID)
    try await restarted.synchronizeSourceIndex(sessionID: sessionID)
    let history = try await store.loadHistory()
    XCTAssertEqual(history.first?.durationNanoseconds, 2_000_000_000)
    let queue = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path)
    let count = try await queue.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM audio_chunks")
    }
    XCTAssertEqual(count, 2, "Recovery, seal and repeated indexing must be idempotent.")
    try queue.close()
    try await store.checkpointAndClose()
  }

  func testOverlappingAndSuccessiveDeviceTracksHaveOneUnionDuration() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID()
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .systemAudio)
    let tracks = [
      track(role: .systemRemote, rate: 48_000), track(role: .microphoneLocal, rate: 16_000),
      track(role: .systemRemote, rate: 44_100),
    ]
    let chunks = try [
      indexed(sessionID, tracks[0], sequence: 0, start: 10_000_000_000, seconds: 2),
      indexed(sessionID, tracks[0], sequence: 1, start: 15_000_000_000, seconds: 1),
      indexed(sessionID, tracks[1], sequence: 0, start: 10_500_000_000, seconds: 2),
      indexed(sessionID, tracks[2], sequence: 0, start: 19_000_000_000, seconds: 1),
    ]
    try await store.indexCommittedSourceAudio(sessionID: sessionID, tracks: tracks, chunks: chunks)
    let history = try await store.loadHistory()
    let usage = try await store.historyUsageStatistics()
    XCTAssertEqual(history.first?.durationNanoseconds, 4_500_000_000)
    XCTAssertEqual(usage.recordedDurationNanoseconds, 4_500_000_000)
    try await store.markSessionSourceAudioExplicitlyDeleted(sessionID: sessionID)
    let deleted = try await store.loadHistory()
    XCTAssertEqual(
      deleted.first?.durationNanoseconds, 4_500_000_000, "Source-only deletion keeps metadata.")
    XCTAssertEqual(deleted.first?.sourceAudioRetained, false)
    let later = try indexed(sessionID, tracks[2], sequence: 1, start: 20_000_000_000, seconds: 1)
    try await store.indexCommittedSourceAudio(
      sessionID: sessionID, tracks: tracks, chunks: chunks + [later])
    let afterLateIndex = try await store.historyUsageStatistics()
    XCTAssertEqual(
      afterLateIndex.recordedDurationNanoseconds, 4_500_000_000,
      "Do not revive deleted source handles.")
    try await store.checkpointAndClose()
  }

  func testConflictingReplayRollsBackNewMetadataWithoutChangingEvidence() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID()
    let track = track(role: .importedSource, rate: 48_000)
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .importedMedia)
    let first = try indexed(sessionID, track, sequence: 0, start: 10_000_000_000, seconds: 1)
    try await store.indexCommittedSourceAudio(
      sessionID: sessionID, tracks: [track], chunks: [first])
    let second = try indexed(sessionID, track, sequence: 1, start: 11_000_000_000, seconds: 1)
    let conflicting = try indexed(sessionID, track, sequence: 0, start: 30_000_000_000, seconds: 1)
    do {
      try await store.indexCommittedSourceAudio(
        sessionID: sessionID, tracks: [track], chunks: [second, conflicting])
      XCTFail("A different source interval at the same sequence must fail closed.")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .processingCommitConflict)
    }
    let history = try await store.loadHistory()
    XCTAssertEqual(history.first?.durationNanoseconds, 1_000_000_000)
    XCTAssertEqual(history.first?.revision, 1)
    try await store.checkpointAndClose()
  }

  func testIndexFailureAtSealLeavesSourceIntactAndRetriesFromSealedJournal() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID()
    let track = track(role: .roomMicrophone, rate: 48_000)
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .roomMicrophone)
    let index = FailingFirstSourceIndex(repository: store)
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets"), sourceIndex: index)
    try await journal.create(
      sessionID: sessionID, descriptor: descriptor(sessionID, tracks: [track]))
    let chunk = captured(track, sequence: 0, start: 10_000_000_000)
    try await journal.append(sessionID: sessionID, chunk: chunk)
    do {
      _ = try await journal.seal(sessionID: sessionID)
      XCTFail("The injected index failure must not look like a completed history commit.")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .databaseAlreadyClosed)
    }
    let ranges = try await journal.seal(sessionID: sessionID)
    XCTAssertEqual(ranges.count, 1)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("assets/" + ranges[0].assetReference)),
      chunk.bytes)
    let history = try await store.loadHistory()
    XCTAssertEqual(history.first?.durationNanoseconds, 1_000_000_000)
    try await store.checkpointAndClose()
  }

  private func track(role: SourceTrackRole, rate: UInt32) -> CaptureTrackDescriptor {
    CaptureTrackDescriptor(
      role: role, deviceUID: "synthetic-duration-fixture", sampleRateHertz: rate, channelCount: 1,
      encoding: .float32LittleEndian, interleaved: true)
  }

  private func descriptor(_ id: SessionID, tracks: [CaptureTrackDescriptor])
    -> MicrophoneCaptureDescriptor
  {
    MicrophoneCaptureDescriptor(
      sessionID: id, deviceUID: "synthetic-duration-fixture",
      sampleRateHertz: tracks[0].sampleRateHertz, channelCount: 1, encoding: .float32LittleEndian,
      interleaved: true, tracks: tracks)
  }

  private func captured(_ track: CaptureTrackDescriptor, sequence: UInt64, start: UInt64)
    -> CapturedPCMChunk
  {
    CapturedPCMChunk(
      trackID: track.id, sequence: sequence, monotonicStartNanoseconds: start,
      frameCount: UInt64(track.sampleRateHertz), sampleRateHertz: track.sampleRateHertz,
      channelCount: 1, encoding: .float32LittleEndian, interleaved: true,
      bytes: Data(repeating: 0, count: Int(track.sampleRateHertz) * 4))
  }

  private func indexed(
    _ id: SessionID, _ track: CaptureTrackDescriptor, sequence: UInt64, start: UInt64,
    seconds: UInt64
  ) throws -> CommittedSourceAudioChunk {
    CommittedSourceAudioChunk(
      trackID: track.id, sequence: sequence, monotonicStartNanoseconds: start,
      frameCount: UInt64(track.sampleRateHertz) * seconds, sampleRateHertz: track.sampleRateHertz,
      contentDigest: try persistenceDigest("a"),
      assetReference: try PortableAssetReference(
        relativePath:
          "sessions/\(id.rawValue.uuidString.lowercased())/journal/chunks/\(track.id.rawValue.uuidString)-\(sequence).pcm"
      ))
  }
}

private actor FailingFirstSourceIndex: SourceAudioIndexRepositoryPort {
  let repository: GRDBDictationStore
  private var failed = false

  init(repository: GRDBDictationStore) { self.repository = repository }

  func indexCommittedSourceAudio(
    sessionID: SessionID, tracks: [CaptureTrackDescriptor], chunks: [CommittedSourceAudioChunk]
  ) async throws {
    if !failed {
      failed = true
      throw BestASRPersistenceError.databaseAlreadyClosed
    }
    try await repository.indexCommittedSourceAudio(
      sessionID: sessionID, tracks: tracks, chunks: chunks)
  }
}
