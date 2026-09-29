import BestASRInference
import Foundation

public struct CandidateRuntimeSegment: Codable, Equatable, Sendable {
  public let segmentID: UUID
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let text: String
  public let confidence: Double?

  public init(
    segmentID: UUID,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    text: String,
    confidence: Double?
  ) {
    self.segmentID = segmentID
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.text = text
    self.confidence = confidence
  }
}

public struct CandidateRuntimeOutput: Codable, Equatable, Sendable {
  public let revisionID: UUID
  public let segments: [CandidateRuntimeSegment]
  public let detectedLanguage: String?

  public init(
    revisionID: UUID,
    segments: [CandidateRuntimeSegment],
    detectedLanguage: String? = nil
  ) {
    self.revisionID = revisionID
    self.segments = segments
    self.detectedLanguage = detectedLanguage
  }
}

public protocol CandidateASRRuntime: Sendable {
  func networkPolicy() async -> CandidateRuntimeNetworkPolicy
  func transcribe(
    _ request: ASRRequest,
    candidateID: String
  ) async throws -> CandidateRuntimeOutput
}

public struct CandidateAdapterPolicy: Codable, Equatable, Sendable {
  public let maximumDictionaryTerms: Int
  public let maximumPriorSegments: Int

  public init(
    maximumDictionaryTerms: Int = 64,
    maximumPriorSegments: Int = 8
  ) {
    self.maximumDictionaryTerms = maximumDictionaryTerms
    self.maximumPriorSegments = maximumPriorSegments
  }
}

private struct CandidateAdapterCore: Sendable {
  let candidateID: String
  let capabilities: [String]
  let networkPolicy: CandidateRuntimeNetworkPolicy
  let runtime: any CandidateASRRuntime
  let policy: CandidateAdapterPolicy
  let artifact: ModelArtifactDescriptor

  func descriptor() -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try InferenceCancellation.check()
    guard request.metadata.contractVersion == InferenceContract.currentVersion else {
      throw failure(
        .unsupportedContractVersion,
        code: "candidate-contract-version",
        retryable: false
      )
    }
    guard request.metadata.modelArtifactID == artifact.artifactID else {
      throw failure(
        .incompatibleArtifact,
        code: "candidate-artifact-id",
        retryable: false
      )
    }
    guard
      request.audio.monotonicStartNanoseconds
        < request.audio.monotonicEndNanoseconds
    else {
      throw failure(
        .invalidRequest,
        code: "candidate-empty-audio-range",
        retryable: false
      )
    }
    guard await runtime.networkPolicy() == networkPolicy else {
      throw failure(
        .modelUnavailable,
        code: "candidate-implicit-network-disallowed",
        retryable: false
      )
    }

    let requiredCapability: InferenceCapability =
      request.mode == .streaming ? .asrStreaming : .asrBatch
    guard capabilities.contains(requiredCapability.rawValue) else {
      throw failure(
        .incompatibleArtifact,
        code: "candidate-mode-unsupported",
        retryable: false
      )
    }

    let boundedRequest = ASRRequest(
      metadata: request.metadata,
      audio: request.audio,
      mode: request.mode,
      languageHints: request.languageHints,
      recognitionContext: request.recognitionContext.bounded(
        maximumDictionaryTerms: policy.maximumDictionaryTerms,
        maximumPriorSegments: policy.maximumPriorSegments
      ),
      supersedesRevisionID: request.supersedesRevisionID
    )
    let output = try await runtime.transcribe(
      boundedRequest,
      candidateID: candidateID
    )
    try InferenceCancellation.check()
    try validate(output, for: boundedRequest)

    return ASRResult(
      modelArtifactID: artifact.artifactID,
      segments: output.segments.map {
        ASRSegment(
          segmentID: $0.segmentID,
          monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
          monotonicEndNanoseconds: $0.monotonicEndNanoseconds,
          text: $0.text,
          confidence: $0.confidence
        )
      },
      detectedLanguage: output.detectedLanguage,
      revision: ASRRevisionMetadata(
        revisionID: output.revisionID,
        supersedesRevisionID: boundedRequest.supersedesRevisionID,
        mode: boundedRequest.mode,
        monotonicStartNanoseconds: boundedRequest.audio.monotonicStartNanoseconds,
        monotonicEndNanoseconds: boundedRequest.audio.monotonicEndNanoseconds
      )
    )
  }

  private func validate(
    _ output: CandidateRuntimeOutput,
    for request: ASRRequest
  ) throws {
    if let detectedLanguage = output.detectedLanguage {
      guard
        !detectedLanguage.isEmpty,
        detectedLanguage.count <= 32,
        detectedLanguage.unicodeScalars.allSatisfy({ scalar in
          CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || scalar.value == 45
        })
      else {
        throw failure(
          .invalidRequest,
          code: "candidate-detected-language-invalid",
          retryable: false
        )
      }
    }
    var segmentIDs = Set<UUID>()
    var previousEnd = request.audio.monotonicStartNanoseconds
    for segment in output.segments {
      guard segmentIDs.insert(segment.segmentID).inserted else {
        throw failure(
          .invalidRequest,
          code: "candidate-duplicate-segment-id",
          retryable: false
        )
      }
      guard
        segment.monotonicStartNanoseconds >= previousEnd,
        segment.monotonicStartNanoseconds < segment.monotonicEndNanoseconds,
        segment.monotonicEndNanoseconds
          <= request.audio.monotonicEndNanoseconds
      else {
        throw failure(
          .invalidRequest,
          code: "candidate-segment-outside-audio-range",
          retryable: false
        )
      }
      previousEnd = segment.monotonicEndNanoseconds
    }
  }

  private func failure(
    _ category: InferenceFailureCategory,
    code: String,
    retryable: Bool
  ) -> InferenceEngineError {
    InferenceEngineError(
      category: category,
      code: code,
      retryable: retryable
    )
  }
}

public enum CandidateAdapterFactoryError: Error, Equatable, Sendable {
  case adapterKindMismatch(expected: String, actual: String)
}

public struct FluidSenseVoiceASRAdapter: ASREngine {
  private let core: CandidateAdapterCore

  public init(
    candidate: ASRCandidateRecord,
    runtime: any CandidateASRRuntime,
    policy: CandidateAdapterPolicy = CandidateAdapterPolicy(),
    artifact: ModelArtifactDescriptor? = nil
  ) throws {
    guard candidate.adapterKind == .fluidSenseVoice else {
      throw CandidateAdapterFactoryError.adapterKindMismatch(
        expected: CandidateAdapterKind.fluidSenseVoice.rawValue,
        actual: candidate.adapterKind.rawValue
      )
    }
    core = CandidateAdapterCore(
      candidateID: candidate.candidateID,
      capabilities: candidate.capabilities,
      networkPolicy: candidate.networkPolicy,
      runtime: runtime,
      policy: policy,
      artifact: artifact ?? candidate.modelArtifactDescriptor
    )
  }

  public func descriptor() async -> InferenceEngineDescriptor { core.descriptor() }
  public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try await core.transcribe(request)
  }
}

public struct WhisperKitASRAdapter: ASREngine {
  private let core: CandidateAdapterCore

  public init(
    candidate: ASRCandidateRecord,
    runtime: any CandidateASRRuntime,
    policy: CandidateAdapterPolicy = CandidateAdapterPolicy(),
    artifact: ModelArtifactDescriptor? = nil
  ) throws {
    guard candidate.adapterKind == .whisperKit else {
      throw CandidateAdapterFactoryError.adapterKindMismatch(
        expected: CandidateAdapterKind.whisperKit.rawValue,
        actual: candidate.adapterKind.rawValue
      )
    }
    core = CandidateAdapterCore(
      candidateID: candidate.candidateID,
      capabilities: candidate.capabilities,
      networkPolicy: candidate.networkPolicy,
      runtime: runtime,
      policy: policy,
      artifact: artifact ?? candidate.modelArtifactDescriptor
    )
  }

  public func descriptor() async -> InferenceEngineDescriptor { core.descriptor() }
  public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try await core.transcribe(request)
  }
}

public struct SherpaOnnxASRAdapter: ASREngine {
  private let core: CandidateAdapterCore

  public init(
    candidate: ASRCandidateRecord,
    runtime: any CandidateASRRuntime,
    policy: CandidateAdapterPolicy = CandidateAdapterPolicy(),
    artifact: ModelArtifactDescriptor? = nil
  ) throws {
    guard candidate.adapterKind == .sherpaOnnx else {
      throw CandidateAdapterFactoryError.adapterKindMismatch(
        expected: CandidateAdapterKind.sherpaOnnx.rawValue,
        actual: candidate.adapterKind.rawValue
      )
    }
    core = CandidateAdapterCore(
      candidateID: candidate.candidateID,
      capabilities: candidate.capabilities,
      networkPolicy: candidate.networkPolicy,
      runtime: runtime,
      policy: policy,
      artifact: artifact ?? candidate.modelArtifactDescriptor
    )
  }

  public func descriptor() async -> InferenceEngineDescriptor { core.descriptor() }
  public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try await core.transcribe(request)
  }
}

/// Production adapter for an exact, model-manager-verified local artifact
/// whose runtime has already passed the shared candidate boundary. This keeps
/// stage-specific ASR models behind the same contract checks without making
/// the user-facing product registry expose implementation model choices.
public struct PinnedOfflineASRAdapter: ASREngine {
  private let core: CandidateAdapterCore

  public init(
    candidateID: String,
    capabilities: [InferenceCapability],
    runtime: any CandidateASRRuntime,
    artifact: ModelArtifactDescriptor,
    policy: CandidateAdapterPolicy = CandidateAdapterPolicy()
  ) {
    core = CandidateAdapterCore(
      candidateID: candidateID,
      capabilities: capabilities.map(\.rawValue),
      networkPolicy: .modelManagerVerifiedArtifactsOnly,
      runtime: runtime,
      policy: policy,
      artifact: artifact
    )
  }

  public func descriptor() async -> InferenceEngineDescriptor {
    core.descriptor()
  }

  public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    try await core.transcribe(request)
  }
}

public enum CandidateAdapterFactory {
  public static func make(
    candidate: ASRCandidateRecord,
    runtime: any CandidateASRRuntime,
    policy: CandidateAdapterPolicy = CandidateAdapterPolicy(),
    artifact: ModelArtifactDescriptor? = nil
  ) throws -> any ASREngine {
    switch candidate.adapterKind {
    case .fluidSenseVoice:
      return try FluidSenseVoiceASRAdapter(
        candidate: candidate,
        runtime: runtime,
        policy: policy,
        artifact: artifact
      )
    case .sherpaOnnx:
      return try SherpaOnnxASRAdapter(
        candidate: candidate,
        runtime: runtime,
        policy: policy,
        artifact: artifact
      )
    case .whisperKit:
      return try WhisperKitASRAdapter(
        candidate: candidate,
        runtime: runtime,
        policy: policy,
        artifact: artifact
      )
    }
  }
}
