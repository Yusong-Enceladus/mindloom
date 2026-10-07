import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Darwin
import Foundation
import GRDB
import MindloomAgentProtocol
import XCTest

/// v12 phase B (B5 appendix C F1, F3, F8, F12; ALIGNMENT 用-3, 用-7, 用-8):
/// the switch, the helper gate, the change records, the search words and the
/// check build's pre-approval.
final class AgentV12Tests: XCTestCase {
  private func service() throws -> AgentAccessService {
    AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: ScriptedOwner(),
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
  }

  private func send(_ descriptor: Int32, _ value: JSONValue) {
    _ = AgentSocketIO.writeAll(descriptor, Data((value.serialized + "\n").utf8))
  }

  /// F1: with 允许其他 App 读 off, an agent's connection gets no session: the
  /// handshake works and every call says the switch is off. Nobody is asked.
  func testWithTheSwitchOffAnAgentIsToldAndNobodyIsAsked() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = ScriptedOwner()
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner, timeZone: AgentFixture.timeZone)
    let server = AgentSocketServer(
      dataRoot: root, service: service, gate: .anyProcessOfThisUser, agentsAllowed: { false })
    try server.start()
    defer { server.stop() }
    let descriptor = try AgentSocketIO.connect(path: server.socketURL.path)
    defer { close(descriptor) }
    send(
      descriptor,
      MCPMessage.request(
        id: 1, method: "initialize", params: ["clientInfo": ["name": "claude-code"]]))
    let hello = try JSONValue.parse(XCTUnwrap(readLine(descriptor)))
    XCTAssertEqual(hello["result"]?["serverInfo"]?["name"], "mindloom")
    send(
      descriptor,
      MCPMessage.request(
        id: 2, method: "tools/call", params: ["name": "today", "arguments": [:]]))
    let call = try JSONValue.parse(XCTUnwrap(readLine(descriptor)))
    XCTAssertEqual(call["result"]?.structured?["error"], "switched_off")
    XCTAssertEqual(
      call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, AgentCopy.switchedOff)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 0)
  }

  /// F8: a gate made for a helper admits that helper's code only; this test
  /// process is not it.
  func testTheGateAdmitsOnlyTheBundledHelpersCode() throws {
    let me = AgentPeer(uid: getuid(), pid: getpid())
    XCTAssertTrue(AgentHelperGate.anyProcessOfThisUser.admits(me))
    // A gate for another binary (`/bin/ls`, Apple's): not this process.
    let other = AgentHelperGate.bundled(helper: URL(fileURLWithPath: "/bin/ls"), appTeam: nil)
    XCTAssertFalse(other.admits(me))
    XCTAssertTrue(other.description.hasPrefix("cdhash H\""), other.description)
    // A helper that is missing: nobody.
    let missing = AgentHelperGate.bundled(
      helper: URL(fileURLWithPath: "/nonexistent/mindloom-mcp"), appTeam: nil)
    XCTAssertFalse(missing.admits(me))
  }

  /// F3: the card names who signed the program in plain words.
  func testWhoSignedItInPlainWords() {
    XCTAssertEqual(
      AgentCodeSigning.developerName(
        "Developer ID Application: Anthropic PBC (ANTHRTEAM1)", team: "ANTHRTEAM1"),
      "Anthropic PBC")
    XCTAssertEqual(
      AgentCodeSigning.developerName("Apple Development: Someone (ABCDE12345)", team: "ABCDE12345"),
      "Someone")
    let signed = AgentClientIdentity(
      name: "claude-code", path: "/Users/test/.local/share/claude/versions/2.1.3/claude",
      signer: "team:ANTHRTEAM1:com.anthropic.claude-code", signerName: "Anthropic PBC")
    XCTAssertEqual(signed.signerLabel, "Anthropic PBC 签名的程序")
    XCTAssertTrue(signed.whoLine.hasSuffix("versions/2.1.3/claude"), signed.whoLine)
    XCTAssertEqual(signed.path, "/Users/test/.local/share/claude/versions/*/claude")
    // The developer's name is for the eyes only: it never changes who it is.
    XCTAssertEqual(
      signed.key,
      AgentClientIdentity(
        name: "claude-code", path: "/Users/test/.local/share/claude/versions/2.1.4/claude",
        signer: "team:ANTHRTEAM1:com.anthropic.claude-code"
      ).key)
    XCTAssertEqual(
      AgentClientIdentity(name: "x", path: "/tmp/x").signerLabel, "没有开发者签名的程序")
  }

  /// The agent's search is 历史's engine (v12 integration): words in any
  /// order, width and case folded, a question's particles carry nothing.
  func testSearchWords() async {
    let documents = [
      AgentSearchDocument(
        matterID: "E1", title: "Twin-7 真机实验", status: "", people: [], steps: [], items: [],
        updatedAt: nil),
      AgentSearchDocument(
        matterID: "E2", title: "实验室周会", status: "", people: [], steps: [], items: [],
        updatedAt: nil),
    ]
    let engine = AgentRecordSearch()
    func ids(_ query: String) async -> [String] {
      await engine.search(query, in: documents, limit: 5, clock: SearchClock()).hits.map(\.matterID)
    }
    let reordered = await ids("真机实验 Twin-7")
    XCTAssertEqual(reordered, ["E1"])
    let wide = await ids("ＴＷＩＮ")
    XCTAssertEqual(wide, ["E1"])
    let particles = await ids("的了吗")
    XCTAssertEqual(particles, [])
    let weekly = await ids("周会")
    XCTAssertEqual(weekly, ["E2"])
  }

  /// The check build's pre-approval spec.
  func testPreapprovalSpec() throws {
    let spec = try XCTUnwrap(
      AgentPreapproval.parse("client=claude-code;path=/x;range=all;change=1;duration=always"))
    XCTAssertEqual(spec.clientName, "claude-code")
    XCTAssertEqual(spec.terms.range, .all)
    XCTAssertEqual(spec.terms.spaces, ["personal"])
    XCTAssertTrue(spec.terms.canChange)
    XCTAssertEqual(spec.terms.duration, .always)
    XCTAssertFalse(spec.terms.showNumbers)
    let narrow = try XCTUnwrap(
      AgentPreapproval.parse("client=codex;path=/x;range=matters:E1,E2;spaces=lab;numbers=1"))
    XCTAssertEqual(narrow.terms.range, .matters(["E1", "E2"]))
    XCTAssertEqual(narrow.terms.spaces, ["personal", "lab"])
    XCTAssertEqual(narrow.terms.duration, .once)
    XCTAssertFalse(narrow.terms.canChange)
    XCTAssertNil(AgentPreapproval.parse("range=all"))
    XCTAssertNil(AgentPreapproval.parse("client=x;duration=forever"))
    let request = AgentConsentRequest(
      client: AgentClientIdentity(name: "claude-code", path: "/x"),
      options: AgentConsentOptions(spaces: [.personal], ropes: [], matters: []),
      requestedAt: Date())
    XCTAssertEqual(spec.answer(request), spec.terms)
    XCTAssertNil(narrow.answer(request))
  }

  /// Review v12-B #13 (regression): the pre-approval is read from the
  /// launch arguments only (a `defaults write` cannot leave one behind), and
  /// it answers only the program it names, not any program that runs the
  /// bundled helper under that name.
  func testPreapprovalComesFromTheLaunchAndMatchesTheProgram() throws {
    let program =
      "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
    let spec = "client=claude-session-e2e;path=\(program);script=/tmp/drive.py;range=all;change=1"
    XCTAssertEqual(
      AgentPreapproval.launchSpec(arguments: [
        "app", "-MindloomNoArm", "YES", "-MindloomAgentTestGrant", spec,
      ]),
      spec)
    XCTAssertNil(AgentPreapproval.launchSpec(arguments: ["app"]))
    XCTAssertNil(AgentPreapproval.launchSpec(arguments: ["app", "-MindloomAgentTestGrant"]))
    XCTAssertNil(
      AgentPreapproval.launchSpec(
        arguments: ["app", "-MindloomAgentTestGrant", spec, "-MindloomAgentTestGrant", spec]))
    XCTAssertNil(AgentPreapproval.launchSpec(arguments: ["app", "--MindloomAgentTestGrant", spec]))
    // No program, no pre-approval.
    XCTAssertNil(AgentPreapproval.parse("client=claude-session-e2e;range=all;change=1"))
    XCTAssertNil(AgentPreapproval.parse("client=x;path=relative/python;range=all"))

    let approval = try XCTUnwrap(AgentPreapproval.parse(spec))
    func request(name: String, path: String, script: String?) -> AgentConsentRequest {
      AgentConsentRequest(
        client: AgentClientIdentity(name: name, path: path, script: script),
        options: AgentConsentOptions(spaces: [.personal], ropes: [], matters: []),
        requestedAt: Date())
    }
    XCTAssertNotNil(
      approval.answer(request(name: "claude-session-e2e", path: program, script: "/tmp/drive.py")))
    // Another program giving the same name gets nothing.
    XCTAssertNil(
      approval.answer(request(name: "claude-session-e2e", path: "/usr/local/bin/x", script: nil)))
    XCTAssertNil(
      approval.answer(request(name: "claude-session-e2e", path: program, script: "/tmp/other.py")))
    XCTAssertNil(approval.answer(request(name: "codex", path: program, script: "/tmp/drive.py")))
  }

  /// The v27 migration rebuilds `agent_audit` (to take `limited`) without
  /// losing a row, and a v26 library's grants stay as they were.
  func testAV26LibraryKeepsItsAuditThroughV27() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("v26.sqlite")
    let old = try DatabaseQueue(path: url.path)
    try BestASRPersistenceSchema.migrator().migrate(
      old, upTo: BestASRPersistenceSchema.userOrganizingMigrationID)
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO agent_audit (
            at, client_key, client_name, grant_id, tool, outcome, matter_ids_json, byte_count
          ) VALUES (5, 'k', 'Claude Code', NULL, 'get_matter', 'denied', '["E1"]', 0)
          """)
    }
    try old.close()
    let store = try GRDBDictationStore(databaseURL: url)
    let rows = try await store.agentAudit(clientKey: "k", limit: 10)
    XCTAssertEqual(rows.map(\.outcome), [.denied])
    XCTAssertEqual(rows.first?.matterIDs, ["E1"])
    try await store.appendAgentAudit(
      AgentAuditRecord(
        at: Date(), clientKey: "k", clientName: "Claude Code", grantID: nil, tool: "today",
        outcome: .limited, matterIDs: [], byteCount: 0))
    let after = try await store.agentAudit(clientKey: "k", limit: 10)
    XCTAssertEqual(after.map(\.outcome), [.limited, .denied])
    try await store.checkpointAndClose()
  }

  /// Review v12-B #2 (regression): a v26 grant row whose flag was set for
  /// 「可以提建议」 (v10's consent sheet) comes out of the v27 migration with
  /// 也可以改 off; a grant made afterwards keeps what the owner chose.
  func testAV26ProposeGrantLosesItsFlagThroughV27() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("v26.sqlite")
    let old = try DatabaseQueue(path: url.path)
    try BestASRPersistenceSchema.migrator().migrate(
      old, upTo: BestASRPersistenceSchema.userOrganizingMigrationID)
    let grantID = UUID()
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO agent_grants (
            grant_id, client_key, client_name, client_path, spaces_json, range_kind,
            range_ids_json, can_propose, duration, show_numbers, ask_new_matters,
            created_at, expires_at, mac
          ) VALUES (?, 'k', 'Claude Code', '/x', '["personal"]', 'all', '[]', 1, 'always', 0, 0,
                    1, NULL, 'm')
          """, arguments: [grantID.uuidString.lowercased()])
    }
    try old.close()
    let store = try GRDBDictationStore(databaseURL: url)
    let grants = try await store.agentGrants()
    XCTAssertEqual(grants.map(\.grantID), [grantID])
    XCTAssertEqual(grants.first?.terms.canChange, false)
    // After the migration, the flag means 也可以改 and is kept as chosen.
    var fresh = try XCTUnwrap(grants.first)
    fresh = AgentGrantRecord(
      grantID: UUID(), clientKey: "k2", clientName: "Codex", clientPath: "/y",
      terms: AgentGrantTerms(spaces: ["personal"], range: .all, canChange: true, duration: .today),
      createdAt: Date(), expiresAt: nil, mac: "m2")
    try await store.saveAgentGrant(fresh)
    let after = try await store.agentGrants()
    XCTAssertEqual(after.first { $0.clientKey == "k2" }?.terms.canChange, true)
    try await store.checkpointAndClose()
  }

  /// `agent_changes` (schema v27) through the real store: newest first, by
  /// client, undone once.
  func testChangeRecordsRoundTrip() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let first = AgentChangeRecord(
      at: Date(timeIntervalSince1970: 1_000), clientKey: "a", clientName: "Claude Code",
      grantID: UUID(), kind: .renameMatter, matterIDs: ["E1"], itemID: nil,
      payload: #"{"rename":{"eventID":"E1","from":"旧","to":"新"}}"#, summary: "把「旧」改名为「新」")
    let second = AgentChangeRecord(
      at: Date(timeIntervalSince1970: 2_000), clientKey: "b", clientName: "Codex", grantID: nil,
      kind: .addNote, matterIDs: [], itemID: "7B1E0000-0000-4000-8000-0000000000AA",
      payload: #"{"item_id":"7B1E0000-0000-4000-8000-0000000000AA"}"#, summary: "收进一条「x」")
    try await store.appendAgentChange(first)
    try await store.appendAgentChange(second)
    let all = try await store.agentChanges(clientKey: nil, limit: 10)
    XCTAssertEqual(all, [second, first])
    let mine = try await store.agentChanges(clientKey: "a", limit: 10)
    XCTAssertEqual(mine, [first])
    let undone = try await store.markAgentChangeUndone(
      first.changeID, at: Date(timeIntervalSince1970: 3_000))
    XCTAssertTrue(undone)
    let twice = try await store.markAgentChangeUndone(first.changeID, at: Date())
    XCTAssertFalse(twice)
    let after = try await store.agentChanges(clientKey: "a", limit: 10).first
    XCTAssertEqual(after?.state, .undone)
    XCTAssertEqual(after?.undoneAt, Date(timeIntervalSince1970: 3_000))
    // The audit takes the new outcome.
    try await store.appendAgentAudit(
      AgentAuditRecord(
        at: Date(), clientKey: "a", clientName: "Claude Code", grantID: nil, tool: "today",
        outcome: .limited, matterIDs: [], byteCount: 0))
    let audit = try await store.agentAudit(clientKey: "a", limit: 1)
    XCTAssertEqual(audit.first?.outcome, .limited)
  }
}
