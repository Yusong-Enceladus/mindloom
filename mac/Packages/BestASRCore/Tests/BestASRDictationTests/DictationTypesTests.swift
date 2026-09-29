import BestASRDictation
import BestASRDomain
import Foundation
import XCTest

final class DictationTypesTests: XCTestCase {
  func testCommandsResultsAndSnapshotRoundTrip() throws {
    let sessionID = SessionID(testUUID(1))
    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(testUUID(2)),
      segmentIDs: [testUUID(3)],
      text: "fixture transcript",
      modelArtifactID: "fixture-asr"
    )
    let polish = DictationPolishResult(
      sourceRevisionID: transcript.revisionID,
      text: "Fixture transcript.",
      disposition: .model,
      modelArtifactID: "fixture-text"
    )
    let insertion = DictationInsertionResult(
      idempotencyKey: try DictationIdempotencyKey("insert:fixture:1"),
      method: .retainedForCopy,
      inserted: false,
      failureReason: .nowhere
    )
    let snapshot = DictationSessionSnapshot(
      sessionID: sessionID,
      revision: 7,
      phase: .completed,
      target: try testTarget(),
      timeline: [
        DictationTimelineMarker(kind: .started, monotonicNanoseconds: 10),
        DictationTimelineMarker(kind: .endRequested, monotonicNanoseconds: 20),
      ],
      transcript: transcript,
      polish: polish,
      insertion: insertion
    )
    let commands: [DictationCommand] = [
      .start(sessionID: sessionID, target: try testTarget()),
      .start(sessionID: sessionID, target: nil),
      .pause,
      .resume,
      .end,
      .cancel,
      .retry,
    ]

    try snapshot.validate()
    XCTAssertEqual(try roundTrip(snapshot), snapshot)
    XCTAssertEqual(try roundTrip(commands), commands)
    XCTAssertEqual(
      try roundTrip(DictationLifecycleEvent.recognitionSucceeded(transcript)),
      .recognitionSucceeded(transcript)
    )
    XCTAssertEqual(try roundTrip(polish), polish)
    XCTAssertEqual(try roundTrip(insertion), insertion)
    XCTAssertEqual(insertion.failureReason, .nowhere)
  }

  func testInvalidIdentifiersRangesAndSnapshotsFailClosed() throws {
    XCTAssertThrowsError(try DictationIdempotencyKey(""))
    XCTAssertThrowsError(try DictationIdempotencyKey("unsafe/value"))
    XCTAssertNoThrow(
      try DictationSessionSnapshot(
        sessionID: SessionID(testUUID(9)),
        revision: 1,
        phase: .recording,
        target: nil
      ).validate()
    )
    XCTAssertThrowsError(
      try DictationSessionSnapshot(
        sessionID: nil,
        revision: 1,
        phase: .recording,
        target: nil
      ).validate()
    )
    XCTAssertThrowsError(
      try DictationSessionSnapshot(
        sessionID: SessionID(testUUID(10)),
        revision: 1,
        phase: .failedRecoverable,
        target: testTarget()
      ).validate()
    )
  }

  func testFailureRequiresSafeCodeAndActiveRecoveryPhase() throws {
    XCTAssertNoThrow(
      try DictationFailure(
        stage: .recognition,
        category: .modelUnavailable,
        code: "model-unavailable",
        retryable: true,
        recoveryPhase: .recognizing
      )
    )
    XCTAssertThrowsError(
      try DictationFailure(
        stage: .recognition,
        category: .modelUnavailable,
        code: "contains private text",
        retryable: true,
        recoveryPhase: .recognizing
      )
    )
    XCTAssertThrowsError(
      try DictationFailure(
        stage: .recognition,
        category: .modelUnavailable,
        code: "model-unavailable",
        retryable: true,
        recoveryPhase: .completed
      )
    )
  }

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try JSONDecoder().decode(T.self, from: encoder.encode(value))
  }
}
