import Foundation
import XCTest

@testable import BestASREvidence

final class EvidenceSchemaTests: XCTestCase {
  private let schemaNames = [
    "environment",
    "spike-summary",
    "benchmark-result",
    "benchmark-run",
    "corpus-manifest",
    "traceability",
    "diagnostic-bundle",
    "engineering-readiness",
    "ax-live-insertion",
    "ax-compatibility-matrix",
    "process-tap-tcc-denial",
  ]

  func testValidFixturesMatchEveryEvidenceSchema() throws {
    for schemaName in schemaNames {
      try validate(fixture: "valid", against: schemaName)
    }
  }

  func testRepositoryCorpusManifestsMatchSchema() throws {
    let schemaURL =
      repositoryRoot
      .appendingPathComponent("schemas/evidence/corpus-manifest.schema.json")
    let schemaData = try Data(contentsOf: schemaURL)
    let tiers = [
      "public",
      "product-synthetic",
      "device-lab",
      "private-consented",
      "adversarial",
      "release-holdout",
    ]

    let manifestPaths =
      tiers.map { "Corpus/\($0)/manifest.json" }
      + ["Corpus/product-synthetic/speaker-manifest.json"]

    for manifestPath in manifestPaths {
      let manifestURL = repositoryRoot.appendingPathComponent(manifestPath)
      try JSONSchemaSubsetValidator.validate(
        instanceData: Data(contentsOf: manifestURL),
        schemaData: schemaData
      )
    }
  }

  func testRepositoryRecommendedMemoryASRResultsMatchSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/benchmark-result.schema.json"
      )
    )
    let reportNames = [
      "fluid-sensevoice-recommended-memory-smoke.json",
      "whisperkit-recommended-memory-smoke.json",
      "sherpa-onnx-recommended-memory-smoke.json",
    ]

    for reportName in reportNames {
      let reportURL = repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-ASR-001/\(reportName)"
      )
      try JSONSchemaSubsetValidator.validate(
        instanceData: Data(contentsOf: reportURL),
        schemaData: schemaData
      )
    }
  }

  func testRepositoryRecommendedMemorySpeakerResultsMatchSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/benchmark-result.schema.json"
      )
    )
    let reportNames = [
      "fluid-automatic-recommended-memory-smoke.json",
      "fluid-oracle-recommended-memory-smoke.json",
      "argmax-automatic-recommended-memory-smoke.json",
      "argmax-oracle-recommended-memory-smoke.json",
      "sherpa-automatic-recommended-memory-smoke.json",
      "sherpa-oracle-recommended-memory-smoke.json",
    ]

    for reportName in reportNames {
      let reportURL = repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-SPK-001/\(reportName)"
      )
      try JSONSchemaSubsetValidator.validate(
        instanceData: Data(contentsOf: reportURL),
        schemaData: schemaData
      )
    }
  }

  func testRepositoryTraceabilityManifestMatchesSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/traceability.schema.json"
      )
    )
    let manifestData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/traceability.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: manifestData,
        schemaData: schemaData
      )
    )
  }

  func testRepositoryEngineeringReadinessReportMatchesSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/engineering-readiness.schema.json"
      )
    )
    let reportData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/readiness/engineering-readiness-report.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: reportData,
        schemaData: schemaData
      )
    )
  }

  func testRepositoryDictationAlphaEvidenceMatchesSchemas() throws {
    let pairs = [
      (
        "schemas/evidence/dictation-deterministic-vertical-slice.schema.json",
        "artifacts/evidence/dictation-alpha/deterministic-vertical-slice.json"
      ),
      (
        "schemas/evidence/dictation-alpha-readiness.schema.json",
        "artifacts/evidence/readiness/dictation-alpha-readiness-report.json"
      ),
    ]
    for (schemaPath, evidencePath) in pairs {
      XCTAssertNoThrow(
        try JSONSchemaSubsetValidator.validate(
          instanceData: Data(
            contentsOf: repositoryRoot.appendingPathComponent(evidencePath)
          ),
          schemaData: Data(
            contentsOf: repositoryRoot.appendingPathComponent(schemaPath)
          )
        )
      )
    }
  }

  func testRepositoryAXLiveInsertionReportMatchesSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/ax-live-insertion.schema.json"
      )
    )
    let reportData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-INS-001/live-summary.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: reportData,
        schemaData: schemaData
      )
    )
  }

  func testRepositoryAXCompatibilityMatrixMatchesSchema() throws {
    let schemaData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "schemas/evidence/ax-compatibility-matrix.schema.json"
      )
    )
    let reportData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "artifacts/evidence/SPIKE-INS-001/compatibility-summary.json"
      )
    )

    XCTAssertNoThrow(
      try JSONSchemaSubsetValidator.validate(
        instanceData: reportData,
        schemaData: schemaData
      )
    )
  }

  func testMissingRequiredFieldsFailClosed() throws {
    for schemaName in schemaNames {
      XCTAssertThrowsError(
        try validate(fixture: "missing-required", against: schemaName),
        "Expected missing-required fixture to fail for \(schemaName)"
      )
    }
  }

  func testUnknownSchemaVersionsFailClosed() throws {
    for schemaName in schemaNames {
      XCTAssertThrowsError(
        try validate(fixture: "unknown-version", against: schemaName),
        "Expected unknown-version fixture to fail for \(schemaName)"
      ) { error in
        XCTAssertTrue(
          String(describing: error).contains("const"),
          "Expected const failure for \(schemaName), got: \(error)"
        )
      }
    }
  }

  func testUnsupportedSchemaKeywordFailsClosed() throws {
    let schema = Data(
      """
      {"type":"object","oneOf":[{"type":"object"}]}
      """.utf8
    )
    let instance = Data("{}".utf8)

    XCTAssertThrowsError(
      try JSONSchemaSubsetValidator.validate(instanceData: instance, schemaData: schema)
    ) { error in
      XCTAssertTrue(String(describing: error).contains("unsupported schema keyword"))
    }
  }

  private func validate(fixture fixtureName: String, against schemaName: String) throws {
    let schemaURL =
      repositoryRoot
      .appendingPathComponent("schemas/evidence/\(schemaName).schema.json")
    let fixtureURL =
      repositoryRoot
      .appendingPathComponent("Tests/Fixtures/EvidenceSchemas/\(schemaName)/\(fixtureName).json")

    try JSONSchemaSubsetValidator.validate(
      instanceData: Data(contentsOf: fixtureURL),
      schemaData: Data(contentsOf: schemaURL)
    )
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      let marker = candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md")
      if FileManager.default.fileExists(atPath: marker.path) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root from \(#filePath)")
  }
}
