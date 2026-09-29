import BestASRDomain
import CryptoKit
import Foundation

public enum CrossRootTransferError: Error, Equatable, Sendable {
  case assetDigestMismatch
  case assetMissing
  case destinationExists
  case invalidManifest
  case invalidRelationships
  case packageExists
  case symbolicLinkRejected
}

public struct PortableFixtureAsset: Codable, Equatable, Sendable {
  public let reference: PortableAssetReference
  public let packagePath: String
  public let sizeBytes: Int
  public let sha256: BestASRDomain.SHA256Digest
}

public struct PortableFixtureManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let snapshotFile: String
  public let snapshotDigest: BestASRDomain.SHA256Digest
  public let assets: [PortableFixtureAsset]
}

public struct CrossRootRoundTripResult: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let status: String
  public let distinctRoots: Bool
  public let stableUUIDsPreserved: Bool
  public let relationshipsPreserved: Bool
  public let relativeReferencesPreserved: Bool
  public let byteIdenticalAssetCount: Int
  public let absolutePathsRecorded: Int

  public init(
    runID: UUID,
    status: String,
    distinctRoots: Bool,
    stableUUIDsPreserved: Bool,
    relationshipsPreserved: Bool,
    relativeReferencesPreserved: Bool,
    byteIdenticalAssetCount: Int,
    absolutePathsRecorded: Int
  ) {
    schemaVersion = 1
    kind = "cross-root-roundtrip-summary"
    self.runID = runID
    self.status = status
    self.distinctRoots = distinctRoots
    self.stableUUIDsPreserved = stableUUIDsPreserved
    self.relationshipsPreserved = relationshipsPreserved
    self.relativeReferencesPreserved = relativeReferencesPreserved
    self.byteIdenticalAssetCount = byteIdenticalAssetCount
    self.absolutePathsRecorded = absolutePathsRecorded
  }
}

public enum CrossRootFixtureTransfer {
  public static func exportFixture(
    snapshot: DomainSnapshot,
    sourceRoot: URL,
    packageRoot: URL,
    fileManager: FileManager = .default
  ) throws -> PortableFixtureManifest {
    guard !fileManager.fileExists(atPath: packageRoot.path) else {
      throw CrossRootTransferError.packageExists
    }
    try validateRelationships(snapshot)
    try fileManager.createDirectory(
      at: packageRoot,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let snapshotData = try encoder.encode(snapshot)
    let snapshotURL = packageRoot.appendingPathComponent("snapshot.json")
    try snapshotData.write(to: snapshotURL, options: .atomic)

    let references = referencedAssets(snapshot)
      .sorted { packagePath(for: $0) < packagePath(for: $1) }
    var assets: [PortableFixtureAsset] = []
    for reference in references {
      let sourceURL = resolvedURL(for: reference, root: sourceRoot)
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw CrossRootTransferError.assetMissing
      }
      let values = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw CrossRootTransferError.symbolicLinkRejected
      }
      let data = try Data(contentsOf: sourceURL)
      let digest = try BestASRDomain.SHA256Digest(sha256(data))
      if case .contentAddressed(let expectedDigest) = reference {
        guard digest == expectedDigest else {
          throw CrossRootTransferError.assetDigestMismatch
        }
      }

      let relativePackagePath = packagePath(for: reference)
      let packagedURL = packageRoot.appendingPathComponent(relativePackagePath)
      try fileManager.createDirectory(
        at: packagedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: packagedURL, options: .atomic)
      assets.append(
        PortableFixtureAsset(
          reference: reference,
          packagePath: relativePackagePath,
          sizeBytes: data.count,
          sha256: digest
        )
      )
    }

    let manifest = PortableFixtureManifest(
      schemaVersion: 1,
      kind: "cross-root-fixture",
      snapshotFile: "snapshot.json",
      snapshotDigest: try BestASRDomain.SHA256Digest(sha256(snapshotData)),
      assets: assets
    )
    try encoder.encode(manifest)
      .write(
        to: packageRoot.appendingPathComponent("manifest.json"),
        options: .atomic
      )
    return manifest
  }

  public static func importFixture(
    packageRoot: URL,
    destinationRoot: URL,
    fileManager: FileManager = .default
  ) throws -> DomainSnapshot {
    guard !fileManager.fileExists(atPath: destinationRoot.path) else {
      throw CrossRootTransferError.destinationExists
    }
    let decoder = JSONDecoder()
    let manifestURL = packageRoot.appendingPathComponent("manifest.json")
    let manifest = try decoder.decode(
      PortableFixtureManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    guard manifest.schemaVersion == 1,
      manifest.kind == "cross-root-fixture",
      manifest.snapshotFile == "snapshot.json"
    else {
      throw CrossRootTransferError.invalidManifest
    }

    let snapshotURL = packageRoot.appendingPathComponent(manifest.snapshotFile)
    let snapshotData = try Data(contentsOf: snapshotURL)
    guard
      try BestASRDomain.SHA256Digest(sha256(snapshotData))
        == manifest.snapshotDigest
    else {
      throw CrossRootTransferError.assetDigestMismatch
    }
    let snapshot = try decoder.decode(DomainSnapshot.self, from: snapshotData)
    try validateRelationships(snapshot)
    guard Set(manifest.assets.map(\.reference)) == referencedAssets(snapshot) else {
      throw CrossRootTransferError.invalidManifest
    }

    try fileManager.createDirectory(
      at: destinationRoot,
      withIntermediateDirectories: true
    )
    for asset in manifest.assets {
      let expectedPackagePath = packagePath(for: asset.reference)
      guard asset.packagePath == expectedPackagePath else {
        throw CrossRootTransferError.invalidManifest
      }
      let packagedURL = packageRoot.appendingPathComponent(expectedPackagePath)
      let data = try Data(contentsOf: packagedURL)
      guard data.count == asset.sizeBytes,
        try BestASRDomain.SHA256Digest(sha256(data)) == asset.sha256
      else {
        throw CrossRootTransferError.assetDigestMismatch
      }
      let destinationURL = resolvedURL(
        for: asset.reference,
        root: destinationRoot
      )
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destinationURL, options: .atomic)
    }
    return snapshot
  }

  public static func resolvedURL(
    for reference: PortableAssetReference,
    root: URL
  ) -> URL {
    switch reference {
    case .relativePath(let path):
      return root.appendingPathComponent(path)
    case .contentAddressed(let digest):
      return
        root
        .appendingPathComponent("content-addressed", isDirectory: true)
        .appendingPathComponent(String(digest.value.prefix(2)), isDirectory: true)
        .appendingPathComponent(digest.value)
    }
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func packagePath(for reference: PortableAssetReference) -> String {
    switch reference {
    case .relativePath(let path):
      return "assets/relative/\(path)"
    case .contentAddressed(let digest):
      return "assets/content-addressed/\(digest.value)"
    }
  }

  private static func referencedAssets(_ snapshot: DomainSnapshot)
    -> Set<PortableAssetReference>
  {
    Set(
      snapshot.tracks.map(\.assetReference)
        + snapshot.chunks.map(\.assetReference)
        + snapshot.modelArtifacts.map(\.directoryReference)
    )
  }

  private static func validateRelationships(_ snapshot: DomainSnapshot) throws {
    let sessionIDs = Set(snapshot.sessions.map(\.id))
    let trackIDs = Set(snapshot.tracks.map(\.id))
    let speakerIDs = Set(snapshot.sessionSpeakers.map(\.id))
    let personIDs = Set(snapshot.persons.map(\.id))
    let correctionIDs = Set(snapshot.personCorrections.map(\.id))
    let changeIDs = Set(snapshot.changeLog.map(\.id))

    guard snapshot.schemaVersion == 1,
      snapshot.tracks.allSatisfy({ sessionIDs.contains($0.sessionID) }),
      snapshot.chunks.allSatisfy({
        sessionIDs.contains($0.sessionID) && trackIDs.contains($0.trackID)
      }),
      snapshot.timelineEvents.allSatisfy({ sessionIDs.contains($0.sessionID) }),
      snapshot.transcriptRevisions.allSatisfy({ sessionIDs.contains($0.sessionID) }),
      snapshot.sessionSpeakers.allSatisfy({ sessionIDs.contains($0.sessionID) }),
      snapshot.speakerOccurrences.allSatisfy({
        sessionIDs.contains($0.sessionID)
          && speakerIDs.contains($0.sessionSpeakerID)
          && Set($0.trackIDs).isSubset(of: trackIDs)
          && ($0.association.personID.map(personIDs.contains) ?? true)
      }),
      snapshot.changeLog.allSatisfy({
        $0.personCorrection.map { correctionIDs.contains($0.id) } ?? true
      }),
      snapshot.tombstones.allSatisfy({ changeIDs.contains($0.changeID) })
    else {
      throw CrossRootTransferError.invalidRelationships
    }
  }
}
