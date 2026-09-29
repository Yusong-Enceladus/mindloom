import Foundation

public enum CorpusTier: String, Codable, Sendable {
  case adversarial
  case deviceLab = "device-lab"
  case privateConsented = "private-consented"
  case productSynthetic = "product-synthetic"
  case `public`
  case releaseHoldout = "release-holdout"
}

public struct CorpusSampleManifest: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let consentClass: String
  public let assetReference: String
  public let contentDigest: String
  public let languages: [String]
  public let tags: [String]

  public init(
    sampleUUID: UUID,
    consentClass: String,
    assetReference: String,
    contentDigest: String,
    languages: [String],
    tags: [String]
  ) {
    self.sampleUUID = sampleUUID
    self.consentClass = consentClass
    self.assetReference = assetReference
    self.contentDigest = contentDigest
    self.languages = languages
    self.tags = tags
  }
}

public struct CorpusManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let manifestID: String
  public let version: String
  public let tier: CorpusTier
  public let releaseHoldout: Bool
  public let containsPrivateContent: Bool
  public let samples: [CorpusSampleManifest]

  public init(
    schemaVersion: Int = 1,
    kind: String = "corpus-manifest",
    manifestID: String,
    version: String,
    tier: CorpusTier,
    releaseHoldout: Bool,
    containsPrivateContent: Bool,
    samples: [CorpusSampleManifest]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.manifestID = manifestID
    self.version = version
    self.tier = tier
    self.releaseHoldout = releaseHoldout
    self.containsPrivateContent = containsPrivateContent
    self.samples = samples
  }
}

public enum CorpusAccessMode: String, Codable, Sendable {
  case releaseEvaluation = "release-evaluation"
  case smoke
  case tuning
}

public enum CorpusIsolationError: Error, Equatable, Sendable {
  case inaccessibleRoot
  case invalidManifest
  case logicalHoldoutViolation
  case rootsNotSeparated
  case unauthorizedPath
}

public struct IsolatedCorpusStore: Sendable {
  private let tuningRoot: URL
  private let releaseHoldoutRoot: URL

  public init(tuningRoot: URL, releaseHoldoutRoot: URL) throws {
    let resolvedTuning = tuningRoot.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedRelease = releaseHoldoutRoot.standardizedFileURL.resolvingSymlinksInPath()
    guard resolvedTuning.isFileURL, resolvedRelease.isFileURL else {
      throw CorpusIsolationError.inaccessibleRoot
    }
    guard
      resolvedTuning != resolvedRelease,
      !Self.isDescendant(resolvedTuning, of: resolvedRelease),
      !Self.isDescendant(resolvedRelease, of: resolvedTuning)
    else {
      throw CorpusIsolationError.rootsNotSeparated
    }
    self.tuningRoot = resolvedTuning
    self.releaseHoldoutRoot = resolvedRelease
  }

  /// Validates the authorized physical root before reading bytes, then validates
  /// the manifest's logical split. This prevents a tuning run from learning even
  /// the contents of a holdout manifest through path traversal or a symlink.
  public func loadManifest(
    at url: URL,
    mode: CorpusAccessMode
  ) throws -> CorpusManifest {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let authorizedRoot =
      mode == .releaseEvaluation
      ? releaseHoldoutRoot
      : tuningRoot
    guard Self.isDescendant(resolvedURL, of: authorizedRoot) else {
      throw CorpusIsolationError.unauthorizedPath
    }

    let data = try Data(contentsOf: resolvedURL)
    let manifest = try JSONDecoder().decode(CorpusManifest.self, from: data)
    guard manifest.schemaVersion == 1,
      manifest.kind == "corpus-manifest",
      !manifest.manifestID.isEmpty,
      !manifest.samples.isEmpty
    else {
      throw CorpusIsolationError.invalidManifest
    }

    switch mode {
    case .releaseEvaluation:
      guard manifest.releaseHoldout, manifest.tier == .releaseHoldout else {
        throw CorpusIsolationError.logicalHoldoutViolation
      }
    case .smoke:
      guard !manifest.releaseHoldout,
        manifest.tier != .releaseHoldout,
        manifest.tier != .privateConsented
      else {
        throw CorpusIsolationError.logicalHoldoutViolation
      }
    case .tuning:
      guard !manifest.releaseHoldout, manifest.tier != .releaseHoldout else {
        throw CorpusIsolationError.logicalHoldoutViolation
      }
    }
    return manifest
  }

  private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let candidatePath = candidate.path
    let rootPath = root.path
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
  }
}
