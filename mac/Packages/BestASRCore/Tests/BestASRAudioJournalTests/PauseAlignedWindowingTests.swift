import BestASRAudioJournal
import XCTest

final class PauseAlignedWindowingTests: XCTestCase {
  private let limit = 30 * 16_000

  func testAudioThatStillFitsIsNeverCutEvenAtAPause() {
    var samples = tone(seconds: 26)
    silence(&samples, from: 22.0, to: 22.6)
    XCTAssertNil(samples.withUnsafeBufferPointer { PauseAlignedWindowing.cut($0, limit: limit) })
    let whole = PauseAlignedWindowing.windows(samples, limit: limit)
    XCTAssertEqual(whole, [0..<samples.count])
  }

  func testOverTheLimitEndsInsideTheLongestLatePause() {
    var samples = tone(seconds: 31)
    silence(&samples, from: 12.0, to: 13.5)  // before two thirds: ignored
    silence(&samples, from: 21.0, to: 21.4)
    silence(&samples, from: 25.0, to: 25.8)
    let cut = samples.withUnsafeBufferPointer { PauseAlignedWindowing.cut($0, limit: limit) }
    let seconds = Double(cut ?? 0) / 16_000
    XCTAssertGreaterThan(seconds, 25.0)
    XCTAssertLessThan(seconds, 25.8)
  }

  func testContinuousSpeechAtOrUnderTheLimitKeepsAccumulating() {
    let samples = tone(seconds: 30)
    XCTAssertNil(samples.withUnsafeBufferPointer { PauseAlignedWindowing.cut($0, limit: limit) })
  }

  func testOverTheLimitWithoutPauseCutsAtTheQuietestPointInside() {
    var samples = tone(seconds: 30.5)
    for index in Int(27.0 * 16_000)..<Int(27.05 * 16_000) { samples[index] *= 0.2 }
    let cut = samples.withUnsafeBufferPointer { PauseAlignedWindowing.cut($0, limit: limit) }
    XCTAssertNotNil(cut)
    XCTAssertLessThanOrEqual(cut ?? .max, limit)
    XCTAssertEqual(Double(cut ?? 0) / 16_000, 27.025, accuracy: 0.05)
  }

  func testWholeRecordingSplitsAtPausesAndNeverExceedsTheLimit() {
    var samples = tone(seconds: 75)
    silence(&samples, from: 24.0, to: 24.5)
    silence(&samples, from: 49.0, to: 49.4)
    let windows = PauseAlignedWindowing.windows(samples, limit: limit)
    XCTAssertEqual(windows.count, 3)
    XCTAssertTrue(windows.allSatisfy { $0.count <= limit })
    XCTAssertEqual(windows.first?.lowerBound, 0)
    XCTAssertEqual(windows.last?.upperBound, samples.count)
    for (previous, next) in zip(windows, windows.dropFirst()) {
      XCTAssertEqual(previous.upperBound, next.lowerBound, "No sample is skipped or repeated")
    }
    XCTAssertEqual(Double(windows[0].upperBound) / 16_000, 24.25, accuracy: 0.2)
  }

  private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.2)) * 0.2 }
  }

  private func silence(_ samples: inout [Float], from: Double, to: Double) {
    for index in Int(from * 16_000)..<Int(to * 16_000) { samples[index] = 0 }
  }
}
