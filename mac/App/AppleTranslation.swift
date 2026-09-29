import Foundation
import NaturalLanguage
import OSLog
import Translation

private let appleTranslationLogger = Logger(
  subsystem: "com.bestasr.app",
  category: "translation"
)

/// Translation through the system's own on-device engine, and nothing else.
///
/// Translating is not the same job as tidying a dictation, and the difference
/// is structural rather than a matter of degree. The local language model
/// survives the tidying job because that path only permits deletion — its
/// validator accepts a candidate only when it is a subsequence of the
/// transcript, so the model's freedom is clamped to what it can do and
/// anything outside falls back to rules. Translation has no such clamp
/// available: it rewrites every word by definition, so it meets the model's
/// ceiling head on. Four rounds of prompt work moved it between fluent and
/// complete without ever getting both, which is what a ceiling looks like.
///
/// macOS ships a translation engine built for exactly this. It runs on the
/// device, it costs this app no disk and no resident memory because the
/// system owns the models, and it is the same engine the rest of the Mac
/// translates with. There is no fallback to the local model: a wrong
/// translation written into someone's chat is worth less than the sentence as
/// spoken, so when a language is not installed the words go in as they were
/// said and the system's download prompt follows — see `TranslationInstaller`.
///
/// Nothing leaves the Mac: the system engine is on-device, and its language
/// packs are downloaded once, by the user, through the system's own prompt.
enum AppleTranslation {
  enum Availability: Equatable {
    /// Ready now.
    case installed
    /// The system can do this pair once the user downloads the language.
    case downloadable
    /// The system does not have this pair at all.
    case unsupported
    /// This Mac is too old for the framework.
    case unavailable
  }

  /// Whether the system can translate `text` into `language` right now.
  ///
  /// Asked of the text rather than of a language pair, because the source is
  /// whatever the user happened to say and the engine detects it better than
  /// a guess from the script would.
  static func availability(
    for text: String,
    intoLanguageNamed language: String
  ) async -> Availability {
    guard #available(macOS 26.0, *), let target = locale(for: language) else {
      return .unavailable
    }
    guard let status = try? await LanguageAvailability().status(for: text, to: target)
    else { return .unsupported }
    return resolve(status)
  }

  /// The same question asked of a language pair rather than of a sentence,
  /// for Settings, where there is no sentence yet.
  static func availability(
    fromLanguageNamed source: String,
    intoLanguageNamed language: String
  ) async -> Availability {
    guard #available(macOS 26.0, *),
      let target = locale(for: language),
      let sourceLocale = locale(for: source)
    else { return .unavailable }
    let status = await LanguageAvailability().status(from: sourceLocale, to: target)
    return resolve(status)
  }

  @available(macOS 26.0, *)
  private static func resolve(_ status: LanguageAvailability.Status) -> Availability {
    switch status {
    case .installed: .installed
    case .supported: .downloadable
    case .unsupported: .unsupported
    @unknown default: .unsupported
    }
  }

  /// Translates, or returns nil when no installed language pair fits. The
  /// caller then delivers the words as spoken and asks for the install.
  ///
  /// The source is not left to a language guesser alone. "三二一" — three
  /// numerals highlighted in WeChat — was guessed as Japanese, the ja→en
  /// pair was not installed, and the user was told to download a pack they
  /// already had. The script says what a guesser cannot on three characters:
  /// Han without kana is Chinese to someone who dictates in Chinese. Every
  /// candidate is tried in order, and the first installed pair is used.
  static func translate(
    _ text: String,
    intoLanguageNamed language: String
  ) async -> String? {
    guard #available(macOS 26.0, *), let target = locale(for: language) else { return nil }
    let candidates = sourceCandidates(for: text)
    if let first = candidates.first, first.minimalIdentifier == target.minimalIdentifier {
      return text
    }
    let availability = LanguageAvailability()
    for source in candidates where source.minimalIdentifier != target.minimalIdentifier {
      guard await (try? availability.status(from: source, to: target)) == .installed else {
        continue
      }
      let session = TranslationSession(installedSource: source, target: target)
      defer { session.cancel() }
      do {
        return try await session.translate(text).targetText
      } catch {
        appleTranslationLogger.notice("system translation failed")
        return nil
      }
    }
    return nil
  }

  /// Languages the text could be in, most likely first: what its script
  /// says, then what the recogniser says, then English for Latin text.
  static func sourceCandidates(for text: String) -> [Locale.Language] {
    var identifiers: [String] = []
    let scalars = text.unicodeScalars
    let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    let hasKana = scalars.contains {
      (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
    }
    let hasHangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) }
    let hasLatin = scalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    if hasKana { identifiers.append("ja") }
    if hasHangul { identifiers.append("ko") }
    if hasHan, !hasKana { identifiers.append(contentsOf: ["zh-Hans", "zh-Hant"]) }
    if let detected = detectedLanguage(of: text) { identifiers.append(detected.minimalIdentifier) }
    if hasLatin { identifiers.append("en") }
    var seen: Set<String> = []
    return identifiers.filter { seen.insert($0).inserted }.map(Locale.Language.init(identifier:))
  }

  /// The language names the app offers, in the identifiers the system uses.
  static func locale(for name: String) -> Locale.Language? {
    identifiers[name].map(Locale.Language.init(identifier:))
  }

  static let identifiers: [String: String] = [
    "简体中文": "zh-Hans", "繁体中文": "zh-Hant", "英语": "en", "日语": "ja",
    "韩语": "ko", "法语": "fr", "德语": "de", "西班牙语": "es", "俄语": "ru",
    "葡萄牙语": "pt", "意大利语": "it", "阿拉伯语": "ar",
  ]

  /// Recognisers are cheap to use and expensive to create, and creating one
  /// per dictation is what made the event organiser flood the log.
  private final class Recognizer: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer = NLLanguageRecognizer()

    func dominantLanguage(of text: String) -> Locale.Language? {
      lock.lock()
      defer { lock.unlock() }
      recognizer.reset()
      recognizer.processString(text)
      guard let dominant = recognizer.dominantLanguage, dominant != .undetermined
      else { return nil }
      return Locale.Language(identifier: dominant.rawValue)
    }
  }

  private static let recognizer = Recognizer()

  static func detectedLanguage(of text: String) -> Locale.Language? {
    recognizer.dominantLanguage(of: text)
  }
}
