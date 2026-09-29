import Foundation

/// What the dictation key was held as: the plain key, or one of its two
/// chords.
public enum SpokenMode: String, Sendable {
  /// Write down what was said.
  case dictate
  /// Write down what was said, in another language.
  case translate
  /// Treat what was said as an instruction, about the highlighted text when
  /// there is one.
  case command
}

/// What a finished dictation is for, decided from three things only: the
/// mode, the words, and whether anything was highlighted. Nothing here is
/// async and nothing here reaches an engine; producing the result is the
/// next step's job.
public enum SpokenJob: Equatable, Sendable {
  /// The words go in as they were said.
  case write
  /// `text` is translated into `language`. `replacing` says whether the
  /// result stands in for a highlight (an instruction about a selection) or
  /// for the words themselves (translate mode).
  case translate(String, to: String, replacing: Bool)
  /// The highlight is rewritten as the instruction says; the result takes
  /// its place.
  case transform(instruction: String, selection: String)
  /// A question or request whose answer is read, not written over anything.
  /// `about` is the highlight the question concerns, if any.
  case answer(instruction: String, about: String?)
  /// Nothing can be produced; this is what the user is told instead.
  case notice(String)
}

/// The routing table. Five rows, read top to bottom, exhaustively tested.
public enum SpokenJobComposer {
  public static let selectSomethingFirst = "先选中要翻译的文字，再说一遍"

  /// `translationLanguage` is the language the translate chord is aimed at
  /// right now. `targetForSelection` picks the language for "翻译一下" with
  /// no language named — the caller knows the user's preferences and can
  /// detect the highlight's language; this table need not.
  public static func compose(
    mode: SpokenMode,
    transcript: String,
    selection: String?,
    translationLanguage: String,
    targetForSelection: (String) -> String
  ) -> SpokenJob {
    let highlight = selection.flatMap { $0.isEmpty ? nil : $0 }
    switch mode {
    case .dictate:
      return .write
    case .translate:
      return .translate(transcript, to: translationLanguage, replacing: false)
    case .command:
      if SpokenTranslationRequest.asksToTranslate(transcript) {
        guard let highlight else { return .notice(selectSomethingFirst) }
        let language =
          SpokenTranslationRequest.language(in: transcript) ?? targetForSelection(highlight)
        return .translate(highlight, to: language, replacing: true)
      }
      guard let highlight else { return .answer(instruction: transcript, about: nil) }
      if SpokenInstructionIntent.showsAnswer(for: transcript) {
        return .answer(instruction: transcript, about: highlight)
      }
      return .transform(instruction: transcript, selection: highlight)
    }
  }
}
