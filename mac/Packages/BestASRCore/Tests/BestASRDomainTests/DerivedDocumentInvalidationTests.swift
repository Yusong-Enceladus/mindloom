import Foundation
import XCTest

@testable import BestASRDomain

final class DerivedDocumentInvalidationTests: XCTestCase {
  func testFreshLineageKeepsDerivedDocumentCurrent() throws {
    let fixture = try makeFixture()

    let evaluation = DerivedDocumentPolicy.evaluate(
      fixture.document,
      against: fixture.lineage
    )

    XCTAssertEqual(evaluation.status, .current)
    XCTAssertTrue(evaluation.invalidationReasons.isEmpty)
    XCTAssertNil(evaluation.regenerationRequest)
  }

  func testEachLineageDimensionInvalidatesAndRegeneratesWithoutSourceMutation()
    throws
  {
    let fixture = try makeFixture()
    let sourceBefore = fixture.source
    let documentBefore = fixture.document
    let nextRevision = try Revision(2)
    let cases: [(DerivedDocumentLineage, DerivedDocumentInvalidationReason)] = [
      (
        DerivedDocumentLineage(
          input: DerivedDocumentInput(
            entity: fixture.lineage.input.entity,
            revision: nextRevision
          ),
          modelArtifactID: fixture.lineage.modelArtifactID,
          configHash: fixture.lineage.configHash
        ),
        .inputRevisionChanged
      ),
      (
        DerivedDocumentLineage(
          input: fixture.lineage.input,
          modelArtifactID: ModelArtifactID(uuid(30)),
          configHash: fixture.lineage.configHash
        ),
        .modelArtifactChanged
      ),
      (
        DerivedDocumentLineage(
          input: fixture.lineage.input,
          modelArtifactID: fixture.lineage.modelArtifactID,
          configHash: try digest(31)
        ),
        .configChanged
      ),
    ]

    for (index, testCase) in cases.enumerated() {
      let evaluation = DerivedDocumentPolicy.evaluate(
        fixture.document,
        against: testCase.0
      )
      XCTAssertEqual(evaluation.status, .stale)
      XCTAssertEqual(evaluation.invalidationReasons, [testCase.1])

      let request = try XCTUnwrap(evaluation.regenerationRequest)
      let regenerated = DerivedDocumentPolicy.regenerate(
        from: request,
        id: DerivedDocumentID(uuid(UInt64(40 + index))),
        revision: nextRevision,
        contentDigest: try digest(UInt64(50 + index)),
        createdAt: fixedDate.addingTimeInterval(TimeInterval(index + 1))
      )

      XCTAssertEqual(regenerated.lineage, testCase.0)
      XCTAssertEqual(regenerated.kind, fixture.document.kind)
      XCTAssertNotEqual(regenerated.id, fixture.document.id)
      XCTAssertEqual(fixture.source, sourceBefore)
      XCTAssertEqual(fixture.source.revision, sourceBefore.revision)
      XCTAssertEqual(fixture.document, documentBefore)
    }
  }

  func testCombinedChangesReportStableReasonOrder() throws {
    let fixture = try makeFixture()
    let changed = DerivedDocumentLineage(
      input: DerivedDocumentInput(
        entity: fixture.lineage.input.entity,
        revision: try Revision(2)
      ),
      modelArtifactID: ModelArtifactID(uuid(30)),
      configHash: try digest(31)
    )

    let evaluation = DerivedDocumentPolicy.evaluate(
      fixture.document,
      against: changed
    )

    XCTAssertEqual(
      evaluation.invalidationReasons,
      [.inputRevisionChanged, .modelArtifactChanged, .configChanged]
    )
  }

  func testLineageAndEvaluationCodableRoundTrip() throws {
    let fixture = try makeFixture()
    let changed = DerivedDocumentLineage(
      input: fixture.lineage.input,
      modelArtifactID: ModelArtifactID(uuid(30)),
      configHash: fixture.lineage.configHash
    )
    let evaluation = DerivedDocumentPolicy.evaluate(
      fixture.document,
      against: changed
    )

    let encodedDocument = try JSONEncoder().encode(fixture.document)
    XCTAssertEqual(
      try JSONDecoder().decode(DerivedDocument.self, from: encodedDocument),
      fixture.document
    )
    let encodedEvaluation = try JSONEncoder().encode(evaluation)
    XCTAssertEqual(
      try JSONDecoder().decode(
        DerivedDocumentEvaluation.self,
        from: encodedEvaluation
      ),
      evaluation
    )
  }

  private func makeFixture() throws -> Fixture {
    let revision = try Revision(1)
    let source = TranscriptRevision(
      id: TranscriptRevisionID(uuid(1)),
      sessionID: SessionID(uuid(2)),
      revision: revision,
      parentID: nil,
      kind: .userEdit,
      content: "synthetic source",
      modelArtifactID: nil,
      configHash: nil,
      createdAt: fixedDate
    )
    let lineage = DerivedDocumentLineage(
      input: DerivedDocumentInput(
        entity: DomainEntityReference(
          kind: .transcriptRevision,
          stableID: source.id.rawValue
        ),
        revision: source.revision
      ),
      modelArtifactID: ModelArtifactID(uuid(3)),
      configHash: try digest(4)
    )
    let document = DerivedDocument(
      id: DerivedDocumentID(uuid(5)),
      revision: revision,
      kind: .summary,
      lineage: lineage,
      contentDigest: try digest(6),
      createdAt: fixedDate
    )
    return Fixture(source: source, lineage: lineage, document: document)
  }

  private func digest(_ value: UInt64) throws -> SHA256Digest {
    try SHA256Digest(String(format: "%064llx", value))
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-4000-8000-%012llx",
        value
      )
    )!
  }

  private var fixedDate: Date {
    Date(timeIntervalSince1970: 1_753_286_400)
  }

  private struct Fixture {
    let source: TranscriptRevision
    let lineage: DerivedDocumentLineage
    let document: DerivedDocument
  }
}
