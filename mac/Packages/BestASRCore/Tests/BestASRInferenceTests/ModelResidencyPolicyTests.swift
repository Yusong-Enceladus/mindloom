import BestASRInference
import XCTest

final class ModelResidencyPolicyTests: XCTestCase {
  func testTheRecognizerStaysAnHourAndTheOthersTenMinutes() {
    let policy = ModelResidencyPolicy.standard
    XCTAssertEqual(policy.residency(of: .recognizer), .seconds(3_600))
    XCTAssertEqual(policy.residency(of: .secondary), .seconds(600))
  }

  /// The steps the runtime's idle timer follows (review 2026-10-06: the
  /// helper these tests used to cover was never called by the runtime).
  func testAfterADictationTheSecondaryModelsGoFirstAndTheRecognizerAfterAnHour() {
    XCTAssertEqual(
      ModelResidencyPolicy.standard.idleReleaseSchedule(afterDictation: true),
      [
        .init(after: .seconds(600), models: [.secondary]),
        .init(after: .seconds(3_600), models: [.recognizer]),
      ])
  }

  func testALaunchNobodyDictatedIntoLetsEverythingGoAfterTenMinutes() {
    XCTAssertEqual(
      ModelResidencyPolicy.standard.idleReleaseSchedule(afterDictation: false),
      [.init(after: .seconds(600), models: [.recognizer, .secondary])])
  }

  func testARecognizerTimerNoLongerThanTheOthersReleasesEverythingAtOnce() {
    let policy = ModelResidencyPolicy(recognizer: .seconds(60), secondary: .seconds(60))
    XCTAssertEqual(
      policy.idleReleaseSchedule(afterDictation: true),
      [.init(after: .seconds(60), models: [.recognizer, .secondary])])
  }

  /// Recommendation 5 (2026-10-06): a warning keeps the recognizer, so a
  /// warning its own load raised does not make every dictation cold.
  func testAWarningReleasesTheOthersAndKeepsTheRecognizer() {
    let policy = ModelResidencyPolicy.standard
    XCTAssertEqual(policy.modelsToRelease(on: .warning), [.secondary])
    XCTAssertEqual(policy.modelsToRelease(on: .normal), [])
  }

  func testCriticalPressureReleasesEveryModelAtOnce() {
    XCTAssertEqual(
      ModelResidencyPolicy.standard.modelsToRelease(on: .critical), [.recognizer, .secondary])
  }

  func testAWarningThatLastsAMinuteReleasesTheRecognizerToo() {
    let policy = ModelResidencyPolicy.standard
    XCTAssertEqual(policy.recognizerPressureGrace, .seconds(60))
    XCTAssertEqual(policy.modelsToRelease(afterWarningLasting: .seconds(59)), [])
    XCTAssertEqual(policy.modelsToRelease(afterWarningLasting: .seconds(60)), [.recognizer])
  }
}
