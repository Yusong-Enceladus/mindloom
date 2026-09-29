import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRProcessing
import XCTest

final class FinalTranscriptReconcilerTests: XCTestCase {
  func testSevereFinalRegressionRetainsMostCredibleLiveContent() throws {
    let parentID = TranscriptRevisionID(processingUUID(910))
    let final = transcript(
      id: 911,
      text: "去掉了写",
      kind: .final,
      parentID: parentID,
      rangeEnd: 20
    )
    let longerWithoutDictionary = transcript(
      id: 912,
      text: "去掉了现在作为词点测试删除名字必须写成",
      kind: .streaming,
      rangeEnd: 18
    )
    let dictionaryCandidate = transcript(
      id: 913,
      text: "这是 bestASR 词典测试产品名字必须写成 bestASR",
      kind: .streaming,
      rangeEnd: 19
    )

    let reconciled = FinalTranscriptReconciler.reconcile(
      final: final,
      liveCandidates: [longerWithoutDictionary, dictionaryCandidate],
      parentRevisionID: parentID,
      dictionaryTerms: ["bestASR"]
    )

    XCTAssertEqual(reconciled.revisionID, final.revisionID)
    XCTAssertEqual(reconciled.text, dictionaryCandidate.text)
    XCTAssertEqual(reconciled.modelArtifactID, dictionaryCandidate.modelArtifactID)
    XCTAssertEqual(reconciled.segmentIDs, dictionaryCandidate.segmentIDs)
    XCTAssertEqual(reconciled.provenance?.kind, .final)
    XCTAssertEqual(reconciled.provenance?.parentRevisionID, parentID)
    XCTAssertEqual(reconciled.provenance?.audioRanges, final.provenance?.audioRanges)
    XCTAssertEqual(
      reconciled.provenance?.segments,
      dictionaryCandidate.provenance?.segments
    )
  }

  func testOrdinaryFinalCorrectionRemainsAuthoritative() throws {
    let parentID = TranscriptRevisionID(processingUUID(920))
    let live = transcript(
      id: 921,
      text: "hello world today",
      kind: .streaming,
      rangeEnd: 10
    )
    let final = transcript(
      id: 922,
      text: "Hello, world today.",
      kind: .final,
      parentID: parentID,
      rangeEnd: 11
    )

    XCTAssertEqual(
      FinalTranscriptReconciler.reconcile(
        final: final,
        liveCandidates: [live],
        parentRevisionID: parentID,
        dictionaryTerms: []
      ),
      final
    )
  }

  func testSmallLiveFragmentsCannotReplaceFinal() throws {
    let parentID = TranscriptRevisionID(processingUUID(930))
    let final = transcript(
      id: 931,
      text: "完成",
      kind: .final,
      parentID: parentID,
      rangeEnd: 5
    )
    let fragment = transcript(
      id: 932,
      text: "测试片段",
      kind: .streaming,
      rangeEnd: 4
    )

    XCTAssertEqual(
      FinalTranscriptReconciler.reconcile(
        final: final,
        liveCandidates: [fragment],
        parentRevisionID: parentID,
        dictionaryTerms: []
      ),
      final
    )
  }

  func testEmptyFinalPromotesCredibleLiveContentWithFinalProvenance() throws {
    let parentID = TranscriptRevisionID(processingUUID(940))
    let live = transcript(
      id: 941,
      text: "bestASR are works in chrome",
      kind: .streaming,
      rangeEnd: 9
    )
    let final = transcript(
      id: 942,
      text: "",
      kind: .final,
      parentID: parentID,
      rangeEnd: 10
    )

    let reconciled = FinalTranscriptReconciler.reconcile(
      final: final,
      liveCandidates: [live],
      parentRevisionID: parentID,
      dictionaryTerms: []
    )

    XCTAssertEqual(reconciled.revisionID, final.revisionID)
    XCTAssertEqual(reconciled.text, live.text)
    XCTAssertEqual(reconciled.segmentIDs, live.segmentIDs)
    XCTAssertEqual(reconciled.provenance?.kind, .final)
    XCTAssertEqual(reconciled.provenance?.parentRevisionID, parentID)
    XCTAssertEqual(reconciled.provenance?.audioRanges, final.provenance?.audioRanges)
  }

  private func transcript(
    id: UInt64,
    text: String,
    kind: TranscriptRevisionKind,
    parentID: TranscriptRevisionID? = nil,
    rangeEnd: UInt64
  ) -> DictationTranscriptResult {
    let segmentID = processingUUID(id + 100)
    return DictationTranscriptResult(
      revisionID: TranscriptRevisionID(processingUUID(id)),
      segmentIDs: [segmentID],
      text: text,
      modelArtifactID: "fixture-asr-v1",
      provenance: DictationTranscriptProvenance(
        parentRevisionID: parentID,
        kind: kind,
        languageHints: ["zh-CN", "en-US"],
        audioRanges: [
          AudioRangeInput(
            sourceID: processingUUID(id + 300),
            trackID: processingUUID(id + 200),
            assetReference: "sessions/source/chunk.pcm",
            contentDigest: String(repeating: "a", count: 64),
            monotonicStartNanoseconds: 0,
            monotonicEndNanoseconds: rangeEnd,
            sampleRateHertz: 16_000,
            channelCount: 1
          )
        ],
        segments: [
          DictationTranscriptSegment(
            id: segmentID,
            monotonicStartNanoseconds: 0,
            monotonicEndNanoseconds: rangeEnd,
            text: text,
            confidence: nil
          )
        ]
      )
    )
  }
}
