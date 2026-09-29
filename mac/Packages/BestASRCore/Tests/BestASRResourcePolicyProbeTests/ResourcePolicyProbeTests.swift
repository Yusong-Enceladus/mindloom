import Foundation
import XCTest

@testable import BestASRResourcePolicyProbe

final class ResourcePolicyProbeTests: XCTestCase {
  func testPriorityAndPressureDirectivesPreserveCaptureAndJournal() async throws {
    let controller = ResourcePolicyController()
    let decision = try await controller.evaluate(
      snapshot(
        memory: .critical,
        thermal: .critical,
        backlog: 4
      )
    )

    XCTAssertEqual(decision.state, .degradedLive)
    XCTAssertEqual(decision.transition, .enteredDegraded)
    XCTAssertEqual(
      decision.directives.map(\.priorityRank),
      [0, 1, 2, 3, 4, 4]
    )
    XCTAssertEqual(decision.directive(for: .capture)?.action, .run)
    XCTAssertEqual(decision.directive(for: .journal)?.action, .run)
    XCTAssertEqual(decision.directive(for: .liveASR)?.action, .deferDurably)
    XCTAssertEqual(decision.directive(for: .finalASR)?.action, .deferDurably)
    XCTAssertEqual(decision.directive(for: .speaker)?.action, .unloadAndDefer)
    XCTAssertEqual(decision.directive(for: .localText)?.action, .unloadAndDefer)
    XCTAssertEqual(
      Set(decision.observableReasonCodes),
      Set(["memory-critical", "thermal-critical", "backlog-full"])
    )
  }

  func testNormalSnapshotRecoversDeferredWorkObservably() async throws {
    let controller = ResourcePolicyController()
    _ = try await controller.evaluate(snapshot(memory: .warning))
    let decision = try await controller.evaluate(snapshot())

    XCTAssertEqual(decision.state, .normal)
    XCTAssertEqual(decision.transition, .recovered)
    XCTAssertTrue(decision.observableReasonCodes.isEmpty)
    XCTAssertTrue(decision.directives.allSatisfy { $0.action == .run })
  }

  func testInvalidBacklogIsRejected() async {
    let controller = ResourcePolicyController()
    do {
      _ = try await controller.evaluate(snapshot(backlog: 5))
      XCTFail("backlog beyond capacity must fail closed")
    } catch {
      XCTAssertEqual(error as? ResourcePolicyError, .invalidBacklog)
    }
  }

  func testProbeMatrixPassesWithoutSourceAudioLoss() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-resource-policy-test-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let matrix = try await ResourcePolicyProbeRunner.run(
      configuration: ResourcePolicyProbeConfiguration(
        summaryURL: root.appendingPathComponent("summary.json"),
        matrixURL: root.appendingPathComponent("matrix.json")
      )
    )

    XCTAssertEqual(matrix.conclusion, "pass")
    XCTAssertEqual(matrix.scenarios.count, 8)
    XCTAssertTrue(matrix.scenarios.allSatisfy { $0.status == "pass" })
    XCTAssertTrue(matrix.scenarios.allSatisfy { !$0.sourceAudioLost })
    XCTAssertEqual(matrix.attemptedCaptureChunkCount, 16)
    XCTAssertEqual(matrix.committedCaptureChunkCount, 16)
    XCTAssertEqual(matrix.recoveredReadableChunkCount, 16)
    XCTAssertEqual(matrix.gapCount, 0)
  }

  private func snapshot(
    memory: ResourceMemoryPressure = .normal,
    thermal: ResourceThermalPressure = .nominal,
    backlog: Int = 0
  ) -> ResourcePressureSnapshot {
    ResourcePressureSnapshot(
      snapshotID: UUID(),
      memoryPressure: memory,
      thermalPressure: thermal,
      inferenceBacklog: backlog,
      inferenceBacklogCapacity: 4,
      recordingActive: true
    )
  }
}
