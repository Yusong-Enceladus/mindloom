import BestASRAudioJournalProbe
import Foundation
import XCTest

final class AudioJournalProbeTests: XCTestCase {
  func testInferenceRangeAppearsOnlyAfterManifestCommit() throws {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }

    XCTAssertEqual(journal.availableInferenceRanges(), [])
    let range = try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 1, count: 32),
      monotonicStartNanoseconds: 10,
      sampleRateHertz: 16_000,
      frameCount: 16
    )
    XCTAssertEqual(journal.availableInferenceRanges(), [range])

    XCTAssertThrowsError(
      try journal.append(
        trackID: "system",
        pcmBytes: Data(repeating: 2, count: 32),
        monotonicStartNanoseconds: 10,
        sampleRateHertz: 16_000,
        frameCount: 16,
        faultPoint: .afterChunkRename
      )
    )
    XCTAssertEqual(journal.availableInferenceRanges(), [range])
  }

  func testNormalFinalizeKeepsBothTracksReadable() throws {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }
    try appendBoth(journal)
    try journal.finalize()
    XCTAssertEqual(journal.manifest.state, .finalized)
    XCTAssertEqual(journal.availableInferenceRanges().count, 2)
    for entry in journal.manifest.committedChunks {
      XCTAssertFalse(try journal.readCommittedChunk(entry).isEmpty)
    }
  }

  func testRecordingReopensFromAppendOnlyCommitLogWithoutManifestRewrites()
    throws
  {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }
    try appendBoth(journal)

    let persistedSnapshot = try JSONDecoder().decode(
      AudioJournalManifest.self,
      from: Data(contentsOf: journal.manifestURL)
    )
    XCTAssertTrue(persistedSnapshot.committedChunks.isEmpty)

    let reopened = try AudioJournal.open(at: journal.rootURL)
    XCTAssertEqual(reopened.manifest.committedChunks.count, 2)
    XCTAssertEqual(reopened.availableInferenceRanges().count, 2)
    XCTAssertEqual(try reopened.nextSequence(for: "microphone"), 1)
    XCTAssertEqual(try reopened.nextSequence(for: "system"), 1)
  }

  func testReopenRepairsTrailingPartialCommitRecordBeforeContinuing() throws {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }
    try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 1, count: 32),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: 16_000,
      frameCount: 16
    )

    let commitLogURL = journal.rootURL.appendingPathComponent("commits.jsonl")
    let handle = try FileHandle(forWritingTo: commitLogURL)
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(#"{"trackID":"microphone""#.utf8))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }

    let reopened = try AudioJournal.open(at: journal.rootURL)
    XCTAssertEqual(reopened.manifest.committedChunks.count, 1)
    XCTAssertEqual(reopened.availableInferenceRanges().count, 1)
    XCTAssertEqual(try reopened.nextSequence(for: "microphone"), 1)

    try reopened.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 2, count: 32),
      monotonicStartNanoseconds: 1_000_000,
      sampleRateHertz: 16_000,
      frameCount: 16
    )
    let reopenedAgain = try AudioJournal.open(at: journal.rootURL)
    XCTAssertEqual(reopenedAgain.manifest.committedChunks.count, 2)
    XCTAssertEqual(reopenedAgain.availableInferenceRanges().count, 2)
    XCTAssertEqual(try reopenedAgain.nextSequence(for: "microphone"), 2)
  }

  func testTruncationCreatesGapAndBlocksFinalize() throws {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }
    try appendBoth(journal)
    let entry = try XCTUnwrap(journal.manifest.committedChunks.first)
    try Data(repeating: 1, count: 4).write(to: journal.chunkURL(for: entry))
    let reopened = try AudioJournal.open(at: journal.rootURL)
    let report = try reopened.recover()
    XCTAssertTrue(report.issues.contains { $0.kind == .truncatedChunk })
    XCTAssertEqual(report.gaps.count, 1)
    XCTAssertEqual(reopened.availableInferenceRanges().count, 1)
    XCTAssertThrowsError(try reopened.finalize())
  }

  func testMissingAndDigestCorruptionNeverFinalize() throws {
    for mutation in ["missing", "digest"] {
      let journal = try makeJournal()
      defer { try? FileManager.default.removeItem(at: journal.rootURL) }
      try appendBoth(journal)
      let entry = try XCTUnwrap(journal.manifest.committedChunks.first)
      let url = journal.chunkURL(for: entry)
      if mutation == "missing" {
        try FileManager.default.removeItem(at: url)
      } else {
        var data = try Data(contentsOf: url)
        data[0] ^= 0xff
        try data.write(to: url)
      }
      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      XCTAssertEqual(report.state, .recoveryRequired)
      XCTAssertEqual(report.gaps.count, 1)
      XCTAssertThrowsError(try reopened.finalize())
    }
  }

  func testPartialStagingRecoveryBoundsUncommittedLoss() throws {
    let journal = try makeJournal()
    defer { try? FileManager.default.removeItem(at: journal.rootURL) }
    let bytes = Data(repeating: 4, count: 128)
    XCTAssertThrowsError(
      try journal.append(
        trackID: "microphone",
        pcmBytes: bytes,
        monotonicStartNanoseconds: 0,
        sampleRateHertz: 16_000,
        frameCount: 64,
        faultPoint: .afterPartialStagingWrite
      )
    )
    let reopened = try AudioJournal.open(at: journal.rootURL)
    let report = try reopened.recover()
    XCTAssertLessThanOrEqual(report.quarantinedByteCount, UInt64(bytes.count))
    XCTAssertEqual(reopened.availableInferenceRanges(), [])
    XCTAssertNotEqual(reopened.manifest.state, .finalized)
  }

  func testInvalidTrackIdentityIsRejected() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(
      try AudioJournal.create(
        at: root,
        sessionID: UUID(),
        tracks: [AudioJournalTrack(trackID: "../escape", role: "invalid")]
      )
    )
  }

  private func makeJournal() throws -> AudioJournal {
    try AudioJournal.create(
      at: temporaryRoot(),
      sessionID: UUID(),
      tracks: [
        AudioJournalTrack(trackID: "microphone", role: "microphoneLocal"),
        AudioJournalTrack(trackID: "system", role: "systemRemote"),
      ]
    )
  }

  private func appendBoth(_ journal: AudioJournal) throws {
    try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 1, count: 32),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: 16_000,
      frameCount: 16
    )
    try journal.append(
      trackID: "system",
      pcmBytes: Data(repeating: 2, count: 32),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: 16_000,
      frameCount: 16
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
