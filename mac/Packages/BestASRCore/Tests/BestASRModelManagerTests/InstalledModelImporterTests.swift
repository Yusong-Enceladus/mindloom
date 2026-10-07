import Foundation
import XCTest

@testable import BestASRModelManager

/// Mindloom Preview's 「使用这台 Mac 上已装的识别模型」 on a fake library tree
/// (never the owner's real library): only registry-listed, active, matching
/// artifacts under `models/` are taken; personal models and everything else
/// stay where they are.
final class InstalledModelImporterTests: XCTestCase {
  private struct Tree {
    let library: URL
    let preview: URL
    let registry: ManagedModelRegistry
    let artifactID: String
  }

  func testImportsTheActiveRegistryArtifactAndNothingElse() async throws {
    let tree = try await makeTree()
    let importer = InstalledModelImporter(
      source: tree.library.appendingPathComponent("models"), registry: tree.registry)
    XCTAssertEqual(importer.candidates().map(\.artifactID), [tree.artifactID])

    let destination = try LocalModelManager(
      rootDirectory: tree.preview.appendingPathComponent("models"), registry: tree.registry)
    let outcome = await importer.importAll(into: destination, healthCheck: WeightsPresent())
    XCTAssertEqual(outcome.imported, [tree.artifactID])
    XCTAssertEqual(outcome.failed, [])
    let active = try await destination.discoverActive(
      artifactID: tree.artifactID, healthCheck: WeightsPresent())
    XCTAssertEqual(active.descriptor.exactVersion, "1.0.0")
    // Nothing but the model went across.
    let copied = try allFiles(tree.preview)
    XCTAssertFalse(copied.contains { $0.contains("personal-models") || $0.contains("secret") })
    XCTAssertFalse(copied.contains { $0.hasSuffix("history.sqlite") })
    // The source is untouched.
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: tree.library.appendingPathComponent("personal-models/cleanup/current/secret.bin")
          .path))

    // A second run finds it already active.
    let again = await importer.importAll(into: destination, healthCheck: WeightsPresent())
    XCTAssertEqual(again.alreadyActive, [tree.artifactID])
  }

  func testRefusesPointersThatLeaveTheVersionsFolderOrAreLinks() async throws {
    let tree = try await makeTree()
    let models = tree.library.appendingPathComponent("models")
    let pointerURL = models.appendingPathComponent("active/\(tree.artifactID).json")
    var pointer = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as? [String: Any])

    // A pointer naming another folder (e.g. personal models).
    pointer["relativePath"] = "../personal-models/cleanup/current"
    try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
    let importer = InstalledModelImporter(source: models, registry: tree.registry)
    XCTAssertEqual(importer.candidates(), [])

    // A pointer that is a symbolic link.
    try FileManager.default.removeItem(at: pointerURL)
    let elsewhere = tree.library.appendingPathComponent("elsewhere.json")
    pointer["relativePath"] = "versions/\(tree.artifactID)/1.0.0"
    try JSONSerialization.data(withJSONObject: pointer).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: pointerURL, withDestinationURL: elsewhere)
    XCTAssertEqual(importer.candidates(), [])

    // A version folder that is a symbolic link.
    try FileManager.default.removeItem(at: pointerURL)
    try FileManager.default.copyItem(at: elsewhere, to: pointerURL)
    let version = models.appendingPathComponent("versions/\(tree.artifactID)/1.0.0")
    let moved = tree.library.appendingPathComponent("moved-version")
    try FileManager.default.moveItem(at: version, to: moved)
    try FileManager.default.createSymbolicLink(at: version, withDestinationURL: moved)
    XCTAssertEqual(importer.candidates(), [])
  }

  /// fix-mac: `active/` itself as a symbolic link is refused too.
  func testRefusesALinkedActiveFolder() async throws {
    let tree = try await makeTree()
    let models = tree.library.appendingPathComponent("models")
    let importer = InstalledModelImporter(source: models, registry: tree.registry)
    XCTAssertEqual(importer.candidates().count, 1)
    let active = models.appendingPathComponent("active")
    let moved = tree.library.appendingPathComponent("moved-active")
    try FileManager.default.moveItem(at: active, to: moved)
    try FileManager.default.createSymbolicLink(at: active, withDestinationURL: moved)
    XCTAssertEqual(importer.candidates(), [])
  }

  func testIgnoresArtifactsTheRegistryDoesNotList() async throws {
    let tree = try await makeTree()
    let other = ManagedModelRegistry(
      schemaVersion: 1,
      models: tree.registry.models.map {
        ManagedModelArtifact(
          id: "another-model", exactVersion: $0.exactVersion,
          activationSequence: $0.activationSequence, downloadBaseURL: $0.downloadBaseURL,
          sourceRevision: $0.sourceRevision, treeSHA256: $0.treeSHA256, license: $0.license,
          licenseFile: $0.licenseFile, licenseSHA256: $0.licenseSHA256,
          totalSizeBytes: $0.totalSizeBytes, files: $0.files)
      }, selectionStatus: "fixture")
    let importer = InstalledModelImporter(
      source: tree.library.appendingPathComponent("models"), registry: other)
    XCTAssertEqual(importer.candidates(), [])
    // No source folder at all: nothing offered.
    let missing = InstalledModelImporter(
      source: tree.library.appendingPathComponent("nope"), registry: tree.registry)
    XCTAssertEqual(missing.candidates(), [])
  }

  // MARK: - Fake tree

  private func makeTree() async throws -> Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mindloom-model-import-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library", isDirectory: true)
    let preview = root.appendingPathComponent("preview", isDirectory: true)
    let source = root.appendingPathComponent("download", isDirectory: true)
    let contents = ["weights.bin": "fixture-weights", "nested/vocab.json": "vocab"]
    for (path, text) in contents {
      let file = source.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
    let files = try contents.keys.sorted().map { path in
      let file = source.appendingPathComponent(path)
      let size = try XCTUnwrap(
        (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value)
      return ManagedModelFile(
        relativePath: path, sizeBytes: size, sha256: try LocalModelManager.sha256(of: file))
    }
    let artifactID = "fixture-asr"
    let artifact = ManagedModelArtifact(
      id: artifactID, exactVersion: "1.0.0", activationSequence: 1,
      downloadBaseURL: "https://huggingface.co/bestasr/fixture/resolve/"
        + String(repeating: "1", count: 40),
      sourceRevision: String(repeating: "1", count: 40),
      treeSHA256: String(repeating: "a", count: 64), license: "LicenseRef-Fixture",
      licenseFile: "Legal/fixture.txt", licenseSHA256: String(repeating: "c", count: 64),
      totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, files: files)
    let registry = ManagedModelRegistry(
      schemaVersion: 1, models: [artifact], selectionStatus: "fixture")
    // The fake library: its models installed the ordinary way, plus things
    // that must never be taken.
    let libraryModels = try LocalModelManager(
      rootDirectory: library.appendingPathComponent("models"), registry: registry)
    _ = try await libraryModels.activate(
      artifactID: artifactID, from: source, healthCheck: WeightsPresent())
    let secret = library.appendingPathComponent("personal-models/cleanup/current/secret.bin")
    try FileManager.default.createDirectory(
      at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("personal".utf8).write(to: secret)
    try Data("records".utf8).write(to: library.appendingPathComponent("history.sqlite"))
    return Tree(library: library, preview: preview, registry: registry, artifactID: artifactID)
  }

  private func allFiles(_ root: URL) throws -> [String] {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { ($0 as? URL)?.path }
  }
}

private struct WeightsPresent: ManagedModelHealthChecking {
  func check(modelDirectory: URL) async throws {
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.appendingPathComponent("weights.bin").path)
    else { throw ModelManagerError(.healthCheckFailed, code: "fixture-health-failed") }
  }
}
