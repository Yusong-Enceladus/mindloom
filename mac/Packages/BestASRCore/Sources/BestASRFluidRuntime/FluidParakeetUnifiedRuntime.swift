import BestASRInference
import BestASRModelManager
import FluidAudio
import Foundation

public enum FluidParakeetUnifiedPinnedArtifact {
  public static let candidateID = "fluid-parakeet-unified-en"
  public static let artifactID = "fluid-parakeet-unified-en-int8-4252711f"
  public static let sourceRevision =
    "4252711f6f060f9a2f91e5f081a806d7f45eebd8"
  public static let treeSHA256 =
    "78c6a306a7207f7a771a5468c1151c0a459d049702cbcc47d28fdc817392e2e4"
  public static let runtimeRevision =
    "19600a485baa4998812e4654b70d2bab8f2c9949"

  public static let descriptor = ModelArtifactDescriptor(
    artifactID: artifactID,
    version: sourceRevision,
    sha256: treeSHA256,
    runtimeID: InferenceRuntimeID("fluid-audio.parakeet-unified-en"),
    capabilities: [
      .asrBatch,
      .asrRevisioned,
      .asrStreaming,
      .asrTimestamps,
    ],
    minimumOS: InferenceOSVersion(major: 14, minor: 2),
    supportedArchitectures: ["arm64"],
    minimumUnifiedMemoryBytes: 17_179_869_184,
    licenseIdentifier: "CC-BY-4.0",
    networkRequired: false,
    metadata: [
      "encoderPrecision": "int8",
      "language": "en-US",
      "runtimeRevision": runtimeRevision,
      "sourceRevision": sourceRevision,
    ]
  )
}

/// Loads the English offline encoder and shared RNNT stages only from an exact,
/// model-manager-verified directory. No Hub client is reachable from this type.
public actor FluidParakeetUnifiedBackend: FluidASRSampleTranscribing {
  private let manager: UnifiedAsrManager

  public init(verifiedModelDirectory: URL) async throws {
    do {
      let manager = UnifiedAsrManager(encoderPrecision: .int8)
      try await manager.loadModels(from: verifiedModelDirectory)
      self.manager = manager
    } catch {
      throw InferenceEngineError(
        category: .modelUnavailable,
        code: "parakeet-unified-verified-model-load-failed",
        retryable: true
      )
    }
  }

  public func transcribe(audioURL: URL) async throws -> String {
    do {
      let samples = try AudioConverter().resampleAudioFile(audioURL)
      return try await manager.transcribe(samples)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "parakeet-unified-runtime-failed",
        retryable: true
      )
    }
  }

  public func transcribe(samples: [Float]) async throws -> String {
    do {
      return try await manager.transcribe(samples)
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError {
      throw error
    } catch {
      throw InferenceEngineError(
        category: .transientRuntime,
        code: "parakeet-unified-runtime-failed",
        retryable: true
      )
    }
  }
}

public struct FluidParakeetUnifiedModelHealthCheck: ManagedModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) async throws {
    let manager = UnifiedAsrManager(encoderPrecision: .int8)
    try await manager.loadModels(from: modelDirectory)
  }
}

public enum FluidParakeetUnifiedRuntimeFactory {
  public static func make(
    modelManager: LocalModelManager,
    audioAssetRoot: URL,
    maximumSamples: Int = Float32PCMFileLoader.defaultMaximumSamples
  ) async throws -> FluidMonolingualASRRuntime {
    let active = try await modelManager.discoverActive(
      artifactID: FluidParakeetUnifiedPinnedArtifact.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    guard
      active.descriptor.version
        == FluidParakeetUnifiedPinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256
        == FluidParakeetUnifiedPinnedArtifact.treeSHA256
    else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "parakeet-unified-active-artifact-mismatch",
        retryable: true
      )
    }
    return FluidMonolingualASRRuntime(
      candidateID: FluidParakeetUnifiedPinnedArtifact.candidateID,
      audioLoader: try Float32PCMFileLoader(
        rootDirectory: audioAssetRoot,
        maximumSamples: maximumSamples
      ),
      backend: try await FluidParakeetUnifiedBackend(
        verifiedModelDirectory: active.directory
      )
    )
  }
}
