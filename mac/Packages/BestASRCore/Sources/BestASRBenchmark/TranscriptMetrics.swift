import Foundation

public struct EditMetricCounts: Equatable, Sendable {
  public let errors: Int
  public let referenceUnits: Int

  public init(errors: Int, referenceUnits: Int) {
    self.errors = errors
    self.referenceUnits = referenceUnits
  }

  public var rate: Double {
    if referenceUnits == 0 {
      return errors == 0 ? 0 : 1
    }
    return Double(errors) / Double(referenceUnits)
  }
}

public struct TranscriptMetricCounts: Equatable, Sendable {
  public let character: EditMetricCounts
  public let word: EditMetricCounts
  public let mixed: EditMetricCounts

  public init(
    character: EditMetricCounts,
    word: EditMetricCounts,
    mixed: EditMetricCounts
  ) {
    self.character = character
    self.word = word
    self.mixed = mixed
  }
}

public struct DangerousTokenMetrics: Equatable, Sendable {
  public let totalErrors: Int
  public let errorsByCategory: [DangerousTokenCategory: Int]

  public init(
    totalErrors: Int,
    errorsByCategory: [DangerousTokenCategory: Int]
  ) {
    self.totalErrors = totalErrors
    self.errorsByCategory = errorsByCategory
  }
}

public enum TranscriptScorer {
  public static func score(reference: String, hypothesis: String) -> TranscriptMetricCounts {
    let normalizedReference = reference.precomposedStringWithCanonicalMapping
    let normalizedHypothesis = hypothesis.precomposedStringWithCanonicalMapping
    let referenceCharacters = characterTokens(normalizedReference)
    let hypothesisCharacters = characterTokens(normalizedHypothesis)
    let referenceWords = wordTokens(normalizedReference)
    let hypothesisWords = wordTokens(normalizedHypothesis)
    let referenceMixed = mixedTokens(normalizedReference)
    let hypothesisMixed = mixedTokens(normalizedHypothesis)

    return TranscriptMetricCounts(
      character: EditMetricCounts(
        errors: editDistance(referenceCharacters, hypothesisCharacters),
        referenceUnits: referenceCharacters.count
      ),
      word: EditMetricCounts(
        errors: editDistance(referenceWords, hypothesisWords),
        referenceUnits: referenceWords.count
      ),
      mixed: EditMetricCounts(
        errors: editDistance(referenceMixed, hypothesisMixed),
        referenceUnits: referenceMixed.count
      )
    )
  }

  public static func dangerousTokenMetrics(
    reference: [DangerousToken],
    hypothesis: [DangerousToken]
  ) -> DangerousTokenMetrics {
    var errorsByCategory: [DangerousTokenCategory: Int] = [:]
    for category in DangerousTokenCategory.allCases {
      let referenceValues = reference.filter { $0.category == category }.map {
        normalizeDangerousValue($0.value)
      }
      let hypothesisValues = hypothesis.filter { $0.category == category }.map {
        normalizeDangerousValue($0.value)
      }
      errorsByCategory[category] = editDistance(referenceValues, hypothesisValues)
    }
    return DangerousTokenMetrics(
      totalErrors: errorsByCategory.values.reduce(0, +),
      errorsByCategory: errorsByCategory
    )
  }

  static func editDistance<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Int {
    if reference.isEmpty { return hypothesis.count }
    if hypothesis.isEmpty { return reference.count }

    var previous = Array(0...hypothesis.count)
    for (referenceIndex, referenceValue) in reference.enumerated() {
      var current = Array(repeating: 0, count: hypothesis.count + 1)
      current[0] = referenceIndex + 1
      for (hypothesisIndex, hypothesisValue) in hypothesis.enumerated() {
        let substitution =
          previous[hypothesisIndex]
          + (referenceValue == hypothesisValue ? 0 : 1)
        let deletion = previous[hypothesisIndex + 1] + 1
        let insertion = current[hypothesisIndex] + 1
        current[hypothesisIndex + 1] = min(substitution, deletion, insertion)
      }
      previous = current
    }
    return previous[hypothesis.count]
  }

  private static func characterTokens(_ value: String) -> [String] {
    value.filter { !$0.isWhitespace }.map(String.init)
  }

  private static func wordTokens(_ value: String) -> [String] {
    let expression = try? NSRegularExpression(
      pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?"
    )
    guard let expression else { return [] }
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let tokenRange = Range(match.range, in: value) else { return nil }
      return String(value[tokenRange]).lowercased()
    }
  }

  private static func mixedTokens(_ value: String) -> [String] {
    var tokens: [String] = []
    var word = ""

    func flushWord() {
      if !word.isEmpty {
        tokens.append(word.lowercased())
        word.removeAll(keepingCapacity: true)
      }
    }

    for scalar in value.unicodeScalars {
      if isHan(scalar) {
        flushWord()
        tokens.append(String(scalar))
      } else if CharacterSet.alphanumerics.contains(scalar) {
        word.unicodeScalars.append(scalar)
      } else {
        flushWord()
      }
    }
    flushWord()
    return tokens
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
      0x20000...0x2EBEF:
      return true
    default:
      return false
    }
  }

  private static func normalizeDangerousValue(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
