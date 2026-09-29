import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation

public struct LocalTextDerivationCommand: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let sourceTranscript: TranscriptRevision
  public let sourceSegmentIDs: [UUID]
  public let taskID: LocalTextTaskID
  public let modelArtifact: ModelArtifact
  public let configHash: BestASRDomain.SHA256Digest
  public let derivedDocumentID: DerivedDocumentID
  public let derivedRevision: Revision
  public let createdAt: Date

  public init(
    jobID: UUID,
    sourceTranscript: TranscriptRevision,
    sourceSegmentIDs: [UUID],
    taskID: LocalTextTaskID,
    modelArtifact: ModelArtifact,
    configHash: BestASRDomain.SHA256Digest,
    derivedDocumentID: DerivedDocumentID,
    derivedRevision: Revision,
    createdAt: Date
  ) {
    self.jobID = jobID
    self.sourceTranscript = sourceTranscript
    self.sourceSegmentIDs = sourceSegmentIDs
    self.taskID = taskID
    self.modelArtifact = modelArtifact
    self.configHash = configHash
    self.derivedDocumentID = derivedDocumentID
    self.derivedRevision = derivedRevision
    self.createdAt = createdAt
  }
}

public struct LocalTextDualOutput: Codable, Equatable, Sendable {
  public let sourceTranscript: TranscriptRevision
  public let sourceSegmentIDs: [UUID]
  public let derivedDocument: DerivedDocument
  public let generated: LocalTextResult

  public init(
    sourceTranscript: TranscriptRevision,
    sourceSegmentIDs: [UUID],
    derivedDocument: DerivedDocument,
    generated: LocalTextResult
  ) {
    self.sourceTranscript = sourceTranscript
    self.sourceSegmentIDs = sourceSegmentIDs
    self.derivedDocument = derivedDocument
    self.generated = generated
  }
}

public struct LocalTextStructuredFailure: Codable, Equatable, Sendable {
  public let sourceTranscriptID: TranscriptRevisionID
  public let sourceRevision: Revision
  public let taskID: LocalTextTaskID
  public let failure: InferenceEngineError

  public init(
    sourceTranscriptID: TranscriptRevisionID,
    sourceRevision: Revision,
    taskID: LocalTextTaskID,
    failure: InferenceEngineError
  ) {
    self.sourceTranscriptID = sourceTranscriptID
    self.sourceRevision = sourceRevision
    self.taskID = taskID
    self.failure = failure
  }
}

public enum LocalTextDerivationOutcome: Codable, Equatable, Sendable {
  case failure(LocalTextStructuredFailure)
  case success(LocalTextDualOutput)
}

public enum LocalTextDerivationCoordinator {
  public static func attempt(
    _ command: LocalTextDerivationCommand,
    engine: any LocalTextEngine
  ) async -> LocalTextDerivationOutcome {
    let descriptor = await engine.descriptor()
    guard descriptor.artifact.artifactID == command.modelArtifact.registryKey else {
      return failure(
        command,
        category: .incompatibleArtifact,
        code: "local-text-domain-artifact-mismatch",
        retryable: false
      )
    }
    guard let kind = documentKind(for: command.taskID) else {
      return failure(
        command,
        category: .invalidRequest,
        code: "local-text-task-unsupported",
        retryable: false
      )
    }

    let request = LocalTextRequest(
      metadata: InferenceRequestMetadata(
        jobID: command.jobID,
        inputRevision: command.sourceTranscript.revision.value,
        modelArtifactID: descriptor.artifact.artifactID,
        configHash: command.configHash.value
      ),
      taskID: command.taskID,
      transcriptRevisionID: command.sourceTranscript.id.rawValue,
      sourceSegmentIDs: command.sourceSegmentIDs,
      sourceText: command.sourceTranscript.content
    )
    do {
      let generated = try await engine.generate(request)
      let lineage = DerivedDocumentLineage(
        input: DerivedDocumentInput(
          entity: DomainEntityReference(
            kind: .transcriptRevision,
            stableID: command.sourceTranscript.id.rawValue
          ),
          revision: command.sourceTranscript.revision
        ),
        modelArtifactID: command.modelArtifact.id,
        configHash: command.configHash
      )
      let document = DerivedDocument(
        id: command.derivedDocumentID,
        revision: command.derivedRevision,
        kind: kind,
        lineage: lineage,
        contentDigest: try digest(generated),
        createdAt: command.createdAt
      )
      return .success(
        LocalTextDualOutput(
          sourceTranscript: command.sourceTranscript,
          sourceSegmentIDs: command.sourceSegmentIDs,
          derivedDocument: document,
          generated: generated
        )
      )
    } catch let error as InferenceEngineError {
      return .failure(
        LocalTextStructuredFailure(
          sourceTranscriptID: command.sourceTranscript.id,
          sourceRevision: command.sourceTranscript.revision,
          taskID: command.taskID,
          failure: error
        )
      )
    } catch {
      return failure(
        command,
        category: .transientRuntime,
        code: "local-text-untyped-runtime-error",
        retryable: true
      )
    }
  }

  private static func documentKind(
    for taskID: LocalTextTaskID
  ) -> DerivedDocumentKind? {
    switch taskID {
    case .actionItems:
      return .actionItems
    case .rewrite:
      return .polishedTranscript
    case .structuredSummary:
      return .summary
    default:
      return nil
    }
  }

  private static func digest(
    _ result: LocalTextResult
  ) throws -> BestASRDomain.SHA256Digest {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(result)
    let value = SHA256.hash(data: bytes).map {
      String(format: "%02x", $0)
    }.joined()
    return try BestASRDomain.SHA256Digest(value)
  }

  private static func failure(
    _ command: LocalTextDerivationCommand,
    category: InferenceFailureCategory,
    code: String,
    retryable: Bool
  ) -> LocalTextDerivationOutcome {
    .failure(
      LocalTextStructuredFailure(
        sourceTranscriptID: command.sourceTranscript.id,
        sourceRevision: command.sourceTranscript.revision,
        taskID: command.taskID,
        failure: InferenceEngineError(
          category: category,
          code: code,
          retryable: retryable
        )
      )
    )
  }
}
