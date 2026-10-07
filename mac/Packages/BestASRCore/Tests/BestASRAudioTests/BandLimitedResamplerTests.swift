import XCTest

@testable import BestASRAudio

/// The resampler that writes the retained 16 kHz copy of a recording
/// (review 10-6 S4): it filters what lies above 8 kHz instead of folding it
/// into the band, and how the samples arrive does not change the result.
final class BandLimitedResamplerTests: XCTestCase {
  func testChunkBoundariesDoNotChangeTheResult() throws {
    let rate = 44_100
    let input = (0..<(rate / 2)).map {
      Float(sin(Double($0) * 0.031) * 0.4 + sin(Double($0) * 1.9) * 0.2)
    }
    var whole = try BandLimitedResampler(sourceRateHertz: rate)
    let once = whole.append(input) + whole.finish()
    var pieces = try BandLimitedResampler(sourceRateHertz: rate)
    var streamed: [Float] = []
    var start = 0
    for size in [1, 7, 4_410, 333, 9_999, 2] where start < input.count {
      let end = min(input.count, start + size)
      streamed += pieces.append(Array(input[start..<end]))
      start = end
    }
    streamed += pieces.append(Array(input[start...]))
    streamed += pieces.finish()

    XCTAssertEqual(streamed, once)
    XCTAssertEqual(
      once.count, BandLimitedResampler.outputCount(sourceFrames: input.count, sourceRateHertz: rate)
    )
  }

  func testSixteenKilohertzPassesThroughUnchanged() throws {
    var resampler = try BandLimitedResampler(sourceRateHertz: 16_000)
    let input: [Float] = [0.1, -0.2, 0.3, 0.9]
    XCTAssertEqual(resampler.append(input) + resampler.finish(), input)
  }

  func testAToneAboveEightKilohertzIsRemovedAndOneBelowSevenIsKept() throws {
    for rate in [48_000, 44_100, 96_000] {
      for (frequency, keep) in [
        (12_000.0, false), (8_500.0, false), (6_500.0, true), (300.0, true),
      ] {
        var resampler = try BandLimitedResampler(sourceRateHertz: rate)
        let input = (0..<rate).map {
          Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / Double(rate)))
        }
        let output = resampler.append(input) + resampler.finish()
        let interior = output.dropFirst(800).dropLast(800)
        let rms = (interior.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(interior.count))
          .squareRoot()
        let level = 20 * log10(max(rms, 1e-12) / (0.5 / 2.0.squareRoot()))
        if keep {
          XCTAssertEqual(level, 0, accuracy: 0.05, "\(frequency) Hz at \(rate) Hz")
        } else {
          XCTAssertLessThan(level, -75, "\(frequency) Hz at \(rate) Hz")
        }
      }
    }
  }
}
