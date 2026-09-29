import Foundation

/// Decides whether a cleanup model's rewrite may be inserted.
///
/// The personal cleanup model is trained to delete fillers, stutters and
/// abandoned restarts, not to reword. A pilot that was allowed to reword moved
/// the text closer to the user's reference style but changed words the user
/// had actually said, so an accepted rewrite must be almost entirely made of
/// characters that came out of the recognizer. Digits are exempt because
/// writing 百分之五 as 5% is a formatting change the user asked for.
public enum DictationCleanupGuard {
  /// The share of characters the model may introduce, ignoring digits. At 1%
  /// the personal model's text keeps the recognizer's own verified precision
  /// (97.78% against the user's corrected transcripts, raw 97.82%) while
  /// still cleaning up 193 of 240 evaluation dictations.
  public static let introducedCharacterLimit = 0.01
  /// A cleanup that drops more than this share of the dictation is a
  /// summary, not a cleanup.
  public static let minimumKeptShare = 0.5

  /// The model's text when it is faithful to the recognizer's, otherwise nil.
  public static func accepted(_ candidate: String, raw: String) -> String? {
    let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("<|"), value.utf8.count <= 16_384 else { return nil }
    let cleaned = comparable(value)
    let source = comparable(raw)
    guard !cleaned.isEmpty, !source.isEmpty else { return nil }
    guard Double(cleaned.count) >= Double(source.count) * minimumKeptShare else { return nil }
    let kept = longestCommonSubsequenceLength(cleaned, source)
    let introduced = Double(cleaned.count - kept) / Double(cleaned.count)
    return introduced <= introducedCharacterLimit ? value : nil
  }

  /// Lowercased word characters only: punctuation, spaces and digits drop out,
  /// so only a real wording change counts as introduced text.
  static func comparable(_ text: String) -> [Character] {
    Array(text.lowercased().filter(\.isLetter))
  }

  static func longestCommonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var previous = [Int](repeating: 0, count: b.count + 1)
    var current = previous
    for left in a {
      for (index, right) in b.enumerated() {
        current[index + 1] =
          left == right ? previous[index] + 1 : max(previous[index + 1], current[index])
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}
