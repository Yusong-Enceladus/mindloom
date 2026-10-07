import Foundation

/// A word the user corrected: written `heard` by dictation, changed to
/// `written` by them.
public struct LearnedCorrectionCandidate: Equatable, Hashable, Sendable {
  public let heard: String
  public let written: String

  public init(heard: String, written: String) {
    self.heard = heard
    self.written = written
  }
}

/// Where a correction was seen (ALIGNMENT 收1-8).
public enum CorrectionSource: String, Codable, Equatable, Sendable {
  /// The user edited a dictation in the App's field after it was typed in
  /// (Codex, native Apps: anything that shows its text to accessibility).
  case field
  /// The user selected the wrong word and said the right one with fn+space
  /// (Claude, WeChat: Apps that show no text).
  case selection
  /// The user corrected a dictation's text in Mindloom's history.
  case history
}

/// Turns what the user corrected into words to learn.
///
/// The rules follow what Typeless and VoiceInk publish (typeless.com help,
/// "History and Dictionary"; tryvoiceink.com "Dictionary Auto Learn"): only a
/// word or two replaced by something that sounds alike counts. A rewrite, a
/// change of case, a changed number, punctuation, or text added around the
/// dictation teaches nothing, because a wrong pair would make every later
/// dictation write a word the user never said.
///
/// A correction seen once is used as a replacement only; seen twice, the word
/// also joins what the recognizer is told to expect (the store counts).
public enum CorrectionLearning {
  /// More substitutions than this in one dictation is a rewrite.
  public static let maximumCorrectionsPerEdit = 3
  /// Shortest a learned word may be (the dictionary's replacement skips
  /// one-character surfaces, which would rewrite every occurrence).
  public static let minimumWordCharacters = 2
  /// Longest a learned word may be.
  public static let maximumWordCharacters = 24
  /// How alike the two must sound (0…1).
  public static let minimumSimilarity = 0.5
  /// For two Chinese words: their toneless pinyin nearly the same (在座 and
  /// 在坐, 张三 and 张珊). 明天 and 后天 (0.5) is a change of mind, not a
  /// word misheard, and a replacement learned from it would rewrite every
  /// later 明天.
  public static let minimumHanSimilarity = 0.75

  /// Whether `heard` → `written` may be learned: a word or two each, not a
  /// change of case or of a number, and sounding alike enough.
  public static func isLearnable(heard: String, written: String) -> Bool {
    guard isWordLike(heard), isWordLike(written), !sameIgnoringCaseAndWidth(heard, written),
      !changesANumber(DictationEditPair(recognized: heard, corrected: written))
    else { return false }
    return similarity(heard, written) >= requiredSimilarity(heard, written)
  }

  static func requiredSimilarity(_ a: String, _ b: String) -> Double {
    func isHanOnly(_ text: String) -> Bool {
      let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
      return !letters.isEmpty && letters.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }
    return isHanOnly(a) && isHanOnly(b) ? minimumHanSimilarity : minimumSimilarity
  }

  // MARK: - Sources

  /// From a dictation the App typed into a field and what the field now
  /// shows (`DictationEditExtractor` finds the dictation in it).
  public static func fromField(
    inserted: String, fieldContents: String
  ) -> [LearnedCorrectionCandidate] {
    guard let edits = DictationEditExtractor.edits(inserted: inserted, fieldContents: fieldContents)
    else { return [] }
    return candidates(edits)
  }

  /// From a dictation's text and the user's edit of it in history.
  public static func fromEdit(original: String, edited: String) -> [LearnedCorrectionCandidate] {
    guard let edits = DictationEditExtractor.edits(inserted: original, fieldContents: edited)
    else { return [] }
    return candidates(edits)
  }

  /// Leading words that say "this is the right one" before the word itself.
  static let correctionCues = [
    "应该写成", "正确的是", "替换成", "替换为", "应该是", "改成", "改为", "换成", "写成", "是",
  ]
  /// Words that make what was said an instruction about the selection, not
  /// the word to write instead of it: what to do, and what form to put it in
  /// (「改成英文」 over a sentence asks for a translation, not for the word
  /// 英文, review 10-6 S8).
  static let instructionWords = [
    "翻译", "总结", "解释", "帮我", "请", "润色", "改写", "扩写", "缩短", "正式", "口语",
    "语气", "简洁", "一点", "一些", "什么", "怎么", "为什么", "吗",
    "英文", "英语", "中文", "汉语", "日文", "日语", "韩文", "法文", "德文", "大写", "小写",
    "繁体", "简体", "列表", "表格", "要点", "段落", "标题", "格式", "拼音",
    "translate", "summar", "rewrite", "explain", "shorter", "longer", "formal", "make ",
    "english", "chinese", "uppercase", "lowercase", "bullet", "list",
  ]

  /// fn+space over a selection: when the selection is a word or two and
  /// what was said is a word or two that sounds like it — after a cue such
  /// as "改成", "应该是" as well — the selection is replaced by what was said.
  /// A cue alone is not enough: 「改成英文」 over 「早上好」 is an instruction
  /// (review 10-6 S8), and 「改成后天」 over 明天 is a change of meaning the
  /// text model handles. The pair is learned only when `isLearnable`.
  /// Anything else stays an instruction for the text model.
  public static func fromSelection(
    selection: String, spoken: String
  ) -> LearnedCorrectionCandidate? {
    let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    var said = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = said.last, "。.!！?？，,、；;：:".contains(last) { said.removeLast() }
    guard isWordLike(selected), !said.isEmpty else { return nil }
    let lowered = said.lowercased()
    guard !instructionWords.contains(where: { lowered.contains($0) }) else { return nil }
    for cue in correctionCues where said.hasPrefix(cue) && said.count > cue.count {
      said = String(said.dropFirst(cue.count)).trimmingCharacters(in: .whitespaces)
      break
    }
    guard isWordLike(said), !sameIgnoringCaseAndWidth(selected, said),
      similarity(selected, said) >= requiredSimilarity(selected, said)
    else { return nil }
    return LearnedCorrectionCandidate(heard: selected, written: said)
  }

  // MARK: - Edits → words

  /// The dictation as inserted and as the field shows it (located by
  /// `DictationEditExtractor`), compared word by word: a Latin word is one
  /// token, a Chinese character is one, spaces and punctuation are their
  /// own. A word replaced by another is a candidate; text added or removed
  /// anywhere in the dictation means the user was writing, and nothing is
  /// learned from that edit.
  static func candidates(_ edits: DictationEdits) -> [LearnedCorrectionCandidate] {
    let source = tokens(edits.source)
    let target = tokens(edits.target)
    var substitutions: [(Range<Int>, Range<Int>)] = []
    for run in joinedAcrossSpaces(differingRuns(source, target), source: source, target: target) {
      let heard = source[run.0].joined()
      let written = target[run.1].joined()
      let meaningful = { (text: String) in text.contains { $0.isLetter || $0.isNumber } }
      if run.0.isEmpty || run.1.isEmpty {
        // Added or removed: punctuation and spaces may change freely.
        if meaningful(heard) || meaningful(written) { return [] }
        continue
      }
      guard meaningful(heard) || meaningful(written) else { continue }
      substitutions.append(run)
    }
    guard !substitutions.isEmpty, substitutions.count <= maximumCorrectionsPerEdit else {
      return []
    }
    var result: [LearnedCorrectionCandidate] = []
    for run in substitutions {
      guard let candidate = word(around: run, source: source, target: target),
        !result.contains(candidate)
      else { continue }
      result.append(candidate)
    }
    return result
  }

  static func tokens(_ characters: [Character]) -> [String] {
    var result: [String] = []
    var word = ""
    func isWordCharacter(_ character: Character) -> Bool {
      (character.isASCII && (character.isLetter || character.isNumber))
        || character == "'" || character == "’" || character == "-"
    }
    for character in characters {
      if isWordCharacter(character) {
        word.append(character)
        continue
      }
      if !word.isEmpty {
        result.append(word)
        word = ""
      }
      result.append(String(character))
    }
    if !word.isEmpty { result.append(word) }
    return result
  }

  /// Runs where the two token lists differ, from their longest common
  /// subsequence.
  static func differingRuns(_ a: [String], _ b: [String]) -> [(Range<Int>, Range<Int>)] {
    var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    var runs: [(Range<Int>, Range<Int>)] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      if i < a.count, j < b.count, a[i] == b[j] {
        i += 1
        j += 1
        continue
      }
      let startI = i
      let startJ = j
      while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] { break }
        if i >= a.count {
          j += 1
        } else if j >= b.count {
          i += 1
        } else if table[i + 1][j] >= table[i][j + 1] {
          i += 1
        } else {
          j += 1
        }
      }
      runs.append((startI..<i, startJ..<j))
    }
    return runs
  }

  /// Runs with nothing but spaces between them, on both sides, joined into
  /// one: 「cloud code」 → 「Claude Code」 is one correction, and cutting
  /// 「cloud」 → 「Claude」 out of it would rewrite every later 「Google Cloud」
  /// (review 10-6 S7).
  static func joinedAcrossSpaces(
    _ runs: [(Range<Int>, Range<Int>)], source: [String], target: [String]
  ) -> [(Range<Int>, Range<Int>)] {
    func onlySpaces(_ tokens: ArraySlice<String>) -> Bool {
      !tokens.isEmpty && tokens.allSatisfy { $0.allSatisfy(\.isWhitespace) }
    }
    var joined: [(Range<Int>, Range<Int>)] = []
    for run in runs {
      if let last = joined.last, !last.0.isEmpty, !last.1.isEmpty, !run.0.isEmpty,
        !run.1.isEmpty,
        onlySpaces(source[last.0.upperBound..<run.0.lowerBound]),
        onlySpaces(target[last.1.upperBound..<run.1.lowerBound])
      {
        joined[joined.count - 1] = (
          last.0.lowerBound..<run.0.upperBound, last.1.lowerBound..<run.1.upperBound
        )
      } else {
        joined.append(run)
      }
    }
    return joined
  }

  /// One replaced word, widened for Chinese to at least two characters with
  /// the unchanged characters around it (the same on both sides), so the
  /// replacement it becomes only matches where that word appears.
  static func word(
    around run: (Range<Int>, Range<Int>), source: [String], target: [String]
  ) -> LearnedCorrectionCandidate? {
    var left = run.0.lowerBound
    var right = run.0.upperBound
    var targetLeft = run.1.lowerBound
    var targetRight = run.1.upperBound
    func isHan(_ token: String) -> Bool {
      token.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
    func length(_ tokens: ArraySlice<String>) -> Int { tokens.joined().count }
    var steps = 0
    while length(source[left..<right]) < minimumWordCharacters
      || length(target[targetLeft..<targetRight]) < minimumWordCharacters,
      steps < 4
    {
      steps += 1
      if left > 0, targetLeft > 0, isHan(source[left - 1]),
        source[left - 1] == target[targetLeft - 1]
      {
        left -= 1
        targetLeft -= 1
      } else if right < source.count, targetRight < target.count, isHan(source[right]),
        source[right] == target[targetRight]
      {
        right += 1
        targetRight += 1
      } else {
        break
      }
    }
    let heard = source[left..<right].joined().trimmingCharacters(in: .whitespaces)
    let written = target[targetLeft..<targetRight].joined().trimmingCharacters(in: .whitespaces)
    let changedHeard = source[run.0].joined()
    let changedWritten = target[run.1].joined()
    guard isLearnable(heard: heard, written: written),
      !changesANumber(DictationEditPair(recognized: changedHeard, corrected: changedWritten))
    else { return nil }
    return LearnedCorrectionCandidate(heard: heard, written: written)
  }

  // MARK: - Tests on words

  /// A word or two: no line breaks or sentence punctuation, at most four
  /// space-separated words, within the length limits.
  static func isWordLike(_ text: String) -> Bool {
    guard text.count >= minimumWordCharacters, text.count <= maximumWordCharacters,
      !text.contains(where: { $0.isNewline || "。！？!?；;，,".contains($0) }),
      text.contains(where: { $0.isLetter })
    else { return false }
    return text.split(separator: " ").count <= 4
  }

  static func sameIgnoringCaseAndWidth(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
  }

  static let numerals = Set("0123456789０１２３４５６７８９零〇一二两三四五六七八九十百千万亿")

  /// A changed number is a fact the user fixed, not a word misheard: the
  /// corrected text has a numeral (三十 → 四十, 几点 → 三点). A numeral that
  /// became a word (张三 → 张珊) is a name misheard as a number and may be
  /// learned.
  static func changesANumber(_ pair: DictationEditPair) -> Bool {
    pair.corrected.contains(where: { numerals.contains($0) })
  }

  /// How alike two words sound, 0…1: Chinese is compared as toneless pinyin,
  /// everything as lowercase letters and digits, by edit distance.
  public static func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(phonetic(a))
    let y = Array(phonetic(b))
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    let distance = levenshtein(x, y)
    return 1 - Double(distance) / Double(max(x.count, y.count))
  }

  static func phonetic(_ text: String) -> String {
    let latin =
      text.applyingTransform(.mandarinToLatin, reverse: false)?
      .applyingTransform(.stripDiacritics, reverse: false) ?? text
    return String(
      latin.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII
      }.map(Character.init))
  }

  static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    var previous = Array(0...b.count)
    for (i, ca) in a.enumerated() {
      var current = [i + 1]
      for (j, cb) in b.enumerated() {
        current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
      }
      previous = current
    }
    return previous[b.count]
  }
}
