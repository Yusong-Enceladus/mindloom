import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// Schema v26 (v11): pins, user groups and step overrides, and the v25 → v26
/// upgrade that widens `agent_grants` without losing grants or approvals.
final class UserOrganizingPersistenceTests: XCTestCase {
  private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

  func testPinsAreIdempotentAndRevive() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("s.sqlite"))
    try await store.setPinned(true, eventID: "E6", at: date(1))
    try await store.setPinned(true, eventID: "E25", at: date(2))
    try await store.setPinned(true, eventID: "E6", at: date(3))
    var snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.pins.map(\.eventID), ["E6", "E25"])
    XCTAssertEqual(snapshot.pins.first?.pinnedAt, date(1))

    try await store.setPinned(false, eventID: "E6", at: date(4))
    snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.pins.map(\.eventID), ["E25"])

    // Pinning again revives the row with a new time and revision.
    try await store.setPinned(true, eventID: "E6", at: date(5))
    snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.pins.map(\.eventID), ["E25", "E6"])
    XCTAssertEqual(snapshot.pins.last?.revision, 3)
    try await store.checkpointAndClose()
  }

  func testGroupsHoldAMatterAtMostOnce() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("s.sqlite"))
    let papers = try await store.createUserGroup(name: "  论文 ", at: date(1))
    let life = try await store.createUserGroup(name: "生活", at: date(2))
    XCTAssertEqual(papers.name, "论文")
    XCTAssertEqual([papers.sortOrder, life.sortOrder], [0, 1])
    do {
      _ = try await store.createUserGroup(name: "   ", at: date(3))
      XCTFail("an empty name must be refused")
    } catch let error as UserOrganizingError {
      XCTAssertEqual(error, .emptyName)
    }

    try await store.moveToUserGroup(eventID: "E6", groupID: papers.id, at: date(4))
    try await store.moveToUserGroup(eventID: "E3", groupID: papers.id, at: date(5))
    try await store.moveToUserGroup(eventID: "E6", groupID: papers.id, at: date(6))
    var snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.groups.map(\.name), ["论文", "生活"])
    XCTAssertEqual(snapshot.group(of: "E6")?.id, papers.id)
    XCTAssertEqual(snapshot.groups[0].eventIDs, ["E6", "E3"])

    // Moving leaves the old group.
    try await store.moveToUserGroup(eventID: "E6", groupID: life.id, at: date(7))
    snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.groups[0].eventIDs, ["E3"])
    XCTAssertEqual(snapshot.groups[1].eventIDs, ["E6"])

    // 不放在分组里.
    try await store.moveToUserGroup(eventID: "E6", groupID: nil, at: date(8))
    snapshot = try await store.userOrganizing()
    XCTAssertNil(snapshot.group(of: "E6"))

    try await store.renameUserGroup(life.id, name: "家里", at: date(9))
    try await store.deleteUserGroup(papers.id, at: date(10))
    snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.groups.map(\.name), ["家里"])
    XCTAssertNil(snapshot.group(of: "E3"))
    do {
      try await store.moveToUserGroup(eventID: "E3", groupID: papers.id, at: date(11))
      XCTFail("a deleted group takes no members")
    } catch let error as UserOrganizingError {
      XCTAssertEqual(error, .unknownGroup)
    }
    try await store.checkpointAndClose()
  }

  func testStepOverridesSetChangeAndTakeBack() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("s.sqlite"))
    try await store.setStepOverride(eventID: "E6", stepID: "st1", state: .done, at: date(1))
    try await store.setStepOverride(eventID: "E6", stepID: "k5", state: .settled, at: date(2))
    var snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.override(eventID: "E6", stepID: "st1")?.state, .done)
    XCTAssertEqual(snapshot.override(eventID: "E6", stepID: "k5")?.state, .settled)

    try await store.setStepOverride(eventID: "E6", stepID: "st1", state: nil, at: date(3))
    snapshot = try await store.userOrganizing()
    XCTAssertNil(snapshot.override(eventID: "E6", stepID: "st1"))
    XCTAssertEqual(snapshot.stepOverrides.count, 1)

    try await store.setStepOverride(eventID: "E6", stepID: "st1", state: .done, at: date(4))
    snapshot = try await store.userOrganizing()
    XCTAssertEqual(snapshot.override(eventID: "E6", stepID: "st1")?.createdAt, date(4))
    XCTAssertEqual(snapshot.override(eventID: "E6", stepID: "st1")?.revision, 3)
    try await store.checkpointAndClose()
  }

  /// A v25 library keeps its agent grants and per-matter approvals through
  /// the v26 rebuild of `agent_grants`, which now also takes `groups`.
  func testV25LibraryUpgradesWithGrantsIntact() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("v25.sqlite")
    let old = try DatabaseQueue(path: url.path)
    try BestASRPersistenceSchema.migrator().migrate(
      old, upTo: BestASRPersistenceSchema.agentAccessMigrationID)
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO agent_grants (
            grant_id, client_key, client_name, client_path, spaces_json, range_kind,
            range_ids_json, can_propose, duration, show_numbers, ask_new_matters,
            created_at, expires_at, mac
          ) VALUES ('g1', 'k', 'Claude Code', '/x', '[]', 'ropes', '["r1"]', 0, 'always', 0, 1,
                    1, NULL, 'm')
          """)
      try db.execute(
        sql: """
          INSERT INTO agent_grant_matters (grant_id, matter_id, allowed, decided_at)
          VALUES ('g1', 'E6', 1, 2)
          """)
    }
    try old.close()

    let store = try GRDBDictationStore(databaseURL: url)
    let inspection = try await store.inspection()
    // v27 (agent changes) follows straight on and keeps the grants too.
    XCTAssertEqual(inspection.userVersion, BestASRPersistenceSchema.currentUserVersion)
    XCTAssertTrue(inspection.tableNames.contains("user_step_overrides"))
    XCTAssertTrue(inspection.tableNames.contains("agent_changes"))
    try await store.checkpointAndClose()

    let check = try DatabaseQueue(path: url.path)
    try await check.write { db in
      XCTAssertEqual(try String.fetchOne(db, sql: "SELECT range_kind FROM agent_grants"), "ropes")
      XCTAssertEqual(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_grant_matters WHERE grant_id = 'g1'"),
        1)
      // The widened check takes a group scope.
      try db.execute(
        sql: """
          INSERT INTO agent_grants (
            grant_id, client_key, client_name, client_path, spaces_json, range_kind,
            range_ids_json, can_propose, duration, show_numbers, ask_new_matters,
            created_at, expires_at, mac
          ) VALUES ('g2', 'k', 'Claude Code', '/x', '[]', 'groups', '[]', 0, 'today', 0, 0,
                    1, 2, 'm')
          """)
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_key_check"), nil)
    }
    try check.close()
  }

  /// The user tables travel in the portable archive, and an archive written
  /// before them still imports.
  func testPortableArchiveCarriesUserOrganizing() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try GRDBDictationStore(databaseURL: root.appendingPathComponent("a.sqlite"))
    let group = try await source.createUserGroup(name: "论文", at: date(1))
    try await source.moveToUserGroup(eventID: "E6", groupID: group.id, at: date(2))
    try await source.setPinned(true, eventID: "E6", at: date(3))
    try await source.setStepOverride(eventID: "E6", stepID: "k6", state: .done, at: date(4))
    let state = try await source.exportPortablePersistenceState()
    XCTAssertEqual(
      Array(state.tables.suffix(4).map(\.name)),
      ["user_pins", "user_groups", "user_group_members", "user_step_overrides"])
    try await source.checkpointAndClose()

    let target = try GRDBDictationStore(databaseURL: root.appendingPathComponent("b.sqlite"))
    try await target.importPortablePersistenceState(state)
    let imported = try await target.userOrganizing()
    XCTAssertEqual(imported.pins.map(\.eventID), ["E6"])
    XCTAssertEqual(imported.group(of: "E6")?.name, "论文")
    XCTAssertEqual(imported.override(eventID: "E6", stepID: "k6")?.state, .done)

    // A v25 archive (no user tables) imports with them empty.
    let older = PortablePersistenceState(
      schemaVersion: 25, tables: Array(state.tables.dropLast(4)))
    let third = try GRDBDictationStore(databaseURL: root.appendingPathComponent("c.sqlite"))
    try await third.importPortablePersistenceState(older)
    let empty = try await third.userOrganizing()
    XCTAssertEqual(empty, .empty)
    try await target.checkpointAndClose()
    try await third.checkpointAndClose()
  }
}
