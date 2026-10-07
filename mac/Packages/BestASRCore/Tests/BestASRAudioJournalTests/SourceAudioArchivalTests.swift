import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import XCTest

/// The 30-day step (lossless, or Opus) replaces the only copy of a recording
/// the App keeps,
/// so these check what would lose something: the archived recording reads
/// back through every reader with its timing, a session that cannot be
/// verified is left exactly as it was, nothing runs before the 16 kHz step,
/// and a crash at any point leaves one whole recording, never two.
final class SourceAudioArchivalTests: XCTestCase {
  private let sampleRate: UInt32 = 48_000
  private let framesPerChunk = 4_800  // 100 ms

  /// The form the App uses now: Apple Lossless, the same samples exactly.
  func testACompactedRecordingIsKeptLosslesslyWithTheSameSamples() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 100, 200, 1_000])
    _ = try await journal.compactSealedRecording(sessionID: sessionID)
    let track = try await journal.sourceTrackDescriptors(sessionID: sessionID)[0]
    let master = root.appendingPathComponent("master.wav")
    _ = try await journal.exportSourceTrackAsWave(
      sessionID: sessionID, trackID: track.id, to: master)

    let outcome = try await journal.archiveSealedRecording(sessionID: sessionID)

    XCTAssertFalse(outcome.alreadyArchived)
    XCTAssertTrue(outcome.runs.allSatisfy { $0.assetReference.hasSuffix(".lossless.caf") })
    XCTAssertLessThan(outcome.archivedByteCount, outcome.originalByteCount)
    XCTAssertEqual(outcome.minimumEnvelopeCorrelation, 1, "Every file checked sample for sample")
    let kept = root.appendingPathComponent("kept.wav")
    _ = try await ProductionAudioJournal(assetRootURL: root).exportSourceTrackAsWave(
      sessionID: sessionID, trackID: track.id, to: kept)
    XCTAssertEqual(
      try Data(contentsOf: kept), try Data(contentsOf: master),
      "Export gives back the 16-bit master byte for byte")
    // Opus later (when the user agrees) converts it from its exact decoding.
    let opus = try await journal.archiveSealedRecording(sessionID: sessionID, format: .opus)
    XCTAssertFalse(opus.alreadyArchived)
    XCTAssertTrue(
      opus.runs.allSatisfy {
        RetainedAudioContainer(reference: $0.assetReference) == .opusCAF
      })
    let again = try await journal.archiveSealedRecording(sessionID: sessionID, format: .opus)
    XCTAssertTrue(again.alreadyArchived, "Opus is never rewritten")
    let lossless = try await journal.archiveSealedRecording(sessionID: sessionID)
    XCTAssertTrue(lossless.alreadyArchived, "Nothing goes back from Opus")
  }

  func testACompactedRecordingBecomesOpusWithTheSameTiming() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 100, 200, 1_000])
    _ = try await journal.compactSealedRecording(sessionID: sessionID)
    let before = try await journal.committedAudioSnapshot(sessionID: sessionID)

    let outcome = try await journal.archiveSealedRecording(sessionID: sessionID, format: .opus)

    XCTAssertFalse(outcome.alreadyArchived)
    XCTAssertEqual(outcome.runs.count, before.count)
    XCTAssertTrue(outcome.runs.allSatisfy { $0.assetReference.hasSuffix(".caf") })
    XCTAssertLessThan(
      outcome.archivedByteCount, outcome.originalByteCount,
      "Opus at 24 kbps is smaller than 16-bit PCM")
    let after = try await ProductionAudioJournal(assetRootURL: root)
      .committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(after.map(\.monotonicStartNanoseconds), before.map(\.monotonicStartNanoseconds))
    XCTAssertEqual(after.map(\.monotonicEndNanoseconds), before.map(\.monotonicEndNanoseconds))
    let chunks = try FileManager.default.contentsOfDirectory(
      atPath: SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root)
        .appendingPathComponent("chunks").path)
    XCTAssertTrue(
      chunks.allSatisfy { $0.hasSuffix(".caf") }, "The 16-bit files it replaced are gone")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: JournalRewrite.stagingURL(
          for: SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root)
        ).path))
    for range in after {
      let frames = UInt64(
        (Double(range.monotonicEndNanoseconds - range.monotonicStartNanoseconds) * 16_000
          / 1_000_000_000).rounded())
      let pcm = try RetainedAudioCodec.pcmBytes(
        at: root.appendingPathComponent(range.assetReference),
        expectedDigest: range.contentDigest, frameCount: frames, encoding: .int16LittleEndian)
      XCTAssertEqual(pcm.count, Int(frames) * 2, "Every reader gets the recorded length")
    }
  }

  func testRecognitionAndExportReadTheArchivedRecording() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 100, 200])
    _ = try await journal.compactSealedRecording(sessionID: sessionID)
    _ = try await journal.archiveSealedRecording(sessionID: sessionID, format: .opus)
    let ranges = try await journal.committedAudioSnapshot(sessionID: sessionID)

    let prepared = try await journal.prepareInferenceAudio(
      sessionID: sessionID, sourceAudio: ranges)
    XCTAssertFalse(prepared.isEmpty, "Re-recognition decodes the Opus copy")
    await journal.discardInferenceAudio(sessionID: sessionID, preparedAudio: prepared)

    let track = try await journal.sourceTrackDescriptors(sessionID: sessionID)[0]
    let destination = root.appendingPathComponent("export.wav")
    let export = try await journal.exportSourceTrackAsWave(
      sessionID: sessionID, trackID: track.id, to: destination)
    XCTAssertEqual(export.sampleRateHertz, 16_000)
    XCTAssertEqual(export.frameCount, 3 * 1_600, "Three 100 ms chunks at 16 kHz")
  }

  func testArchivingTwiceChangesNothingAndReportsWhatIsThere() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 100])
    _ = try await journal.compactSealedRecording(sessionID: sessionID)
    let first = try await journal.archiveSealedRecording(sessionID: sessionID)

    let second = try await journal.archiveSealedRecording(sessionID: sessionID)

    XCTAssertTrue(second.alreadyArchived)
    // The runs it holds, so an index left behind by a crash is repaired.
    XCTAssertEqual(second.runs.map(\.assetReference), first.runs.map(\.assetReference))
    XCTAssertEqual(second.runs.map(\.contentDigest), first.runs.map(\.contentDigest))
  }

  func testNothingIsArchivedBeforeThe16kHzStep() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    try await record(
      sessionID: sessionID, journal: try ProductionAudioJournal(assetRootURL: root), starts: [0])
    do {
      _ = try await SourceAudioArchival.archive(sessionID: sessionID, assetRoot: root)
      XCTFail("Opus is made from the 16-bit master only")
    } catch let error as SourceAudioArchivalError {
      XCTAssertEqual(error, .sessionNotCompact)
    }
  }

  func testAChunkThatFailsItsDigestStopsArchivalAndChangesNothing() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 1_000])
    _ = try await journal.compactSealedRecording(sessionID: sessionID)
    let journalRoot = SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root)
    let chunks = journalRoot.appendingPathComponent("chunks")
    let names = try FileManager.default.contentsOfDirectory(atPath: chunks.path).sorted()
    try Data(repeating: 9, count: 64).write(to: chunks.appendingPathComponent(names[0]))

    do {
      _ = try await SourceAudioArchival.archive(sessionID: sessionID, assetRoot: root)
      XCTFail("A chunk that fails its digest must stop archival")
    } catch let error as SourceAudioArchivalError {
      guard case .sourceChunkCorrupt = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chunks.path).sorted(), names)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: JournalRewrite.stagingURL(for: journalRoot).path),
      "Nothing half-built is left beside the journal")
  }

  /// Regression (rewrite crash safety): a rewrite interrupted at any point
  /// leaves `journal.rewrite` beside the live journal, holding either an
  /// unfinished copy or the replaced recording. The live journal must still
  /// open with exactly one recording, the next rewrite must succeed, and a
  /// fresh journal must clear the leftover.
  func testAnInterruptedRewriteLeavesOneWholeRecording() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID()
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await record(sessionID: sessionID, journal: journal, starts: [0, 100, 200])
    let journalRoot = SourceAudioCompaction.journalRootURL(sessionID: sessionID, assetRoot: root)
    // What a crash in the middle of building the replacement leaves.
    let leftover = JournalRewrite.stagingURL(for: journalRoot)
    try FileManager.default.createDirectory(
      at: leftover.appendingPathComponent("chunks"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 128).write(
      to: leftover.appendingPathComponent("chunks/partial.pcm"))
    try Data("{}".utf8).write(to: leftover.appendingPathComponent("manifest.json"))

    let before = try await ProductionAudioJournal(assetRootURL: root)
      .committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(before.count, 3)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: leftover.path),
      "Opening the journal at launch clears the leftover")

    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    let outcome = try await SourceAudioCompaction.compact(sessionID: sessionID, assetRoot: root)
    XCTAssertEqual(outcome.runs.count, 1)
    let after = try await ProductionAudioJournal(assetRootURL: root)
      .committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(after.count, 1, "The rewritten recording, once")
  }

  // MARK: - Fixtures

  private func record(
    sessionID: SessionID, journal: ProductionAudioJournal, starts: [UInt64]
  ) async throws {
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "archival-fixture", sampleRateHertz: sampleRate,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true))
    for (index, start) in starts.enumerated() {
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          sequence: UInt64(index), monotonicStartNanoseconds: start * 1_000_000,
          frameCount: UInt64(framesPerChunk), sampleRateHertz: sampleRate, channelCount: 1,
          encoding: .float32LittleEndian, interleaved: true,
          bytes: speechLike(frames: framesPerChunk, phase: index)))
    }
    _ = try await journal.seal(sessionID: sessionID)
  }

  /// A voiced sound whose loudness rises and falls, like a syllable.
  private func speechLike(frames: Int, phase: Int) -> Data {
    var samples: [Float] = []
    samples.reserveCapacity(frames)
    for frame in 0..<frames {
      let t = Float(frame + phase * frames) / Float(sampleRate)
      let envelope = 0.5 + 0.5 * sin(2 * Float.pi * 4 * t)
      let voice =
        sin(2 * Float.pi * 180 * t) + 0.5 * sin(2 * Float.pi * 360 * t)
        + 0.25 * sin(2 * Float.pi * 720 * t)
      samples.append(0.3 * envelope * voice)
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
