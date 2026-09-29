import BestASRInference
import BestASRModelManager
import BestASRRecognition
import Foundation
import MLX
import MLXAudioSTT
import MLXNN

public struct QwenRecognizedText: Equatable, Sendable {
  public let text: String
  public let language: String?

  public init(text: String, language: String?) {
    self.text = text
    self.language = language
  }
}

public protocol QwenASRSampleTranscribing: Sendable {
  func transcribe(samples: [Float], dictionaryTerms: [String]) async throws -> QwenRecognizedText
  /// Drops the weights so an idle App does not hold them.
  func release() async
}

public protocol QwenWordsAligning: Sendable {
  func align(samples: [Float], text: String, language: String?) async throws
    -> [TranscriptAlignmentWord]
  func prepare() async throws
  func release() async
}

/// A model and its KV caches never leave this actor. The public forward pass
/// lets the calling structured task own decoding all the way to completion;
/// cancelling it cannot leave an SDK detached producer using the same model.
public actor QwenASRBackend: QwenASRSampleTranscribing {
  private let directory: URL
  private var model: Qwen3ASRModel?
  /// Model inference is synchronous compute that holds its thread for the
  /// whole decode. On Swift's shared cooperative pool it starves everything
  /// else the dictation needs at exactly the wrong moment, so this actor runs
  /// on a thread of its own.
  private let computeQueue = DispatchSerialQueue(
    label: "com.bestasr.app.qwen-asr", qos: .userInitiated)

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    computeQueue.asUnownedSerialExecutor()
  }

  public init(verifiedModelDirectory: URL) { directory = verifiedModelDirectory }

  public func prepare() throws {
    guard model == nil else { return }
    model = try QwenNativeModelLoader.asr(from: directory)
  }

  /// Drops the weights. The next request loads them again; dictation warms
  /// the model when it starts, so an idle App does not hold 2 GB of GPU
  /// memory for a dictation that may not come.
  public func release() {
    model = nil
  }

  public func transcribe(samples: [Float], dictionaryTerms: [String]) throws -> QwenRecognizedText {
    try InferenceCancellation.check()
    guard !samples.isEmpty, samples.count <= QwenASRPinnedArtifact.maximumSamples,
      samples.allSatisfy(\.isFinite)
    else { throw qwenFailure(.invalidRequest, "qwen-asr-audio-invalid", false) }
    try prepare()
    guard let model, let tokenizer = model.tokenizer else {
      throw qwenFailure(.modelUnavailable, "qwen-asr-not-prepared", true)
    }
    // Keep prompt context bounded without changing the user's dictionary.
    // Canonical replacements still run on every resulting phrase afterwards.
    var terms: [String] = []
    var contextBytes = 0
    for term in dictionaryTerms.prefix(64) {
      let bounded = String(term.prefix(128))
      guard !bounded.isEmpty, !bounded.contains("<|"), !bounded.contains("<asr_text>") else {
        continue
      }
      guard contextBytes + bounded.utf8.count + 2 <= 2_048 else { break }
      terms.append(bounded)
      contextBytes += bounded.utf8.count + 2
    }
    // Not model.preprocessAudio: its filters are on a different mel scale
    // from training (verbatim CER 3.20% -> 2.71% on the personal eval set).
    let featuresStarted = ContinuousClock.now
    let (features, mask, audioTokens) = QwenWhisperFeatures.extract(
      samples, melBins: model.config.audioConfig.numMelBins)
    logQwenStage("qwen-features", since: featuresStarted, samples: samples.count)
    try InferenceCancellation.check()
    let input = model.buildPrompt(
      numAudioTokens: audioTokens, context: terms.joined(separator: ", "), language: nil)
    let promptLength = input.dim(1)
    guard promptLength > 1, promptLength <= 4_096 else {
      throw qwenFailure(.invalidRequest, "qwen-asr-prompt-limit", false)
    }
    let prefillStarted = ContinuousClock.now
    let cache = model.makeCache()
    // Match the upstream last-token prefill boundary for bounded clips while
    // using only public interfaces; no private module introspection or SDK fork.
    let prefix = model.callAsFunction(
      inputIds: input[0..., 0..<(promptLength - 1)],
      inputFeatures: features, featureAttentionMask: mask, cache: cache
    )
    eval(prefix)
    try InferenceCancellation.check()
    var logits = model.callAsFunction(
      inputIds: input[0..., (promptLength - 1)..<promptLength], cache: cache)
    eval(logits)
    logQwenStage("qwen-prefill", since: prefillStarted, samples: samples.count)
    let generateStarted = ContinuousClock.now
    var generated: [Int] = []
    var ended = false
    for _ in 0..<2_048 {
      try InferenceCancellation.check()
      let next = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
      try InferenceCancellation.check()
      if next == 151_645 || next == 151_643 {
        ended = true
        break
      }
      generated.append(next)
      if generated.count >= 24, Set(generated.suffix(24)).count <= 3 {
        // Do not present an interrupted repetition loop as a complete final.
        throw qwenFailure(.transientRuntime, "qwen-asr-repetitive-output", true)
      }
      logits = model.callAsFunction(
        inputIds: MLXArray([Int32(next)]).expandedDimensions(axis: 0), cache: cache)
    }
    logQwenStage("qwen-generate", since: generateStarted, samples: generated.count)
    guard ended else { throw qwenFailure(.transientRuntime, "qwen-asr-output-limit", true) }
    try InferenceCancellation.check()
    return try Self.parse(tokenizer.decode(tokens: generated))
  }

  public nonisolated static func parse(_ output: String) throws -> QwenRecognizedText {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return QwenRecognizedText(text: "", language: nil) }
    guard value.hasPrefix("language "), let marker = value.range(of: "<asr_text>") else {
      // The pinned automatic-language prompt must produce its own header.
      // Broken/incomplete control text is not a user's transcript.
      throw qwenFailure(.transientRuntime, "qwen-asr-output-header-invalid", true)
    }
    let language = value[value.index(value.startIndex, offsetBy: 9)..<marker.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let text = value[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 16_384, !text.contains("<|"), !text.contains("<asr_text>") else {
      throw qwenFailure(.transientRuntime, "qwen-asr-output-invalid", true)
    }
    return QwenRecognizedText(text: text, language: language.isEmpty ? nil : language)
  }
}

public actor QwenForcedAlignmentBackend: QwenWordsAligning {
  private let directory: URL
  private var model: Qwen3ForcedAlignerModel?
  /// Alignment is model inference too; see `QwenASRBackend`.
  private let computeQueue = DispatchSerialQueue(
    label: "com.bestasr.app.qwen-aligner", qos: .userInitiated)

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    computeQueue.asUnownedSerialExecutor()
  }

  public init(verifiedModelDirectory: URL) { directory = verifiedModelDirectory }

  public func prepare() throws {
    guard model == nil else { return }
    model = try QwenNativeModelLoader.alignment(from: directory)
  }

  /// Drops the weights; see `QwenASRBackend.release()`.
  public func release() {
    model = nil
  }

  public func align(samples: [Float], text: String, language: String?) throws
    -> [TranscriptAlignmentWord]
  {
    try InferenceCancellation.check()
    guard !samples.isEmpty, samples.count <= QwenASRPinnedArtifact.maximumSamples,
      samples.allSatisfy(\.isFinite), !text.isEmpty, text.count <= 4_000
    else { throw qwenFailure(.invalidRequest, "qwen-alignment-input-invalid", false) }
    try prepare()
    guard let model else {
      throw qwenFailure(.modelUnavailable, "qwen-alignment-not-prepared", true)
    }
    let processor = ForceAlignProcessor()
    let selectedLanguage =
      text.contains(where: processor.isCJKChar) ? "Chinese" : (language ?? "English")
    let expected =
      selectedLanguage.lowercased() == "chinese"
      ? processor.tokenizeChineseMixed(text) : processor.tokenizeSpaceLang(text)
    guard !expected.isEmpty, expected.count <= 1_024 else {
      throw qwenFailure(.invalidRequest, "qwen-alignment-word-limit", false)
    }
    let result = model.generate(audio: MLXArray(samples), text: text, language: selectedLanguage)
    try InferenceCancellation.check()
    guard result.items.map(\.text) == expected else {
      throw qwenFailure(.transientRuntime, "qwen-alignment-word-coverage", true)
    }
    return result.items.map {
      TranscriptAlignmentWord(text: $0.text, startSeconds: $0.startTime, endSeconds: $0.endTime)
    }
  }
}

public struct QwenASRModelHealthCheck: ManagedModelHealthChecking {
  public init() {}
  public func check(modelDirectory: URL) async throws {
    try await QwenASRBackend(verifiedModelDirectory: modelDirectory).prepare()
  }
}

public struct QwenAlignmentModelHealthCheck: ManagedModelHealthChecking {
  public init() {}
  public func check(modelDirectory: URL) async throws {
    try await QwenForcedAlignmentBackend(verifiedModelDirectory: modelDirectory).prepare()
  }
}

private enum QwenNativeModelLoader {
  static func requireMetalResources() throws {
    let roots =
      [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
      ].compactMap { $0 } + Bundle.allBundles.compactMap(\.resourceURL)
    // Mirror Cmlx's loaded-bundle resource lookup. Merely finding a sibling
    // directory of an XCTest bundle is insufficient for its native loader.
    guard
      roots.contains(where: {
        FileManager.default.fileExists(
          atPath: $0.appendingPathComponent(
            "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
          ).path)
      })
    else { throw qwenFailure(.modelUnavailable, "qwen-metal-resource-missing", false) }
  }

  static func asr(from directory: URL) throws -> Qwen3ASRModel {
    do {
      try InferenceCancellation.check()
      guard directory.isFileURL else {
        throw qwenFailure(.invalidRequest, "qwen-model-local-files-required", false)
      }
      try requireMetalResources()
      let config = try JSONDecoder().decode(
        Qwen3ASRConfig.self,
        from: Data(contentsOf: directory.appendingPathComponent("config.json")))
      guard config.modelType == "qwen3_asr", !config.isForcedAligner,
        config.perLayerQuantization != nil
      else {
        throw qwenFailure(.incompatibleArtifact, "qwen-asr-config-invalid", false)
      }
      let tokenizer = try QwenLocalTokenizer.load(from: directory)
      guard tokenizer.encode(text: "<|im_end|>") == [151_645],
        tokenizer.encode(text: "<|endoftext|>") == [151_643]
      else {
        throw qwenFailure(.incompatibleArtifact, "qwen-asr-tokenizer-invalid", false)
      }
      let model = Qwen3ASRModel(config)
      model.tokenizer = tokenizer
      let weights = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
      let sanitized = Qwen3ASRModel.sanitize(
        weights: weights, skipLmHead: config.textConfig.tieWordEmbeddings)
      quantize(model: model) { path, _ in
        guard !path.hasPrefix("audio_tower"), sanitized["\(path).scales"] != nil else { return nil }
        return config.perLayerQuantization?.quantization(layer: path)?.asTuple
      }
      try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
      eval(model)
      try InferenceCancellation.check()
      return model
    } catch let error as InferenceEngineError { throw error } catch {
      throw qwenFailure(.modelUnavailable, "qwen-asr-verified-load-failed", true)
    }
  }

  static func alignment(from directory: URL) throws -> Qwen3ForcedAlignerModel {
    do {
      try InferenceCancellation.check()
      guard directory.isFileURL else {
        throw qwenFailure(.invalidRequest, "qwen-model-local-files-required", false)
      }
      try requireMetalResources()
      let config = try JSONDecoder().decode(
        Qwen3ASRConfig.self,
        from: Data(contentsOf: directory.appendingPathComponent("config.json")))
      guard config.isForcedAligner, config.perLayerQuantization != nil,
        config.timestampSegmentTime == 80, let timestampID = config.timestampTokenId
      else {
        throw qwenFailure(.incompatibleArtifact, "qwen-alignment-config-invalid", false)
      }
      let tokenizer = try QwenLocalTokenizer.load(from: directory)
      guard tokenizer.encode(text: "<timestamp>") == [timestampID] else {
        throw qwenFailure(.incompatibleArtifact, "qwen-alignment-tokenizer-invalid", false)
      }
      let model = Qwen3ForcedAlignerModel(config)
      model.tokenizer = tokenizer
      let weights = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
      let sanitized = Qwen3ForcedAlignerModel.sanitize(weights: weights)
      quantize(model: model) { path, _ in
        guard !path.hasPrefix("audio_tower"), sanitized["\(path).scales"] != nil else { return nil }
        return config.perLayerQuantization?.quantization(layer: path)?.asTuple
      }
      try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
      eval(model)
      try InferenceCancellation.check()
      return model
    } catch let error as InferenceEngineError { throw error } catch {
      throw qwenFailure(.modelUnavailable, "qwen-alignment-verified-load-failed", true)
    }
  }
}

func qwenFailure(_ category: InferenceFailureCategory, _ code: String, _ retryable: Bool)
  -> InferenceEngineError
{
  InferenceEngineError(category: category, code: code, retryable: retryable)
}
