import BestASRCandidateAdapters
import BestASRInference
import BestASRModelManager
@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation

public enum FluidSenseVoicePinnedArtifact {
  public static let artifactID = "fluid-sensevoice-small-int8-0e0bf30b"
  public static let sourceRevision = "0e0bf30bfc6836f182ccd1d89984df919c949e26"
  public static let treeSHA256 =
    "df817fcc1009d0d909c2d7eea7dd6babdd4e3288f9b84973ce04fe66c27cf7be"
  public static let runtimeRevision =
    "19600a485baa4998812e4654b70d2bab8f2c9949"

  public static let descriptor = ModelArtifactDescriptor(
    artifactID: artifactID,
    version: sourceRevision,
    sha256: treeSHA256,
    runtimeID: InferenceRuntimeID("fluid-audio.sensevoice"),
    capabilities: [
      .asrBatch,
      .asrMultilingual,
      .asrRevisioned,
      .asrStreaming,
      .asrTimestamps,
    ],
    minimumOS: InferenceOSVersion(major: 14, minor: 2),
    supportedArchitectures: ["arm64"],
    minimumUnifiedMemoryBytes: 17_179_869_184,
    licenseIdentifier: "LicenseRef-FunASR-Model-1.1",
    networkRequired: false,
    metadata: [
      "encoderPrecision": "int8",
      "runtimeRevision": runtimeRevision,
      "sourceRevision": sourceRevision,
    ]
  )
}

public protocol SenseVoiceAudioSampleLoading: Sendable {
  func loadSamples(for input: AudioRangeInput) async throws -> [Float]
}

public protocol SenseVoiceTranscribing: Sendable {
  func transcribe(samples: [Float]) async throws -> String
}

public struct SenseVoiceTranscription: Equatable, Sendable {
  public let text: String
  public let detectedLanguage: String?

  public init(text: String, detectedLanguage: String?) {
    self.text = text
    self.detectedLanguage = detectedLanguage
  }
}

public protocol SenseVoiceDetailedTranscribing: SenseVoiceTranscribing {
  func transcribeDetailed(samples: [Float]) async throws
    -> SenseVoiceTranscription
}

enum SenseVoiceRawTranscriptionParser {
  static func parse(_ raw: String) -> SenseVoiceTranscription {
    var detectedLanguage: String?
    var cursor = raw.startIndex
    while let opening = raw.range(
      of: "<|",
      range: cursor..<raw.endIndex
    ),
      let closing = raw.range(
        of: "|>",
        range: opening.upperBound..<raw.endIndex
      )
    {
      let tag = String(raw[opening.upperBound..<closing.lowerBound])
        .lowercased()
      if detectedLanguage == nil {
        detectedLanguage = canonicalLanguage(for: tag)
      }
      cursor = closing.upperBound
    }
    let text =
      raw
      .replacingOccurrences(
        of: "<\\|[^|]*\\|>",
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return SenseVoiceTranscription(
      text: text,
      detectedLanguage: detectedLanguage
    )
  }

  private static func canonicalLanguage(for tag: String) -> String? {
    switch tag {
    case "zh": "zh-CN"
    case "en": "en-US"
    case "yue": "yue-HK"
    case "ja": "ja-JP"
    case "ko": "ko-KR"
    default: nil
    }
  }
}

enum SenseVoiceCTCDecoder {
  static func tokenIDs(logits: MLMultiArray, validFrames: Int) -> [Int] {
    guard logits.shape.count == 3, logits.shape[2].intValue > 0 else { return [] }
    let vocabularyCount = logits.shape[2].intValue
    let frameCount = min(max(0, validFrames), logits.shape[1].intValue)
    let frameStride = logits.strides[1].intValue
    let tokenStride = logits.strides[2].intValue
    var tokens: [Int] = []
    var previousToken = -1

    func appendArgmax(_ value: (Int) -> Float) {
      var bestToken = 0
      var bestValue = value(0)
      for token in 1..<vocabularyCount {
        let candidate = value(token)
        if candidate > bestValue {
          bestValue = candidate
          bestToken = token
        }
      }
      if bestToken != SenseVoiceConfig.blankId, bestToken != previousToken {
        tokens.append(bestToken)
      }
      previousToken = bestToken
    }

    // ANE outputs Float16 with padded row strides. Reading the native storage
    // avoids millions of NSNumber/index-array allocations per utterance while
    // respecting that padding in both Float16 and Float32 outputs.
    switch logits.dataType {
    case .float16:
      #if arch(arm64)
        let pointer = logits.dataPointer.assumingMemoryBound(to: Float16.self)
        for frame in 0..<frameCount {
          let base = frame * frameStride
          appendArgmax { Float(pointer[base + $0 * tokenStride]) }
        }
      #else
        for frame in 0..<frameCount {
          appendArgmax { logits[[0, frame as NSNumber, $0 as NSNumber]].floatValue }
        }
      #endif
    case .float32:
      let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
      for frame in 0..<frameCount {
        let base = frame * frameStride
        appendArgmax { pointer[base + $0 * tokenStride] }
      }
    default:
      for frame in 0..<frameCount {
        appendArgmax { logits[[0, frame as NSNumber, $0 as NSNumber]].floatValue }
      }
    }
    return tokens
  }
}

public struct SenseVoiceActivitySegmenter: Sendable {
  public let sampleRateHertz: Int
  public let frameDurationMilliseconds: Int
  public let minimumRMS: Float
  public let minimumPeak: Float
  public let splitSilenceMilliseconds: Int
  public let paddingMilliseconds: Int
  public let minimumActiveMilliseconds: Int

  public init(
    sampleRateHertz: Int = 16_000,
    frameDurationMilliseconds: Int = 20,
    minimumRMS: Float = 0.006,
    minimumPeak: Float = 0.02,
    splitSilenceMilliseconds: Int = 600,
    paddingMilliseconds: Int = 160,
    minimumActiveMilliseconds: Int = 80
  ) {
    self.sampleRateHertz = sampleRateHertz
    self.frameDurationMilliseconds = frameDurationMilliseconds
    self.minimumRMS = minimumRMS
    self.minimumPeak = minimumPeak
    self.splitSilenceMilliseconds = splitSilenceMilliseconds
    self.paddingMilliseconds = paddingMilliseconds
    self.minimumActiveMilliseconds = minimumActiveMilliseconds
  }

  public func speechRanges(in samples: [Float]) -> [Range<Int>] {
    guard sampleRateHertz > 0,
      frameDurationMilliseconds > 0,
      minimumRMS > 0,
      minimumPeak > 0,
      splitSilenceMilliseconds >= frameDurationMilliseconds,
      paddingMilliseconds >= 0,
      minimumActiveMilliseconds >= frameDurationMilliseconds,
      !samples.isEmpty,
      samples.allSatisfy({ $0.isFinite })
    else { return [] }

    let frameSize = max(
      1,
      sampleRateHertz * frameDurationMilliseconds / 1_000
    )
    var activeFrames: [Int] = []
    for frameStart in stride(from: 0, to: samples.count, by: frameSize) {
      let frameEnd = min(samples.count, frameStart + frameSize)
      var sumSquares: Double = 0
      var peak: Float = 0
      for sample in samples[frameStart..<frameEnd] {
        let magnitude = abs(sample)
        peak = max(peak, magnitude)
        sumSquares += Double(sample) * Double(sample)
      }
      let rms = Float(
        (sumSquares / Double(max(1, frameEnd - frameStart))).squareRoot()
      )
      if rms >= minimumRMS && peak >= minimumPeak {
        activeFrames.append(frameStart / frameSize)
      }
    }
    guard !activeFrames.isEmpty else { return [] }

    let splitFrames = max(
      1,
      splitSilenceMilliseconds / frameDurationMilliseconds
    )
    let minimumActiveFrames = max(
      1,
      minimumActiveMilliseconds / frameDurationMilliseconds
    )
    let paddingSamples = sampleRateHertz * paddingMilliseconds / 1_000
    var groups: [(first: Int, last: Int, activeCount: Int)] = []
    var first = activeFrames[0]
    var last = activeFrames[0]
    var activeCount = 1
    for frame in activeFrames.dropFirst() {
      if frame - last > splitFrames {
        groups.append((first, last, activeCount))
        first = frame
        activeCount = 1
      } else {
        activeCount += 1
      }
      last = frame
    }
    groups.append((first, last, activeCount))

    if groups.count == 1,
      let only = groups.first,
      only.activeCount >= minimumActiveFrames
    {
      return [0..<samples.count]
    }

    var ranges: [Range<Int>] = []
    for group in groups where group.activeCount >= minimumActiveFrames {
      let lower = max(0, group.first * frameSize - paddingSamples)
      let upper = min(
        samples.count,
        (group.last + 1) * frameSize + paddingSamples
      )
      guard lower < upper else { continue }
      if let previous = ranges.last, lower <= previous.upperBound {
        ranges[ranges.count - 1] = previous.lowerBound..<upper
      } else {
        ranges.append(lower..<upper)
      }
    }
    return ranges
  }

}

public struct SenseVoiceDictionaryNormalizer: Sendable {
  public let maximumTerms: Int
  public let maximumTermCharacters: Int

  public init(maximumTerms: Int = 64, maximumTermCharacters: Int = 128) {
    self.maximumTerms = maximumTerms
    self.maximumTermCharacters = maximumTermCharacters
  }

  public func normalize(_ text: String, dictionaryTerms: [String]) -> String {
    normalize(text, dictionaryTerms: dictionaryTerms, dictionaryHints: [])
  }

  public func normalize(
    _ text: String,
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint]
  ) -> String {
    guard maximumTerms > 0, maximumTermCharacters > 0 else { return text }
    var result = replaceExplicitHints(in: text, hints: dictionaryHints)
    var seenTerms = Set<String>()
    let terms = (dictionaryTerms + dictionaryHints.map(\.canonicalForm))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter {
        guard !$0.isEmpty, $0.count <= maximumTermCharacters else {
          return false
        }
        return seenTerms.insert(Self.comparisonKey($0)).inserted
      }
      .prefix(maximumTerms)
    for term in terms {
      if term.unicodeScalars.contains(where: Self.isHan) {
        result = replaceHanCandidate(in: result, with: term)
      } else {
        result = replaceLatinCandidate(in: result, with: term)
      }
    }
    return result
  }

  private struct ExplicitMapping {
    let canonicalForm: String
    let surface: String
    let key: String
    let isASCII: Bool
  }

  /// Rewrites only explicit, unambiguous surfaces.  Every replacement is
  /// marked with a private-use scalar until the pass completes so one
  /// dictionary entry cannot cascade into another entry's spoken form.
  private func replaceExplicitHints(
    in text: String,
    hints: [ASRDictionaryHint]
  ) -> String {
    var mappings: [ExplicitMapping] = []
    for hint in hints.prefix(maximumTerms) {
      let canonical = hint.canonicalForm.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard
        !canonical.isEmpty,
        canonical.count <= maximumTermCharacters,
        canonical == hint.canonicalForm
      else { continue }
      let surfaces = [canonical] + Array(hint.spokenForms.prefix(32))
      for surface in surfaces {
        guard
          !surface.isEmpty,
          surface.count <= maximumTermCharacters,
          surface == surface.trimmingCharacters(in: .whitespacesAndNewlines)
        else { continue }
        let isASCII = surface.unicodeScalars.allSatisfy { $0.value < 128 }
        let key =
          isASCII
          ? Self.asciiAlphanumeric(surface)
          : Self.comparisonKey(surface)
        guard key.count >= 2 else { continue }
        mappings.append(
          ExplicitMapping(
            canonicalForm: canonical,
            surface: surface,
            key: key,
            isASCII: isASCII
          )
        )
      }
    }

    let grouped = Dictionary(grouping: mappings, by: \.key)
    var seenMappings = Set<String>()
    let safeMappings = mappings.filter { mapping in
      let canonicalForms = Set(
        grouped[mapping.key, default: []].map(\.canonicalForm)
      )
      guard canonicalForms.count == 1 else { return false }
      return seenMappings.insert(
        "\(mapping.key)\u{0}\(mapping.canonicalForm)"
      ).inserted
    }.sorted {
      if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
      return $0.surface.count > $1.surface.count
    }

    var result = text
    var replacements: [(placeholder: String, canonical: String)] = []
    for (index, mapping) in safeMappings.enumerated() {
      guard let scalar = UnicodeScalar(0xF0000 + index) else { continue }
      let placeholder = String(scalar)
      let replaced: String
      if mapping.isASCII {
        replaced = replaceASCIIExactCandidates(
          in: result,
          normalizedSurface: mapping.key,
          with: placeholder
        )
      } else {
        replaced = replaceLiteralCandidates(
          in: result,
          surface: mapping.surface,
          with: placeholder
        )
      }
      if replaced != result {
        replacements.append((placeholder, mapping.canonicalForm))
        result = replaced
      }
    }
    for replacement in replacements {
      result = result.replacingOccurrences(
        of: replacement.placeholder,
        with: replacement.canonical
      )
    }
    return result
  }

  private func replaceASCIIExactCandidates(
    in text: String,
    normalizedSurface: String,
    with replacement: String
  ) -> String {
    guard
      let expression = try? NSRegularExpression(pattern: "[A-Za-z0-9]+")
    else { return text }
    let fullRange = NSRange(text.startIndex..., in: text)
    let tokens = expression.matches(in: text, range: fullRange).compactMap {
      Range($0.range, in: text)
    }
    guard !tokens.isEmpty else { return text }
    var matches: [Range<String.Index>] = []
    for start in tokens.indices {
      let maximumEnd = min(tokens.count - 1, start + 7)
      for end in start...maximumEnd {
        let candidateRange = tokens[start].lowerBound..<tokens[end].upperBound
        if Self.asciiAlphanumeric(String(text[candidateRange]))
          == normalizedSurface
        {
          matches.append(candidateRange)
          break
        }
      }
    }
    var nonoverlapping: [Range<String.Index>] = []
    for match in matches {
      if nonoverlapping.last.map({ $0.upperBound <= match.lowerBound }) ?? true {
        nonoverlapping.append(match)
      }
    }
    var result = text
    for match in nonoverlapping.reversed() {
      result.replaceSubrange(match, with: replacement)
    }
    return result
  }

  private func replaceLiteralCandidates(
    in text: String,
    surface: String,
    with replacement: String
  ) -> String {
    var ranges: [Range<String.Index>] = []
    var lower = text.startIndex
    while lower < text.endIndex,
      let match = text.range(
        of: surface,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        range: lower..<text.endIndex
      )
    {
      ranges.append(match)
      lower = match.upperBound
    }
    var result = text
    for range in ranges.reversed() {
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }

  public static func join(_ pieces: [String]) -> String {
    TranscriptTextJoiner.join(pieces)
  }

  private func replaceHanCandidate(in text: String, with term: String) -> String {
    if text.contains(term) { return text }
    let termCharacters = Array(term)
    guard termCharacters.count >= 2 else { return text }
    let characters = Array(text)
    guard characters.count >= termCharacters.count else { return text }
    var matches: [(offset: Int, distance: Int)] = []
    for offset in 0...(characters.count - termCharacters.count) {
      let candidate = Array(
        characters[offset..<(offset + termCharacters.count)]
      )
      guard
        candidate.allSatisfy({ character in
          character.unicodeScalars.allSatisfy(Self.isHan)
        })
      else { continue }
      let distance = Self.editDistance(candidate, termCharacters)
      if distance <= 1 {
        matches.append((offset, distance))
      }
    }
    guard let minimum = matches.map(\.distance).min() else { return text }
    let best = matches.filter { $0.distance == minimum }
    guard best.count == 1, let match = best.first else { return text }
    let lower = text.index(text.startIndex, offsetBy: match.offset)
    let upper = text.index(lower, offsetBy: termCharacters.count)
    var result = text
    result.replaceSubrange(lower..<upper, with: term)
    return result
  }

  private func replaceLatinCandidate(in text: String, with term: String) -> String {
    let normalizedTerm = Self.asciiAlphanumeric(term)
    guard normalizedTerm.count >= 2,
      let expression = try? NSRegularExpression(pattern: "[A-Za-z0-9]+")
    else { return text }
    let fullRange = NSRange(text.startIndex..., in: text)
    let tokens = expression.matches(in: text, range: fullRange).compactMap {
      Range($0.range, in: text)
    }
    guard !tokens.isEmpty else { return text }

    struct Match {
      let range: Range<String.Index>
      let distance: Int
      let tokenCount: Int
    }
    var matches: [Match] = []
    for start in tokens.indices {
      let maximumEnd = min(tokens.count - 1, start + 3)
      for end in start...maximumEnd {
        let candidateRange = tokens[start].lowerBound..<tokens[end].upperBound
        let surface = String(text[candidateRange])
        guard surface.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
          continue
        }
        let normalizedCandidate = Self.asciiAlphanumeric(surface)
        let distance = Self.editDistance(
          Array(normalizedCandidate),
          Array(normalizedTerm)
        )
        let exact = distance == 0
        let near =
          normalizedTerm.count >= 5
          && normalizedCandidate.first == normalizedTerm.first
          && distance <= 2
        let phonetic =
          start == end
          && normalizedCandidate.first == normalizedTerm.first
          && Self.soundex(normalizedCandidate) == Self.soundex(normalizedTerm)
        if exact || near || phonetic {
          matches.append(
            Match(
              range: candidateRange,
              distance: distance,
              tokenCount: end - start + 1
            )
          )
        }
      }
    }
    guard var selected = matches.first else { return text }
    for match in matches.dropFirst() {
      if match.distance < selected.distance
        || (match.distance == selected.distance
          && match.tokenCount < selected.tokenCount)
      {
        selected = match
      }
    }
    let best = matches.filter {
      $0.distance == selected.distance && $0.tokenCount == selected.tokenCount
    }
    guard best.count == 1, let match = best.first else { return text }
    var result = text
    result.replaceSubrange(match.range, with: term)
    return result
  }

  private static func asciiAlphanumeric(_ value: String) -> String {
    String(
      value.lowercased().unicodeScalars.filter {
        $0.value < 128 && CharacterSet.alphanumerics.contains($0)
      }
    )
  }

  private static func comparisonKey(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased()
  }

  private static func soundex(_ value: String) -> String {
    let letters = value.uppercased().filter { $0.isASCII && $0.isLetter }
    guard let first = letters.first else { return "" }
    var output = String(first)
    var previous = soundexDigit(first)
    for letter in letters.dropFirst() {
      let digit = soundexDigit(letter)
      if let digit, digit != previous {
        output.append(digit)
      }
      previous = digit
      if output.count == 4 { break }
    }
    while output.count < 4 { output.append("0") }
    return output
  }

  private static func soundexDigit(_ character: Character) -> Character? {
    switch character {
    case "B", "F", "P", "V": "1"
    case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
    case "D", "T": "3"
    case "L": "4"
    case "M", "N": "5"
    case "R": "6"
    default: nil
    }
  }

  private static func editDistance<T: Equatable>(
    _ reference: [T],
    _ hypothesis: [T]
  ) -> Int {
    if reference.isEmpty { return hypothesis.count }
    if hypothesis.isEmpty { return reference.count }
    var previous = Array(0...hypothesis.count)
    for (referenceIndex, referenceValue) in reference.enumerated() {
      var current = Array(repeating: 0, count: hypothesis.count + 1)
      current[0] = referenceIndex + 1
      for (hypothesisIndex, hypothesisValue) in hypothesis.enumerated() {
        current[hypothesisIndex + 1] = min(
          previous[hypothesisIndex]
            + (referenceValue == hypothesisValue ? 0 : 1),
          previous[hypothesisIndex + 1] + 1,
          current[hypothesisIndex] + 1
        )
      }
      previous = current
    }
    return previous[hypothesis.count]
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
}

/// A production bridge over verified local artifacts. Model loading never
/// reaches an SDK download entry point.
public actor FluidSenseVoiceBackend: SenseVoiceDetailedTranscribing {
  private let models: SenseVoiceModels

  public init(verifiedModelDirectory: URL) throws {
    do {
      models = try FluidASRModelLoader.senseVoice(from: verifiedModelDirectory)
    } catch {
      throw InferenceEngineError(
        category: .modelUnavailable,
        code: "sensevoice-verified-model-load-failed",
        retryable: true
      )
    }
  }

  public func transcribe(samples: [Float]) async throws -> String {
    try await transcribeDetailed(samples: samples).text
  }

  public func transcribeDetailed(samples: [Float]) async throws
    -> SenseVoiceTranscription
  {
    do {
      try Task.checkCancellation()
      let features = try runPreprocessor(audio: samples)
      let (logits, validFrames) = try runEncoder(features: features)
      try Task.checkCancellation()
      return decode(logits: logits, validFrames: validFrames)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "sensevoice-runtime-failed",
        retryable: true
      )
    }
  }

  public func transcribe(
    audioURL: URL,
    dictionaryTerms: [String] = [],
    segmenter: SenseVoiceActivitySegmenter = SenseVoiceActivitySegmenter(),
    normalizer: SenseVoiceDictionaryNormalizer = SenseVoiceDictionaryNormalizer()
  ) async throws -> String {
    try await transcribe(
      audioURL: audioURL,
      dictionaryTerms: dictionaryTerms,
      dictionaryHints: [],
      segmenter: segmenter,
      normalizer: normalizer
    )
  }

  public func transcribe(
    audioURL: URL,
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint],
    segmenter: SenseVoiceActivitySegmenter = SenseVoiceActivitySegmenter(),
    normalizer: SenseVoiceDictionaryNormalizer = SenseVoiceDictionaryNormalizer()
  ) async throws -> String {
    do {
      let samples = try AudioConverter().resampleAudioFile(audioURL)
      let ranges = segmenter.speechRanges(in: samples)
      var pieces: [String] = []
      pieces.reserveCapacity(ranges.count)
      for range in ranges {
        try Task.checkCancellation()
        let raw = try await transcribe(samples: Array(samples[range]))
        pieces.append(
          normalizer.normalize(
            raw,
            dictionaryTerms: dictionaryTerms,
            dictionaryHints: dictionaryHints
          )
        )
      }
      return SenseVoiceDictionaryNormalizer.join(pieces)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "sensevoice-runtime-failed",
        retryable: true
      )
    }
  }

  private func runPreprocessor(audio: [Float]) throws -> MLMultiArray {
    let waveform = try MLMultiArray(
      shape: [1, audio.count as NSNumber],
      dataType: .float32
    )
    let pointer = waveform.dataPointer.assumingMemoryBound(to: Float32.self)
    for index in audio.indices {
      pointer[index] = audio[index] * SenseVoiceConfig.waveformScale
    }
    let input = try MLDictionaryFeatureProvider(
      dictionary: ["waveform": MLFeatureValue(multiArray: waveform)]
    )
    let output = try models.preprocessor.prediction(from: input)
    guard
      let features = output.featureValue(for: "features")?.multiArrayValue
    else {
      throw InferenceEngineError(
        category: .corruptInput,
        code: "sensevoice-preprocessor-output-missing",
        retryable: true
      )
    }
    return features
  }

  private func runEncoder(features: MLMultiArray) throws
    -> (logits: MLMultiArray, validFrames: Int)
  {
    let featureDimension = SenseVoiceConfig.featureDim
    let frameCount = min(
      features.shape[1].intValue,
      SenseVoiceConfig.maxFrames
    )
    let bucket = SenseVoiceConfig.pickBucket(forFrames: frameCount)
    let speech = try MLMultiArray(
      shape: [1, bucket as NSNumber, featureDimension as NSNumber],
      dataType: .float32
    )
    let speechPointer = speech.dataPointer.assumingMemoryBound(
      to: Float32.self
    )
    memset(
      speechPointer,
      0,
      bucket * featureDimension * MemoryLayout<Float32>.size
    )
    let elementCount = frameCount * featureDimension
    if features.dataType == .float32 {
      memcpy(
        speechPointer,
        features.dataPointer,
        elementCount * MemoryLayout<Float32>.size
      )
    } else {
      for index in 0..<elementCount {
        speechPointer[index] = features[index].floatValue
      }
    }
    let lengths = try MLMultiArray(shape: [1], dataType: .int32)
    lengths[0] = NSNumber(value: frameCount)
    let language = try MLMultiArray(shape: [1], dataType: .int32)
    language[0] = NSNumber(value: SenseVoiceConfig.defaultLanguage)
    let textNormalization = try MLMultiArray(shape: [1], dataType: .int32)
    textNormalization[0] = NSNumber(value: SenseVoiceConfig.defaultTextNorm)
    let input = try MLDictionaryFeatureProvider(
      dictionary: [
        "speech": MLFeatureValue(multiArray: speech),
        "speech_lengths": MLFeatureValue(multiArray: lengths),
        "language": MLFeatureValue(multiArray: language),
        "textnorm": MLFeatureValue(multiArray: textNormalization),
      ]
    )
    let output = try models.encoder.prediction(from: input)
    guard
      let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue
    else {
      throw InferenceEngineError(
        category: .corruptInput,
        code: "sensevoice-encoder-output-missing",
        retryable: true
      )
    }
    return (logits, SenseVoiceConfig.numQueryTokens + frameCount)
  }

  private func decode(
    logits: MLMultiArray,
    validFrames: Int
  ) -> SenseVoiceTranscription {
    let tokenIDs = SenseVoiceCTCDecoder.tokenIDs(logits: logits, validFrames: validFrames)
    return SenseVoiceRawTranscriptionParser.parse(
      decodeCtcTokenIds(tokenIDs, vocabulary: models.vocabulary)
    )
  }
}

public struct FluidSenseVoiceModelHealthCheck: ManagedModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) async throws {
    _ = try FluidASRModelLoader.senseVoice(from: modelDirectory)
  }
}

public enum FluidSenseVoiceRuntimeFactory {
  public static func make(
    modelManager: LocalModelManager,
    audioAssetRoot: URL,
    maximumSamples: Int = Float32PCMFileLoader.defaultMaximumSamples
  ) async throws -> FluidSenseVoiceRuntime {
    let active = try await modelManager.discoverActive(
      artifactID: FluidSenseVoicePinnedArtifact.artifactID,
      // discoverActive already verifies the exact registered file set, sizes,
      // and SHA-256 digests. Runtime construction below is the executable
      // health check, so loading the Core ML models here as well would double
      // cold-start cost. Activation still uses the full model health check.
      healthCheck: FileSetModelHealthCheck()
    )
    guard
      active.descriptor.exactVersion
        == FluidSenseVoicePinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256
        == FluidSenseVoicePinnedArtifact.treeSHA256
    else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "sensevoice-active-artifact-mismatch",
        retryable: false
      )
    }
    return try FluidSenseVoiceRuntime(
      verifiedModelDirectory: active.directory,
      audioAssetRoot: audioAssetRoot,
      maximumSamples: maximumSamples
    )
  }
}

public struct FluidSenseVoiceRuntime: CandidateASRRuntime {
  private let audioLoader: any SenseVoiceAudioSampleLoading
  private let backend: any SenseVoiceTranscribing
  private let activitySegmenter: SenseVoiceActivitySegmenter
  private let dictionaryNormalizer: SenseVoiceDictionaryNormalizer

  public init(
    audioLoader: any SenseVoiceAudioSampleLoading,
    backend: any SenseVoiceTranscribing,
    activitySegmenter: SenseVoiceActivitySegmenter = SenseVoiceActivitySegmenter(),
    dictionaryNormalizer: SenseVoiceDictionaryNormalizer = SenseVoiceDictionaryNormalizer()
  ) {
    self.audioLoader = audioLoader
    self.backend = backend
    self.activitySegmenter = activitySegmenter
    self.dictionaryNormalizer = dictionaryNormalizer
  }

  init(
    verifiedModelDirectory: URL,
    audioAssetRoot: URL,
    maximumSamples: Int = Float32PCMFileLoader.defaultMaximumSamples
  ) throws {
    self.init(
      audioLoader: try Float32PCMFileLoader(
        rootDirectory: audioAssetRoot,
        maximumSamples: maximumSamples
      ),
      backend: try FluidSenseVoiceBackend(
        verifiedModelDirectory: verifiedModelDirectory
      )
    )
  }

  public func networkPolicy() async -> CandidateRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactsOnly
  }

  public func transcribe(
    _ request: ASRRequest,
    candidateID: String
  ) async throws -> CandidateRuntimeOutput {
    try InferenceCancellation.check()
    guard candidateID == "fluid-sensevoice" else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "sensevoice-candidate-id-mismatch",
        retryable: false
      )
    }
    guard
      request.audio.sampleRateHertz == 16_000,
      request.audio.channelCount == 1
    else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "sensevoice-requires-16khz-mono",
        retryable: false
      )
    }

    let samples = try await audioLoader.loadSamples(for: request.audio)
    try InferenceCancellation.check()
    guard !samples.isEmpty else {
      throw InferenceEngineError(
        category: .corruptInput,
        code: "sensevoice-empty-audio",
        retryable: false
      )
    }

    let speechRanges = activitySegmenter.speechRanges(in: samples)
    var recognized:
      [(
        range: Range<Int>,
        text: String,
        detectedLanguage: String?
      )] = []
    recognized.reserveCapacity(speechRanges.count)
    for range in speechRanges {
      let transcription: SenseVoiceTranscription
      do {
        if let detailedBackend = backend as? any SenseVoiceDetailedTranscribing {
          transcription = try await detailedBackend.transcribeDetailed(
            samples: Array(samples[range])
          )
        } else {
          transcription = SenseVoiceTranscription(
            text: try await backend.transcribe(
              samples: Array(samples[range])
            ),
            detectedLanguage: nil
          )
        }
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      } catch let error as InferenceEngineError {
        throw error
      } catch {
        throw InferenceEngineError(
          category: .transientRuntime,
          code: "sensevoice-runtime-failed",
          retryable: true
        )
      }
      try InferenceCancellation.check()
      let normalized = dictionaryNormalizer.normalize(
        transcription.text.trimmingCharacters(in: .whitespacesAndNewlines),
        dictionaryTerms: request.recognitionContext.dictionaryTerms,
        dictionaryHints: request.recognitionContext.dictionaryHints
      )
      if !normalized.isEmpty {
        recognized.append(
          (range, normalized, transcription.detectedLanguage)
        )
      }
    }
    let text = SenseVoiceDictionaryNormalizer.join(recognized.map(\.text))
    let detectedLanguages = Set(recognized.compactMap(\.detectedLanguage))
    let detectedLanguage =
      detectedLanguages.count == 1 ? detectedLanguages.first : nil
    let revisionID = deterministicUUID(
      namespace: "revision",
      request: request,
      text: text,
      detectedLanguage: detectedLanguage
    )
    let segments: [CandidateRuntimeSegment]
    if recognized.isEmpty {
      segments = []
    } else {
      let inputDuration =
        request.audio.monotonicEndNanoseconds
        - request.audio.monotonicStartNanoseconds
      segments = recognized.enumerated().map { index, item in
        let startOffset = UInt64(
          (Double(inputDuration) * Double(item.range.lowerBound)
            / Double(samples.count)).rounded(.down)
        )
        let endOffset = UInt64(
          (Double(inputDuration) * Double(item.range.upperBound)
            / Double(samples.count)).rounded(.up)
        )
        return CandidateRuntimeSegment(
          segmentID: deterministicUUID(
            namespace: "segment-\(index)-\(item.range.lowerBound)-\(item.range.upperBound)",
            request: request,
            text: item.text,
            detectedLanguage: item.detectedLanguage
          ),
          monotonicStartNanoseconds:
            request.audio.monotonicStartNanoseconds + startOffset,
          monotonicEndNanoseconds: min(
            request.audio.monotonicEndNanoseconds,
            request.audio.monotonicStartNanoseconds + max(startOffset + 1, endOffset)
          ),
          text: item.text,
          confidence: nil
        )
      }
    }
    return CandidateRuntimeOutput(
      revisionID: revisionID,
      segments: segments,
      detectedLanguage: detectedLanguage
    )
  }

  private func deterministicUUID(
    namespace: String,
    request: ASRRequest,
    text: String,
    detectedLanguage: String?
  ) -> UUID {
    let seed = [
      namespace,
      request.metadata.jobID.uuidString.lowercased(),
      String(request.metadata.inputRevision),
      request.metadata.modelArtifactID,
      request.metadata.configHash,
      request.audio.contentDigest,
      String(request.audio.monotonicStartNanoseconds),
      String(request.audio.monotonicEndNanoseconds),
      request.mode.rawValue,
      request.supersedesRevisionID?.uuidString.lowercased() ?? "none",
      detectedLanguage ?? "undetected",
      text,
    ].joined(separator: "\u{1f}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}

public struct Float32PCMFileLoader: SenseVoiceAudioSampleLoading {
  public static let defaultMaximumSamples = 1_728_000

  private let rootDirectory: URL
  private let maximumSamples: Int

  public init(
    rootDirectory: URL,
    maximumSamples: Int = defaultMaximumSamples
  ) throws {
    guard maximumSamples > 0 else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "sensevoice-invalid-sample-limit",
        retryable: false
      )
    }
    let resolvedRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: resolvedRoot.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      throw InferenceEngineError(
        category: .corruptInput,
        code: "sensevoice-audio-root-missing",
        retryable: false
      )
    }
    self.rootDirectory = resolvedRoot
    self.maximumSamples = maximumSamples
  }

  public func loadSamples(for input: AudioRangeInput) async throws -> [Float] {
    try InferenceCancellation.check()
    guard input.sampleRateHertz == 16_000, input.channelCount == 1 else {
      throw failure(.invalidRequest, "sensevoice-requires-16khz-mono")
    }
    guard
      input.contentDigest.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil
    else {
      throw failure(.corruptInput, "sensevoice-invalid-audio-digest")
    }
    guard let fileURL = safeFileURL(for: input.assetReference) else {
      throw failure(.corruptInput, "sensevoice-unsafe-audio-reference")
    }
    let values = try fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw failure(.corruptInput, "sensevoice-audio-file-missing")
    }
    let byteCount = values.fileSize ?? -1
    guard
      byteCount > 0,
      byteCount.isMultiple(of: MemoryLayout<UInt32>.size)
    else {
      throw failure(.corruptInput, "sensevoice-malformed-float32-audio")
    }
    let sampleCount = byteCount / MemoryLayout<UInt32>.size
    guard sampleCount <= maximumSamples else {
      throw InferenceEngineError(
        category: .resourcePressure,
        code: "sensevoice-audio-range-too-large",
        retryable: false
      )
    }

    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map {
      String(format: "%02x", $0)
    }.joined()
    guard digest == input.contentDigest else {
      throw failure(.corruptInput, "sensevoice-audio-digest-mismatch")
    }
    try InferenceCancellation.check()

    var samples: [Float] = []
    samples.reserveCapacity(sampleCount)
    data.withUnsafeBytes { rawBytes in
      for index in stride(from: 0, to: rawBytes.count, by: 4) {
        let bits =
          UInt32(rawBytes[index])
          | (UInt32(rawBytes[index + 1]) << 8)
          | (UInt32(rawBytes[index + 2]) << 16)
          | (UInt32(rawBytes[index + 3]) << 24)
        samples.append(Float(bitPattern: bits))
      }
    }
    guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.001 }) else {
      throw failure(.corruptInput, "sensevoice-invalid-float32-sample")
    }
    return samples
  }

  private func safeFileURL(for reference: String) -> URL? {
    guard
      !reference.isEmpty,
      !reference.hasPrefix("/"),
      URL(string: reference)?.scheme == nil
    else {
      return nil
    }
    let components = reference.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      return nil
    }

    let candidate =
      rootDirectory
      .appendingPathComponent(reference, isDirectory: false)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let rootPrefix =
      rootDirectory.path.hasSuffix("/")
      ? rootDirectory.path
      : rootDirectory.path + "/"
    guard candidate.path.hasPrefix(rootPrefix) else { return nil }
    return candidate
  }

  private func failure(
    _ category: InferenceFailureCategory,
    _ code: String
  ) -> InferenceEngineError {
    InferenceEngineError(category: category, code: code, retryable: false)
  }
}
