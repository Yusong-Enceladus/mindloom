import BestASRAlphaEvaluation
import Foundation
@preconcurrency import WhisperKit

/// This challenger belongs only to the developer evaluator. It is deliberately
/// absent from the App's model catalog and production routing until compared.
enum WhisperEvaluationArtifact {
  static let modelID = "whisperkit-large-v3-turbo-626mb-0f63a780"
  static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
  static let modelFolder = "openai_whisper-large-v3-v20240930_626MB"
  static let tokenizerID = "whisper-large-v3-tokenizer-06f233fe"
  static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
  static let runtimeRevision = "25c62997041c134b03ca82731ce2f6fd2cae1eb9"
}

/// Actor ownership and an explicit busy guard keep this non-Sendable SDK from
/// receiving overlapping requests, including across suspension points.
actor WhisperFileTranscriber: AlphaASRFileTranscribing {
  private let modelDirectory: URL
  private let tokenizerDirectory: URL
  private var runtime: WhisperKit?
  private var busy = false

  init(verifiedModelDirectory: URL, verifiedTokenizerDirectory: URL) {
    modelDirectory = verifiedModelDirectory.appendingPathComponent(
      WhisperEvaluationArtifact.modelFolder
    )
    tokenizerDirectory = verifiedTokenizerDirectory
  }

  func prepare() async throws {
    guard !busy else { throw WhisperEvaluationError.concurrentRequest }
    guard runtime == nil else { return }
    busy = true
    defer { busy = false }
    try Task.checkCancellation()

    // The SDK otherwise catches local tokenizer errors and retries the Hub.
    // Parse the exact local tokenizer first and propagate any failure. The
    // evaluation launcher additionally denies all network to the whole process.
    _ = try await AutoTokenizerWrapper.from(
      modelFolder: tokenizerDirectory,
      hubApi: HubApiWrapper(downloadBase: tokenizerDirectory)
    )
    let loaded = try await WhisperKit(
      WhisperKitConfig(
        model: WhisperEvaluationArtifact.modelFolder,
        downloadBase: tokenizerDirectory,
        modelFolder: modelDirectory.path,
        tokenizerFolder: tokenizerDirectory,
        computeOptions: ModelComputeOptions(
          melCompute: .cpuAndGPU,
          audioEncoderCompute: .cpuAndNeuralEngine,
          textDecoderCompute: .cpuAndNeuralEngine
        ),
        verbose: false,
        prewarm: false,
        load: true,
        download: false
      )
    )
    try Task.checkCancellation()
    guard loaded.modelVariant == .largev3 else {
      throw WhisperEvaluationError.unexpectedModel
    }
    runtime = loaded
  }

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    guard !busy else { throw WhisperEvaluationError.concurrentRequest }
    guard let runtime, let tokenizer = runtime.tokenizer else {
      throw WhisperEvaluationError.notPrepared
    }
    busy = true
    defer { busy = false }
    try Task.checkCancellation()

    let context = dictionaryTerms.prefix(64).map { String($0.prefix(128)) }
      .joined(separator: ", ")
    let contextTokens = tokenizer.encode(text: context)
      .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    let options = DecodingOptions(
      verbose: false,
      task: .transcribe,
      temperature: 0,
      temperatureFallbackCount: 0,
      usePrefillPrompt: true,
      detectLanguage: true,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: false,
      promptTokens: context.isEmpty ? nil : Array(contextTokens.prefix(128)),
      suppressBlank: true,
      concurrentWorkerCount: 1
    )
    let results = try await runtime.transcribe(
      audioPath: audioURL.path,
      decodeOptions: options,
      callback: { _ in Task.isCancelled ? false : nil }
    )
    try Task.checkCancellation()
    return results.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private enum WhisperEvaluationError: Error {
  case concurrentRequest
  case notPrepared
  case unexpectedModel
}
