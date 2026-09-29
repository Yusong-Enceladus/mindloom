import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import XCTest

final class GRDBEventMemoryStoreTests: XCTestCase {
  func testEventRelationshipsAreEditableSearchableAndUndoable() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let firstSession = SessionID(persistenceUUID(970))
    let secondSession = SessionID(persistenceUUID(971))
    try await store.create(preparingSnapshot(sessionID: firstSession))
    try await store.create(
      preparingSnapshot(sessionID: secondSession),
      inputMode: .roomMicrophone
    )

    let event = try await store.createEvent(
      title: "Project Aurora",
      notes: "local evidence",
      sessionIDs: [firstSession]
    )
    try await store.linkSessions(
      [secondSession],
      to: event.id,
      source: .manual,
      evidence: .manual(at: Date(timeIntervalSince1970: 10))
    )
    var summaries = try await store.eventSummaries(query: "Aurora")
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(Set(summaries[0].sessionIDs), Set([firstSession, secondSession]))

    let split = try await store.splitEvent(
      sourceID: event.id,
      sessionIDs: [secondSession],
      newTitle: "Aurora follow-up"
    )
    summaries = try await store.eventSummaries()
    XCTAssertEqual(summaries.count, 2)
    XCTAssertEqual(
      summaries.first(where: { $0.id == split.id })?.sessionIDs,
      [secondSession]
    )

    let splitUndone = try await store.undoLastEventEdit()
    XCTAssertTrue(splitUndone)
    summaries = try await store.eventSummaries()
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(Set(summaries[0].sessionIDs), Set([firstSession, secondSession]))
    try await store.checkpointAndClose()
  }

  func testCandidateAcceptanceCreatesEventWithoutMutatingSessionEvidence()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(972))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let date = Date(timeIntervalSince1970: 20)
    let candidate = EventCandidate(
      id: EventCandidateID(persistenceUUID(973)),
      sessionID: sessionID,
      candidateEventID: nil,
      proposedTitle: "Customer interview",
      evidence: EventLinkEvidence(
        semanticScore: 0.8,
        temporalScore: 1,
        peopleScore: 0,
        sourceScore: 0.4,
        aggregateScore: 0.75,
        modelIdentifier: "test-local-model",
        evaluatedAt: date
      ),
      createdAt: date,
      updatedAt: date
    )
    try await store.replacePendingEventCandidates([candidate])
    let eventID = try await store.acceptEventCandidate(id: candidate.id)

    let loadedDetail = try await store.eventDetail(id: eventID)
    let detail = try XCTUnwrap(loadedDetail)
    XCTAssertEqual(detail.summary.event.title, "Customer interview")
    XCTAssertEqual(detail.summary.sessionIDs, [sessionID])
    XCTAssertEqual(detail.sessionLinks.first?.source, .candidateAccepted)
    let candidateUndone = try await store.undoLastEventEdit()
    let removedEvent = try await store.eventDetail(id: eventID)
    let retainedSession = try await store.load(sessionID: sessionID)
    XCTAssertTrue(candidateUndone)
    XCTAssertNil(removedEvent)
    XCTAssertNotNil(retainedSession)
    try await store.checkpointAndClose()
  }

  func testOneSessionCanLinkToTwoEventsAndMoveOnlyOneRelationship()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(974))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let first = try await store.createEvent(
      title: "Roadmap",
      notes: "",
      sessionIDs: [sessionID]
    )
    let second = try await store.createEvent(
      title: "Customer launch",
      notes: "",
      sessionIDs: []
    )
    let firstDetailBeforeLink = try await store.eventDetail(id: first.id)
    let firstRevisionBeforeLink = try XCTUnwrap(firstDetailBeforeLink)
      .summary.event.revision

    try await store.linkSessions(
      [sessionID],
      to: second.id,
      source: .manual,
      evidence: .manual(at: Date(timeIntervalSince1970: 30))
    )
    let loadedFirst = try await store.eventDetail(id: first.id)
    let loadedSecond = try await store.eventDetail(id: second.id)
    let linkedFirst = try XCTUnwrap(loadedFirst)
    let linkedSecond = try XCTUnwrap(loadedSecond)
    XCTAssertEqual(linkedFirst.summary.sessionIDs, [sessionID])
    XCTAssertEqual(linkedSecond.summary.sessionIDs, [sessionID])
    XCTAssertEqual(linkedFirst.summary.event.revision, firstRevisionBeforeLink)

    try await store.moveSessions(
      [sessionID],
      from: first.id,
      to: second.id,
      evidence: .manual(at: Date(timeIntervalSince1970: 31))
    )
    let firstAfterMove = try await store.eventDetail(id: first.id)
    let secondAfterMove = try await store.eventDetail(id: second.id)
    let organizationAfterMove = try await store.eventOrganizationSessions()
    XCTAssertEqual(try XCTUnwrap(firstAfterMove).summary.sessionIDs, [])
    XCTAssertEqual(
      try XCTUnwrap(secondAfterMove).summary.sessionIDs,
      [sessionID]
    )
    XCTAssertEqual(
      organizationAfterMove.first?.rejectedEventIDs,
      Set([first.id])
    )
    let moveUndone = try await store.undoLastEventEdit()
    XCTAssertTrue(moveUndone)
    let firstAfterUndo = try await store.eventDetail(id: first.id)
    let organizationAfterUndo = try await store.eventOrganizationSessions()
    XCTAssertEqual(
      try XCTUnwrap(firstAfterUndo).summary.sessionIDs,
      [sessionID]
    )
    XCTAssertEqual(
      organizationAfterUndo.first?.rejectedEventIDs,
      Set<EventID>()
    )
    try await store.checkpointAndClose()
  }

  func testDismissedCandidateDoesNotReappearAfterOrganizerReplacement()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(975))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let date = Date(timeIntervalSince1970: 40)
    let candidate = EventCandidate(
      id: EventCandidateID(persistenceUUID(976)),
      sessionID: sessionID,
      candidateEventID: nil,
      proposedTitle: "Design review",
      evidence: EventLinkEvidence(
        semanticScore: 0.7,
        temporalScore: 1,
        peopleScore: 0,
        sourceScore: 0.4,
        aggregateScore: 0.7,
        modelIdentifier: "test-local-model",
        evaluatedAt: date
      ),
      createdAt: date,
      updatedAt: date
    )
    try await store.replacePendingEventCandidates([candidate])
    try await store.dismissEventCandidate(id: candidate.id)
    var remainingCandidates = try await store.eventCandidates()
    XCTAssertTrue(remainingCandidates.isEmpty)

    let dismissalUndone = try await store.undoLastEventEdit()
    remainingCandidates = try await store.eventCandidates()
    XCTAssertTrue(dismissalUndone)
    XCTAssertEqual(remainingCandidates, [candidate])

    try await store.dismissEventCandidate(id: candidate.id)
    try await store.replacePendingEventCandidates([candidate])
    remainingCandidates = try await store.eventCandidates()
    XCTAssertTrue(
      remainingCandidates.isEmpty,
      "A fresh organizer pass must still respect the user's dismissal."
    )
    try await store.checkpointAndClose()
  }

  func testAutomaticLinkDoesNotReplaceTheLastUserUndoOperation() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let firstSession = SessionID(persistenceUUID(982))
    let automaticallyLinkedSession = SessionID(persistenceUUID(983))
    try await store.create(preparingSnapshot(sessionID: firstSession))
    try await store.create(preparingSnapshot(sessionID: automaticallyLinkedSession))
    let event = try await store.createEvent(
      title: "Local memory",
      notes: "",
      sessionIDs: [firstSession]
    )
    let date = Date(timeIntervalSince1970: 60)
    try await store.linkSessions(
      [automaticallyLinkedSession],
      to: event.id,
      source: .automatic,
      evidence: EventLinkEvidence(
        semanticScore: 0.95,
        temporalScore: 0.95,
        peopleScore: 0,
        sourceScore: 0.8,
        aggregateScore: 0.92,
        modelIdentifier: "fixture-local-organizer",
        evaluatedAt: date
      )
    )

    let didUndo = try await store.undoLastEventEdit()
    let removedEvent = try await store.eventDetail(id: event.id)
    let retainedSession = try await store.load(
      sessionID: automaticallyLinkedSession
    )
    XCTAssertTrue(didUndo)
    XCTAssertNil(removedEvent)
    XCTAssertNotNil(retainedSession)
    try await store.checkpointAndClose()
  }

  func testCandidateAndRejectedPeopleNeverBecomeEventRelationships() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(984))
    try await store.create(preparingSnapshot(sessionID: sessionID))

    let confirmedPersonID = PersonID(persistenceUUID(985))
    let candidatePersonID = PersonID(persistenceUUID(986))
    let rejectedPersonID = PersonID(persistenceUUID(987))
    for personID in [confirmedPersonID, candidatePersonID, rejectedPersonID] {
      try await store.ensureLocalSelfPerson(personID: personID)
    }

    let workerID = persistenceUUID(988)
    let trackID = persistenceUUID(989)
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID,
      audio: [
        AudioRangeInput(
          sourceID: sessionID.rawValue,
          trackID: trackID,
          assetReference: "sessions/fixture/journal/chunks/00000.pcm",
          contentDigest: String(repeating: "f", count: 64),
          monotonicStartNanoseconds: 1_000_000_000,
          monotonicEndNanoseconds: 4_000_000_000,
          sampleRateHertz: 48_000,
          channelCount: 1
        )
      ],
      inputRevision: 1,
      modelArtifactKey: "fixture-speaker",
      embeddingSpaceID: "fixture-space",
      configHash: try persistenceDigest("f")
    )
    let claimedJob = try await store.claimNextSpeakerFinalJob(workerID: workerID)
    let claimed = try XCTUnwrap(claimedJob)
    let revision = try Revision(1)
    let associations: [(PersonID, PersonAssociationStatus, Confidence?)] = [
      (confirmedPersonID, .userConfirmed, nil),
      (candidatePersonID, .candidate, try Confidence(0.72)),
      (rejectedPersonID, .rejected, nil),
    ]
    let speakers = associations.enumerated().map { index, _ in
      SessionSpeaker(
        id: SessionSpeakerID(persistenceUUID(UInt64(990 + index))),
        sessionID: sessionID,
        revision: revision,
        stableOrdinal: UInt32(index + 1)
      )
    }
    let occurrences = try zip(speakers, associations).enumerated().map {
      index, pair in
      let (speaker, association) = pair
      return SpeakerOccurrence(
        id: SpeakerOccurrenceID(persistenceUUID(UInt64(993 + index))),
        sessionID: sessionID,
        sessionSpeakerID: speaker.id,
        revision: revision,
        trackIDs: [],
        monotonicStartNanoseconds: UInt64(index + 1) * 1_000_000_000,
        monotonicEndNanoseconds: UInt64(index + 2) * 1_000_000_000,
        overlapsAnotherSpeaker: false,
        association: try PersonAssociation(
          status: association.1,
          personID: association.0,
          confidence: association.2,
          evidenceRevision: revision
        )
      )
    }
    try await store.completeSpeakerFinalJob(
      jobID: claimed.job.id,
      workerID: workerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: sessionID,
        sessionSpeakers: speakers,
        occurrences: occurrences,
        embeddings: []
      )
    )
    let event = try await store.createEvent(
      title: "Identity filtering",
      notes: "",
      sessionIDs: [sessionID]
    )

    let loadedDetail = try await store.eventDetail(id: event.id)
    let detail = try XCTUnwrap(loadedDetail)
    XCTAssertEqual(detail.summary.personIDs, [confirmedPersonID])
    XCTAssertEqual(detail.personLinks.map(\.personID), [confirmedPersonID])
    let organizationSessions = try await store.eventOrganizationSessions()
    let organizationSession = try XCTUnwrap(organizationSessions.first)
    XCTAssertEqual(organizationSession.personIDs, Set([confirmedPersonID]))
    try await store.checkpointAndClose()
  }

  func testEventDocumentSearchProvenanceStalenessAndExplicitDeletion()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(977))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let firstTranscriptID = TranscriptRevisionID(persistenceUUID(978))
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: firstTranscriptID,
          segmentIDs: [],
          text: "We discussed the launch schedule.",
          modelArtifactID: "fixture-asr"
        ),
        inputRevision: 1,
        configHash: try persistenceDigest("d"),
        createdAt: Date(timeIntervalSince1970: 50)
      )
    )
    let event = try await store.createEvent(
      title: "Launch planning",
      notes: "",
      sessionIDs: [sessionID]
    )
    let eventDetail = try await store.eventDetail(id: event.id)
    let eventRevision = try XCTUnwrap(eventDetail).summary.event.revision
    let sourceID = firstTranscriptID.rawValue
    let document = EventTextDocumentRecord(
      id: persistenceUUID(979),
      eventID: event.id,
      eventRevision: eventRevision,
      taskID: .structuredSummary,
      modelArtifactID: "fixture-local-text",
      configHash: try persistenceDigest("e"),
      sourceReferences: [
        EventTextSourceReference(
          sessionID: sessionID,
          transcriptRevisionID: firstTranscriptID,
          sourceRevision: try Revision(1),
          segmentIDs: [sourceID]
        )
      ],
      result: LocalTextResult(
        modelArtifactID: "fixture-local-text",
        taskID: .structuredSummary,
        outputText: "Project Galaxy launch is scheduled.",
        claims: [
          LocalTextClaim(
            claimID: persistenceUUID(980),
            text: "Project Galaxy launch is scheduled.",
            sourceSegmentIDs: [sourceID],
            confidence: 0.9
          )
        ]
      ),
      createdAt: Date(timeIntervalSince1970: 51)
    )
    try await store.saveEventTextDocument(document)
    try await store.saveEventTextDocument(document)
    let identicalRetry = try await store.eventTextDocuments(eventID: event.id)
    XCTAssertEqual(identicalRetry.count, 1)
    XCTAssertEqual(identicalRetry.first?.createdAt, document.createdAt)
    let conflictingDocument = EventTextDocumentRecord(
      id: document.id,
      eventID: document.eventID,
      eventRevision: document.eventRevision,
      taskID: document.taskID,
      modelArtifactID: document.modelArtifactID,
      configHash: document.configHash,
      sourceReferences: document.sourceReferences,
      result: LocalTextResult(
        modelArtifactID: document.modelArtifactID,
        taskID: document.taskID,
        outputText: "A different result must have a different identity.",
        claims: []
      ),
      createdAt: Date(timeIntervalSince1970: 51.5)
    )
    do {
      try await store.saveEventTextDocument(conflictingDocument)
      XCTFail("an existing result cannot be overwritten under the same ID")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let matchingHistory = try await store.searchHistory(
      query: "Galaxy",
      mode: nil,
      status: nil
    )
    XCTAssertEqual(matchingHistory.map(\.sessionID), [sessionID])

    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: TranscriptRevisionID(persistenceUUID(981)),
          segmentIDs: [],
          text: "The schedule changed.",
          modelArtifactID: "fixture-asr"
        ),
        inputRevision: 2,
        configHash: try persistenceDigest("d"),
        createdAt: Date(timeIntervalSince1970: 52)
      )
    )
    let staleDocuments = try await store.eventTextDocuments(eventID: event.id)
    XCTAssertEqual(staleDocuments.first?.state, .stale)
    do {
      try await store.saveEventTextDocument(document)
      XCTFail("an in-flight old result cannot revive after its source changes")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let revisedSource = TranscriptRevisionID(persistenceUUID(981))
    let revisedDocument = EventTextDocumentRecord(
      id: persistenceUUID(982),
      eventID: event.id,
      eventRevision: eventRevision,
      taskID: .structuredSummary,
      modelArtifactID: document.modelArtifactID,
      configHash: document.configHash,
      sourceReferences: [
        EventTextSourceReference(
          sessionID: sessionID,
          transcriptRevisionID: revisedSource,
          sourceRevision: try Revision(2),
          segmentIDs: [revisedSource.rawValue]
        )
      ],
      result: LocalTextResult(
        modelArtifactID: document.modelArtifactID,
        taskID: .structuredSummary,
        outputText: "The schedule changed.",
        claims: [
          LocalTextClaim(
            claimID: persistenceUUID(983),
            text: "The schedule changed.",
            sourceSegmentIDs: [revisedSource.rawValue]
          )
        ]
      ),
      createdAt: Date(timeIntervalSince1970: 52.5)
    )
    try await store.saveEventTextDocument(revisedDocument)
    let revisedDocuments = try await store.eventTextDocuments(eventID: event.id)
    XCTAssertEqual(revisedDocuments.count, 2)
    XCTAssertEqual(revisedDocuments.filter { $0.state == .current }.map(\.id), [revisedDocument.id])
    XCTAssertEqual(revisedDocuments.first(where: { $0.id == document.id })?.result, document.result)

    _ = try await store.saveUserTranscriptEdit(
      sessionID: sessionID,
      content: "The manually corrected schedule.",
      createdAt: Date(timeIntervalSince1970: 53)
    )
    let afterWholeTextEdit = try await store.eventTextDocuments(eventID: event.id)
    XCTAssertEqual(afterWholeTextEdit.count, 2)
    XCTAssertTrue(afterWholeTextEdit.allSatisfy { $0.state == .stale })

    try await store.deleteSessionRecordsExplicitly(sessionID: sessionID)
    let deletedSession = try await store.load(sessionID: sessionID)
    let deletedSourceDocuments = try await store.eventTextDocuments(
      eventID: event.id
    )
    let survivingEvent = try await store.eventDetail(id: event.id)
    XCTAssertNil(deletedSession)
    XCTAssertTrue(deletedSourceDocuments.isEmpty)
    XCTAssertEqual(try XCTUnwrap(survivingEvent).summary.sessionIDs, [])
    try await store.checkpointAndClose()
  }
}
