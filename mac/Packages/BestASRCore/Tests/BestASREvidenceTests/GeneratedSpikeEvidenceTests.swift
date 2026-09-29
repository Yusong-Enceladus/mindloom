import BestASRAudioJournalProbe
import CryptoKit
import Foundation
import XCTest

@testable import BestASREvidence

final class GeneratedSpikeEvidenceTests: XCTestCase {
  func testSecuritySpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-SEC-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testSecurityMatrixHasNoSkippedOrFailedScenario() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-SEC-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])

    XCTAssertEqual(scenarios.count, 10)
    XCTAssertTrue(
      scenarios.allSatisfy { $0["status"] as? String == "pass" }
    )
  }

  func testMigrationSpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-MIG-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testMigrationMatrixHasNoSkippedOrFailedScenario() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-MIG-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])

    XCTAssertEqual(scenarios.count, 10)
    XCTAssertTrue(
      scenarios.allSatisfy { $0["status"] as? String == "pass" }
    )
  }

  func testAudioTimelineSpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-TIM-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testAudioTimelineMatrixHasCompletePassingMetadata() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-TIM-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
    let chunks = try XCTUnwrap(root["chunks"] as? [[String: Any]])

    XCTAssertEqual(scenarios.count, 5)
    XCTAssertEqual(chunks.count, 8)
    XCTAssertTrue(
      scenarios.allSatisfy { $0["status"] as? String == "pass" }
    )
    XCTAssertTrue(
      chunks.allSatisfy {
        ($0["contentDigest"] as? String)?.count == 64
          && $0["hostTime"] != nil
          && $0["monotonicStartNanoseconds"] != nil
          && $0["sampleRateHertz"] != nil
          && $0["frameCount"] != nil
          && $0["sequence"] != nil
      }
    )
  }

  func testAudioJournalSpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-JRN-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testAudioJournalMatrixCoversKillBoundariesAndBothTracks() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-JRN-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
    let killScenarios = scenarios.filter {
      ($0["scenarioID"] as? String)?.hasPrefix("sigkill-seed-") == true
    }
    let metrics = killScenarios.compactMap { $0["metrics"] as? [String: String] }
    let faultPoints = Set(metrics.compactMap { $0["faultPoint"] })
    let tracks = Set(metrics.compactMap { $0["trackID"] })

    XCTAssertEqual(scenarios.count, 18)
    XCTAssertEqual(killScenarios.count, 12)
    XCTAssertEqual(
      faultPoints, Set(AudioJournalFaultPoint.allCases.filter { $0 != .none }.map(\.rawValue)))
    XCTAssertEqual(tracks, ["microphone", "system"])
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(root["maximumUncommittedLossNanoseconds"] as? NSNumber)
        .uint64Value,
      2_000_000_000
    )
  }

  func testWorkerSpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-WRK-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testWorkerMatrixPassesWithoutDuplicateTranscriptCommit() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-WRK-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
    let reconnect = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String
          == "reconnect-drains-durable-backlog-without-duplicate-transcript"
      }
    )
    let metrics = try XCTUnwrap(reconnect["metrics"] as? [String: String])

    XCTAssertEqual(scenarios.count, 5)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertEqual(metrics["duplicateTranscriptCommitCount"], "0")
  }

  func testXPCSpikeSummaryMatchesEvidenceSchema() throws {
    let root = repositoryRoot
    let summary = try Data(
      contentsOf: root.appendingPathComponent(
        "artifacts/evidence/SPIKE-XPC-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: root.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testXPCMatrixPassesCrashRestartAndIdempotency() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-XPC-001/matrix.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
    let crash = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String == "worker-crash-restart-and-job-replay"
      }
    )
    let duplicate = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String
          == "duplicate-response-collapses-by-idempotency-key"
      }
    )
    let crashMetrics = try XCTUnwrap(crash["metrics"] as? [String: String])
    let duplicateMetrics = try XCTUnwrap(
      duplicate["metrics"] as? [String: String]
    )

    XCTAssertEqual(scenarios.count, 6)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertEqual(crashMetrics["captureCommittedChunkCount"], "3")
    XCTAssertEqual(duplicateMetrics["duplicateTranscriptCommitCount"], "0")
  }

  func testXPCRuntimeComparisonIsConditionalWithExplicitRollback() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-XPC-001/comparison.json"
      )
    )
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
    let memory = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String == "memory-reclamation-lifetime"
      }
    )
    let crash = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String == "crash-domain-isolation"
      }
    )
    let signing = try XCTUnwrap(
      scenarios.first {
        $0["scenarioID"] as? String == "signing-and-bundle-complexity"
      }
    )
    let memoryMetrics = try XCTUnwrap(memory["metrics"] as? [String: String])
    let crashMetrics = try XCTUnwrap(crash["metrics"] as? [String: String])
    let signingMetrics = try XCTUnwrap(signing["metrics"] as? [String: String])
    let rollback = try XCTUnwrap(root["rollback"] as? String)
    let unmetCriteria = try XCTUnwrap(root["unmetCriteria"] as? [String])

    XCTAssertEqual(scenarios.count, 4)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertEqual(root["conclusion"] as? String, "conditional")
    XCTAssertFalse(rollback.isEmpty)
    XCTAssertFalse(unmetCriteria.isEmpty)
    XCTAssertEqual(memoryMetrics["workerProcessExitObserved"], "true")
    XCTAssertEqual(crashMetrics["sameProcessCrashTerminatedHost"], "true")
    XCTAssertEqual(crashMetrics["xpcCrashTerminatedHost"], "false")
    XCTAssertEqual(crashMetrics["xpcWorkerRestarted"], "true")
    XCTAssertEqual(signingMetrics["inProcessCodeObjectCount"], "1")
    XCTAssertEqual(signingMetrics["xpcCodeObjectCount"], "2")
  }

  func testASRCandidateAdapterSmokeIsSharedAuditableAndNonSelecting() throws {
    let reportURL = repositoryRoot.appendingPathComponent(
      "artifacts/evidence/SPIKE-ASR-001/adapter-contract-smoke.json"
    )
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: reportURL))
        as? [String: Any]
    )
    let candidates = try XCTUnwrap(report["candidates"] as? [[String: Any]])
    let requirements = try XCTUnwrap(report["requirementsCovered"] as? [String])
    let unmet = try XCTUnwrap(report["unmetReleaseCriteria"] as? [String])

    XCTAssertEqual(report["conclusion"] as? String, "pass")
    XCTAssertEqual(
      report["selectionDecision"] as? String,
      "no-default-candidate-selected"
    )
    XCTAssertEqual(
      requirements,
      (1...10).map { String(format: "ASR-%03d", $0) }
    )
    XCTAssertEqual(candidates.count, 3)
    XCTAssertFalse(unmet.isEmpty)
    for candidate in candidates {
      let scenarios = try XCTUnwrap(candidate["scenarios"] as? [[String: Any]])
      XCTAssertEqual(candidate["digestScope"] as? String, "contract-fixture-only")
      XCTAssertEqual(candidate["executionMode"] as? String, "contract-fixture-runtime")
      XCTAssertEqual(candidate["releaseEligible"] as? Bool, false)
      XCTAssertEqual(scenarios.count, 10)
      XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    }

    let manifestData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/inference-candidates.json"
      )
    )
    let fixtureData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/CandidateAdapters/contract-cases.json"
      )
    )
    XCTAssertEqual(report["manifestSHA256"] as? String, sha256(manifestData))
    XCTAssertEqual(report["fixtureSuiteSHA256"] as? String, sha256(fixtureData))
  }

  func testLLMFactualGateSummaryMatchesEvidenceSchema() throws {
    let summary = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-LLM-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testLLMFactualGateRejectsHigherStyleCandidateInEveryCategory() throws {
    let matrix = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repositoryRoot.appendingPathComponent(
            "artifacts/evidence/SPIKE-LLM-001/matrix.json"
          )
        )
      ) as? [String: Any]
    )
    let candidates = try XCTUnwrap(matrix["candidates"] as? [[String: Any]])
    let scenarios = try XCTUnwrap(matrix["scenarios"] as? [[String: Any]])
    let safe = try XCTUnwrap(
      candidates.first { $0["candidateID"] as? String == "fact-preserving-fixture" }
    )
    let unsafe = try XCTUnwrap(
      candidates.first {
        $0["candidateID"] as? String
          == "style-preferred-factually-unsafe-fixture"
      }
    )
    let unsafeCategories = try XCTUnwrap(
      unsafe["categoryResults"] as? [[String: Any]]
    )

    XCTAssertEqual(matrix["conclusion"] as? String, "pass")
    XCTAssertEqual(matrix["sourceMutationDetected"] as? Bool, false)
    XCTAssertEqual(scenarios.count, 8)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertEqual(safe["hardGateEligible"] as? Bool, true)
    XCTAssertEqual(unsafe["hardGateEligible"] as? Bool, false)
    XCTAssertGreaterThan(
      try XCTUnwrap(unsafe["meanStylePreferenceScore"] as? Double),
      try XCTUnwrap(safe["meanStylePreferenceScore"] as? Double)
    )
    XCTAssertEqual(unsafeCategories.count, 5)
    XCTAssertTrue(
      unsafeCategories.allSatisfy {
        $0["errorCount"] as? Int == 1
          && $0["hardLimit"] as? Int == 0
          && $0["passed"] as? Bool == false
      }
    )

    let fixtureData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/LocalText/factual-gate-suite.json"
      )
    )
    XCTAssertEqual(matrix["fixtureSHA256"] as? String, sha256(fixtureData))
  }

  func testResourcePolicySummaryMatchesEvidenceSchema() throws {
    let summary = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-RES-001/summary.json"
      )
    )
    let schema = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/spike-summary.schema.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: summary,
        schemaData: schema
      )
    )
  }

  func testResourcePolicyMatrixPreservesCaptureThroughEveryPressure() throws {
    let matrix = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repositoryRoot.appendingPathComponent(
            "artifacts/evidence/SPIKE-RES-001/matrix.json"
          )
        )
      ) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(matrix["scenarios"] as? [[String: Any]])
    let priorityOrder = try XCTUnwrap(matrix["priorityOrder"] as? [String])

    XCTAssertEqual(matrix["conclusion"] as? String, "pass")
    XCTAssertEqual(
      priorityOrder,
      ["capture", "journal", "live-asr", "final-asr", "local-text", "speaker"]
    )
    XCTAssertEqual(scenarios.count, 8)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertTrue(
      scenarios.allSatisfy { $0["sourceAudioLost"] as? Bool == false }
    )
    XCTAssertEqual(matrix["attemptedCaptureChunkCount"] as? Int, 16)
    XCTAssertEqual(matrix["committedCaptureChunkCount"] as? Int, 16)
    XCTAssertEqual(matrix["recoveredReadableChunkCount"] as? Int, 16)
    XCTAssertEqual(matrix["gapCount"] as? Int, 0)
  }

  func testUpdateRollbackEvidenceUsesSeparateKeysAndPreservesData() throws {
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repositoryRoot.appendingPathComponent(
            "artifacts/evidence/updates/update-rollback-summary.json"
          )
        )
      ) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])

    XCTAssertEqual(report["conclusion"] as? String, "pass")
    XCTAssertEqual(report["signingAlgorithm"] as? String, "Ed25519")
    XCTAssertEqual(report["finalAppVersion"] as? String, "1.1.0")
    XCTAssertEqual(report["finalModelVersion"] as? String, "2.0.0")
    XCTAssertEqual(report["userDataUnchanged"] as? Bool, true)
    XCTAssertEqual(report["sourceAudioPreserved"] as? Bool, true)
    XCTAssertNotEqual(
      report["appPublicKeySHA256"] as? String,
      report["modelPublicKeySHA256"] as? String
    )
    XCTAssertEqual(scenarios.count, 10)
    XCTAssertTrue(
      scenarios.allSatisfy {
        $0["status"] as? String == "pass"
          && $0["appAndModelNamespacesSeparated"] as? Bool == true
          && $0["userDataUnchanged"] as? Bool == true
          && $0["sourceAudioPreserved"] as? Bool == true
          && $0["stagingRemoved"] as? Bool == true
      }
    )
    let failures = scenarios.filter { $0["expectedFailure"] != nil }
    XCTAssertEqual(failures.count, 8)
    XCTAssertTrue(
      failures.allSatisfy {
        $0["expectedFailure"] as? String
          == $0["observedFailure"] as? String
      }
    )
  }

  func testTextInsertionContractFailsClosedButRemainsConditional() throws {
    let reportURL = repositoryRoot.appendingPathComponent(
      "artifacts/evidence/SPIKE-INS-001/contract-summary.json"
    )
    let data = try Data(contentsOf: reportURL)
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])
    let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertEqual(report["contractConclusion"] as? String, "pass")
    XCTAssertEqual(report["conclusion"] as? String, "conditional")
    XCTAssertEqual(report["liveCompatibilityEvaluated"] as? Bool, false)
    XCTAssertEqual(scenarios.count, 9)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertTrue(
      scenarios.allSatisfy { $0["wrongTargetWriteCount"] as? Int == 0 }
    )
    XCTAssertFalse(serialized.contains("fixture replacement"))
    XCTAssertFalse(serialized.contains("com.bestasr.ax-fixture"))
  }

  func testAXLiveInsertionEvidenceCoversSafetyMatrixWithoutTargetContent() throws {
    let reportURL = repositoryRoot.appendingPathComponent(
      "artifacts/evidence/SPIKE-INS-001/live-summary.json"
    )
    let data = try Data(contentsOf: reportURL)
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])
    let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
    let scenarioIDs = Set(
      scenarios.compactMap { $0["scenarioID"] as? String }
    )

    XCTAssertEqual(report["conclusion"] as? String, "pass")
    XCTAssertEqual(report["liveAccessibilityEvaluated"] as? Bool, true)
    XCTAssertEqual(
      report["externalApplicationMatrixEvaluated"] as? Bool,
      false
    )
    XCTAssertEqual(scenarios.count, 7)
    XCTAssertTrue(
      scenarios.allSatisfy {
        $0["status"] as? String == "pass"
          && $0["wrongTargetWriteCount"] as? Int == 0
          && ($0["durationMilliseconds"] as? Double ?? 0) > 0
      }
    )
    XCTAssertEqual(
      scenarioIDs,
      [
        "live-selection-replace",
        "live-clipboard-fallback-restores-owned-pasteboard",
        "live-noneditable-rejected",
        "live-secure-field-rejected",
        "live-permission-denial-fails-before-write",
        "live-focus-race-fails-closed",
        "live-selection-race-fails-closed",
      ]
    )
    XCTAssertTrue(
      scenarios.contains {
        $0["insertionMethod"] as? String == "accessibility-selection"
      }
    )
    XCTAssertTrue(
      scenarios.contains {
        $0["insertionMethod"] as? String == "clipboard-paste"
      }
    )
    XCTAssertFalse(serialized.contains("fixture replacement"))
    XCTAssertFalse(serialized.contains("synthetic-secret"))
    XCTAssertFalse(serialized.contains("alpha target omega"))
    XCTAssertFalse(serialized.contains("com.bestasr.spike"))
  }

  func testTwoHourRecordingEvidenceHasNoDroppedFramesAndReopensExactly() throws {
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repositoryRoot.appendingPathComponent(
            "artifacts/evidence/SPIKE-JRN-001/long-recording.json"
          )
        )
      ) as? [String: Any]
    )
    let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])
    let deviceEvents = try XCTUnwrap(
      report["deviceEvents"] as? [[String: Any]]
    )
    let resourceSamples = try XCTUnwrap(
      report["resourceSamples"] as? [[String: Any]]
    )

    XCTAssertEqual(report["conclusion"] as? String, "pass")
    XCTAssertGreaterThanOrEqual(
      try XCTUnwrap(report["requestedDurationNanoseconds"] as? Int),
      7_200_000_000_000
    )
    XCTAssertGreaterThanOrEqual(
      try XCTUnwrap(report["measuredDurationNanoseconds"] as? Int),
      7_200_000_000_000
    )
    XCTAssertEqual(report["committedChunkCount"] as? Int, 7_199)
    XCTAssertEqual(report["droppedFrameCount"] as? Int, 0)
    XCTAssertEqual(report["gapCount"] as? Int, 1)
    XCTAssertEqual(deviceEvents.count, 2)
    XCTAssertEqual(
      deviceEvents.compactMap { $0["kind"] as? String },
      ["deviceDisconnected", "deviceReconnected"]
    )
    XCTAssertEqual(scenarios.count, 6)
    XCTAssertTrue(scenarios.allSatisfy { $0["status"] as? String == "pass" })
    XCTAssertGreaterThan(resourceSamples.count, 100)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
