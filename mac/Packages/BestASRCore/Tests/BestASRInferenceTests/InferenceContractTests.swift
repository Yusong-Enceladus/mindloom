import Foundation
import XCTest

@testable import BestASRInference

final class InferenceContractTests: XCTestCase {
  func testEveryEngineUsesOneVersionedReplaceableContract() async throws {
    let first = FakeUnifiedEngine(artifact: artifact(id: "fixture-a"), label: "first")
    let second = FakeUnifiedEngine(artifact: artifact(id: "fixture-b"), label: "second")
    let request = asrRequest(artifactID: "fixture-a")
    let engines: [any ASREngine] = [first, second]
    var outputs: [ASRResult] = []
    for (index, engine) in engines.enumerated() {
      let artifactID = index == 0 ? "fixture-a" : "fixture-b"
      outputs.append(
        try await engine.transcribe(asrRequest(artifactID: artifactID))
      )
    }

    XCTAssertEqual(outputs.map(\.segments.first?.text), ["first", "second"])
    XCTAssertTrue(
      outputs.allSatisfy { $0.contractVersion == InferenceContract.currentVersion }
    )
    let diarization = try await first.diarize(
      DiarizationRequest(
        metadata: request.metadata,
        audio: [request.audio],
        expectedSpeakerRange: 1...3
      )
    )
    let embedding = try await first.embed(
      SpeakerEmbeddingRequest(
        metadata: request.metadata,
        audio: request.audio,
        embeddingSpaceID: "fixture-space"
      )
    )
    let text = try await first.generate(
      LocalTextRequest(
        metadata: request.metadata,
        taskID: .rewrite,
        transcriptRevisionID: UUID(),
        sourceSegmentIDs: [],
        sourceText: "synthetic input"
      )
    )
    XCTAssertEqual(diarization.turns.first?.speakerClusterID, "speaker-0")
    XCTAssertEqual(embedding.vector, [0.25, 0.75])
    XCTAssertEqual(text.outputText, "first")
  }

  func testErrorsAreCategorizedAndUnsupportedVersionsFailClosed() async throws {
    let failing = FailingASREngine(artifact: artifact(id: "fixture-a"))
    do {
      _ = try await failing.transcribe(asrRequest(artifactID: "fixture-a"))
      XCTFail("Expected a categorized engine failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .modelUnavailable)
      XCTAssertTrue(error.retryable)
      XCTAssertEqual(error.code, "fixture-unavailable")
    }

    let engine = FakeUnifiedEngine(artifact: artifact(id: "fixture-a"), label: "ok")
    do {
      _ = try await engine.transcribe(
        asrRequest(artifactID: "fixture-a", contractVersion: 999)
      )
      XCTFail("Expected an unsupported protocol version failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .unsupportedContractVersion)
      XCTAssertFalse(error.retryable)
    }
  }

  func testCancellationProducesExplicitCancelledCategory() async throws {
    let engine = CancellableASREngine(artifact: artifact(id: "fixture-a"))
    let request = asrRequest(artifactID: "fixture-a")
    let task = Task {
      try await engine.transcribe(request)
    }
    await Task.yield()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error, .cancelled)
    }
  }

  func testRegistryPreservesUnknownArtifactsAndSelectsByCapabilities() async throws {
    let registry = CapabilityModelRegistry()
    let known = artifact(id: "known")
    let unknown = ModelArtifactDescriptor(
      artifactID: "future-vendor-artifact",
      version: "9.0.0",
      sha256: String(repeating: "b", count: 64),
      runtimeID: InferenceRuntimeID("future.runtime"),
      capabilities: [InferenceCapability("vendor.future.capability")],
      minimumOS: InferenceOSVersion(major: 14, minor: 2),
      supportedArchitectures: ["arm64"],
      minimumUnifiedMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
      licenseIdentifier: "LicenseRef-Future",
      networkRequired: false,
      metadata: ["opaqueFeature": "preserved"]
    )
    let roundTripped = try JSONDecoder().decode(
      ModelArtifactDescriptor.self,
      from: JSONEncoder().encode(unknown)
    )
    XCTAssertEqual(roundTripped, unknown)

    try await registry.register(known)
    try await registry.register(roundTripped)
    let environment = InferenceRuntimeEnvironment(
      osVersion: InferenceOSVersion(major: 14, minor: 2),
      architecture: "arm64",
      unifiedMemoryBytes: 16 * 1_024 * 1_024 * 1_024
    )
    let knownMatches = await registry.compatibleArtifacts(
      for: CapabilityRequirement(capabilities: [.asrBatch]),
      environment: environment
    )
    let futureMatches = await registry.compatibleArtifacts(
      for: CapabilityRequirement(
        capabilities: [InferenceCapability("vendor.future.capability")]
      ),
      environment: environment
    )

    XCTAssertEqual(knownMatches.map(\.artifactID), ["known"])
    XCTAssertEqual(futureMatches.map(\.artifactID), ["future-vendor-artifact"])
    let preserved = await registry.artifact(id: "future-vendor-artifact")
    XCTAssertEqual(preserved?.metadata["opaqueFeature"], "preserved")
  }

  private func artifact(id: String) -> ModelArtifactDescriptor {
    ModelArtifactDescriptor(
      artifactID: id,
      version: "1.0.0",
      sha256: String(repeating: "a", count: 64),
      runtimeID: InferenceRuntimeID("fixture.runtime"),
      capabilities: [
        .asrBatch,
        .diarizationBatch,
        .localTextStructured,
        .speakerEmbedding,
      ],
      minimumOS: InferenceOSVersion(major: 14, minor: 2),
      supportedArchitectures: ["arm64"],
      minimumUnifiedMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
      licenseIdentifier: "LicenseRef-Fixture",
      networkRequired: false
    )
  }

  private func asrRequest(
    artifactID: String,
    contractVersion: Int = InferenceContract.currentVersion
  ) -> ASRRequest {
    ASRRequest(
      metadata: InferenceRequestMetadata(
        contractVersion: contractVersion,
        jobID: UUID(),
        inputRevision: 1,
        modelArtifactID: artifactID,
        configHash: String(repeating: "c", count: 64)
      ),
      audio: AudioRangeInput(
        sourceID: UUID(),
        trackID: UUID(),
        assetReference: "sessions/fixture/chunk.pcm",
        contentDigest: String(repeating: "d", count: 64),
        monotonicStartNanoseconds: 0,
        monotonicEndNanoseconds: 1_000_000_000,
        sampleRateHertz: 16_000,
        channelCount: 1
      ),
      mode: .final,
      languageHints: ["zh-CN", "en-US"]
    )
  }
}

private struct FakeUnifiedEngine: ASREngine, DiarizationEngine,
  SpeakerEmbeddingEngine, LocalTextEngine
{
  let artifact: ModelArtifactDescriptor
  let label: String

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try validate(request.metadata)
    return ASRResult(
      modelArtifactID: artifact.artifactID,
      segments: [
        ASRSegment(
          segmentID: UUID(),
          monotonicStartNanoseconds: request.audio.monotonicStartNanoseconds,
          monotonicEndNanoseconds: request.audio.monotonicEndNanoseconds,
          text: label,
          confidence: 1
        )
      ]
    )
  }

  func diarize(_ request: DiarizationRequest) async throws -> DiarizationResult {
    try validate(request.metadata)
    guard let audio = request.audio.first else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "fixture-empty-audio",
        retryable: false
      )
    }
    return DiarizationResult(
      modelArtifactID: artifact.artifactID,
      turns: [
        DiarizationTurn(
          turnID: UUID(),
          speakerClusterID: "speaker-0",
          monotonicStartNanoseconds: audio.monotonicStartNanoseconds,
          monotonicEndNanoseconds: audio.monotonicEndNanoseconds,
          confidence: 1,
          overlapsAnotherSpeaker: false
        )
      ]
    )
  }

  func embed(_ request: SpeakerEmbeddingRequest) async throws
    -> SpeakerEmbeddingResult
  {
    try validate(request.metadata)
    return SpeakerEmbeddingResult(
      modelArtifactID: artifact.artifactID,
      embeddingSpaceID: request.embeddingSpaceID,
      vector: [0.25, 0.75]
    )
  }

  func generate(_ request: LocalTextRequest) async throws -> LocalTextResult {
    try validate(request.metadata)
    return LocalTextResult(
      modelArtifactID: artifact.artifactID,
      taskID: request.taskID,
      outputText: label,
      claims: []
    )
  }

  private func validate(_ metadata: InferenceRequestMetadata) throws {
    guard metadata.contractVersion == InferenceContract.currentVersion else {
      throw InferenceEngineError(
        category: .unsupportedContractVersion,
        code: "fixture-version",
        retryable: false
      )
    }
    guard metadata.modelArtifactID == artifact.artifactID else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "fixture-artifact",
        retryable: false
      )
    }
  }
}

private struct FailingASREngine: ASREngine {
  let artifact: ModelArtifactDescriptor

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    throw InferenceEngineError(
      category: .modelUnavailable,
      code: "fixture-unavailable",
      retryable: true
    )
  }
}

private struct CancellableASREngine: ASREngine {
  let artifact: ModelArtifactDescriptor

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    while true {
      try InferenceCancellation.check()
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      }
    }
  }
}
