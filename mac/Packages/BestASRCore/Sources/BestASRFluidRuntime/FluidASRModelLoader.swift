import BestASRInference
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Local-only loading policy for the pinned FunASR Core ML artifacts.
///
/// On the development Mac, the CPU-only framing convolutions changed already
/// observed speech features when the waveform grew by 20 ms. FP32 CPU/GPU
/// preprocessing preserves the common prefix. Keep this policy separate from
/// the quantized encoder/decoder, whose FP16 activations require the ANE.
enum FluidASRModelLoader {
  static func preprocessorConfiguration() -> MLModelConfiguration {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    configuration.allowLowPrecisionAccumulationOnGPU = false
    return configuration
  }

  static func inferenceConfiguration() -> MLModelConfiguration {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    return configuration
  }

  static func preprocessor(named name: String, from directory: URL) throws -> MLModel {
    try model(named: name, from: directory, configuration: preprocessorConfiguration())
  }

  static func senseVoice(from directory: URL) throws -> SenseVoiceModels {
    try SenseVoiceModels(
      preprocessor: preprocessor(named: "SenseVoicePreprocessor", from: directory),
      encoder: model(
        named: "SenseVoiceSmall_int8", from: directory,
        configuration: inferenceConfiguration()
      ),
      vocabulary: vocabulary(from: directory)
    )
  }

  static func paraformer(from directory: URL) throws -> ParaformerModels {
    let configuration = inferenceConfiguration()
    return try ParaformerModels(
      preprocessor: preprocessor(named: "ParaformerPreprocessor", from: directory),
      encoder: model(
        named: "ParaformerEncoder_int8", from: directory, configuration: configuration),
      cifAlphas: model(named: "ParaformerCifAlphas", from: directory, configuration: configuration),
      decoder: model(
        named: "ParaformerDecoder_int8", from: directory, configuration: configuration),
      vocabulary: vocabulary(from: directory)
    )
  }

  private static func model(
    named name: String, from directory: URL, configuration: MLModelConfiguration
  ) throws -> MLModel {
    try MLModel(
      contentsOf: directory.appendingPathComponent("\(name).mlmodelc"),
      configuration: configuration
    )
  }

  private static func vocabulary(from directory: URL) throws -> [Int: String] {
    let data = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
    let value = try JSONSerialization.jsonObject(with: data)
    if let tokens = value as? [String] {
      return Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
    }
    if let tokens = value as? [String: String] {
      var result: [Int: String] = [:]
      for (key, token) in tokens {
        guard let index = Int(key), index >= 0, result[index] == nil else {
          throw invalidVocabulary
        }
        result[index] = token
      }
      return result
    }
    throw invalidVocabulary
  }

  private static var invalidVocabulary: InferenceEngineError {
    InferenceEngineError(
      category: .incompatibleArtifact,
      code: "fluid-asr-invalid-local-vocabulary",
      retryable: false
    )
  }
}
