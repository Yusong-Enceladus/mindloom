import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation
import XCTest

final class ProcessingPersistenceAtomicityTests: XCTestCase {
  func testConflictingSnapshotRollsBackTranscriptInsert() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let sessionID = SessionID(processingUUID(150))
    let recognizing = try await makeRecognizingSnapshot(store: store, sessionID: sessionID)
    let transcript = processingTranscript(id: 151)
    let conflicting = DictationSessionSnapshot(
      sessionID: sessionID,
      revision: recognizing.revision,
      phase: .polishing,
      target: recognizing.target,
      timeline: recognizing.timeline,
      transcript: transcript
    )

    do {
      try await store.commitRecognition(
        DictationRecognitionCommit(
          snapshot: conflicting,
          transcript: transcript,
          inputRevision: 1,
          configHash: try processingDigest("a"),
          createdAt: Date(timeIntervalSince1970: 100)
        )
      )
      XCTFail("Expected non-monotonic commit")
    } catch let error as BestASRPersistenceError {
      XCTAssertEqual(
        error,
        .nonMonotonicRevision(
          current: recognizing.revision,
          proposed: recognizing.revision
        )
      )
    }
    let transcripts = try await store.loadTranscripts(sessionID: sessionID)
    let durableSnapshot = try await store.load(sessionID: sessionID)
    XCTAssertEqual(transcripts, [])
    XCTAssertEqual(durableSnapshot, recognizing)
    try await store.checkpointAndClose()
  }
}
