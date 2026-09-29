import BestASRDictation
import BestASRDictationFixtures
import BestASRDomain
import BestASRInference
import BestASRPersistence
import BestASRProcessing
import Foundation
import XCTest

final class DictationProcessingCoordinatorTests: XCTestCase {
  func testEmptyFinalTranscriptRetainsAudioAsRecoverableRecognitionFailure()
    async throws
  {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(749))
    let recognizing = try await makeRecognizingSnapshot(
      store: store,
      sessionID: sessionID,
      target: nil
    )
    let emptyTranscript = processingTranscript(id: 748, text: "")
    let polish = DeterministicPolishAdapter(
      outcomes: [.result(processingPolish(transcript: emptyTranscript))]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(emptyTranscript)]),
      polish: polish,
      insertion: DeterministicInsertionAdapter(
        target: try DeterministicDictationHarness.fixtureTarget(),
        outcomes: [.result(method: .retainedForCopy, inserted: false)]
      ),
      speaker: DeterministicSpeakerScheduler()
    )

    do {
      _ = try await coordinator.process(
        processingRequest(sessionID: sessionID)
      )
      XCTFail("Expected empty recognition to remain recoverable")
    } catch DictationProcessingError.stageFailed(let failure) {
      XCTAssertEqual(failure.stage, .recognition)
      XCTAssertEqual(failure.code, "asr-no-speech-detected")
      XCTAssertTrue(failure.retryable)
    }

    let loaded = try await store.load(sessionID: sessionID)
    let durable = try XCTUnwrap(loaded)
    let polishCalls = await polish.callCount()
    XCTAssertEqual(durable.phase, .failedRecoverable)
    XCTAssertNil(durable.transcript)
    XCTAssertEqual(polishCalls, 0)
    try await store.checkpointAndClose()
  }

  /// A dictation started with nothing focused is still asked to insert: the
  /// user may have clicked into a field while speaking, and only the
  /// insertion service — which reads the focus as it delivers — can know.
  /// Skipping the call outright sent every such dictation to the clipboard.
  func testNoStartTargetStillAsksTheInsertionServiceWhereTheCaretIsNow()
    async throws
  {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(750))
    let recognizing = try await makeRecognizingSnapshot(
      store: store,
      sessionID: sessionID,
      target: nil
    )
    let transcript = processingTranscript(id: 751)
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: insertion,
      speaker: DeterministicSpeakerScheduler()
    )

    let outcome = try await coordinator.process(
      processingRequest(sessionID: sessionID)
    )
    let insertionCalls = await insertion.callCount()

    XCTAssertEqual(outcome.snapshot.phase, .completed)
    XCTAssertNil(outcome.snapshot.target)
    XCTAssertEqual(outcome.snapshot.insertion?.method, .accessibilityReplacement)
    XCTAssertTrue(outcome.snapshot.insertion?.inserted ?? false)
    XCTAssertEqual(insertionCalls, 1)
    XCTAssertNotNil(outcome.snapshot.polish?.text)
    try await store.checkpointAndClose()
  }

  func testPersistentSpeakerSchedulingRunsAfterLabelFreeInsertionAndReplaysSafely()
    async throws
  {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(700))
    let recognizing = try await makeRecognizingSnapshot(
      store: store,
      sessionID: sessionID
    )
    let transcript = processingTranscript(id: 701)
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: insertion,
      speaker: GRDBSingleSpeakerScheduler(store: store)
    )
    let request = try processingRequest(sessionID: sessionID)

    let completed = try await coordinator.process(request)
    let duplicate = try await coordinator.process(request)
    let loadedWork = try await store.loadSingleSpeakerWork(sessionID: sessionID)
    let work = try XCTUnwrap(loadedWork)
    let insertionCalls = await insertion.callCount()
    let insertionMutations = await insertion.mutationCount()
    let snapshotBeforeSpeakerResult = try await store.load(sessionID: sessionID)
    let insertionBeforeSpeakerResult = try await store.insertionResult(
      sessionID: sessionID
    )
    let completedSpeakerWork = try await store.completeSingleSpeakerWorkUnknown(
      sessionID: sessionID
    )
    let replayedSpeakerWork = try await store.completeSingleSpeakerWorkUnknown(
      sessionID: sessionID
    )
    let snapshotAfterSpeakerResult = try await store.load(sessionID: sessionID)
    let insertionAfterSpeakerResult = try await store.insertionResult(
      sessionID: sessionID
    )

    XCTAssertEqual(completed.snapshot.phase, .completed)
    XCTAssertEqual(
      completed.snapshot.polish?.text,
      processingPolish(
        transcript: transcript
      ).text)
    XCTAssertEqual(duplicate.snapshot, completed.snapshot)
    XCTAssertEqual(insertionCalls, 1)
    XCTAssertEqual(insertionMutations, 1)
    XCTAssertEqual(work.occurrences.count, processingAudio(sessionID: sessionID).count)
    XCTAssertEqual(work.job.state, .queued)
    XCTAssertEqual(completedSpeakerWork.job.state, .succeeded)
    XCTAssertEqual(replayedSpeakerWork, completedSpeakerWork)
    XCTAssertEqual(snapshotAfterSpeakerResult, snapshotBeforeSpeakerResult)
    XCTAssertEqual(insertionAfterSpeakerResult, insertionBeforeSpeakerResult)
    try await store.checkpointAndClose()
  }

  func testSuccessCommitsRawPolishInsertionAndSchedulesSpeaker() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(1))
    let recognizing = try await makeRecognizingSnapshot(
      store: store,
      sessionID: sessionID,
      duplicateEnd: true
    )
    let transcript = processingTranscript()
    let asr = DeterministicASRAdapter(outcomes: [.result(transcript)])
    let polish = DeterministicPolishAdapter(
      outcomes: [.result(processingPolish(transcript: transcript))]
    )
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let speaker = DeterministicSpeakerScheduler()
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: asr,
      polish: polish,
      insertion: insertion,
      speaker: speaker
    )
    let request = try processingRequest(sessionID: sessionID)

    let first = try await coordinator.process(request)
    let duplicate = try await coordinator.process(request)
    let raw = try await store.loadTranscripts(sessionID: sessionID)
    let derived = try await store.loadDerivations(sessionID: sessionID)
    let insertionCalls = await insertion.callCount()
    let insertionMutations = await insertion.mutationCount()
    let speakerSchedules = await speaker.uniqueScheduleCount()
    let asrRequests = await asr.requests()

    XCTAssertEqual(first.snapshot.phase, .completed)
    XCTAssertEqual(duplicate.snapshot, first.snapshot)
    XCTAssertEqual(raw.map(\.content), [transcript.text])
    XCTAssertEqual(derived.map(\.outputText), [processingPolish(transcript: transcript).text])
    XCTAssertEqual(insertionCalls, 1)
    XCTAssertEqual(insertionMutations, 1)
    XCTAssertEqual(speakerSchedules, 1)
    XCTAssertEqual(
      asrRequests.first?.dictionaryHints,
      [ASRDictionaryHint(canonicalForm: "Alice", spokenForms: ["Allis"])]
    )
    try await store.checkpointAndClose()
  }

  func testASRFailurePersistsAndRetryResumesFromRecognition() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(20))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 21)
    let failure = try DictationAdapterFailure(
      category: .modelUnavailable,
      code: "fixture-model-unavailable",
      retryable: true
    )
    let asr = DeterministicASRAdapter(
      outcomes: [.failure(failure), .result(transcript)]
    )
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: asr,
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: insertion,
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)

    do {
      _ = try await coordinator.process(request)
      XCTFail("Expected ASR failure")
    } catch let error as DictationProcessingError {
      guard case .stageFailed(let persistedFailure) = error else {
        return XCTFail("Unexpected \(error)")
      }
      XCTAssertEqual(persistedFailure.stage, .recognition)
      XCTAssertEqual(persistedFailure.category, .modelUnavailable)
    }
    let failed = try await store.load(sessionID: sessionID)
    let failedTranscripts = try await store.loadTranscripts(sessionID: sessionID)
    XCTAssertEqual(failed?.phase, .failedRecoverable)
    XCTAssertEqual(failedTranscripts, [])

    let recovered = try await coordinator.process(request)
    let asrCalls = await asr.callCount()
    let insertionCalls = await insertion.callCount()
    XCTAssertEqual(recovered.snapshot.phase, .completed)
    XCTAssertEqual(asrCalls, 2)
    XCTAssertEqual(insertionCalls, 1)
    try await store.checkpointAndClose()
  }

  func testPolishFailureAndFactualChangeBothFallBackWithoutBlocking() async throws {
    for (offset, polishOutcome) in try polishFailureCases() {
      let root = try processingTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try GRDBDictationStore(
        databaseURL: root.appendingPathComponent("history.sqlite")
      )
      let sessionID = SessionID(processingUUID(40 + offset))
      let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
      let transcript = processingTranscript(id: 50 + offset)
      let coordinator = DictationProcessingCoordinator(
        initialSnapshot: recognizing,
        repository: store,
        asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
        polish: DeterministicPolishAdapter(
          outcomes: [polishOutcome(transcript)]
        ),
        insertion: DeterministicInsertionAdapter(
          target: try DeterministicDictationHarness.fixtureTarget(),
          outcomes: [.result(method: .retainedForCopy, inserted: false)]
        ),
        speaker: DeterministicSpeakerScheduler(
          outcomes: [
            .failure(
              try DictationAdapterFailure(
                category: .resourcePressure,
                code: "speaker-busy",
                retryable: true
              )
            )
          ]
        )
      )

      let outcome = try await coordinator.process(
        processingRequest(sessionID: sessionID)
      )
      XCTAssertEqual(outcome.snapshot.phase, .completed)
      XCTAssertEqual(
        outcome.snapshot.polish?.disposition,
        .punctuationOnlyFallback
      )
      // A single-sentence dictation gets no closing period (cleanup v2).
      XCTAssertEqual(outcome.snapshot.polish?.text, transcript.text)
      XCTAssertEqual(
        outcome.speakerScheduling,
        .deferred(code: "speaker-schedule-deferred")
      )
      try await store.checkpointAndClose()
    }
  }

  func testAmbiguousInsertionTimeoutNeverMutatesTargetTwice() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(70))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 71)
    let timeout = try DictationAdapterFailure(
      category: .transientRuntime,
      code: "adapter-timeout",
      retryable: true
    )
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [
        .failure(timeout, externalMutationOccurred: true),
        .result(method: .accessibilityReplacement, inserted: true),
      ]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: insertion,
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)

    do {
      _ = try await coordinator.process(request)
      XCTFail("Expected insertion timeout")
    } catch let error as DictationProcessingError {
      guard case .stageFailed(let failure) = error else {
        return XCTFail("Unexpected \(error)")
      }
      XCTAssertEqual(failure.stage, .insertion)
    }
    let callsAfterTimeout = await insertion.callCount()
    let mutationsAfterTimeout = await insertion.mutationCount()
    XCTAssertEqual(callsAfterTimeout, 1)
    XCTAssertEqual(mutationsAfterTimeout, 1)

    let reconciled = try await coordinator.process(request)
    XCTAssertEqual(reconciled.snapshot.phase, .completed)
    XCTAssertEqual(reconciled.snapshot.insertion?.method, .retainedForCopy)
    XCTAssertEqual(reconciled.snapshot.insertion?.inserted, false)
    let callsAfterReconcile = await insertion.callCount()
    let mutationsAfterReconcile = await insertion.mutationCount()
    XCTAssertEqual(callsAfterReconcile, 1)
    XCTAssertEqual(mutationsAfterReconcile, 1)
    _ = try await coordinator.process(request)
    let callsAfterDuplicate = await insertion.callCount()
    XCTAssertEqual(callsAfterDuplicate, 1)
    try await store.checkpointAndClose()
  }

  func testSpeakerSchedulingFailureDoesNotRollbackAndRetriesIdempotently() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(80))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 81)
    let insertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let speaker = DeterministicSpeakerScheduler(
      outcomes: [
        .failure(
          try DictationAdapterFailure(
            category: .resourcePressure,
            code: "speaker-worker-busy",
            retryable: true
          )
        ),
        .success,
      ]
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: insertion,
      speaker: speaker
    )
    let request = try processingRequest(sessionID: sessionID)

    let first = try await coordinator.process(request)
    XCTAssertEqual(
      first.speakerScheduling,
      .deferred(code: "speaker-schedule-deferred")
    )
    XCTAssertEqual(first.snapshot.phase, .completed)
    let retried = try await coordinator.process(request)
    let insertionCalls = await insertion.callCount()
    let speakerCalls = await speaker.callCount()
    let uniqueSchedules = await speaker.uniqueScheduleCount()
    XCTAssertEqual(retried.speakerScheduling, .scheduled)
    XCTAssertEqual(insertionCalls, 1)
    XCTAssertEqual(speakerCalls, 2)
    XCTAssertEqual(uniqueSchedules, 1)
    try await store.checkpointAndClose()
  }

  func testProcessRestartReconcilesOrphanReservationWithoutAdapterReplay() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let sessionID = SessionID(processingUUID(90))
    let firstStore = try GRDBDictationStore(databaseURL: databaseURL)
    let recognizing = try await makeRecognizingSnapshot(
      store: firstStore,
      sessionID: sessionID
    )
    let transcript = processingTranscript(id: 91)
    let firstInsertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [
        .failure(
          try DictationAdapterFailure(
            category: .transientRuntime,
            code: "process-killed-after-write",
            retryable: true
          ),
          externalMutationOccurred: true
        )
      ]
    )
    let first = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: firstStore,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: firstInsertion,
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)
    do { _ = try await first.process(request) } catch {}
    let firstMutationCount = await firstInsertion.mutationCount()
    XCTAssertEqual(firstMutationCount, 1)
    try await firstStore.checkpointAndClose()

    let restartedStore = try GRDBDictationStore(databaseURL: databaseURL)
    let loadedRestartedSnapshot = try await restartedStore.load(sessionID: sessionID)
    let restartedSnapshot = try XCTUnwrap(loadedRestartedSnapshot)
    let restartedInsertion = DeterministicInsertionAdapter(
      target: try DeterministicDictationHarness.fixtureTarget(),
      outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
    )
    let restarted = DictationProcessingCoordinator(
      initialSnapshot: restartedSnapshot,
      repository: restartedStore,
      asr: DeterministicASRAdapter(outcomes: [.result(transcript)]),
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: restartedInsertion,
      speaker: DeterministicSpeakerScheduler()
    )

    let outcome = try await restarted.process(request)
    let restartedCalls = await restartedInsertion.callCount()
    XCTAssertEqual(outcome.snapshot.phase, .completed)
    XCTAssertEqual(outcome.snapshot.insertion?.method, .retainedForCopy)
    XCTAssertEqual(restartedCalls, 0)
    try await restartedStore.checkpointAndClose()
  }

  func testActorRestartAfterASRFailureUsesDurableRecoveryState() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(110))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 111)
    let asr = DeterministicASRAdapter(
      outcomes: [
        .failure(
          try DictationAdapterFailure(
            category: .transientRuntime,
            code: "worker-restarted",
            retryable: true
          )
        ),
        .result(transcript),
      ]
    )
    let first = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: asr,
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: DeterministicInsertionAdapter(
        target: try DeterministicDictationHarness.fixtureTarget(),
        outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
      ),
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)
    do { _ = try await first.process(request) } catch {}
    let loadedDurableFailure = try await store.load(sessionID: sessionID)
    let durableFailure = try XCTUnwrap(loadedDurableFailure)

    let restarted = DictationProcessingCoordinator(
      initialSnapshot: durableFailure,
      repository: store,
      asr: asr,
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: DeterministicInsertionAdapter(
        target: try DeterministicDictationHarness.fixtureTarget(),
        outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
      ),
      speaker: DeterministicSpeakerScheduler()
    )
    let outcome = try await restarted.process(request)
    let asrCalls = await asr.callCount()
    XCTAssertEqual(outcome.snapshot.phase, .completed)
    XCTAssertEqual(asrCalls, 2)
    try await store.checkpointAndClose()
  }

  func testLostPersistenceAcknowledgementResumesWithoutRepeatingASR() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(130))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 131)
    let asr = DeterministicASRAdapter(outcomes: [.result(transcript)])
    let repository = AcknowledgementLossRepository(store: store)
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: repository,
      asr: asr,
      polish: DeterministicPolishAdapter(
        outcomes: [.result(processingPolish(transcript: transcript))]
      ),
      insertion: DeterministicInsertionAdapter(
        target: try DeterministicDictationHarness.fixtureTarget(),
        outcomes: [.result(method: .accessibilityReplacement, inserted: true)]
      ),
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)

    do {
      _ = try await coordinator.process(request)
      XCTFail("Expected simulated acknowledgement loss")
    } catch let error as DictationProcessingError {
      XCTAssertEqual(
        error,
        .persistenceUnavailable(code: "recognition-commit-failed")
      )
    }
    let asrCallsAfterLoss = await asr.callCount()
    let snapshotAfterLoss = try await store.load(sessionID: sessionID)
    XCTAssertEqual(asrCallsAfterLoss, 1)
    XCTAssertEqual(snapshotAfterLoss?.phase, .polishing)

    let outcome = try await coordinator.process(request)
    let finalASRCalls = await asr.callCount()
    let transcriptCount = try await store.loadTranscripts(sessionID: sessionID).count
    XCTAssertEqual(outcome.snapshot.phase, .completed)
    XCTAssertEqual(finalASRCalls, 1)
    XCTAssertEqual(transcriptCount, 1)
    try await store.checkpointAndClose()
  }

  private func polishFailureCases() throws -> [(
    UInt64, (DictationTranscriptResult) -> DeterministicPolishOutcome
  )] {
    let runtimeFailure = try DictationAdapterFailure(
      category: .modelUnavailable,
      code: "polish-model-unavailable",
      retryable: true
    )
    let timeout = try DictationAdapterFailure(
      category: .transientRuntime,
      code: "polish-timeout",
      retryable: true
    )
    return [
      (0, { _ in .failure(runtimeFailure) }),
      (
        1,
        { transcript in
          .result(
            processingPolish(
              transcript: transcript,
              text: "Do not send 35% to Alice at 10:30."
            )
          )
        }
      ),
      (2, { _ in .failure(timeout) }),
      (
        3,
        { transcript in
          .result(
            DictationPolishResult(
              sourceRevisionID: TranscriptRevisionID(processingUUID(999)),
              text: transcript.text,
              disposition: .model,
              modelArtifactID: "fixture-polish-v1"
            )
          )
        }
      ),
    ]
  }
}
