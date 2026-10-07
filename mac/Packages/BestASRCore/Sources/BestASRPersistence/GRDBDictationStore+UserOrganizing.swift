import BestASRDomain
import Foundation
import GRDB

/// 置顶, 分组 and 标为完成 made by hand on this Mac (schema v26). Rows are
/// never deleted: a change bumps `revision`, a removal sets `deleted_at`, and
/// doing it again revives the row. Nothing here is sent to the DGX Spark.
extension GRDBDictationStore: UserOrganizingStore {
  public func userOrganizing() async throws -> UserOrganizingSnapshot {
    let database = try requirePool()
    return try await database.read { db in
      let pins = try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, pinned_at, revision FROM user_pins
          WHERE deleted_at IS NULL ORDER BY pinned_at, event_id
          """
      ).map { row in
        UserPin(
          eventID: row["event_id"], pinnedAt: Date(timeIntervalSince1970: row["pinned_at"]),
          revision: row["revision"])
      }
      var members: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT group_id, event_id FROM user_group_members
          WHERE deleted_at IS NULL ORDER BY added_at, event_id
          """)
      {
        members[row["group_id"], default: []].append(row["event_id"])
      }
      let groups = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM user_groups WHERE deleted_at IS NULL
          ORDER BY sort_order, created_at, group_id
          """
      ).compactMap { row -> UserGroup? in
        let id: String = row["group_id"]
        guard let uuid = UUID(uuidString: id) else { return nil }
        return UserGroup(
          id: uuid, name: row["name"], sortOrder: row["sort_order"],
          createdAt: Date(timeIntervalSince1970: row["created_at"]),
          updatedAt: Date(timeIntervalSince1970: row["updated_at"]), revision: row["revision"],
          eventIDs: members[id] ?? [])
      }
      let overrides = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM user_step_overrides WHERE deleted_at IS NULL
          ORDER BY created_at, event_id, step_id
          """
      ).compactMap { row -> UserStepOverride? in
        guard let state = UserStepOverride.State(rawValue: row["state"]) else { return nil }
        return UserStepOverride(
          eventID: row["event_id"], stepID: row["step_id"], state: state,
          createdAt: Date(timeIntervalSince1970: row["created_at"]), revision: row["revision"])
      }
      return UserOrganizingSnapshot(pins: pins, groups: groups, stepOverrides: overrides)
    }
  }

  public func setPinned(_ pinned: Bool, eventID: String, at date: Date) async throws {
    let database = try requirePool()
    let at = date.timeIntervalSince1970
    try await database.write { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT deleted_at FROM user_pins WHERE event_id = ?", arguments: [eventID])
      let live = row.map { ($0["deleted_at"] as Double?) == nil } ?? false
      switch (pinned, row, live) {
      case (true, nil, _):
        try db.execute(
          sql: "INSERT INTO user_pins (event_id, pinned_at, revision) VALUES (?, ?, 1)",
          arguments: [eventID, at])
      case (true, _?, false):
        try db.execute(
          sql: """
            UPDATE user_pins SET pinned_at = ?, deleted_at = NULL, revision = revision + 1
            WHERE event_id = ?
            """, arguments: [at, eventID])
      case (false, _?, true):
        try db.execute(
          sql: "UPDATE user_pins SET deleted_at = ?, revision = revision + 1 WHERE event_id = ?",
          arguments: [at, eventID])
      default:
        break
      }
    }
  }

  @discardableResult
  public func createUserGroup(name: String, at date: Date) async throws -> UserGroup {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw UserOrganizingError.emptyName }
    let database = try requirePool()
    let id = UUID()
    let at = date.timeIntervalSince1970
    let order = try await database.write { db -> Int in
      let order =
        (try Int.fetchOne(
          db, sql: "SELECT MAX(sort_order) FROM user_groups WHERE deleted_at IS NULL") ?? -1) + 1
      try db.execute(
        sql: """
          INSERT INTO user_groups (
            group_id, name, sort_order, created_at, updated_at, revision
          ) VALUES (?, ?, ?, ?, ?, 1)
          """, arguments: [id.uuidString.lowercased(), clean, order, at, at])
      return order
    }
    return UserGroup(id: id, name: clean, sortOrder: order, createdAt: date, updatedAt: date)
  }

  public func renameUserGroup(_ groupID: UUID, name: String, at date: Date) async throws {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw UserOrganizingError.emptyName }
    let database = try requirePool()
    try await database.write { db in
      let id = try Self.liveGroupID(db, groupID)
      try db.execute(
        sql: """
          UPDATE user_groups SET name = ?, updated_at = ?, revision = revision + 1
          WHERE group_id = ? AND name != ?
          """, arguments: [clean, date.timeIntervalSince1970, id, clean])
    }
  }

  public func deleteUserGroup(_ groupID: UUID, at date: Date) async throws {
    let database = try requirePool()
    let at = date.timeIntervalSince1970
    try await database.write { db in
      let id = groupID.uuidString.lowercased()
      try db.execute(
        sql: """
          UPDATE user_group_members SET deleted_at = ?, revision = revision + 1
          WHERE group_id = ? AND deleted_at IS NULL
          """, arguments: [at, id])
      try db.execute(
        sql: """
          UPDATE user_groups SET deleted_at = ?, updated_at = ?, revision = revision + 1
          WHERE group_id = ? AND deleted_at IS NULL
          """, arguments: [at, at, id])
    }
  }

  public func moveToUserGroup(eventID: String, groupID: UUID?, at date: Date) async throws {
    let database = try requirePool()
    let at = date.timeIntervalSince1970
    try await database.write { db in
      let target = try groupID.map { try Self.liveGroupID(db, $0) }
      // Leave every other group (a matter is in at most one).
      try db.execute(
        sql: """
          UPDATE user_group_members SET deleted_at = ?, revision = revision + 1
          WHERE event_id = ? AND deleted_at IS NULL AND group_id IS NOT ?
          """, arguments: [at, eventID, target])
      guard let target else { return }
      let existing = try Row.fetchOne(
        db, sql: "SELECT deleted_at FROM user_group_members WHERE group_id = ? AND event_id = ?",
        arguments: [target, eventID])
      if existing == nil {
        try db.execute(
          sql: """
            INSERT INTO user_group_members (group_id, event_id, added_at, revision)
            VALUES (?, ?, ?, 1)
            """, arguments: [target, eventID, at])
      } else if let existing, (existing["deleted_at"] as Double?) != nil {
        try db.execute(
          sql: """
            UPDATE user_group_members SET added_at = ?, deleted_at = NULL, revision = revision + 1
            WHERE group_id = ? AND event_id = ?
            """, arguments: [at, target, eventID])
      }
    }
  }

  public func setStepOverride(
    eventID: String, stepID: String, state: UserStepOverride.State?, at date: Date
  ) async throws {
    let database = try requirePool()
    let at = date.timeIntervalSince1970
    try await database.write { db in
      let existing = try Row.fetchOne(
        db,
        sql: "SELECT state, deleted_at FROM user_step_overrides WHERE event_id = ? AND step_id = ?",
        arguments: [eventID, stepID])
      if let state {
        if existing == nil {
          try db.execute(
            sql: """
              INSERT INTO user_step_overrides (event_id, step_id, state, created_at, revision)
              VALUES (?, ?, ?, ?, 1)
              """, arguments: [eventID, stepID, state.rawValue, at])
        } else if let existing,
          (existing["deleted_at"] as Double?) != nil || (existing["state"] as String) != state.rawValue
        {
          try db.execute(
            sql: """
              UPDATE user_step_overrides
              SET state = ?, created_at = ?, deleted_at = NULL, revision = revision + 1
              WHERE event_id = ? AND step_id = ?
              """, arguments: [state.rawValue, at, eventID, stepID])
        }
      } else if let existing, (existing["deleted_at"] as Double?) == nil {
        try db.execute(
          sql: """
            UPDATE user_step_overrides SET deleted_at = ?, revision = revision + 1
            WHERE event_id = ? AND step_id = ?
            """, arguments: [at, eventID, stepID])
      }
    }
  }

  private nonisolated static func liveGroupID(_ db: Database, _ groupID: UUID) throws -> String {
    let id = groupID.uuidString.lowercased()
    guard
      try Bool.fetchOne(
        db, sql: "SELECT 1 FROM user_groups WHERE group_id = ? AND deleted_at IS NULL",
        arguments: [id]) == true
    else { throw UserOrganizingError.unknownGroup }
    return id
  }
}
