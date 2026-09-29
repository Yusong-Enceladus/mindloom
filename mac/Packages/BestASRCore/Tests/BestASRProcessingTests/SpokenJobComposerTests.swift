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

  func testAnInstructionWithNothingHighlightedIsAnswered() {
    XCTAssertEqual(
      compose(.command, "十七乘以二十三", selection: nil),
      .answer(instruction: "十七乘以二十三", about: nil))
  }
}
