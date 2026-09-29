import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation
import XCTest

@testable import bestASR

@MainActor
final class SilentTakeRetentionTests: XCTestCase {
  func testCommittedSilenceAndItsRecordSurviveAutomaticCleanup() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let silence = Data(repeating: 0, count: 48_000 * MemoryLayout<Float>.size)
    try await fixture.journal.append(
      sessionID: fixture.sessionID, chunk: chunk(silence))
    let ranges = try await fixture.journal.seal(sessionID: fixture.sessionID)
    let source = fixture.assetRoot.appendingPathComponent(
      try XCTUnwrap(ranges.first).assetReference)
    let failure = try DictationFailure(
      stage: .recognition, category: .corruptInput, code: "dictation-asr-no-speech-detected",
      retryable: true, recoveryPhase: .recognizing)
    let silentSnapshot = DictationSessionSnapshot(
      sessionID: fixture.sessionID, revision: 2, phase: .failedRecoverable, failure: failure)
    try await fixture.store.save(silentSnapshot)

    let deleted = await fixture.model.discardVerifiedEmptyTake(fixture.sessionID)

    XCTAssertFalse(deleted)
    XCTAssertEqual(try Data(contentsOf: source), silence)
    let saved = try await fixture.store.load(sessionID: fixture.sessionID)
    XCTAssertEqual(saved, silentSnapshot)
    let report = try await fixture.journal.recover(sessionID: fixture.sessionID)
    XCTAssertEqual(report.readableCommittedChunkCount, 1)
    XCTAssertEqual(report.issueCount, 0)
    let rows = try await fixture.store.loadHistory()
    XCTAssertTrue(try XCTUnwrap(rows.first).sourceAudioRetained)
    try await fixture.store.checkpointAndClose()
  }

  func testOnlyVerifiedEmptyTakeIsRemovedAndOtherRecordsRemain() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let other = SessionID()
    try await fixture.store.create(
      DictationSessionSnapshot(sessionID: other, revision: 1, phase: .preparing))
    fixture.model.startupRecoverySessionIDs = [fixture.sessionID, other]
    let journalRoot = await fixture.journal.journalRootURL(sessionID: fixture.sessionID)

    let emptySnapshot = try await fixture.store.load(sessionID: fixture.sessionID)
    let remaining = await fixture.model.cleanUpVerifiedEmptyRecoveryCandidates([
      DictationRecoveryCandidate(
        snapshot: try XCTUnwrap(emptySnapshot),
        journal: DictationJournalRecoveryStatus(
          committedChunkCount: 0, issueCount: 0, sealed: false),
        disposition: .requiresRepair),
      DictationRecoveryCandidate(
        snapshot: DictationSessionSnapshot(sessionID: other, revision: 1, phase: .preparing),
        journal: nil, disposition: .requiresRepair),
    ])

    XCTAssertEqual(remaining.compactMap { $0.snapshot.sessionID }, [other])
    XCTAssertEqual(DictationAppModel.startupRecoverySessionIDs(from: remaining), [other])
    let emptyRow = try await fixture.store.load(sessionID: fixture.sessionID)
    let otherRow = try await fixture.store.load(sessionID: other)
    XCTAssertNil(emptyRow)
    XCTAssertNotNil(otherRow)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journalRoot.path))
    XCTAssertEqual(fixture.model.startupRecoverySessionIDs, [other])
    try await fixture.store.checkpointAndClose()
  }

  func testMissingJournalMetadataCannotAuthorizeDeletion() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let journalRoot = await fixture.journal.journalRootURL(sessionID: fixture.sessionID)
    try FileManager.default.removeItem(
      at: journalRoot.appendingPathComponent("production-metadata.json"))

    let deleted = await fixture.model.discardVerifiedEmptyTake(fixture.sessionID)

    XCTAssertFalse(deleted)
    let saved = try await fixture.store.load(sessionID: fixture.sessionID)
    XCTAssertNotNil(saved)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journalRoot.path))
    fixture.model.journal = nil
    let withoutJournal = await fixture.model.discardVerifiedEmptyTake(fixture.sessionID)
    XCTAssertFalse(withoutJournal)
    try await fixture.store.checkpointAndClose()
  }

  func testEarlierQuarantinedAudioSurvivesRepeatedCleanupChecks() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    do {
      try await fixture.journal.append(
        sessionID: fixture.sessionID,
        chunk: chunk(Data(repeating: 0, count: 256)), faultPoint: .afterPartialStagingWrite)
      XCTFail("Expected a partial write fault")
    } catch let error as AudioJournalError {
      XCTAssertEqual(error, .injectedCrash(.afterPartialStagingWrite))
    }
    let firstRecovery = try await fixture.journal.recover(sessionID: fixture.sessionID)
    XCTAssertGreaterThan(firstRecovery.quarantinedByteCount, 0)
    XCTAssertGreaterThan(firstRecovery.issueCount, 0)
    let journalRoot = await fixture.journal.journalRootURL(sessionID: fixture.sessionID)
    let quarantined = try FileManager.default.contentsOfDirectory(
      at: journalRoot.appendingPathComponent("quarantine"), includingPropertiesForKeys: nil)
    let source = try XCTUnwrap(quarantined.first)
    let originalBytes = try Data(contentsOf: source)

    // The second recovery can report no NEW quarantine bytes or issues.
    // Existing isolated source bytes still prohibit automatic deletion.
    let snapshot = try await fixture.store.load(sessionID: fixture.sessionID)
    let status = try await fixture.journal.recoveryStatus(sessionID: fixture.sessionID)
    XCTAssertEqual(status.committedChunkCount, 0)
    XCTAssertEqual(status.issueCount, 0)
    let remaining = await fixture.model.cleanUpVerifiedEmptyRecoveryCandidates([
      DictationRecoveryCandidate(
        snapshot: try XCTUnwrap(snapshot), journal: status, disposition: .requiresRepair)
    ])

    XCTAssertEqual(remaining.compactMap { $0.snapshot.sessionID }, [fixture.sessionID])
    XCTAssertEqual(
      DictationAppModel.startupRecoverySessionIDs(from: remaining), [fixture.sessionID])
    XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    let saved = try await fixture.store.load(sessionID: fixture.sessionID)
    XCTAssertNotNil(saved)
    try await fixture.store.checkpointAndClose()
  }

  func testUnknownOrDamagedRecoveryCandidatesAreNotEmptyTakes() {
    let snapshot = DictationSessionSnapshot(sessionID: SessionID(), revision: 1, phase: .recording)
    for journal in [
      nil,
      DictationJournalRecoveryStatus(committedChunkCount: 0, issueCount: 1, sealed: false),
      DictationJournalRecoveryStatus(committedChunkCount: 1, issueCount: 0, sealed: true),
    ] {
      XCTAssertFalse(
        DictationAppModel.isTakeWithoutAudio(
          DictationRecoveryCandidate(
            snapshot: snapshot, journal: journal, disposition: .requiresRepair)))
    }
    XCTAssertTrue(
      DictationAppModel.isTakeWithoutAudio(
        DictationRecoveryCandidate(
          snapshot: snapshot,
          journal: DictationJournalRecoveryStatus(
            committedChunkCount: 0, issueCount: 0, sealed: false),
          disposition: .requiresRepair)))
  }

  private struct Fixture {
    let root: URL
    let assetRoot: URL
    let sessionID: SessionID
    let store: GRDBDictationStore
    let journal: ProductionAudioJournal
    let model: DictationAppModel
  }

  private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let assetRoot = root.appendingPathComponent("assets")
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID()
    try await store.create(
      DictationSessionSnapshot(sessionID: sessionID, revision: 1, phase: .preparing))
    let journal = try ProductionAudioJournal(assetRootURL: assetRoot, sourceIndex: store)
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "synthetic-silence",
        sampleRateHertz: 48_000, channelCount: 1,
        encoding: .float32LittleEndian, interleaved: true))
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.journal = journal
    return Fixture(
      root: root, assetRoot: assetRoot, sessionID: sessionID,
      store: store, journal: journal, model: model)
  }

  private func chunk(_ bytes: Data) -> CapturedPCMChunk {
    CapturedPCMChunk(
      sequence: 0, monotonicStartNanoseconds: 0,
      frameCount: UInt64(bytes.count / MemoryLayout<Float>.size),
      sampleRateHertz: 48_000, channelCount: 1, encoding: .float32LittleEndian,
      interleaved: true, bytes: bytes)
  }
}
