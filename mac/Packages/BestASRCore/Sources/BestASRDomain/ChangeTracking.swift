import Foundation

public enum DomainEntityKind: String, Codable, Sendable {
  case audioChunk
  case durableJob
  case derivedDocument
  case event
  case eventCandidate
  case modelArtifact
  case person
  case session
  case sessionSpeaker
  case sourceTrack
  case speakerOccurrence
  case timelineEvent
  case transcriptRevision
}

public struct DomainEntityReference: Codable, Equatable, Hashable, Sendable {
  public let kind: DomainEntityKind
  public let stableID: UUID

  public init(kind: DomainEntityKind, stableID: UUID) {
    self.kind = kind
    self.stableID = stableID
  }
}

public enum ChangeOperationKind: String, Codable, Sendable {
  case create
  case personCorrection
  case update
}

public struct ChangeLogEntry: Codable, Equatable, Sendable {
  public let id: ChangeID
  public let entity: DomainEntityReference
  public let revision: Revision
  public let occurredAt: Date
  public let originDeviceID: UUID
  public let operation: ChangeOperationKind
  public let payloadDigest: SHA256Digest
  public let personCorrection: PersonCorrectionOperation?

  public init(
    id: ChangeID,
    entity: DomainEntityReference,
    revision: Revision,
    occurredAt: Date,
    originDeviceID: UUID,
    operation: ChangeOperationKind,
    payloadDigest: SHA256Digest,
    personCorrection: PersonCorrectionOperation?
  ) {
    self.id = id
    self.entity = entity
    self.revision = revision
    self.occurredAt = occurredAt
    self.originDeviceID = originDeviceID
    self.operation = operation
    self.payloadDigest = payloadDigest
    self.personCorrection = personCorrection
  }
}

public enum DeletionScope: String, Codable, Sendable {
  case explicitSourceAssetDeletion
  case metadataOnly
}

public struct Tombstone: Codable, Equatable, Sendable {
  public let id: TombstoneID
  public let entity: DomainEntityReference
  public let revision: Revision
  public let deletedAt: Date
  public let deletionScope: DeletionScope
  public let changeID: ChangeID

  public init(
    id: TombstoneID,
    entity: DomainEntityReference,
    revision: Revision,
    deletedAt: Date,
    deletionScope: DeletionScope,
    changeID: ChangeID
  ) {
    self.id = id
    self.entity = entity
    self.revision = revision
    self.deletedAt = deletedAt
    self.deletionScope = deletionScope
    self.changeID = changeID
  }
}

public struct DomainSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sessions: [Session]
  public let tracks: [SourceTrack]
  public let chunks: [AudioChunk]
  public let timelineEvents: [TimelineEvent]
  public let transcriptRevisions: [TranscriptRevision]
  public let durableJobs: [DurableJob]
  public let modelArtifacts: [ModelArtifact]
  public let sessionSpeakers: [SessionSpeaker]
  public let speakerOccurrences: [SpeakerOccurrence]
  public let persons: [Person]
  public let personCorrections: [PersonCorrectionOperation]
  public let changeLog: [ChangeLogEntry]
  public let tombstones: [Tombstone]

  public init(
    schemaVersion: Int = 1,
    sessions: [Session],
    tracks: [SourceTrack],
    chunks: [AudioChunk],
    timelineEvents: [TimelineEvent],
    transcriptRevisions: [TranscriptRevision],
    durableJobs: [DurableJob],
    modelArtifacts: [ModelArtifact],
    sessionSpeakers: [SessionSpeaker],
    speakerOccurrences: [SpeakerOccurrence],
    persons: [Person],
    personCorrections: [PersonCorrectionOperation],
    changeLog: [ChangeLogEntry],
    tombstones: [Tombstone]
  ) {
    self.schemaVersion = schemaVersion
    self.sessions = sessions
    self.tracks = tracks
    self.chunks = chunks
    self.timelineEvents = timelineEvents
    self.transcriptRevisions = transcriptRevisions
    self.durableJobs = durableJobs
    self.modelArtifacts = modelArtifacts
    self.sessionSpeakers = sessionSpeakers
    self.speakerOccurrences = speakerOccurrences
    self.persons = persons
    self.personCorrections = personCorrections
    self.changeLog = changeLog
    self.tombstones = tombstones
  }
}
