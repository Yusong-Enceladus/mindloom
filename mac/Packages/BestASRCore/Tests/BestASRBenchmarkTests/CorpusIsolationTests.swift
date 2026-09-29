import Foundation
import XCTest

@testable import BestASRBenchmark

final class CorpusIsolationTests: XCTestCase {
  func testTuningCannotReadHoldoutByDirectPathOrSymlink() throws {
    let fixture = try makeFixtureRoots()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try IsolatedCorpusStore(
      tuningRoot: fixture.tuning,
      releaseHoldoutRoot: fixture.release
    )
    let tuningURL = fixture.tuning.appendingPathComponent("manifest.json")
    let releaseURL = fixture.release.appendingPathComponent("manifest.json")
    try write(manifest(tier: .productSynthetic), to: tuningURL)
    try write(manifest(tier: .releaseHoldout), to: releaseURL)

    XCTAssertNoThrow(try store.loadManifest(at: tuningURL, mode: .tuning))
    XCTAssertThrowsError(
      try store.loadManifest(at: releaseURL, mode: .tuning)
    ) { error in
      XCTAssertEqual(error as? CorpusIsolationError, .unauthorizedPath)
    }

    let linkURL = fixture.tuning.appendingPathComponent("holdout-link.json")
    try FileManager.default.createSymbolicLink(
      at: linkURL,
      withDestinationURL: releaseURL
    )
    XCTAssertThrowsError(
      try store.loadManifest(at: linkURL, mode: .tuning)
    ) { error in
      XCTAssertEqual(error as? CorpusIsolationError, .unauthorizedPath)
    }
  }

  func testLogicalSplitMustMatchEvaluationMode() throws {
    let fixture = try makeFixtureRoots()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try IsolatedCorpusStore(
      tuningRoot: fixture.tuning,
      releaseHoldoutRoot: fixture.release
    )
    let mislabeledTuning = fixture.tuning.appendingPathComponent("mislabeled.json")
    let releaseURL = fixture.release.appendingPathComponent("manifest.json")
    try write(manifest(tier: .releaseHoldout), to: mislabeledTuning)
    try write(manifest(tier: .releaseHoldout), to: releaseURL)

    XCTAssertThrowsError(
      try store.loadManifest(at: mislabeledTuning, mode: .tuning)
    ) { error in
      XCTAssertEqual(error as? CorpusIsolationError, .logicalHoldoutViolation)
    }
    XCTAssertEqual(
      try store.loadManifest(at: releaseURL, mode: .releaseEvaluation).tier,
      .releaseHoldout
    )
  }

  func testRootsMustBePhysicallyDisjoint() throws {
    let fixture = try makeFixtureRoots()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let nested = fixture.tuning.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nested,
      withIntermediateDirectories: true
    )

    XCTAssertThrowsError(
      try IsolatedCorpusStore(
        tuningRoot: fixture.tuning,
        releaseHoldoutRoot: nested
      )
    ) { error in
      XCTAssertEqual(error as? CorpusIsolationError, .rootsNotSeparated)
    }
  }

  private func makeFixtureRoots() throws -> (root: URL, tuning: URL, release: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-corpus-isolation-\(UUID().uuidString)",
      isDirectory: true
    )
    let tuning = root.appendingPathComponent("tuning", isDirectory: true)
    let release = root.appendingPathComponent("release", isDirectory: true)
    try FileManager.default.createDirectory(at: tuning, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    return (root, tuning, release)
  }

  private func manifest(tier: CorpusTier) -> CorpusManifest {
    CorpusManifest(
      manifestID: tier == .releaseHoldout ? "release-v1" : "tuning-v1",
      version: "1.0.0",
      tier: tier,
      releaseHoldout: tier == .releaseHoldout,
      containsPrivateContent: false,
      samples: [
        CorpusSampleManifest(
          sampleUUID: UUID(),
          consentClass: "synthetic",
          assetReference: "fixture://synthetic/opaque",
          contentDigest: String(repeating: "a", count: 64),
          languages: ["zh-CN", "en-US"],
          tags: ["synthetic"]
        )
      ]
    )
  }

  private func write(_ manifest: CorpusManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(to: url, options: .atomic)
  }
}
