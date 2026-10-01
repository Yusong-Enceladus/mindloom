import BestASRDomain
import Foundation
import GRDB

/// The library's agent records (AGENT-CONTRACT §2): grants, per-matter
/// approvals, the audit list and the Agent 收件箱. Local tables only (schema
/// v25): never sent, never in a portable archive.
extension GRDBDictationStore: AgentAccessRecordStore {
  /// The audit keeps this many rows; older ones go first.
  public static let maximumAgentAuditRows = 20_000

  public func agentGrants() async throws -> [AgentGrantRecord] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM agent_grants ORDER BY created_at, grant_id")
        .compactMap(Self.agentGrant)
    }
  }

  public func saveAgentGrant(_ grant: AgentGrantRecord) async throws {
    guard grant.terms.duration != .once else { return }
    let database = try requirePool()
    let spaces = try Self.agentJSON(grant.terms.spaces.sorted())
    let ids = try Self.agentJSON(grant.terms.range.ids.sorted())
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO agent_grants (
            grant_id, client_key, client_name, client_path, spaces_json, range_kind,
            range_ids_json, can_propose, duration, show_numbers, ask_new_matters,
            created_at, expires_at, mac
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          grant.grantID.uuidString.lowercased(), grant.clientKey, grant.clientName,
          grant.clientPath, spaces, grant.terms.range.kind, ids, grant.terms.canPropose,
          grant.terms.duration.rawValue, grant.terms.showNumbers, grant.terms.askForNewMatters,
          grant.createdAt.timeIntervalSince1970, grant.expiresAt?.timeIntervalSince1970,
          grant.mac,
        ])
    }
  }

  public func deleteAgentGrant(_ grantID: UUID) async throws {
    let database = try requirePool()
    let id = grantID.uuidString.lowercased()
    try await database.write { db in
      try db.execute(sql: "DELETE FROM agent_grant_matters WHERE grant_id = ?", arguments: [id])
      try db.execute(sql: "DELETE FROM agent_grants WHERE grant_id = ?", arguments: [id])
    }
  }

  public func agentMatterDecisions(grantID: UUID) async throws -> [String: Bool] {
    let database = try requirePool()
    let id = grantID.uuidString.lowercased()
    return try await database.read { db in
      var decisions: [String: Bool] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT matter_id, allowed FROM agent_grant_matters WHERE grant_id = ?",
        arguments: [id])
      {
        decisions[row["matter_id"]] = row["allowed"]
      }
      return decisions
    }
  }

  public func recordAgentMatterDecision(
    grantID: UUID, matterID: String, allowed: Bool, at: Date
  ) async throws {
    let database = try requirePool()
    let id = grantID.uuidString.lowercased()
    try await database.write { db in
      // A grant revoked meanwhile keeps no answers.
      guard
        try Bool.fetchOne(
          db, sql: "SELECT 1 FROM agent_grants WHERE grant_id = ?", arguments: [id]) == true
      else { return }
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO agent_grant_matters (grant_id, matter_id, allowed, decided_at)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [id, matterID, allowed, at.timeIntervalSince1970])
    }
  }

  public func appendAgentAudit(_ record: AgentAuditRecord) async throws {
    let database = try requirePool()
    let ids = try Self.agentJSON(record.matterIDs)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO agent_audit (
            at, client_key, client_name, grant_id, tool, outcome, matter_ids_json, byte_count
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.at.timeIntervalSince1970, record.clientKey, record.clientName,
          record.grantID?.uuidString.lowercased(), record.tool, record.outcome.rawValue, ids,
          max(0, record.byteCount),
        ])
      try db.execute(
        sql: """
          DELETE FROM agent_audit WHERE id <= (
            SELECT id FROM agent_audit ORDER BY id DESC LIMIT 1 OFFSET ?)
          """,
        arguments: [Self.maximumAgentAuditRows])
    }
  }

  public func agentAudit(clientKey: String?, limit: Int) async throws -> [AgentAuditRecord] {
    let database = try requirePool()
    let bounded = max(1, min(limit, Self.maximumAgentAuditRows))
    return try await database.read { db in
      let rows: [Row]
      if let clientKey {
        rows = try Row.fetchAll(
          db,
          sql: "SELECT * FROM agent_audit WHERE client_key = ? ORDER BY id DESC LIMIT ?",
          arguments: [clientKey, bounded])
      } else {
        rows = try Row.fetchAll(
          db, sql: "SELECT * FROM agent_audit ORDER BY id DESC LIMIT ?", arguments: [bounded])
      }
      return rows.compactMap(Self.agentAuditRecord)
    }
  }

  public func addAgentProposal(_ proposal: AgentInboxProposal) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO agent_inbox (
            proposal_id, client_key, client_name, created_at, title, body, matter_hint, state
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
          """,
        arguments: [
          proposal.proposalID.uuidString.lowercased(), proposal.clientKey, proposal.clientName,
          proposal.createdAt.timeIntervalSince1970, proposal.title, proposal.text,
          proposal.matterHint,
        ])
    }
  }

  public func agentProposals(includeDecided: Bool) async throws -> [AgentInboxProposal] {
    let database = try requirePool()
    return try await database.read { db in
      let sql =
        includeDecided
        ? "SELECT * FROM agent_inbox ORDER BY created_at DESC, proposal_id"
        : "SELECT * FROM agent_inbox WHERE state = 'pending' ORDER BY created_at DESC, proposal_id"
      return try Row.fetchAll(db, sql: sql).compactMap(Self.agentProposal)
    }
  }

  public func resolveAgentProposal(
    _ proposalID: UUID, state: AgentInboxProposal.State, itemID: SessionID?, at: Date
  ) async throws {
    guard state != .pending else { return }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE agent_inbox
          SET state = ?, resolved_at = ?, item_id = ?, title = '', body = '', matter_hint = ''
          WHERE proposal_id = ? AND state = 'pending'
          """,
        arguments: [
          state.rawValue, at.timeIntervalSince1970, itemID?.rawValue.uuidString,
          proposalID.uuidString.lowercased(),
        ])
    }
  }

  // MARK: - Rows

  private nonisolated static func agentJSON(_ values: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  private nonisolated static func agentStrings(_ text: String?) -> [String] {
    guard let text, let data = text.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  private nonisolated static func agentGrant(_ row: Row) -> AgentGrantRecord? {
    guard let id = (row["grant_id"] as String?).flatMap(UUID.init(uuidString:)),
      let duration = (row["duration"] as String?).flatMap(AgentGrantDuration.init(rawValue:)),
      let range = AgentScopeRange(
        kind: row["range_kind"] ?? "", ids: Set(agentStrings(row["range_ids_json"])))
    else { return nil }
    let terms = AgentGrantTerms(
      spaces: Set(agentStrings(row["spaces_json"])), range: range,
      canPropose: row["can_propose"] ?? false, duration: duration,
      showNumbers: row["show_numbers"] ?? false,
      askForNewMatters: row["ask_new_matters"] ?? false)
    return AgentGrantRecord(
      grantID: id, clientKey: row["client_key"] ?? "", clientName: row["client_name"] ?? "",
      clientPath: row["client_path"] ?? "", terms: terms,
      createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0),
      expiresAt: (row["expires_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
      mac: row["mac"] ?? "")
  }

  private nonisolated static func agentAuditRecord(_ row: Row) -> AgentAuditRecord? {
    guard let outcome = (row["outcome"] as String?).flatMap(AgentAuditOutcome.init(rawValue:))
    else { return nil }
    return AgentAuditRecord(
      id: row["id"] ?? 0, at: Date(timeIntervalSince1970: row["at"] ?? 0),
      clientKey: row["client_key"] ?? "", clientName: row["client_name"] ?? "",
      grantID: (row["grant_id"] as String?).flatMap(UUID.init(uuidString:)),
      tool: row["tool"] ?? "", outcome: outcome,
      matterIDs: agentStrings(row["matter_ids_json"]), byteCount: row["byte_count"] ?? 0)
  }

  private nonisolated static func agentProposal(_ row: Row) -> AgentInboxProposal? {
    guard let id = (row["proposal_id"] as String?).flatMap(UUID.init(uuidString:)),
      let state = (row["state"] as String?).flatMap(AgentInboxProposal.State.init(rawValue:))
    else { return nil }
    return AgentInboxProposal(
      proposalID: id, clientKey: row["client_key"] ?? "", clientName: row["client_name"] ?? "",
      createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0), title: row["title"] ?? "",
      text: row["body"] ?? "", matterHint: row["matter_hint"] ?? "", state: state,
      resolvedAt: (row["resolved_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
      itemID: (row["item_id"] as String?).flatMap(UUID.init(uuidString:)).map(SessionID.init))
  }
}
