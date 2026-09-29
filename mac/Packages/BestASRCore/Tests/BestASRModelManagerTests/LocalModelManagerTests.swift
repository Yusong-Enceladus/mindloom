import CryptoKit
import Foundation
import XCTest

@testable import BestASRModelManager

final class LocalModelManagerTests: XCTestCase {
  func testProductionRegistryDecodesPinnedSenseVoiceArtifact() throws {
    let registry = try productionRegistry()
    let artifact = try XCTUnwrap(
      registry.artifact(id: "fluid-sensevoice-small-int8-0e0bf30b")
    )

    XCTAssertEqual(
      artifact.exactVersion,
      "0e0bf30bfc6836f182ccd1d89984df919c949e26"
    )
    XCTAssertEqual(artifact.activationSequence, 1)
    XCTAssertEqual(artifact.files.count, 10)
    XCTAssertEqual(artifact.totalSizeBytes, 239_918_735)
    XCTAssertEqual(artifact.license, "LicenseRef-FunASR-Model-1.1")
    XCTAssertTrue(artifact.downloadBaseURL.hasPrefix("https://huggingface.co/"))
    XCTAssertTrue(artifact.downloadBaseURL.hasSuffix(artifact.sourceRevision))
  }

  func testRegistryRejectsInsecureOrUnpinnedDownloadSource() throws {
    let original = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/model-artifacts.json"
      )
    )
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: original) as? [String: Any]
    )
    var models = try XCTUnwrap(root["models"] as? [[String: Any]])
    models[0]["downloadBaseURL"] = "http://example.com/latest"
    root["models"] = models
    let tampered = try JSONSerialization.data(withJSONObject: root)
    XCTAssertThrowsError(try ManagedModelRegistry.decode(tampered)) { error in
      XCTAssertEqual((error as? ModelManagerError)?.category, .invalidManifest)
    }
  }

  func testActivationIsAtomicDiscoverableAfterRestartAndIdempotent() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    let first = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: fixture.sourceV1,
      healthCheck: PassingHealthCheck()
    )

    XCTAssertEqual(first.disposition, .activated)
    XCTAssertNil(first.previousActiveVersion)
    XCTAssertEqual(first.lastKnownGoodVersion, fixture.v1.exactVersion)
    XCTAssertEqual(first.verifiedFileCount, 2)

    let reopened = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    let active = try await reopened.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(active.descriptor, fixture.v1)
    XCTAssertEqual(active.recovery, .none)

    let missingSource = fixture.root.appendingPathComponent("not-present")
    let repeated = try await reopened.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: missingSource,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(repeated.disposition, .alreadyActive)
  }

  func testPartialInstallAndDigestMismatchLeaveNoFalseActiveModel() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    try FileManager.default.removeItem(
      at: fixture.sourceV1.appendingPathComponent("nested/vocab.json")
    )

    await assertFailure(.partialInstall) {
      _ = try await manager.activate(
        artifactID: fixture.artifactID,
        version: fixture.v1.exactVersion,
        from: fixture.sourceV1,
        healthCheck: PassingHealthCheck()
      )
    }
    await assertFailure(.missingModel) {
      _ = try await manager.discoverActive(
        artifactID: fixture.artifactID,
        healthCheck: PassingHealthCheck()
      )
    }
    XCTAssertTrue(try directoryEntries(fixture.store.appendingPathComponent("staging")).isEmpty)

    try Data("wrong bytes".utf8).write(
      to: fixture.sourceV1.appendingPathComponent("nested/vocab.json"),
      options: .atomic
    )
    await assertFailure(.sizeMismatch) {
      _ = try await manager.activate(
        artifactID: fixture.artifactID,
        version: fixture.v1.exactVersion,
        from: fixture.sourceV1,
        healthCheck: PassingHealthCheck()
      )
    }
  }

  func testDigestAndHealthFailuresPreserveLastKnownGood() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: fixture.sourceV1,
      healthCheck: PassingHealthCheck()
    )

    try Data("same-size-wrong".utf8).write(
      to: fixture.sourceV2.appendingPathComponent("weights.bin"),
      options: .atomic
    )
    await assertFailure(.digestMismatch) {
      _ = try await manager.activate(
        artifactID: fixture.artifactID,
        version: fixture.v2.exactVersion,
        from: fixture.sourceV2,
        healthCheck: PassingHealthCheck()
      )
    }
    var active = try await manager.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(active.descriptor.version, fixture.v1.version)

    try restore(source: fixture.sourceV2, contents: fixture.v2Contents)
    await assertFailure(.healthCheckFailed) {
      _ = try await manager.activate(
        artifactID: fixture.artifactID,
        version: fixture.v2.exactVersion,
        from: fixture.sourceV2,
        healthCheck: FailingHealthCheck()
      )
    }
    active = try await manager.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(active.descriptor.version, fixture.v1.version)
  }

  func testCorruptActiveVersionAutomaticallyRestoresLastKnownGood() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: fixture.sourceV1,
      healthCheck: PassingHealthCheck()
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v2.exactVersion,
      from: fixture.sourceV2,
      healthCheck: PassingHealthCheck()
    )

    let activeV2File = fixture.store.appendingPathComponent(
      "versions/\(fixture.artifactID)/\(fixture.v2.version)/weights.bin"
    )
    try Data("corrupt".utf8).write(to: activeV2File, options: .atomic)

    let recovered = try await manager.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(recovered.descriptor.version, fixture.v1.version)
    XCTAssertEqual(recovered.recovery, .restoredLastKnownGood)
    XCTAssertEqual(recovered.replacedVersion, fixture.v2.version)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: activeV2File.path),
      "recovery must not silently delete the damaged artifact"
    )

    let afterRestart = try await manager.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(afterRestart.descriptor.version, fixture.v1.version)
    XCTAssertEqual(afterRestart.recovery, .none)
  }

  func testInvalidActiveAndRollbackEnterRepairWithoutDeletingAnything() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: fixture.sourceV1,
      healthCheck: PassingHealthCheck()
    )
    let installed = fixture.store.appendingPathComponent(
      "versions/\(fixture.artifactID)/\(fixture.v1.version)/weights.bin"
    )
    try Data("damaged".utf8).write(to: installed, options: .atomic)

    await assertFailure(.repairRequired) {
      _ = try await manager.discoverActive(
        artifactID: fixture.artifactID,
        healthCheck: PassingHealthCheck()
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
  }

  func testPointerCorruptionRecoversFromVerifiedLastKnownGood() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v1.exactVersion,
      from: fixture.sourceV1,
      healthCheck: PassingHealthCheck()
    )
    try Data("not json".utf8).write(
      to: fixture.store.appendingPathComponent(
        "active/\(fixture.artifactID).json"
      ),
      options: .atomic
    )

    let recovered = try await manager.discoverActive(
      artifactID: fixture.artifactID,
      healthCheck: PassingHealthCheck()
    )
    XCTAssertEqual(recovered.descriptor.version, fixture.v1.version)
    XCTAssertEqual(recovered.recovery, .restoredLastKnownGood)
  }

  func testDowngradeIsRejectedAndSourceSymlinkIsNeverFollowed() async throws {
    let fixture = try makeFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.store,
      registry: fixture.registry
    )
    _ = try await manager.activate(
      artifactID: fixture.artifactID,
      version: fixture.v2.exactVersion,
      from: fixture.sourceV2,
      healthCheck: PassingHealthCheck()
    )
    await assertFailure(.downgradeRejected) {
      _ = try await manager.activate(
        artifactID: fixture.artifactID,
        version: fixture.v1.exactVersion,
        from: fixture.sourceV1,
        healthCheck: PassingHealthCheck()
      )
    }

    let symlinkSource = fixture.root.appendingPathComponent("symlink-source")
    try FileManager.default.createDirectory(
      at: symlinkSource.appendingPathComponent("nested"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: symlinkSource.appendingPathComponent("weights.bin"),
      withDestinationURL: fixture.sourceV1.appendingPathComponent("weights.bin")
    )
    try FileManager.default.copyItem(
      at: fixture.sourceV1.appendingPathComponent("nested/vocab.json"),
      to: symlinkSource.appendingPathComponent("nested/vocab.json")
    )
    let freshStore = fixture.root.appendingPathComponent("fresh-store")
    let fresh = try LocalModelManager(
      rootDirectory: freshStore,
      registry: fixture.registry
    )
    await assertFailure(.partialInstall) {
      _ = try await fresh.activate(
        artifactID: fixture.artifactID,
        version: fixture.v1.exactVersion,
        from: symlinkSource,
        healthCheck: PassingHealthCheck()
      )
    }
  }

  func testProductionManagerContainsNoNetworkingOrImplicitDownloadPath() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Packages/BestASRCore/Sources/BestASRModelManager/LocalModelManager.swift"
      ),
      encoding: .utf8
    )
    XCTAssertFalse(source.contains("URLSession"))
    XCTAssertFalse(source.contains("downloadTask"))
    XCTAssertFalse(source.contains("downloadAndLoad"))
    XCTAssertFalse(source.contains("ModelHub"))
  }

  private func assertFailure(
    _ category: ModelManagerFailureCategory,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected model-manager failure: \(category)")
    } catch let error as ModelManagerError {
      XCTAssertEqual(error.category, category, error.code)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func productionRegistry() throws -> ManagedModelRegistry {
    try ManagedModelRegistry.decode(
      Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "config/model-artifacts.json"
        )
      )
    )
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-production-model-manager-\(UUID().uuidString)",
      isDirectory: true
    )
    let sourceV1 = root.appendingPathComponent("source-v1", isDirectory: true)
    let sourceV2 = root.appendingPathComponent("source-v2", isDirectory: true)
    let v1Contents = ["weights.bin": "fixture-v1-data", "nested/vocab.json": "vocab-v1"]
    let v2Contents = ["weights.bin": "fixture-v2-data", "nested/vocab.json": "vocab-v2"]
    try restore(source: sourceV1, contents: v1Contents)
    try restore(source: sourceV2, contents: v2Contents)

    let artifactID = "fixture-sensevoice"
    let v1 = try artifact(
      id: artifactID,
      version: "1.0.0",
      sequence: 1,
      source: sourceV1
    )
    let v2 = try artifact(
      id: artifactID,
      version: "2.0.0",
      sequence: 2,
      source: sourceV2
    )
    let registry = ManagedModelRegistry(
      schemaVersion: 1,
      models: [v1, v2],
      selectionStatus: "fixture"
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Fixture(
      root: root,
      store: root.appendingPathComponent("store"),
      sourceV1: sourceV1,
      sourceV2: sourceV2,
      artifactID: artifactID,
      registry: registry,
      v1: v1,
      v2: v2,
      v2Contents: v2Contents
    )
  }

  private func artifact(
    id: String,
    version: String,
    sequence: UInt64,
    source: URL
  ) throws -> ManagedModelArtifact {
    let relativePaths = ["weights.bin", "nested/vocab.json"]
    let files = try relativePaths.map { relativePath in
      let file = source.appendingPathComponent(relativePath)
      let size = try XCTUnwrap(
        (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
          .uint64Value
      )
      return ManagedModelFile(
        relativePath: relativePath,
        sizeBytes: size,
        sha256: try LocalModelManager.sha256(of: file)
      )
    }
    return ManagedModelArtifact(
      id: id,
      exactVersion: version,
      activationSequence: sequence,
      downloadBaseURL:
        "https://huggingface.co/bestasr/fixture/resolve/\(String(repeating: sequence == 1 ? "1" : "2", count: 40))",
      sourceRevision: String(repeating: sequence == 1 ? "1" : "2", count: 40),
      treeSHA256: String(repeating: sequence == 1 ? "a" : "b", count: 64),
      license: "LicenseRef-Fixture",
      licenseFile: "Legal/fixture.txt",
      licenseSHA256: String(repeating: "c", count: 64),
      totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
      files: files
    )
  }

  private func restore(source: URL, contents: [String: String]) throws {
    try? FileManager.default.removeItem(at: source)
    for (relativePath, text) in contents {
      let file = source.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(text.utf8).write(to: file, options: .atomic)
    }
  }

  private func directoryEntries(_ directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
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

private struct Fixture {
  let root: URL
  let store: URL
  let sourceV1: URL
  let sourceV2: URL
  let artifactID: String
  let registry: ManagedModelRegistry
  let v1: ManagedModelArtifact
  let v2: ManagedModelArtifact
  let v2Contents: [String: String]
}

private struct PassingHealthCheck: ManagedModelHealthChecking {
  func check(modelDirectory: URL) async throws {
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.appendingPathComponent("weights.bin").path
      )
    else {
      throw ModelManagerError(.healthCheckFailed, code: "fixture-health-failed")
    }
  }
}

private struct FailingHealthCheck: ManagedModelHealthChecking {
  func check(modelDirectory: URL) async throws {
    throw ModelManagerError(.healthCheckFailed, code: "fixture-health-failed")
  }
}
