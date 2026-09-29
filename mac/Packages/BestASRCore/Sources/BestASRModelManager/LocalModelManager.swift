import CryptoKit
import Darwin
import Foundation

public struct ManagedModelFile: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sizeBytes: UInt64
  public let sha256: String
}

public struct ManagedModelArtifact: Codable, Equatable, Sendable {
  public let id: String
  public let exactVersion: String
  public let activationSequence: UInt64
  public let downloadBaseURL: String
  public let sourceRevision: String
  public let treeSHA256: String
  public let license: String
  public let licenseFile: String
  public let licenseSHA256: String
  public let totalSizeBytes: UInt64
  public let files: [ManagedModelFile]

  public var artifactID: String { id }
  public var version: String { exactVersion }

  public init(
    id: String,
    exactVersion: String,
    activationSequence: UInt64,
    downloadBaseURL: String,
    sourceRevision: String,
    treeSHA256: String,
    license: String,
    licenseFile: String,
    licenseSHA256: String,
    totalSizeBytes: UInt64,
    files: [ManagedModelFile]
  ) {
    self.id = id
    self.exactVersion = exactVersion
    self.activationSequence = activationSequence
    self.downloadBaseURL = downloadBaseURL
    self.sourceRevision = sourceRevision
    self.treeSHA256 = treeSHA256
    self.license = license
    self.licenseFile = licenseFile
    self.licenseSHA256 = licenseSHA256
    self.totalSizeBytes = totalSizeBytes
    self.files = files
  }
}

public struct ManagedModelRegistry: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let models: [ManagedModelArtifact]
  public let selectionStatus: String

  public static func decode(_ data: Data) throws -> Self {
    let registry: Self
    do {
      registry = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw ModelManagerError(.invalidManifest, code: "model-registry-decode-failed")
    }
    try registry.validate()
    return registry
  }

  public func artifact(
    id: String,
    version: String? = nil
  ) -> ManagedModelArtifact? {
    let candidates = models.filter { model in
      model.id == id && (version == nil || model.exactVersion == version)
    }
    return candidates.max { $0.activationSequence < $1.activationSequence }
  }

  fileprivate func validate() throws {
    guard schemaVersion == 1, !selectionStatus.isEmpty, !models.isEmpty else {
      throw ModelManagerError(.invalidManifest, code: "model-registry-invalid-root")
    }
    var identities = Set<String>()
    var sequencesByArtifact: [String: Set<UInt64>] = [:]
    for model in models {
      guard
        Self.safeComponent(model.id),
        Self.safeComponent(model.exactVersion),
        model.activationSequence > 0,
        Self.downloadBaseURL(model.downloadBaseURL, revision: model.sourceRevision),
        Self.revision(model.sourceRevision),
        Self.digest(model.treeSHA256),
        !model.license.isEmpty,
        Self.safeRelativePath(model.licenseFile),
        Self.digest(model.licenseSHA256),
        model.totalSizeBytes > 0,
        !model.files.isEmpty
      else {
        throw ModelManagerError(.invalidManifest, code: "model-artifact-invalid")
      }
      let identity = "\(model.id)\u{1f}\(model.exactVersion)"
      guard identities.insert(identity).inserted else {
        throw ModelManagerError(.invalidManifest, code: "model-artifact-duplicate")
      }
      var sequences = sequencesByArtifact[model.id, default: []]
      guard sequences.insert(model.activationSequence).inserted else {
        throw ModelManagerError(
          .invalidManifest,
          code: "model-activation-sequence-duplicate"
        )
      }
      sequencesByArtifact[model.id] = sequences

      var filePaths = Set<String>()
      var total: UInt64 = 0
      for file in model.files {
        guard
          Self.safeRelativePath(file.relativePath),
          file.sizeBytes > 0,
          Self.digest(file.sha256),
          filePaths.insert(file.relativePath).inserted,
          total <= UInt64.max - file.sizeBytes
        else {
          throw ModelManagerError(.invalidManifest, code: "model-file-invalid")
        }
        total += file.sizeBytes
      }
      guard total == model.totalSizeBytes else {
        throw ModelManagerError(.invalidManifest, code: "model-size-total-mismatch")
      }
    }
  }

  fileprivate static func safeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value.count <= 128
      && value.range(
        of: "^[A-Za-z0-9._-]+$",
        options: .regularExpression
      ) != nil
  }

  fileprivate static func safeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), URL(string: value)?.scheme == nil
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  fileprivate static func digest(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  fileprivate static func revision(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
  }

  fileprivate static func downloadBaseURL(
    _ value: String,
    revision: String
  ) -> Bool {
    guard
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "huggingface.co",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.hasSuffix("/resolve/\(revision)")
    else { return false }
    return true
  }
}

public enum ModelManagerFailureCategory: String, Codable, Sendable {
  case digestMismatch
  case downgradeRejected
  case fileSystem
  case healthCheckFailed
  case invalidManifest
  case missingModel
  case partialInstall
  case repairRequired
  case sizeMismatch
  case unsafePath
}

public struct ModelManagerError: Error, Codable, Equatable, Sendable {
  public let category: ModelManagerFailureCategory
  public let code: String
  public let retryable: Bool

  public init(
    _ category: ModelManagerFailureCategory,
    code: String,
    retryable: Bool? = nil
  ) {
    self.category = category
    self.code = code
    self.retryable =
      retryable
      ?? [
        .fileSystem, .healthCheckFailed, .missingModel, .partialInstall,
        .repairRequired,
      ].contains(category)
  }
}

public protocol ManagedModelHealthChecking: Sendable {
  func check(modelDirectory: URL) async throws
}

public struct FileSetModelHealthCheck: ManagedModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) async throws {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      throw ModelManagerError(
        .healthCheckFailed,
        code: "model-directory-health-check-failed"
      )
    }
  }
}

public enum ModelActivationDisposition: String, Codable, Sendable {
  case activated
  case alreadyActive
  case repaired
}

public struct ModelActivationResult: Codable, Equatable, Sendable {
  public let artifactID: String
  public let version: String
  public let disposition: ModelActivationDisposition
  public let previousActiveVersion: String?
  public let lastKnownGoodVersion: String
  public let verifiedFileCount: Int
}

public enum ModelRecoveryDisposition: String, Codable, Sendable {
  case none
  case restoredLastKnownGood
}

public struct ActiveManagedModel: Equatable, Sendable {
  public let descriptor: ManagedModelArtifact
  public let directory: URL
  public let recovery: ModelRecoveryDisposition
  public let replacedVersion: String?
}

private enum PointerKind: String {
  case active
  case lastKnownGood = "last-known-good"
}

private struct InstalledModelPointer: Codable, Equatable {
  let schemaVersion: Int
  let artifactID: String
  let version: String
  let activationSequence: UInt64
  let treeSHA256: String
  let relativePath: String
}

public actor LocalModelManager {
  private let rootDirectory: URL
  private let registry: ManagedModelRegistry
  private let fileManager = FileManager.default

  public init(
    rootDirectory: URL,
    registry: ManagedModelRegistry
  ) throws {
    try registry.validate()
    guard rootDirectory.path != "/" else {
      throw ModelManagerError(.unsafePath, code: "model-root-too-broad")
    }
    try FileManager.default.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    self.rootDirectory = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
    self.registry = registry
  }

  public func activate(
    artifactID: String,
    version: String? = nil,
    from sourceDirectory: URL,
    healthCheck: any ManagedModelHealthChecking
  ) async throws -> ModelActivationResult {
    guard let descriptor = registry.artifact(id: artifactID, version: version) else {
      throw ModelManagerError(.invalidManifest, code: "model-artifact-not-registered")
    }
    try createStoreDirectories()

    let previousPointer = try? readPointer(.active, artifactID: artifactID)
    if let previousPointer,
      previousPointer.activationSequence > descriptor.activationSequence
    {
      throw ModelManagerError(
        .downgradeRejected,
        code: "model-activation-downgrade-rejected",
        retryable: false
      )
    }

    if let previousPointer,
      previousPointer.version == descriptor.version,
      let existing = try? await verifiedModel(
        pointer: previousPointer,
        artifactID: artifactID,
        healthCheck: healthCheck,
        recovery: .none,
        replacedVersion: nil
      )
    {
      return ModelActivationResult(
        artifactID: artifactID,
        version: descriptor.version,
        disposition: .alreadyActive,
        previousActiveVersion: descriptor.version,
        lastKnownGoodVersion: existing.descriptor.version,
        verifiedFileCount: descriptor.files.count
      )
    }

    let stagingDirectory = stagingURL(for: descriptor)
    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )
    defer { try? removeStagingDirectory(stagingDirectory) }

    do {
      try copyAndVerify(
        descriptor: descriptor,
        sourceDirectory: sourceDirectory,
        stagingDirectory: stagingDirectory
      )
      try await runHealthCheck(healthCheck, directory: stagingDirectory)
    } catch let error as ModelManagerError {
      throw error
    } catch {
      throw ModelManagerError(.fileSystem, code: "model-staging-failed")
    }

    let destination = versionDirectory(for: descriptor)
    var replacedExisting = false
    var quarantineDirectory: URL?
    if fileManager.fileExists(atPath: destination.path) {
      let installedPointer = pointer(for: descriptor)
      if (try? await verifiedModel(
        pointer: installedPointer,
        artifactID: artifactID,
        healthCheck: healthCheck,
        recovery: .none,
        replacedVersion: nil
      )) != nil {
        try removeStagingDirectory(stagingDirectory)
      } else {
        let quarantine = quarantineURL(for: descriptor)
        try fileManager.createDirectory(
          at: quarantine.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: destination, to: quarantine)
        do {
          try fileManager.moveItem(at: stagingDirectory, to: destination)
          replacedExisting = true
          quarantineDirectory = quarantine
        } catch {
          try? fileManager.moveItem(at: quarantine, to: destination)
          throw ModelManagerError(.fileSystem, code: "model-repair-move-failed")
        }
      }
    } else {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      do {
        try fileManager.moveItem(at: stagingDirectory, to: destination)
      } catch {
        throw ModelManagerError(.fileSystem, code: "model-activation-move-failed")
      }
    }
    try synchronizeDirectory(destination.deletingLastPathComponent())

    let newPointer = pointer(for: descriptor)
    let validPreviousPointer: InstalledModelPointer?
    if let previousPointer,
      (try? await verifiedModel(
        pointer: previousPointer,
        artifactID: artifactID,
        healthCheck: healthCheck,
        recovery: .none,
        replacedVersion: nil
      )) != nil
    {
      validPreviousPointer = previousPointer
    } else {
      validPreviousPointer = nil
    }

    do {
      let rollbackPointer = validPreviousPointer ?? newPointer
      try writePointer(rollbackPointer, kind: .lastKnownGood)
      try writePointer(newPointer, kind: .active)
    } catch {
      if replacedExisting, let quarantineDirectory {
        let failedReplacement = quarantineURL(for: descriptor)
        try? fileManager.moveItem(at: destination, to: failedReplacement)
        try? fileManager.moveItem(at: quarantineDirectory, to: destination)
      }
      throw ModelManagerError(.fileSystem, code: "model-pointer-commit-failed")
    }

    return ModelActivationResult(
      artifactID: artifactID,
      version: descriptor.version,
      disposition: replacedExisting ? .repaired : .activated,
      previousActiveVersion: previousPointer?.version,
      lastKnownGoodVersion: (validPreviousPointer ?? newPointer).version,
      verifiedFileCount: descriptor.files.count
    )
  }

  public func discoverActive(
    artifactID: String,
    healthCheck: any ManagedModelHealthChecking
  ) async throws -> ActiveManagedModel {
    var failedActiveVersion: String?
    if let active = try? readPointer(.active, artifactID: artifactID) {
      failedActiveVersion = active.version
      if let verified = try? await verifiedModel(
        pointer: active,
        artifactID: artifactID,
        healthCheck: healthCheck,
        recovery: .none,
        replacedVersion: nil
      ) {
        return verified
      }
    }

    if let rollback = try? readPointer(.lastKnownGood, artifactID: artifactID),
      let verified = try? await verifiedModel(
        pointer: rollback,
        artifactID: artifactID,
        healthCheck: healthCheck,
        recovery: .restoredLastKnownGood,
        replacedVersion: failedActiveVersion
      )
    {
      try writePointer(rollback, kind: .active)
      return verified
    }

    let hasAnyPointer =
      fileManager.fileExists(atPath: pointerURL(.active, artifactID: artifactID).path)
      || fileManager.fileExists(
        atPath: pointerURL(.lastKnownGood, artifactID: artifactID).path
      )
    if hasAnyPointer {
      throw ModelManagerError(
        .repairRequired,
        code: "model-active-and-rollback-invalid"
      )
    }
    throw ModelManagerError(.missingModel, code: "model-not-installed")
  }

  /// Explicitly restores the independently verified last-known-good pointer.
  /// Model bytes are never downloaded or deleted by this operation.
  public func restoreLastKnownGood(
    artifactID: String,
    healthCheck: any ManagedModelHealthChecking
  ) async throws -> ActiveManagedModel {
    let rollback = try readPointer(.lastKnownGood, artifactID: artifactID)
    let active = try? readPointer(.active, artifactID: artifactID)
    let verified = try await verifiedModel(
      pointer: rollback,
      artifactID: artifactID,
      healthCheck: healthCheck,
      recovery: .restoredLastKnownGood,
      replacedVersion: active?.version
    )
    try writePointer(rollback, kind: .active)
    return verified
  }

  public static func sha256(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func createStoreDirectories() throws {
    for component in ["staging", "versions", "active", "last-known-good", "quarantine"] {
      try fileManager.createDirectory(
        at: rootDirectory.appendingPathComponent(component, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
  }

  private func copyAndVerify(
    descriptor: ManagedModelArtifact,
    sourceDirectory: URL,
    stagingDirectory: URL
  ) throws {
    var sourceIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: sourceDirectory.path,
        isDirectory: &sourceIsDirectory
      ),
      sourceIsDirectory.boolValue
    else {
      throw ModelManagerError(.partialInstall, code: "model-source-directory-missing")
    }

    for file in descriptor.files {
      let source = sourceDirectory.appendingPathComponent(file.relativePath)
      let values: URLResourceValues
      do {
        values = try source.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
      } catch {
        throw ModelManagerError(.partialInstall, code: "model-source-file-missing")
      }
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ModelManagerError(.partialInstall, code: "model-source-file-missing")
      }

      let destination = stagingDirectory.appendingPathComponent(file.relativePath)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      do {
        try fileManager.copyItem(at: source, to: destination)
        try FileHandle(forWritingTo: destination).synchronizeAndClose()
      } catch {
        throw ModelManagerError(.fileSystem, code: "model-file-copy-failed")
      }
      try verify(file: destination, expected: file)
    }
    try verifyDirectory(stagingDirectory, descriptor: descriptor)
    try synchronizeDirectory(stagingDirectory)
  }

  private func verifiedModel(
    pointer: InstalledModelPointer,
    artifactID: String,
    healthCheck: any ManagedModelHealthChecking,
    recovery: ModelRecoveryDisposition,
    replacedVersion: String?
  ) async throws -> ActiveManagedModel {
    guard
      pointer.schemaVersion == 1,
      pointer.artifactID == artifactID,
      let descriptor = registry.artifact(
        id: pointer.artifactID,
        version: pointer.version
      ),
      descriptor.activationSequence == pointer.activationSequence,
      descriptor.treeSHA256 == pointer.treeSHA256,
      pointer.relativePath == relativeVersionPath(for: descriptor)
    else {
      throw ModelManagerError(.repairRequired, code: "model-pointer-invalid")
    }
    let directory = rootDirectory.appendingPathComponent(
      pointer.relativePath,
      isDirectory: true
    )
    try verifyDirectory(directory, descriptor: descriptor)
    try await runHealthCheck(healthCheck, directory: directory)
    return ActiveManagedModel(
      descriptor: descriptor,
      directory: directory,
      recovery: recovery,
      replacedVersion: replacedVersion
    )
  }

  private func verifyDirectory(
    _ directory: URL,
    descriptor: ManagedModelArtifact
  ) throws {
    let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedRoot == directory.standardizedFileURL else {
      throw ModelManagerError(.unsafePath, code: "model-directory-symlink-rejected")
    }
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ModelManagerError(.missingModel, code: "model-version-directory-missing")
    }

    let actualFiles = try collectRegularFiles(
      in: directory,
      relativePrefix: ""
    )
    let expectedFiles = Set(descriptor.files.map(\.relativePath))
    guard actualFiles == expectedFiles else {
      throw ModelManagerError(.partialInstall, code: "model-file-set-mismatch")
    }
    for file in descriptor.files {
      try verify(
        file: directory.appendingPathComponent(file.relativePath),
        expected: file
      )
    }
  }

  private func collectRegularFiles(
    in directory: URL,
    relativePrefix: String
  ) throws -> Set<String> {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: []
      )
    } catch {
      throw ModelManagerError(.fileSystem, code: "model-directory-enumeration-failed")
    }

    var files = Set<String>()
    for child in children {
      let values = try child.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else {
        throw ModelManagerError(.unsafePath, code: "model-file-symlink-rejected")
      }
      let relative =
        relativePrefix.isEmpty
        ? child.lastPathComponent
        : "\(relativePrefix)/\(child.lastPathComponent)"
      if values.isDirectory == true {
        files.formUnion(
          try collectRegularFiles(in: child, relativePrefix: relative)
        )
      } else if values.isRegularFile == true {
        files.insert(relative)
      } else {
        throw ModelManagerError(.repairRequired, code: "model-file-kind-invalid")
      }
    }
    return files
  }

  private func verify(file: URL, expected: ManagedModelFile) throws {
    let values = try file.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ModelManagerError(.partialInstall, code: "model-file-missing")
    }
    guard let fileSize = values.fileSize,
      fileSize >= 0,
      UInt64(fileSize) == expected.sizeBytes
    else {
      throw ModelManagerError(.sizeMismatch, code: "model-file-size-mismatch")
    }
    guard try Self.sha256(of: file) == expected.sha256 else {
      throw ModelManagerError(.digestMismatch, code: "model-file-digest-mismatch")
    }
  }

  private func runHealthCheck(
    _ healthCheck: any ManagedModelHealthChecking,
    directory: URL
  ) async throws {
    do {
      try await healthCheck.check(modelDirectory: directory)
    } catch {
      throw ModelManagerError(.healthCheckFailed, code: "model-health-check-failed")
    }
  }

  private func pointer(for descriptor: ManagedModelArtifact) -> InstalledModelPointer {
    InstalledModelPointer(
      schemaVersion: 1,
      artifactID: descriptor.id,
      version: descriptor.exactVersion,
      activationSequence: descriptor.activationSequence,
      treeSHA256: descriptor.treeSHA256,
      relativePath: relativeVersionPath(for: descriptor)
    )
  }

  private func readPointer(
    _ kind: PointerKind,
    artifactID: String
  ) throws -> InstalledModelPointer {
    guard ManagedModelRegistry.safeComponent(artifactID) else {
      throw ModelManagerError(.unsafePath, code: "model-artifact-id-unsafe")
    }
    let data = try Data(contentsOf: pointerURL(kind, artifactID: artifactID))
    do {
      return try JSONDecoder().decode(InstalledModelPointer.self, from: data)
    } catch {
      throw ModelManagerError(.repairRequired, code: "model-pointer-decode-failed")
    }
  }

  private func writePointer(
    _ pointer: InstalledModelPointer,
    kind: PointerKind
  ) throws {
    let directory = rootDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = pointerURL(kind, artifactID: pointer.artifactID)
    let temporary = directory.appendingPathComponent(
      ".\(pointer.artifactID)-\(UUID().uuidString).tmp"
    )
    defer { try? fileManager.removeItem(at: temporary) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(pointer)
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw ModelManagerError(.fileSystem, code: "model-pointer-create-failed")
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw ModelManagerError(.fileSystem, code: "model-pointer-write-failed")
    }
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw ModelManagerError(.fileSystem, code: "model-pointer-rename-failed")
    }
    try synchronizeDirectory(directory)
  }

  private func pointerURL(_ kind: PointerKind, artifactID: String) -> URL {
    rootDirectory
      .appendingPathComponent(kind.rawValue, isDirectory: true)
      .appendingPathComponent("\(artifactID).json")
  }

  private func stagingURL(for descriptor: ManagedModelArtifact) -> URL {
    rootDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(
        "\(descriptor.id)-\(descriptor.version)-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  private func versionDirectory(for descriptor: ManagedModelArtifact) -> URL {
    rootDirectory.appendingPathComponent(
      relativeVersionPath(for: descriptor),
      isDirectory: true
    )
  }

  private func relativeVersionPath(for descriptor: ManagedModelArtifact) -> String {
    "versions/\(descriptor.id)/\(descriptor.version)"
  }

  private func quarantineURL(for descriptor: ManagedModelArtifact) -> URL {
    rootDirectory
      .appendingPathComponent("quarantine", isDirectory: true)
      .appendingPathComponent(
        "\(descriptor.id)-\(descriptor.version)-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  private func removeStagingDirectory(_ directory: URL) throws {
    let stagingRoot =
      rootDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .standardizedFileURL.path + "/"
    let candidate = directory.standardizedFileURL.path
    guard candidate.hasPrefix(stagingRoot) else {
      throw ModelManagerError(.unsafePath, code: "model-staging-cleanup-unsafe")
    }
    if fileManager.fileExists(atPath: candidate) {
      try fileManager.removeItem(at: directory)
    }
  }

  private func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw ModelManagerError(.fileSystem, code: "model-directory-open-failed")
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw ModelManagerError(.fileSystem, code: "model-directory-sync-failed")
    }
  }
}

extension FileHandle {
  fileprivate func synchronizeAndClose() throws {
    do {
      try synchronize()
      try close()
    } catch {
      try? close()
      throw error
    }
  }
}
