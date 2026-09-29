import BestASRDomain
import BestASRInference
import Foundation
import XCTest

@testable import BestASRLocalText

final class LocalTextAdapterTests: XCTestCase {
  func testRewriteSummaryAndActionItemsProduceSeparateVersionedOutputs() async throws {
    let fixture = try loadFixture()
    let source = try makeSource(fixture)
    let sourceBefore = source
    let runtime = FixtureLocalTextRuntime(fixture: fixture)
    let adapter = VersionedLocalTextAdapter(
      artifact: inferenceArtifact,
      runtime: runtime
    )
    let tasks: [(LocalTextTaskID, DerivedDocumentKind)] = [
      (.rewrite, .polishedTranscript),
      (.structuredSummary, .summary),
      (.actionItems, .actionItems),
    ]

    for (index, task) in tasks.enumerated() {
      let outcome = await LocalTextDerivationCoordinator.attempt(
        try command(
          source: source,
          fixture: fixture,
          taskID: task.0,
          documentID: DerivedDocumentID(uuid(UInt64(200 + index)))
        ),
        engine: adapter
      )
      let output = try unwrapSuccess(outcome)

      XCTAssertEqual(output.sourceTranscript, source)
      XCTAssertEqual(output.derivedDocument.kind, task.1)
      XCTAssertEqual(
        output.derivedDocument.lineage.input.entity,
        DomainEntityReference(
          kind: .transcriptRevision,
          stableID: source.id.rawValue
        )
      )
      XCTAssertEqual(
        output.derivedDocument.lineage.input.revision,
        source.revision
      )
      XCTAssertEqual(
        output.derivedDocument.lineage.modelArtifactID,
        try domainArtifact.id
      )
      XCTAssertEqual(output.derivedDocument.lineage.configHash, try digest(9))
      XCTAssertEqual(output.generated.taskID, task.0)
      XCTAssertTrue(
        output.generated.claims.allSatisfy {
          !$0.sourceSegmentIDs.isEmpty
            && Set($0.sourceSegmentIDs).isSubset(of: Set(fixture.sourceSegmentIDs))
        }
      )
      XCTAssertTrue(
        output.generated.structuredItems.allSatisfy {
          !$0.sourceSegmentIDs.isEmpty
            && Set($0.sourceSegmentIDs).isSubset(of: Set(fixture.sourceSegmentIDs))
        }
      )
    }
    XCTAssertEqual(source, sourceBefore)
  }

  func testRegenerationIsDeterministicAndNeverOverwritesSourceOrPriorOutput() async throws {
    let fixture = try loadFixture()
    let source = try makeSource(fixture)
    let sourceBefore = source
    let adapter = VersionedLocalTextAdapter(
      artifact: inferenceArtifact,
      runtime: FixtureLocalTextRuntime(fixture: fixture)
    )
    let firstOutcome = await LocalTextDerivationCoordinator.attempt(
      try command(
        source: source,
        fixture: fixture,
        taskID: .rewrite,
        documentID: DerivedDocumentID(uuid(300))
      ),
      engine: adapter
    )
    let secondOutcome = await LocalTextDerivationCoordinator.attempt(
      try command(
        source: source,
        fixture: fixture,
        taskID: .rewrite,
        documentID: DerivedDocumentID(uuid(301))
      ),
      engine: adapter
    )
    let first = try unwrapSuccess(firstOutcome)
    let second = try unwrapSuccess(secondOutcome)

    XCTAssertNotEqual(first.derivedDocument.id, second.derivedDocument.id)
    XCTAssertEqual(first.derivedDocument.lineage, second.derivedDocument.lineage)
    XCTAssertEqual(
      first.derivedDocument.contentDigest,
      second.derivedDocument.contentDigest
    )
    XCTAssertEqual(first.generated, second.generated)
    XCTAssertEqual(first.sourceTranscript, sourceBefore)
    XCTAssertEqual(second.sourceTranscript, sourceBefore)
    XCTAssertEqual(source, sourceBefore)
  }

  func testLowConfidenceMustBeCautiousAndUnknownReferencesFailClosed() async throws {
    let fixture = try loadFixture()
    let source = try makeSource(fixture)
    let sourceBefore = source
    let unsafeClaim = LocalTextClaim(
      claimID: uuid(400),
      text: "unsupported certainty",
      sourceSegmentIDs: [fixture.sourceSegmentIDs[0]],
      confidence: 0.20,
      disposition: .supported
    )
    let unsafeAdapter = VersionedLocalTextAdapter(
      artifact: inferenceArtifact,
      runtime: FixedLocalTextRuntime(
        output: LocalTextRuntimeOutput(
          outputText: "unsafe",
          claims: [unsafeClaim],
          structuredItems: []
        )
      )
    )
    let unsafeOutcome = await LocalTextDerivationCoordinator.attempt(
      try command(
        source: source,
        fixture: fixture,
        taskID: .rewrite,
        documentID: DerivedDocumentID(uuid(401))
      ),
      engine: unsafeAdapter
    )
    let unsafeFailure = try unwrapFailure(unsafeOutcome)
    XCTAssertEqual(unsafeFailure.failure.category, .invalidRequest)
    XCTAssertEqual(unsafeFailure.failure.code, "local-text-invalid-claim")
    XCTAssertEqual(unsafeFailure.sourceTranscriptID, source.id)
    XCTAssertEqual(unsafeFailure.sourceRevision, source.revision)

    let unknownSegment = uuid(499)
    let unknownReferenceAdapter = VersionedLocalTextAdapter(
      artifact: inferenceArtifact,
      runtime: FixedLocalTextRuntime(
        output: LocalTextRuntimeOutput(
          outputText: "bad reference",
          claims: [
            LocalTextClaim(
              claimID: uuid(402),
              text: "bad reference",
              sourceSegmentIDs: [unknownSegment],
              confidence: 0.99
            )
          ],
          structuredItems: []
        )
      )
    )
    let referenceOutcome = await LocalTextDerivationCoordinator.attempt(
      try command(
        source: source,
        fixture: fixture,
        taskID: .rewrite,
        documentID: DerivedDocumentID(uuid(403))
      ),
      engine: unknownReferenceAdapter
    )
    XCTAssertEqual(
      try unwrapFailure(referenceOutcome).failure.code,
      "local-text-invalid-claim"
    )
    XCTAssertEqual(source, sourceBefore)
  }

  func testRuntimeFailureIsStructuredAndSourceAddressable() async throws {
    let fixture = try loadFixture()
    let source = try makeSource(fixture)
    let adapter = VersionedLocalTextAdapter(
      artifact: inferenceArtifact,
      runtime: FailingLocalTextRuntime()
    )
    let outcome = await LocalTextDerivationCoordinator.attempt(
      try command(
        source: source,
        fixture: fixture,
        taskID: .structuredSummary,
        documentID: DerivedDocumentID(uuid(500))
      ),
      engine: adapter
    )
    let failure = try unwrapFailure(outcome)

    XCTAssertEqual(failure.sourceTranscriptID, source.id)
    XCTAssertEqual(failure.sourceRevision, source.revision)
    XCTAssertEqual(failure.taskID, .structuredSummary)
    XCTAssertEqual(failure.failure.category, .modelUnavailable)
    XCTAssertEqual(failure.failure.code, "fixture-model-unavailable")
    XCTAssertTrue(failure.failure.retryable)
  }

  private func command(
    source: TranscriptRevision,
    fixture: LocalTextFixture,
    taskID: LocalTextTaskID,
    documentID: DerivedDocumentID
  ) throws -> LocalTextDerivationCommand {
    LocalTextDerivationCommand(
      jobID: uuid(600),
      sourceTranscript: source,
      sourceSegmentIDs: fixture.sourceSegmentIDs,
      taskID: taskID,
      modelArtifact: try domainArtifact,
      configHash: try digest(9),
      derivedDocumentID: documentID,
      derivedRevision: try Revision(1),
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func makeSource(_ fixture: LocalTextFixture) throws -> TranscriptRevision {
    TranscriptRevision(
      id: fixture.sourceTranscriptID,
      sessionID: fixture.sessionID,
      revision: try Revision(1),
      parentID: nil,
      kind: .final,
      content: fixture.sourceText,
      modelArtifactID: nil,
      configHash: nil,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func unwrapSuccess(
    _ outcome: LocalTextDerivationOutcome
  ) throws -> LocalTextDualOutput {
    guard case .success(let output) = outcome else {
      XCTFail("Expected successful dual output, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return output
  }

  private func unwrapFailure(
    _ outcome: LocalTextDerivationOutcome
  ) throws -> LocalTextStructuredFailure {
    guard case .failure(let failure) = outcome else {
      XCTFail("Expected structured failure, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return failure
  }

  private func loadFixture() throws -> LocalTextFixture {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/LocalText/contract-cases.json"
      )
    )
    let fixture = try JSONDecoder().decode(LocalTextFixture.self, from: data)
    XCTAssertEqual(fixture.schemaVersion, 1)
    XCTAssertEqual(fixture.kind, "local-text-contract-fixture")
    return fixture
  }

  private var inferenceArtifact: ModelArtifactDescriptor {
    ModelArtifactDescriptor(
      artifactID: "local-text-contract-fixture",
      version: "1.0.0",
      sha256: String(repeating: "a", count: 64),
      runtimeID: InferenceRuntimeID("fixture.local-text"),
      capabilities: [.localTextStructured],
      minimumOS: InferenceOSVersion(major: 14, minor: 2),
      supportedArchitectures: ["arm64"],
      minimumUnifiedMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
      licenseIdentifier: "LicenseRef-Fixture",
      networkRequired: false
    )
  }

  private var domainArtifact: ModelArtifact {
    get throws {
      ModelArtifact(
        id: ModelArtifactID(uuid(700)),
        revision: try Revision(1),
        registryKey: inferenceArtifact.artifactID,
        version: inferenceArtifact.version,
        capability: .localText,
        digest: try digest(10),
        directoryReference: try PortableAssetReference(
          relativePath: "models/local-text-contract-fixture"
        ),
        licenseIdentifier: inferenceArtifact.licenseIdentifier,
        state: .active
      )
    }
  }

  private func digest(_ value: UInt64) throws -> SHA256Digest {
    try SHA256Digest(String(format: "%064llx", value))
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private enum TestError: Error {
  case unexpectedOutcome
}

private struct LocalTextFixture: Codable, Sendable {
  let schemaVersion: Int
  let kind: String
  let sourceTranscriptID: TranscriptRevisionID
  let sessionID: SessionID
  let sourceText: String
  let sourceSegmentIDs: [UUID]
  let rewriteText: String
  let summaryText: String
  let actionText: String
  let actionOwner: String
}

private actor FixtureLocalTextRuntime: LocalTextCandidateRuntime {
  let fixture: LocalTextFixture

  init(fixture: LocalTextFixture) {
    self.fixture = fixture
  }

  func networkPolicy() -> LocalTextRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactOnly
  }

  func generate(_ request: LocalTextRequest) -> LocalTextRuntimeOutput {
    let segmentIDs = request.sourceSegmentIDs
    switch request.taskID {
    case .rewrite:
      return LocalTextRuntimeOutput(
        outputText: fixture.rewriteText,
        claims: [
          LocalTextClaim(
            claimID: Self.uuid(801),
            text: fixture.rewriteText,
            sourceSegmentIDs: segmentIDs,
            confidence: 0.99
          )
        ],
        structuredItems: []
      )
    case .structuredSummary:
      return LocalTextRuntimeOutput(
        outputText: fixture.summaryText,
        claims: [],
        structuredItems: [
          LocalTextStructuredItem(
            itemID: Self.uuid(802),
            kind: .summaryPoint,
            text: fixture.summaryText,
            owner: nil,
            sourceSegmentIDs: segmentIDs,
            confidence: 0.70,
            disposition: .cautious
          )
        ]
      )
    case .actionItems:
      return LocalTextRuntimeOutput(
        outputText: fixture.actionText,
        claims: [],
        structuredItems: [
          LocalTextStructuredItem(
            itemID: Self.uuid(803),
            kind: .actionItem,
            text: fixture.actionText,
            owner: fixture.actionOwner,
            sourceSegmentIDs: segmentIDs,
            confidence: 0.99,
            disposition: .supported
          )
        ]
      )
    default:
      return LocalTextRuntimeOutput(
        outputText: "unsupported",
        claims: [],
        structuredItems: []
      )
    }
  }

  private static func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }
}

private actor FixedLocalTextRuntime: LocalTextCandidateRuntime {
  let output: LocalTextRuntimeOutput

  init(output: LocalTextRuntimeOutput) {
    self.output = output
  }

  func networkPolicy() -> LocalTextRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactOnly
  }

  func generate(_ request: LocalTextRequest) -> LocalTextRuntimeOutput { output }
}

private actor FailingLocalTextRuntime: LocalTextCandidateRuntime {
  func networkPolicy() -> LocalTextRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactOnly
  }

  func generate(_ request: LocalTextRequest) throws -> LocalTextRuntimeOutput {
    throw InferenceEngineError(
      category: .modelUnavailable,
      code: "fixture-model-unavailable",
      retryable: true
    )
  }
}
