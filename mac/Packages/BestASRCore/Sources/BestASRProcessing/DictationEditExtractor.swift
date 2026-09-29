import Foundation

/// One word the user replaced right after a dictation was inserted.
public struct DictationEditPair: Equatable, Sendable {
  /// What the recognizer produced.
  public let recognized: String
  /// What the user changed it to.
  public let corrected: String

  public init(recognized: String, corrected: String) {
    self.recognized = recognized
    self.corrected = corrected
  }
}

/// Recovers what the user fixed in a dictation the App had just inserted.
///
/// The field's later contents are whatever the user has done since: they may
/// have typed around it, deleted everything, or sent the message. Only an edit
/// that still looks like the same sentence counts; anything else is discarded
/// rather than guessed at, because a wrong pair would teach the recognizer a
/// word the user never said.
public enum DictationEditExtractor {
  /// The inserted text must still be this recognizable in the field.
  public static let minimumSimilarity = 0.85
  /// Longer replacements are rewrites, not corrections of a misheard word.
  public static let maximumPairCharacters = 12
  /// Dictations longer than this are not searched for. A field that large is
  /// a document the user is writing, not a sentence we just inserted.
  public static let maximumComparedCharacters = 800

  /// Pairs of (recognized, corrected) words, or nothing when the field no
  /// longer holds a recognizable copy of the dictation.
  public static func pairs(inserted: String, fieldContents: String) -> [DictationEditPair] {
    let source = Array(inserted.trimmingCharacters(in: .whitespacesAndNewlines))
    let field = Array(fieldContents)
    guard source.count >= 2, source.count <= maximumComparedCharacters,
      !field.isEmpty, field.count <= maximumComparedCharacters * 3
    else { return [] }
    var codes: [Character: Int32] = [:]
    let sourceCodes = encode(source, into: &codes)
    let fieldCodes = encode(field, into: &codes)
    guard let span = locate(sourceCodes, in: fieldCodes) else { return [] }
    guard span.codes != sourceCodes else { return [] }
    return substitutions(from: source, sourceCodes, to: Array(field[span.range]), span.codes)
  }

  private static func encode(_ text: [Character], into codes: inout [Character: Int32]) -> [Int32] {
    text.map { character in
      if let code = codes[character] { return code }
      let code = Int32(codes.count)
      codes[character] = code
      return code
    }
  }

  /// The part of the field that is what we inserted, with whatever the user
  /// typed before or after it trimmed off.
  private static func locate(
    _ source: [Int32], in field: [Int32]
  ) -> (range: Range<Int>, codes: [Int32])? {
    var best: (score: Int, range: Range<Int>)?
    let slack = max(4, source.count / 4)
    for start in candidateStarts(for: source, in: field) {
      let end = min(field.count, start + source.count + slack)
      guard start < end else { continue }
      let window = Array(field[start..<end])
      let table = SubsequenceTable(source, window)
      guard let matched = matchedRange(source, window, table: table) else { continue }
      let score = Int(table[0, 0])
      if score > (best?.score ?? 0) {
        best = (score, (start + matched.lowerBound)..<(start + matched.upperBound))
      }
    }
    guard let best, Double(best.score) / Double(source.count) >= minimumSimilarity else {
      return nil
    }
    return (best.range, Array(field[best.range]))
  }

  /// Where the insertion may begin: anchored on runs of its own characters, so
  /// a long document costs a handful of comparisons instead of one per
  /// character. The start of the field covers a composer we filled ourselves.
  private static func candidateStarts(for source: [Int32], in field: [Int32]) -> [Int] {
    var starts: Set<Int> = [0]
    let anchorLength = min(8, source.count)
    let offsets = Set([0, max(0, source.count / 2 - anchorLength / 2), source.count - anchorLength])
    for offset in offsets {
      let anchor = Array(source[offset..<(offset + anchorLength)])
      var index = 0
      while index + anchor.count <= field.count {
        if Array(field[index..<(index + anchor.count)]) == anchor {
          starts.insert(max(0, index - offset))
          break
        }
        index += 1
      }
    }
    return starts.sorted()
  }

  /// The window trimmed to the dictation itself, so text the user typed around
  /// it is not read as an edit.
  ///
  /// A word the user fixed at the very start or end has nothing to line up
  /// with, so the trim keeps as many characters beyond the outermost match as
  /// the dictation has left unmatched there — a replacement is about as long
  /// as what it replaced — and no more, which is what keeps "明天…评审会" from
  /// swallowing the "，麻烦你提前到一下" typed after it.
  private static func matchedRange(
    _ source: [Int32], _ window: [Int32], table: SubsequenceTable
  ) -> Range<Int>? {
    var left = 0
    var right = 0
    var firstSource: Int?
    var lastSource = 0
    var first: Int?
    var last: Int?
    while left < source.count, right < window.count {
      if source[left] == window[right] {
        if first == nil {
          first = right
          firstSource = left
        }
        last = right
        lastSource = left
        left += 1
        right += 1
      } else if table[left + 1, right] >= table[left, right + 1] {
        left += 1
      } else {
        right += 1
      }
    }
    guard let first, let last, let firstSource else { return nil }
    let start = max(0, first - firstSource)
    let end = min(window.count, last + 1 + (source.count - 1 - lastSource))
    return start..<end
  }

  /// Character runs that differ, kept only when both sides are short enough to
  /// be a misheard word rather than a rewrite.
  static func substitutions(
    from source: [Character], _ sourceCodes: [Int32],
    to target: [Character], _ targetCodes: [Int32]
  ) -> [DictationEditPair] {
    var pairs: [DictationEditPair] = []
    let table = SubsequenceTable(sourceCodes, targetCodes)
    var left = 0
    var right = 0
    while left < source.count || right < target.count {
      if left < source.count, right < target.count, sourceCodes[left] == targetCodes[right] {
        left += 1
        right += 1
        continue
      }
      let runStartLeft = left
      let runStartRight = right
      while left < source.count || right < target.count {
        if left < source.count, right < target.count, sourceCodes[left] == targetCodes[right] {
          break
        }
        if left >= source.count {
          right += 1
        } else if right >= target.count {
          left += 1
        } else if table[left + 1, right] >= table[left, right + 1] {
          left += 1
        } else {
          right += 1
        }
      }
      let recognized = String(source[runStartLeft..<left])
      let corrected = String(target[runStartRight..<right])
      guard !recognized.isEmpty, !corrected.isEmpty,
        recognized.count <= maximumPairCharacters, corrected.count <= maximumPairCharacters,
        recognized.contains(where: { $0.isLetter || $0.isNumber }),
        corrected.contains(where: { $0.isLetter || $0.isNumber })
      else { continue }
      pairs.append(DictationEditPair(recognized: recognized, corrected: corrected))
    }
    return pairs
  }

}

/// `self[i, j]` is the longest common subsequence of the suffixes starting at
/// `i` and `j`. Both the trimming and the diff walk it backwards. One flat
/// buffer, because an array of arrays costs more than the comparison itself.
struct SubsequenceTable {
  private let columns: Int
  private var storage: [Int32]

  init(_ a: [Int32], _ b: [Int32]) {
    columns = b.count + 1
    storage = [Int32](repeating: 0, count: (a.count + 1) * columns)
    storage.withUnsafeMutableBufferPointer { table in
      for i in stride(from: a.count - 1, through: 0, by: -1) {
        let row = i * columns
        let next = row + columns
        for j in stride(from: b.count - 1, through: 0, by: -1) {
          table[row + j] =
            a[i] == b[j]
            ? table[next + j + 1] + 1 : max(table[next + j], table[row + j + 1])
        }
      }
    }
  }

  subscript(i: Int, j: Int) -> Int32 { storage[i * columns + j] }
}
