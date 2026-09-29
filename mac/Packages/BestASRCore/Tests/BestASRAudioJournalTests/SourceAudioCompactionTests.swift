import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import XCTest

/// Compaction rewrites recordings the user cannot get back, so these check the
/// three things that would lose something: the audio still plays back through
/// the journal it was written for, a pause is still a pause, and a session
/// whose source cannot be verified is left exactly as it was.
final class SourceAudioCompactionTests: XCTestCase {
  private let sampleRate: UInt32 = 48_000
  private let framesPerChunk = 4_800  // 100 ms

  func testContiguousChunksBecomeOneFileAndAPauseStaysAGap() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    try await record(sessionID: sessionID, root: root, starts: [0, 100, 200, 1_000])

    let outcome = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)

    XCTAssertFalse(outcome.alreadyCompact)
    XCTAssertEqual(outcome.runs.count, 2, "The pause has to split the recording")
    XCTAssertEqual(outcome.runs[0].replacedAssetReferences.count, 3)
    XCTAssertEqual(outcome.runs[1].replacedAssetReferences.count, 1)
    XCTAssertEqual(outcome.originalByteCount, UInt64(4 * framesPerChunk * 4))
    XCTAssertLessThan(
      outcome.compactedByteCount, outcome.originalByteCount / 5,
      "16 kHz 16-bit is a sixth of 48 kHz float32")
    for track in outcome.tracks {
      XCTAssertEqual(track.sampleRateHertz, 16_000)
      XCTAssertEqual(track.encoding, .int16LittleEndian)
    }
    let journalRoot = SourceAudioCompaction.journalRootURL(
      sessionID: sessionID, assetRoot: root)
    let remaining = try FileManager.default.contentsOfDirectory(
      atPath: journalRoot.appendingPathComponent("chunks").path)
    XCTAssertEqual(remaining.count, 2, "The chunks it replaced must be gone")
  }

  func testTheCompactedSessionStillReadsBackWithItsOriginalTiming() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    try await record(sessionID: sessionID, root: root, starts: [0, 100, 200, 1_000])
    let before = try await ProductionAudioJournal(assetRootURL: root)
      .committedAudioSnapshot(sessionID: sessionID)
    let spokenBefore = duration(of: before)

    _ = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)

    // A fresh journal replays the commit log into the manifest and rejects a
    // disagreement, so this is also the check that both were rewritten.
    let reopened = try ProductionAudioJournal(assetRootURL: root)
    let after = try await reopened.committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(after.count, 2)
    XCTAssertEqual(after[0].monotonicStartNanoseconds, before[0].monotonicStartNanoseconds)
    XCTAssertEqual(
      Double(duration(of: after)), Double(spokenBefore), accuracy: 2_000_000,
      "The recorded duration may not move by more than a couple of milliseconds")
    let descriptors = try await reopened.sourceTrackDescriptors(sessionID: sessionID)
    XCTAssertEqual(descriptors.first?.sampleRateHertz, 16_000)
    XCTAssertEqual(descriptors.first?.encoding, .int16LittleEndian)
    for range in after {
      let bytes = try Data(contentsOf: root.appendingPathComponent(range.assetReference))
      XCTAssertFalse(bytes.isEmpty, "Every range the journal publishes must have its file")
    }
  }

  func testCompactingTwiceChangesNothing() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    try await record(sessionID: sessionID, root: root, starts: [0, 100])
    let first = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)

    let second = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)

    XCTAssertTrue(second.alreadyCompact)
    XCTAssertEqual(second.originalByteCount, first.compactedByteCount)
    XCTAssertTrue(second.runs.isEmpty)
  }

  func testASourceItCannotVerifyIsLeftAlone() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    try await record(sessionID: sessionID, root: root, starts: [0, 100])
    let journalRoot = SourceAudioCompaction.journalRootURL(
      sessionID: sessionID, assetRoot: root)
    let chunks = journalRoot.appendingPathComponent("chunks")
    let names = try FileManager.default.contentsOfDirectory(atPath: chunks.path).sorted()
    try Data(repeating: 7, count: 64).write(
      to: chunks.appendingPathComponent(names[0]))

    do {
      _ = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)
      XCTFail("A chunk that fails its digest must stop compaction")
    } catch let error as SourceAudioCompactionError {
      guard case .sourceChunkCorrupt = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: chunks.path).sorted(), names,
      "Nothing may be deleted when the source cannot be trusted")
  }

  func testTheJournalThatRewroteItStopsServingTheOldRecording() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, root: root, starts: [0, 100, 200], journal: journal)
    // Reading first is the point: it is what leaves the old manifest cached.
    let before = try await journal.committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(before.count, 3)

    _ = try await journal.compactSealedRecording(sessionID: sessionID)

    let after = try await journal.committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(after.count, 1, "The same journal must serve what it just wrote")
    for range in after {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent(range.assetReference).path),
        "A range whose file is gone is a recording the user cannot play")
    }
    let descriptors = try await journal.sourceTrackDescriptors(sessionID: sessionID)
    XCTAssertEqual(descriptors.first?.encoding, .int16LittleEndian)
  }

  // MARK: - Fixtures

  /// A sealed session whose chunks start at the given millisecond offsets.
  private func record(
    sessionID: SessionID, root: URL, starts: [UInt64],
    journal openJournal: ProductionAudioJournal? = nil
  ) async throws {
    let journal = try openJournal ?? ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID,
        deviceUID: "compaction-fixture",
        sampleRateHertz: sampleRate,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true
      )
    )
    for (index, start) in starts.enumerated() {
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          sequence: UInt64(index),
          monotonicStartNanoseconds: start * 1_000_000,
          frameCount: UInt64(framesPerChunk),
          sampleRateHertz: sampleRate,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: tone(frames: framesPerChunk, phase: index)
        )
      )
    }
    _ = try await journal.seal(sessionID: sessionID)
  }

  private func tone(frames: Int, phase: Int) -> Data {
    var samples: [Float] = []
    samples.reserveCapacity(frames)
    for frame in 0..<frames {
      let angle = 2 * Float.pi * 440 * Float(frame + phase * frames) / Float(sampleRate)
      samples.append(0.5 * sin(angle))
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  private func duration(of ranges: [AudioRangeInput]) -> UInt64 {
    ranges.reduce(UInt64(0)) {
      $0 + ($1.monotonicEndNanoseconds - $1.monotonicStartNanoseconds)
    }
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
