import BestASRDomain
import BestASRSecurityEnvelopeProbe
import CryptoKit
import Foundation

public enum PortableArchiveStore {
  public static let defaultKDFIterations: UInt32 = 100_000

  public static func export(
    payload: PortableArchivePayload,
    secret: PortableArchiveSecret,
    to destination: URL,
    kdfIterations: UInt32 = defaultKDFIterations,
    fault: PortableArchiveExportFault = .none,
    fileManager: FileManager = .default
  ) throws -> UUID {
    guard payload.schemaVersion == 1 else {
      throw PortableArchiveError.unsupportedVersion
    }
    try validate(payload)
    let encoder = canonicalEncoder()
    return try exportPayloadData(
      encoder.encode(payload),
      secret: secret,
      to: destination,
      kdfIterations: kdfIterations,
      fault: fault,
      fileManager: fileManager
    )
  }

  public static func exportLegacyV0(
    snapshot: DomainSnapshot,
    assets: [PortableArchiveAsset],
    dictionaries: [PortableDictionaryEntry],
    secret: PortableArchiveSecret,
    to destination: URL,
    kdfIterations: UInt32 = defaultKDFIterations,
    fileManager: FileManager = .default
  ) throws -> UUID {
    let migratedView = PortableArchivePayload(
      snapshot: snapshot,
      assets: assets,
      dictionaries: dictionaries,
      derivedDocuments: [],
      settings: []
    )
    try validate(migratedView)
    let legacy = PortableArchivePayloadV0(
      schemaVersion: 0,
      snapshot: snapshot,
      assets: assets,
      dictionaries: dictionaries
    )
    return try exportPayloadData(
      canonicalEncoder().encode(legacy),
      secret: secret,
      to: destination,
      kdfIterations: kdfIterations,
      fault: .none,
      fileManager: fileManager
    )
  }

  public static func importArchive(
    at archiveURL: URL,
    secret: PortableArchiveSecret,
    destinationRoot: URL,
    destinationMasterKey: SymmetricKey,
    availableBytes: Int64 = .max,
    fault: PortableArchiveImportFault = .none,
    fileManager: FileManager = .default
  ) throws -> PortableArchiveImportResult {
    let archiveData = try Data(contentsOf: archiveURL)
    let container: PortableArchiveContainer
    do {
      container = try JSONDecoder().decode(
        PortableArchiveContainer.self,
        from: archiveData
      )
    } catch {
      throw PortableArchiveError.invalidArchive
    }
    guard container.schemaVersion == 1,
      container.kind == "bestasr-portable-archive",
      container.kdf.algorithm == "PBKDF2-HMAC-SHA256",
      container.kdf.iterations > 0,
      container.kdf.salt.count >= 16,
      container.envelope.keyIdentifier == container.archiveID
    else {
      throw PortableArchiveError.unsupportedVersion
    }

    let wrappingKeyData = try PortableSecretKDF.deriveKeyData(
      secret: secret.bytes,
      salt: container.kdf.salt,
      iterations: container.kdf.iterations
    )
    let payloadData: Data
    do {
      payloadData = try EnvelopeCrypto.decrypt(
        container.envelope,
        masterKey: try EnvelopeCrypto.key(from: wrappingKeyData)
      )
    } catch {
      throw PortableArchiveError.authenticationFailed
    }
    let decoded = try decodePayload(payloadData)
    try validate(decoded.payload)
    let requiredBytes = Int64(payloadData.count + archiveData.count)
    guard availableBytes >= requiredBytes else {
      throw PortableArchiveError.insufficientSpace
    }

    let importsRoot = destinationRoot.appendingPathComponent(
      "imports",
      isDirectory: true
    )
    let finalRoot = importsRoot.appendingPathComponent(
      container.archiveID.uuidString,
      isDirectory: true
    )
    let receiptURL = finalRoot.appendingPathComponent("receipt.json")
    if fileManager.fileExists(atPath: finalRoot.path) {
      let receipt = try JSONDecoder().decode(
        PortableArchiveReceipt.self,
        from: Data(contentsOf: receiptURL)
      )
      guard receipt.archiveID == container.archiveID else {
        throw PortableArchiveError.destinationConflict
      }
      return PortableArchiveImportResult(
        outcome: .alreadyImported,
        archiveID: container.archiveID,
        payload: decoded.payload,
        destination: finalRoot,
        migratedFromSchemaVersion: decoded.migratedFrom
      )
    }

    try fileManager.createDirectory(
      at: importsRoot,
      withIntermediateDirectories: true
    )
    let stagingRoot = importsRoot.appendingPathComponent(
      ".import-\(container.archiveID.uuidString).staging",
      isDirectory: true
    )
    if fileManager.fileExists(atPath: stagingRoot.path) {
      try fileManager.removeItem(at: stagingRoot)
    }
    try fileManager.createDirectory(
      at: stagingRoot,
      withIntermediateDirectories: true
    )

    do {
      let metadataEnvelope = try EnvelopeCrypto.encrypt(
        payloadData,
        masterKey: destinationMasterKey,
        purpose: .databaseBackup,
        keyIdentifier: container.archiveID
      )
      try AtomicEnvelopeFile.commit(
        metadataEnvelope,
        to: stagingRoot.appendingPathComponent("metadata.envelope")
      )
      switch fault {
      case .cancelledAfterFirstEncryptedWrite:
        throw PortableArchiveError.cancelled
      case .simulatedKillAfterFirstEncryptedWrite:
        throw PortableArchiveError.simulatedProcessKill
      case .none:
        break
      }

      for (index, asset) in decoded.payload.assets.enumerated() {
        let assetEnvelope = try EnvelopeCrypto.encrypt(
          asset.bytes,
          masterKey: destinationMasterKey,
          purpose: .asset
        )
        try AtomicEnvelopeFile.commit(
          assetEnvelope,
          to: stagingRoot.appendingPathComponent(
            String(format: "asset-%04d.envelope", index)
          )
        )
      }
      let receipt = PortableArchiveReceipt(
        schemaVersion: 1,
        archiveID: container.archiveID,
        payloadDigest: try digest(payloadData),
        assetCount: decoded.payload.assets.count
      )
      try canonicalEncoder().encode(receipt).write(
        to: stagingRoot.appendingPathComponent("receipt.json"),
        options: .withoutOverwriting
      )
      try fileManager.moveItem(at: stagingRoot, to: finalRoot)
    } catch PortableArchiveError.simulatedProcessKill {
      throw PortableArchiveError.simulatedProcessKill
    } catch {
      try? fileManager.removeItem(at: stagingRoot)
      throw error
    }

    return PortableArchiveImportResult(
      outcome: .imported,
      archiveID: container.archiveID,
      payload: decoded.payload,
      destination: finalRoot,
      migratedFromSchemaVersion: decoded.migratedFrom
    )
  }

  public static func recoverImportStaging(
    destinationRoot: URL,
    fileManager: FileManager = .default
  ) throws -> Int {
    let importsRoot = destinationRoot.appendingPathComponent(
      "imports",
      isDirectory: true
    )
    guard fileManager.fileExists(atPath: importsRoot.path) else { return 0 }
    let children = try fileManager.contentsOfDirectory(
      at: importsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    )
    var removed = 0
    for child in children where child.lastPathComponent.hasSuffix(".staging") {
      guard child.lastPathComponent.hasPrefix(".import-") else { continue }
      try fileManager.removeItem(at: child)
      removed += 1
    }
    return removed
  }

  public static func recoverExportStaging(
    in directory: URL,
    fileManager: FileManager = .default
  ) throws -> Int {
    guard fileManager.fileExists(atPath: directory.path) else { return 0 }
    let children = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )
    var removed = 0
    for child in children
    where child.lastPathComponent.hasPrefix(".")
      && child.lastPathComponent.hasSuffix(".bestasrarchive-staging")
    {
      try fileManager.removeItem(at: child)
      removed += 1
    }
    return removed
  }

  private static func exportPayloadData(
    _ payloadData: Data,
    secret: PortableArchiveSecret,
    to destination: URL,
    kdfIterations: UInt32,
    fault: PortableArchiveExportFault,
    fileManager: FileManager
  ) throws -> UUID {
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw PortableArchiveError.archiveExists
    }
    if fault == .insufficientSpace {
      throw PortableArchiveError.insufficientSpace
    }
    let archiveID = UUID()
    let salt = randomData(count: 16)
    let kdf = PortableArchiveKDFParameters(
      iterations: kdfIterations,
      salt: salt
    )
    let wrappingKeyData = try PortableSecretKDF.deriveKeyData(
      secret: secret.bytes,
      salt: salt,
      iterations: kdfIterations
    )
    let envelope = try EnvelopeCrypto.encrypt(
      payloadData,
      masterKey: try EnvelopeCrypto.key(from: wrappingKeyData),
      purpose: .databaseBackup,
      keyIdentifier: archiveID
    )
    let container = PortableArchiveContainer(
      archiveID: archiveID,
      kdf: kdf,
      envelope: envelope
    )
    let containerData = try canonicalEncoder().encode(container)
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let staging = parent.appendingPathComponent(
      ".\(archiveID.uuidString).bestasrarchive-staging"
    )
    try containerData.write(
      to: staging,
      options: Data.WritingOptions.withoutOverwriting
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: staging.path
    )
    switch fault {
    case .cancelled:
      try fileManager.removeItem(at: staging)
      throw PortableArchiveError.cancelled
    case .simulatedProcessKill:
      throw PortableArchiveError.simulatedProcessKill
    case .insufficientSpace:
      throw PortableArchiveError.insufficientSpace
    case .none:
      try fileManager.moveItem(at: staging, to: destination)
      return archiveID
    }
  }

  private static func decodePayload(_ data: Data) throws
    -> (payload: PortableArchivePayload, migratedFrom: Int?)
  {
    let object: [String: Any]
    do {
      object =
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
        ?? [:]
    } catch {
      throw PortableArchiveError.invalidArchive
    }
    guard let version = object["schemaVersion"] as? NSNumber else {
      throw PortableArchiveError.invalidArchive
    }
    switch version.intValue {
    case 0:
      let legacy = try JSONDecoder().decode(
        PortableArchivePayloadV0.self,
        from: data
      )
      return (
        PortableArchivePayload(
          snapshot: legacy.snapshot,
          assets: legacy.assets,
          dictionaries: legacy.dictionaries,
          derivedDocuments: [],
          settings: []
        ),
        0
      )
    case 1:
      return (
        try JSONDecoder().decode(PortableArchivePayload.self, from: data),
        nil
      )
    default:
      throw PortableArchiveError.unsupportedVersion
    }
  }

  private static func validate(_ payload: PortableArchivePayload) throws {
    let sessionIDs = Set(payload.snapshot.sessions.map(\.id))
    let trackIDs = Set(payload.snapshot.tracks.map(\.id))
    let speakerIDs = Set(payload.snapshot.sessionSpeakers.map(\.id))
    let personIDs = Set(payload.snapshot.persons.map(\.id))
    let correctionIDs = Set(payload.snapshot.personCorrections.map(\.id))
    let changeIDs = Set(payload.snapshot.changeLog.map(\.id))
    guard payload.snapshot.schemaVersion == 1,
      payload.snapshot.tracks.allSatisfy({ sessionIDs.contains($0.sessionID) }),
      payload.snapshot.chunks.allSatisfy({
        sessionIDs.contains($0.sessionID) && trackIDs.contains($0.trackID)
      }),
      payload.snapshot.speakerOccurrences.allSatisfy({
        sessionIDs.contains($0.sessionID)
          && speakerIDs.contains($0.sessionSpeakerID)
          && Set($0.trackIDs).isSubset(of: trackIDs)
          && ($0.association.personID.map(personIDs.contains) ?? true)
      }),
      payload.snapshot.changeLog.allSatisfy({
        $0.personCorrection.map { correctionIDs.contains($0.id) } ?? true
      }),
      payload.snapshot.tombstones.allSatisfy({ changeIDs.contains($0.changeID) })
    else {
      throw PortableArchiveError.invalidAssetRelationships
    }

    let requiredReferences = Set(
      payload.snapshot.tracks.map(\.assetReference)
        + payload.snapshot.chunks.map(\.assetReference)
    )
    let actualReferences = Set(payload.assets.map(\.reference))
    guard actualReferences == requiredReferences,
      actualReferences.count == payload.assets.count
    else {
      throw PortableArchiveError.invalidAssetRelationships
    }
    for asset in payload.assets {
      guard try digest(asset.bytes) == asset.contentDigest else {
        throw PortableArchiveError.invalidAssetDigest
      }
    }
  }

  private static func digest(_ data: Data) throws
    -> BestASRDomain.SHA256Digest
  {
    try BestASRDomain.SHA256Digest(
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }

  private static func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func randomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}
