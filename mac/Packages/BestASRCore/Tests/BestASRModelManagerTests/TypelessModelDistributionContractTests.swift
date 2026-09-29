import Foundation
import XCTest

@testable import BestASRModelManager

final class ModelArtifactRegistryTests: XCTestCase {
  func testProductCatalogPinsBothRecommendedArtifactsAndLicenseInventory() throws {
    let registry = try productionRegistry()
    let expected: [(String, String)] = [
      ("fluid-sensevoice-small-int8-0e0bf30b", "LicenseRef-FunASR-Model-1.1"),
      ("qwen3-1.7b-mlx-4bit-21457c6f", "Apache-2.0"),
    ]

    for (artifactID, license) in expected {
      let artifact = try XCTUnwrap(registry.artifact(id: artifactID))
      XCTAssertEqual(artifact.license, license)
      XCTAssertEqual(artifact.exactVersion, artifact.sourceRevision)
      XCTAssertEqual(artifact.sourceRevision.count, 40)
      XCTAssertTrue(artifact.downloadBaseURL.hasPrefix("https://huggingface.co/"))
      XCTAssertTrue(
        artifact.downloadBaseURL.hasSuffix("/resolve/\(artifact.sourceRevision)")
      )
      XCTAssertEqual(
        artifact.files.reduce(UInt64(0)) { $0 + $1.sizeBytes },
        artifact.totalSizeBytes
      )
      XCTAssertFalse(artifact.files.contains { $0.relativePath.hasPrefix("/") })
    }
  }

  func testCatalogRejectsMalformedOrMutableDownloadLocation() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/model-artifacts.json"
      ))
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var models = try XCTUnwrap(root["models"] as? [[String: Any]])
    models[0]["downloadBaseURL"] = "https://huggingface.co/example/latest"
    root["models"] = models

    XCTAssertThrowsError(
      try ManagedModelRegistry.decode(
        JSONSerialization.data(withJSONObject: root)
      )
    )
  }
}

final class ModelDistributionDomainTests: XCTestCase {
  func testEveryReadinessStateRoundTripsWithBoundedMetadataOnly() throws {
    for phase in [
      ModelDistributionPhase.consentRequired, .downloading, .verifying, .warming,
      .ready, .retryableFailure, .incompatible,
    ] {
      let state = ModelDistributionState(
        artifactID: "fixture-model",
        version: String(repeating: "1", count: 40),
        phase: phase,
        completedBytes: 4,
        totalBytes: 10,
        currentFile: "weights.bin",
        errorCode: phase == .retryableFailure ? "network-interrupted" : nil
      )
      let data = try JSONEncoder().encode(state)
      XCTAssertEqual(
        try JSONDecoder().decode(ModelDistributionState.self, from: data),
        state
      )
      let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
      for prohibited in [
        "transcript", "dictionary", "speaker", "participant", "windowTitle",
        "clipboard", "foregroundText",
      ] {
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains(prohibited))
      }
    }
  }
}

private func productionRegistry() throws -> ManagedModelRegistry {
  try ManagedModelRegistry.decode(
    Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/model-artifacts.json"
      ))
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
