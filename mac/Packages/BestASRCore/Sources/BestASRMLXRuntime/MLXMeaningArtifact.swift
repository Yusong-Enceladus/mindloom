import BestASRInference
import BestASRModelManager
import Foundation

/// The meaning search's model (v12 search): a pinned, signed-off artifact
/// downloaded and checked file by file by `LocalModelManager` like every
/// other model, plus how it is run (`MLXMeaningRecipe`) and the similarity
/// below which a piece is not a result. Chosen by local evaluation
/// (`MeaningEvalCLI`; notes in IMPLEMENTATION_STATUS.md), not by vendor
/// numbers.
public struct MLXMeaningArtifact: Equatable, Sendable {
  public let artifactID: String
  public let sourceRevision: String
  public let treeSHA256: String
  public let totalSizeBytes: UInt64
  public let recipe: MLXMeaningRecipe
  /// Pieces less similar than this are not found by meaning. Calibrated on
  /// the synthetic and the private real set: at 0.75 a search for something
  /// the library does not hold shows about as much as the character search
  /// alone, while recall stays at its best.
  public let floor: Float

  /// Qwen3-Embedding-0.6B, MLX 4-bit (DWQ) conversion: 351 MB on disk.
  public static let qwen3Embedding4Bit = Self(
    artifactID: "qwen3-embedding-0.6b-mlx-4bit-6c3ae708",
    sourceRevision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
    treeSHA256: "c9b6afa5185b24e8757450b1f168c87ae6c3d4d1fa3c092528d923f10e34271d",
    totalSizeBytes: 351_226_578,
    recipe: .qwen3Embedding(
      name: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
      revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a"),
    floor: 0.75)

  /// The one the App installs and searches with.
  public static let selected = qwen3Embedding4Bit
}

public enum MLXMeaningEmbedderFactory {
  /// The embedder over the verified, active copy of `artifact` (nothing is
  /// loaded until the first piece is embedded).
  public static func make(
    modelManager: LocalModelManager, artifact: MLXMeaningArtifact = .selected
  ) async throws -> MLXMeaningEmbedder {
    let active = try await modelManager.discoverActive(
      artifactID: artifact.artifactID, healthCheck: FileSetModelHealthCheck())
    guard active.descriptor.exactVersion == artifact.sourceRevision,
      active.descriptor.treeSHA256 == artifact.treeSHA256
    else {
      throw InferenceEngineError(
        category: .incompatibleArtifact, code: "mlx-meaning-active-artifact-mismatch",
        retryable: false)
    }
    return MLXMeaningEmbedder(
      verifiedModelDirectory: active.directory, recipe: artifact.recipe,
      tokenBudget: appTokenBudget)
  }

  /// Tokens per forward pass in the App. Measured on a copy of a real
  /// library at the App's 256 MB MLX cache limit: 1,024 indexed faster
  /// (80 pieces/s against 60) with a lower peak (MLX 1,280 MB against
  /// 1,355 MB) than 2,048 or 4,096.
  public static let appTokenBudget = 1_024
}

/// Model-manager activation check: the exact files load through the MLX
/// embedder and give a vector of the expected length (synthetic text).
public struct MLXMeaningModelHealthCheck: ManagedModelHealthChecking {
  private let recipe: MLXMeaningRecipe

  public init(recipe: MLXMeaningRecipe = MLXMeaningArtifact.selected.recipe) {
    self.recipe = recipe
  }

  public func check(modelDirectory: URL) async throws {
    let embedder = MLXMeaningEmbedder(verifiedModelDirectory: modelDirectory, recipe: recipe)
    let vectors = try await embedder.embed(["模型检查"], role: .document)
    await embedder.release()
    guard vectors.first?.count == recipe.dimension else {
      throw InferenceEngineError(
        category: .modelUnavailable, code: "mlx-meaning-health-check-failed", retryable: false)
    }
  }
}
