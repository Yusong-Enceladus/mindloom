import Foundation
import XCTest

@testable import BestASRModelManagerProbe

final class ModelManagerProbeTests: XCTestCase {
  func testSuccessfulActivationSwitchesPointerOnlyAfterHealthCheck() throws {
    let fixture = try makeFixture()
    let manager = ModelManagerProbe(root: fixture.store)
    let descriptor = try descriptor(
      artifactID: "fixture-model",
      version: "1.0.0",
      source: fixture.completeSource
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: descriptor,
      sourceDirectory: fixture.completeSource,
      healthCheck: PassingModelHealthCheck()
    )

    XCTAssertEqual(attempt.status, .pass)
    XCTAssertNil(attempt.failureCategory)
    XCTAssertEqual(attempt.activeVersionAfter, "1.0.0")
    XCTAssertTrue(attempt.stagingRemoved)
    XCTAssertEqual(try manager.activeVersion(for: "fixture-model"), "1.0.0")
  }

  func testPartialDownloadPreservesLastKnownGood() throws {
    let fixture = try makeFixture()
    let manager = ModelManagerProbe(root: fixture.store)
    try activateKnownGood(manager: manager, source: fixture.completeSource)
    let missingFile = ModelFileDescriptor(
      relativePath: "missing.bin",
      sizeBytes: 4,
      sha256: String(repeating: "0", count: 64)
    )
    let partialDescriptor = ModelArtifactDescriptor(
      artifactID: "fixture-model",
      version: "2.0.0",
      files: [
        try fileDescriptor(
          relativePath: "weights.bin",
          source: fixture.completeSource
        ),
        missingFile,
      ]
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: partialDescriptor,
      sourceDirectory: fixture.completeSource,
      healthCheck: PassingModelHealthCheck()
    )

    assertRollback(attempt, category: .partialDownload)
  }

  func testDigestMismatchPreservesLastKnownGood() throws {
    let fixture = try makeFixture()
    let manager = ModelManagerProbe(root: fixture.store)
    try activateKnownGood(manager: manager, source: fixture.completeSource)
    let validFile = try fileDescriptor(
      relativePath: "weights.bin",
      source: fixture.completeSource
    )
    let descriptor = ModelArtifactDescriptor(
      artifactID: "fixture-model",
      version: "2.0.0",
      files: [
        ModelFileDescriptor(
          relativePath: validFile.relativePath,
          sizeBytes: validFile.sizeBytes,
          sha256: String(repeating: "f", count: 64)
        )
      ]
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: descriptor,
      sourceDirectory: fixture.completeSource,
      healthCheck: PassingModelHealthCheck()
    )

    assertRollback(attempt, category: .digestMismatch)
  }

  func testHealthCheckFailurePreservesLastKnownGood() throws {
    let fixture = try makeFixture()
    let manager = ModelManagerProbe(root: fixture.store)
    try activateKnownGood(manager: manager, source: fixture.completeSource)
    let descriptor = try descriptor(
      artifactID: "fixture-model",
      version: "2.0.0",
      source: fixture.completeSource
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: descriptor,
      sourceDirectory: fixture.completeSource,
      healthCheck: FailingModelHealthCheck()
    )

    assertRollback(attempt, category: .healthCheckFailed)
  }

  func testDowngradePreservesLastKnownGood() throws {
    let fixture = try makeFixture()
    let manager = ModelManagerProbe(root: fixture.store)
    try activateKnownGood(manager: manager, source: fixture.completeSource)
    let descriptor = try descriptor(
      artifactID: "fixture-model",
      version: "0.9.0",
      source: fixture.completeSource
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: descriptor,
      sourceDirectory: fixture.completeSource,
      healthCheck: PassingModelHealthCheck()
    )

    assertRollback(attempt, category: .downgradeRejected)
  }

  func testPointerWriteFailureRemovesMovedVersionDirectory() throws {
    let fixture = try makeFixture()
    try FileManager.default.createDirectory(
      at: fixture.store,
      withIntermediateDirectories: true
    )
    try Data("blocks active directory".utf8).write(
      to: fixture.store.appendingPathComponent("active")
    )
    let manager = ModelManagerProbe(root: fixture.store)
    let model = try descriptor(
      artifactID: "fixture-model",
      version: "1.0.0",
      source: fixture.completeSource
    )

    let attempt = manager.stageVerifyAndActivate(
      descriptor: model,
      sourceDirectory: fixture.completeSource,
      healthCheck: PassingModelHealthCheck()
    )

    XCTAssertEqual(attempt.status, .fail)
    XCTAssertEqual(attempt.failureCategory, .fileSystem)
    XCTAssertTrue(attempt.stagingRemoved)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.store.appendingPathComponent(
          "versions/fixture-model/1.0.0"
        ).path
      )
    )
  }

  private func assertRollback(
    _ attempt: ModelActivationAttempt,
    category: ModelActivationFailureCategory,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(attempt.status, .fail, file: file, line: line)
    XCTAssertEqual(attempt.failureCategory, category, file: file, line: line)
    XCTAssertEqual(attempt.previousActiveVersion, "1.0.0", file: file, line: line)
    XCTAssertEqual(attempt.activeVersionAfter, "1.0.0", file: file, line: line)
    XCTAssertTrue(attempt.lastKnownGoodPreserved, file: file, line: line)
    XCTAssertTrue(attempt.stagingRemoved, file: file, line: line)
  }

  private func activateKnownGood(manager: ModelManagerProbe, source: URL) throws {
    let knownGood = try descriptor(
      artifactID: "fixture-model",
      version: "1.0.0",
      source: source
    )
    let attempt = manager.stageVerifyAndActivate(
      descriptor: knownGood,
      sourceDirectory: source,
      healthCheck: PassingModelHealthCheck()
    )
    XCTAssertEqual(attempt.status, .pass)
  }

  private func descriptor(
    artifactID: String,
    version: String,
    source: URL
  ) throws -> ModelArtifactDescriptor {
    ModelArtifactDescriptor(
      artifactID: artifactID,
      version: version,
      files: [
        try fileDescriptor(relativePath: "weights.bin", source: source)
      ]
    )
  }

  private func fileDescriptor(relativePath: String, source: URL) throws
    -> ModelFileDescriptor
  {
    let file = source.appendingPathComponent(relativePath)
    let size = try XCTUnwrap(
      (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
        .intValue
    )
    return ModelFileDescriptor(
      relativePath: relativePath,
      sizeBytes: size,
      sha256: try ModelManagerProbe.sha256(of: file)
    )
  }

  private func makeFixture() throws -> (root: URL, store: URL, completeSource: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-model-manager-\(UUID().uuidString)")
    let store = root.appendingPathComponent("store", isDirectory: true)
    let completeSource = root.appendingPathComponent("complete", isDirectory: true)
    try FileManager.default.createDirectory(
      at: completeSource,
      withIntermediateDirectories: true
    )
    try Data("fixture model bytes".utf8)
      .write(to: completeSource.appendingPathComponent("weights.bin"))
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return (root, store, completeSource)
  }
}
