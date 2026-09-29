import BestASRDictation
import BestASRDictationFixtures
import BestASRDomain
import BestASRInference
import BestASRPersistence
import BestASRProcessing
import Foundation
import XCTest

final class FinalTranscriptReplacementTests: XCTestCase {
  func testFinalAndPolishRetainLiveSourceRevisionAndReplayIdempotently() async throws {
    let root = try processingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(processingUUID(870))
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite")
    )
    let recognizing = try await makeRecognizingSnapshot(
      store: store,
      sessionID: sessionID
    )
    let audio = processingAudio(sessionID: sessionID)
    let liveID = TranscriptRevisionID(processingUUID(871))
    let live = DictationTranscriptResult(
      revisionID: liveID,
      segmentIDs: [],
      text: "live draft",
      modelArtifactID: "fixture-asr-v1",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: nil,
        kind: .streaming,
        languageHints: ["en-US"],
        audioRanges: audio,
        segments: []
      )
    )
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: live,
        inputRevision: 1,
        configHash: try processingDigest("a"),
        createdAt: Date(timeIntervalSince1970: 1)
      )
    )
    let final = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(processingUUID(872)),
      segmentIDs: [],
      text: "final transcript",
      modelArtifactID: "fixture-asr-v1",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: liveID,
        kind: .final,
        languageHints: ["en-US"],
        audioRanges: audio,
        segments: []
      )
    )
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: recognizing,
      repository: store,
      asr: DeterministicASRAdapter(outcomes: [.result(final)]),
      polish: DeterministicPolishAdapter(
        outcomes: [
          .result(
            DictationPolishResult(
              sourceRevisionID: final.revisionID,
              text: "Final transcript.",
              disposition: .model,
              modelArtifactID: "fixture-polish-v1"
            )
          )
        ]
      ),
      insertion: DeterministicInsertionAdapter(
        target: try DeterministicDictationHarness.fixtureTarget(),
        outcomes: [.result(method: .retainedForCopy, inserted: false)]
      ),
      speaker: DeterministicSpeakerScheduler()
    )
    let request = try processingRequest(sessionID: sessionID)

    let completed = try await coordinator.process(request)
    let replayed = try await coordinator.process(request)
    let revisions = try await store.loadTranscripts(sessionID: sessionID)
    let derivations = try await store.loadDerivations(sessionID: sessionID)

    XCTAssertEqual(completed.snapshot.phase, .completed)
    XCTAssertEqual(replayed.snapshot, completed.snapshot)
    XCTAssertEqual(revisions.map(\.kind), [.streaming, .final])
    XCTAssertEqual(revisions[1].parentID, liveID)
    XCTAssertEqual(revisions[1].audioRanges, audio)
    XCTAssertEqual(derivations.count, 1)
    XCTAssertEqual(derivations[0].sourceTranscriptID, final.revisionID)
    try await store.checkpointAndClose()
  }
}
