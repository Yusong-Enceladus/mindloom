import BestASRProcessing
import XCTest

@testable import bestASR

/// What each job becomes, with both engines faked, and what the app is told
/// to do beside it.
final class SpokenJobProducerTests: XCTestCase {
  private func producer(
    translate: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
    follow: @escaping @Sendable (String, String?) async -> String? = { _, _ in nil }
  ) -> SpokenJobProducer {
    SpokenJobProducer(translate: translate, follow: follow)
  }

  func testWordsGoInAsSaid() async {
    let result = await producer().produce(.write)
    XCTAssertEqual(result, .init(delivery: .asIs))
  }

  func testTranslateModeWithoutAPackWritesTheWordsAndAsksForThePack() async {
    let result = await producer().produce(.translate("明天开会", to: "英语", replacing: false))
    XCTAssertEqual(result.delivery, .asIs)
    XCTAssertEqual(result.languagePackNeeded, "英语")
    XCTAssertNil(result.answerForPanel)
  }

  func testATranslatedHighlightReplacesItselfAndIsKeptForThePanel() async {
    let result = await producer(translate: { text, _ in "Three two one" })
      .produce(.translate("三二一", to: "英语", replacing: true))
    XCTAssertEqual(result.delivery, .replaced("Three two one"))
    XCTAssertEqual(result.answerForPanel, "Three two one")
  }

  func testAHighlightWithoutAPackIsToldNotSilentlyWrittenBack() async {
    let result = await producer().produce(.translate("三二一", to: "英语", replacing: true))
    XCTAssertEqual(result.delivery, .shown("需要先下载英语语言包，下载后再试一次"))
    XCTAssertEqual(result.languagePackNeeded, "英语")
  }

  func testARewriteThatPassesTheGatesReplacesTheHighlight() async {
    let result = await producer(follow: { _, _ in "Short draft." })
      .produce(.transform(instruction: "改短一点", selection: "This is a rather long draft."))
    XCTAssertEqual(result.delivery, .replaced("Short draft."))
  }

  func testARewriteThatEchoesOrBalloonsIsShownNotWritten() async {
    let echo = await producer(follow: { instruction, _ in instruction })
      .produce(.transform(instruction: "改短一点", selection: "draft"))
    XCTAssertEqual(echo.delivery, .shown("改短一点"))
    let balloon = String(repeating: "长", count: 500)
    let over = await producer(follow: { _, _ in balloon })
      .produce(.transform(instruction: "改短一点", selection: "短句"))
    XCTAssertEqual(over.delivery, .shown(balloon))
  }

  func testAnEngineThatCannotAnswerIsUnavailable() async {
    let result = await producer().produce(.transform(instruction: "改短", selection: "x"))
    XCTAssertEqual(result.delivery, .unavailable)
  }

  func testAQuestionAboutAHighlightIsShownAndAFreeInstructionIsWritten() async {
    let about = await producer(follow: { _, _ in "It means a quorum." })
      .produce(.answer(instruction: "什么意思", about: "quorum"))
    XCTAssertEqual(about.delivery, .shown("It means a quorum."))
    let free = await producer(follow: { _, _ in "391" })
      .produce(.answer(instruction: "十七乘以二十三", about: nil))
    XCTAssertEqual(free.delivery, .replaced("391"))
    XCTAssertEqual(free.answerForPanel, "391")
  }

  func testANoticeIsShown() async {
    let result = await producer().produce(.notice("先选中要翻译的文字，再说一遍"))
    XCTAssertEqual(result.delivery, .shown("先选中要翻译的文字，再说一遍"))
  }
}
