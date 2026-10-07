import BestASRAudioJournal
import Foundation
import XCTest

/// The system Opus and Apple Lossless encoders and the one decode path every
/// reader uses.
final class RetainedAudioCodecTests: XCTestCase {
  func testOpusRoundTripKeepsTheLengthAndTheLoudnessOverTime() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let master = syllables(seconds: 3)
    let url = root.appendingPathComponent("take.caf")

    try RetainedAudioCodec.encodeOpus(samples: master, to: url)
    let correlation = try RetainedAudioCodec.verify(encoded: url, master: master)

    let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    XCTAssertLessThan(size, master.count * 2 / 6, "24 kbps is well under a sixth of 256 kbps")
    XCTAssertGreaterThanOrEqual(correlation, RetainedAudioCodec.minimumEnvelopeCorrelation)
    let decoded = try RetainedAudioCodec.decodeMono16k(url)
    XCTAssertLessThanOrEqual(
      abs(decoded.count - master.count), Int(RetainedAudioCodec.lengthToleranceFrames))
  }

  func testEveryReaderGetsExactlyTheRecordedFrames() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let master = syllables(seconds: 1.37)
    let url = root.appendingPathComponent("take.caf")
    try RetainedAudioCodec.encodeOpus(samples: master, to: url)
    let digest = try RetainedAudioCodec.fileDigest(url)

    let pcm = try RetainedAudioCodec.pcmBytes(
      at: url, expectedDigest: digest, frameCount: UInt64(master.count),
      encoding: .int16LittleEndian)

    XCTAssertEqual(pcm.count, master.count * 2)
  }

  func testAFileThatDoesNotMatchItsDigestIsRefused() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("take.caf")
    try RetainedAudioCodec.encodeOpus(samples: syllables(seconds: 1), to: url)
    XCTAssertThrowsError(
      try RetainedAudioCodec.pcmBytes(
        at: url, expectedDigest: String(repeating: "0", count: 64), frameCount: nil,
        encoding: .int16LittleEndian)
    ) { error in
      XCTAssertEqual(error as? RetainedAudioCodecError, .digestMismatch)
    }
  }

  func testACopyMuchShorterThanItsMasterFailsVerification() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let master = syllables(seconds: 2)
    let url = root.appendingPathComponent("short.caf")
    try RetainedAudioCodec.encodeOpus(samples: Array(master.prefix(master.count / 2)), to: url)
    XCTAssertThrowsError(try RetainedAudioCodec.verify(encoded: url, master: master)) { error in
      guard case .lengthMismatch = error as? RetainedAudioCodecError else {
        return XCTFail("\(error)")
      }
    }
  }

  func testAGarbledCopyFailsVerification() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let master = syllables(seconds: 2)
    // The same length, loudness running the other way.
    let url = root.appendingPathComponent("reversed.caf")
    try RetainedAudioCodec.encodeOpus(samples: master.reversed(), to: url)
    XCTAssertThrowsError(try RetainedAudioCodec.verify(encoded: url, master: master))
  }

  /// The lossless form gives back the 16-bit master sample for sample, and
  /// every reader gets those exact bytes.
  func testLosslessRoundTripIsBitExact() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    // 16-bit values, as the master is: including full scale both ways.
    let bytes = RetainedAudioCodec.int16LittleEndian(syllables(seconds: 2.3) + [1, -1, 0.5, -0.5])
    let master = RetainedAudioCodec.samples(int16LittleEndian: bytes)
    let url = root.appendingPathComponent("take.lossless.caf")

    try RetainedAudioCodec.encode(samples: master, to: url, format: .lossless)
    XCTAssertEqual(
      try RetainedAudioCodec.verify(encoded: url, master: master, format: .lossless), 1)
    let pcm = try RetainedAudioCodec.pcmBytes(
      at: url, expectedDigest: try RetainedAudioCodec.fileDigest(url),
      frameCount: UInt64(master.count), encoding: .int16LittleEndian)
    XCTAssertEqual(pcm, bytes, "The same bytes the 16-bit master held")
    let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    XCTAssertLessThan(size, bytes.count, "Smaller than the 16-bit master")
    // Changed by one step in one sample: no longer the same recording.
    var changed = master
    changed[100] += 1 / 32_768
    XCTAssertThrowsError(
      try RetainedAudioCodec.verify(encoded: url, master: changed, format: .lossless))
  }

  func testSixteenBitSamplesSurviveTheConversionBothWays() {
    let values: [Int16] = [.min, -16_385, -1, 0, 1, 16_384, .max]
    var data = Data()
    for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    XCTAssertEqual(
      RetainedAudioCodec.int16LittleEndian(RetainedAudioCodec.samples(int16LittleEndian: data)),
      data)
  }

  func testTheContainerIsReadFromTheName() {
    XCTAssertEqual(RetainedAudioContainer(reference: "chunks/a-1.pcm"), .pcm)
    XCTAssertEqual(RetainedAudioContainer(reference: "chunks/a-2.caf"), .opusCAF)
    XCTAssertEqual(RetainedAudioContainer(reference: "chunks/a-3.lossless.caf"), .losslessCAF)
    XCTAssertTrue(RetainedAudioContainer.losslessCAF.isCompressed)
    XCTAssertEqual(RetainedAudioContainer(reference: "source/original.ogg"), .compressedOriginal)
    XCTAssertFalse(RetainedAudioContainer.pcm.isCompressed)
  }

  func testATypelessOriginalPlaysAsOneSixteenKilohertzTrack() throws {
    let session = UUID()
    let asset = UUID()
    let source = try XCTUnwrap(
      RetainedOriginalPlayback.source(
        sessionID: session, assetID: asset,
        assetReference: "sessions/x/source/original.ogg",
        digest: String(repeating: "a", count: 64), mediaType: "audio/ogg",
        durationNanoseconds: 2_500_000_000))
    XCTAssertEqual(source.descriptor.sampleRateHertz, 16_000)
    XCTAssertEqual(source.ranges.count, 1)
    XCTAssertEqual(source.ranges[0].monotonicEndNanoseconds, 2_500_000_000)
    XCTAssertNil(
      RetainedOriginalPlayback.source(
        sessionID: session, assetID: asset, assetReference: "sessions/x/source/original.pdf",
        digest: String(repeating: "a", count: 64), mediaType: "application/pdf",
        durationNanoseconds: 1), "Only audio plays")
  }

  // MARK: - Fixtures

  /// Syllable-like bursts: a voiced tone whose loudness rises and falls four
  /// times a second, with short pauses.
  private func syllables(seconds: Double) -> [Float] {
    let count = Int(seconds * 16_000)
    return (0..<count).map { index in
      let t = Float(index) / 16_000
      let envelope = max(0, sin(2 * Float.pi * 4 * t))
      let voice =
        sin(2 * Float.pi * 150 * t) + 0.6 * sin(2 * Float.pi * 450 * t)
        + 0.3 * sin(2 * Float.pi * 1_100 * t)
      return 0.25 * envelope * voice
    }
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
