import Foundation

// v11 (Mindloom): what the user organizes by hand on this Mac — 置顶, 分组 and
// 标为完成 / 已经定了 on a step the organizer derived. These never leave the
// Mac (they are not organizer decisions) and the organizer never proposes
// them. Stable IDs, revisions and tombstones keep them ready for a future
// sync. Persistence: schema v26 (`GRDBDictationStore+UserOrganizing`).

/// One pinned matter (sidebar 置顶, oldest pin first).
public struct UserPin: Equatable, Hashable, Sendable {
  /// The ID the pages use: a Spark event UUID or a local event ID.
  public let eventID: String
  public let pinnedAt: Date
  public let revision: Int

  public init(eventID: String, pinnedAt: Date, revision: Int = 1) {
    self.eventID = eventID
    self.pinnedAt = pinnedAt
    self.revision = revision
  }
}

/// A user-made group of matters (分组). A matter is in at most one group.
public struct UserGroup: Equatable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let name: String
  /// Sidebar order (ascending); new groups go last.
  public let sortOrder: Int
  public let createdAt: Date
  public let updatedAt: Date
  public let revision: Int
  /// Member matter IDs, in the order they were added. A member whose matter
  /// no longer exists stays here; the pages hide it.
  public let eventIDs: [String]

  public init(
    id: UUID, name: String, sortOrder: Int, createdAt: Date, updatedAt: Date, revision: Int = 1,
    eventIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.sortOrder = sortOrder
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.revision = revision
    self.eventIDs = eventIDs
  }
}

/// 标为完成 (or 已经定了 for an open question) on one organizer step. It wins
/// over whatever a later organizer map says about that step.
public struct UserStepOverride: Equatable, Hashable, Sendable {
  public enum State: String, Equatable, Hashable, Sendable, Codable {
    /// 标为完成.
    case done
    /// 已经定了 (an open question settled).
    case settled
  }

  public let eventID: String
  /// A map knot ID (`k6`) or a status-line step ID (`st1`).
  public let stepID: String
  public let state: State
  /// When the user marked it (the step's day when it had none or a later one).
  public let createdAt: Date
  public let revision: Int

  public init(
    eventID: String, stepID: String, state: State = .done, createdAt: Date, revision: Int = 1
  ) {
    self.eventID = eventID
    self.stepID = stepID
    self.state = state
    self.createdAt = createdAt
    self.revision = revision
  }
}

/// Everything live (tombstones left out), as the pages read it.
public struct UserOrganizingSnapshot: Equatable, Sendable {
  public var pins: [UserPin]
  public var groups: [UserGroup]
  public var stepOverrides: [UserStepOverride]

  public init(
    pins: [UserPin] = [], groups: [UserGroup] = [], stepOverrides: [UserStepOverride] = []
  ) {
    self.pins = pins
    self.groups = groups
    self.stepOverrides = stepOverrides
  }

  public static let empty = UserOrganizingSnapshot()

  /// The group a matter is in, if any.
  public func group(of eventID: String) -> UserGroup? {
    groups.first { $0.eventIDs.contains(eventID) }
  }

  public func isPinned(_ eventID: String) -> Bool { pins.contains { $0.eventID == eventID } }

  public func override(eventID: String, stepID: String) -> UserStepOverride? {
    stepOverrides.first { $0.eventID == eventID && $0.stepID == stepID }
  }
}

/// The library's user-organizing records. Every write is idempotent: pinning
/// a pinned matter, or moving a matter to the group it is in, changes nothing.
public protocol UserOrganizingStore: Sendable {
  func userOrganizing() async throws -> UserOrganizingSnapshot
  /// 置顶 / 取消置顶.
  func setPinned(_ pinned: Bool, eventID: String, at date: Date) async throws
  /// 新建分组: a new group, last in the sidebar. The name is trimmed and must
  /// not be empty.
  @discardableResult
  func createUserGroup(name: String, at date: Date) async throws -> UserGroup
  func renameUserGroup(_ groupID: UUID, name: String, at date: Date) async throws
  /// Tombstones the group and its memberships (the matters stay).
  func deleteUserGroup(_ groupID: UUID, at date: Date) async throws
  /// 移到分组 / 添加到「…」: the matter leaves its current group (if any) and
  /// joins `groupID`; nil is 不放在分组里.
  func moveToUserGroup(eventID: String, groupID: UUID?, at date: Date) async throws
  /// 标为完成 / 已经定了 (`state`), or nil to take it back (撤销).
  func setStepOverride(
    eventID: String, stepID: String, state: UserStepOverride.State?, at date: Date
  ) async throws
}

public enum UserOrganizingError: Error, Equatable, Sendable {
  case emptyName
  case unknownGroup
}

/// The same records in memory: snapshots, previews and tests.
public actor InMemoryUserOrganizingStore: UserOrganizingStore {
  private var snapshot: UserOrganizingSnapshot

  public init(_ snapshot: UserOrganizingSnapshot = .empty) {
    self.snapshot = snapshot
  }

  public func userOrganizing() async throws -> UserOrganizingSnapshot { snapshot }

  public func setPinned(_ pinned: Bool, eventID: String, at date: Date) async throws {
    let isPinned = snapshot.isPinned(eventID)
    if pinned, !isPinned {
      snapshot.pins.append(UserPin(eventID: eventID, pinnedAt: date))
    } else if !pinned, isPinned {
      snapshot.pins.removeAll { $0.eventID == eventID }
    }
  }

  @discardableResult
  public func createUserGroup(name: String, at date: Date) async throws -> UserGroup {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw UserOrganizingError.emptyName }
    let group = UserGroup(
      id: UUID(), name: clean, sortOrder: (snapshot.groups.map(\.sortOrder).max() ?? -1) + 1,
      createdAt: date, updatedAt: date)
    snapshot.groups.append(group)
    return group
  }

  public func renameUserGroup(_ groupID: UUID, name: String, at date: Date) async throws {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw UserOrganizingError.emptyName }
    guard let index = snapshot.groups.firstIndex(where: { $0.id == groupID }) else {
      throw UserOrganizingError.unknownGroup
    }
    let old = snapshot.groups[index]
    snapshot.groups[index] = UserGroup(
      id: old.id, name: clean, sortOrder: old.sortOrder, createdAt: old.createdAt,
      updatedAt: date, revision: old.revision + 1, eventIDs: old.eventIDs)
  }

  public func deleteUserGroup(_ groupID: UUID, at date: Date) async throws {
    snapshot.groups.removeAll { $0.id == groupID }
  }

  public func moveToUserGroup(eventID: String, groupID: UUID?, at date: Date) async throws {
    if let groupID, !snapshot.groups.contains(where: { $0.id == groupID }) {
      throw UserOrganizingError.unknownGroup
    }
    snapshot.groups = snapshot.groups.map { group in
      var ids = group.eventIDs
      if group.id == groupID {
        if !ids.contains(eventID) { ids.append(eventID) }
      } else {
        ids.removeAll { $0 == eventID }
      }
      guard ids != group.eventIDs else { return group }
      return UserGroup(
        id: group.id, name: group.name, sortOrder: group.sortOrder, createdAt: group.createdAt,
        updatedAt: date, revision: group.revision + 1, eventIDs: ids)
    }
  }

  public func setStepOverride(
    eventID: String, stepID: String, state: UserStepOverride.State?, at date: Date
  ) async throws {
    snapshot.stepOverrides.removeAll { $0.eventID == eventID && $0.stepID == stepID }
    if let state {
      snapshot.stepOverrides.append(
        UserStepOverride(eventID: eventID, stepID: stepID, state: state, createdAt: date))
    }
  }
}
