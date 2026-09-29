import Foundation

public enum SourceContextReliability: String, Codable, Sendable {
  /// The adapter recognized an explicit meeting/window field or speaking state.
  case reliable
  /// The value is useful display context but must not drive identity decisions.
  case advisory
}

/// A bounded, local-only snapshot from a source application's visible UI.
/// Values are evidence attached to the session; they never alter the audio
/// capture boundary and never replace speaker-embedding evidence.
public struct SourceContextSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: SessionID
  public let revision: Revision
  public let adapterID: String
  public let sourceBundleID: String?
  public let meetingTitle: String?
  public let windowTitle: String?
  public let participantDisplayNames: [String]
  public let activeSpeakerDisplayName: String?
  public let monotonicNanoseconds: UInt64
  public let reliability: SourceContextReliability

  public init(
    id: UUID = UUID(),
    sessionID: SessionID,
    revision: Revision,
    adapterID: String,
    sourceBundleID: String?,
    meetingTitle: String?,
    windowTitle: String?,
    participantDisplayNames: [String],
    activeSpeakerDisplayName: String?,
    monotonicNanoseconds: UInt64,
    reliability: SourceContextReliability
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.adapterID = adapterID
    self.sourceBundleID = sourceBundleID
    self.meetingTitle = meetingTitle
    self.windowTitle = windowTitle
    self.participantDisplayNames = participantDisplayNames
    self.activeSpeakerDisplayName = activeSpeakerDisplayName
    self.monotonicNanoseconds = monotonicNanoseconds
    self.reliability = reliability
  }

  public var displayTitle: String? { meetingTitle ?? windowTitle }
}

/// A conservative, time-aligned mapping from one session speaker to a name
/// exposed by a local meeting application's current-speaker UI. Participant
/// lists alone never create this evidence. The referenced source snapshots
/// remain the provenance record, while the occurrence IDs identify the clean
/// audio turns that overlapped those snapshots.
public struct PlatformSpeakerNameEvidence:
  Codable, Equatable, Identifiable, Sendable
{
  public let id: UUID
  public let sessionID: SessionID
  public let sessionSpeakerID: SessionSpeakerID
  public let revision: Revision
  public let displayName: String
  public let occurrenceIDs: [SpeakerOccurrenceID]
  public let sourceContextIDs: [UUID]
  public let alignedSpeechNanoseconds: UInt64

  public init(
    id: UUID,
    sessionID: SessionID,
    sessionSpeakerID: SessionSpeakerID,
    revision: Revision,
    displayName: String,
    occurrenceIDs: [SpeakerOccurrenceID],
    sourceContextIDs: [UUID],
    alignedSpeechNanoseconds: UInt64
  ) {
    self.id = id
    self.sessionID = sessionID
    self.sessionSpeakerID = sessionSpeakerID
    self.revision = revision
    self.displayName = displayName
    self.occurrenceIDs = occurrenceIDs
    self.sourceContextIDs = sourceContextIDs
    self.alignedSpeechNanoseconds = alignedSpeechNanoseconds
  }
}
