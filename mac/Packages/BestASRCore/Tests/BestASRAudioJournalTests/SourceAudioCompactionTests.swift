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
    // What the journal holds is reported again (nothing replaced), so an
    // index left naming the old files by a crash after the swap is repaired
    // by applying it (v12 storage).
    XCTAssertEqual(second.runs.map(\.assetReference), first.runs.map(\.assetReference))
    XCTAssertEqual(second.runs.map(\.contentDigest), first.runs.map(\.contentDigest))
    XCTAssertTrue(second.runs.allSatisfy { $0.replacedAssetReferences.isEmpty })
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

  /// Regression (review 10-6 S5): a recording read, played or held while
  /// its new copy is made is not swapped: the copy is discarded and the
  /// original stays and plays; the next idle period tries again.
  func testARecordingOpenedWhileItsCopyIsMadeIsLeftAsItWas() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, root: root, starts: [0, 100, 200], journal: journal)
    let staging = JournalRewrite.stagingURL(
      for: SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root))

    do {
      _ = try await journal.compactSealedRecording(
        sessionID: sessionID,
        stillFree: {
          // The user presses play while the copy is being made.
          _ = try? await journal.recover(sessionID: sessionID)
          return true
        })
      XCTFail("A recording read during the rewrite is not swapped")
    } catch ProductionAudioJournalError.recordingInUse {}
    do {
      _ = try await journal.compactSealedRecording(sessionID: sessionID, stillFree: { false })
      XCTFail("The App said the recording is in use")
    } catch ProductionAudioJournalError.recordingInUse {}
    var descriptors = try await journal.sourceTrackDescriptors(sessionID: sessionID)
    XCTAssertEqual(descriptors.first?.sampleRateHertz, sampleRate, "The original stays")
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "The copy is discarded")
    let ranges = try await journal.recover(sessionID: sessionID).ranges
    XCTAssertEqual(ranges.count, 3, "And still reads back")

    let outcome = try await journal.compactSealedRecording(sessionID: sessionID)
    XCTAssertFalse(outcome.alreadyCompact)
    descriptors = try await journal.sourceTrackDescriptors(sessionID: sessionID)
    XCTAssertEqual(descriptors.first?.sampleRateHertz, 16_000, "Taken when free")
  }

  /// Regression (review 10-6 S6): archived chunks cannot be opened by a
  /// build before v12 storage, so archival waits until every installed copy
  /// of the App declares it reads them.
  func testArchivalWaitsForEveryInstalledCopyToReadIt() {
    let reader: [String: Any] = [RetainedAudioReaderGate.readerKey: 1]
    XCTAssertTrue(RetainedAudioReaderGate.allowsArchival(installed: [reader, reader]))
    XCTAssertFalse(
      RetainedAudioReaderGate.allowsArchival(installed: [reader, ["CFBundleVersion": "41"]]),
      "An older copy is installed")
    XCTAssertFalse(RetainedAudioReaderGate.allowsArchival(installed: []))
  }

  /// Regression (review 10-6 S4): the 16 kHz copy replaces the original,
  /// so what lies above 8 kHz must be filtered out, not folded into the band
  /// that is kept (linear interpolation turned a 12 kHz tone at 48 kHz into a
  /// 4 kHz tone at full strength). Speech below 7 kHz is kept as recorded,
  /// at the same instants.
  func testWhatLiesAboveEightKilohertzIsNotFoldedIntoTheStoredRecording() async throws {
    for (rate, frequency) in [(48_000, 12_000.0), (48_000, 9_000.0), (44_100, 10_000.0)] {
      let stored = try await compactedTone(rate: UInt32(rate), frequency: frequency)
      let interior = Array(stored.dropFirst(400).dropLast(400))
      let level = 20 * log10(rms(interior) / (0.5 / 2.0.squareRoot()))
      XCTAssertLessThan(level, -60, "\(frequency) Hz at \(rate) Hz is \(level) dB")
    }
    for rate in [48_000, 44_100] {
      let stored = try await compactedTone(rate: UInt32(rate), frequency: 1_000)
      XCTAssertEqual(
        stored.count, (rate * 3 / 10 - 1) * 16_000 / rate + 1, "Every instant recorded, no more")
      var worst: Float = 0
      for n in 400..<(stored.count - 400) {
        let expected = 0.5 * sin(2 * Float.pi * 1_000 * Float(n) / 16_000)
        worst = max(worst, abs(stored[n] - expected))
      }
      XCTAssertLessThan(worst, 0.002, "The band below 7 kHz is kept, not delayed (\(rate) Hz)")
    }
  }

  /// Three 100 ms chunks of one tone, compacted; the stored 16 kHz samples.
  private func compactedTone(rate: UInt32, frequency: Double) async throws -> [Float] {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "compaction-fixture", sampleRateHertz: rate,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true))
    let frames = Int(rate) / 10
    for index in 0..<3 {
      let samples = (0..<frames).map { frame -> Float in
        let t = Double(frame + index * frames) / Double(rate)
        return Float(0.5 * sin(2 * Double.pi * frequency * t))
      }
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          sequence: UInt64(index),
          monotonicStartNanoseconds: 1_000_000 + UInt64(index) * 100_000_000,
          frameCount: UInt64(frames), sampleRateHertz: rate, channelCount: 1,
          encoding: .float32LittleEndian, interleaved: true,
          bytes: samples.withUnsafeBytes { Data($0) }))
    }
    _ = try await journal.seal(sessionID: sessionID)
    let outcome = try await journal.compactSealedRecording(sessionID: sessionID)
    XCTAssertEqual(outcome.runs.count, 1)
    let journalRoot = SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root)
    let manifest = try JSONDecoder().decode(
      AudioJournalManifest.self,
      from: Data(contentsOf: journalRoot.appendingPathComponent("manifest.json")))
    var stored: [Float] = []
    for entry in manifest.committedChunks {
      let data = try Data(contentsOf: journalRoot.appendingPathComponent(entry.relativePath))
      data.withUnsafeBytes { raw in
        for offset in stride(from: 0, to: data.count - 1, by: 2) {
          let value = Int16(
            bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian)
          stored.append(Float(value) / 32_767)
        }
      }
    }
    return stored
  }

  private func rms(_ samples: [Float]) -> Double {
    (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
      .squareRoot()
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

/// A meeting recorded without a pause is cut into files of about five
/// minutes at its own chunk boundaries (收1-25): playback, export and the
/// Opus step then hold one piece in memory, not the whole meeting.
final class SourceAudioCompactionPieceTests: XCTestCase {
  func testALongRunIsCutAtChunkBoundariesIntoPiecesOfAtMostFiveMinutes() {
    let chunkFrames: UInt32 = 8_000  // 500 ms at 16 kHz
    let chunkNanoseconds: UInt64 = 500_000_000
    let run = (0..<1_400).map { index in  // 700 s
      AudioJournalChunkEntry(
        trackID: "track", sequence: UInt64(index), relativePath: "chunks/track-\(index).pcm",
        monotonicStartNanoseconds: 1_000 + UInt64(index) * chunkNanoseconds,
        sampleRateHertz: 16_000, frameCount: chunkFrames, byteCount: UInt64(chunkFrames) * 2,
        contentDigest: String(repeating: "a", count: 64))
    }
    let pieces = SourceAudioCompaction.pieces(of: run)
    XCTAssertEqual(pieces.map(\.count), [600, 600, 200])
    XCTAssertEqual(pieces.flatMap { $0 }, run, "Every chunk once, in order")
    for piece in pieces {
      let span = SourceAudioCompaction.end(of: piece.last!) - piece.first!.monotonicStartNanoseconds
      XCTAssertLessThanOrEqual(span, SourceAudioCompaction.maximumPieceNanoseconds)
    }
    // A short dictation stays one file.
    XCTAssertEqual(SourceAudioCompaction.pieces(of: Array(run.prefix(40))).count, 1)
    XCTAssertEqual(SourceAudioCompaction.pieces(of: []).count, 0)
  }
}
