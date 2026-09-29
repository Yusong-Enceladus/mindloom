import BestASRDomain
import XCTest

@testable import BestASRMigrationProbe

final class PersonHistoryReducerTests: XCTestCase {
  func testOutOfOrderAndDuplicateReplayIsDeterministic() throws {
    let fixture = try makeFixture()
    let expected = try PersonHistoryReducer.reduce(
      changeLog: fixture.changes,
      tombstones: fixture.tombstones
    )

    for seed in UInt64(1)...64 {
      let changes = shuffled(
        fixture.changes + fixture.changes.filter { $0.revision.value.isMultiple(of: 2) },
        seed: seed
      )
      let tombstones = shuffled(
        fixture.tombstones + fixture.tombstones,
        seed: seed &+ 1_000
      )
      XCTAssertEqual(
        try PersonHistoryReducer.reduce(
          changeLog: changes,
          tombstones: tombstones
        ),
        expected,
        "non-deterministic replay for seed \(seed)"
      )
    }

    XCTAssertEqual(expected.decisionOrder.map(\.revision.value), Array(1...10))
    XCTAssertEqual(expected.appliedCorrectionIDs.count, 6)
    XCTAssertEqual(expected.ignoredAutomaticCorrectionIDs.count, 2)
  }

  func testMergeThenSplitPreservesTheExplicitUserDecision() throws {
    let fixture = try makeFixture()
    let state = try PersonHistoryReducer.reduce(
      changeLog: fixture.changes,
      tombstones: fixture.tombstones
    )

    XCTAssertEqual(
      state.occurrenceAssignments[fixture.occurrenceA]?.personID,
      fixture.personA
    )
    XCTAssertEqual(
      state.occurrenceAssignments[fixture.occurrenceB]?.personID,
      fixture.personB
    )
    XCTAssertEqual(
      state.occurrenceAssignments[fixture.occurrenceB]?.actor,
      .user
    )
    XCTAssertEqual(state.canonicalPersonID(for: fixture.personB), fixture.personB)
    XCTAssertNil(state.personMerges[fixture.personB])
  }

  func testAutomaticResultsCannotOverrideUserConfirmationOrName() throws {
    let fixture = try makeFixture()
    let state = try PersonHistoryReducer.reduce(
      changeLog: fixture.changes,
      tombstones: fixture.tombstones
    )

    XCTAssertEqual(
      state.occurrenceAssignments[fixture.occurrenceB]?.personID,
      fixture.personB
    )
    XCTAssertEqual(state.personNames[fixture.personA]?.displayName, "Alice")
    XCTAssertEqual(state.personNames[fixture.personA]?.actor, .user)
    XCTAssertTrue(
      state.ignoredAutomaticCorrectionIDs.contains(
        fixture.automaticOverwriteID
      )
    )
    XCTAssertTrue(
      state.ignoredAutomaticCorrectionIDs.contains(
        fixture.automaticRenameOverwriteID
      )
    )
  }

  func testMetadataTombstoneDoesNotAuthorizeSourceAudioDeletion() throws {
    let fixture = try makeFixture()
    let state = try PersonHistoryReducer.reduce(
      changeLog: fixture.changes,
      tombstones: fixture.tombstones
    )

    XCTAssertEqual(state.latestTombstones.count, 2)
    XCTAssertFalse(
      state.sourceAssetDeletionAuthorizations.contains(fixture.sessionEntity)
    )
    XCTAssertTrue(
      state.sourceAssetDeletionAuthorizations.contains(fixture.trackEntity)
    )
  }

  func testAutomaticMergeCannotRemapAUserConfirmedOccurrence() throws {
    let occurrenceID = SpeakerOccurrenceID(uuid(1))
    let personA = PersonID(uuid(2))
    let personB = PersonID(uuid(3))
    let userConfirm = try change(
      index: 1,
      actor: .user,
      payload: .confirm(occurrenceID: occurrenceID, personID: personA)
    )
    let automaticMerge = try change(
      index: 2,
      actor: .automatic,
      payload: .merge(primaryID: personB, mergedID: personA)
    )

    let state = try PersonHistoryReducer.reduce(
      changeLog: [automaticMerge.entry, userConfirm.entry],
      tombstones: []
    )

    XCTAssertEqual(
      state.occurrenceAssignments[occurrenceID]?.personID,
      personA
    )
    XCTAssertTrue(state.personMerges.isEmpty)
    XCTAssertTrue(
      state.ignoredAutomaticCorrectionIDs.contains(automaticMerge.operation.id)
    )
  }

  func testConflictingDuplicateChangeIsRejected() throws {
    let first = try change(
      index: 1,
      actor: .user,
      payload: .rename(personID: PersonID(uuid(1)), displayName: "Alice")
    )
    let conflictingOperation = PersonCorrectionOperation(
      id: first.operation.id,
      revision: first.operation.revision,
      occurredAt: first.operation.occurredAt,
      actor: .user,
      payload: .rename(personID: PersonID(uuid(1)), displayName: "Mallory"),
      reversesOperationID: nil
    )
    let conflictingEntry = ChangeLogEntry(
      id: first.entry.id,
      entity: first.entry.entity,
      revision: first.entry.revision,
      occurredAt: first.entry.occurredAt,
      originDeviceID: first.entry.originDeviceID,
      operation: .personCorrection,
      payloadDigest: first.entry.payloadDigest,
      personCorrection: conflictingOperation
    )

    XCTAssertThrowsError(
      try PersonHistoryReducer.reduce(
        changeLog: [first.entry, conflictingEntry],
        tombstones: []
      )
    ) { error in
      XCTAssertEqual(
        error as? PersonHistoryReducerError,
        .conflictingDuplicateChange(first.entry.id)
      )
    }
  }

  private func makeFixture() throws -> Fixture {
    let occurrenceA = SpeakerOccurrenceID(uuid(10))
    let occurrenceB = SpeakerOccurrenceID(uuid(11))
    let personA = PersonID(uuid(12))
    let personB = PersonID(uuid(13))

    let automaticConfirm = try change(
      index: 1,
      actor: .automatic,
      payload: .confirm(occurrenceID: occurrenceA, personID: personA)
    )
    let userConfirm = try change(
      index: 2,
      actor: .user,
      payload: .confirm(occurrenceID: occurrenceB, personID: personB)
    )
    let merge = try change(
      index: 3,
      actor: .user,
      payload: .merge(primaryID: personA, mergedID: personB)
    )
    let split = try change(
      index: 4,
      actor: .user,
      payload: .split(
        sourcePersonID: personA,
        newPersonID: personB,
        occurrenceIDs: [occurrenceB]
      )
    )
    let automaticOverwrite = try change(
      index: 5,
      actor: .automatic,
      payload: .confirm(occurrenceID: occurrenceB, personID: personA)
    )
    let automaticName = try change(
      index: 6,
      actor: .automatic,
      payload: .rename(personID: personA, displayName: "Auto Alice")
    )
    let userName = try change(
      index: 7,
      actor: .user,
      payload: .rename(personID: personA, displayName: "Alice")
    )
    let automaticRenameOverwrite = try change(
      index: 8,
      actor: .automatic,
      payload: .rename(personID: personA, displayName: "Machine Alice")
    )

    let sessionEntity = DomainEntityReference(
      kind: .session,
      stableID: uuid(20)
    )
    let trackEntity = DomainEntityReference(
      kind: .sourceTrack,
      stableID: uuid(21)
    )
    let metadataTombstone = Tombstone(
      id: TombstoneID(uuid(22)),
      entity: sessionEntity,
      revision: try Revision(9),
      deletedAt: date(9),
      deletionScope: .metadataOnly,
      changeID: ChangeID(uuid(209))
    )
    let explicitTrackDeletion = Tombstone(
      id: TombstoneID(uuid(23)),
      entity: trackEntity,
      revision: try Revision(10),
      deletedAt: date(10),
      deletionScope: .explicitSourceAssetDeletion,
      changeID: ChangeID(uuid(210))
    )

    return Fixture(
      changes: [
        automaticConfirm.entry,
        userConfirm.entry,
        merge.entry,
        split.entry,
        automaticOverwrite.entry,
        automaticName.entry,
        userName.entry,
        automaticRenameOverwrite.entry,
      ],
      tombstones: [metadataTombstone, explicitTrackDeletion],
      occurrenceA: occurrenceA,
      occurrenceB: occurrenceB,
      personA: personA,
      personB: personB,
      automaticOverwriteID: automaticOverwrite.operation.id,
      automaticRenameOverwriteID: automaticRenameOverwrite.operation.id,
      sessionEntity: sessionEntity,
      trackEntity: trackEntity
    )
  }

  private func change(
    index: UInt64,
    actor: PersonCorrectionActor,
    payload: PersonCorrectionPayload
  ) throws -> (entry: ChangeLogEntry, operation: PersonCorrectionOperation) {
    let revision = try Revision(index)
    let operation = PersonCorrectionOperation(
      id: PersonCorrectionID(uuid(100 + index)),
      revision: revision,
      occurredAt: date(index),
      actor: actor,
      payload: payload,
      reversesOperationID: nil
    )
    let entry = ChangeLogEntry(
      id: ChangeID(uuid(200 + index)),
      entity: DomainEntityReference(kind: .person, stableID: uuid(300 + index)),
      revision: revision,
      occurredAt: date(index),
      originDeviceID: uuid(400 + index),
      operation: .personCorrection,
      payloadDigest: try SHA256Digest(String(format: "%064llx", index)),
      personCorrection: operation
    )
    return (entry, operation)
  }

  private func shuffled<Element>(_ input: [Element], seed: UInt64) -> [Element] {
    var result = input
    var state = seed
    guard result.count > 1 else { return result }
    for index in stride(from: result.count - 1, through: 1, by: -1) {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let destination = Int(state % UInt64(index + 1))
      result.swapAt(index, destination)
    }
    return result
  }

  private func date(_ index: UInt64) -> Date {
    Date(timeIntervalSince1970: 1_753_286_400 + TimeInterval(index))
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-4000-8000-%012llx",
        value
      )
    )!
  }

  private struct Fixture {
    let changes: [ChangeLogEntry]
    let tombstones: [Tombstone]
    let occurrenceA: SpeakerOccurrenceID
    let occurrenceB: SpeakerOccurrenceID
    let personA: PersonID
    let personB: PersonID
    let automaticOverwriteID: PersonCorrectionID
    let automaticRenameOverwriteID: PersonCorrectionID
    let sessionEntity: DomainEntityReference
    let trackEntity: DomainEntityReference
  }
}
