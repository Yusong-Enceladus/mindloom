import BestASRMLXRuntime
import CryptoKit
import Foundation
import XCTest

/// v12 search: the meaning model the App installs is the one in the signed
/// catalog (same revision, files, sizes and tree digest), and everything
/// that shapes its vectors is part of the version the index is built under.
final class MLXMeaningArtifactTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  func testSelectedArtifactMatchesTheCatalogEntry() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent("config/model-artifacts.json"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let models = try XCTUnwrap(root["models"] as? [[String: Any]])
    let artifact = MLXMeaningArtifact.selected
    let entry = try XCTUnwrap(models.first { ($0["id"] as? String) == artifact.artifactID })
    XCTAssertEqual(entry["sourceRevision"] as? String, artifact.sourceRevision)
    XCTAssertEqual(entry["exactVersion"] as? String, artifact.sourceRevision)
    XCTAssertEqual(entry["treeSHA256"] as? String, artifact.treeSHA256)
    XCTAssertEqual((entry["totalSizeBytes"] as? NSNumber)?.uint64Value, artifact.totalSizeBytes)
    XCTAssertEqual(entry["license"] as? String, "Apache-2.0")
    XCTAssertTrue(
      (entry["downloadBaseURL"] as? String)?.hasSuffix("/resolve/\(artifact.sourceRevision)")
        == true)
    XCTAssertTrue(artifact.recipe.modelVersion.contains(String(artifact.sourceRevision.prefix(12))))

    // The tree digest is the one the files give (sha256-shasum-path-list-v1).
    let files = try XCTUnwrap(entry["files"] as? [[String: Any]])
    let listing = files.compactMap { file -> (String, String)? in
      guard let path = file["relativePath"] as? String, let sha = file["sha256"] as? String else {
        return nil
      }
      return (path, sha)
    }
    .sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    .map { "\($0.1)  ./\($0.0)\n" }.joined()
    let digest = SHA256.hash(data: Data(listing.utf8)).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(digest, artifact.treeSHA256)
    let total = files.compactMap { ($0["sizeBytes"] as? NSNumber)?.uint64Value }.reduce(0, +)
    XCTAssertEqual(total, artifact.totalSizeBytes)
  }

  func testEverythingThatShapesVectorsChangesTheVersion() {
    let base = MLXMeaningRecipe.qwen3Embedding(
      name: "m", revision: String(repeating: "a", count: 40))
    let shorter = MLXMeaningRecipe.qwen3Embedding(
      name: "m", revision: String(repeating: "a", count: 40), dimension: 512)
    let otherPrompt = MLXMeaningRecipe.qwen3Embedding(
      name: "m", revision: String(repeating: "a", count: 40), instruction: "Instruct: x\nQuery:")
    let otherRevision = MLXMeaningRecipe.qwen3Embedding(
      name: "m", revision: String(repeating: "b", count: 40))
    let versions = Set([base, shorter, otherPrompt, otherRevision].map(\.modelVersion))
    XCTAssertEqual(versions.count, 4)
    XCTAssertEqual(shorter.dimension, 512)
    XCTAssertEqual(base.dimension, 1_024)
  }
}
