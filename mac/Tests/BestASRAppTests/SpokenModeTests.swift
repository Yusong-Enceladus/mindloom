import BestASRDictation
import BestASRMacUI
import XCTest

@testable import bestASR

/// The two Typeless-style modes ride the dictation key as chords rather than
/// as shortcuts of their own, so the mapping from a chorded key to a mode is
/// the whole contract between the keyboard and what gets delivered.
final class SpokenModeTests: XCTestCase {
  func testOnlySpaceAndShiftMeanSomething() {
    XCTAssertEqual(
      DictationAppModel.spokenMode(forChord: CarbonHotkeyBackend.spaceKeyCode), .command)
    XCTAssertEqual(
      DictationAppModel.spokenMode(forChord: CarbonHotkeyBackend.leftShiftKeyCode), .translate)
    XCTAssertEqual(
      DictationAppModel.spokenMode(forChord: CarbonHotkeyBackend.rightShiftKeyCode), .translate)
  }

  /// Fn with anything else belongs to macOS — Fn Delete is forward delete, Fn
  /// with an arrow is Home/End/Page. Those must still cancel the dictation the
  /// Fn press started rather than quietly turning it into an instruction.
  func testEveryOtherChordStillCancels() {
    for keyCode in [UInt32(51), 117, 123, 124, 125, 126, 36, 48] {
      XCTAssertNil(
        DictationAppModel.spokenMode(forChord: keyCode),
        "Fn with key \(keyCode) belongs to macOS"
      )
    }
    XCTAssertNil(DictationAppModel.spokenMode(forChord: nil))
  }

  /// Nothing else on screen tells a 翻译 or 指令 dictation apart from an
  /// ordinary one, and by the time the difference shows it has already been
  /// delivered. The capsule names the mode while it is still listening.
  func testCapsuleNamesOnlyTheModesThatChangeTheOutcome() {
    XCTAssertEqual(
      DictationAppModel.capsuleListeningCaption(.dictate, language: "英语"), "")
    XCTAssertEqual(
      DictationAppModel.capsuleListeningCaption(.translate, language: "日语"), "翻译成日语")
    XCTAssertEqual(
      DictationAppModel.capsuleListeningCaption(.command, language: "英语"), "指令")
  }

  /// Shift entering 翻译 and Shift pressed again are the same key doing the
  /// same thing one step further along, so the ring has to wrap and has to
  /// survive a language being removed from Settings underneath it.
  func testShiftWalksTheChosenLanguagesAndWrapsAround() {
    let chosen = ["英语", "日语", "德语"]
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 0, among: chosen), "英语")
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 1, among: chosen), "日语")
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 2, among: chosen), "德语")
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 3, among: chosen), "英语")
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 7, among: chosen), "日语")
  }

  func testTheRingNeverLeavesTheUserWithNoLanguage() {
    XCTAssertEqual(DictationAppModel.translationLanguage(at: 2, among: []), "英语")
    XCTAssertEqual(DictationAppModel.translationLanguage(at: -1, among: ["日语"]), "日语")
    XCTAssertEqual(
      DictationAppModel.translationLanguage(at: -1, among: ["英语", "日语"]), "日语")
  }

  func testAtMostThreeLanguagesCanBeCycledThrough() {
    XCTAssertEqual(DictationAppModel.maximumTranslationLanguages, 3)
  }

  func testCommandStatusSaysWhetherItActsOnSomething() {
    XCTAssertEqual(
      DictationAppModel.spokenModeStatus(.command, hasSelection: true, language: "英语"),
      "说出要对选中文字做的事"
    )
    XCTAssertEqual(
      DictationAppModel.spokenModeStatus(.command, hasSelection: false, language: "英语"),
      "说出要它做的事"
    )
    XCTAssertEqual(
      DictationAppModel.spokenModeStatus(.translate, hasSelection: false, language: "德语"),
      "说完写入德语"
    )
  }
}

final class TranslationSourceTests: XCTestCase {
  /// "三二一" highlighted in WeChat was guessed as Japanese, the ja→en pair
  /// was not installed, and the user was told to download a pack they
  /// already had. Han without kana is Chinese first.
  func testHanWithoutKanaIsChineseBeforeAnyGuess() {
    let candidates = AppleTranslation.sourceCandidates(for: "三二一").map(\.minimalIdentifier)
    XCTAssertEqual(candidates.first, "zh")
    XCTAssertTrue(candidates.contains("zh-Hant") || candidates.contains("zh"))
  }

  func testKanaIsJapaneseAndLatinIsEnglish() {
    XCTAssertEqual(
      AppleTranslation.sourceCandidates(for: "テストです").first?.minimalIdentifier, "ja")
    XCTAssertTrue(
      AppleTranslation.sourceCandidates(for: "Test it.").map(\.minimalIdentifier).contains("en"))
  }
}
