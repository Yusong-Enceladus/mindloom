import BestASRDictation
import BestASRDomain
import BestASRInference
import XCTest

@testable import BestASRPersistence

/// A meeting's item shows the live draft while it is being recognised
/// again and the recomputed text once that is done, even when a live line
/// is stored later (v12 1C, ALIGNMENT 收2-3). Synthetic rows only.
final class MeetingRecomputedTextTests: XCTestCase {
  func testAMeetingsItemShowsTheRecomputedTextOnceItIsDone() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("store.sqlite"))
    let sessionID = SessionID(persistenceUUID(1_300))
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .roomMicrophone)
    let audio = [
      AudioRangeInput(
        sourceID: sessionID.rawValue, trackID: persistenceUUID(1_301),
        assetReference: "sessions/fixture/journal/chunks/00000.pcm",
        contentDigest: String(repeating: "e", count: 64),
        monotonicStartNanoseconds: 100, monotonicEndNanoseconds: 200,
        sampleRateHertz: 48_000, channelCount: 1)
    ]
    func commit(
      _ id: UInt64, _ text: String, _ kind: TranscriptRevisionKind, parent: UInt64?,
      revision: UInt64, at seconds: Double
    ) async throws {
      try await store.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: DictationTranscriptResult(
            revisionID: TranscriptRevisionID(persistenceUUID(id)), segmentIDs: [], text: text,
            modelArtifactID: "fixture-asr",
            provenance: DictationTranscriptProvenance(
              parentRevisionID: parent.map { TranscriptRevisionID(persistenceUUID($0)) },
              kind: kind,
              languageHints: ["zh-CN"], audioRanges: audio, segments: [])),
          inputRevision: revision, configHash: try persistenceDigest("e"),
          createdAt: Date(timeIntervalSince1970: seconds)))
    }

    try await commit(1_310, "说话人 A  下周三之前", .streaming, parent: nil, revision: 1, at: 300)
    var item = try await store.loadHistory().first { $0.sessionID == sessionID }
    XCTAssertEqual(item?.rawText, "说话人 A  下周三之前", "the live draft while it is recognised again")
    var record = try await store.memoryItemRecords(ids: [sessionID]).first
    XCTAssertNil(record?.text, "a meeting's item has no committed text before the recomputed one")

    try await commit(1_311, "下周三之前把三组数据跑完。", .final, parent: 1_310, revision: 2, at: 400)
    try await commit(1_312, "说话人 A  迟到的一行", .sentence, parent: 1_310, revision: 3, at: 500)
    item = try await store.loadHistory().first { $0.sessionID == sessionID }
    XCTAssertEqual(item?.rawText, "下周三之前把三组数据跑完。")
    XCTAssertEqual(item?.inputMode, .roomMicrophone)
    record = try await store.memoryItemRecords(ids: [sessionID]).first
    XCTAssertEqual(record?.text, "下周三之前把三组数据跑完。")
    try await store.checkpointAndClose()
  }
}
