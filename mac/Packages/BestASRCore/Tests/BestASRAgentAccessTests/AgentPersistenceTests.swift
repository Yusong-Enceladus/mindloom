import BestASRAgentAccess
import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// The library's agent tables (schema v25) through the real store.
final class AgentPersistenceTests: XCTestCase {
  func testGrantsDecisionsAuditAndInboxRoundTrip() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: url)
    let terms = AgentGrantTerms(
      spaces: ["personal", "lab"], range: .ropes(["r-research"]), canPropose: true,
      duration: .today, showNumbers: false, askForNewMatters: true)
    let grant = AgentGrantRecord(
      grantID: UUID(), clientKey: "abc", clientName: "Claude Code", clientPath: "/x/*",
      terms: terms, createdAt: Date(timeIntervalSince1970: 1_000),
      expiresAt: Date(timeIntervalSince1970: 2_000), mac: "m")
    try await store.saveAgentGrant(grant)
    let loaded = try await store.agentGrants()
    XCTAssertEqual(loaded, [grant])
    XCTAssertEqual(loaded.first?.canonicalText, grant.canonicalText)
    // 这一次 is never written.
    let once = AgentGrantRecord(
      grantID: UUID(), clientKey: "abc", clientName: "x", clientPath: "/x",
      terms: AgentGrantTerms(duration: .once),
      createdAt: Date(), expiresAt: nil, mac: "")
    try await store.saveAgentGrant(once)
    let afterOnce = try await store.agentGrants()
    XCTAssertEqual(afterOnce.count, 1)

    try await store.recordAgentMatterDecision(
      grantID: grant.grantID, matterID: "E-1", allowed: true, at: Date())
    try await store.recordAgentMatterDecision(
      grantID: grant.grantID, matterID: "E-2", allowed: false, at: Date())
    let decisions = try await store.agentMatterDecisions(grantID: grant.grantID)
    XCTAssertEqual(decisions, ["E-1": true, "E-2": false])
    try await store.deleteAgentGrant(grant.grantID)
    let noGrants = try await store.agentGrants()
    XCTAssertEqual(noGrants, [])
    let noDecisions = try await store.agentMatterDecisions(grantID: grant.grantID)
    XCTAssertEqual(noDecisions, [:])
    // A decision for a revoked grant is not kept.
    try await store.recordAgentMatterDecision(
      grantID: grant.grantID, matterID: "E-3", allowed: true, at: Date())
    let stale = try await store.agentMatterDecisions(grantID: grant.grantID)
    XCTAssertEqual(stale, [:])

    for (index, client) in ["a", "b", "a"].enumerated() {
      try await store.appendAgentAudit(
        AgentAuditRecord(
          at: Date(timeIntervalSince1970: Double(index)), clientKey: client, clientName: client,
          grantID: nil, tool: "get_matter", outcome: .allowed, matterIDs: ["E-\(index)"],
          byteCount: 10 * index))
    }
    let all = try await store.agentAudit(clientKey: nil, limit: 10)
    XCTAssertEqual(all.map(\.matterIDs), [["E-2"], ["E-1"], ["E-0"]])
    let onlyA = try await store.agentAudit(clientKey: "a", limit: 10)
    XCTAssertEqual(onlyA.count, 2)
    XCTAssertEqual(onlyA.first?.byteCount, 20)

    let proposal = AgentInboxProposal(
      clientKey: "a", clientName: "Codex", createdAt: Date(), title: "交接", text: "正文",
      matterHint: "E-1")
    try await store.addAgentProposal(proposal)
    let pending = try await store.agentProposals(includeDecided: false)
    XCTAssertEqual(pending.map(\.text), ["正文"])
    try await store.resolveAgentProposal(
      proposal.proposalID, state: .rejected, itemID: nil, at: Date())
    let open = try await store.agentProposals(includeDecided: false)
    XCTAssertEqual(open, [])
    let decided = try await store.agentProposals(includeDecided: true)
    XCTAssertEqual(decided.first?.state, .rejected)
    XCTAssertEqual(decided.first?.text, "", "the text leaves once decided")
    XCTAssertEqual(decided.first?.title, "")
    try await store.checkpointAndClose()

    // The agent tables are local: never among the portable tables, and no
    // item row was made by any of this.
    let queue = try DatabaseQueue(path: url.path)
    let sessions = try await queue.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions")
    }
    XCTAssertEqual(sessions, 0)
  }
}
