import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

final class PersonPresentationPersistenceTests: XCTestCase {
  private let sessionID = SessionID(persistenceUUID(8_100))
  private let names: [String?] = ["Jordan, Jr.", "Jordan, Jr.", nil, nil]
  private let birth = Date(timeIntervalSince1970: 1_788_000_000)

  private func seedPeople(at url: URL) async throws -> [PersonID] {
    let queue = try DatabaseQueue(path: url.path)
    let names = self.names
    let birth = self.birth
    let sessionID = self.sessionID
    let ids = (1...4).map {
      PersonID(UUID(uuidString: String(format: "7FAFAF%02d-CCAA-4000-8000-000000000071", $0))!)
    }
    try await queue.write { db in
      for index in ids.indices {
        let speakerID = persistenceUUID(UInt64(8_200 + index)).uuidString
        try db.execute(
          sql: """
            INSERT INTO persons(id, revision, display_name, aliases_json, created_at, updated_at)
            VALUES (?, 1, ?, '[]', ?, ?)
            """,
          arguments: [
            ids[index].rawValue.uuidString, names[index],
            birth.timeIntervalSince1970, birth.timeIntervalSince1970,
          ])
        try db.execute(
          sql: """
            INSERT INTO session_speakers(id, session_id, revision, stable_ordinal)
            VALUES (?, ?, 1, ?)
            """, arguments: [speakerID, sessionID.rawValue.uuidString, index + 1])
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrences(
              id, session_id, session_speaker_id, revision, monotonic_start_ns,
              monotonic_end_ns, overlaps_another_speaker, association_status,
              person_id, evidence_revision
            ) VALUES (?, ?, ?, 1, ?, ?, 0, ?, ?, 1)
            """,
          arguments: [
            persistenceUUID(UInt64(8_300 + index)).uuidString,
            sessionID.rawValue.uuidString, speakerID, index * 1_000_000_000,
            (index + 1) * 1_000_000_000,
            index < 2 ? "userConfirmed" : "anonymousIdentity", ids[index].rawValue.uuidString,
          ])
      }
    }
    try queue.close()
    return ids
  }

  func testHistoryAndEventPreservePairedPeopleWithCommasAndIdenticalNames() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: url)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let ids = try await seedPeople(at: url)
    let items = try await store.loadHistory()
    let item = try XCTUnwrap(items.first)
    let unnamed = PersonDisplayTitle.formatted(displayName: nil, createdAt: birth)
    XCTAssertEqual(item.personIDs, ids)
    XCTAssertEqual(item.personDisplayNames, ["Jordan, Jr.", "Jordan, Jr.", unnamed, unnamed])

    let event = try await store.createEvent(
      title: "Synthetic people", notes: "", sessionIDs: [sessionID])
    let events = try await store.eventSummaries()
    let summary = try XCTUnwrap(events.first { $0.id == event.id })
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: zip(summary.personIDs, summary.personDisplayNames)),
      Dictionary(uniqueKeysWithValues: zip(item.personIDs, item.personDisplayNames))
    )
    let people = try await store.personSummaries()
    for person in people {
      XCTAssertEqual(
        person.displayTitle, item.personDisplayNames[try XCTUnwrap(ids.firstIndex(of: person.id))])
    }
    try await store.checkpointAndClose()
  }

  func testDerivedSearchRepairRemovesUUIDKeywordsWithoutChangingSourceIdentity() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: url)
    try await store.create(preparingSnapshot(sessionID: sessionID))
    let ids = try await seedPeople(at: url)
    let before = try await store.loadHistory()
    try await store.checkpointAndClose()

    // Reproduce a retained v4 derived index, not a new portable schema.
    let legacy = try DatabaseQueue(path: url.path)
    try await legacy.write { db in
      try db.execute(
        sql: "UPDATE bestasr_derived_index_metadata SET value = '4' WHERE key = 'history-search'")
      try db.execute(
        sql:
          "UPDATE history_search_fts SET content = content || ' ' || person_id WHERE source_kind = 'person'"
      )
    }
    try legacy.close()
    let reopened = try GRDBDictationStore(databaseURL: url)
    let after = try await reopened.loadHistory()
    XCTAssertEqual(after, before)
    let inspection = try await reopened.inspection()
    XCTAssertEqual(
      inspection.userVersion, BestASRPersistenceSchema.currentUserVersion,
      "A reopened legacy database has to arrive at the current schema")
    for query in ["7F", "7FAFAF", ids[0].rawValue.uuidString] {
      let matches = try await reopened.searchHistory(query: query, mode: nil, status: nil)
      XCTAssertTrue(matches.isEmpty, "Storage-only identity must not match a memory query.")
    }
    for query in ["Jordan, Jr.", "待命名", "未知"] {
      let matches = try await reopened.searchHistory(query: query, mode: nil, status: nil)
      XCTAssertEqual(matches.map(\.sessionID), [sessionID])
    }
    try await reopened.renamePerson(
      personID: ids[2], displayName: "陈老师", aliases: ["海星"], originDeviceID: UUID())
    let renamed = try await reopened.searchHistory(query: "陈老师", mode: nil, status: nil)
    let aliased = try await reopened.searchHistory(query: "海星", mode: nil, status: nil)
    XCTAssertEqual(renamed.map(\.sessionID), [sessionID])
    XCTAssertEqual(aliased.map(\.sessionID), [sessionID])
    try await reopened.checkpointAndClose()
  }
}
