import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
  case invalidAssociation
  case invalidConfidence
  case invalidDictionaryEntry
  case invalidDigest
  case invalidPortableAssetReference
  case invalidRevision
}

public struct StableID<Tag>: Codable, Hashable, CustomStringConvertible, Sendable {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(UUID.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String {
    rawValue.uuidString
  }
}

public enum SessionIdentity: Sendable {}
public enum TrackIdentity: Sendable {}
public enum ChunkIdentity: Sendable {}
public enum TimelineEventIdentity: Sendable {}
public enum TranscriptRevisionIdentity: Sendable {}
public enum DurableJobIdentity: Sendable {}
public enum ModelArtifactIdentity: Sendable {}
public enum SessionSpeakerIdentity: Sendable {}
public enum SpeakerOccurrenceIdentity: Sendable {}
public enum PersonIdentity: Sendable {}
public enum ChangeIdentity: Sendable {}
public enum TombstoneIdentity: Sendable {}
public enum PersonCorrectionIdentity: Sendable {}
public enum DerivedDocumentIdentity: Sendable {}
public enum DictionaryEntryIdentity: Sendable {}
public enum EventIdentity: Sendable {}
public enum EventCandidateIdentity: Sendable {}
public enum EventEditOperationIdentity: Sendable {}

public typealias SessionID = StableID<SessionIdentity>
public typealias TrackID = StableID<TrackIdentity>
public typealias ChunkID = StableID<ChunkIdentity>
public typealias TimelineEventID = StableID<TimelineEventIdentity>
public typealias TranscriptRevisionID = StableID<TranscriptRevisionIdentity>
public typealias DurableJobID = StableID<DurableJobIdentity>
public typealias ModelArtifactID = StableID<ModelArtifactIdentity>
public typealias SessionSpeakerID = StableID<SessionSpeakerIdentity>
public typealias SpeakerOccurrenceID = StableID<SpeakerOccurrenceIdentity>
public typealias PersonID = StableID<PersonIdentity>
public typealias ChangeID = StableID<ChangeIdentity>
public typealias TombstoneID = StableID<TombstoneIdentity>
public typealias PersonCorrectionID = StableID<PersonCorrectionIdentity>
public typealias DerivedDocumentID = StableID<DerivedDocumentIdentity>
public typealias DictionaryEntryID = StableID<DictionaryEntryIdentity>
public typealias EventID = StableID<EventIdentity>
public typealias EventCandidateID = StableID<EventCandidateIdentity>
public typealias EventEditOperationID = StableID<EventEditOperationIdentity>

public struct Revision: Codable, Hashable, Comparable, Sendable {
  public let value: UInt64

  public init(_ value: UInt64) throws {
    guard value > 0 else {
      throw DomainValidationError.invalidRevision
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(UInt64.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }

  public static func < (lhs: Revision, rhs: Revision) -> Bool {
    lhs.value < rhs.value
  }
}

public struct SHA256Digest: Codable, Hashable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    guard
      value.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil
    else {
      throw DomainValidationError.invalidDigest
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public enum PortableAssetReference: Codable, Equatable, Hashable, Sendable {
  case contentAddressed(SHA256Digest)
  case relativePath(String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case value
  }

  private enum Kind: String, Codable {
    case contentAddressed
    case relativePath
  }

  public init(relativePath: String) throws {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty,
      !relativePath.hasPrefix("/"),
      !relativePath.hasPrefix("~"),
      !relativePath.contains("\\"),
      !relativePath.contains("://"),
      components.allSatisfy({
        !$0.isEmpty
          && $0 != "."
          && $0 != ".."
          && $0.range(
            of: "^[A-Za-z0-9._-]+$",
            options: .regularExpression
          ) != nil
      })
    else {
      throw DomainValidationError.invalidPortableAssetReference
    }
    self = .relativePath(relativePath)
  }

  public init(contentDigest: SHA256Digest) {
    self = .contentAddressed(contentDigest)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .contentAddressed:
      self = .contentAddressed(
        try container.decode(SHA256Digest.self, forKey: .value)
      )
    case .relativePath:
      try self.init(
        relativePath: container.decode(String.self, forKey: .value)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .contentAddressed(let digest):
      try container.encode(Kind.contentAddressed, forKey: .kind)
      try container.encode(digest, forKey: .value)
    case .relativePath(let path):
      try container.encode(Kind.relativePath, forKey: .kind)
      try container.encode(path, forKey: .value)
    }
  }
}

public struct Confidence: Codable, Equatable, Comparable, Sendable {
  public let value: Double

  public init(_ value: Double) throws {
    guard value.isFinite, (0...1).contains(value) else {
      throw DomainValidationError.invalidConfidence
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(Double.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }

  public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
    lhs.value < rhs.value
  }
}
