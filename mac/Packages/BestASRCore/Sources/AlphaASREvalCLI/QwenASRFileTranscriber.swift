import AVFoundation
import BestASRAlphaEvaluation
import BestASRQwenRuntime
import Foundation
import Hub
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXNN
import Tokenizers

enum QwenASREvaluationArtifact {
  static let modelID = "qwen3-asr-1.7b-8bit-a8379a2e"
  static let modelRevision = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
  static let runtimeRevision = "cae704f53bc32a3d0b606823828fbc5bedaaf388"
}

/// Developer challenger only. Synchronous MLX work stays on this actor, never
/// on the App main actor. Do not turn this into a production adapter without
/// cancellation, timestamp/alignment and durable-job integration.
actor QwenASRFileTranscriber: AlphaASRFileTranscribing {
  private let modelDirectory: URL
  private var runtime: Qwen3ASRModel?

  init(verifiedModelDirectory: URL) {
    modelDirectory = verifiedModelDirectory
  }

  func prepare() throws {
    guard runtime == nil else { return }
    try Task.checkCancellation()
    // SwiftPM does not compile MLX's Metal resource bundle. The evaluation
    // launcher assembles it from the existing canonical native App build.
    let metalResource = Bundle.main.bundleURL.appendingPathComponent(
      "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    )
    guard FileManager.default.fileExists(atPath: metalResource.path) else {
      throw QwenASREvaluationError.missingMetalResources
    }
    let config = try JSONDecoder().decode(
      Qwen3ASRConfig.self,
      from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
    )
    guard config.modelType == "qwen3_asr", !config.isForcedAligner,
      config.perLayerQuantization != nil
    else { throw QwenASREvaluationError.unexpectedModel }

    // Adapted from the pinned upstream local loader (MIT; see Legal notice).
    // Its convenience entry point writes tokenizer.json into the verified
    // model directory; building the same tokenizer in memory avoids that.
    let model = Qwen3ASRModel(config)
    model.tokenizer = try QwenLocalTokenizer.load(from: modelDirectory)
    let weights = try MLX.loadArrays(
      url: modelDirectory.appendingPathComponent("model.safetensors")
    )
    let sanitized = Qwen3ASRModel.sanitize(
      weights: weights,
      skipLmHead: config.textConfig.tieWordEmbeddings
    )
    quantize(model: model) { path, _ in
      guard !path.hasPrefix("audio_tower"), sanitized["\(path).scales"] != nil
      else { return nil }
      return config.perLayerQuantization?.quantization(layer: path)?.asTuple
    }
    try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
    eval(model)
    try Task.checkCancellation()
    runtime = model
  }

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    guard let runtime else { throw QwenASREvaluationError.notPrepared }
    try Task.checkCancellation()
    let file = try AVAudioFile(forReading: audioURL)
    // Upstream loadAudioArray reads the first channel. Explicitly reject
    // multichannel evaluation inputs rather than silently dropping a track.
    guard file.processingFormat.channelCount == 1,
      file.processingFormat.sampleRate.isFinite,
      file.processingFormat.sampleRate > 0, file.length > 0,
      Double(file.length) / file.processingFormat.sampleRate <= 600
    else { throw QwenASREvaluationError.unsupportedAudio }
    let (_, samples) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
    let context = dictionaryTerms.prefix(64).map { String($0.prefix(128)) }
      .joined(separator: ", ")
    let result = runtime.generate(
      audio: samples,
      maxTokens: 2048,
      temperature: 0,
      context: context,
      language: nil,
      chunkDuration: 30,
      minChunkDuration: 1,
      repetitionPenalty: 1,
      repetitionContextSize: 32
    )
    try Task.checkCancellation()
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

}

enum QwenASREvaluationError: Error {
  case missingMetalResources
  case notPrepared
  case unexpectedModel
  case unsupportedAudio
  case invalidTokenizer
}
