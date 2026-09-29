import Foundation

/// Model-independent word evidence. UI and persistence consume complete
/// source-backed phrases, not the aligner's punctuation-stripped tokens.
public struct TranscriptAlignmentWord: Codable, Equatable, Sendable {
  public let text: String
  public let startSeconds: Double
  public let endSeconds: Double

  public init(text: String, startSeconds: Double, endSeconds: Double) {
    self.text = text
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
  }
}

public struct AlignedTranscriptPhrase: Equatable, Sendable {
  public let text: String
  public let startSeconds: Double
  public let endSeconds: Double

  public init(text: String, startSeconds: Double, endSeconds: Double) {
    self.text = text
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
  }
}

public enum TranscriptAlignmentError: Error, Equatable, Sendable {
  case invalidInput
  case textCoverageMismatch
  case invalidTimestamp
  case noPlayableRange
}

public struct AlignedTranscriptAssembler: Sendable {
  public init() {}

  /// All visible characters, punctuation and whitespace must be retained in
  /// order. Quantization can place a word exactly on a clip boundary or give
  /// it zero duration; coalesce it with its phrase, never drop its text or
  /// invent a per-word playback interval. A malformed alignment is rejected
  /// so callers can retain their existing source-backed recognition route.
  public func assemble(
    text: String,
    words: [TranscriptAlignmentWord],
    durationSeconds: Double,
    quantizationSeconds: Double
  ) throws -> [AlignedTranscriptPhrase] {
    guard !text.isEmpty, text.count <= 16_384, !words.isEmpty, words.count <= 4_096,
      durationSeconds.isFinite, durationSeconds > 0,
      quantizationSeconds.isFinite, quantizationSeconds > 0,
      quantizationSeconds <= 1
    else { throw TranscriptAlignmentError.invalidInput }
    let characters = Array(text)
    let kept = characters.indices.filter { index in
      characters[index].isLetter || characters[index].isNumber || characters[index] == "'"
    }
    guard String(kept.map { characters[$0] }) == words.map(\.text).joined(),
      words.allSatisfy({ !$0.text.isEmpty })
    else { throw TranscriptAlignmentError.textCoverageMismatch }

    var sentenceEnds = Set<Int>()
    // Foundation's native multilingual sentence tokenizer handles punctuation
    // and abbreviations; it does not require a model download or a cloud call.
    text.enumerateSubstrings(
      in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]
    ) {
      _, range, _, _ in
      sentenceEnds.insert(text.distance(from: text.startIndex, to: range.upperBound))
    }

    var times: [(start: Double, end: Double)] = []
    var characterEnds: [Int] = []
    var characterStarts: [Int] = []
    var consumed = 0
    var previousEnd = 0.0
    for word in words {
      guard word.startSeconds.isFinite, word.endSeconds.isFinite,
        word.startSeconds >= -quantizationSeconds,
        word.endSeconds <= durationSeconds + quantizationSeconds,
        word.startSeconds <= word.endSeconds,
        times.isEmpty || word.startSeconds + 0.000_000_1 >= previousEnd
      else { throw TranscriptAlignmentError.invalidTimestamp }
      let start = max(previousEnd, min(durationSeconds, max(0, word.startSeconds)))
      let end = min(durationSeconds, max(start, word.endSeconds))
      times.append((start, end))
      previousEnd = end
      characterStarts.append(kept[consumed])
      consumed += word.text.count
      guard consumed <= kept.count else { throw TranscriptAlignmentError.textCoverageMismatch }
      characterEnds.append(kept[consumed - 1] + 1)
    }

    var phrases: [AlignedTranscriptPhrase] = []
    var groupStart = 0
    var textStart = 0
    for index in words.indices {
      let last = index == words.count - 1
      let nextTextStart = last ? characters.count : characterStarts[index + 1]
      let nativeSentenceEnd = sentenceEnds.contains {
        $0 >= characterEnds[index] && $0 <= nextTextStart
      }
      let pause = last ? 0 : times[index + 1].start - times[index].end
      let longPhrase = times[index].end - times[groupStart].start >= 12
      guard last || nativeSentenceEnd || pause >= 0.6 || longPhrase else { continue }
      let start = times[groupStart].start
      let end = times[index].end
      if end <= start {
        if !last { continue }
        guard let prior = phrases.popLast() else {
          throw TranscriptAlignmentError.noPlayableRange
        }
        phrases.append(
          AlignedTranscriptPhrase(
            text: prior.text + String(characters[textStart..<nextTextStart]),
            startSeconds: prior.startSeconds, endSeconds: max(prior.endSeconds, end)
          ))
      } else {
        phrases.append(
          AlignedTranscriptPhrase(
            text: String(characters[textStart..<nextTextStart]),
            startSeconds: start, endSeconds: end
          ))
      }
      textStart = nextTextStart
      groupStart = index + 1
    }
    guard !phrases.isEmpty, phrases.map(\.text).joined() == text,
      phrases.allSatisfy({ $0.startSeconds < $0.endSeconds })
    else { throw TranscriptAlignmentError.noPlayableRange }
    return phrases
  }
}
