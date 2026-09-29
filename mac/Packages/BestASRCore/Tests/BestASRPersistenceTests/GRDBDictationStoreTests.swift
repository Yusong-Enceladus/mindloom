import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import XCTest

final class GRDBDictationStoreTests: XCTestCase {
  func testPersonEmbeddingLookupQualifiesJoinedOrderingColumns() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )

    let embeddings = try await store.loadPersonEmbeddings(
      embeddingSpaceID: "fluid-community1-embedding-256-v1"
    )

    XCTAssertTrue(embeddings.isEmpty)
    try await store.checkpointAndClose()
  }

  func testLocalTextClaimExclusionLetsAnotherSessionRunAfterFailure()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let firstSessionID = SessionID(persistenceUUID(920))
    let secondSessionID = SessionID(persistenceUUID(921))
    for sessionID in [firstSessionID, secondSessionID] {
      try await store.create(
        preparingSnapshot(sessionID: sessionID),
        inputMode: .roomMicrophone
      )
      _ = try await store.scheduleDefaultLocalTextWork(
        sessionID: sessionID,
        inputRevision: 1,
        modelArtifactKey: "local-text-v1",
        configHash: try persistenceDigest("e")
      )
    }
    let workerID = persistenceUUID(922)
    let firstClaim = try await store.claimNextDefaultLocalTextJob(
      workerID: workerID,
      modelArtifactKey: "local-text-v1"
    )
    let first = try XCTUnwrap(firstClaim)
    try await store.failDefaultLocalTextJob(
      jobID: first.job.id,
      workerID: workerID,
      category: .transientWorker,
      retryable: true
    )

    let secondClaim = try await store.claimNextDefaultLocalTextJob(
      workerID: workerID,
      excludingJobIDs: [first.job.id],
      modelArtifactKey: "local-text-v1"
    )
    let second = try XCTUnwrap(secondClaim)

    XCTAssertNotEqual(second.job.id, first.job.id)
    XCTAssertNotEqual(second.sessionID, first.sessionID)
    try await store.checkpointAndClose()
  }

  func testLocalTextConfigurationUpgradeRequeuesExactlyOnce() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(923))
    try await store.create(
      preparingSnapshot(sessionID: sessionID),
      inputMode: .roomMicrophone
    )
    _ = try await store.scheduleDefaultLocalTextWork(
      sessionID: sessionID,
      inputRevision: 1,
      modelArtifactKey: "local-text-v1",
      configHash: try persistenceDigest("a")
    )
    let workerID = persistenceUUID(924)
    let originalClaim = try await store.claimNextDefaultLocalTextJob(
      workerID: workerID,
      modelArtifactKey: "local-text-v1"
    )
    let original = try XCTUnwrap(originalClaim)
    try await store.failDefaultLocalTextJob(
      jobID: original.job.id,
      workerID: workerID,
      category: .corruptInput,
      retryable: false
    )

    let upgradedHash = try persistenceDigest("b")
    let firstCount = try await store.requeueDefaultLocalTextJobsForConfiguration(
      modelArtifactKey: "local-text-v1",
      configHash: upgradedHash
    )
    let secondCount = try await store.requeueDefaultLocalTextJobsForConfiguration(
      modelArtifactKey: "local-text-v1",
      configHash: upgradedHash
    )
    let upgradedClaim = try await store.claimNextDefaultLocalTextJob(
      workerID: workerID,
      modelArtifactKey: "local-text-v1"
    )
    let upgraded = try XCTUnwrap(upgradedClaim)

    XCTAssertEqual(firstCount, 1)
    XCTAssertEqual(secondCount, 0)
    XCTAssertEqual(upgraded.job.id, original.job.id)
    XCTAssertEqual(upgraded.job.configHash, upgradedHash)
    XCTAssertEqual(upgraded.job.retryCount, 0)
    try await store.checkpointAndClose()
  }

  func testExplicitDeletionDeletesParentedTranscriptChainAtomically()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(910))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let parentID = TranscriptRevisionID(persistenceUUID(911))
    try await store.save(
      transcript: TranscriptRevision(
        id: parentID,
        sessionID: sessionID,
        revision: try Revision(1),
        parentID: nil,
        kind: .streaming,
        content: "draft",
        modelArtifactID: nil,
        configHash: try persistenceDigest("d"),
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await store.save(
      transcript: TranscriptRevision(
        id: TranscriptRevisionID(persistenceUUID(912)),
        sessionID: sessionID,
        revision: try Revision(2),
        parentID: parentID,
        kind: .final,
        content: "final",
        modelArtifactID: nil,
        configHash: try persistenceDigest("f"),
        createdAt: Date(timeIntervalSince1970: 101)
      )
    )

    try await store.deleteSessionRecordsExplicitly(sessionID: sessionID)

    let deletedSession = try await store.load(sessionID: sessionID)
    let deletedTranscripts = try await store.loadTranscripts(
      sessionID: sessionID
    )
    let remainingModes = try await store.sessionModes()
    XCTAssertNil(deletedSession)
    XCTAssertTrue(deletedTranscripts.isEmpty)
    XCTAssertTrue(remainingModes.isEmpty)
    try await store.checkpointAndClose()
  }

  func testCancelEphemeralDeletesParentedLiveTranscriptChain() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(900))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let draftID = TranscriptRevisionID(persistenceUUID(901))
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: persistenceUUID(903),
        assetReference: "sessions/fixture/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "d", count: 64),
        monotonicStartNanoseconds: 100,
        monotonicEndNanoseconds: 200,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    let draft = DictationTranscriptResult(
      revisionID: draftID,
      segmentIDs: [],
      text: "draft",
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .streaming,
        languageHints: ["en-US"],
        audioRanges: audio,
        segments: []
      )
    )
    let sentence = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(902)),
      segmentIDs: [],
      text: "sentence",
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: draftID,
        kind: .sentence,
        languageHints: ["en-US"],
        audioRanges: audio,
        segments: []
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: draft,
        inputRevision: 1,
        configHash: try persistenceDigest("c"),
        createdAt: Date(timeIntervalSince1970: 300)
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: sentence,
        inputRevision: 2,
        configHash: try persistenceDigest("c"),
        createdAt: Date(timeIntervalSince1970: 301)
      )
    )

    try await store.cancelEphemeral(sessionID: sessionID)

    let cancelled = try await store.load(sessionID: sessionID)
    let transcripts = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertNil(cancelled)
    XCTAssertTrue(transcripts.isEmpty)
  }

  func testHistorySeparatesRawPolishedProcessingFailedAndRecoveredState()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let completedID = SessionID(persistenceUUID(850))
    let failedID = SessionID(persistenceUUID(851))
    let processingID = SessionID(persistenceUUID(852))
    let nonretryableID = SessionID(persistenceUUID(855))
    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(853)),
      segmentIDs: [persistenceUUID(854)],
      text: "raw fixture",
      modelArtifactID: "fixture-asr"
    )
    let polish = DictationPolishResult(
      sourceRevisionID: transcript.revisionID,
      text: "Raw fixture.",
      disposition: .punctuationOnlyFallback,
      modelArtifactID: nil
    )
    let insertion = DictationInsertionResult(
      idempotencyKey: try DictationIdempotencyKey("insert:history:1"),
      method: .retainedForCopy,
      inserted: false
    )
    let completedPreparing = try preparingSnapshot(sessionID: completedID)
    try await store.create(completedPreparing)
    try await store.save(
      DictationSessionSnapshot(
        sessionID: completedID,
        revision: 2,
        phase: .completed,
        target: completedPreparing.target,
        timeline: completedPreparing.timeline,
        transcript: transcript,
        polish: polish,
        insertion: insertion
      )
    )
    try await store.markRecovered(sessionID: completedID)
    try await store.markRecovered(sessionID: completedID)

    let failedPreparing = try preparingSnapshot(sessionID: failedID)
    try await store.create(failedPreparing)
    try await store.save(
      DictationSessionSnapshot(
        sessionID: failedID,
        revision: 2,
        phase: .failedRecoverable,
        target: failedPreparing.target,
        timeline: failedPreparing.timeline,
        failure: try DictationFailure(
          stage: .recognition,
          category: .modelUnavailable,
          code: "fixture-model-unavailable",
          retryable: true,
          recoveryPhase: .recognizing
        )
      )
    )
    try await store.create(preparingSnapshot(sessionID: processingID))
    let nonretryablePreparing = try preparingSnapshot(sessionID: nonretryableID)
    try await store.create(nonretryablePreparing)
    try await store.save(
      DictationSessionSnapshot(
        sessionID: nonretryableID,
        revision: 2,
        phase: .failedRecoverable,
        target: nonretryablePreparing.target,
        timeline: nonretryablePreparing.timeline,
        failure: try DictationFailure(
          stage: .journal,
          category: .corruptInput,
          code: "fixture-no-committed-audio",
          retryable: false,
          recoveryPhase: .finalizing
        )
      )
    )

    let history = try await store.loadHistory()
    let recovered = try XCTUnwrap(history.first { $0.sessionID == completedID })
    let failed = try XCTUnwrap(history.first { $0.sessionID == failedID })
    let processing = try XCTUnwrap(history.first { $0.sessionID == processingID })
    let nonretryable = try XCTUnwrap(
      history.first { $0.sessionID == nonretryableID }
    )

    XCTAssertEqual(recovered.status, .recovered)
    XCTAssertEqual(recovered.rawText, "raw fixture")
    XCTAssertEqual(recovered.polishedText, "Raw fixture.")
    XCTAssertEqual(recovered.preferredText, "Raw fixture.")
    XCTAssertFalse(recovered.canRetry)
    XCTAssertTrue(recovered.sourceAudioRetained)
    XCTAssertNotNil(recovered.recoveredAt)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.failureCode, "fixture-model-unavailable")
    XCTAssertTrue(failed.canRetry)
    XCTAssertEqual(processing.status, .processing)
    XCTAssertFalse(processing.canRetry)
    XCTAssertEqual(nonretryable.status, .failed)
    XCTAssertEqual(nonretryable.failureCode, "fixture-no-committed-audio")
    XCTAssertFalse(nonretryable.canRetry)
    try await store.checkpointAndClose()
  }

  func testHistoryDoesNotResurrectSnapshotPolishAfterReRecognition() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(856))
    let original = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(857)),
      segmentIDs: [],
      text: "old recognition",
      modelArtifactID: "fixture-asr"
    )
    let polish = DictationPolishResult(
      sourceRevisionID: original.revisionID,
      text: "Old polished recognition.",
      disposition: .punctuationOnlyFallback,
      modelArtifactID: nil
    )
    let preparing = try preparingSnapshot(sessionID: sessionID)
    try await store.create(preparing)
    try await store.save(
      DictationSessionSnapshot(
        sessionID: sessionID,
        revision: 2,
        phase: .completed,
        target: preparing.target,
        timeline: preparing.timeline,
        transcript: original,
        polish: polish,
        insertion: DictationInsertionResult(
          idempotencyKey: try DictationIdempotencyKey("insert:history:rerecognition"),
          method: .retainedForCopy,
          inserted: false
        )
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: original,
        inputRevision: 1,
        configHash: try persistenceDigest(),
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    let originalHistory = try await store.loadHistory()
    XCTAssertEqual(originalHistory.first?.preferredText, polish.text)

    let replacement = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(858)),
      segmentIDs: [],
      text: "新的中文识别结果",
      modelArtifactID: "fixture-asr"
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: replacement,
        inputRevision: 2,
        configHash: try persistenceDigest(),
        createdAt: Date(timeIntervalSince1970: 200)
      )
    )
    let history = try await store.loadHistory()
    let item = try XCTUnwrap(history.first)
    XCTAssertEqual(item.rawText, replacement.text)
    XCTAssertNil(item.polishedText)
    XCTAssertEqual(item.preferredText, replacement.text)
    XCTAssertTrue(item.sourceAudioRetained)
    let snapshot = try await store.load(sessionID: sessionID)
    XCTAssertEqual(snapshot?.polish, polish, "original evidence remains intact")
    let revisions = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(Set(revisions.map(\.id)), [original.revisionID, replacement.revisionID])
    try await store.checkpointAndClose()
  }

  func testAutomaticTitleFollowsReRecognitionWithoutOverwritingManualNames() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(859))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    try await store.setAutomaticSessionTitle(sessionID: sessionID, from: "旧的自动标题")
    try await store.setAutomaticSessionTitle(sessionID: sessionID, from: "新的自动标题")
    var history = try await store.loadHistory()
    XCTAssertEqual(history.first?.title, "新的自动标题")
    try await store.renameSession(sessionID: sessionID, title: "用户保存的标题")
    try await store.setAutomaticSessionTitle(sessionID: sessionID, from: "再次识别的自动标题")
    history = try await store.loadHistory()
    XCTAssertEqual(history.first?.title, "用户保存的标题")
    try await store.checkpointAndClose()
  }

  func testSingleSpeakerWorkUsesStableV1IdentityRecordsAndIsIdempotent()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("store.sqlite")
    let sessionID = SessionID(persistenceUUID(800))
    let trackID = persistenceUUID(801)
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: trackID,
        assetReference: "sessions/fixture/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "a", count: 64),
        monotonicStartNanoseconds: 100,
        monotonicEndNanoseconds: 200,
        sampleRateHertz: 48_000,
        channelCount: 1
      ),
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: trackID,
        assetReference: "sessions/fixture/journal/chunks/00001.pcm",
        contentDigest: String(repeating: "b", count: 64),
        monotonicStartNanoseconds: 200,
        monotonicEndNanoseconds: 300,
        sampleRateHertz: 48_000,
        channelCount: 1
      ),
    ]
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    try await store.create(preparingSnapshot(sessionID: sessionID))

    let first = try await store.scheduleSingleSpeakerWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: 1
    )
    let duplicate = try await store.scheduleSingleSpeakerWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: 1
    )

    XCTAssertEqual(duplicate, first)
    XCTAssertEqual(first.sessionSpeaker.sessionID, sessionID)
    XCTAssertEqual(first.sessionSpeaker.stableOrdinal, 1)
    XCTAssertEqual(first.occurrences.count, 2)
    XCTAssertEqual(
      first.occurrences.map(\.trackIDs),
      [[TrackID(trackID)], [TrackID(trackID)]]
    )
    XCTAssertTrue(
      first.occurrences.allSatisfy {
        $0.association.status == .unknown
          && $0.association.personID == nil
          && $0.association.confidence == nil
          && !$0.overlapsAnotherSpeaker
      })
    let jobCount = try await store.jobCount(sessionID: sessionID)
    XCTAssertEqual(first.job.kind, .speakerFinal)
    XCTAssertEqual(first.job.state, .queued)
    XCTAssertEqual(jobCount, 1)
    try await store.checkpointAndClose()

    let reopened = try GRDBDictationStore(databaseURL: databaseURL)
    let reopenedWork = try await reopened.loadSingleSpeakerWork(
      sessionID: sessionID
    )
    XCTAssertEqual(reopenedWork, first)
    try await reopened.checkpointAndClose()
  }

  func testLegacySpeakerJobWithoutInputIsQuarantinedWithoutStarvingValidWork()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let legacySessionID = SessionID(persistenceUUID(802))
    let validSessionID = SessionID(persistenceUUID(803))
    let workerID = persistenceUUID(804)
    try await store.create(preparingSnapshot(sessionID: legacySessionID))
    let legacyAudio = [
      AudioRangeInput(
        sourceID: legacySessionID.rawValue,
        trackID: persistenceUUID(805),
        assetReference: "sessions/legacy/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "c", count: 64),
        monotonicStartNanoseconds: 100,
        monotonicEndNanoseconds: 200,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    let legacy = try await store.scheduleSingleSpeakerWork(
      sessionID: legacySessionID,
      audio: legacyAudio,
      inputRevision: 1
    )

    let legacyClaim = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    XCTAssertNil(legacyClaim)
    let portable = try await store.exportPortablePersistenceState()
    let jobs = try XCTUnwrap(
      portable.tables.first(where: { $0.name == "durable_jobs" })
    )
    let idIndex = try XCTUnwrap(jobs.columns.firstIndex(of: "id"))
    let stateIndex = try XCTUnwrap(jobs.columns.firstIndex(of: "state"))
    let errorIndex = try XCTUnwrap(
      jobs.columns.firstIndex(of: "error_category")
    )
    let legacyRow = try XCTUnwrap(
      jobs.rows.first {
        $0[idIndex] == .text(legacy.job.id.rawValue.uuidString)
      }
    )
    XCTAssertEqual(
      legacyRow[stateIndex],
      .text(DurableJobState.permanentFailed.rawValue)
    )
    XCTAssertEqual(
      legacyRow[errorIndex],
      .text(DurableJobErrorCategory.corruptInput.rawValue)
    )

    try await store.create(preparingSnapshot(sessionID: validSessionID))
    let validAudio = [
      AudioRangeInput(
        sourceID: validSessionID.rawValue,
        trackID: persistenceUUID(806),
        assetReference: "sessions/valid/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "d", count: 64),
        monotonicStartNanoseconds: 300,
        monotonicEndNanoseconds: 400,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    let valid = try await store.scheduleSpeakerFinalWork(
      sessionID: validSessionID,
      audio: validAudio,
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("e")
    )
    let validClaim = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let claimed = try XCTUnwrap(validClaim)
    XCTAssertEqual(claimed.job.id, valid.id)
    XCTAssertEqual(claimed.session.id, validSessionID)
    try await store.checkpointAndClose()
  }

  func testSpeakerClaimExclusionLetsAnotherSessionRunAfterFailure() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let firstSessionID = SessionID(persistenceUUID(807))
    let secondSessionID = SessionID(persistenceUUID(808))
    let workerID = persistenceUUID(809)
    let fixtures: [(SessionID, UUID, Character)] = [
      (firstSessionID, persistenceUUID(810), "e"),
      (secondSessionID, persistenceUUID(811), "f"),
    ]
    for (sessionID, trackID, digestCharacter) in fixtures {
      try await store.create(preparingSnapshot(sessionID: sessionID))
      _ = try await store.scheduleSpeakerFinalWork(
        sessionID: sessionID,
        audio: [
          AudioRangeInput(
            sourceID: sessionID.rawValue,
            trackID: trackID,
            assetReference:
              "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/chunks/00000.pcm",
            contentDigest: String(repeating: digestCharacter, count: 64),
            monotonicStartNanoseconds: 100,
            monotonicEndNanoseconds: 200,
            sampleRateHertz: 48_000,
            channelCount: 1
          )
        ],
        inputRevision: 1,
        modelArtifactKey: "speaker-v1",
        embeddingSpaceID: "space-v1",
        configHash: try persistenceDigest(digestCharacter)
      )
    }

    let firstClaimValue = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let firstClaim = try XCTUnwrap(firstClaimValue)
    try await store.failSpeakerFinalJob(
      jobID: firstClaim.job.id,
      workerID: workerID,
      category: .transientWorker,
      retryable: true
    )
    let nextClaim = try await store.claimNextSpeakerFinalJob(
      workerID: workerID,
      excludingJobIDs: [firstClaim.job.id]
    )
    let secondClaim = try XCTUnwrap(nextClaim)
    XCTAssertNotEqual(secondClaim.job.id, firstClaim.job.id)
    XCTAssertNotEqual(secondClaim.session.id, firstClaim.session.id)
    try await store.checkpointAndClose()
  }

  func testPlatformNameEvidencePersistsAndSurvivesSpeakerModelRebuild()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(820))
    let speakerID = SessionSpeakerID(persistenceUUID(821))
    let occurrenceID = SpeakerOccurrenceID(persistenceUUID(822))
    let trackID = persistenceUUID(823)
    let workerID = persistenceUUID(824)
    let firstContextID = persistenceUUID(825)
    let secondContextID = persistenceUUID(826)
    try await store.create(
      preparingSnapshot(sessionID: sessionID),
      inputMode: .systemAudio
    )
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: trackID,
        assetReference:
          "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "a", count: 64),
        monotonicStartNanoseconds: 1_000_000_000,
        monotonicEndNanoseconds: 2_500_000_000,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("a")
    )
    for (id, timestamp) in [
      (firstContextID, UInt64(1_000_000_000)),
      (secondContextID, UInt64(2_000_000_000)),
    ] {
      try await store.saveSourceContext(
        SourceContextSnapshot(
          id: id,
          sessionID: sessionID,
          revision: try Revision(1),
          adapterID: "fixture-platform",
          sourceBundleID: "com.example.meeting",
          meetingTitle: "Fixture meeting",
          windowTitle: nil,
          participantDisplayNames: ["Alice", "Bob"],
          activeSpeakerDisplayName: "Alice",
          monotonicNanoseconds: timestamp,
          reliability: .reliable
        )
      )
    }
    let claimedJob = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let claimed = try XCTUnwrap(claimedJob)
    let speaker = SessionSpeaker(
      id: speakerID,
      sessionID: sessionID,
      revision: try Revision(1),
      stableOrdinal: 1
    )
    let occurrence = SpeakerOccurrence(
      id: occurrenceID,
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      revision: try Revision(1),
      trackIDs: [TrackID(trackID)],
      monotonicStartNanoseconds: 1_000_000_000,
      monotonicEndNanoseconds: 2_500_000_000,
      overlapsAnotherSpeaker: false,
      association: try PersonAssociation(
        status: .unknown,
        personID: nil,
        confidence: nil,
        evidenceRevision: try Revision(1)
      )
    )
    let evidence = PlatformSpeakerNameEvidence(
      id: persistenceUUID(827),
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      revision: try Revision(1),
      displayName: "Alice",
      occurrenceIDs: [occurrenceID],
      sourceContextIDs: [firstContextID, secondContextID],
      alignedSpeechNanoseconds: 1_500_000_000
    )
    let firstCommit = SpeakerFinalPersistenceCommit(
      sessionID: sessionID,
      sessionSpeakers: [speaker],
      occurrences: [occurrence],
      embeddings: [
        StoredSpeakerEmbedding(
          sessionSpeakerID: speakerID,
          revision: try Revision(1),
          embeddingSpaceID: "space-v1",
          vector: [1, 0, 0],
          speechDurationNanoseconds: 1_500_000_000,
          signalQuality: try Confidence(0.95),
          modelArtifactKey: "speaker-v1"
        )
      ],
      platformNameEvidence: [evidence]
    )
    try await store.completeSpeakerFinalJob(
      jobID: claimed.job.id,
      workerID: workerID,
      commit: firstCommit
    )
    let firstSummaries = try await store.sessionSpeakerSummaries(
      sessionID: sessionID
    )
    let firstSummary = try XCTUnwrap(firstSummaries.first)
    XCTAssertEqual(firstSummary.displayName, "Alice")
    XCTAssertEqual(firstSummary.associationStatus, .automaticMatch)
    let firstPersonID = try XCTUnwrap(firstSummary.personID)
    let portable = try await store.exportPortablePersistenceState()
    XCTAssertEqual(
      portable.tables.first(where: { $0.name == "speaker_name_evidence" })?
        .rows.count,
      1
    )

    let rebuiltCount = try await store.requeueAutomaticSpeakerJobs(
      modelArtifactKey: "speaker-v2",
      embeddingSpaceID: "space-v2",
      configHash: try persistenceDigest("b")
    )
    XCTAssertEqual(rebuiltCount, 1)
    let rebuiltJob = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let rebuilt = try XCTUnwrap(rebuiltJob)
    XCTAssertEqual(rebuilt.modelArtifactKey, "speaker-v2")
    XCTAssertEqual(rebuilt.embeddingSpaceID, "space-v2")
    XCTAssertEqual(rebuilt.job.configHash, try persistenceDigest("b"))
    let rebuiltCommit = SpeakerFinalPersistenceCommit(
      sessionID: sessionID,
      sessionSpeakers: [speaker],
      occurrences: [occurrence],
      embeddings: [
        StoredSpeakerEmbedding(
          sessionSpeakerID: speakerID,
          revision: try Revision(1),
          embeddingSpaceID: "space-v2",
          vector: [0.99, 0.01, 0],
          speechDurationNanoseconds: 1_500_000_000,
          signalQuality: try Confidence(0.96),
          modelArtifactKey: "speaker-v2"
        )
      ],
      platformNameEvidence: [evidence]
    )
    try await store.completeSpeakerFinalJob(
      jobID: rebuilt.job.id,
      workerID: workerID,
      commit: rebuiltCommit
    )
    let rebuiltSummaries = try await store.sessionSpeakerSummaries(
      sessionID: sessionID
    )
    let rebuiltSummary = try XCTUnwrap(rebuiltSummaries.first)
    XCTAssertEqual(rebuiltSummary.personID, firstPersonID)
    XCTAssertEqual(rebuiltSummary.displayName, "Alice")
    try await store.checkpointAndClose()
  }

  func testAnonymousPersonIDRemainsStableAcrossEmbeddingSpaces() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(840))
    let speakerID = SessionSpeakerID(persistenceUUID(841))
    let occurrenceID = SpeakerOccurrenceID(persistenceUUID(842))
    let trackID = persistenceUUID(843)
    let workerID = persistenceUUID(844)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: trackID,
        assetReference:
          "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "c", count: 64),
        monotonicStartNanoseconds: 1_000_000_000,
        monotonicEndNanoseconds: 2_000_000_000,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("c")
    )
    let speaker = SessionSpeaker(
      id: speakerID,
      sessionID: sessionID,
      revision: try Revision(1),
      stableOrdinal: 1
    )
    let occurrence = SpeakerOccurrence(
      id: occurrenceID,
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      revision: try Revision(1),
      trackIDs: [TrackID(trackID)],
      monotonicStartNanoseconds: 1_000_000_000,
      monotonicEndNanoseconds: 2_000_000_000,
      overlapsAnotherSpeaker: false,
      association: try PersonAssociation(
        status: .unknown,
        personID: nil,
        confidence: nil,
        evidenceRevision: try Revision(1)
      )
    )
    func commit(
      space: String,
      model: String
    ) throws -> SpeakerFinalPersistenceCommit {
      SpeakerFinalPersistenceCommit(
        sessionID: sessionID,
        sessionSpeakers: [speaker],
        occurrences: [occurrence],
        embeddings: [
          StoredSpeakerEmbedding(
            sessionSpeakerID: speakerID,
            revision: try Revision(1),
            embeddingSpaceID: space,
            vector: [1, 0],
            speechDurationNanoseconds: 1_000_000_000,
            signalQuality: try Confidence(0.9),
            modelArtifactKey: model
          )
        ]
      )
    }
    let firstJob = try await store.claimNextSpeakerFinalJob(workerID: workerID)
    let first = try XCTUnwrap(firstJob)
    try await store.completeSpeakerFinalJob(
      jobID: first.job.id,
      workerID: workerID,
      commit: try commit(space: "space-v1", model: "speaker-v1")
    )
    let originalSummaries = try await store.sessionSpeakerSummaries(
      sessionID: sessionID
    )
    let originalPersonID = try XCTUnwrap(originalSummaries.first?.personID)
    _ = try await store.requeueAutomaticSpeakerJobs(
      modelArtifactKey: "speaker-v2",
      embeddingSpaceID: "space-v2",
      configHash: try persistenceDigest("d")
    )
    let secondJob = try await store.claimNextSpeakerFinalJob(workerID: workerID)
    let second = try XCTUnwrap(secondJob)
    try await store.completeSpeakerFinalJob(
      jobID: second.job.id,
      workerID: workerID,
      commit: try commit(space: "space-v2", model: "speaker-v2")
    )
    let rebuiltSummaries = try await store.sessionSpeakerSummaries(
      sessionID: sessionID
    )
    let rebuiltPersonID = try XCTUnwrap(rebuiltSummaries.first?.personID)
    XCTAssertEqual(rebuiltPersonID, originalPersonID)
    try await store.checkpointAndClose()
  }

  func testSnapshotPersistsAcrossReopenAndRejectsNonMonotonicRevision() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("store.sqlite")
    let sessionID = SessionID(persistenceUUID(1))
    let initial = try preparingSnapshot(sessionID: sessionID)
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    try await store.create(initial)

    let recording = DictationSessionSnapshot(
      sessionID: sessionID,
      revision: 2,
      phase: .recording,
      target: try persistenceTarget(),
      timeline: initial.timeline
    )
    try await store.save(recording)
    await assertThrowsPersistenceError(.nonMonotonicRevision(current: 2, proposed: 2)) {
      try await store.save(recording)
    }
    let recoverable = try await store.loadRecoverable()
    XCTAssertEqual(recoverable, [recording])
    try await store.checkpointAndClose()

    let reopened = try GRDBDictationStore(databaseURL: databaseURL)
    let reloaded = try await reopened.load(sessionID: sessionID)
    XCTAssertEqual(reloaded, recording)
    try await reopened.checkpointAndClose()
  }

  func testInsertionReservationIsDurableAndAtMostOnce() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(10))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let key = try DictationIdempotencyKey("insert:10:1")
    let acquired = try await store.reserveInsertion(sessionID: sessionID, key: key)
    XCTAssertEqual(acquired, .acquired)
    let alreadyReserved = try await store.reserveInsertion(
      sessionID: sessionID,
      key: key
    )
    XCTAssertEqual(alreadyReserved, .alreadyReserved)
    let result = DictationInsertionResult(
      idempotencyKey: key,
      method: .accessibilityReplacement,
      inserted: true
    )
    try await store.completeInsertion(sessionID: sessionID, result: result)
    try await store.completeInsertion(sessionID: sessionID, result: result)
    let alreadyCompleted = try await store.reserveInsertion(
      sessionID: sessionID,
      key: key
    )
    XCTAssertEqual(alreadyCompleted, .alreadyCompleted)
    await assertThrowsPersistenceError(.insertionKeyConflict) {
      _ = try await store.reserveInsertion(
        sessionID: sessionID,
        key: DictationIdempotencyKey("insert:10:2")
      )
    }
    try await store.checkpointAndClose()
  }

  func testJobsAndDerivationsCommitAtomicallyAndBecomeStale() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(20))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let transcriptID = TranscriptRevisionID(persistenceUUID(21))
    let transcript = TranscriptRevision(
      id: transcriptID,
      sessionID: sessionID,
      revision: try Revision(1),
      parentID: nil,
      kind: .final,
      content: "fixture raw",
      modelArtifactID: nil,
      configHash: try persistenceDigest("c"),
      createdAt: Date(timeIntervalSince1970: 100)
    )
    try await store.save(transcript: transcript)
    let job = DurableJob(
      id: DurableJobID(persistenceUUID(22)),
      revision: try Revision(1),
      kind: .localText,
      state: .queued,
      inputRevision: try Revision(1),
      modelArtifactID: nil,
      configHash: try persistenceDigest("d"),
      retryCount: 0,
      errorCategory: .none,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    try await store.enqueue(job: job, sessionID: sessionID)
    let jobCount = try await store.jobCount(sessionID: sessionID)
    XCTAssertEqual(jobCount, 1)

    let derivation = DictationDerivedTextRecord(
      id: persistenceUUID(23),
      sessionID: sessionID,
      sourceTranscriptID: transcriptID,
      sourceRevision: try Revision(1),
      outputText: "Fixture raw.",
      modelArtifactID: "fixture-text",
      configHash: try persistenceDigest("e"),
      state: .current,
      createdAt: Date(timeIntervalSince1970: 101)
    )
    try await store.save(derivation: derivation)
    let currentDerivations = try await store.loadDerivations(sessionID: sessionID)
    XCTAssertEqual(currentDerivations, [derivation])
    let staleCount = try await store.markDerivationsStale(
      sessionID: sessionID,
      currentSourceTranscriptID: transcriptID,
      modelArtifactID: "replacement-text",
      configHash: try persistenceDigest("e")
    )
    XCTAssertEqual(staleCount, 1)
    let staleDerivations = try await store.loadDerivations(sessionID: sessionID)
    let stale = try XCTUnwrap(staleDerivations.first)
    XCTAssertEqual(stale.state, .stale)
    XCTAssertEqual(stale.outputText, derivation.outputText)
    try await store.checkpointAndClose()
  }

  func testRelativeAssetsRemainValidAfterCrossRootCopy() async throws {
    let sourceRoot = try persistenceTemporaryDirectory()
    let destinationParent = try persistenceTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationParent)
    }
    let databaseURL = sourceRoot.appendingPathComponent("store.sqlite")
    let sessionID = SessionID(persistenceUUID(30))
    let trackID = TrackID(persistenceUUID(31))
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    try await store.save(
      track: SourceTrack(
        id: trackID,
        sessionID: sessionID,
        revision: try Revision(1),
        role: .microphoneLocal,
        assetReference: PortableAssetReference(
          relativePath: "sessions/fixture/journal/manifest.json"
        ),
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    )
    try await store.save(
      chunk: AudioChunk(
        id: ChunkID(persistenceUUID(32)),
        sessionID: sessionID,
        trackID: trackID,
        revision: try Revision(1),
        sequence: 0,
        monotonicStartNanoseconds: 10,
        frameCount: 480,
        contentDigest: try persistenceDigest("f"),
        assetReference: PortableAssetReference(
          relativePath: "sessions/fixture/journal/chunks/chunk-0.pcm"
        )
      )
    )
    try await store.checkpointAndClose()

    let copiedRoot = destinationParent.appendingPathComponent("copied")
    try FileManager.default.copyItem(at: sourceRoot, to: copiedRoot)
    let copied = try GRDBDictationStore(
      databaseURL: copiedRoot.appendingPathComponent("store.sqlite")
    )
    let references = try await copied.assetReferences(sessionID: sessionID)
    XCTAssertEqual(
      references,
      [
        "sessions/fixture/journal/chunks/chunk-0.pcm",
        "sessions/fixture/journal/manifest.json",
      ]
    )
    XCTAssertFalse(references.contains { $0.hasPrefix("/") || $0.contains("..") })
    try await copied.checkpointAndClose()
  }

  func testDraftAndFinalReplacementPersistParentTimingAndLanguageProvenance()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(60))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue,
        trackID: persistenceUUID(61),
        assetReference: "sessions/fixture/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "a", count: 64),
        monotonicStartNanoseconds: 100,
        monotonicEndNanoseconds: 200,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ]
    let draftID = TranscriptRevisionID(persistenceUUID(62))
    let draftSegment = DictationTranscriptSegment(
      id: persistenceUUID(63),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      text: "draft",
      confidence: 0.8
    )
    let draft = DictationTranscriptResult(
      revisionID: draftID,
      segmentIDs: [draftSegment.id],
      text: "draft",
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .streaming,
        languageHints: ["zh-CN", "en-US"],
        audioRanges: audio,
        segments: [draftSegment]
      )
    )
    let finalSegment = DictationTranscriptSegment(
      id: persistenceUUID(64),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      text: "final",
      confidence: 0.9
    )
    let final = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(65)),
      segmentIDs: [finalSegment.id],
      text: "final",
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: draftID,
        kind: .final,
        languageHints: ["zh-CN", "en-US"],
        audioRanges: audio,
        segments: [finalSegment]
      )
    )
    let draftCommit = DictationTranscriptRevisionCommit(
      sessionID: sessionID,
      transcript: draft,
      inputRevision: 1,
      configHash: try persistenceDigest("b"),
      createdAt: Date(timeIntervalSince1970: 200)
    )
    let finalCommit = DictationTranscriptRevisionCommit(
      sessionID: sessionID,
      transcript: final,
      inputRevision: 2,
      configHash: try persistenceDigest("b"),
      createdAt: Date(timeIntervalSince1970: 201)
    )

    let draftAsFinalCommit = DictationRecognitionCommit(
      snapshot: DictationSessionSnapshot(
        sessionID: sessionID,
        revision: 2,
        phase: .polishing,
        target: try persistenceTarget(),
        timeline: [
          DictationTimelineMarker(kind: .started, monotonicNanoseconds: 10)
        ],
        transcript: draft
      ),
      transcript: draft,
      inputRevision: 1,
      configHash: try persistenceDigest("b"),
      createdAt: Date(timeIntervalSince1970: 200)
    )
    await assertThrowsPersistenceError(.invalidSnapshot) {
      try await store.commitRecognition(draftAsFinalCommit)
    }

    try await store.commitTranscriptRevision(draftCommit)
    try await store.commitTranscriptRevision(finalCommit)
    try await store.commitTranscriptRevision(finalCommit)

    let records = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records[0].kind, .streaming)
    XCTAssertNil(records[0].parentID)
    XCTAssertEqual(records[1].kind, .final)
    XCTAssertEqual(records[1].parentID, draftID)
    XCTAssertEqual(records[1].languageHints, ["zh-CN", "en-US"])
    XCTAssertEqual(records[1].audioRanges, audio)
    XCTAssertEqual(records[1].segments, [finalSegment])

    let conflicting = DictationTranscriptRevisionCommit(
      sessionID: sessionID,
      transcript: DictationTranscriptResult(
        revisionID: final.revisionID,
        segmentIDs: final.segmentIDs,
        text: "conflict",
        modelArtifactID: final.modelArtifactID,
        provenance: final.provenance
      ),
      inputRevision: 2,
      configHash: try persistenceDigest("b"),
      createdAt: Date(timeIntervalSince1970: 201)
    )
    await assertThrowsPersistenceError(.processingCommitConflict) {
      try await store.commitTranscriptRevision(conflicting)
    }
    try await store.checkpointAndClose()
  }

  func testTranscriptSegmentMaySpanContiguousSourceChunksButNotAGap() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(70))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let first = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: persistenceUUID(71),
      assetReference: "sessions/fixture/chunk-0.pcm",
      contentDigest: String(repeating: "a", count: 64),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let contiguous = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: first.trackID,
      assetReference: "sessions/fixture/chunk-1.pcm",
      contentDigest: String(repeating: "b", count: 64),
      monotonicStartNanoseconds: 200,
      monotonicEndNanoseconds: 300,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let segment = DictationTranscriptSegment(
      id: persistenceUUID(72),
      monotonicStartNanoseconds: 150,
      monotonicEndNanoseconds: 250,
      text: "cross chunk",
      confidence: 0.9
    )
    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(73)),
      segmentIDs: [segment.id],
      text: segment.text,
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .final,
        languageHints: ["en-US"],
        audioRanges: [first, contiguous],
        segments: [segment]
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: transcript,
        inputRevision: 1,
        configHash: try persistenceDigest("c"),
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    let storedTranscripts = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(storedTranscripts.count, 1)

    let gapped = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: first.trackID,
      assetReference: "sessions/fixture/chunk-gap.pcm",
      contentDigest: String(repeating: "d", count: 64),
      monotonicStartNanoseconds: 1_000_000,
      monotonicEndNanoseconds: 1_000_100,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let invalid = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(74)),
      segmentIDs: [segment.id],
      text: segment.text,
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .final,
        languageHints: ["en-US"],
        audioRanges: [first, gapped],
        segments: [segment]
      )
    )
    await assertThrowsPersistenceError(.invalidSnapshot) {
      try await store.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: invalid,
          inputRevision: 2,
          configHash: try persistenceDigest("e"),
          createdAt: Date(timeIntervalSince1970: 101)
        )
      )
    }
    try await store.checkpointAndClose()
  }

  func testInlineTranscriptEditPreservesTimingAudioAndSegmentIdentity() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(680))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let audio = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: persistenceUUID(681),
      assetReference: "sessions/inline/source.pcm",
      contentDigest: String(repeating: "a", count: 64),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 500,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let first = DictationTranscriptSegment(
      id: persistenceUUID(682),
      monotonicStartNanoseconds: 120,
      monotonicEndNanoseconds: 260,
      text: "hello",
      confidence: 0.9
    )
    let second = DictationTranscriptSegment(
      id: persistenceUUID(683),
      monotonicStartNanoseconds: 280,
      monotonicEndNanoseconds: 450,
      text: "world",
      confidence: 0.8
    )
    let sourceID = TranscriptRevisionID(persistenceUUID(684))
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: sourceID,
          segmentIDs: [first.id, second.id],
          text: "hello world",
          modelArtifactID: "fixture-asr",
          provenance: DictationTranscriptProvenance(
            parentRevisionID: nil,
            kind: .final,
            languageHints: ["en-US"],
            audioRanges: [audio],
            segments: [first, second]
          )
        ),
        inputRevision: 1,
        configHash: try persistenceDigest("a"),
        createdAt: Date(timeIntervalSince1970: 300)
      )
    )

    let edited = try await store.saveUserTranscriptSegmentEdit(
      sessionID: sessionID,
      sourceTranscriptID: sourceID,
      segmentID: second.id,
      replacement: "everyone",
      createdAt: Date(timeIntervalSince1970: 301)
    )
    XCTAssertEqual(edited.inputRevision, 2)
    XCTAssertEqual(edited.parentID, sourceID)
    XCTAssertEqual(edited.kind, .userEdit)
    XCTAssertEqual(edited.content, "hello everyone")
    XCTAssertEqual(edited.audioRanges, [audio])
    XCTAssertEqual(edited.segments.map(\.id), [first.id, second.id])
    XCTAssertEqual(edited.segments.map(\.text), ["hello", "everyone"])
    XCTAssertNotNil(edited.configHash)

    await assertThrowsPersistenceError(.processingCommitConflict) {
      _ = try await store.saveUserTranscriptSegmentEdit(
        sessionID: sessionID,
        sourceTranscriptID: sourceID,
        segmentID: first.id,
        replacement: "stale edit"
      )
    }
    let revisions = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(revisions.count, 2)
    XCTAssertEqual(revisions.last, edited)

    let restored = try await store.restoreTranscriptRevision(
      sessionID: sessionID,
      sourceTranscriptID: sourceID,
      expectedCurrentTranscriptID: edited.id,
      createdAt: Date(timeIntervalSince1970: 302)
    )
    XCTAssertEqual(restored.inputRevision, 3)
    XCTAssertEqual(restored.parentID, sourceID)
    XCTAssertEqual(restored.content, "hello world")
    XCTAssertEqual(restored.audioRanges, [audio])
    XCTAssertEqual(restored.segments, [first, second])
    XCTAssertEqual(restored.languageHints, ["en-US"])
    let restoredCorrection = try await store.restoreTranscriptRevision(
      sessionID: sessionID,
      sourceTranscriptID: edited.id,
      expectedCurrentTranscriptID: restored.id,
      createdAt: Date(timeIntervalSince1970: 303)
    )
    XCTAssertEqual(restoredCorrection.inputRevision, 4)
    XCTAssertEqual(restoredCorrection.parentID, edited.id)
    XCTAssertEqual(restoredCorrection.segments, edited.segments)
    XCTAssertEqual(restoredCorrection.audioRanges, edited.audioRanges)
    await assertThrowsPersistenceError(.processingCommitConflict) {
      _ = try await store.restoreTranscriptRevision(
        sessionID: sessionID,
        sourceTranscriptID: sourceID,
        expectedCurrentTranscriptID: restored.id
      )
    }
    let retained = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(retained.count, 4)
    XCTAssertEqual(retained.first(where: { $0.id == edited.id }), edited)
    XCTAssertEqual(retained.first(where: { $0.id == sourceID })?.segments, [first, second])
    let punctuated = try await store.saveUserTranscriptSegmentEdit(
      sessionID: sessionID,
      sourceTranscriptID: restoredCorrection.id,
      segmentID: first.id,
      replacement: "Hello.",
      createdAt: Date(timeIntervalSince1970: 304))
    XCTAssertEqual(punctuated.content, "Hello. everyone")
    XCTAssertEqual(punctuated.segments.map(\.id), [first.id, second.id])
    XCTAssertEqual(punctuated.audioRanges, [audio])
    try await store.checkpointAndClose()
  }

  func testTranscriptEditsUseNewestTerminalParentAndAllocateAfterLiveRevision()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(780))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let audio = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: persistenceUUID(781),
      assetReference: "sessions/out-of-order/source.pcm",
      contentDigest: String(repeating: "b", count: 64),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 500,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let liveID = TranscriptRevisionID(persistenceUUID(782))
    let liveSegment = DictationTranscriptSegment(
      id: persistenceUUID(783),
      monotonicStartNanoseconds: 300,
      monotonicEndNanoseconds: 450,
      text: "late live sentence",
      confidence: 0.8
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: liveID,
          segmentIDs: [liveSegment.id],
          text: liveSegment.text,
          modelArtifactID: "fixture-live",
          provenance: DictationTranscriptProvenance(
            parentRevisionID: nil,
            kind: .sentence,
            languageHints: ["en-US"],
            audioRanges: [audio],
            segments: [liveSegment]
          )
        ),
        inputRevision: 45,
        configHash: try persistenceDigest("b"),
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    let finalID = TranscriptRevisionID(persistenceUUID(784))
    let finalSegment = DictationTranscriptSegment(
      id: persistenceUUID(785),
      monotonicStartNanoseconds: 120,
      monotonicEndNanoseconds: 450,
      text: "complete final transcript",
      confidence: 0.95
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: finalID,
          segmentIDs: [finalSegment.id],
          text: finalSegment.text,
          modelArtifactID: "fixture-final",
          provenance: DictationTranscriptProvenance(
            parentRevisionID: liveID,
            kind: .final,
            languageHints: ["en-US"],
            audioRanges: [audio],
            segments: [finalSegment]
          )
        ),
        inputRevision: 6,
        configHash: try persistenceDigest("c"),
        createdAt: Date(timeIntervalSince1970: 200)
      )
    )

    try await store.setAutomaticSessionTitle(
      sessionID: sessionID, from: "outdated automatic navigation title"
    )
    let organizationBeforeEdit = try await store.eventOrganizationSessions()
    let finalEventSource = try XCTUnwrap(
      organizationBeforeEdit.first(where: { $0.sessionID == sessionID })
    )
    XCTAssertTrue(finalEventSource.semanticText.contains(finalSegment.text))
    XCTAssertFalse(finalEventSource.semanticText.contains(liveSegment.text))
    XCTAssertFalse(finalEventSource.semanticText.contains("outdated automatic navigation title"))
    XCTAssertEqual(finalEventSource.title, "outdated automatic navigation title")

    let segmentEdit = try await store.saveUserTranscriptSegmentEdit(
      sessionID: sessionID,
      sourceTranscriptID: finalID,
      segmentID: finalSegment.id,
      replacement: "corrected complete transcript",
      createdAt: Date(timeIntervalSince1970: 201)
    )
    XCTAssertEqual(segmentEdit.inputRevision, 46)
    XCTAssertEqual(segmentEdit.parentID, finalID)

    let wholeEdit = try await store.saveUserTranscriptEdit(
      sessionID: sessionID,
      content: "whole transcript correction",
      createdAt: Date(timeIntervalSince1970: 202)
    )
    XCTAssertEqual(wholeEdit.inputRevision, 47)
    XCTAssertEqual(wholeEdit.parentID, segmentEdit.id)
    let history = try await store.loadHistory(limit: 10)
    XCTAssertEqual(
      history.first(where: { $0.sessionID == sessionID })?.rawText,
      "whole transcript correction"
    )
    let organizationAfterEdit = try await store.eventOrganizationSessions()
    let editedEventSource = try XCTUnwrap(
      organizationAfterEdit.first(where: { $0.sessionID == sessionID })
    )
    XCTAssertTrue(editedEventSource.semanticText.contains("whole transcript correction"))
    XCTAssertFalse(editedEventSource.semanticText.contains(liveSegment.text))
    try await store.checkpointAndClose()
  }

  func testRejectedPersonCandidateStopsAppearingAsAnActiveMemoryLink()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(690))
    let speakerID = SessionSpeakerID(persistenceUUID(691))
    let occurrenceID = SpeakerOccurrenceID(persistenceUUID(692))
    let trackID = persistenceUUID(693)
    let workerID = persistenceUUID(694)
    let originDeviceID = persistenceUUID(695)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let audio = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: trackID,
      assetReference: "sessions/rejected-person/source.pcm",
      contentDigest: String(repeating: "f", count: 64),
      monotonicStartNanoseconds: 1_000_000_000,
      monotonicEndNanoseconds: 4_000_000_000,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID,
      audio: [audio],
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("f")
    )
    let claimedJob = try await store.claimNextSpeakerFinalJob(workerID: workerID)
    let claimed = try XCTUnwrap(claimedJob)
    try await store.completeSpeakerFinalJob(
      jobID: claimed.job.id,
      workerID: workerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: sessionID,
        sessionSpeakers: [
          SessionSpeaker(
            id: speakerID,
            sessionID: sessionID,
            revision: try Revision(1),
            stableOrdinal: 1
          )
        ],
        occurrences: [
          SpeakerOccurrence(
            id: occurrenceID,
            sessionID: sessionID,
            sessionSpeakerID: speakerID,
            revision: try Revision(1),
            trackIDs: [TrackID(trackID)],
            monotonicStartNanoseconds: 1_000_000_000,
            monotonicEndNanoseconds: 4_000_000_000,
            overlapsAnotherSpeaker: false,
            association: try PersonAssociation(
              status: .unknown,
              personID: nil,
              confidence: nil,
              evidenceRevision: try Revision(1)
            )
          )
        ],
        embeddings: [
          StoredSpeakerEmbedding(
            sessionSpeakerID: speakerID,
            revision: try Revision(1),
            embeddingSpaceID: "space-v1",
            vector: [1, 0],
            speechDurationNanoseconds: 3_000_000_000,
            signalQuality: try Confidence(0.95),
            modelArtifactKey: "speaker-v1"
          )
        ]
      )
    )
    let person = try await store.confirmSessionSpeaker(
      sessionSpeakerID: speakerID,
      personID: nil,
      newDisplayName: "Alice Fixture",
      originDeviceID: originDeviceID
    )

    let linkedItems = try await store.loadHistory(limit: 10)
    let linkedHistory = try XCTUnwrap(
      linkedItems.first { $0.sessionID == sessionID }
    )
    XCTAssertEqual(linkedHistory.personIDs, [person.id])
    XCTAssertEqual(linkedHistory.personDisplayNames, ["Alice Fixture"])
    let linkedOccurrences = try await store.personOccurrenceSummaries(
      personID: person.id
    )
    XCTAssertEqual(linkedOccurrences.count, 1)
    let linkedPeople = try await store.personSummaries()
    XCTAssertEqual(
      linkedPeople.first { $0.id == person.id }?.occurrenceCount,
      1
    )
    let linkedSearch = try await store.searchHistory(
      query: "Alice Fixture",
      mode: nil,
      status: nil
    )
    XCTAssertEqual(
      linkedSearch.map(\.sessionID),
      [sessionID]
    )

    try await store.rejectSessionSpeakerCandidate(
      sessionSpeakerID: speakerID,
      candidatePersonID: person.id,
      originDeviceID: originDeviceID
    )
    let rejectedOccurrences = try await store.sessionOccurrenceSummaries(
      sessionID: sessionID
    )
    let rejectedOccurrence = try XCTUnwrap(rejectedOccurrences.first)
    XCTAssertEqual(rejectedOccurrence.associationStatus, .rejected)
    XCTAssertEqual(
      rejectedOccurrence.personID,
      person.id,
      "The rejected candidate remains as provenance, not an active link."
    )
    let unlinkedItems = try await store.loadHistory(limit: 10)
    let unlinkedHistory = try XCTUnwrap(
      unlinkedItems.first { $0.sessionID == sessionID }
    )
    XCTAssertTrue(unlinkedHistory.personIDs.isEmpty)
    XCTAssertTrue(unlinkedHistory.personDisplayNames.isEmpty)
    let unlinkedOccurrences = try await store.personOccurrenceSummaries(
      personID: person.id
    )
    XCTAssertTrue(unlinkedOccurrences.isEmpty)
    let unlinkedPeople = try await store.personSummaries()
    XCTAssertEqual(
      unlinkedPeople.first { $0.id == person.id }?.occurrenceCount,
      0
    )
    let unlinkedSearch = try await store.searchHistory(
      query: "Alice Fixture",
      mode: nil,
      status: nil
    )
    XCTAssertTrue(unlinkedSearch.isEmpty)

    let undone = try await store.undoLastPersonEdit(
      originDeviceID: originDeviceID
    )
    XCTAssertTrue(undone)
    let restoredItems = try await store.loadHistory(limit: 10)
    let restoredHistory = try XCTUnwrap(
      restoredItems.first { $0.sessionID == sessionID }
    )
    XCTAssertEqual(restoredHistory.personIDs, [person.id])
    let restoredOccurrences = try await store.personOccurrenceSummaries(
      personID: person.id
    )
    XCTAssertEqual(restoredOccurrences.count, 1)
    try await store.checkpointAndClose()
  }

  func testPendingPersonReviewCandidatesExposeExactSourceAndRespectUndo()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let originDeviceID = persistenceUUID(710)
    let workerID = persistenceUUID(711)

    let knownSessionID = SessionID(persistenceUUID(712))
    let knownSpeakerID = SessionSpeakerID(persistenceUUID(713))
    let knownOccurrenceID = SpeakerOccurrenceID(persistenceUUID(714))
    let knownTrackID = persistenceUUID(715)
    try await store.create(preparingSnapshot(sessionID: knownSessionID))
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: knownSessionID,
      audio: [
        AudioRangeInput(
          sourceID: knownSessionID.rawValue,
          trackID: knownTrackID,
          assetReference: "sessions/person-review/known.pcm",
          contentDigest: String(repeating: "a", count: 64),
          monotonicStartNanoseconds: 1_000_000_000,
          monotonicEndNanoseconds: 5_000_000_000,
          sampleRateHertz: 48_000,
          channelCount: 1
        )
      ],
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("a")
    )
    let claimedKnownJob = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let knownJob = try XCTUnwrap(claimedKnownJob)
    try await store.completeSpeakerFinalJob(
      jobID: knownJob.job.id,
      workerID: workerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: knownSessionID,
        sessionSpeakers: [
          SessionSpeaker(
            id: knownSpeakerID,
            sessionID: knownSessionID,
            revision: try Revision(1),
            stableOrdinal: 1
          )
        ],
        occurrences: [
          SpeakerOccurrence(
            id: knownOccurrenceID,
            sessionID: knownSessionID,
            sessionSpeakerID: knownSpeakerID,
            revision: try Revision(1),
            trackIDs: [TrackID(knownTrackID)],
            monotonicStartNanoseconds: 1_000_000_000,
            monotonicEndNanoseconds: 5_000_000_000,
            overlapsAnotherSpeaker: false,
            association: try PersonAssociation(
              status: .unknown,
              personID: nil,
              confidence: nil,
              evidenceRevision: try Revision(1)
            )
          )
        ],
        embeddings: [
          StoredSpeakerEmbedding(
            sessionSpeakerID: knownSpeakerID,
            revision: try Revision(1),
            embeddingSpaceID: "space-v1",
            vector: [1, 0],
            speechDurationNanoseconds: 4_000_000_000,
            signalQuality: try Confidence(0.95),
            modelArtifactKey: "speaker-v1"
          )
        ]
      )
    )
    let knownPerson = try await store.confirmSessionSpeaker(
      sessionSpeakerID: knownSpeakerID,
      personID: nil,
      newDisplayName: "王芳",
      originDeviceID: originDeviceID
    )

    let candidateSessionID = SessionID(persistenceUUID(716))
    let candidateSpeakerID = SessionSpeakerID(persistenceUUID(717))
    let candidateOccurrenceID = SpeakerOccurrenceID(persistenceUUID(718))
    let candidateTrackID = persistenceUUID(719)
    try await store.create(preparingSnapshot(sessionID: candidateSessionID))
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: candidateSessionID,
      audio: [
        AudioRangeInput(
          sourceID: candidateSessionID.rawValue,
          trackID: candidateTrackID,
          assetReference: "sessions/person-review/candidate.pcm",
          contentDigest: String(repeating: "b", count: 64),
          monotonicStartNanoseconds: 2_000_000_000,
          monotonicEndNanoseconds: 8_000_000_000,
          sampleRateHertz: 48_000,
          channelCount: 1
        )
      ],
      inputRevision: 1,
      modelArtifactKey: "speaker-v1",
      embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("b")
    )
    let claimedCandidateJob = try await store.claimNextSpeakerFinalJob(
      workerID: workerID
    )
    let candidateJob = try XCTUnwrap(claimedCandidateJob)
    try await store.completeSpeakerFinalJob(
      jobID: candidateJob.job.id,
      workerID: workerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: candidateSessionID,
        sessionSpeakers: [
          SessionSpeaker(
            id: candidateSpeakerID,
            sessionID: candidateSessionID,
            revision: try Revision(1),
            stableOrdinal: 1
          )
        ],
        occurrences: [
          SpeakerOccurrence(
            id: candidateOccurrenceID,
            sessionID: candidateSessionID,
            sessionSpeakerID: candidateSpeakerID,
            revision: try Revision(1),
            trackIDs: [TrackID(candidateTrackID)],
            monotonicStartNanoseconds: 2_000_000_000,
            monotonicEndNanoseconds: 8_000_000_000,
            overlapsAnotherSpeaker: false,
            association: try PersonAssociation(
              status: .candidate,
              personID: knownPerson.id,
              confidence: try Confidence(0.74),
              evidenceRevision: try Revision(1)
            )
          )
        ],
        embeddings: [
          StoredSpeakerEmbedding(
            sessionSpeakerID: candidateSpeakerID,
            revision: try Revision(1),
            embeddingSpaceID: "space-v1",
            vector: [0.98, 0.02],
            speechDurationNanoseconds: 6_000_000_000,
            signalQuality: try Confidence(0.93),
            modelArtifactKey: "speaker-v1"
          )
        ]
      )
    )

    let pending = try await store.pendingPersonReviewCandidates()
    let candidate = try XCTUnwrap(pending.first)
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(candidate.speakerID, candidateSpeakerID)
    XCTAssertEqual(candidate.sessionID, candidateSessionID)
    XCTAssertEqual(candidate.representativeOccurrenceID, candidateOccurrenceID)
    XCTAssertEqual(candidate.candidatePersonID, knownPerson.id)
    XCTAssertEqual(candidate.candidateDisplayName, "王芳")
    XCTAssertEqual(candidate.monotonicStartNanoseconds, 2_000_000_000)
    XCTAssertEqual(candidate.monotonicEndNanoseconds, 8_000_000_000)
    XCTAssertEqual(candidate.occurrenceCount, 1)

    try await store.rejectSessionSpeakerCandidate(
      sessionSpeakerID: candidateSpeakerID,
      candidatePersonID: knownPerson.id,
      originDeviceID: originDeviceID
    )
    let dismissed = try await store.pendingPersonReviewCandidates()
    XCTAssertTrue(dismissed.isEmpty)
    let rejectedOccurrences = try await store.sessionOccurrenceSummaries(
      sessionID: candidateSessionID
    )
    let rejected = try XCTUnwrap(
      rejectedOccurrences.first
    )
    XCTAssertEqual(rejected.associationStatus, .rejected)
    XCTAssertEqual(rejected.personID, knownPerson.id)

    let undone = try await store.undoLastPersonEdit(
      originDeviceID: originDeviceID
    )
    XCTAssertTrue(undone)
    let restored = try await store.pendingPersonReviewCandidates()
    XCTAssertEqual(restored.map(\.speakerID), [candidateSpeakerID])
    try await store.checkpointAndClose()
  }

  func testOverlappingTrackSegmentsPersistWithoutBorrowingCrossTrackCoverage()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(760))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let remoteTrack = persistenceUUID(761)
    let microphoneTrack = persistenceUUID(762)
    let remoteRange = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: remoteTrack,
      assetReference: "sessions/fixture/remote.pcm",
      contentDigest: String(repeating: "a", count: 64),
      monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: 2_000_000,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let microphoneRange = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: microphoneTrack,
      assetReference: "sessions/fixture/microphone.pcm",
      contentDigest: String(repeating: "b", count: 64),
      monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: 2_000_000,
      sampleRateHertz: 44_100,
      channelCount: 1
    )
    let remoteSegment = DictationTranscriptSegment(
      id: persistenceUUID(763),
      monotonicStartNanoseconds: 100_000,
      monotonicEndNanoseconds: 1_200_000,
      text: "remote",
      confidence: 0.9
    )
    let microphoneSegment = DictationTranscriptSegment(
      id: persistenceUUID(764),
      monotonicStartNanoseconds: 400_000,
      monotonicEndNanoseconds: 1_500_000,
      text: "local",
      confidence: 0.8
    )
    let valid = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(765)),
      segmentIDs: [remoteSegment.id, microphoneSegment.id],
      text: "remote local",
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .final,
        languageHints: ["zh-CN", "en-US"],
        audioRanges: [remoteRange, microphoneRange],
        segments: [remoteSegment, microphoneSegment]
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: valid,
        inputRevision: 1,
        configHash: try persistenceDigest("f"),
        createdAt: Date(timeIntervalSince1970: 102)
      )
    )

    let firstHalf = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: remoteTrack,
      assetReference: "sessions/fixture/remote-half.pcm",
      contentDigest: String(repeating: "c", count: 64),
      monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: 1_000_000,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let secondHalf = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: microphoneTrack,
      assetReference: "sessions/fixture/microphone-half.pcm",
      contentDigest: String(repeating: "d", count: 64),
      monotonicStartNanoseconds: 1_000_000,
      monotonicEndNanoseconds: 2_000_000,
      sampleRateHertz: 44_100,
      channelCount: 1
    )
    let crossTrackSegment = DictationTranscriptSegment(
      id: persistenceUUID(766),
      monotonicStartNanoseconds: 500_000,
      monotonicEndNanoseconds: 1_500_000,
      text: "invalid cross-track bridge",
      confidence: 0.7
    )
    let invalid = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(persistenceUUID(767)),
      segmentIDs: [crossTrackSegment.id],
      text: crossTrackSegment.text,
      modelArtifactID: "fixture-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .final,
        languageHints: ["en-US"],
        audioRanges: [firstHalf, secondHalf],
        segments: [crossTrackSegment]
      )
    )
    await assertThrowsPersistenceError(.invalidSnapshot) {
      try await store.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: invalid,
          inputRevision: 2,
          configHash: try persistenceDigest("0"),
          createdAt: Date(timeIntervalSince1970: 103)
        )
      )
    }

    let stored = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(stored.map(\.id), [valid.revisionID])
    XCTAssertEqual(stored.first?.segments, [remoteSegment, microphoneSegment])
    try await store.checkpointAndClose()
  }

  func testDictionaryCRUDSearchProjectionAndTombstonePersistAcrossReopen() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("store.sqlite")
    let store = try GRDBDictationStore(databaseURL: databaseURL)

    let created = try await store.createDictionaryEntry(
      canonicalForm: "Alice",
      spokenForms: ["艾丽斯"]
    )
    XCTAssertEqual(created.revision, try Revision(1))
    let initialSearch = try await store.searchDictionaryEntries(
      query: "ali",
      includeDisabled: false,
      limit: 10
    )
    XCTAssertEqual(initialSearch, [created])
    await assertThrowsPersistenceError(.duplicateDictionaryEntry) {
      _ = try await store.createDictionaryEntry(
        canonicalForm: "alice",
        spokenForms: []
      )
    }

    let edited = try await store.updateDictionaryEntry(
      id: created.id,
      expectedRevision: created.revision,
      canonicalForm: "Alice Zhang",
      spokenForms: ["艾丽斯", "Alice Z"]
    )
    XCTAssertEqual(edited.id, created.id)
    XCTAssertEqual(edited.revision, try Revision(2))
    let editedSearch = try await store.searchDictionaryEntries(
      query: "Alice Z",
      includeDisabled: false,
      limit: 10
    )
    XCTAssertEqual(editedSearch, [edited])
    await assertThrowsPersistenceError(
      .dictionaryRevisionConflict(current: 2, expected: 1)
    ) {
      _ = try await store.setDictionaryEntryEnabled(
        id: created.id,
        expectedRevision: created.revision,
        enabled: false
      )
    }

    let disabled = try await store.setDictionaryEntryEnabled(
      id: edited.id,
      expectedRevision: edited.revision,
      enabled: false
    )
    let disabledProjection = try await store.dictionaryContext(
      maximumEntries: 64,
      maximumUTF8Bytes: 16_384
    )
    XCTAssertEqual(disabledProjection.entries, [])
    let disabledSearch = try await store.searchDictionaryEntries(
      query: "艾丽斯",
      includeDisabled: true,
      limit: 10
    )
    XCTAssertEqual(disabledSearch, [disabled])

    let enabled = try await store.setDictionaryEntryEnabled(
      id: disabled.id,
      expectedRevision: disabled.revision,
      enabled: true
    )
    let projection = try await store.dictionaryContext(
      maximumEntries: 1,
      maximumUTF8Bytes: 16_384
    )
    XCTAssertEqual(projection.entries, [enabled])
    XCTAssertEqual(projection.canonicalTerms, ["Alice Zhang"])

    let deleted = try await store.deleteDictionaryEntry(
      id: enabled.id,
      expectedRevision: enabled.revision
    )
    XCTAssertEqual(deleted.id, created.id)
    XCTAssertEqual(deleted.revision, try Revision(5))
    XCTAssertNotNil(deleted.tombstonedAt)
    let deletedLookup = try await store.dictionaryEntry(id: created.id)
    XCTAssertNil(deletedLookup)
    let deletedSearch = try await store.searchDictionaryEntries(
      query: "",
      includeDisabled: true,
      limit: 10
    )
    XCTAssertEqual(deletedSearch, [])
    try await store.checkpointAndClose()

    let reopened = try GRDBDictationStore(databaseURL: databaseURL)
    let reopenedLookup = try await reopened.dictionaryEntry(id: created.id)
    XCTAssertNil(reopenedLookup)
    try await reopened.checkpointAndClose()
  }

  func testDictionaryChangeInvalidatesCurrentDerivedTextWithoutMutation() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let sessionID = SessionID(persistenceUUID(80))
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let transcriptID = TranscriptRevisionID(persistenceUUID(81))
    try await store.save(
      transcript: TranscriptRevision(
        id: transcriptID,
        sessionID: sessionID,
        revision: try Revision(1),
        parentID: nil,
        kind: .final,
        content: "Alice ships",
        modelArtifactID: nil,
        configHash: try persistenceDigest("a"),
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    let derivation = DictationDerivedTextRecord(
      id: persistenceUUID(82),
      sessionID: sessionID,
      sourceTranscriptID: transcriptID,
      sourceRevision: try Revision(1),
      outputText: "Alice ships.",
      modelArtifactID: nil,
      configHash: try persistenceDigest("b"),
      state: .current,
      createdAt: Date(timeIntervalSince1970: 101)
    )
    try await store.save(derivation: derivation)

    _ = try await store.createDictionaryEntry(
      canonicalForm: "Alice",
      spokenForms: []
    )
    let derivations = try await store.loadDerivations(sessionID: sessionID)
    let stored = try XCTUnwrap(derivations.first)
    XCTAssertEqual(stored.state, .stale)
    XCTAssertEqual(stored.outputText, derivation.outputText)
    try await store.checkpointAndClose()
  }
}

private func assertThrowsPersistenceError(
  _ expected: BestASRPersistenceError,
  operation: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as BestASRPersistenceError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
