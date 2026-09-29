import Foundation

public protocol SessionRepository: Sendable {
  func loadSession(id: SessionID) async throws -> Session?
  func saveSnapshot(_ snapshot: DomainSnapshot) async throws
}

public protocol DurableJobRepository: Sendable {
  func enqueue(_ job: DurableJob) async throws
  func nextRunnableJob() async throws -> DurableJob?
  func update(_ job: DurableJob) async throws
}

public protocol ModelArtifactRepository: Sendable {
  func activeArtifact(for capability: ModelCapability) async throws -> ModelArtifact?
  func save(_ artifact: ModelArtifact) async throws
}

public protocol DerivedDocumentRepository: Sendable {
  func load(id: DerivedDocumentID) async throws -> DerivedDocument?
  func save(_ document: DerivedDocument) async throws
}

public protocol DictionaryRepository: Sendable {
  func createDictionaryEntry(
    canonicalForm: String,
    spokenForms: [String]
  ) async throws -> DictionaryEntry
  func dictionaryEntry(id: DictionaryEntryID) async throws -> DictionaryEntry?
  func searchDictionaryEntries(
    query: String,
    includeDisabled: Bool,
    limit: Int
  ) async throws -> [DictionaryEntry]
  func updateDictionaryEntry(
    id: DictionaryEntryID,
    expectedRevision: Revision,
    canonicalForm: String,
    spokenForms: [String]
  ) async throws -> DictionaryEntry
  func setDictionaryEntryEnabled(
    id: DictionaryEntryID,
    expectedRevision: Revision,
    enabled: Bool
  ) async throws -> DictionaryEntry
  func deleteDictionaryEntry(
    id: DictionaryEntryID,
    expectedRevision: Revision
  ) async throws -> DictionaryEntry
  func dictionaryContext(
    maximumEntries: Int,
    maximumUTF8Bytes: Int
  ) async throws -> DictionaryContextProjection
}

public protocol ChangeLogRepository: Sendable {
  func append(_ entry: ChangeLogEntry) async throws
  func changes(after revision: Revision?) async throws -> [ChangeLogEntry]
  func save(_ tombstone: Tombstone) async throws
}

public protocol EventMemoryRepository: Sendable {
  func createEvent(
    title: String,
    notes: String,
    sessionIDs: [SessionID]
  ) async throws -> MemoryEvent
  func updateEvent(
    id: EventID,
    title: String,
    notes: String
  ) async throws -> MemoryEvent
  func linkSessions(
    _ sessionIDs: [SessionID],
    to eventID: EventID,
    source: EventMembershipSource,
    evidence: EventLinkEvidence
  ) async throws
  func moveSessions(
    _ sessionIDs: [SessionID],
    from sourceEventID: EventID,
    to targetEventID: EventID,
    evidence: EventLinkEvidence
  ) async throws
  func removeSessions(_ sessionIDs: [SessionID], from eventID: EventID) async throws
  func mergeEvents(primaryID: EventID, mergedID: EventID) async throws
  func splitEvent(
    sourceID: EventID,
    sessionIDs: [SessionID],
    newTitle: String
  ) async throws -> MemoryEvent
  func retireEvent(id: EventID) async throws
  func undoLastEventEdit() async throws -> Bool
  func eventCandidates() async throws -> [EventCandidate]
  func replacePendingEventCandidates(_ candidates: [EventCandidate]) async throws
  func acceptEventCandidate(id: EventCandidateID) async throws -> EventID
  func dismissEventCandidate(id: EventCandidateID) async throws
  func eventOrganizationSessions() async throws -> [EventOrganizationSession]
}

/// Future sync implementations consume stable change sets without becoming the
/// source of truth for local capture, inference, search, or history.
public protocol SyncAdapter: Sendable {
  func exportChanges(after revision: Revision?) async throws -> [ChangeLogEntry]
  func importChanges(_ changes: [ChangeLogEntry], tombstones: [Tombstone]) async throws
}
