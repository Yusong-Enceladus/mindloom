import Foundation

public enum DerivedDocumentKind: String, Codable, CaseIterable, Sendable {
  case actionItems
  case asrTranscript
  case polishedTranscript
  case summary
}

public struct DerivedDocumentInput: Codable, Equatable, Sendable {
  public let entity: DomainEntityReference
  public let revision: Revision

  public init(entity: DomainEntityReference, revision: Revision) {
    self.entity = entity
    self.revision = revision
  }
}

public struct DerivedDocumentLineage: Codable, Equatable, Sendable {
  public let input: DerivedDocumentInput
  public let modelArtifactID: ModelArtifactID
  public let configHash: SHA256Digest

  public init(
    input: DerivedDocumentInput,
    modelArtifactID: ModelArtifactID,
    configHash: SHA256Digest
  ) {
    self.input = input
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
  }
}

public struct DerivedDocument: Codable, Equatable, Sendable {
  public let id: DerivedDocumentID
  public let revision: Revision
  public let kind: DerivedDocumentKind
  public let lineage: DerivedDocumentLineage
  public let contentDigest: SHA256Digest
  public let createdAt: Date

  public init(
    id: DerivedDocumentID,
    revision: Revision,
    kind: DerivedDocumentKind,
    lineage: DerivedDocumentLineage,
    contentDigest: SHA256Digest,
    createdAt: Date
  ) {
    self.id = id
    self.revision = revision
    self.kind = kind
    self.lineage = lineage
    self.contentDigest = contentDigest
    self.createdAt = createdAt
  }
}

public enum DerivedDocumentInvalidationReason: String, Codable, Sendable {
  case configChanged
  case inputRevisionChanged
  case modelArtifactChanged
}

public enum DerivedDocumentReadStatus: String, Codable, Sendable {
  case current
  case stale
}

public struct DerivedDocumentRegenerationRequest: Codable, Equatable, Sendable {
  public let replacesDocumentID: DerivedDocumentID
  public let kind: DerivedDocumentKind
  public let lineage: DerivedDocumentLineage

  public init(
    replacesDocumentID: DerivedDocumentID,
    kind: DerivedDocumentKind,
    lineage: DerivedDocumentLineage
  ) {
    self.replacesDocumentID = replacesDocumentID
    self.kind = kind
    self.lineage = lineage
  }
}

public struct DerivedDocumentEvaluation: Codable, Equatable, Sendable {
  public let status: DerivedDocumentReadStatus
  public let invalidationReasons: [DerivedDocumentInvalidationReason]
  public let regenerationRequest: DerivedDocumentRegenerationRequest?

  public init(
    status: DerivedDocumentReadStatus,
    invalidationReasons: [DerivedDocumentInvalidationReason],
    regenerationRequest: DerivedDocumentRegenerationRequest?
  ) {
    self.status = status
    self.invalidationReasons = invalidationReasons
    self.regenerationRequest = regenerationRequest
  }
}

public enum DerivedDocumentPolicy {
  public static func evaluate(
    _ document: DerivedDocument,
    against expectedLineage: DerivedDocumentLineage
  ) -> DerivedDocumentEvaluation {
    var reasons: [DerivedDocumentInvalidationReason] = []
    if document.lineage.input != expectedLineage.input {
      reasons.append(.inputRevisionChanged)
    }
    if document.lineage.modelArtifactID != expectedLineage.modelArtifactID {
      reasons.append(.modelArtifactChanged)
    }
    if document.lineage.configHash != expectedLineage.configHash {
      reasons.append(.configChanged)
    }

    guard !reasons.isEmpty else {
      return DerivedDocumentEvaluation(
        status: .current,
        invalidationReasons: [],
        regenerationRequest: nil
      )
    }
    return DerivedDocumentEvaluation(
      status: .stale,
      invalidationReasons: reasons,
      regenerationRequest: DerivedDocumentRegenerationRequest(
        replacesDocumentID: document.id,
        kind: document.kind,
        lineage: expectedLineage
      )
    )
  }

  public static func regenerate(
    from request: DerivedDocumentRegenerationRequest,
    id: DerivedDocumentID,
    revision: Revision,
    contentDigest: SHA256Digest,
    createdAt: Date
  ) -> DerivedDocument {
    DerivedDocument(
      id: id,
      revision: revision,
      kind: request.kind,
      lineage: request.lineage,
      contentDigest: contentDigest,
      createdAt: createdAt
    )
  }
}
