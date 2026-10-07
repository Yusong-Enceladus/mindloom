import AppKit
import BestASRDictation
import BestASRDomain
import BestASRMacUI
import XCTest

/// 实时字与最终字 (ALIGNMENT 收1-18, PRD DICT-025): where the final text
/// replaces the live caption, only what recognition changed is marked.
final class CaptionRevisionTests: XCTestCase {
  func testOnlyTheCharactersRecognitionChangedAreMarked() {
    XCTAssertEqual(
      CaptionRevision.revisedRanges(live: "明天和张三开会讨论预算", final: "明天和张珊开会，讨论预算。"),
      [4..<5])
    XCTAssertEqual(
      CaptionRevision.revisedRanges(live: "send it to jon today", final: "Send it to John today."),
      [13..<14])
  }

  func testPunctuationCaseAndSpacingAreNotMarked() {
    XCTAssertEqual(
      CaptionRevision.revisedRanges(
        live: "hello world how are you", final: "Hello world, how are you?"),
      [])
    XCTAssertEqual(CaptionRevision.revisedRanges(live: "好的我知道了", final: "好的，我知道了。"), [])
  }

  func testWordsTheLiveCaptionHadNotReachedAreNew() {
    XCTAssertEqual(
      CaptionRevision.revisedRanges(live: "跟高原说一声cover第一段", final: "跟高原说一声，cover 第一段我又删了两句。"),
      [])
    // A changed word is still marked when new words follow it.
    XCTAssertEqual(
      CaptionRevision.revisedRanges(live: "明天和张三开会", final: "明天和张珊开会讨论预算明天再说"),
      [4..<5])
  }

  func testADifferentTextIsNotMarked() {
    // A translation, or an instruction's result.
    XCTAssertEqual(
      CaptionRevision.revisedRanges(live: "明天下午开会", final: "Meeting tomorrow afternoon."), [])
    XCTAssertEqual(CaptionRevision.revisedRanges(live: "", final: "明天开会"), [])
  }

  /// The HUD carries the marks with the final text and clears them when the
  /// next take begins.
  @MainActor
  func testTheHUDMarksTheFinalTextAndClearsTheMarksOnTheNextTake() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try snapshot(.recording), liveText: "明天和张三开会")
    XCTAssertEqual(controller.presentation.revised, [])
    controller.render(try snapshot(.recognizing), liveText: "明天和张三开会")
    controller.render(try snapshot(.completed), liveText: "明天和张珊开会。")
    XCTAssertEqual(controller.presentation.committed, "明天和张珊开会。")
    XCTAssertEqual(controller.presentation.revised, [4..<5])
    controller.dismiss()
    controller.render(try snapshot(.recording), liveText: "下一句")
    XCTAssertEqual(controller.presentation.revised, [])
    controller.dismiss()
  }

  private func snapshot(_ phase: DictationPhase) throws -> DictationSessionSnapshot {
    let target = DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.example.editor", isSecure: false)
    let revisionID = TranscriptRevisionID()
    return DictationSessionSnapshot(
      sessionID: SessionID(UUID(uuidString: "00000000-0000-4000-8000-000000000025")!),
      revision: 1,
      phase: phase,
      target: target,
      transcript: phase == .completed
        ? DictationTranscriptResult(
          revisionID: revisionID, segmentIDs: [], text: "fixture", modelArtifactID: "fixture")
        : nil,
      insertion: phase == .completed
        ? DictationInsertionResult(
          idempotencyKey: try DictationIdempotencyKey("caption-revision"),
          method: .clipboardPaste, inserted: true)
        : nil
    )
  }
}
