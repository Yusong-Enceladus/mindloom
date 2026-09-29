import BestASRInference
import Foundation

public enum LocalTextRuntimeNetworkPolicy: String, Codable, Sendable {
  case implicitNetworkAllowed = "implicit-network-allowed"
  case modelManagerVerifiedArtifactOnly = "model-manager-verified-artifact-only"
}

public struct LocalTextRuntimeOutput: Codable, Equatable, Sendable {
  public let outputText: String
  public let claims: [LocalTextClaim]
  public let structuredItems: [LocalTextStructuredItem]

  public init(
    outputText: String,
    claims: [LocalTextClaim],
    structuredItems: [LocalTextStructuredItem]
  ) {
    self.outputText = outputText
    self.claims = claims
    self.structuredItems = structuredItems
  }
}

public protocol LocalTextCandidateRuntime: Sendable {
  func networkPolicy() async -> LocalTextRuntimeNetworkPolicy
  func generate(_ request: LocalTextRequest) async throws -> LocalTextRuntimeOutput
}

public struct LocalTextAdapterPolicy: Codable, Equatable, Sendable {
  public let minimumSupportedClaimConfidence: Double

  public init(minimumSupportedClaimConfidence: Double = 0.75) {
    self.minimumSupportedClaimConfidence = minimumSupportedClaimConfidence
  }
}

public struct VersionedLocalTextAdapter: LocalTextEngine {
  private let artifact: ModelArtifactDescriptor
  private let runtime: any LocalTextCandidateRuntime
  private let policy: LocalTextAdapterPolicy

  public init(
    artifact: ModelArtifactDescriptor,
    runtime: any LocalTextCandidateRuntime,
    policy: LocalTextAdapterPolicy = LocalTextAdapterPolicy()
  ) {
    self.artifact = artifact
    self.runtime = runtime
    self.policy = policy
  }

  public func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  public func generate(_ request: LocalTextRequest) async throws -> LocalTextResult {
    try InferenceCancellation.check()
    guard request.metadata.contractVersion == InferenceContract.currentVersion else {
      throw failure(
        .unsupportedContractVersion,
        code: "local-text-contract-version",
        retryable: false
      )
    }
    guard request.metadata.modelArtifactID == artifact.artifactID else {
      throw failure(
        .incompatibleArtifact,
        code: "local-text-artifact-id",
        retryable: false
      )
    }
    guard artifact.capabilities.contains(.localTextStructured) else {
      throw failure(
        .incompatibleArtifact,
        code: "local-text-capability",
        retryable: false
      )
    }
    guard !artifact.networkRequired,
      await runtime.networkPolicy() == .modelManagerVerifiedArtifactOnly
    else {
      throw failure(
        .modelUnavailable,
        code: "local-text-network-disallowed",
        retryable: false
      )
    }
    guard
      !request.sourceText.isEmpty,
      !request.sourceSegmentIDs.isEmpty,
      isSHA256(request.metadata.configHash)
    else {
      throw failure(
        .invalidRequest,
        code: "local-text-source-input",
        retryable: false
      )
    }

    let output = try await runtime.generate(request)
    try InferenceCancellation.check()
    try validate(output, request: request)
    return LocalTextResult(
      modelArtifactID: artifact.artifactID,
      taskID: request.taskID,
      outputText: output.outputText,
      claims: output.claims,
      structuredItems: output.structuredItems
    )
  }

  private func validate(
    _ output: LocalTextRuntimeOutput,
    request: LocalTextRequest
  ) throws {
    guard !output.outputText.isEmpty else {
      throw failure(
        .invalidRequest,
        code: "local-text-empty-output",
        retryable: false
      )
    }
    let allowedSegmentIDs = Set(request.sourceSegmentIDs)
    for claim in output.claims {
      guard
        !claim.text.isEmpty,
        !claim.sourceSegmentIDs.isEmpty,
        Set(claim.sourceSegmentIDs).isSubset(of: allowedSegmentIDs),
        isValidConfidence(claim.confidence),
        isSafeDisposition(
          confidence: claim.confidence,
          disposition: claim.disposition
        )
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-invalid-claim",
          retryable: false
        )
      }
    }
    for item in output.structuredItems {
      guard
        !item.text.isEmpty,
        !item.sourceSegmentIDs.isEmpty,
        Set(item.sourceSegmentIDs).isSubset(of: allowedSegmentIDs),
        item.confidence.isFinite,
        (0...1).contains(item.confidence),
        isSafeDisposition(
          confidence: item.confidence,
          disposition: item.disposition
        )
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-invalid-structured-item",
          retryable: false
        )
      }
    }

    switch request.taskID {
    case .rewrite:
      guard output.structuredItems.isEmpty else {
        throw failure(
          .invalidRequest,
          code: "local-text-rewrite-shape",
          retryable: false
        )
      }
    case .structuredSummary:
      guard
        !output.structuredItems.isEmpty,
        output.structuredItems.allSatisfy({ $0.kind == .summaryPoint })
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-summary-shape",
          retryable: false
        )
      }
    case .actionItems:
      guard
        !output.structuredItems.isEmpty,
        output.structuredItems.allSatisfy({ $0.kind == .actionItem })
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-action-shape",
          retryable: false
        )
      }
    case .chapters:
      guard
        !output.structuredItems.isEmpty,
        output.structuredItems.allSatisfy({ $0.kind == .chapter })
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-chapter-shape",
          retryable: false
        )
      }
    case .decisions:
      guard
        !output.structuredItems.isEmpty,
        output.structuredItems.allSatisfy({ $0.kind == .decision })
      else {
        throw failure(
          .invalidRequest,
          code: "local-text-decision-shape",
          retryable: false
        )
      }
    default:
      throw failure(
        .invalidRequest,
        code: "local-text-task-unsupported",
        retryable: false
      )
    }
  }

  private func isValidConfidence(_ confidence: Double?) -> Bool {
    guard let confidence else { return true }
    return confidence.isFinite && (0...1).contains(confidence)
  }

  private func isSafeDisposition(
    confidence: Double?,
    disposition: LocalTextClaimDisposition
  ) -> Bool {
    guard let confidence else { return disposition == .supported }
    return confidence >= policy.minimumSupportedClaimConfidence
      || disposition == .cautious
  }

  private func isSafeDisposition(
    confidence: Double,
    disposition: LocalTextClaimDisposition
  ) -> Bool {
    confidence >= policy.minimumSupportedClaimConfidence
      || disposition == .cautious
  }

  private func isSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
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
