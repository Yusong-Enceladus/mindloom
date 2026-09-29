import BestASRDictation
import Foundation
import XCTest

final class DictationSilenceDetectorTests: XCTestCase {
  func testDefaultConfigurationHasStableProvenanceIdentifier() throws {
    XCTAssertEqual(
      try DictationSilenceConfiguration().provenanceIdentifier,
      "rms=0.012;minimumSpeechNs=250000000;sentenceSilenceNs=650000000"
    )
  }

  func testSpeechThenConfiguredSilenceEmitsOneSentenceBoundary() throws {
    var detector = DictationSilenceDetector(
      configuration: try DictationSilenceConfiguration(
        rmsThreshold: 0.01,
        minimumSpeechNanoseconds: 250_000_000,
        sentenceSilenceNanoseconds: 500_000_000
      )
    )
    XCTAssertFalse(try detector.consume(chunk(sequence: 0, value: 0.1)))
    XCTAssertFalse(try detector.consume(chunk(sequence: 1, value: 0)))
    XCTAssertTrue(try detector.consume(chunk(sequence: 2, value: 0)))
    XCTAssertFalse(try detector.consume(chunk(sequence: 3, value: 0)))
  }

  func testNoiseBelowThresholdDoesNotCreateBoundaryWithoutSpeech() throws {
    var detector = DictationSilenceDetector(
      configuration: try DictationSilenceConfiguration(
        rmsThreshold: 0.02,
        minimumSpeechNanoseconds: 250_000_000,
        sentenceSilenceNanoseconds: 500_000_000
      )
    )
    for sequence in 0..<8 {
      XCTAssertFalse(
        try detector.consume(
          chunk(sequence: UInt64(sequence), value: 0.005)
        )
      )
    }
  }

  func testPauseResetRequiresNewSpeechBeforeAnotherBoundary() throws {
    var detector = DictationSilenceDetector(
      configuration: try DictationSilenceConfiguration(
        minimumSpeechNanoseconds: 250_000_000,
        sentenceSilenceNanoseconds: 500_000_000
      )
    )
    _ = try detector.consume(chunk(sequence: 0, value: 0.1))
    _ = try detector.consume(chunk(sequence: 1, value: 0))
    XCTAssertTrue(try detector.consume(chunk(sequence: 2, value: 0)))
    detector.reset()
    XCTAssertFalse(try detector.consume(chunk(sequence: 3, value: 0)))
  }

  func testMonotonicDiscontinuityIsNotInventedAsSilence() throws {
    var detector = DictationSilenceDetector(
      configuration: try DictationSilenceConfiguration(
        rmsThreshold: 0.01,
        minimumSpeechNanoseconds: 250_000_000,
        sentenceSilenceNanoseconds: 500_000_000
      )
    )
    XCTAssertFalse(try detector.consume(chunk(sequence: 0, value: 0.1)))
    XCTAssertFalse(
      try detector.consume(
        chunk(sequence: 1, value: 0, start: 10_000_000_000)
      ),
      "a timeline gap must not be counted as synthesized silent PCM"
    )
    XCTAssertTrue(
      try detector.consume(
        chunk(sequence: 2, value: 0, start: 10_250_000_000)
      )
    )
  }

  private func chunk(
    sequence: UInt64,
    value: Float,
    start: UInt64? = nil
  ) -> CapturedPCMChunk {
    let samples = [Float](repeating: value, count: 4_000)
    return CapturedPCMChunk(
      sequence: sequence,
      monotonicStartNanoseconds: start ?? sequence * 250_000_000,
      frameCount: UInt64(samples.count),
      sampleRateHertz: 16_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true,
      bytes: samples.withUnsafeBytes { Data($0) }
    )
  }
}
