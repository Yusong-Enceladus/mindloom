import Foundation

public enum AudioJournalState: String, Codable, Sendable {
  case finalized
  case recording
  case recoveryRequired
  case stoppedForDiskPressure
}

public struct AudioJournalTrack: Codable, Equatable, Sendable {
  public let trackID: String
  public let role: String

  public init(trackID: String, role: String) {
    self.trackID = trackID
    self.role = role
  }
}

public struct AudioJournalChunkEntry: Codable, Equatable, Sendable {
  public let trackID: String
  public let sequence: UInt64
  public let relativePath: String
  public let monotonicStartNanoseconds: UInt64
  public let sampleRateHertz: UInt32
  public let frameCount: UInt32
  public let byteCount: UInt64
  public let contentDigest: String

  public init(
    trackID: String,
    sequence: UInt64,
    relativePath: String,
    monotonicStartNanoseconds: UInt64,
    sampleRateHertz: UInt32,
    frameCount: UInt32,
    byteCount: UInt64,
    contentDigest: String
  ) {
    self.trackID = trackID
    self.sequence = sequence
    self.relativePath = relativePath
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.sampleRateHertz = sampleRateHertz
    self.frameCount = frameCount
    self.byteCount = byteCount
    self.contentDigest = contentDigest
  }
}

public enum AudioJournalIssueKind: String, Codable, Sendable {
  case corruptDigest
  case duplicateSequence
  case missingChunk
  case orphanCommittedFile
  case orphanStagingFile
  case truncatedChunk
}

public struct AudioJournalRecoveryIssue: Codable, Equatable, Sendable {
  public let kind: AudioJournalIssueKind
  public let trackID: String?
  public let sequence: UInt64?
  public let byteCount: UInt64

  public init(
    kind: AudioJournalIssueKind,
    trackID: String? = nil,
    sequence: UInt64? = nil,
    byteCount: UInt64 = 0
  ) {
    self.kind = kind
    self.trackID = trackID
    self.sequence = sequence
    self.byteCount = byteCount
  }
}

public struct AudioJournalGap: Codable, Equatable, Sendable {
  public let trackID: String
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let durationNanoseconds: UInt64
  public let reason: AudioJournalIssueKind

  public init(
    trackID: String,
    sequence: UInt64,
    monotonicStartNanoseconds: UInt64,
    durationNanoseconds: UInt64,
    reason: AudioJournalIssueKind
  ) {
    self.trackID = trackID
    self.sequence = sequence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.durationNanoseconds = durationNanoseconds
    self.reason = reason
  }
}

public struct AudioJournalManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sessionID: UUID
  public var state: AudioJournalState
  public var tracks: [AudioJournalTrack]
  public var committedChunks: [AudioJournalChunkEntry]
  public var recoveryIssues: [AudioJournalRecoveryIssue]
  public var gaps: [AudioJournalGap]

  public init(
    schemaVersion: Int = 1,
    sessionID: UUID,
    state: AudioJournalState,
    tracks: [AudioJournalTrack],
    committedChunks: [AudioJournalChunkEntry],
    recoveryIssues: [AudioJournalRecoveryIssue],
    gaps: [AudioJournalGap]
  ) {
    self.schemaVersion = schemaVersion
    self.sessionID = sessionID
    self.state = state
    self.tracks = tracks
    self.committedChunks = committedChunks
    self.recoveryIssues = recoveryIssues
    self.gaps = gaps
  }
}

public struct CommittedInferenceRange: Codable, Equatable, Sendable {
  public let trackID: String
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let durationNanoseconds: UInt64
  public let contentDigest: String

  public init(entry: AudioJournalChunkEntry) {
    trackID = entry.trackID
    sequence = entry.sequence
    monotonicStartNanoseconds = entry.monotonicStartNanoseconds
    durationNanoseconds = UInt64(
      (Double(entry.frameCount) * 1_000_000_000
        / Double(entry.sampleRateHertz)).rounded()
    )
    contentDigest = entry.contentDigest
  }
}

public struct AudioJournalRecoveryReport: Codable, Equatable, Sendable {
  public let state: AudioJournalState
  public let readableCommittedChunkCount: Int
  public let quarantinedByteCount: UInt64
  public let issues: [AudioJournalRecoveryIssue]
  public let gaps: [AudioJournalGap]

  public init(
    state: AudioJournalState,
    readableCommittedChunkCount: Int,
    quarantinedByteCount: UInt64,
    issues: [AudioJournalRecoveryIssue],
    gaps: [AudioJournalGap]
  ) {
    self.state = state
    self.readableCommittedChunkCount = readableCommittedChunkCount
    self.quarantinedByteCount = quarantinedByteCount
    self.issues = issues
    self.gaps = gaps
  }
}

public enum AudioJournalFaultPoint: String, Codable, CaseIterable, Sendable {
  case afterChunkRename
  case afterManifestCommit
  case afterPartialStagingWrite
  case afterStagingSync
  case none
}

public enum AudioJournalError: Error, Equatable {
  case cannotFinalize
  case injectedCrash(AudioJournalFaultPoint)
  case invalidManifest
  case invalidTrackID(String)
  case journalAlreadyExists
  case journalNotRecording
  case posix(operation: String, code: Int32)
  case unknownTrack(String)
}
