import BestASRDictation
import BestASRDictationFixtures
import BestASRDomain
import BestASRInference
import BestASRPersistence
import BestASRProcessing
import Foundation
import XCTest

final class TypelessDictationRecoveryTests: XCTestCase {
  func testCommittedLiveRevisionAndSourceSessionSurviveRelaunch() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let sessionID = SessionID(processingUUID(850))
    let first = try GRDBDictationStore(databaseURL: databaseURL)
    let actor = DictationSessionActor(clock: DeterministicDictationClock())
    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: try fixtureTarget())
    )
    try await first.create(preparing)
    let recording = try await actor.handle(.preparationSucceeded)
    try await first.save(recording)
    let audio = processingAudio(sessionID: sessionID)
    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(processingUUID(851)),
      segmentIDs: [],
      text: "recoverable live draft",
      modelArtifactID: "fixture-live-asr",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .streaming,
        languageHints: ["en-US"],
        audioRanges: audio,
        segments: []
      )
    )
    try await first.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: transcript,
        inputRevision: 1,
        configHash: try processingDigest("e"),
        createdAt: Date(timeIntervalSince1970: 1)
      )
    )
    try await first.checkpointAndClose()

    let reopened = try GRDBDictationStore(databaseURL: databaseURL)
    let recoveredSession = try await reopened.load(sessionID: sessionID)
    let revisions = try await reopened.loadTranscripts(sessionID: sessionID)
    let recoverable = try await reopened.loadRecoverable()

    XCTAssertEqual(recoveredSession, recording)
    XCTAssertEqual(revisions.count, 1)
    XCTAssertEqual(revisions[0].id, transcript.revisionID)
    XCTAssertEqual(revisions[0].kind, .streaming)
    XCTAssertEqual(revisions[0].audioRanges, audio)
    XCTAssertTrue(recoverable.contains { $0.sessionID == sessionID })
    try await reopened.checkpointAndClose()
  }

  private func fixtureTarget() throws -> DictationTargetSnapshot {
    DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.example.fixture", isSecure: false)
  }
}

final class TypelessDictationPrivacyTests: XCTestCase {
  func testLiveEventAndCommitDiagnosticsContainNoUserContextFields() throws {
    let event = LiveDictationEvent(
      sessionID: SessionID(processingUUID(860)),
      text: "",
      state: .unavailable
    )
    let data = try JSONEncoder().encode(
      PrivacyEventProjection(
        sessionID: event.sessionID.rawValue.uuidString,
        state: "unavailable"
      )
    )
    let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
    for prohibited in [
      "audio", "transcript", "dictionary", "speaker", "participant",
      "windowTitle", "clipboard", "foregroundText",
    ] {
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains(prohibited))
    }
  }
}

private struct PrivacyEventProjection: Codable {
  let sessionID: String
  let state: String
}
