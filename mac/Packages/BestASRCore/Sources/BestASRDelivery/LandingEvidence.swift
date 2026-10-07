import Foundation

/// What shows that pasted words arrived: the field read before ⌘V and the
/// same field read after it.
///
/// "The field's text changed" is not enough (2026-10-05, DELIVERY.md 原因 3):
/// the element asked after ⌘V used to be whichever one had the keyboard by
/// then, so a focus that moved — or a field that changed for any other
/// reason — counted as the words landing. The words themselves have to be
/// seen: the same field shows them more times than it did before. Where a
/// field reports no text at all but does report its caret, the caret moving
/// on by exactly the words' length is the one other observation accepted.
enum LandingEvidence {
  /// Text as a field may show it: compatibility-normalized, without
  /// whitespace, line breaks, zero-width characters or object replacement
  /// characters. A field may wrap, join or re-space what was pasted (a
  /// single-line field drops line breaks; a rich editor turns them into
  /// paragraphs; an editor puts a no-break space where a space was).
  static func comparable(_ text: String) -> String {
    let normalized = text.precomposedStringWithCompatibilityMapping
    var scalars = String.UnicodeScalarView()
    for scalar in normalized.unicodeScalars where !ignored(scalar) {
      scalars.append(scalar)
    }
    return String(scalars)
  }

  private static func ignored(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isWhitespace { return true }
    switch scalar.value {
    case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFC: return true
    default: return false
    }
  }

  /// How many times `needle` appears in `haystack`, without overlaps. Both
  /// are already comparable.
  static func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [.literal], range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }

  /// True only when the words were seen to arrive in the field `before` and
  /// `after` were both read from.
  static func landed(_ words: String, before: FocusedText, after: FocusedText) -> Bool {
    let needle = comparable(words)
    guard !needle.isEmpty else { return false }
    if let old = before.value, let new = after.value {
      return occurrences(of: needle, in: comparable(new))
        > occurrences(of: needle, in: comparable(old))
    }
    guard before.value == nil, after.value == nil,
      let start = before.selectionLocation, let end = after.selectionLocation,
      after.selectionLength == 0
    else { return false }
    return end == start + (words as NSString).length
  }
}
