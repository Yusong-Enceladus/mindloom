import BestASRDomain
import BestASRSecurityEnvelopeProbe
import Foundation

public enum PortableArchiveError: Error, Equatable, Sendable {
  case archiveExists
  case authenticationFailed
  case cancelled
  case destinationConflict
  case insufficientSpace
  case invalidArchive
  case invalidAssetDigest
  case invalidAssetRelationships
  case invalidSecret
  case simulatedProcessKill
  case unsupportedVersion
}

public struct PortableArchiveSecret: Sendable {
  let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count >= 16 else {
      throw PortableArchiveError.invalidSecret
    }
    self.bytes = bytes
  }
}

public enum ArchiveAudioOrigin: String, Codable, Sendable {
  case importedOriginal
  case nativeCapture
}

public struct PortableArchiveAsset: Codable, Equatable, Sendable {
  public let reference: PortableAssetReference
  public let origin: ArchiveAudioOrigin
  public let contentDigest: BestASRDomain.SHA256Digest
  public let bytes: Data

  public init(
    reference: PortableAssetReference,
    origin: ArchiveAudioOrigin,
    contentDigest: BestASRDomain.SHA256Digest,
    bytes: Data
  ) {
    self.reference = reference
    self.origin = origin
    self.contentDigest = contentDigest
    self.bytes = bytes
  }
}

public struct PortableDictionaryEntry: Codable, Equatable, Sendable {
  public let id: UUID
  public let revision: Revision
  public let spokenForm: String
  public let canonicalForm: String

  public init(
    id: UUID,
    revision: Revision,
    spokenForm: String,
    canonicalForm: String
  ) {
    self.id = id
    self.revision = revision
    self.spokenForm = spokenForm
    self.canonicalForm = canonicalForm
  }
}

public struct PortableSetting: Codable, Equatable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct PortableArchivePayload: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let snapshot: DomainSnapshot
  public let assets: [PortableArchiveAsset]
  public let dictionaries: [PortableDictionaryEntry]
  public let derivedDocuments: [DerivedDocument]
  public let settings: [PortableSetting]

  public init(
    schemaVersion: Int = 1,
    snapshot: DomainSnapshot,
    assets: [PortableArchiveAsset],
    dictionaries: [PortableDictionaryEntry],
    derivedDocuments: [DerivedDocument],
    settings: [PortableSetting]
  ) {
    self.schemaVersion = schemaVersion
    self.snapshot = snapshot
    self.assets = assets
    self.dictionaries = dictionaries
    self.derivedDocuments = derivedDocuments
    self.settings = settings
  }
}

struct PortableArchivePayloadV0: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let snapshot: DomainSnapshot
  let assets: [PortableArchiveAsset]
  let dictionaries: [PortableDictionaryEntry]
}

public struct PortableArchiveKDFParameters: Codable, Equatable, Sendable {
  public let algorithm: String
  public let iterations: UInt32
  public let salt: Data

  public init(iterations: UInt32, salt: Data) {
    algorithm = "PBKDF2-HMAC-SHA256"
    self.iterations = iterations
    self.salt = salt
  }
}

public struct PortableArchiveContainer: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let archiveID: UUID
  public let kdf: PortableArchiveKDFParameters
  public let envelope: EncryptedEnvelope

  public init(
    schemaVersion: Int = 1,
    kind: String = "bestasr-portable-archive",
    archiveID: UUID,
    kdf: PortableArchiveKDFParameters,
    envelope: EncryptedEnvelope
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.archiveID = archiveID
    self.kdf = kdf
    self.envelope = envelope
  }
}

public enum PortableArchiveExportFault: Sendable {
  case cancelled
  case insufficientSpace
  case none
  case simulatedProcessKill
}

public enum PortableArchiveImportFault: Sendable {
  case cancelledAfterFirstEncryptedWrite
  case none
  case simulatedKillAfterFirstEncryptedWrite
}

public enum PortableArchiveImportOutcome: String, Codable, Sendable {
  case alreadyImported
  case imported
}

public struct PortableArchiveImportResult: Equatable, Sendable {
  public let outcome: PortableArchiveImportOutcome
  public let archiveID: UUID
  public let payload: PortableArchivePayload
  public let destination: URL
  public let migratedFromSchemaVersion: Int?
}

struct PortableArchiveReceipt: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let archiveID: UUID
  let payloadDigest: BestASRDomain.SHA256Digest
  let assetCount: Int
}
