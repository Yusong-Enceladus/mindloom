import MLX
@testable import BestASRQwenRuntime
import XCTest

final class QwenWhisperFeaturesTests: XCTestCase {
  /// Values from transformers' WhisperFeatureExtractor loaded from the
  /// Qwen3-ASR-1.7B preprocessor config, for the same synthetic 1.5 s signal.
  func testFeaturesMatchTheTrainingFeatureExtractor() {
    let samples: [Float] = (0..<24_000).map { index in
      let n = Double(index)
      let value = 0.3 * sin(2 * .pi * 440 * n / 16_000)
        + 0.2 * sin(2 * .pi * (200 + 1_500 * n / 24_000) * n / 16_000)
        + 0.05 * sin(2 * .pi * 3_100 * n / 16_000)
      return Float(value)
    }
    Device.withDefaultDevice(.cpu) {
      let (features, mask, tokens) = QwenWhisperFeatures.extract(samples, melBins: 128)
      XCTAssertEqual(features.shape, [1, 128, 150])
      XCTAssertEqual(mask.shape, [1, 150])
      XCTAssertEqual(tokens, 20)
      XCTAssertEqual(features.mean().item(Float.self), -0.33616, accuracy: 1e-3)
      let reference: [(Int, Int, Float)] = [
        (0, 0, 1.00229), (10, 5, 0.92084), (40, 75, -0.56229),
        (80, 120, 0.91430), (127, 149, -0.44172), (64, 100, -0.56229),
      ]
      for (mel, frame, expected) in reference {
        XCTAssertEqual(
          features[0, mel, frame].item(Float.self), expected, accuracy: 2e-3, "mel \(mel) frame \(frame)")
      }
    }
  }

  func testClipShorterThanOneWindowIsPaddedInsteadOfTrapping() {
    Device.withDefaultDevice(.cpu) {
      let (features, _, tokens) = QwenWhisperFeatures.extract(
        [Float](repeating: 0.01, count: 100), melBins: 128)
      XCTAssertEqual(features.shape, [1, 128, 2])
      XCTAssertEqual(tokens, 1)
    }
  }

  func testAudioTokenCountUsesFloorDivisionLikeTheModel() {
    XCTAssertEqual(QwenWhisperFeatures.audioTokens(frames: 150), 20)
    XCTAssertEqual(QwenWhisperFeatures.audioTokens(frames: 100), 13)
    XCTAssertEqual(QwenWhisperFeatures.audioTokens(frames: 101), 14)
    XCTAssertEqual(QwenWhisperFeatures.audioTokens(frames: 3_000), 390)
  }
}
