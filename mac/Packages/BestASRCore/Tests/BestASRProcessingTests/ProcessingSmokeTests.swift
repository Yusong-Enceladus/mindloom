import BestASRDictationFixtures
import Foundation
import XCTest

final class ProcessingSmokeTests: XCTestCase {
  func testDeterministicHarnessCompletesWithoutHardwareOrNetwork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-processing-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await DeterministicDictationHarness.run(at: root)

    XCTAssertEqual(result.snapshot.phase.rawValue, "completed")
    XCTAssertEqual(result.audioRangeCount, 3)
    XCTAssertEqual(result.transcripts.count, 1)
    XCTAssertEqual(result.derivations.count, 1)
    XCTAssertEqual(result.insertionCallCount, 1)
    XCTAssertEqual(result.insertionMutationCount, 1)
    XCTAssertEqual(result.speakerScheduleCount, 1)
    XCTAssertEqual(result.networkAttemptCount, 0)
  }
}
