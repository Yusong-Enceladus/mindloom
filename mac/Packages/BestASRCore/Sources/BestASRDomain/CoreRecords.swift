import Foundation

public enum SessionInputMode: String, Codable, CaseIterable, Hashable, Sendable {
  case dictation
  case importedMedia
  case roomMicrophone
  case systemAudio
  /// Text, a screenshot/image, or a document the user pasted or dragged in.
  /// It has no audio: no tracks, chunks, speaker work, or recognition. Its
  /// body is a `final` transcript revision holding the pasted or locally
  /// extracted text, so identity, revisions, tombstones, search, events,
  /// export, and the organizer outbox are the same as for a recording.
  case userItem
}

public enum SessionState: String, Codable, Sendable {
  case cancelled
  case completed
  case failedRecoverable
  case finalizing
  case paused
  case preparing
  case recording
}

public enum SourceAudioRetention: String, Codable, Sendable {
  case retainedUntilExplicitDeletion
  /// The user explicitly removed the retained source bytes while keeping the
  /// transcript, revisions, timeline, people, and source provenance records.
  case explicitlyDeletedByUser
}

public struct Session: Codable, Equatable, Sendable {
  public let id: SessionID
  public let revision: Revision
  public let inputMode: SessionInputMode
  public let state: SessionState
  public let createdAt: Date
  public let updatedAt: Date
  public let sourceAudioRetention: SourceAudioRetention

  public init(
    id: SessionID,
    revision: Revision,
    inputMode: SessionInputMode,
    state: SessionState,
    createdAt: Date,
    updatedAt: Date,
    sourceAudioRetention: SourceAudioRetention = .retainedUntilExplicitDeletion
  ) {
    self.id = id
    self.revision = revision
    self.inputMode = inputMode
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sourceAudioRetention = sourceAudioRetention
  }
}

public enum SourceTrackRole: String, Codable, Hashable, Sendable {
  case importedSource
  case microphoneLocal
  case roomMicrophone
  case systemRemote
}

public struct SourceTrack: Codable, Equatable, Sendable {
  public let id: TrackID
  public let sessionID: SessionID
  public let revision: Revision
  public let role: SourceTrackRole
  public let assetReference: PortableAssetReference
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16

  public init(
    id: TrackID,
    sessionID: SessionID,
    revision: Revision,
    role: SourceTrackRole,
    assetReference: PortableAssetReference,
    sampleRateHertz: UInt32,
    channelCount: UInt16
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.role = role
    self.assetReference = assetReference
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
  }
}

public struct AudioChunk: Codable, Equatable, Sendable {
  public let id: ChunkID
  public let sessionID: SessionID
  public let trackID: TrackID
  public let revision: Revision
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let frameCount: UInt64
  public let contentDigest: SHA256Digest
  public let assetReference: PortableAssetReference

  public init(
    id: ChunkID,
    sessionID: SessionID,
    trackID: TrackID,
    revision: Revision,
    sequence: UInt64,
    monotonicStartNanoseconds: UInt64,
    frameCount: UInt64,
    contentDigest: SHA256Digest,
    assetReference: PortableAssetReference
  ) {
    self.id = id
    self.sessionID = sessionID
    self.trackID = trackID
    self.revision = revision
    self.sequence = sequence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.frameCount = frameCount
    self.contentDigest = contentDigest
    self.assetReference = assetReference
  }
}

public enum TimelineEventKind: String, Codable, Sendable {
  case deviceChanged
  case gap
  case pause
  case resume
  case sourceChanged
}

public struct TimelineEvent: Codable, Equatable, Sendable {
  public let id: TimelineEventID
  public let sessionID: SessionID
  public let revision: Revision
  public let kind: TimelineEventKind
  public let monotonicNanoseconds: UInt64
  public let durationNanoseconds: UInt64?

  public init(
    id: TimelineEventID,
    sessionID: SessionID,
    revision: Revision,
    kind: TimelineEventKind,
    monotonicNanoseconds: UInt64,
    durationNanoseconds: UInt64?
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.kind = kind
    self.monotonicNanoseconds = monotonicNanoseconds
    self.durationNanoseconds = durationNanoseconds
  }
}

public enum TranscriptRevisionKind: String, Codable, Sendable {
  case final
  case sentence
  case streaming
  case userEdit
}

public struct TranscriptRevision: Codable, Equatable, Sendable {
  public let id: TranscriptRevisionID
  public let sessionID: SessionID
  public let revision: Revision
  public let parentID: TranscriptRevisionID?
  public let kind: TranscriptRevisionKind
  public let content: String
  public let modelArtifactID: ModelArtifactID?
  public let configHash: SHA256Digest?
  public let createdAt: Date

  public init(
    id: TranscriptRevisionID,
    sessionID: SessionID,
    revision: Revision,
    parentID: TranscriptRevisionID?,
    kind: TranscriptRevisionKind,
    content: String,
    modelArtifactID: ModelArtifactID?,
    configHash: SHA256Digest?,
    createdAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.parentID = parentID
    self.kind = kind
    self.content = content
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.createdAt = createdAt
  }
}

public enum DurableJobKind: String, Codable, Sendable {
  case asrFinal
  case asrLive
  case localText
  case searchIndex
  case speakerFinal
}

public enum DurableJobState: String, Codable, Sendable {
  case cancelled
  case permanentFailed
  case queued
  case retryableFailed
  case running
  case succeeded
}

public enum DurableJobErrorCategory: String, Codable, Sendable {
  case cancelled
  case corruptInput
  case incompatibleArtifact
  case modelUnavailable
  case none
  case resourcePressure
  case transientWorker
}

public struct DurableJob: Codable, Equatable, Sendable {
  public let id: DurableJobID
  public let revision: Revision
  public let kind: DurableJobKind
  public let state: DurableJobState
  public let inputRevision: Revision
  public let modelArtifactID: ModelArtifactID?
  public let configHash: SHA256Digest
  public let retryCount: UInt32
  public let errorCategory: DurableJobErrorCategory
  public let leaseOwner: UUID?
  public let leaseExpiresAt: Date?

  public init(
    id: DurableJobID,
    revision: Revision,
    kind: DurableJobKind,
    state: DurableJobState,
    inputRevision: Revision,
    modelArtifactID: ModelArtifactID?,
    configHash: SHA256Digest,
    retryCount: UInt32,
    errorCategory: DurableJobErrorCategory,
    leaseOwner: UUID?,
    leaseExpiresAt: Date?
  ) {
    self.id = id
    self.revision = revision
    self.kind = kind
    self.state = state
    self.inputRevision = inputRevision
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.retryCount = retryCount
    self.errorCategory = errorCategory
    self.leaseOwner = leaseOwner
    self.leaseExpiresAt = leaseExpiresAt
  }

  public var idempotencyKey: String {
    [
      kind.rawValue,
      String(inputRevision.value),
      modelArtifactID?.rawValue.uuidString ?? "no-model",
      configHash.value,
    ].joined(separator: ":")
  }
}

public enum ModelCapability: String, Codable, CaseIterable, Sendable {
  case asr
  case diarization
  case localText
  case speakerEmbedding
}

public enum ModelArtifactState: String, Codable, Sendable {
  case active
  case inactive
  case quarantined
  case staged
}

public struct ModelArtifact: Codable, Equatable, Sendable {
  public let id: ModelArtifactID
  public let revision: Revision
  public let registryKey: String
  public let version: String
  public let capability: ModelCapability
  public let digest: SHA256Digest
  public let directoryReference: PortableAssetReference
  public let licenseIdentifier: String
  public let state: ModelArtifactState

  public init(
    id: ModelArtifactID,
    revision: Revision,
    registryKey: String,
    version: String,
    capability: ModelCapability,
    digest: SHA256Digest,
    directoryReference: PortableAssetReference,
    licenseIdentifier: String,
    state: ModelArtifactState
  ) {
    self.id = id
    self.revision = revision
    self.registryKey = registryKey
    self.version = version
    self.capability = capability
    self.digest = digest
    self.directoryReference = directoryReference
    self.licenseIdentifier = licenseIdentifier
    self.state = state
  }
}
