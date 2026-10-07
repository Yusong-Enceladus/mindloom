import XCTest

@testable import BestASRProcessing

/// 收1-8: only a word or two replaced by something that sounds alike is
/// learned; everything else the user does to a dictation teaches nothing.
final class CorrectionLearningTests: XCTestCase {
  func testAChineseCharacterFixedInAFieldIsLearnedAsAWord() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "他说的是在座的各位同事，明天上午十点开会",
        fieldContents: "他说的是在坐的各位同事，明天上午十点开会"),
      [LearnedCorrectionCandidate(heard: "在座", written: "在坐")])
  }

  func testALatinWordIsLearnedWhole() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "我们用 mindlum 记录会议", fieldContents: "我们用 mindloom 记录会议"),
      [LearnedCorrectionCandidate(heard: "mindlum", written: "mindloom")])
  }

  func testAChangeOfCaseTeachesNothing() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "我们用 fable 这个模型跑一下", fieldContents: "我们用 Fable 这个模型跑一下"),
      [])
  }

  func testAChangedNumberIsAFactNotAMisheardWord() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "麻烦把超时时间调成三十秒", fieldContents: "麻烦把超时时间调成四十秒"),
      [])
  }

  func testWordsThatDoNotSoundAlikeAreARewrite() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "这个方案我觉得很好，明天可以先跑一遍",
        fieldContents: "这个方案我觉得不错，明天可以先跑一遍"),
      [])
  }

  func testTextAddedInsideTheDictationBesideAFixTeachesNothing() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "明天上午十点在三楼会议室开评审会",
        fieldContents: "明天上午十点在三楼的会议事开评审会"),
      [], "The user was writing, not only fixing a word")
  }

  func testTextTypedAfterTheDictationDoesNotHideAFix() {
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "明天上午十点在三楼会议室开评审会",
        fieldContents: "明天上午十点在三楼会议事开评审会，记得带电脑"),
      [LearnedCorrectionCandidate(heard: "议室", written: "议事")])
  }

  func testAHistoryEditIsLearnedTheSameWay() {
    XCTAssertEqual(
      CorrectionLearning.fromEdit(
        original: "下周和 Clod 团队开会", edited: "下周和 Claude 团队开会"),
      [LearnedCorrectionCandidate(heard: "Clod", written: "Claude")])
  }

  func testSelectionCorrections() {
    XCTAssertEqual(
      CorrectionLearning.fromSelection(selection: "mind loom", spoken: "Mindloom。"),
      LearnedCorrectionCandidate(heard: "mind loom", written: "Mindloom"))
    XCTAssertEqual(
      CorrectionLearning.fromSelection(selection: "在座", spoken: "应该是在坐"),
      LearnedCorrectionCandidate(heard: "在座", written: "在坐"))
    XCTAssertNil(CorrectionLearning.fromSelection(selection: "你好", spoken: "翻译成英文"))
    XCTAssertNil(CorrectionLearning.fromSelection(selection: "你好", spoken: "你好"))
    XCTAssertNil(
      CorrectionLearning.fromSelection(
        selection: "这是一整段很长的文字，用来测试选中的内容太长时的情况", spoken: "改短"))
  }

  /// Regression (v12 storage review): 明天 → 后天 is a change of mind. Learned
  /// as a replacement it would rewrite every later 明天.
  func testAChangeOfMeaningBetweenChineseWordsIsNotLearned() {
    XCTAssertEqual(
      CorrectionLearning.fromField(inserted: "明天上午十点开会", fieldContents: "后天上午十点开会"), [])
    XCTAssertFalse(CorrectionLearning.isLearnable(heard: "明天", written: "后天"))
    XCTAssertTrue(CorrectionLearning.isLearnable(heard: "在座", written: "在坐"))
    XCTAssertTrue(CorrectionLearning.isLearnable(heard: "张三", written: "张珊"))
    // Said over a selection after 改成 it is an instruction for the text
    // model, not a word to write as said (review 10-6 S8).
    XCTAssertNil(CorrectionLearning.fromSelection(selection: "明天", spoken: "改成后天"))
  }

  /// Regression (review 10-6 S8): a cue such as 改成 does not make what
  /// follows the right word. 「改成英文」 over a sentence asks for English.
  func testACueFollowedByAnInstructionIsNotACorrection() {
    for (selection, said) in [
      ("早上好", "改成英文"), ("Good morning", "改成英文"), ("hello world", "改成大写"),
      ("软件开发", "改成繁体"), ("苹果 香蕉 橙子", "改成列表"), ("会议纪要", "写成英文"),
      ("明天", "改成后天"),
    ] {
      XCTAssertNil(
        CorrectionLearning.fromSelection(selection: selection, spoken: said), "\(said)")
    }
    XCTAssertEqual(
      CorrectionLearning.fromSelection(selection: "在座", spoken: "改成在坐"),
      LearnedCorrectionCandidate(heard: "在座", written: "在坐"), "A sound-alike after a cue")
  }

  /// Regression (review 10-6 S7): 「cloud code」 → 「Claude Code」 is learned
  /// as one correction. Cut down to 「cloud」 → 「Claude」 it would rewrite
  /// every later 「Google Cloud」.
  func testWordsCorrectedTogetherAreLearnedTogether() {
    XCTAssertEqual(
      CorrectionLearning.fromEdit(
        original: "I opened cloud code and asked it to fix the build",
        edited: "I opened Claude Code and asked it to fix the build"),
      [LearnedCorrectionCandidate(heard: "cloud code", written: "Claude Code")])
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "我在 cloud code 里面改了这个文件", fieldContents: "我在 Claude Code 里面改了这个文件"),
      [LearnedCorrectionCandidate(heard: "cloud code", written: "Claude Code")])
  }

  /// Regression (review 10-6 S14): a name fixed in a short chat message is
  /// learned; unrelated text in the field still teaches nothing.
  func testAFixInAShortDictationIsLearned() {
    XCTAssertEqual(
      CorrectionLearning.fromField(inserted: "发给王伟看看", fieldContents: "发给汪维看看"),
      [LearnedCorrectionCandidate(heard: "王伟", written: "汪维")])
    XCTAssertEqual(
      CorrectionLearning.fromField(
        inserted: "我们和王伟一起开会讨论一下", fieldContents: "我们和汪维一起开会讨论一下"),
      [LearnedCorrectionCandidate(heard: "王伟", written: "汪维")])
    XCTAssertEqual(
      CorrectionLearning.fromField(inserted: "这个叫mind loom", fieldContents: "这个叫Mindloom"),
      [LearnedCorrectionCandidate(heard: "mind loom", written: "Mindloom")])
    XCTAssertEqual(
      CorrectionLearning.fromField(inserted: "发给王伟看看", fieldContents: "好的明天见"), [])
    XCTAssertEqual(
      CorrectionLearning.fromField(inserted: "发给王伟看看", fieldContents: "发给他们两个人看"), [],
      "Text added or rewritten, not a word fixed")
  }

  func testPronunciationSimilarity() {
    XCTAssertEqual(CorrectionLearning.similarity("在座", "在坐"), 1, accuracy: 0.001)
    XCTAssertGreaterThan(CorrectionLearning.similarity("mindlum", "mindloom"), 0.7)
    XCTAssertLessThan(CorrectionLearning.similarity("很好", "不错"), 0.5)
  }
}
