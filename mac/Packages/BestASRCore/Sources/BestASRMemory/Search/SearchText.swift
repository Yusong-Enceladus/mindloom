import Foundation

/// Lexical normalization shared by the record search index and the queries
/// (B4 §3.2a). Both sides go through the same steps, so what the user types
/// and what was said meet in one form:
///
/// - compatibility forms folded (full-width Ａ１ → A1, ﹐ → ,), case folded;
/// - traditional Chinese characters read as simplified (們 → 们);
/// - Chinese text cut into two-character grams (穹顶具身 → 穹顶 顶具 具身), with
///   each character also kept alone for one-character searches;
/// - each Chinese character also read as toneless pinyin, in two-syllable
///   grams (穹顶 → qiongding), so a homophone typo (穹鼎) still meets it;
/// - Latin words split at camel case and letter/digit seams (GripDiff → grip
///   diff, Twin7 → twin 7), and neighbouring words also joined (grip diff →
///   gripdiff), so spacing and casing never decide a match.
///
/// Pure and deterministic; the per-character readings are cached.
public enum SearchText {
  /// The characters searched as a run without spaces (Han ideographs and
  /// kana).
  public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF,
      0x2A700...0x2EBEF, 0x30000...0x3134F:
      return true
    case 0x3040...0x30FF:  // hiragana, katakana
      return true
    case 0x3005, 0x3007:  // 々 〇
      return true
    default:
      return false
    }
  }

  /// Letters and digits outside the Han runs (Latin, Greek, Cyrillic, digits…).
  public static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    guard !isHan(scalar) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
  }

  /// Compatibility forms folded (full width → half width), lower case,
  /// traditional → simplified, diacritics kept off. The result keeps every
  /// separator, so it can be shown and searched again.
  public static func normalize(_ text: String) -> String {
    let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
    var out = String.UnicodeScalarView()
    out.reserveCapacity(folded.unicodeScalars.count)
    for scalar in folded.unicodeScalars {
      if isHan(scalar) {
        out.append(contentsOf: HanReadings.shared.simplified(scalar).unicodeScalars)
      } else if let plain = latinPlain(scalar) {
        out.append(plain)
      } else {
        out.append(scalar)
      }
    }
    return String(out)
  }

  /// é → e, ü → u (one scalar each); nil when nothing changes.
  private static func latinPlain(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
    guard scalar.value >= 0xC0, scalar.value < 0x250 else { return nil }
    let stripped = String(scalar).folding(options: .diacriticInsensitive, locale: nil)
    guard stripped.unicodeScalars.count == 1, let first = stripped.unicodeScalars.first,
      first != scalar
    else { return nil }
    return first
  }

  /// The toneless pinyin of one Han character ("" for kana and characters
  /// with no Mandarin reading).
  public static func pinyin(_ scalar: Unicode.Scalar) -> String {
    HanReadings.shared.pinyin(scalar)
  }

  /// The tokens of one text for the index, column by column (space
  /// separated, already normalized). At most `limit` characters are read.
  public static func indexTokens(_ text: String, limit: Int = 200_000) -> IndexedText {
    var body: [String] = []
    var uni: [String] = []
    var pin: [String] = []
    var previousWord: (text: String, endedAt: Int)?
    for run in runs(of: text, limit: limit) {
      switch run.kind {
      case .han(let characters):
        if characters.count >= 2 {
          for index in 0..<(characters.count - 1) {
            body.append(characters[index] + characters[index + 1])
          }
        }
        uni.append(contentsOf: characters)
        let syllables = characters.map { HanReadings.shared.pinyin($0.unicodeScalars.first!) }
        if syllables.count >= 2 {
          for index in 0..<(syllables.count - 1)
          where !syllables[index].isEmpty && !syllables[index + 1].isEmpty {
            pin.append(syllables[index] + syllables[index + 1])
          }
        }
        previousWord = nil
      case .word(let original):
        let lower = original.lowercased()
        body.append(lower)
        let parts = wordParts(original)
        if parts.count > 1 { body.append(contentsOf: parts) }
        // Neighbouring words separated by one space, dash, dot or underscore
        // are also kept joined (grip diff → gripdiff).
        if let previous = previousWord, run.start - previous.endedAt <= 1 {
          body.append(previous.text + lower)
        }
        previousWord = (lower, run.end)
      }
    }
    return IndexedText(
      body: body.joined(separator: " "), uni: uni.joined(separator: " "),
      pin: pin.joined(separator: " "))
  }

  /// A camel-case or letter/digit compound split into its lower-case parts
  /// (GripDiff → [grip, diff]; HTTPServer → [http, server]; Twin7 → [twin, 7]).
  /// A plain word gives one part.
  public static func wordParts(_ word: String) -> [String] {
    let scalars = Array(word.unicodeScalars)
    guard scalars.count > 1 else { return [word.lowercased()] }
    var parts: [String] = []
    var current = String.UnicodeScalarView()
    func kind(_ s: Unicode.Scalar) -> Int {
      if CharacterSet.decimalDigits.contains(s) { return 0 }
      if CharacterSet.uppercaseLetters.contains(s) { return 1 }
      return 2
    }
    for index in scalars.indices {
      let scalar = scalars[index]
      if index > 0 {
        let a = kind(scalars[index - 1])
        let b = kind(scalar)
        var split = false
        if (a == 0) != (b == 0) { split = true }  // letter ↔ digit
        if a == 2 && b == 1 { split = true }  // lower → Upper
        // UPPERWord: split before the last capital of a capital run.
        if a == 1 && b == 1, index + 1 < scalars.count, kind(scalars[index + 1]) == 2 {
          split = true
        }
        if split, !current.isEmpty {
          parts.append(String(current).lowercased())
          current = String.UnicodeScalarView()
        }
      }
      current.append(scalar)
    }
    if !current.isEmpty { parts.append(String(current).lowercased()) }
    return parts
  }

  /// The words of a text as written (system word boundaries; spaces and
  /// punctuation left out), for picking a misheard word (加进词典).
  public static func displayWords(_ text: String, limit: Int = 200) -> [String] {
    var words: [String] = []
    let cf = text as CFString
    let tokenizer = CFStringTokenizerCreate(
      nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary,
      Locale(identifier: "zh_CN") as CFLocale)
    let ns = text as NSString
    var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
    while type != [], words.count < limit {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      let word = ns.substring(with: NSRange(location: range.location, length: range.length))
      if word.unicodeScalars.contains(where: { isHan($0) || isWordCharacter($0) }) {
        words.append(word)
      }
      type = CFStringTokenizerAdvanceToNextToken(tokenizer)
    }
    return words
  }

  /// One stretch of a text: a Han run (normalized characters) or one word
  /// (compatibility-folded, case kept for the camel split). `start`/`end`
  /// count scalars of the folded text, so neighbouring words can be found.
  public struct Run: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case han([String])
      case word(String)
    }

    public let kind: Kind
    public let start: Int
    public let end: Int
  }

  /// The runs of a text, in order (separators dropped).
  public static func runs(of text: String, limit: Int = .max) -> [Run] {
    let folded = text.precomposedStringWithCompatibilityMapping
    var runs: [Run] = []
    var han: [String] = []
    var word = String.UnicodeScalarView()
    var start = 0
    var position = 0
    func flushHan() {
      if !han.isEmpty { runs.append(Run(kind: .han(han), start: start, end: position)) }
      han = []
    }
    func flushWord() {
      if !word.isEmpty { runs.append(Run(kind: .word(String(word)), start: start, end: position)) }
      word = String.UnicodeScalarView()
    }
    for scalar in folded.unicodeScalars {
      if position >= limit { break }
      if isHan(scalar) {
        flushWord()
        if han.isEmpty { start = position }
        han.append(HanReadings.shared.simplified(scalar))
      } else if isWordCharacter(scalar) {
        flushHan()
        if word.isEmpty { start = position }
        word.append(latinPlain(scalar) ?? scalar)
      } else {
        flushHan()
        flushWord()
      }
      position += 1
    }
    flushHan()
    flushWord()
    return runs
  }
}

/// The index's columns for one record (space-separated tokens).
public struct IndexedText: Equatable, Sendable {
  /// Two-character grams of the Han runs, and the words.
  public let body: String
  /// Each Han character alone.
  public let uni: String
  /// Two-syllable toneless pinyin grams.
  public let pin: String

  public init(body: String, uni: String, pin: String) {
    self.body = body
    self.uni = uni
    self.pin = pin
  }
}

/// Per-character readings (simplified form, toneless pinyin), computed once
/// per character with the system's transforms and kept for the process.
final class HanReadings: @unchecked Sendable {
  static let shared = HanReadings()
  private let lock = NSLock()
  private var simplifiedCache: [UInt32: String] = [:]
  private var pinyinCache: [UInt32: String] = [:]

  func simplified(_ scalar: Unicode.Scalar) -> String {
    lock.lock()
    if let hit = simplifiedCache[scalar.value] {
      lock.unlock()
      return hit
    }
    lock.unlock()
    let single = String(scalar)
    var value = single
    if !(0x3040...0x30FF).contains(scalar.value),
      let converted = single.applyingTransform(StringTransform("Hant-Hans"), reverse: false),
      converted.unicodeScalars.count == 1
    {
      value = converted
    }
    lock.lock()
    simplifiedCache[scalar.value] = value
    lock.unlock()
    return value
  }

  func pinyin(_ scalar: Unicode.Scalar) -> String {
    lock.lock()
    if let hit = pinyinCache[scalar.value] {
      lock.unlock()
      return hit
    }
    lock.unlock()
    var value = ""
    if !(0x3040...0x30FF).contains(scalar.value),
      let latin = String(scalar).applyingTransform(.mandarinToLatin, reverse: false)
    {
      let plain = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      let letters = plain.unicodeScalars.filter { ("a"..."z").contains($0) }
      // A character the transform did not read comes back as itself.
      if !letters.isEmpty, letters.count == plain.unicodeScalars.count {
        value = String(String.UnicodeScalarView(letters))
      }
    }
    lock.lock()
    pinyinCache[scalar.value] = value
    lock.unlock()
    return value
  }
}

/// The simplified form of one Han character (as the index reads it).
enum HanReadingsBridge {
  static func simplified(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    HanReadings.shared.simplified(scalar).unicodeScalars.first ?? scalar
  }
}
