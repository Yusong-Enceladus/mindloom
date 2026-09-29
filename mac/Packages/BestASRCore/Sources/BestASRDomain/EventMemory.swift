import Foundation

public enum EventConfirmationState: String, Codable, Equatable, Sendable {
  case automatic
  case userConfirmed
}

/// A durable, user-visible unit of episodic memory. It groups one or more
/// audio sessions without replacing any source audio, transcript, person
/// occurrence, or derived document that supports it.
public struct MemoryEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: EventID
  public let revision: Revision
  public let title: String
  public let notes: String
  public let startAt: Date
  public let endAt: Date
  public let titleIsUserEdited: Bool
  public let confirmationState: EventConfirmationState
  public let createdAt: Date
  public let updatedAt: Date
  public let retiredAt: Date?
  public let mergedIntoEventID: EventID?

  public init(
    id: EventID = EventID(),
    revision: Revision,
    title: String,
    notes: String = "",
    startAt: Date,
    endAt: Date,
    titleIsUserEdited: Bool,
    confirmationState: EventConfirmationState = .userConfirmed,
    createdAt: Date,
    updatedAt: Date,
    retiredAt: Date? = nil,
    mergedIntoEventID: EventID? = nil
  ) {
    self.id = id
    self.revision = revision
    self.title = title
    self.notes = notes
    self.startAt = startAt
    self.endAt = endAt
    self.titleIsUserEdited = titleIsUserEdited
    self.confirmationState = confirmationState
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.retiredAt = retiredAt
    self.mergedIntoEventID = mergedIntoEventID
  }
}

public enum EventMembershipSource: String, Codable, Equatable, Sendable {
  case automatic
  case candidateAccepted
  case manual
}

public enum EventLinkRejectionReason: String, Codable, Equatable, Sendable {
  case manualMove
  case manualRemoval
  case manualSplit
}

public struct EventLinkRejection: Codable, Equatable, Sendable {
  public let eventID: EventID
  public let sessionID: SessionID
  public let reason: EventLinkRejectionReason
  public let createdAt: Date

  public init(
    eventID: EventID,
    sessionID: SessionID,
    reason: EventLinkRejectionReason,
    createdAt: Date
  ) {
    self.eventID = eventID
    self.sessionID = sessionID
    self.reason = reason
    self.createdAt = createdAt
  }
}

/// Scores remain independently inspectable so an automatic grouping never
/// becomes an untraceable assertion about the user's history.
public struct EventLinkEvidence: Codable, Equatable, Sendable {
  public let semanticScore: Double
  public let temporalScore: Double
  public let peopleScore: Double
  public let sourceScore: Double
  public let aggregateScore: Double
  public let modelIdentifier: String
  public let evaluatedAt: Date

  public init(
    semanticScore: Double,
    temporalScore: Double,
    peopleScore: Double,
    sourceScore: Double,
    aggregateScore: Double,
    modelIdentifier: String,
    evaluatedAt: Date
  ) {
    self.semanticScore = semanticScore
    self.temporalScore = temporalScore
    self.peopleScore = peopleScore
    self.sourceScore = sourceScore
    self.aggregateScore = aggregateScore
    self.modelIdentifier = modelIdentifier
    self.evaluatedAt = evaluatedAt
  }

  public static func manual(at date: Date = Date()) -> Self {
    Self(
      semanticScore: 0,
      temporalScore: 0,
      peopleScore: 0,
      sourceScore: 0,
      aggregateScore: 1,
      modelIdentifier: "user-manual-v1",
      evaluatedAt: date
    )
  }
}

public struct EventSessionLink: Codable, Equatable, Sendable {
  public let eventID: EventID
  public let sessionID: SessionID
  public let source: EventMembershipSource
  public let confidence: Confidence
  public let evidence: EventLinkEvidence
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    eventID: EventID,
    sessionID: SessionID,
    source: EventMembershipSource,
    confidence: Confidence,
    evidence: EventLinkEvidence,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.eventID = eventID
    self.sessionID = sessionID
    self.source = source
    self.confidence = confidence
    self.evidence = evidence
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct EventPersonLink: Codable, Equatable, Sendable {
  public let eventID: EventID
  public let personID: PersonID
  public let occurrenceCount: Int
  public let speechDurationNanoseconds: UInt64

  public init(
    eventID: EventID,
    personID: PersonID,
    occurrenceCount: Int,
    speechDurationNanoseconds: UInt64
  ) {
    self.eventID = eventID
    self.personID = personID
    self.occurrenceCount = occurrenceCount
    self.speechDurationNanoseconds = speechDurationNanoseconds
  }
}

public enum EventCandidateState: String, Codable, Equatable, Sendable {
  case accepted
  case dismissed
  case pending
  case superseded
}

public struct EventCandidate: Codable, Equatable, Identifiable, Sendable {
  public let id: EventCandidateID
  public let sessionID: SessionID
  public let candidateEventID: EventID?
  public let proposedTitle: String
  public let evidence: EventLinkEvidence
  public let state: EventCandidateState
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: EventCandidateID = EventCandidateID(),
    sessionID: SessionID,
    candidateEventID: EventID?,
    proposedTitle: String,
    evidence: EventLinkEvidence,
    state: EventCandidateState = .pending,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.candidateEventID = candidateEventID
    self.proposedTitle = proposedTitle
    self.evidence = evidence
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// Private text is intentionally present only in this in-process value. It is
/// consumed by an on-device semantic model and is never logging or telemetry
/// material.
public struct EventOrganizationSession: Equatable, Sendable {
  public let sessionID: SessionID
  public let title: String
  public let semanticText: String
  public let createdAt: Date
  public let updatedAt: Date
  public let inputMode: String
  public let sourceIdentifier: String?
  public let sourceBundleIdentifier: String?
  public let personIDs: Set<PersonID>
  public let currentEventIDs: Set<EventID>
  public let rejectedEventIDs: Set<EventID>

  public init(
    sessionID: SessionID,
    title: String,
    semanticText: String,
    createdAt: Date,
    updatedAt: Date,
    inputMode: String,
    sourceIdentifier: String?,
    sourceBundleIdentifier: String?,
    personIDs: Set<PersonID>,
    currentEventIDs: Set<EventID>,
    rejectedEventIDs: Set<EventID>
  ) {
    self.sessionID = sessionID
    self.title = title
    self.semanticText = semanticText
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.inputMode = inputMode
    self.sourceIdentifier = sourceIdentifier
    self.sourceBundleIdentifier = sourceBundleIdentifier
    self.personIDs = personIDs
    self.currentEventIDs = currentEventIDs
    self.rejectedEventIDs = rejectedEventIDs
  }
}
