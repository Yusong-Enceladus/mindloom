import Foundation
import MindloomPhoneKit
import NaturalLanguage

/// The phone's text rules (PHONE-SPEC §6.0).
enum PhoneText {
  /// U+2060 WORD JOINER.
  static let joiner: Character = "\u{2060}"

  /// Keeps every multi-character Chinese word whole when the text wraps (「上季度 / 预算表」 never
  /// split): the characters inside each word are joined with U+2060, so a line may only break
  /// between words.
  static func keepingWordsWhole(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: isCJK) else { return text }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    tokenizer.setLanguage(.simplifiedChinese)
    var joinAfter = Set<String.Index>()
    var previous: Range<String.Index>?
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let word = text[range]
      defer { previous = range }
      // A one-character verb and its 一下 / 一点 / 一个 … stay together (「问一下」), as the
      // prototype's segmenter keeps them.
      if Self.measureWords.contains(String(word)), let previous, previous.upperBound == range.lowerBound,
        text[previous].count == 1, text[previous].unicodeScalars.contains(where: isCJK)
      {
        joinAfter.insert(previous.lowerBound)
      }
      guard word.count > 1, word.unicodeScalars.contains(where: isCJK) else { return true }
      var index = range.lowerBound
      while index < range.upperBound {
        let next = text.index(after: index)
        if next < range.upperBound { joinAfter.insert(index) }
        index = next
      }
      return true
    }
    guard !joinAfter.isEmpty else { return text }
    var out = ""
    out.reserveCapacity(text.count * 2)
    var index = text.startIndex
    while index < text.endIndex {
      out.append(text[index])
      if joinAfter.contains(index) { out.append(joiner) }
      index = text.index(after: index)
    }
    return out
  }

  private static let measureWords: Set<String> = ["一下", "一点", "一些", "一个", "一次", "一遍"]

  /// The text without word joiners (copy, share, accessibility).
  static func plain(_ text: String) -> String {
    text.filter { $0 != joiner }
  }

  /// Appends 「。」 unless the text already ends in 。！？，,.!? (PHONE-SPEC §7.1 commit).
  static func finalized(_ recognized: String) -> String {
    PhoneTextRules.finalized(recognized)
  }

  /// More than 42 characters: clamped to two lines with 「展开」.
  static func needsClamp(_ text: String) -> Bool {
    plain(text).count > 42
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
  }
}
