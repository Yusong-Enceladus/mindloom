import CryptoKit
import Foundation

public struct ModelFileDescriptor: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sizeBytes: Int
  public let sha256: String

  public init(relativePath: String, sizeBytes: Int, sha256: String) {
    self.relativePath = relativePath
    self.sizeBytes = sizeBytes
    self.sha256 = sha256
  }
}

public struct ModelArtifactDescriptor: Codable, Equatable, Sendable {
  public let artifactID: String
  public let version: String
  public let files: [ModelFileDescriptor]

  public init(artifactID: String, version: String, files: [ModelFileDescriptor]) {
    self.artifactID = artifactID
    self.version = version
    self.files = files
  }
}

public enum ModelActivationStatus: String, Codable, Sendable {
  case pass
  case fail
}

public enum ModelActivationFailureCategory: String, Codable, Error, Sendable {
  case digestMismatch
  case downgradeRejected
  case fileSystem
  case healthCheckFailed
  case invalidDescriptor
  case partialDownload
  case sizeMismatch
}

public struct ModelActivationAttempt: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: ModelActivationStatus
  public let artifactID: String
  public let requestedVersion: String
  public let failureCategory: ModelActivationFailureCategory?
  public let previousActiveVersion: String?
  public let activeVersionAfter: String?
  public let lastKnownGoodPreserved: Bool
  public let stagingRemoved: Bool
  public let verifiedFileCount: Int
}

public protocol ModelHealthChecking: Sendable {
  func check(modelDirectory: URL) throws
}

public struct PassingModelHealthCheck: ModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) throws {
    guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
      throw ModelActivationFailureCategory.healthCheckFailed
    }
  }
}

public struct FailingModelHealthCheck: ModelHealthChecking {
  public init() {}

  public func check(modelDirectory _: URL) throws {
    throw ModelActivationFailureCategory.healthCheckFailed
  }
}

private struct ActiveModelPointer: Codable {
  let schemaVersion: Int
  let artifactID: String
  let version: String
  let relativePath: String
}

public struct ModelManagerProbe {
  private let root: URL
  private let fileManager: FileManager

  public init(root: URL, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }

  public func stageVerifyAndActivate(
    descriptor: ModelArtifactDescriptor,
    sourceDirectory: URL,
    healthCheck: any ModelHealthChecking
  ) -> ModelActivationAttempt {
    let previousActiveVersion = try? activeVersion(for: descriptor.artifactID)
    let stagingDirectory =
      root
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(
        "\(descriptor.artifactID)-\(descriptor.version)-\(UUID().uuidString)",
        isDirectory: true
      )
    var verifiedFileCount = 0
    var failureCategory: ModelActivationFailureCategory?

    do {
      try validate(descriptor: descriptor)
      if let previousActiveVersion,
        let requested = ModelSemanticVersion(descriptor.version),
        let current = ModelSemanticVersion(previousActiveVersion),
        requested <= current
      {
        throw ModelActivationFailureCategory.downgradeRejected
      }
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )

      for file in descriptor.files {
        let source = sourceDirectory.appendingPathComponent(file.relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
          throw ModelActivationFailureCategory.partialDownload
        }
        let destination = stagingDirectory.appendingPathComponent(file.relativePath)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        try verify(file: destination, descriptor: file)
        verifiedFileCount += 1
      }

      do {
        try healthCheck.check(modelDirectory: stagingDirectory)
      } catch {
        throw ModelActivationFailureCategory.healthCheckFailed
      }

      let versionDirectory =
        root
        .appendingPathComponent("versions", isDirectory: true)
        .appendingPathComponent(descriptor.artifactID, isDirectory: true)
        .appendingPathComponent(descriptor.version, isDirectory: true)
      try fileManager.createDirectory(
        at: versionDirectory.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard !fileManager.fileExists(atPath: versionDirectory.path) else {
        throw ModelActivationFailureCategory.fileSystem
      }
      try fileManager.moveItem(at: stagingDirectory, to: versionDirectory)
      do {
        try writeActivePointer(
          artifactID: descriptor.artifactID,
          version: descriptor.version,
          versionDirectory: versionDirectory
        )
      } catch {
        try? fileManager.removeItem(at: versionDirectory)
        throw error
      }
    } catch let category as ModelActivationFailureCategory {
      failureCategory = category
    } catch {
      failureCategory = .fileSystem
    }

    if fileManager.fileExists(atPath: stagingDirectory.path) {
      try? fileManager.removeItem(at: stagingDirectory)
    }

    let activeVersionAfter = try? activeVersion(for: descriptor.artifactID)
    let stagingRemoved = !fileManager.fileExists(atPath: stagingDirectory.path)
    let succeeded = failureCategory == nil
    return ModelActivationAttempt(
      schemaVersion: 1,
      status: succeeded ? .pass : .fail,
      artifactID: descriptor.artifactID,
      requestedVersion: descriptor.version,
      failureCategory: failureCategory,
      previousActiveVersion: previousActiveVersion,
      activeVersionAfter: activeVersionAfter,
      lastKnownGoodPreserved: succeeded
        || previousActiveVersion == activeVersionAfter,
      stagingRemoved: stagingRemoved,
      verifiedFileCount: verifiedFileCount
    )
  }

  public func activeVersion(for artifactID: String) throws -> String? {
    let pointerURL = activePointerURL(for: artifactID)
    guard fileManager.fileExists(atPath: pointerURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: pointerURL)
    return try JSONDecoder().decode(ActiveModelPointer.self, from: data).version
  }

  public static func sha256(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer {
      try? handle.close()
    }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func validate(descriptor: ModelArtifactDescriptor) throws {
    guard isSafeComponent(descriptor.artifactID),
      isSafeComponent(descriptor.version),
      ModelSemanticVersion(descriptor.version) != nil,
      !descriptor.files.isEmpty
    else {
      throw ModelActivationFailureCategory.invalidDescriptor
    }
    var paths = Set<String>()
    for file in descriptor.files {
      let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
      guard !file.relativePath.hasPrefix("/"),
        !components.isEmpty,
        components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        file.sizeBytes >= 0,
        file.sha256.range(
          of: "^[0-9a-f]{64}$",
          options: .regularExpression
        ) != nil,
        paths.insert(file.relativePath).inserted
      else {
        throw ModelActivationFailureCategory.invalidDescriptor
      }
    }
  }

  private func verify(file: URL, descriptor: ModelFileDescriptor) throws {
    let attributes = try fileManager.attributesOfItem(atPath: file.path)
    let actualSize = (attributes[.size] as? NSNumber)?.intValue
    guard actualSize == descriptor.sizeBytes else {
      throw ModelActivationFailureCategory.sizeMismatch
    }
    guard try Self.sha256(of: file) == descriptor.sha256 else {
      throw ModelActivationFailureCategory.digestMismatch
    }
  }

  private func writeActivePointer(
    artifactID: String,
    version: String,
    versionDirectory: URL
  ) throws {
    let pointerDirectory = root.appendingPathComponent("active", isDirectory: true)
    try fileManager.createDirectory(
      at: pointerDirectory,
      withIntermediateDirectories: true
    )
    let pointerURL = activePointerURL(for: artifactID)
    let temporaryPointer =
      pointerDirectory
      .appendingPathComponent(".\(artifactID)-\(UUID().uuidString).tmp")
    defer {
      if fileManager.fileExists(atPath: temporaryPointer.path) {
        try? fileManager.removeItem(at: temporaryPointer)
      }
    }
    let relativePath = versionDirectory.path.replacingOccurrences(
      of: root.path + "/",
      with: ""
    )
    let pointer = ActiveModelPointer(
      schemaVersion: 1,
      artifactID: artifactID,
      version: version,
      relativePath: relativePath
    )
    try JSONEncoder().encode(pointer).write(to: temporaryPointer, options: .atomic)

    if fileManager.fileExists(atPath: pointerURL.path) {
      _ = try fileManager.replaceItemAt(
        pointerURL,
        withItemAt: temporaryPointer,
        backupItemName: nil,
        options: .usingNewMetadataOnly
      )
    } else {
      try fileManager.moveItem(at: temporaryPointer, to: pointerURL)
    }
  }

  private func activePointerURL(for artifactID: String) -> URL {
    root
      .appendingPathComponent("active", isDirectory: true)
      .appendingPathComponent("\(artifactID).json")
  }

  private func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value.count <= 128
      && value.range(
        of: "^[A-Za-z0-9._-]+$",
        options: .regularExpression
      ) != nil
  }
}

private struct ModelSemanticVersion: Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ value: String) {
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 3,
      let major = Int(pieces[0]),
      let minor = Int(pieces[1]),
      let patch = Int(pieces[2]),
      major >= 0,
      minor >= 0,
      patch >= 0
    else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public struct ModelActivationProbeScenario: Codable, Equatable, Sendable {
  public let name: String
  public let result: ModelActivationStatus
  public let expectedFailureCategory: ModelActivationFailureCategory?
  public let attempt: ModelActivationAttempt

  public init(
    name: String,
    result: ModelActivationStatus,
    expectedFailureCategory: ModelActivationFailureCategory?,
    attempt: ModelActivationAttempt
  ) {
    self.name = name
    self.result = result
    self.expectedFailureCategory = expectedFailureCategory
    self.attempt = attempt
  }
}

public struct ModelActivationProbeReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let status: ModelActivationStatus
  public let scenarios: [ModelActivationProbeScenario]

  public init(runID: UUID, scenarios: [ModelActivationProbeScenario]) {
    self.schemaVersion = 1
    self.kind = "model-activation-summary"
    self.runID = runID
    self.scenarios = scenarios
    self.status = scenarios.allSatisfy { $0.result == .pass } ? .pass : .fail
  }
}
