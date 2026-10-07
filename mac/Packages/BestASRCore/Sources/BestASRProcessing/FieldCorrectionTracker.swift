import Foundation

/// What the user has made of one dictation in the field it was typed into,
/// followed while the App watches that field (ALIGNMENT 收1-8).
///
/// A chat App empties its field the moment the message is sent, usually a
/// few seconds after the user fixed the word, and a field the user goes on
/// writing in may by then hold the next message. Reading it once, when the
/// next dictation starts or after 90 seconds, saw neither the fix nor the
/// dictation (review 10-6 S10). So the field is read every second or two:
/// each reading that still holds the dictation replaces what was seen
/// before, and a reading that no longer holds it (emptied, sent, or another
/// text) leaves the last one standing.
public struct FieldCorrectionTracker: Equatable, Sendable {
  /// The delivery this follows (its idempotency key).
  public let key: String
  public let inserted: String
  /// The words fixed in the last reading that still held the dictation.
  public private(set) var corrections: [LearnedCorrectionCandidate] = []

  public init(key: String, inserted: String) {
    self.key = key
    self.inserted = inserted
  }

  /// One reading of the field (nil: gone or empty).
  public mutating func observe(_ fieldContents: String?) {
    guard let fieldContents, !fieldContents.isEmpty else { return }
    let dictation = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
    if !dictation.isEmpty, fieldContents.contains(dictation) {
      // The dictation stands as it was typed: a fix seen before was undone.
      corrections = []
      return
    }
    guard DictationEditExtractor.edits(inserted: inserted, fieldContents: fieldContents) != nil
    else { return }
    corrections = CorrectionLearning.fromField(inserted: inserted, fieldContents: fieldContents)
  }
}
