import CryptoKit
import Foundation

public struct AppUpdateManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let version: String
  public let minimumOS: String
  public let packageSizeBytes: Int
  public let packageSHA256: String
  public let signingKeyID: String
  public let signatureBase64: String

  public init(
    schemaVersion: Int = 1,
    version: String,
    minimumOS: String,
    packageSizeBytes: Int,
    packageSHA256: String,
    signingKeyID: String,
    signatureBase64: String
  ) {
    self.schemaVersion = schemaVersion
    self.version = version
    self.minimumOS = minimumOS
    self.packageSizeBytes = packageSizeBytes
    self.packageSHA256 = packageSHA256
    self.signingKeyID = signingKeyID
    self.signatureBase64 = signatureBase64
  }

  public var signingPayload: Data {
    Data(
      [
        "bestasr-app-update-v1",
        String(schemaVersion),
        version,
        minimumOS,
        String(packageSizeBytes),
        packageSHA256,
        signingKeyID,
      ].joined(separator: "\n").utf8
    )
  }

  public func replacingSignature(_ signatureBase64: String) -> Self {
    Self(
      schemaVersion: schemaVersion,
      version: version,
      minimumOS: minimumOS,
      packageSizeBytes: packageSizeBytes,
      packageSHA256: packageSHA256,
      signingKeyID: signingKeyID,
      signatureBase64: signatureBase64
    )
  }
}

public enum AppUpdateFailureCategory: String, Codable, Error, Sendable {
  case digestMismatch
  case downgradeRejected
  case fileSystem
  case healthCheckFailed
  case incompatibleOS
  case interruptedDownload
  case invalidManifest
  case signatureMismatch
  case sizeMismatch
  case unknownSigningKey
}

public enum AppUpdateFaultPoint: String, Codable, Sendable {
  case afterPartialStaging
  case none
}

public enum AppUpdateStatus: String, Codable, Sendable {
  case fail
  case pass
}

public struct AppUpdateAttempt: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: AppUpdateStatus
  public let requestedVersion: String
  public let previousActiveVersion: String?
  public let activeVersionAfter: String?
  public let failureCategory: AppUpdateFailureCategory?
  public let signatureVerified: Bool
  public let packageVerified: Bool
  public let lastKnownGoodPreserved: Bool
  public let stagingRemoved: Bool

  public init(
    status: AppUpdateStatus,
    requestedVersion: String,
    previousActiveVersion: String?,
    activeVersionAfter: String?,
    failureCategory: AppUpdateFailureCategory?,
    signatureVerified: Bool,
    packageVerified: Bool,
    lastKnownGoodPreserved: Bool,
    stagingRemoved: Bool
  ) {
    schemaVersion = 1
    self.status = status
    self.requestedVersion = requestedVersion
    self.previousActiveVersion = previousActiveVersion
    self.activeVersionAfter = activeVersionAfter
    self.failureCategory = failureCategory
    self.signatureVerified = signatureVerified
    self.packageVerified = packageVerified
    self.lastKnownGoodPreserved = lastKnownGoodPreserved
    self.stagingRemoved = stagingRemoved
  }
}

public protocol AppUpdateHealthChecking: Sendable {
  func check(packageURL: URL) throws
}

public struct PassingAppUpdateHealthCheck: AppUpdateHealthChecking {
  public init() {}

  public func check(packageURL: URL) throws {
    guard FileManager.default.fileExists(atPath: packageURL.path) else {
      throw AppUpdateFailureCategory.healthCheckFailed
    }
  }
}

public struct FailingAppUpdateHealthCheck: AppUpdateHealthChecking {
  public init() {}

  public func check(packageURL _: URL) throws {
    throw AppUpdateFailureCategory.healthCheckFailed
  }
}

private struct ActiveAppPointer: Codable {
  let schemaVersion: Int
  let version: String
  let relativePath: String
  let packageSHA256: String
}

public struct AppUpdateManager {
  private let root: URL
  private let trustedSigningKeys: [String: Data]
  private let supportedOS: String
  private let fileManager: FileManager

  public init(
    root: URL,
    trustedSigningKeys: [String: Data],
    supportedOS: String = "14.2.0",
    fileManager: FileManager = .default
  ) {
    self.root = root
    self.trustedSigningKeys = trustedSigningKeys
    self.supportedOS = supportedOS
    self.fileManager = fileManager
  }

  public func stageVerifyAndActivate(
    manifest: AppUpdateManifest,
    packageURL: URL,
    faultPoint: AppUpdateFaultPoint = .none,
    healthCheck: any AppUpdateHealthChecking = PassingAppUpdateHealthCheck()
  ) -> AppUpdateAttempt {
    let previousActiveVersion = try? activeVersion()
    let stagingDirectory =
      root
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(
        "app-\(manifest.version)-\(UUID().uuidString)",
        isDirectory: true
      )
    let stagedPackage = stagingDirectory.appendingPathComponent("bestASR.pkg")
    var failureCategory: AppUpdateFailureCategory?
    var signatureVerified = false
    var packageVerified = false

    do {
      try validate(manifest: manifest, currentVersion: previousActiveVersion)
      guard let publicKeyBytes = trustedSigningKeys[manifest.signingKeyID] else {
        throw AppUpdateFailureCategory.unknownSigningKey
      }
      let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyBytes
      )
      guard let signature = Data(base64Encoded: manifest.signatureBase64),
        publicKey.isValidSignature(signature, for: manifest.signingPayload)
      else {
        throw AppUpdateFailureCategory.signatureMismatch
      }
      signatureVerified = true

      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )
      guard fileManager.fileExists(atPath: packageURL.path) else {
        throw AppUpdateFailureCategory.interruptedDownload
      }
      if faultPoint == .afterPartialStaging {
        let source = try Data(contentsOf: packageURL)
        try Data(source.prefix(max(1, source.count / 2))).write(to: stagedPackage)
        throw AppUpdateFailureCategory.interruptedDownload
      }
      try fileManager.copyItem(at: packageURL, to: stagedPackage)
      try verifyPackage(at: stagedPackage, manifest: manifest)
      packageVerified = true

      do {
        try healthCheck.check(packageURL: stagedPackage)
      } catch {
        throw AppUpdateFailureCategory.healthCheckFailed
      }

      let versionDirectory =
        root
        .appendingPathComponent("versions", isDirectory: true)
        .appendingPathComponent(manifest.version, isDirectory: true)
      try fileManager.createDirectory(
        at: versionDirectory.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard !fileManager.fileExists(atPath: versionDirectory.path) else {
        throw AppUpdateFailureCategory.fileSystem
      }
      try fileManager.moveItem(at: stagingDirectory, to: versionDirectory)
      do {
        try writeActivePointer(
          manifest: manifest,
          versionDirectory: versionDirectory
        )
      } catch {
        try? fileManager.removeItem(at: versionDirectory)
        throw error
      }
    } catch let category as AppUpdateFailureCategory {
      failureCategory = category
    } catch {
      failureCategory = .fileSystem
    }

    if fileManager.fileExists(atPath: stagingDirectory.path) {
      try? fileManager.removeItem(at: stagingDirectory)
    }
    let activeVersionAfter = try? activeVersion()
    let succeeded = failureCategory == nil
    return AppUpdateAttempt(
      status: succeeded ? .pass : .fail,
      requestedVersion: manifest.version,
      previousActiveVersion: previousActiveVersion,
      activeVersionAfter: activeVersionAfter,
      failureCategory: failureCategory,
      signatureVerified: signatureVerified,
      packageVerified: packageVerified,
      lastKnownGoodPreserved: succeeded
        || activeVersionAfter == previousActiveVersion,
      stagingRemoved: !fileManager.fileExists(atPath: stagingDirectory.path)
    )
  }

  public func activeVersion() throws -> String? {
    let pointerURL = activePointerURL
    guard fileManager.fileExists(atPath: pointerURL.path) else {
      return nil
    }
    return try JSONDecoder().decode(
      ActiveAppPointer.self,
      from: Data(contentsOf: pointerURL)
    ).version
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256(of url: URL) throws -> String {
    sha256(try Data(contentsOf: url))
  }

  private func validate(
    manifest: AppUpdateManifest,
    currentVersion: String?
  ) throws {
    guard manifest.schemaVersion == 1,
      SemanticVersion(manifest.version) != nil,
      let minimumOS = SemanticVersion(normalizing: manifest.minimumOS),
      let hostOS = SemanticVersion(normalizing: supportedOS),
      manifest.packageSizeBytes > 0,
      manifest.packageSHA256.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil,
      isSafeComponent(manifest.signingKeyID),
      Data(base64Encoded: manifest.signatureBase64) != nil
    else {
      throw AppUpdateFailureCategory.invalidManifest
    }
    guard minimumOS <= hostOS else {
      throw AppUpdateFailureCategory.incompatibleOS
    }
    if let currentVersion,
      let requested = SemanticVersion(manifest.version),
      let current = SemanticVersion(currentVersion),
      requested <= current
    {
      throw AppUpdateFailureCategory.downgradeRejected
    }
  }

  private func verifyPackage(
    at packageURL: URL,
    manifest: AppUpdateManifest
  ) throws {
    let attributes = try fileManager.attributesOfItem(atPath: packageURL.path)
    let actualSize = (attributes[.size] as? NSNumber)?.intValue
    guard actualSize == manifest.packageSizeBytes else {
      throw AppUpdateFailureCategory.sizeMismatch
    }
    guard try Self.sha256(of: packageURL) == manifest.packageSHA256 else {
      throw AppUpdateFailureCategory.digestMismatch
    }
  }

  private func writeActivePointer(
    manifest: AppUpdateManifest,
    versionDirectory: URL
  ) throws {
    try fileManager.createDirectory(
      at: activePointerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = activePointerURL.deletingLastPathComponent()
      .appendingPathComponent(".app-\(UUID().uuidString).tmp")
    defer {
      if fileManager.fileExists(atPath: temporary.path) {
        try? fileManager.removeItem(at: temporary)
      }
    }
    let pointer = ActiveAppPointer(
      schemaVersion: 1,
      version: manifest.version,
      relativePath: versionDirectory.path.replacingOccurrences(
        of: root.path + "/",
        with: ""
      ),
      packageSHA256: manifest.packageSHA256
    )
    try JSONEncoder().encode(pointer).write(to: temporary, options: .atomic)
    if fileManager.fileExists(atPath: activePointerURL.path) {
      _ = try fileManager.replaceItemAt(
        activePointerURL,
        withItemAt: temporary,
        backupItemName: nil,
        options: .usingNewMetadataOnly
      )
    } else {
      try fileManager.moveItem(at: temporary, to: activePointerURL)
    }
  }

  private var activePointerURL: URL {
    root
      .appendingPathComponent("active", isDirectory: true)
      .appendingPathComponent("app.json")
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

private struct SemanticVersion: Comparable {
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

  init?(normalizing value: String) {
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    if pieces.count == 2 {
      self.init(value + ".0")
    } else {
      self.init(value)
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
