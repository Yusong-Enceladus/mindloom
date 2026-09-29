import XCTest

@testable import BestASRProcessing

final class SpokenTranslationRequestTests: XCTestCase {
  func testTheLanguagesPeopleActuallySayAreRecognised() {
    let cases: [(String, String?)] = [
      ("翻译成中文", "简体中文"),
      ("翻译成简体中文", "简体中文"),
      ("翻译成繁体中文", "繁体中文"),
      ("帮我翻译成英文", "英语"),
      ("translate this into Japanese", "日语"),
      ("译成德语", "德语"),
      // Not a translation, and must not be treated as one.
      ("把这段改短一点", nil),
      ("这段翻译得对不对", nil),
      ("summarize this", nil),
    ]
    for (instruction, expected) in cases {
      XCTAssertEqual(SpokenTranslationRequest.language(in: instruction), expected, instruction)
    }
  }

  /// "翻译一下" names no language but is still a translation, and must not
  /// reach the general model: it went there once and the answer was "Use
  /// non-thinking mode."
  func testATranslationWithoutANamedLanguageIsStillATranslation() {
    XCTAssertTrue(SpokenTranslationRequest.asksToTranslate("翻译一下"))
    XCTAssertTrue(SpokenTranslationRequest.asksToTranslate("translate this"))
    XCTAssertNil(SpokenTranslationRequest.language(in: "翻译一下"))
    XCTAssertFalse(SpokenTranslationRequest.asksToTranslate("把这段改短一点"))
  }
}
