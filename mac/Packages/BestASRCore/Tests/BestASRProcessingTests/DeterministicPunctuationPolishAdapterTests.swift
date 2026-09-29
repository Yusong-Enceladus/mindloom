import BestASRDictation
import BestASRDomain
import BestASRProcessing
import XCTest

final class DeterministicPunctuationPolishAdapterTests: XCTestCase {
  func testSingleSentenceHasNoClosingPeriod() async throws {
    let adapter = DeterministicPunctuationPolishAdapter()
    let english = try await adapter.polish(request(text: "  keep 25% for Alice.  "))
    let mandarin = try await adapter.polish(request(text: "好的，我马上过去。"))
    let bare = try await adapter.polish(request(text: "不要删除原始音频"))

    XCTAssertEqual(english.text, "keep 25% for Alice")
    XCTAssertEqual(mandarin.text, "好的，我马上过去")
    XCTAssertEqual(bare.text, "不要删除原始音频")
    XCTAssertEqual(english.disposition, .punctuationOnlyFallback)
    XCTAssertTrue(
      DictationProtectedFactValidator.validate(
        source: "keep 25% for Alice.",
        candidate: english.text,
        dictionaryTerms: ["Alice"]
      ).passed
    )
  }

  func testSeveralSentencesKeepOrGainTheirTerminalMark() async throws {
    let adapter = DeterministicPunctuationPolishAdapter()
    let kept = try await adapter.polish(request(text: "先保存。然后导出。"))
    let added = try await adapter.polish(request(text: "先保存。然后导出"))

    XCTAssertEqual(kept.text, "先保存。然后导出。")
    XCTAssertEqual(added.text, "先保存。然后导出。")
  }

  func testQuestionsAndDecimalsAreNotTreatedAsExtraSentences() {
    XCTAssertEqual(DictationTextCleanup.apply("这个要改吗？"), "这个要改吗？")
    XCTAssertEqual(DictationTextCleanup.apply("版本升级到 3.5。"), "版本升级到 3.5")
  }

  func testFillersAndTheCommasTheyLeaveAreRemoved() {
    XCTAssertEqual(DictationTextCleanup.apply("嗯，好的，我知道了。"), "好的，我知道了")
    XCTAssertEqual(DictationTextCleanup.apply("我觉得，嗯，这个方案呃可以。"), "我觉得，这个方案可以")
    XCTAssertEqual(DictationTextCleanup.apply("先这样吧，呃。后面再说。"), "先这样吧。后面再说。")
    XCTAssertEqual(DictationTextCleanup.apply("嗯嗯。"), "嗯嗯。", "Only fillers: keep what was said")
  }

  func testPreservesQuestionAndEmptyRawInput() async throws {
    let adapter = DeterministicPunctuationPolishAdapter()
    let existing = try await adapter.polish(request(text: "Already safe!"))
    let empty = try await adapter.polish(request(text: ""))

    XCTAssertEqual(existing.text, "Already safe!")
    XCTAssertEqual(empty.text, "")
    XCTAssertEqual(empty.disposition, .rawTranscriptFallback)
  }

  private func request(text: String) throws -> DictationPolishRequest {
    DictationPolishRequest(
      sessionID: SessionID(uuid(1)),
      transcript: DictationTranscriptResult(
        revisionID: TranscriptRevisionID(uuid(2)),
        segmentIDs: [uuid(3)],
        text: text,
        modelArtifactID: "fixture-model"
      ),
      dictionaryTerms: ["Alice"],
      targetBundleIdentifier: "com.example.fixture"
    )
  }
}

private func uuid(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-4000-8000-%012llx",
      value
    )
  )!
}
