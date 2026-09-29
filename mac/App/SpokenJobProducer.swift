import BestASRProcessing
import Foundation

/// Turns a `SpokenJob` into what the insertion path delivers, and says what
/// else the app must do about it. Nothing here touches app state: the two
/// engines come in as functions, and the side effects go out as fields.
///
/// The local model's output goes through gates before it may replace a
/// highlight, because the highlight is the user's own draft and a wrong
/// rewrite written over it costs more than no rewrite. An answer that
/// fails a gate is shown instead of written, never silently dropped.
struct SpokenJobProducer: Sendable {
  /// System translation: nil when no installed language pair fits.
  var translate: @Sendable (_ text: String, _ language: String) async -> String?
  /// The local model following an instruction, about a highlight or not;
  /// nil when it could not.
  var follow: @Sendable (_ instruction: String, _ selection: String?) async -> String?

  struct Result: Equatable {
    var delivery: DictationDelivery
    /// Shown beside the field when the delivery does not land, so an
    /// answer aimed at read-only text is read rather than lost.
    var answerForPanel: String?
    /// A language the system can translate into once the user downloads it.
    var languagePackNeeded: String?
  }

  func produce(_ job: SpokenJob) async -> Result {
    switch job {
    case .write:
      return Result(delivery: .asIs)

    case .translate(let text, let language, let replacing):
      guard let translated = await translate(text, language) else {
        // No language pack. In translate mode the words go in as spoken —
        // a sentence in the wrong language is still the user's sentence —
        // and the download prompt follows. An instruction about a
        // highlight has nothing to fall back to, so the user is told.
        return replacing
          ? Result(
            delivery: .shown(Self.languagePackNotice(language)),
            answerForPanel: Self.languagePackNotice(language),
            languagePackNeeded: language)
          : Result(delivery: .asIs, languagePackNeeded: language)
      }
      return Result(delivery: .replaced(translated), answerForPanel: replacing ? translated : nil)

    case .transform(let instruction, let selection):
      guard let answer = await follow(instruction, selection) else {
        return Result(delivery: .unavailable)
      }
      guard Self.isAcceptableRewrite(answer, of: selection, instruction: instruction) else {
        return Result(delivery: .shown(answer), answerForPanel: answer)
      }
      return Result(delivery: .replaced(answer), answerForPanel: answer)

    case .answer(let instruction, let about):
      guard let answer = await follow(instruction, about) else {
        return Result(delivery: .unavailable)
      }
      // A question about a highlight is read beside it. An instruction with
      // nothing highlighted is written where the caret is, like any
      // dictation; the insertion path hands it back to be shown if there is
      // nowhere to write.
      return about == nil
        ? Result(delivery: .replaced(answer), answerForPanel: answer)
        : Result(delivery: .shown(answer), answerForPanel: answer)

    case .notice(let text):
      return Result(delivery: .shown(text), answerForPanel: text)
    }
  }

  static func languagePackNotice(_ language: String) -> String {
    "需要先下载\(language)语言包，下载后再试一次"
  }

  /// The gates a rewrite must pass to be written over the highlight: it is
  /// not the instruction echoed back, it is not empty, and it is not wildly
  /// longer than what it rewrites — a 1.7B model asked to shorten a line
  /// that comes back with four paragraphs has answered something else.
  static func isAcceptableRewrite(_ answer: String, of selection: String, instruction: String)
    -> Bool
  {
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return false }
    return trimmed.count <= max(4 * selection.count, 400)
  }
}
