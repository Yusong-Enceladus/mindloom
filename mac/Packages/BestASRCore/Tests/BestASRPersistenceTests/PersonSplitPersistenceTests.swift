import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// v12 「不是他」 (ALIGNMENT 理3-1): some of a person's speech goes to a new
/// person nobody named yet, under the ID the page already showed; merging
/// and naming still work and the split can be undone. Synthetic data only.
final class PersonSplitPersistenceTests: XCTestCase {
  private let sessionID = SessionID(persistenceUUID(9_100))
  private let birth = Date(timeIntervalSince1970: 1_788_000_000)
  private let device = UUID(uuidString: "0D000000-0000-4000-8000-000000000001")!

  private func personID(_ n: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "9A000000-0000-4000-8000-%012d", n))!)
  }

  private func occurrenceID(_ n: Int) -> SpeakerOccurrenceID {
    SpeakerOccurrenceID(persistenceUUID(UInt64(9_300 + n)))
  }

  /// Person 1 (「虚构甲」) speaks three turns, person 2 (unnamed) one.
  private func seed(at url: URL) async throws {
    let queue = try DatabaseQueue(path: url.path)
    let session = sessionID.rawValue.uuidString
    let born = birth.timeIntervalSince1970
    let people: [(id: String, name: String?, speaker: String, turns: [(String, Int)])] = [
      (
        personID(1).rawValue.uuidString, "虚构甲", persistenceUUID(9_200).uuidString,
        [0, 1, 2].map { (occurrenceID($0).rawValue.uuidString, $0) }
      ),
      (
        personID(2).rawValue.uuidString, nil, persistenceUUID(9_201).uuidString,
        [(occurrenceID(3).rawValue.uuidString, 3)]
      ),
    ]
    try await queue.write { db in
      for (index, row) in people.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO persons(id, revision, display_name, aliases_json, created_at, updated_at)
            VALUES (?, 1, ?, '[]', ?, ?)
            """,
          arguments: [row.id, row.name, born + Double(index), born])
        try db.execute(
          sql: """
            INSERT INTO session_speakers(id, session_id, revision, stable_ordinal)
            VALUES (?, ?, 1, ?)
            """, arguments: [row.speaker, session, index + 1])
        for (occurrence, turn) in row.turns {
          try db.execute(
            sql: """
              INSERT INTO speaker_occurrences(
                id, session_id, session_speaker_id, revision, monotonic_start_ns,
                monotonic_end_ns, overlaps_another_speaker, association_status,
                person_id, evidence_revision
              ) VALUES (?, ?, ?, 1, ?, ?, 0, ?, ?, 1)
              """,
            arguments: [
              occurrence, session, row.speaker, turn * 2_000_000_000, (turn + 1) * 2_000_000_000,
              row.name == nil ? "anonymousIdentity" : "userConfirmed", row.id,
            ])
        }
      }
    }
    try queue.close()
  }

  func testNotPersonMakesANewUnnamedPersonUnderTheChosenID() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: url)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    try await seed(at: url)

    let chosen = personID(7)
    let made = try await store.splitPersonOccurrences(
      sourcePersonID: personID(1), occurrenceIDs: [occurrenceID(1), occurrenceID(2)],
      newDisplayName: nil, newPersonID: chosen, originDeviceID: device)
    XCTAssertEqual(made.id, chosen)
    XCTAssertNil(made.displayName)

    let people = try await store.personSummaries()
    let newcomer = try XCTUnwrap(people.first { $0.id == chosen })
    XCTAssertNil(newcomer.person.displayName)
    XCTAssertEqual(newcomer.occurrenceCount, 2)
    XCTAssertEqual(newcomer.sessionCount, 1)
    XCTAssertEqual(people.first { $0.id == personID(1) }?.occurrenceCount, 1)
    let turns = try await store.sessionOccurrenceSummaries(sessionID: sessionID)
    XCTAssertEqual(
      turns.filter { $0.personID == chosen }.map(\.id), [occurrenceID(1), occurrenceID(2)])

    // The same ID twice, or a person's own ID, is refused (nothing changes).
    do {
      _ = try await store.splitPersonOccurrences(
        sourcePersonID: personID(1), occurrenceIDs: [occurrenceID(0)], newDisplayName: nil,
        newPersonID: chosen, originDeviceID: device)
      XCTFail("an existing person ID must be refused")
    } catch {}
    do {
      _ = try await store.splitPersonOccurrences(
        sourcePersonID: personID(1), occurrenceIDs: [occurrenceID(0)], newDisplayName: "  ",
        originDeviceID: device)
      XCTFail("a blank name must be refused")
    } catch {}
    let unchanged = try await store.sessionOccurrenceSummaries(sessionID: sessionID)
    XCTAssertEqual(unchanged.filter { $0.personID == personID(1) }.count, 1)

    // Naming the new voice, then merging the other unnamed voice into it.
    _ = try await store.renamePerson(
      personID: chosen, displayName: "虚构丙", aliases: [], originDeviceID: device)
    try await store.mergePersons(primaryID: chosen, mergedID: personID(2), originDeviceID: device)
    let after = try await store.personSummaries()
    XCTAssertNil(after.first { $0.id == personID(2) })
    XCTAssertEqual(after.first { $0.id == chosen }?.occurrenceCount, 3)

    // Each step can still be undone, the split last.
    for _ in 0..<3 {
      let undid = try await store.undoLastPersonEdit(originDeviceID: device)
      XCTAssertTrue(undid)
    }
    let undone = try await store.sessionOccurrenceSummaries(sessionID: sessionID)
    XCTAssertEqual(undone.filter { $0.personID == personID(1) }.count, 3)
    XCTAssertEqual(undone.filter { $0.personID == personID(2) }.count, 1)
    try await store.checkpointAndClose()
  }
}
