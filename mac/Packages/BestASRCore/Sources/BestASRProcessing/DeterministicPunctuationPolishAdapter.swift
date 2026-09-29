import BestASRDictation
import Foundation

/// The local rule cleanup every dictation gets before insertion. It never
/// invents words or facts: it removes the fillers 嗯 and 呃, drops the closing
/// period when the whole dictation is a single sentence, and otherwise adds
/// one terminal mark when none is present.
public struct DeterministicPunctuationPolishAdapter: DictationPolishPort {
  public init() {}

  public func polish(
    _ request: DictationPolishRequest
  ) async throws -> DictationPolishResult {
    let source = request.transcript.text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else {
      return DictationPolishResult(
        sourceRevisionID: request.transcript.revisionID,
        text: request.transcript.text,
        disposition: .rawTranscriptFallback,
        modelArtifactID: nil
      )
    }
    return DictationPolishResult(
      sourceRevisionID: request.transcript.revisionID,
      text: DictationTextCleanup.apply(source),
      disposition: .punctuationOnlyFallback,
      modelArtifactID: nil
    )
  }
}

/// Rules agreed with the user on 2026-09-19 for inserted dictation text.
public enum DictationTextCleanup {
  /// Identifies this rule set in derived-text provenance.
  public static let revision = "dictation-cleanup-v2-fillers-single-sentence"

  private static let fillers: Set<Character> = ["嗯", "呃"]
  private static let commas: Set<Character> = ["，", "、", ","]
  private static let stops: Set<Character> = ["。", "！", "？", "!", "?"]

  public static func apply(_ text: String) -> String {
    let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var value = removingFillers(original)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // A dictation of nothing but fillers was probably meant; keep it.
    guard value.contains(where: { $0.isLetter || $0.isNumber }) else { return original }
    if isSingleSentence(value) {
      if value.last == "。" || value.last == "." {
        value.removeLast()
        value = value.trimmingCharacters(in: .whitespaces)
      }
    } else if let last = value.last, !stops.contains(last), last != "." {
      value.append(containsHan(value) ? "。" : ".")
    }
    return value
  }

  /// Removes each filler and one comma it leaves dangling, so
  /// "我觉得，嗯，这个" becomes "我觉得，这个" and "嗯，好的" becomes "好的".
  static func removingFillers(_ text: String) -> String {
    var output: [Character] = []
    var droppedFiller = false
    for character in text {
      if fillers.contains(character) {
        droppedFiller = true
        continue
      }
      if droppedFiller, commas.contains(character) || character == " " {
        if output.last.map({ commas.contains($0) || stops.contains($0) }) ?? true {
          continue
        }
      }
      if droppedFiller, stops.contains(character) || character == "." ,
        let last = output.last, commas.contains(last)
      {
        output.removeLast()
      }
      droppedFiller = false
      output.append(character)
    }
    while let first = output.first, commas.contains(first) || first == " " {
      output.removeFirst()
    }
    return String(output)
  }

  /// No sentence ends before the last character: CJK/ASCII stops, or an ASCII
  /// period followed by a space (so "3.5" and "e.g" do not count).
  static func isSingleSentence(_ text: String) -> Bool {
    let characters = Array(text)
    guard characters.count > 1 else { return true }
    for index in 0..<(characters.count - 1) {
      let character = characters[index]
      if stops.contains(character) { return false }
      if character == ".", characters[index + 1] == " " { return false }
    }
    return true
  }

  private static func containsHan(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
        0x20000...0x2EBEF:
        true
      default:
        false
      }
    }
  }
}
