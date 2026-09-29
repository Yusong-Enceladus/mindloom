import Foundation

/// Deterministic edits that are safer and cheaper than asking a generative
/// model to infer them. The protected-fact gate remains authoritative after
/// these edits; this component does not bypass it.
public enum MLXTranscriptMechanicalEditor {
  public static func prepareSource(_ source: String) -> String {
    var value = source.precomposedStringWithCanonicalMapping
    value = replacing(
      pattern:
        #"(?i)(?<![\p{L}\p{N}])(?:um|uh|erm|hmm)(?![\p{L}\p{N}])(?:[ \t]*[,，]?[ \t]*)?"#,
      in: value,
      with: " "
    )
    value = replacing(
      pattern: #"^(?:\s*(?:嗯+|呃+|那个)[,，\s]*)+"#,
      in: value,
      with: ""
    )
    value = collapseRepeatedLatinPhrases(value)
    value = collapseRepeatedHanPhrases(value)
    value = replacing(pattern: #"[ \t]{2,}"#, in: value, with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? source : value
  }

  public static func finalizeOutput(_ candidate: String) -> String {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return candidate }
    if trimmed.unicodeScalars.last.map(isTerminalPunctuation) == true {
      return trimmed
    }
    return trimmed + (containsHan(trimmed) ? "。" : ".")
  }

  private static func collapseRepeatedLatinPhrases(_ source: String) -> String {
    var value = source
    for wordCount in stride(from: 4, through: 2, by: -1) {
      let word = #"[\p{L}'’-]+"#
      let phrase = "((?:\(word)[ \\t]+){\(wordCount - 1)}\(word))"
      let pattern =
        "(?i)(?<![\\p{L}\\p{N}])\(phrase)[ \\t]+\\1"
        + "(?![\\p{L}\\p{N}])"
      value = replacingUntilStable(pattern: pattern, in: value, with: "$1")
    }
    let repeatedWord =
      #"(?i)(?<![\p{L}\p{N}])([\p{L}'’-]+)(?:[ \t]+\1)+(?![\p{L}\p{N}])"#
    return replacingUntilStable(
      pattern: repeatedWord,
      in: value,
      with: "$1"
    )
  }

  private static func collapseRepeatedHanPhrases(_ source: String) -> String {
    var characters = Array(source)
    guard characters.count >= 4 else { return source }
    var changed = false
    for length in stride(from: min(8, characters.count / 2), through: 2, by: -1) {
      var index = 0
      while index + length * 2 <= characters.count {
        let first = Array(characters[index..<(index + length)])
        let second = Array(
          characters[(index + length)..<(index + length * 2)]
        )
        if first == second, first.allSatisfy(isHan) {
          characters.removeSubrange(
            (index + length)..<(index + length * 2)
          )
          changed = true
        } else {
          index += 1
        }
      }
    }
    return changed ? String(characters) : source
  }

  private static func replacingUntilStable(
    pattern: String,
    in source: String,
    with replacement: String
  ) -> String {
    var value = source
    while true {
      let next = replacing(
        pattern: pattern,
        in: value,
        with: replacement
      )
      if next == value { return value }
      value = next
    }
  }

  private static func replacing(
    pattern: String,
    in source: String,
    with replacement: String
  ) -> String {
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      expression.firstMatch(
        in: source,
        range: NSRange(source.startIndex..<source.endIndex, in: source)
      ) != nil
    else { return source }
    return expression.stringByReplacingMatches(
      in: source,
      range: NSRange(source.startIndex..<source.endIndex, in: source),
      withTemplate: replacement
    )
  }

  private static func containsHan(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: isHan)
  }

  private static func isHan(_ character: Character) -> Bool {
    !character.unicodeScalars.isEmpty
      && character.unicodeScalars.allSatisfy(isHan)
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

  private static func isTerminalPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet(charactersIn: ".!?。！？").contains(scalar)
  }
}
