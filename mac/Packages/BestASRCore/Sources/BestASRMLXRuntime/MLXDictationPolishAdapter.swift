import BestASRDictation
import BestASRInference
import Foundation

/// Bridges the generic, versioned local-text engine into the dictation
/// pipeline. The coordinator still applies the authoritative protected-fact
/// validator and falls back without losing the source transcript.
public struct MLXDictationPolishAdapter: DictationPolishPort {
  private let engine: any LocalTextEngine
  private let artifactID: String
  private let configHash: String

  public init(
    engine: any LocalTextEngine,
    artifactID: String,
    configHash: String
  ) throws {
    guard
      !artifactID.isEmpty,
      configHash.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil
    else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "mlx-dictation-adapter-config-invalid",
        retryable: false
      )
    }
    self.engine = engine
    self.artifactID = artifactID
    self.configHash = configHash
  }

  public func polish(
    _ request: DictationPolishRequest
  ) async throws -> DictationPolishResult {
    let segmentIDs =
      request.transcript.segmentIDs.isEmpty
      ? [request.transcript.revisionID.rawValue]
      : request.transcript.segmentIDs
    let generated = try await engine.generate(
      LocalTextRequest(
        metadata: InferenceRequestMetadata(
          jobID: request.transcript.revisionID.rawValue,
          inputRevision: 1,
          modelArtifactID: artifactID,
          configHash: configHash
        ),
        taskID: .rewrite,
        transcriptRevisionID: request.transcript.revisionID.rawValue,
        sourceSegmentIDs: segmentIDs,
        sourceText: request.transcript.text
      )
    )
    guard
      generated.modelArtifactID == artifactID,
      generated.taskID == .rewrite,
      !generated.outputText.isEmpty
    else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "mlx-dictation-adapter-output-invalid",
        retryable: false
      )
    }
    return DictationPolishResult(
      sourceRevisionID: request.transcript.revisionID,
      text: generated.outputText,
      disposition: .model,
      modelArtifactID: generated.modelArtifactID
    )
  }
}
