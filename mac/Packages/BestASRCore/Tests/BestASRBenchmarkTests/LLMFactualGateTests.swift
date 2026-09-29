import Foundation
import XCTest

@testable import BestASRBenchmark

final class LLMFactualGateTests: XCTestCase {
  func testHigherStyleScoreCannotBypassAnyDangerousFactCategory() throws {
    let suite = try loadSuite()
    let sourceBefore = suite.sources
    let evaluation = try LLMFactualHardGate.evaluate(suite)
    let safe = try XCTUnwrap(
      evaluation.candidateResults.first {
        $0.candidateID == "fact-preserving-fixture"
      }
    )
    let unsafe = try XCTUnwrap(
      evaluation.candidateResults.first {
        $0.candidateID == "style-preferred-factually-unsafe-fixture"
      }
    )

    XCTAssertTrue(safe.hardGateEligible)
    XCTAssertTrue(safe.failedSampleUUIDs.isEmpty)
    XCTAssertTrue(safe.categoryResults.allSatisfy(\.passed))
    XCTAssertGreaterThan(
      unsafe.meanStylePreferenceScore,
      safe.meanStylePreferenceScore
    )
    XCTAssertFalse(unsafe.hardGateEligible)
    XCTAssertEqual(unsafe.failedSampleUUIDs.count, 5)
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: unsafe.categoryResults.map {
          ($0.category, $0.errorCount)
        }
      ),
      Dictionary(
        uniqueKeysWithValues: DangerousTokenCategory.allCases.map { ($0, 1) }
      )
    )
    XCTAssertEqual(suite.sources, sourceBefore)
  }

  func testGateRequiresCompleteCategoryAndCandidateSampleCoverage() throws {
    let suite = try loadSuite()
    let incompleteSources = suite.sources.filter {
      !$0.dangerousTokens.contains { $0.category == .actionOwner }
    }
    let incompleteSuite = LLMFactualGateSuite(
      suiteID: suite.suiteID,
      sources: incompleteSources,
      candidates: suite.candidates.map {
        LLMFactualCandidate(
          candidateID: $0.candidateID,
          modelArtifactSHA256: $0.modelArtifactSHA256,
          samples: $0.samples.filter { sample in
            incompleteSources.contains { $0.sampleUUID == sample.sampleUUID }
          }
        )
      }
    )
    XCTAssertThrowsError(try LLMFactualHardGate.evaluate(incompleteSuite)) {
      XCTAssertEqual(
        $0 as? LLMFactualGateError,
        .incompleteCategoryCoverage
      )
    }

    let missingSampleCandidate = LLMFactualCandidate(
      candidateID: suite.candidates[0].candidateID,
      modelArtifactSHA256: suite.candidates[0].modelArtifactSHA256,
      samples: Array(suite.candidates[0].samples.dropLast())
    )
    let missingSampleSuite = LLMFactualGateSuite(
      suiteID: suite.suiteID,
      sources: suite.sources,
      candidates: [missingSampleCandidate]
    )
    XCTAssertThrowsError(try LLMFactualHardGate.evaluate(missingSampleSuite)) {
      XCTAssertEqual(
        $0 as? LLMFactualGateError,
        .candidateSampleSetMismatch(missingSampleCandidate.candidateID)
      )
    }
  }

  private func loadSuite() throws -> LLMFactualGateSuite {
    try JSONDecoder().decode(
      LLMFactualGateSuite.self,
      from: Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "Tests/Fixtures/LocalText/factual-gate-suite.json"
        )
      )
    )
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
