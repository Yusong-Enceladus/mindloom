import BestASRRecognition
import XCTest

final class AlignedTranscriptAssemblerTests: XCTestCase {
  func testChineseAndEnglishPunctuationArePreservedAsNaturalPhrases() throws {
    let text = "今天开会。 Please bring the notes."
    let words = ["今", "天", "开", "会", "Please", "bring", "the", "notes"].enumerated().map {
      TranscriptAlignmentWord(
        text: $0.element, startSeconds: Double($0.offset) * 0.3,
        endSeconds: Double($0.offset + 1) * 0.3)
    }
    let phrases = try assemble(text, words, duration: 3)
    XCTAssertEqual(phrases.map(\.text).joined(), text)
    XCTAssertGreaterThanOrEqual(phrases.count, 2)
    XCTAssertLessThan(phrases.count, words.count)
    XCTAssertTrue(phrases.contains { $0.text.contains("Please bring the notes.") })
  }

  func testZeroDurationWordsAreNotDroppedOrGivenFakePlaybackRows() throws {
    let text = "We will go. Yes."
    let words = [
      word("We", 0, 0), word("will", 0, 0.4), word("go", 0.4, 0.8), word("Yes", 0.8, 0.8),
    ]
    let phrases = try assemble(text, words, duration: 1)
    XCTAssertEqual(phrases.map(\.text).joined(), text)
    XCTAssertTrue(phrases.allSatisfy { $0.endSeconds > $0.startSeconds })
    XCTAssertEqual(phrases.last?.endSeconds, 0.8)
  }

  func testOneQuantizationStepAtSourceEdgesIsBounded() throws {
    let phrases = try assemble("Stop.", [word("Stop", -0.04, 1.007_437_5)], duration: 1)
    XCTAssertEqual(phrases.first?.startSeconds, 0)
    XCTAssertEqual(phrases.first?.endSeconds, 1)
    XCTAssertThrowsError(try assemble("Stop.", [word("Stop", 0, 1.09)], duration: 1))
  }

  func testTextGapsReorderingAndInvalidTimesRejectWholeAlignment() {
    for words in [
      [word("one", 0, 0.2)],
      [word("two", 0, 0.2), word("one", 0.2, 0.4)],
      [word("one", 0.4, 0.6), word("two", 0.2, 0.4)],
      [word("one", 0, .nan), word("two", 0.2, 0.4)],
      [word("one", 0, 0), word("two", 0, 0)],
    ] {
      XCTAssertThrowsError(try assemble("one two", words, duration: 1))
    }
  }

  func testDecimalAndApostropheContentIsRetainedExactly() throws {
    let text = "Don't change 3.5 to 35."
    let tokens = ["Don't", "change", "35", "to", "35"]
    let words = tokens.enumerated().map {
      word($0.element, Double($0.offset), Double($0.offset + 1))
    }
    let phrases = try assemble(text, words, duration: 6)
    XCTAssertEqual(phrases.map(\.text).joined(), text)
    XCTAssertTrue(phrases.first?.text.contains("3.5") == true)
  }

  func testLongSilenceSeparatesReadablePhrasesWithoutChangingText() throws {
    let text = "before the pause after the pause"
    let words = [
      word("before", 0, 0.3), word("the", 0.3, 0.4), word("pause", 0.4, 0.8),
      word("after", 2, 2.3), word("the", 2.3, 2.4), word("pause", 2.4, 2.8),
    ]
    let phrases = try assemble(text, words, duration: 3)
    XCTAssertEqual(phrases.count, 2)
    XCTAssertEqual(phrases.map(\.text).joined(), text)
    XCTAssertEqual(phrases[1].startSeconds, 2)
  }

  private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptAlignmentWord {
    TranscriptAlignmentWord(text: text, startSeconds: start, endSeconds: end)
  }

  private func assemble(_ text: String, _ words: [TranscriptAlignmentWord], duration: Double) throws
    -> [AlignedTranscriptPhrase]
  {
    try AlignedTranscriptAssembler().assemble(
      text: text, words: words,
      durationSeconds: duration, quantizationSeconds: 0.08)
  }
}
