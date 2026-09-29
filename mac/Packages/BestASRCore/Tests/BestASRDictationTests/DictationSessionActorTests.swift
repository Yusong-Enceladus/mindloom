import BestASRDictation
import BestASRDomain
import XCTest

final class DictationSessionActorTests: XCTestCase {
  func testRecordingWithoutFocusedTargetPreservesNilTarget() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 90))
    let sessionID = SessionID(testUUID(19))

    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: nil)
    )
    let recording = try await actor.handle(.preparationSucceeded)

    XCTAssertNil(preparing.target)
    XCTAssertNil(recording.target)
    try recording.validate()
  }

  func testCompletePathAndSameSessionPauseResume() async throws {
    let diagnostics = CapturingDictationDiagnostics()
    let actor = DictationSessionActor(
      clock: FixedDictationClock(value: 123),
      diagnostics: diagnostics
    )
    let sessionID = SessionID(testUUID(20))

    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: testTarget())
    )
    XCTAssertEqual(preparing.phase, .preparing)
    let recording = try await actor.handle(.preparationSucceeded)
    XCTAssertEqual(recording.phase, .recording)
    let paused = try await actor.handle(.pause)
    XCTAssertEqual(paused.phase, .paused)
    let resumed = try await actor.handle(.resume)
    XCTAssertEqual(resumed.phase, .recording)
    XCTAssertEqual(resumed.sessionID, sessionID)
    XCTAssertEqual(
      resumed.timeline.map(\.kind),
      [.started, .paused, .resumed]
    )
    let finalizing = try await actor.handle(.end)
    XCTAssertEqual(finalizing.phase, .finalizing)
    let recognizing = try await actor.handle(.journalSealed)
    XCTAssertEqual(recognizing.phase, .recognizing)

    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(testUUID(21)),
      segmentIDs: [testUUID(22)],
      text: "raw",
      modelArtifactID: "fixture-asr"
    )
    let polishing = try await actor.handle(.recognitionSucceeded(transcript))
    XCTAssertEqual(polishing.phase, .polishing)
    let polish = DictationPolishResult(
      sourceRevisionID: transcript.revisionID,
      text: "Raw.",
      disposition: .model,
      modelArtifactID: "fixture-text"
    )
    let inserting = try await actor.handle(.polishSucceeded(polish))
    XCTAssertEqual(inserting.phase, .inserting)
    let insertion = DictationInsertionResult(
      idempotencyKey: try DictationIdempotencyKey("insert:20:1"),
      method: .accessibilityReplacement,
      inserted: true
    )
    let completed = try await actor.handle(.insertionCompleted(insertion))
    XCTAssertEqual(completed.phase, .completed)
    XCTAssertEqual(completed.transcript, transcript)
    XCTAssertEqual(completed.polish, polish)
    XCTAssertEqual(completed.insertion, insertion)
    try completed.validate()

    let events = await diagnostics.snapshot()
    XCTAssertEqual(events.last?.phase, .completed)
    XCTAssertTrue(events.allSatisfy { $0.sessionID == sessionID })
  }

  func testNaturalSilenceDoesNotMutateStateOrRevision() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 100))
    _ = try await actor.handle(
      .start(sessionID: SessionID(testUUID(30)), target: testTarget())
    )
    let recording = try await actor.handle(.preparationSucceeded)
    let afterSilence = try await actor.handle(.ambientSilence)

    XCTAssertEqual(afterSilence, recording)
    XCTAssertEqual(afterSilence.phase, .recording)
  }

  func testCancelSuppressesProcessingPath() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 200))
    _ = try await actor.handle(
      .start(sessionID: SessionID(testUUID(40)), target: testTarget())
    )
    _ = try await actor.handle(.preparationSucceeded)
    let cancelling = try await actor.handle(.cancel)
    XCTAssertEqual(cancelling.phase, .cancelling)
    let cancelled = try await actor.handle(.cancellationCompleted)
    XCTAssertEqual(cancelled.phase, .cancelled)
    XCTAssertNil(cancelled.transcript)
    XCTAssertNil(cancelled.polish)
    XCTAssertNil(cancelled.insertion)
  }

  func testRecoverableFailureReturnsToExplicitRecoveryPhase() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 300))
    _ = try await actor.handle(
      .start(sessionID: SessionID(testUUID(50)), target: testTarget())
    )
    _ = try await actor.handle(.preparationSucceeded)
    _ = try await actor.handle(.end)
    _ = try await actor.handle(.journalSealed)
    let failure = try DictationFailure(
      stage: .recognition,
      category: .modelUnavailable,
      code: "model-unavailable",
      retryable: true,
      recoveryPhase: .recognizing
    )
    let failed = try await actor.handle(.failed(failure))
    XCTAssertEqual(failed.phase, .failedRecoverable)
    XCTAssertEqual(failed.failure, failure)

    let retried = try await actor.handle(.retry)
    XCTAssertEqual(retried.phase, .recognizing)
    XCTAssertNil(retried.failure)
  }

  func testRecoverableFailureCanBeAbandonedForANewSession() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 350))
    _ = try await actor.handle(
      .start(sessionID: SessionID(testUUID(51)), target: testTarget())
    )
    _ = try await actor.handle(.preparationSucceeded)
    let failure = try DictationFailure(
      stage: .capture,
      category: .transientRuntime,
      code: "device-reset",
      retryable: true,
      recoveryPhase: .recording
    )
    _ = try await actor.handle(.failed(failure))

    let replacementID = SessionID(testUUID(52))
    let replacement = try await actor.handle(
      .start(sessionID: replacementID, target: nil)
    )

    XCTAssertEqual(replacement.phase, .preparing)
    XCTAssertEqual(replacement.sessionID, replacementID)
    XCTAssertNil(replacement.failure)
    XCTAssertEqual(replacement.timeline.map(\.kind), [.started])
  }

  func testIllegalTransitionsFailWithoutMutationAndEndIsIdempotent() async throws {
    let actor = DictationSessionActor(clock: FixedDictationClock(value: 400))
    await assertThrowsErrorAsync {
      _ = try await actor.handle(.pause)
    }
    let idle = await actor.currentSnapshot()
    XCTAssertEqual(idle.phase, .idle)

    _ = try await actor.handle(
      .start(sessionID: SessionID(testUUID(60)), target: testTarget())
    )
    _ = try await actor.handle(.preparationSucceeded)
    let ending = try await actor.handle(.end)
    let duplicate = try await actor.handle(.end)
    XCTAssertEqual(duplicate, ending)

    await assertThrowsErrorAsync {
      _ = try await actor.handle(.resume)
    }
    let afterRejectedResume = await actor.currentSnapshot()
    XCTAssertEqual(afterRejectedResume, ending)
  }
}

private func assertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
