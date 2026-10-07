import XCTest

@testable import BestASRProcessing

/// Every row of the routing table, and nothing that is not a row.
final class SpokenJobComposerTests: XCTestCase {
  private func compose(
    _ mode: SpokenMode, _ transcript: String, selection: String? = nil
  ) -> SpokenJob {
    SpokenJobComposer.compose(
      mode: mode, transcript: transcript, selection: selection,
      translationLanguage: "英语", targetForSelection: { _ in "简体中文" })
  }

  func testDictationIsWrittenAsSaid() {
    XCTAssertEqual(compose(.dictate, "明天开会"), .write)
    XCTAssertEqual(compose(.dictate, "翻译成英文", selection: "x"), .write)
  }

  func testTranslateModeTranslatesTheWordsIntoTheChosenLanguage() {
    XCTAssertEqual(
      compose(.translate, "明天开会", selection: "ignored"),
      .translate("明天开会", to: "英语", replacing: false))
  }

  func testATranslationInstructionActsOnTheHighlightOrAsksForOne() {
    XCTAssertEqual(
      compose(.command, "翻译成英文", selection: "三二一"),
      .translate("三二一", to: "英语", replacing: true))
    XCTAssertEqual(
      compose(.command, "翻译一下", selection: "hello"),
      .translate("hello", to: "简体中文", replacing: true),
      "No language named: the caller's default for this highlight")
    XCTAssertEqual(
      compose(.command, "翻译成英文", selection: nil),
      .notice(SpokenJobComposer.selectSomethingFirst))
    XCTAssertEqual(
      compose(.command, "翻译成英文", selection: ""),
      .notice(SpokenJobComposer.selectSomethingFirst))
  }

  func testAQuestionAboutTheHighlightIsAnsweredNotWrittenOverIt() {
    XCTAssertEqual(
      compose(.command, "解释一下", selection: "quorum"),
      .answer(instruction: "解释一下", about: "quorum"))
    XCTAssertEqual(
      compose(.command, "总结一下", selection: "long text"),
      .answer(instruction: "总结一下", about: "long text"))
  }

  func testAnEditOfTheHighlightReplacesIt() {
    XCTAssertEqual(
      compose(.command, "改短一点", selection: "a long draft"),
      .transform(instruction: "改短一点", selection: "a long draft"))
  }

  /// 收1-8: in an App that shows no text, the user selects the wrong word
  /// and says the right one with fn+space.
  func testTheRightWordSaidOverAWrongOneReplacesItAsSaid() {
    XCTAssertEqual(
      compose(.command, "Mindloom。", selection: "mind loom"),
      .correct(heard: "mind loom", written: "Mindloom"))
    XCTAssertEqual(
      compose(.command, "改成在坐", selection: "在座"),
      .correct(heard: "在座", written: "在坐"))
    XCTAssertEqual(
      compose(.command, "改正式一点", selection: "你好"),
      .transform(instruction: "改正式一点", selection: "你好"),
      "An instruction about the selection is still an instruction")
    XCTAssertEqual(
      compose(.command, "下午三点", selection: "明天上午"),
      .transform(instruction: "下午三点", selection: "明天上午"),
      "Words that do not sound alike are not a correction")
  }

  /// Regression (review 10-6 S8): an instruction after 改成 or 写成 over a
  /// selection goes to the text model; it is never pasted over the selection
  /// as the literal word.
  func testAnInstructionAfterACueStaysAnInstruction() {
    for (said, selection) in [
      ("改成英文", "早上好"), ("改成英文", "Good morning"), ("改成大写", "hello world"),
      ("改成繁体", "软件开发"), ("改成列表", "苹果 香蕉 橙子"), ("写成英文", "会议纪要"),
      ("改成后天", "明天"),
    ] {
      XCTAssertEqual(
        compose(.command, said, selection: selection),
        .transform(instruction: said, selection: selection), "\(said) over \(selection)")
    }
  }

  func testAnInstructionWithNothingHighlightedIsAnswered() {
    XCTAssertEqual(
      compose(.command, "十七乘以二十三", selection: nil),
      .answer(instruction: "十七乘以二十三", about: nil))
  }
}
