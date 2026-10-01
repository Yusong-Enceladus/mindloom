import Foundation

// Agents reading and writing 织机 (AGENT-CONTRACT; PRD §0.3 第 11 条). The
// App serves a local MCP server; what an agent may see is a grant the owner
// gave in the consent sheet. These are the records the library keeps about
// it: grants (scope, never content), per-matter approvals, the audit list
// (never content) and the Agent 收件箱 (proposals, content until decided).

/// The personal space's ID. Shared spaces (SPACES-CONTRACT) use their own IDs.
public enum AgentSpaceID {
  public static let personal = "personal"
  /// What an agent may pass for the personal space.
  public static let personalAliases: Set<String> = ["personal", "我的", "mine", "me"]

  public static func normalized(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return personalAliases.contains(trimmed.lowercased()) ? personal : trimmed
  }
}

/// Which matters of the allowed spaces a grant covers.
public enum AgentScopeRange: Equatable, Hashable, Sendable {
  case all
  /// Matters in these ropes (and in ropes nested under them).
  case ropes(Set<String>)
  /// Exactly these matters.
  case matters(Set<String>)

  public var kind: String {
    switch self {
    case .all: "all"
    case .ropes: "ropes"
    case .matters: "matters"
    }
  }

  public var ids: Set<String> {
    switch self {
    case .all: []
    case .ropes(let ids), .matters(let ids): ids
    }
  }

  public init?(kind: String, ids: Set<String>) {
    switch kind {
    case "all": self = .all
    case "ropes": self = .ropes(ids)
    case "matters": self = .matters(ids)
    default: return nil
    }
  }
}

/// 这一次 / 今天 / 一直.
public enum AgentGrantDuration: String, CaseIterable, Sendable {
  /// This connection only; never written to the library.
  case once
  /// Until the next local midnight.
  case today
  case always
}

/// What the owner chose in the consent sheet.
public struct AgentGrantTerms: Equatable, Sendable {
  public var spaces: Set<String>
  public var range: AgentScopeRange
  /// 只读 + 可以提建议（写进收件箱）.
  public var canPropose: Bool
  public var duration: AgentGrantDuration
  /// 号码：原样. Default false: numbers go out as placeholders.
  public var showNumbers: Bool
  /// 读新的一件事时先问我.
  public var askForNewMatters: Bool

  public init(
    spaces: Set<String> = [AgentSpaceID.personal], range: AgentScopeRange = .all,
    canPropose: Bool = false, duration: AgentGrantDuration = .once, showNumbers: Bool = false,
    askForNewMatters: Bool = false
  ) {
    self.spaces = spaces
    self.range = range
    self.canPropose = canPropose
    self.duration = duration
    self.showNumbers = showNumbers
    self.askForNewMatters = askForNewMatters
  }
}

/// A stored grant (`agent_grants`). The row carries a MAC made with the
/// grant's own secret, which lives only in the Keychain: a row edited in the
/// database, or one whose secret was deleted, is not a grant.
public struct AgentGrantRecord: Equatable, Sendable {
  public let grantID: UUID
  public let clientKey: String
  public let clientName: String
  public let clientPath: String
  public let terms: AgentGrantTerms
  public let createdAt: Date
  public let expiresAt: Date?
  public var mac: String

  public init(
    grantID: UUID, clientKey: String, clientName: String, clientPath: String,
    terms: AgentGrantTerms, createdAt: Date, expiresAt: Date?, mac: String
  ) {
    self.grantID = grantID
    self.clientKey = clientKey
    self.clientName = clientName
    self.clientPath = clientPath
    self.terms = terms
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.mac = mac
  }

  /// Every field the MAC covers, in a fixed order.
  public var canonicalText: String {
    [
      "mindloom-agent-grant-v1", grantID.uuidString.lowercased(), clientKey, clientName,
      clientPath, terms.spaces.sorted().joined(separator: ","), terms.range.kind,
      terms.range.ids.sorted().joined(separator: ","), terms.canPropose ? "1" : "0",
      terms.duration.rawValue, terms.showNumbers ? "1" : "0",
      terms.askForNewMatters ? "1" : "0", String(Int64(createdAt.timeIntervalSince1970 * 1_000)),
      expiresAt.map { String(Int64($0.timeIntervalSince1970 * 1_000)) } ?? "-",
    ].joined(separator: "\n")
  }
}

/// How one agent call ended. The audit keeps only this, never content.
public enum AgentAuditOutcome: String, CaseIterable, Sendable {
  case allowed
  /// The owner refused, or the grant does not allow this.
  case denied
  /// Waiting for the owner in the consent sheet or a matter approval.
  case pending
  /// Asked for a matter or person the grant does not cover (or that does
  /// not exist; the agent is not told which).
  case notFound = "not_found"
  case invalid
  case failed
}

/// One row of 谁读过什么 (`agent_audit`): who, when, which tool, which matter
/// IDs came back, how many bytes, and how it ended. Content is never kept:
/// no query, no text, no title.
public struct AgentAuditRecord: Equatable, Sendable, Identifiable {
  public let id: Int64
  public let at: Date
  public let clientKey: String
  public let clientName: String
  public let grantID: UUID?
  public let tool: String
  public let outcome: AgentAuditOutcome
  public let matterIDs: [String]
  public let byteCount: Int

  public init(
    id: Int64 = 0, at: Date, clientKey: String, clientName: String, grantID: UUID?,
    tool: String, outcome: AgentAuditOutcome, matterIDs: [String], byteCount: Int
  ) {
    self.id = id
    self.at = at
    self.clientKey = clientKey
    self.clientName = clientName
    self.grantID = grantID
    self.tool = tool
    self.outcome = outcome
    self.matterIDs = matterIDs
    self.byteCount = byteCount
  }
}

/// A proposal waiting in the Agent 收件箱 (`agent_inbox`). Accepting it
/// makes a user item whose source is `agent:<client name>`; nothing is filed
/// before that. Once decided, the text leaves this row.
public struct AgentInboxProposal: Equatable, Sendable, Identifiable {
  public enum State: String, Sendable {
    case pending
    case accepted
    case rejected
  }

  public let proposalID: UUID
  public let clientKey: String
  public let clientName: String
  public let createdAt: Date
  public let title: String
  public let text: String
  public let matterHint: String
  public var state: State
  public var resolvedAt: Date?
  public var itemID: SessionID?

  public var id: UUID { proposalID }

  public init(
    proposalID: UUID = UUID(), clientKey: String, clientName: String, createdAt: Date,
    title: String, text: String, matterHint: String, state: State = .pending,
    resolvedAt: Date? = nil, itemID: SessionID? = nil
  ) {
    self.proposalID = proposalID
    self.clientKey = clientKey
    self.clientName = clientName
    self.createdAt = createdAt
    self.title = title
    self.text = text
    self.matterHint = matterHint
    self.state = state
    self.resolvedAt = resolvedAt
    self.itemID = itemID
  }

  /// The source label of the item it becomes: never the owner's own words.
  public static func sourceName(clientName: String) -> String {
    let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
    return "agent:" + (name.isEmpty ? "未知" : String(name.prefix(60)))
  }

  /// The item's text: the title (when given) on its own first line.
  public var itemText: String {
    let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return heading.isEmpty ? text : heading + "\n\n" + text
  }
}

/// The library's agent records. Local only: never sent, never in a portable
/// archive.
public protocol AgentAccessRecordStore: Sendable {
  func agentGrants() async throws -> [AgentGrantRecord]
  func saveAgentGrant(_ grant: AgentGrantRecord) async throws
  /// Deletes the grant and its matter approvals.
  func deleteAgentGrant(_ grantID: UUID) async throws
  /// Matter ID → allowed, for "读新的一件事时先问我".
  func agentMatterDecisions(grantID: UUID) async throws -> [String: Bool]
  func recordAgentMatterDecision(grantID: UUID, matterID: String, allowed: Bool, at: Date)
    async throws
  func appendAgentAudit(_ record: AgentAuditRecord) async throws
  /// Newest first; `clientKey` filters to one client.
  func agentAudit(clientKey: String?, limit: Int) async throws -> [AgentAuditRecord]
  func addAgentProposal(_ proposal: AgentInboxProposal) async throws
  func agentProposals(includeDecided: Bool) async throws -> [AgentInboxProposal]
  /// Marks a proposal decided and drops its text and title.
  func resolveAgentProposal(
    _ proposalID: UUID, state: AgentInboxProposal.State, itemID: SessionID?, at: Date
  ) async throws
}
