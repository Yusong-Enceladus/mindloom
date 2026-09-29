import BestASRAudioJournalProbe
import BestASRLongRecordingProbe
import Foundation
import XCTest

final class LongRecordingProbeTests: XCTestCase {
  func testDiskPressurePolicyPrioritizesCapture() {
    let policy = DiskPressurePolicy(
      softWatermarkBytes: 1_000,
      hardWatermarkBytes: 500
    )
    XCTAssertEqual(
      policy.decision(availableBytes: 2_000),
      DiskPressureDecision(
        level: .normal,
        captureMayContinue: true,
        heavyInferenceMayRun: true
      )
    )
    XCTAssertEqual(
      policy.decision(availableBytes: 750),
      DiskPressureDecision(
        level: .soft,
        captureMayContinue: true,
        heavyInferenceMayRun: false
      )
    )
    XCTAssertEqual(
      policy.decision(availableBytes: 500),
      DiskPressureDecision(
        level: .hard,
        captureMayContinue: false,
        heavyInferenceMayRun: false
      )
    )
  }

  func testDiskStopPreservesCommittedChunkWithoutFalseComplete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try AudioJournal.create(
      at: root,
      sessionID: UUID(),
      tracks: [AudioJournalTrack(trackID: "mic", role: "microphoneLocal")]
    )
    try journal.append(
      trackID: "mic",
      pcmBytes: Data(repeating: 0, count: 32),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: 16_000,
      frameCount: 16
    )
    try journal.stopForDiskPressure()
    XCTAssertEqual(journal.manifest.state, .stoppedForDiskPressure)
    XCTAssertEqual(journal.availableInferenceRanges().count, 1)
    XCTAssertThrowsError(try journal.finalize())
  }

  func testProbeRejectsChunkLongerThanTwoSeconds() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(
      try LongRecordingProbeRunner.run(
        configuration: LongRecordingProbeConfiguration(
          durationNanoseconds: 1,
          chunkDurationNanoseconds: 2_000_000_001,
          evidenceURL: root.appendingPathComponent("evidence.json"),
          workingRootURL: root
        )
      )
    ) { error in
      XCTAssertEqual(error as? LongRecordingProbeError, .invalidChunkDuration)
    }
  }
}
