import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import XCTest

final class HistoryRerecognitionTests: XCTestCase {
  func testAllFourModesPublishResumableSpeakerWorkWithTheNewText() async throws {
    let modes: [SessionInputMode] = [.dictation, .roomMicrophone, .systemAudio, .importedMedia]
    for mode in modes {
      let fixture = try await makeFixture(mode: mode)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let replacement = try commit(sessionID: fixture.sessionID, revision: 2)
      let jobValue = try await publish(replacement, in: fixture, audio: fixture.audio)
      let job = try XCTUnwrap(jobValue)
      XCTAssertEqual(job.kind, .speakerFinal)
      XCTAssertEqual(job.inputRevision.value, 2)
      let duplicate = try await publish(replacement, in: fixture, audio: fixture.audio)
      XCTAssertEqual(duplicate, job)
      try await fixture.store.checkpointAndClose()

      let reopened = try GRDBDictationStore(databaseURL: fixture.databaseURL)
      let storedJob = try await reopened.speakerFinalJob(id: job.id)
      XCTAssertEqual(storedJob?.state, .queued)
      let claimedValue = try await reopened.claimNextSpeakerFinalJob(workerID: UUID())
      let claimed = try XCTUnwrap(claimedValue)
      XCTAssertEqual(claimed.job.id, job.id)
      XCTAssertEqual(claimed.session.inputMode, mode)
      XCTAssertEqual(claimed.audio, fixture.audio)
      XCTAssertEqual(claimed.modelArtifactKey, "speaker-repair-v2")
      let transcripts = try await reopened.loadTranscripts(sessionID: fixture.sessionID)
      XCTAssertEqual(
        Set(transcripts.map(\.id)),
        [fixture.original.transcript.revisionID, replacement.transcript.revisionID])
      let history = try await reopened.loadHistory()
      XCTAssertEqual(history.first?.sourceAudioRetained, true)
      try await reopened.checkpointAndClose()
    }
  }

  func testConflictingSpeakerInputRollsBackTheNewTranscript() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let replacement = try commit(sessionID: fixture.sessionID, revision: 2)
    let otherAudio = audio(sessionID: fixture.sessionID, trackID: fixture.trackID, digest: "b")
    _ = try await fixture.store.scheduleSpeakerFinalWork(
      sessionID: fixture.sessionID, audio: otherAudio, inputRevision: 2,
      modelArtifactKey: "speaker-repair-v2", embeddingSpaceID: "unchanged-space-v1",
      configHash: try persistenceDigest("f")
    )
    do {
      _ = try await publish(replacement, in: fixture, audio: fixture.audio)
      XCTFail("Text must not commit without its matching resumable speaker input")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let transcripts = try await fixture.store.loadTranscripts(sessionID: fixture.sessionID)
    XCTAssertEqual(transcripts.map(\.id), [fixture.original.transcript.revisionID])
    let claimed = try await fixture.store.claimNextSpeakerFinalJob(workerID: UUID())
    XCTAssertEqual(claimed?.audio, otherAudio)
    try await fixture.store.checkpointAndClose()
  }

  func testConcurrentNewerTextWinsOverAnOlderRerecognitionResult() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lateASR = try commit(sessionID: fixture.sessionID, revision: 2)
    let newerUserText = try commit(sessionID: fixture.sessionID, revision: 2)
    try await fixture.store.commitTranscriptRevision(newerUserText)
    do {
      _ = try await publish(lateASR, in: fixture, audio: fixture.audio)
      XCTFail("A late result must not supersede a newer edit")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let transcripts = try await fixture.store.loadTranscripts(sessionID: fixture.sessionID)
    XCTAssertEqual(
      Set(transcripts.map(\.id)),
      [fixture.original.transcript.revisionID, newerUserText.transcript.revisionID])
    let jobCount = try await fixture.store.jobCount(sessionID: fixture.sessionID)
    XCTAssertEqual(jobCount, 0)
    try await fixture.store.checkpointAndClose()
  }

  func testExplicitSourceDeletionPreventsPublishingTextAndSpeakerWork() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.store.markSessionSourceAudioExplicitlyDeleted(sessionID: fixture.sessionID)
    do {
      _ = try await publish(
        try commit(sessionID: fixture.sessionID, revision: 2), in: fixture, audio: fixture.audio)
      XCTFail("An in-flight operation must respect explicit source deletion")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let transcripts = try await fixture.store.loadTranscripts(sessionID: fixture.sessionID)
    XCTAssertEqual(transcripts.map(\.id), [fixture.original.transcript.revisionID])
    let jobCount = try await fixture.store.jobCount(sessionID: fixture.sessionID)
    XCTAssertEqual(jobCount, 0)
    try await fixture.store.checkpointAndClose()
  }

  func testRerecognitionPreservesUserConfirmedIdentityDecisions() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let speaker = try await seedSpeaker(in: fixture)
    _ = try await fixture.store.confirmSessionSpeaker(
      sessionSpeakerID: speaker.sessionSpeakers[0].id, personID: nil,
      newDisplayName: "Confirmed fixture person", originDeviceID: UUID()
    )
    let before = try await fixture.store.sessionOccurrenceSummaries(sessionID: fixture.sessionID)
    let replacement = try commit(sessionID: fixture.sessionID, revision: 2)
    let followUp = try await publish(replacement, in: fixture, audio: fixture.audio)
    XCTAssertNil(followUp, "User decisions are preserved, not silently re-clustered")
    let after = try await fixture.store.sessionOccurrenceSummaries(sessionID: fixture.sessionID)
    XCTAssertEqual(after, before)
    let transcripts = try await fixture.store.loadTranscripts(sessionID: fixture.sessionID)
    XCTAssertEqual(transcripts.count, 2)
    let jobCount = try await fixture.store.jobCount(sessionID: fixture.sessionID)
    XCTAssertEqual(jobCount, 1, "Only the original already-completed speaker job remains")
    try await fixture.store.checkpointAndClose()
  }

  func testPersonConfirmedDuringInferenceCannotLoseItsSourceAnchor() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let oldSpeaker = try await seedSpeaker(in: fixture)
    let followUpValue = try await publish(
      try commit(sessionID: fixture.sessionID, revision: 2), in: fixture, audio: fixture.audio)
    let followUp = try XCTUnwrap(followUpValue)
    let workerID = UUID()
    let claimed = try await fixture.store.claimNextSpeakerFinalJob(workerID: workerID)
    XCTAssertEqual(claimed?.job.id, followUp.id)
    _ = try await fixture.store.confirmSessionSpeaker(
      sessionSpeakerID: oldSpeaker.sessionSpeakers[0].id, personID: nil,
      newDisplayName: "Confirmed during inference", originDeviceID: UUID()
    )
    let before = try await fixture.store.sessionOccurrenceSummaries(sessionID: fixture.sessionID)
    do {
      try await fixture.store.completeSpeakerFinalJob(
        jobID: followUp.id, workerID: workerID,
        commit: speakerCommit(in: fixture, revision: 2)
      )
      XCTFail("A replacement cluster must not discard a newly confirmed source anchor")
    } catch BestASRPersistenceError.processingCommitConflict {}
    let after = try await fixture.store.sessionOccurrenceSummaries(sessionID: fixture.sessionID)
    XCTAssertEqual(after, before)
    try await fixture.store.checkpointAndClose()
  }

  private struct Fixture {
    let root: URL
    let databaseURL: URL
    let store: GRDBDictationStore
    let sessionID: SessionID
    let trackID: UUID
    let audio: [AudioRangeInput]
    let original: DictationTranscriptRevisionCommit
  }

  private func makeFixture(mode: SessionInputMode = .dictation) async throws -> Fixture {
    let root = try persistenceTemporaryDirectory()
    let databaseURL = root.appendingPathComponent("store.sqlite")
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let sessionID = SessionID()
    let trackID = UUID()
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: mode)
    let original = try commit(sessionID: sessionID, revision: 1)
    try await store.commitTranscriptRevision(original)
    return Fixture(
      root: root, databaseURL: databaseURL, store: store, sessionID: sessionID,
      trackID: trackID, audio: audio(sessionID: sessionID, trackID: trackID), original: original)
  }

  private func audio(sessionID: SessionID, trackID: UUID, digest: Character = "a")
    -> [AudioRangeInput]
  {
    [
      AudioRangeInput(
        sourceID: sessionID.rawValue, trackID: trackID,
        assetReference: "sessions/fixture/journal/source.pcm",
        contentDigest: String(repeating: String(digest), count: 64),
        monotonicStartNanoseconds: 1_000_000_000,
        monotonicEndNanoseconds: 4_000_000_000, sampleRateHertz: 48_000, channelCount: 1)
    ]
  }

  private func commit(sessionID: SessionID, revision: UInt64) throws
    -> DictationTranscriptRevisionCommit
  {
    DictationTranscriptRevisionCommit(
      sessionID: sessionID,
      transcript: DictationTranscriptResult(
        revisionID: TranscriptRevisionID(), segmentIDs: [],
        text: "Synthetic revision \(revision)", modelArtifactID: "fixture-asr"),
      inputRevision: revision, configHash: try persistenceDigest(),
      createdAt: Date(timeIntervalSince1970: Double(revision))
    )
  }

  private func publish(
    _ commit: DictationTranscriptRevisionCommit, in fixture: Fixture,
    audio: [AudioRangeInput]
  ) async throws -> DurableJob? {
    try await fixture.store.commitRerecognizedTranscriptRevision(
      commit, sourceAudio: audio, speakerModelArtifactKey: "speaker-repair-v2",
      embeddingSpaceID: "unchanged-space-v1", speakerConfigHash: try persistenceDigest("f")
    )
  }

  private func seedSpeaker(in fixture: Fixture) async throws -> SpeakerFinalPersistenceCommit {
    let workerID = UUID()
    _ = try await fixture.store.scheduleSpeakerFinalWork(
      sessionID: fixture.sessionID, audio: fixture.audio, inputRevision: 1,
      modelArtifactKey: "speaker-repair-v1", embeddingSpaceID: "unchanged-space-v1",
      configHash: try persistenceDigest("e")
    )
    let claimedValue = try await fixture.store.claimNextSpeakerFinalJob(workerID: workerID)
    let claimed = try XCTUnwrap(claimedValue)
    let speaker = try speakerCommit(in: fixture, revision: 1)
    try await fixture.store.completeSpeakerFinalJob(
      jobID: claimed.job.id, workerID: workerID, commit: speaker)
    return speaker
  }

  private func speakerCommit(in fixture: Fixture, revision value: UInt64) throws
    -> SpeakerFinalPersistenceCommit
  {
    let speakerID = SessionSpeakerID()
    let revision = try Revision(value)
    return SpeakerFinalPersistenceCommit(
      sessionID: fixture.sessionID,
      sessionSpeakers: [
        SessionSpeaker(
          id: speakerID, sessionID: fixture.sessionID, revision: revision, stableOrdinal: 1)
      ],
      occurrences: [
        SpeakerOccurrence(
          id: SpeakerOccurrenceID(), sessionID: fixture.sessionID,
          sessionSpeakerID: speakerID, revision: revision, trackIDs: [TrackID(fixture.trackID)],
          monotonicStartNanoseconds: 1_000_000_000, monotonicEndNanoseconds: 4_000_000_000,
          overlapsAnotherSpeaker: false,
          association: try PersonAssociation(
            status: .unknown, personID: nil, confidence: nil, evidenceRevision: revision))
      ],
      embeddings: []
    )
  }
}
