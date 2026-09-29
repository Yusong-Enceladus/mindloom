import Foundation

public enum DictationProtectedFactCategory: String, Codable, CaseIterable, Sendable {
  case actionOwner
  case commitment
  case dateTime
  case dictionaryTerm
  case email
  case money
  case negation
  case number
  /// Kept as a compatibility umbrella for callers that predate the more
  /// precise number, money, percentage and date/time categories.
  case numberDateTimeAmount
  case percentage
  case structure
  case unsupportedFact
  case url
}

public struct DictationProtectedFactValidation: Codable, Equatable, Sendable {
  public let passed: Bool
  public let violatedCategories: [DictationProtectedFactCategory]

  public init(
    passed: Bool,
    violatedCategories: [DictationProtectedFactCategory]
  ) {
    self.passed = passed
    self.violatedCategories = violatedCategories
  }
}

/// A deliberately conservative, deterministic gate used before any generated
/// text can reach another application. Removing content is allowed, so filler
/// words and explicit self-corrections can be dropped. Adding/reordering content
/// or changing a protected relationship fails closed.
public enum DictationProtectedFactValidator {
  private static let numberPattern =
    #"[-+]?\d+(?:[.,]\d+)?"#
  private static let moneyPattern =
    #"(?:[$¥￥€£]\s*[-+]?\d+(?:[,.]\d+)*|(?:人民币|美元|美金|欧元|英镑|usd|rmb|cny|eur|gbp)\s*[-+]?\d+(?:[,.]\d+)*|[-+]?\d+(?:[,.]\d+)*\s*(?:元|美元|人民币|美金|欧元|英镑|usd|rmb|cny|eur|gbp))"#
  private static let percentagePattern =
    #"(?:百分之\s*[-+]?\d+(?:[.,]\d+)?|[-+]?\d+(?:[.,]\d+)?\s*(?:%|％|percent|per\s+cent))"#
  private static let dateTimePattern =
    #"(?:\d{4}[-/.年]\d{1,2}(?:[-/.月]\d{1,2}(?:日|号)?)?|\d{1,2}[:：]\d{2}(?::\d{2})?\s*(?:am|pm)?|(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?|\d{1,2}\s*(?:点|时)(?:\s*\d{1,2}\s*分?)?)"#
  private static let emailPattern =
    #"\b[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\b"#
  private static let urlPattern = #"\b(?:https?://|www\.)[^\s]+"#
  private static let negationPattern =
    #"\b(?:no|not|never|cannot|can't|won't|don't|doesn't|isn't|aren't|wasn't|weren't|didn't|shouldn't|mustn't|without)\b|(?:不是|不要|不会|不能|没有|未曾|无需|不得|不|没|未|无|别)"#
  private static let commitmentPattern =
    #"\b(?:will|shall|must|promise(?:d|s)?|agree(?:d|s)?|commit(?:ted|s)?|guarantee(?:d|s)?|need(?:s|ed)?\s+to|has\s+to|have\s+to|is\s+responsible\s+for|are\s+responsible\s+for)\b|(?:将会|必须|承诺|答应|保证|负责|需要|会|将)"#
  private static let ownerCuePattern =
    #"(will|shall|must|promise(?:d|s)?|agree(?:d|s)?|commit(?:ted|s)?|guarantee(?:d|s)?|need(?:s|ed)?\s+to|has\s+to|have\s+to|is\s+responsible\s+for|are\s+responsible\s+for|owns?|please|将会|必须|承诺|答应|保证|负责|需要|会|将|请)"#
  private static let ownerActionPattern =
    #"(?:\s|[,，])*?(?:not\s+|never\s+|不|别)?(?:to\s+)?(?:(?:um|uh|erm|hmm|嗯|呃)\s+)*([\p{L}\p{N}][\p{L}\p{N}_'’-]{0,63})"#

  public static func validate(
    source: String,
    candidate: String,
    dictionaryTerms: [String]
  ) -> DictationProtectedFactValidation {
    var violations = Set<DictationProtectedFactCategory>()
    let normalizedSource = normalize(source)
    let normalizedCandidate = normalize(candidate)

    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      != candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      violations.insert(.structure)
    }
    if candidate.utf8.count > max(4_096, source.utf8.count * 3 + 256) {
      violations.insert(.structure)
    }

    compareMatches(
      pattern: numberPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .number,
      into: &violations
    )
    compareMatches(
      pattern: moneyPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .money,
      into: &violations
    )
    compareMatches(
      pattern: percentagePattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .percentage,
      into: &violations
    )
    compareMatches(
      pattern: dateTimePattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .dateTime,
      into: &violations
    )
    if !violations.isDisjoint(with: [.number, .money, .percentage, .dateTime]) {
      violations.insert(.numberDateTimeAmount)
    }
    compareMatches(
      pattern: emailPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .email,
      into: &violations
    )
    compareMatches(
      pattern: urlPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .url,
      into: &violations,
      trimTrailingPunctuation: true
    )
    compareMatches(
      pattern: negationPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .negation,
      into: &violations
    )
    compareMatches(
      pattern: commitmentPattern,
      source: normalizedSource,
      candidate: normalizedCandidate,
      category: .commitment,
      into: &violations
    )

    let terms = Array(
      Set(dictionaryTerms.map(normalize).filter { !$0.isEmpty })
    ).sorted()
    for term in terms {
      if dictionaryOccurrenceCount(of: term, in: normalizedSource)
        != dictionaryOccurrenceCount(of: term, in: normalizedCandidate)
      {
        violations.insert(.dictionaryTerm)
      }
    }

    if actionOwnerRelations(in: normalizedSource, dictionaryTerms: terms)
      != actionOwnerRelations(in: normalizedCandidate, dictionaryTerms: terms)
    {
      violations.insert(.actionOwner)
    }

    if !contentScalars(normalizedCandidate).isSubsequence(
      of: contentScalars(normalizedSource)
    ) {
      violations.insert(.unsupportedFact)
    }

    let ordered = violations.sorted { $0.rawValue < $1.rawValue }
    return DictationProtectedFactValidation(
      passed: ordered.isEmpty,
      violatedCategories: ordered
    )
  }

  private static func compareMatches(
    pattern: String,
    source: String,
    candidate: String,
    category: DictationProtectedFactCategory,
    into violations: inout Set<DictationProtectedFactCategory>,
    trimTrailingPunctuation: Bool = false
  ) {
    let sourceValues = matches(
      pattern: pattern,
      in: source,
      trimTrailingPunctuation: trimTrailingPunctuation
    )
    let candidateValues = matches(
      pattern: pattern,
      in: candidate,
      trimTrailingPunctuation: trimTrailingPunctuation
    )
    if sourceValues != candidateValues { violations.insert(category) }
  }

  private static func matches(
    pattern: String,
    in text: String,
    trimTrailingPunctuation: Bool
  ) -> [String] {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let swiftRange = Range(match.range, in: text) else { return nil }
      var value = String(text[swiftRange])
        .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        .lowercased()
      if trimTrailingPunctuation {
        value = value.trimmingCharacters(
          in: CharacterSet(charactersIn: ".,;:!?，。；：！？、")
        )
      }
      return value
    }.sorted()
  }

  private static func actionOwnerRelations(
    in text: String,
    dictionaryTerms: [String]
  ) -> [String] {
    let fixedActors = [
      "i", "we", "you", "he", "she", "they",
      "我", "我们", "你", "你们", "他", "她", "他们", "她们",
    ]
    let actors = Array(Set(dictionaryTerms + fixedActors))
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
    var relations: [String] = []
    for actor in actors {
      let escaped = NSRegularExpression.escapedPattern(for: actor)
      let hasHan = actor.unicodeScalars.contains { scalar in
        (0x3400...0x4DBF).contains(scalar.value)
          || (0x4E00...0x9FFF).contains(scalar.value)
          || (0xF900...0xFAFF).contains(scalar.value)
      }
      let actorPattern =
        hasHan
        ? "(\(escaped))"
        : "(?<![\\p{L}\\p{N}])(\(escaped))(?![\\p{L}\\p{N}])"
      let forward =
        actorPattern + #"(?:\s|[,，])*?"# + ownerCuePattern
        + ownerActionPattern
      relations.append(contentsOf: capturedRelations(pattern: forward, in: text))

      if hasHan {
        let reverse =
          #"由\s*"# + actorPattern + #"\s*(负责)"#
          + ownerActionPattern
        relations.append(contentsOf: capturedRelations(pattern: reverse, in: text))
      }
    }
    return relations.sorted()
  }

  private static func capturedRelations(pattern: String, in text: String) -> [String] {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges == 4 else { return nil }
      let components = (1...3).compactMap { index -> String? in
        guard let swiftRange = Range(match.range(at: index), in: text) else {
          return nil
        }
        let component = String(text[swiftRange])
          .replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
          )
          .lowercased()
        return index == 3 ? canonicalAction(component) : component
      }
      guard components.count == 3 else { return nil }
      return components.joined(separator: "|")
    }
  }

  /// Chinese has no mandatory word boundaries, so the regex action capture can
  /// include the entire remainder of a sentence. Comparing that whole capture
  /// incorrectly rejects safe removal of a later filler or exact repetition.
  /// The leading two Han characters identify the action predicate while the
  /// global subsequence gate still prevents added or reordered content.
  private static func canonicalAction(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }
    guard scalars.contains(where: isHan) else { return value }
    return String(String.UnicodeScalarView(scalars.prefix(2)))
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
      0x20000...0x2EBEF:
      true
    default:
      false
    }
  }

  private static func dictionaryOccurrenceCount(
    of term: String,
    in text: String
  ) -> Int {
    let escaped = NSRegularExpression.escapedPattern(for: term)
    let hasHan = term.unicodeScalars.contains { scalar in
      (0x3400...0x4DBF).contains(scalar.value)
        || (0x4E00...0x9FFF).contains(scalar.value)
        || (0xF900...0xFAFF).contains(scalar.value)
    }
    let pattern =
      hasHan
      ? escaped
      : "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else { return 0 }
    return expression.numberOfMatches(
      in: text,
      range: NSRange(text.startIndex..<text.endIndex, in: text)
    )
  }

  private static func normalize(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: "‘", with: "'")
      .lowercased()
  }

  private static func contentScalars(_ value: String) -> [Unicode.Scalar] {
    value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
  }
}

extension Array where Element: Equatable {
  fileprivate func isSubsequence(of source: [Element]) -> Bool {
    guard !isEmpty else { return true }
    var candidateIndex = startIndex
    for element in source where candidateIndex < endIndex {
      if self[candidateIndex] == element {
        formIndex(after: &candidateIndex)
      }
    }
    return candidateIndex == endIndex
  }
}
