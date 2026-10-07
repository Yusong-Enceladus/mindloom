import Foundation

/// Where the final text differs from what the live caption showed
/// (ALIGNMENT 收1-18): when the caption switches to the final text, the
/// letters and digits the final recognition changed are marked lightly, so
/// the user sees what was corrected without reading the line twice.
///
/// Punctuation and spacing are never marked (the final text is punctuated,
/// the live draft is not), nor are words after the point the live caption
/// had reached (they are new, not changed). When most of the line changed — a translation, an
/// instruction's result, a draft that never caught up — nothing is marked:
/// the final text is simply a different text.
public enum CaptionRevision {
  /// Above this share of changed letters the final text counts as new.
  public static let maximumChangedShare = 0.5

  /// Character ranges of `final` (offsets in `Character`s) not found, in
  /// order, in `live`.
  public static func revisedRanges(live: String, final: String) -> [Range<Int>] {
    let a = Array(live)
    let b = Array(final)
    guard !a.isEmpty, !b.isEmpty, a.count <= 2_000, b.count <= 2_000 else { return [] }
    func significant(_ character: Character) -> Bool { character.isLetter || character.isNumber }
    // Longest common subsequence over letters and digits only.
    let x = a.filter(significant).map { Character($0.lowercased()) }
    let yIndices = b.indices.filter { significant(b[$0]) }
    let y = yIndices.map { Character(b[$0].lowercased()) }
    guard !x.isEmpty, !y.isEmpty else { return [] }
    var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
    for i in stride(from: x.count - 1, through: 0, by: -1) {
      for j in stride(from: y.count - 1, through: 0, by: -1) {
        table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    var matched = Set<Int>()
    var lastLiveMatch = -1
    var i = 0
    var j = 0
    while i < x.count, j < y.count {
      if x[i] == y[j] {
        matched.insert(j)
        lastLiveMatch = i
        i += 1
        j += 1
      } else if table[i + 1][j] >= table[i][j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    // Words after the end of the live caption, when the caption ended on
    // a word the final text also has, are words it had not reached yet: new,
    // not revised, so they are not marked.
    let reachedEnd = lastLiveMatch == x.count - 1
    let lastMatched = matched.max() ?? -1
    let changed = y.indices.filter {
      !matched.contains($0) && !(reachedEnd && $0 > lastMatched)
    }
    // The share is taken over the part of the line the live caption covered.
    let covered = reachedEnd ? lastMatched + 1 : y.count
    guard !changed.isEmpty,
      Double(changed.count) / Double(max(1, covered)) <= maximumChangedShare
    else { return [] }
    // Back to offsets in `final`, joining neighbours.
    var ranges: [Range<Int>] = []
    for index in changed {
      let offset = yIndices[index]
      if let last = ranges.last, last.upperBound == offset {
        ranges[ranges.count - 1] = last.lowerBound..<(offset + 1)
      } else {
        ranges.append(offset..<(offset + 1))
      }
    }
    return ranges
  }
}
