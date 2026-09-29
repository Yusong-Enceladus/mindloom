import Foundation

public struct SessionSpeaker: Codable, Equatable, Sendable {
  public let id: SessionSpeakerID
  public let sessionID: SessionID
  public let revision: Revision
  public let stableOrdinal: UInt32

  public init(
    id: SessionSpeakerID,
    sessionID: SessionID,
    revision: Revision,
    stableOrdinal: UInt32
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.stableOrdinal = stableOrdinal
  }
}

public enum PersonAssociationStatus: String, Codable, Sendable {
  /// A stable local person created from sufficient voice evidence before the
  /// user has supplied a name or confirmed a cross-session match.
  case anonymousIdentity
  case automaticMatch
  case candidate
  case rejected
  case unknown
  case userConfirmed
}

public struct PersonAssociation: Codable, Equatable, Sendable {
  public let status: PersonAssociationStatus
  public let personID: PersonID?
  public let confidence: Confidence?
  public let evidenceRevision: Revision

  private enum CodingKeys: String, CodingKey {
    case confidence
    case evidenceRevision
    case personID
    case status
  }

  public init(
    status: PersonAssociationStatus,
    personID: PersonID?,
    confidence: Confidence?,
    evidenceRevision: Revision
  ) throws {
    switch status {
    case .unknown:
      guard personID == nil, confidence == nil else {
        throw DomainValidationError.invalidAssociation
      }
    case .anonymousIdentity:
      guard personID != nil, confidence == nil else {
        throw DomainValidationError.invalidAssociation
      }
    case .candidate, .automaticMatch:
      guard personID != nil, confidence != nil else {
        throw DomainValidationError.invalidAssociation
      }
    case .rejected, .userConfirmed:
      guard personID != nil else {
        throw DomainValidationError.invalidAssociation
      }
    }
    self.status = status
    self.personID = personID
    self.confidence = confidence
    self.evidenceRevision = evidenceRevision
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      status: container.decode(PersonAssociationStatus.self, forKey: .status),
      personID: container.decodeIfPresent(PersonID.self, forKey: .personID),
      confidence: container.decodeIfPresent(Confidence.self, forKey: .confidence),
      evidenceRevision: container.decode(Revision.self, forKey: .evidenceRevision)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(personID, forKey: .personID)
    try container.encodeIfPresent(confidence, forKey: .confidence)
    try container.encode(evidenceRevision, forKey: .evidenceRevision)
  }
}

public struct SpeakerOccurrence: Codable, Equatable, Sendable {
  public let id: SpeakerOccurrenceID
  public let sessionID: SessionID
  public let sessionSpeakerID: SessionSpeakerID
  public let revision: Revision
  public let trackIDs: [TrackID]
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let overlapsAnotherSpeaker: Bool
  public let association: PersonAssociation

  public init(
    id: SpeakerOccurrenceID,
    sessionID: SessionID,
    sessionSpeakerID: SessionSpeakerID,
    revision: Revision,
    trackIDs: [TrackID],
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    overlapsAnotherSpeaker: Bool,
    association: PersonAssociation
  ) {
    self.id = id
    self.sessionID = sessionID
    self.sessionSpeakerID = sessionSpeakerID
    self.revision = revision
    self.trackIDs = trackIDs
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
    self.association = association
  }
}

public struct Person: Codable, Equatable, Sendable {
  public let id: PersonID
  public let revision: Revision
  public let displayName: String?
  public let aliases: [String]
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: PersonID,
    revision: Revision,
    displayName: String?,
    aliases: [String],
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.revision = revision
    self.displayName = displayName
    self.aliases = aliases
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum PersonCorrectionActor: String, Codable, Sendable {
  case automatic
  case user
}

public enum PersonCorrectionPayload: Codable, Equatable, Sendable {
  case confirm(occurrenceID: SpeakerOccurrenceID, personID: PersonID)
  case merge(primaryID: PersonID, mergedID: PersonID)
  case reject(occurrenceID: SpeakerOccurrenceID, candidatePersonID: PersonID)
  case rename(personID: PersonID, displayName: String)
  case split(
    sourcePersonID: PersonID,
    newPersonID: PersonID,
    occurrenceIDs: [SpeakerOccurrenceID]
  )

  private enum CodingKeys: String, CodingKey {
    case candidatePersonID
    case displayName
    case kind
    case mergedID
    case newPersonID
    case occurrenceID
    case occurrenceIDs
    case personID
    case primaryID
    case sourcePersonID
  }

  private enum Kind: String, Codable {
    case confirm
    case merge
    case reject
    case rename
    case split
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .confirm:
      self = .confirm(
        occurrenceID: try container.decode(
          SpeakerOccurrenceID.self,
          forKey: .occurrenceID
        ),
        personID: try container.decode(PersonID.self, forKey: .personID)
      )
    case .merge:
      self = .merge(
        primaryID: try container.decode(PersonID.self, forKey: .primaryID),
        mergedID: try container.decode(PersonID.self, forKey: .mergedID)
      )
    case .reject:
      self = .reject(
        occurrenceID: try container.decode(
          SpeakerOccurrenceID.self,
          forKey: .occurrenceID
        ),
        candidatePersonID: try container.decode(
          PersonID.self,
          forKey: .candidatePersonID
        )
      )
    case .rename:
      self = .rename(
        personID: try container.decode(PersonID.self, forKey: .personID),
        displayName: try container.decode(String.self, forKey: .displayName)
      )
    case .split:
      self = .split(
        sourcePersonID: try container.decode(PersonID.self, forKey: .sourcePersonID),
        newPersonID: try container.decode(PersonID.self, forKey: .newPersonID),
        occurrenceIDs: try container.decode(
          [SpeakerOccurrenceID].self,
          forKey: .occurrenceIDs
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .confirm(let occurrenceID, let personID):
      try container.encode(Kind.confirm, forKey: .kind)
      try container.encode(occurrenceID, forKey: .occurrenceID)
      try container.encode(personID, forKey: .personID)
    case .merge(let primaryID, let mergedID):
      try container.encode(Kind.merge, forKey: .kind)
      try container.encode(primaryID, forKey: .primaryID)
      try container.encode(mergedID, forKey: .mergedID)
    case .reject(let occurrenceID, let candidatePersonID):
      try container.encode(Kind.reject, forKey: .kind)
      try container.encode(occurrenceID, forKey: .occurrenceID)
      try container.encode(candidatePersonID, forKey: .candidatePersonID)
    case .rename(let personID, let displayName):
      try container.encode(Kind.rename, forKey: .kind)
      try container.encode(personID, forKey: .personID)
      try container.encode(displayName, forKey: .displayName)
    case .split(let sourcePersonID, let newPersonID, let occurrenceIDs):
      try container.encode(Kind.split, forKey: .kind)
      try container.encode(sourcePersonID, forKey: .sourcePersonID)
      try container.encode(newPersonID, forKey: .newPersonID)
      try container.encode(occurrenceIDs, forKey: .occurrenceIDs)
    }
  }
}

public struct PersonCorrectionOperation: Codable, Equatable, Sendable {
  public let id: PersonCorrectionID
  public let revision: Revision
  public let occurredAt: Date
  public let actor: PersonCorrectionActor
  public let payload: PersonCorrectionPayload
  public let reversesOperationID: PersonCorrectionID?

  public init(
    id: PersonCorrectionID,
    revision: Revision,
    occurredAt: Date,
    actor: PersonCorrectionActor,
    payload: PersonCorrectionPayload,
    reversesOperationID: PersonCorrectionID?
  ) {
    self.id = id
    self.revision = revision
    self.occurredAt = occurredAt
    self.actor = actor
    self.payload = payload
    self.reversesOperationID = reversesOperationID
  }
}
