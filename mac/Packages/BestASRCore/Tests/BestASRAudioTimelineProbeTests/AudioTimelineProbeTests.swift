import BestASRAudioTimelineProbe
import Foundation
import XCTest

final class AudioTimelineProbeTests: XCTestCase {
  func testHostTimeConversionUsesIntegerTimebase() throws {
    let converter = try HostTimeConverter(numerator: 125, denominator: 3)
    XCTAssertEqual(try converter.monotonicNanoseconds(for: 9), 375)
    XCTAssertThrowsError(
      try HostTimeConverter(numerator: 0, denominator: 1)
    )
  }

  func testPulseQuantizationRemainsWithinOneFrame() {
    let expected: UInt64 = 1_237_123_456
    let result = AudioProbeSignal.pulseChunk(
      frameCount: 48_000,
      sampleRateHertz: 48_000,
      chunkStartNanoseconds: 1_000_000_000,
      pulseNanoseconds: expected
    )
    let observed = try! XCTUnwrap(result.observedPulseNanoseconds)
    XCTAssertLessThanOrEqual(
      abs(Int64(observed) - Int64(expected)),
      Int64((1_000_000_000.0 / 48_000.0).rounded(.up))
    )
    XCTAssertEqual(AudioProbeSignal.digest(samples: result.samples).count, 64)
  }

  func testDriftEstimatorRecoversKnownRate() throws {
    let result = try ClockDriftEstimator.observation(
      nominalSampleRateHertz: 48_000,
      startFrame: 0,
      endFrame: 47_997_600,
      startMonotonicNanoseconds: 0,
      endMonotonicNanoseconds: 1_000_000_000_000,
      expectedPartsPerMillion: -50
    )
    XCTAssertEqual(result.measuredPartsPerMillion, -50, accuracy: 0.001)
  }

  func testValidatorRejectsSilentRateChange() throws {
    let track = ProbeTrack(
      trackID: "mic",
      sourceRole: .microphoneLocal,
      clockDomain: "clock-a"
    )
    let chunks = [
      chunk(trackID: "mic", sequence: 0, hostTime: 1, rate: 48_000),
      chunk(trackID: "mic", sequence: 1, hostTime: 2, rate: 44_100),
    ]
    XCTAssertThrowsError(
      try AudioTimelineValidator.validate(
        tracks: [track],
        chunks: chunks,
        boundaries: []
      )
    ) { error in
      XCTAssertEqual(
        error as? AudioTimelineProbeError,
        .sampleRateChangedWithoutBoundary(trackID: "mic", sequence: 1)
      )
    }
  }

  func testValidatorRejectsSequenceGapAndBadDigest() throws {
    let track = ProbeTrack(
      trackID: "system",
      sourceRole: .systemRemote,
      clockDomain: "clock-b"
    )
    XCTAssertThrowsError(
      try AudioTimelineValidator.validate(
        tracks: [track],
        chunks: [chunk(trackID: "system", sequence: 1, hostTime: 1)],
        boundaries: []
      )
    )
    var invalid = chunk(trackID: "system", sequence: 0, hostTime: 1)
    invalid = ProbeAudioChunk(
      trackID: invalid.trackID,
      segment: invalid.segment,
      sequence: invalid.sequence,
      hostTime: invalid.hostTime,
      monotonicStartNanoseconds: invalid.monotonicStartNanoseconds,
      sampleRateHertz: invalid.sampleRateHertz,
      frameCount: invalid.frameCount,
      contentDigest: "invalid"
    )
    XCTAssertThrowsError(
      try AudioTimelineValidator.validate(
        tracks: [track],
        chunks: [invalid],
        boundaries: []
      )
    )
  }

  func testRunnerWritesReviewableEvidence() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = root.appendingPathComponent("summary.json")
    let matrix = root.appendingPathComponent("matrix.json")
    XCTAssertEqual(
      try AudioTimelineProbeRunner.run(
        configuration: AudioTimelineProbeConfiguration(
          summaryURL: summary,
          matrixURL: matrix
        )
      ),
      "conditional"
    )
    let decoded = try JSONDecoder.withISO8601.decode(
      AudioTimelineMatrixEvidence.self,
      from: Data(contentsOf: matrix)
    )
    XCTAssertEqual(decoded.tracks.count, 2)
    XCTAssertEqual(decoded.chunks.count, 8)
    XCTAssertEqual(decoded.pulseObservations.count, 6)
    XCTAssertTrue(decoded.scenarios.allSatisfy { $0.status == "pass" })
    XCTAssertTrue(FileManager.default.fileExists(atPath: summary.path))
  }

  private func chunk(
    trackID: String,
    sequence: UInt64,
    hostTime: UInt64,
    rate: UInt32 = 48_000
  ) -> ProbeAudioChunk {
    ProbeAudioChunk(
      trackID: trackID,
      segment: 0,
      sequence: sequence,
      hostTime: hostTime,
      monotonicStartNanoseconds: hostTime,
      sampleRateHertz: rate,
      frameCount: rate,
      contentDigest: String(repeating: "a", count: 64)
    )
  }
}

extension JSONDecoder {
  fileprivate static var withISO8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
