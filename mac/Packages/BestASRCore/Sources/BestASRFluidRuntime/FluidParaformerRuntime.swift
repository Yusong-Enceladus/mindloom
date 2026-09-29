import BestASRInference
import BestASRModelManager
import FluidAudio
import Foundation

public enum FluidParaformerPinnedArtifact {
  public static let candidateID = "fluid-paraformer-zh"
  public static let artifactID = "fluid-paraformer-large-zh-int8-5dd557bd"
  public static let sourceRevision =
    "5dd557bd06342a3cd07ceccb909d8a45e48b053a"
  public static let treeSHA256 =
    "d1a072eea0c4b478452e0f5143920aae35a4e4484e9f20808ed5579e5a3b26b6"
  public static let runtimeRevision =
    "19600a485baa4998812e4654b70d2bab8f2c9949"

  public static let descriptor = ModelArtifactDescriptor(
    artifactID: artifactID,
    version: sourceRevision,
    sha256: treeSHA256,
    runtimeID: InferenceRuntimeID("fluid-audio.paraformer-zh"),
    capabilities: [
      .asrBatch,
      .asrRevisioned,
      .asrTimestamps,
    ],
    minimumOS: InferenceOSVersion(major: 14, minor: 2),
    supportedArchitectures: ["arm64"],
    minimumUnifiedMemoryBytes: 17_179_869_184,
    licenseIdentifier: "LicenseRef-FunASR-Model-1.1",
    networkRequired: false,
    metadata: [
      "encoderPrecision": "int8",
      "language": "zh-CN",
      "runtimeRevision": runtimeRevision,
      "sourceRevision": sourceRevision,
    ]
  )
}

/// Loads only a model-manager-verified local Paraformer directory. The
/// FluidAudio automatic download entry point is deliberately unreachable.
public actor FluidParaformerBackend: FluidASRSampleTranscribing {
  private let manager: ParaformerManager

  public init(verifiedModelDirectory: URL) throws {
    do {
      let models = try FluidASRModelLoader.paraformer(from: verifiedModelDirectory)
      manager = ParaformerManager(models: models)
    } catch {
      throw InferenceEngineError(
        category: .modelUnavailable,
        code: "paraformer-verified-model-load-failed",
        retryable: true
      )
    }
  }

  public func transcribe(audioURL: URL) async throws -> String {
    do {
      return try await manager.transcribe(audioURL: audioURL)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "paraformer-runtime-failed",
        retryable: true
      )
    }
  }

  public func transcribe(samples: [Float]) async throws -> String {
    do {
      return try await manager.transcribe(audio: samples)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "paraformer-runtime-failed",
        retryable: true
      )
    }
  }
}

public struct FluidParaformerModelHealthCheck: ManagedModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) async throws {
    _ = try FluidASRModelLoader.paraformer(from: modelDirectory)
  }
}

public enum FluidParaformerRuntimeFactory {
  public static func make(
    modelManager: LocalModelManager,
    audioAssetRoot: URL,
    maximumSamples: Int = Float32PCMFileLoader.defaultMaximumSamples
  ) async throws -> FluidMonolingualASRRuntime {
    let active = try await modelManager.discoverActive(
      artifactID: FluidParaformerPinnedArtifact.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    guard
      active.descriptor.version == FluidParaformerPinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256 == FluidParaformerPinnedArtifact.treeSHA256
    else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "paraformer-active-artifact-mismatch",
        retryable: true
      )
    }
    return FluidMonolingualASRRuntime(
      candidateID: FluidParaformerPinnedArtifact.candidateID,
      audioLoader: try Float32PCMFileLoader(
        rootDirectory: audioAssetRoot,
        maximumSamples: maximumSamples
      ),
      backend: try FluidParaformerBackend(
        verifiedModelDirectory: active.directory
      )
    )
  }
}
