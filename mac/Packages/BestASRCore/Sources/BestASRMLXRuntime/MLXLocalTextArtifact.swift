import BestASRInference
import BestASRLocalText
import BestASRModelManager
import Foundation

public struct MLXLocalTextArtifact: Codable, Equatable, Sendable {
  public static let runtimeRevision =
    "1c05248bb0899e2a7a4962b84d319cf12f4e12aa"
  public static let polishPipelineRevision =
    "qwen3-structured-1024-protected-fact-gate-v2"

  public let artifactID: String
  public let sourceRevision: String
  public let treeSHA256: String
  public let totalSizeBytes: UInt64

  public init(
    artifactID: String,
    sourceRevision: String,
    treeSHA256: String,
    totalSizeBytes: UInt64
  ) {
    self.artifactID = artifactID
    self.sourceRevision = sourceRevision
    self.treeSHA256 = treeSHA256
    self.totalSizeBytes = totalSizeBytes
  }

  public var descriptor: ModelArtifactDescriptor {
    ModelArtifactDescriptor(
      artifactID: artifactID,
      version: sourceRevision,
      sha256: treeSHA256,
      runtimeID: InferenceRuntimeID("mlx-swift-lm.qwen3"),
      capabilities: [.localTextStructured],
      minimumOS: InferenceOSVersion(major: 14, minor: 2),
      supportedArchitectures: ["arm64"],
      minimumUnifiedMemoryBytes: 17_179_869_184,
      licenseIdentifier: "Apache-2.0",
      networkRequired: false,
      metadata: [
        "quantization": "4-bit",
        "runtimeRevision": Self.runtimeRevision,
        "sourceRevision": sourceRevision,
      ]
    )
  }

  public static let qwen3Small = Self(
    artifactID: "qwen3-0.6b-mlx-4bit-173234aa",
    sourceRevision: "173234aa840d113125e9f2271100ddbaf16c9620",
    treeSHA256:
      "2b65858858995aad107c11876efc66def306fc532d69053ff0f522d670d70428",
    totalSizeBytes: 332_782_902
  )

  /// The general text model: spoken instructions and local-text jobs. Loaded
  /// only when one of those needs it, released with the other models when the
  /// App is idle. Tidying a dictation stays on the personal 0.6B, whose
  /// validator clamps it to deletion.
  ///
  /// Kept at 1.7B after measuring the 4B below on the same nine probe cases
  /// (2026-09-22): the 4B rewrote "这事儿我明天弄完" as "这 matter 我明天处理完",
  /// echoed the summarize case exactly as the 1.7B does, and took about twice
  /// as long, for +1.2 GB of disk. It was better on one English tone rewrite.
  /// That is not a model to give someone who dictates in Chinese.
  public static let qwen3Selected = Self(
    artifactID: "qwen3-1.7b-mlx-4bit-21457c6f",
    sourceRevision: "21457c6f51ed54a7c16e988c0844db973815c137",
    treeSHA256:
      "09570edbadcacc0bb3abc5c58d688f92978cd62601cf98e11cf38356fd5bd7be",
    totalSizeBytes: 930_271_884
  )

  /// Qwen's own MLX conversion of Qwen3-4B, pinned so it can be measured
  /// again (`SpokenModeProbeCLI --artifact large`). Downloaded and hashed file
  /// by file; the tree digest below is the one the files actually produce.
  /// Not the mlx-community conversion, which was also measured and was worse.
  public static let qwen3Large = Self(
    artifactID: "qwen3-4b-mlx-4bit-52a5ab34",
    sourceRevision: "52a5ab34fa604bc8af6d3ce0cac0cab10b7eb495",
    treeSHA256:
      "0680d815bfd81891fb6413245bf5db78b1119cd3ba1f15ca5abfa66b7d65b505",
    totalSizeBytes: 2_153_299_972
  )
}

public enum MLXLocalTextRuntimeFactory {
  public static func make(
    modelManager: LocalModelManager,
    artifact: MLXLocalTextArtifact,
    policy: MLXLocalTextRuntimePolicy = MLXLocalTextRuntimePolicy(),
    prepare: Bool = true
  ) async throws -> VersionedLocalTextAdapter {
    VersionedLocalTextAdapter(
      artifact: artifact.descriptor,
      runtime: try await makeRuntime(
        modelManager: modelManager,
        artifact: artifact,
        policy: policy,
        prepare: prepare
      )
    )
  }

  /// The same verified runtime without the versioned task wrapper, for the
  /// two capabilities that are not `LocalTextTaskID` tasks — translation and
  /// spoken instructions. Both replace the text wholesale, which the task
  /// pipeline's validator is built to reject, so they call the model directly
  /// and carry their own bounds.
  public static func makeRuntime(
    modelManager: LocalModelManager,
    artifact: MLXLocalTextArtifact,
    policy: MLXLocalTextRuntimePolicy = MLXLocalTextRuntimePolicy(),
    prepare: Bool = true
  ) async throws -> MLXLocalTextRuntime {
    let active = try await modelManager.discoverActive(
      artifactID: artifact.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    guard
      active.descriptor.exactVersion == artifact.sourceRevision,
      active.descriptor.treeSHA256 == artifact.treeSHA256
    else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "mlx-local-text-active-artifact-mismatch",
        retryable: false
      )
    }
    let runtime = MLXLocalTextRuntime(
      verifiedModelDirectory: active.directory,
      policy: policy
    )
    if prepare {
      try await runtime.prepare()
    }
    return runtime
  }
}

/// Model-manager activation health check that exercises the exact local
/// artifact through the concrete MLX loader without generating user text.
public struct MLXLocalTextModelHealthCheck: ManagedModelHealthChecking {
  private let policy: MLXLocalTextRuntimePolicy

  public init(policy: MLXLocalTextRuntimePolicy = MLXLocalTextRuntimePolicy()) {
    self.policy = policy
  }

  public func check(modelDirectory: URL) async throws {
    let runtime = MLXLocalTextRuntime(
      verifiedModelDirectory: modelDirectory,
      policy: policy
    )
    try await runtime.prepare()
  }
}
