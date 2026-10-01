import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// Regression tests for the v7 review of agent access (findings V7-A1–A5).
/// Synthetic data only.
final class AgentReviewFixTests: XCTestCase {
  private func service(
    _ snapshot: AgentMemorySnapshot, owner: ScriptedOwner,
    records: MemoryAgentRecords = MemoryAgentRecords(), timeout: Duration = .seconds(5)
  ) -> AgentAccessService {
    AgentAccessService(
      memory: FixedMemory(snapshot: snapshot), records: records,
      secrets: MemoryAgentGrantSecretStore(), consent: owner,
      configuration: .init(consentTimeout: timeout, denialCooldown: 60),
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
  }

  // MARK: - V7-A1: a split recording never names a matter outside the grant

  static let meeting = """
    虚构项目周会

    苗青禾(00:00:03):
    先说展会：展位定在二号馆，三米乘三米。

    欧阳帆(00:00:40):
    海报我周三前出两版。

    苗青禾(00:01:20):
    另一件事，复诊约在下周二，医生说要再查一次。

    欧阳帆(00:02:05):
    好，我陪你去。
    """

  /// One recording split over a matter the agent may read (秋季展会) and one it may not.
  private func splitMeeting() throws -> AgentMemorySnapshot {
    let base = AgentFixture.now.addingTimeInterval(-3_600)
    let meeting = SessionID(UUID(uuidString: "7B1E0000-0000-4000-8000-0000000000AA")!)
    let turns = try XCTUnwrap(MemoryTranscriptText.parse(Self.meeting)).turns
    let expo = MemoryItemSegment(
      itemID: meeting.rawValue.uuidString, segID: "s1", start: turns[0].start, end: turns[1].end,
      gist: "展会展位和海报")
    let clinic = MemoryItemSegment(
      itemID: meeting.rawValue.uuidString, segID: "s2", start: turns[2].start, end: turns[3].end,
      gist: "复诊安排")
    let record = MemoryItemRecord(
      sessionID: meeting, inputMode: .userItem, itemKind: .document, title: "周会.txt",
      startedAt: base, updatedAt: base, sourceBundleID: "com.tencent.meeting",
      sourceDisplayName: "腾讯会议", sourceIdentifier: "周会.txt", text: Self.meeting)
    let events = [
      MemoryEventSource(
        eventID: "ev-expo", origin: .spark, title: "秋季展会", statusLine: "", pinned: false,
        updatedAt: base, itemIDs: [meeting.rawValue.uuidString], personIDs: [], segments: [expo]),
      MemoryEventSource(
        eventID: "ev-clinic", origin: .spark, title: "苗青禾的肿瘤复诊", statusLine: "", pinned: false,
        updatedAt: base, itemIDs: [meeting.rawValue.uuidString], personIDs: [], segments: [clinic]),
    ]
    let projection = MemoryProjection(events: events, records: [record], now: AgentFixture.now)
    return AgentMemorySnapshot(projection: projection, timeZone: AgentFixture.timeZone)
  }

  func testGetMatterNeverNamesAMatterOutsideTheGrant() async throws {
    let owner = ScriptedOwner()
    let service = service(try splitMeeting(), owner: owner)
    await owner.queue(allowAll(range: .matters(["ev-expo"])))
    let client = await AgentTestClient(service: service)
    let search = await client.call("search_matters", ["query": "复诊"])
    XCTAssertEqual(search.matterIDs, [])
    for format in ["text", "json"] {
      let matter = await client.call("get_matter", ["id": "ev-expo", "format": .string(format)])
      XCTAssertFalse(matter.isErrorResult)
      XCTAssertFalse(matter.text.contains("肿瘤复诊"), "\(format): \(matter.text.prefix(600))")
      XCTAssertFalse(
        matter["structuredContent"]?.serialized.contains("肿瘤复诊") ?? true, format)
      XCTAssertTrue(matter.text.contains("展会展位和海报"), "the part's own note stays")
    }
  }

  func testAnInScopeSiblingIsNamedButNotWhenEachMatterWaitsForTheOwner() async throws {
    let owner = ScriptedOwner()
    let open = service(try splitMeeting(), owner: owner)
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: open)
    let matter = await client.call("get_matter", ["id": "ev-expo"])
    XCTAssertTrue(matter.text.contains("同一段记录还涉及：「苗青禾的肿瘤复诊」"))
    // "Ask me first": the other matter may be one the owner refuses; it is not named.
    let askingOwner = ScriptedOwner()
    let asking = service(try splitMeeting(), owner: askingOwner)
    await askingOwner.queue(allowAll(ask: true))
    await askingOwner.queueApproval(["EV-EXPO": true])
    let second = await AgentTestClient(service: asking)
    let shown = await second.call("get_matter", ["id": "ev-expo"])
    XCTAssertFalse(shown.isErrorResult, shown.text)
    XCTAssertFalse(shown.text.contains("肿瘤复诊"))
  }

  // MARK: - V7-A2: search cannot recover a masked number

  func testSearchCannotRecoverAMaskedNumber() async throws {
    let owner = ScriptedOwner()
    let service = service(try AgentFixture.snapshot(), owner: owner)
    await owner.queue(allowAll())  // numbers masked (the default)
    let client = await AgentTestClient(service: service)
    let matter = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(matter.text.contains(AgentFixture.phone))
    var known = "138"
    for _ in 0..<8 {
      var next: String?
      for digit in 0...9 where next == nil {
        let found = await client.call("search_matters", ["query": .string(known + "\(digit)")])
        if found.matterIDs.contains(AgentFixture.twin) { next = known + "\(digit)" }
      }
      guard let next else { break }
      known = next
    }
    XCTAssertNotEqual(known, AgentFixture.phone)
    XCTAssertEqual(known, "138", "not even one digit leaked")
    // A query that holds a whole number is refused, not answered.
    let whole = await client.call("search_matters", ["query": .string(AgentFixture.phone)])
    XCTAssertTrue(whole.isErrorResult)
    XCTAssertEqual(whole.errorCode, "invalid_arguments")
    // Words still find their matter.
    let words = await client.call("search_matters", ["query": "第三组"])
    XCTAssertEqual(words.matterIDs, [AgentFixture.twin])
  }

  func testWithNumbersShownSearchFindsThem() async throws {
    let owner = ScriptedOwner()
    let service = service(try AgentFixture.snapshot(), owner: owner)
    await owner.queue(allowAll(numbers: true))
    let client = await AgentTestClient(service: service)
    let found = await client.call("search_matters", ["query": .string(AgentFixture.phone)])
    XCTAssertFalse(found.isErrorResult)
    XCTAssertEqual(found.matterIDs, [AgentFixture.twin])
  }

  // MARK: - V7-A3: a name and a parent path are not an identity

  func testAnotherProcessCannotInheritAGrantByTellingTheSameName() async throws {
    let owner = ScriptedOwner()
    let service = service(try AgentFixture.snapshot(), owner: owner, timeout: .milliseconds(200))
    await owner.queue(allowAll())
    let claude = await AgentTestClient(service: service)
    _ = await claude.call("list_recent")
    // An unsigned binary dropped into the same version folder, same clientInfo name.
    let dropped = await AgentTestClient(
      service: service, name: "claude-code",
      path: "/Users/test/.local/share/claude/versions/9.9.9", signer: nil)
    let read = await dropped.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(read.isErrorResult)
    // A program signed by someone else at the same place.
    let otherTeam = await AgentTestClient(
      service: service, name: "claude-code",
      path: "/Users/test/.local/share/claude/versions/2.1.260",
      signer: "team:OTHERTEAM9:com.example.tool")
    let second = await otherTeam.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(second.isErrorResult)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 3, "each new program was shown to the owner")
    // A node script other than the one granted is another client too.
    let nodeOwner = ScriptedOwner()
    let nodeService = self.service(
      try AgentFixture.snapshot(), owner: nodeOwner, timeout: .milliseconds(200))
    await nodeOwner.queue(allowAll())
    let node = "/Users/test/.nvm/versions/node/v20.11.1/bin/node"
    let granted = await AgentTestClient(
      service: nodeService, path: node, signer: nil,
      script: "/Users/test/.nvm/versions/node/v20.11.1/lib/node_modules/@anthropic-ai/claude-code/cli.js")
    let grantedRead = await granted.call("list_recent")
    XCTAssertFalse(grantedRead.isErrorResult)
    let script = await AgentTestClient(
      service: nodeService, path: node, signer: nil, script: "/Users/test/Projects/other.js")
    let scriptRead = await script.call("list_recent")
    XCTAssertTrue(scriptRead.isErrorResult)
    // And the signed Claude Code after an update is still the same client.
    let updated = await AgentTestClient(
      service: service, path: "/Users/test/.local/share/claude/versions/2.2.0")
    let updatedRead = await updated.call("list_recent")
    XCTAssertFalse(updatedRead.isErrorResult)
  }

  // MARK: - V7-A4: no count or existence hints from matters not granted

  func testCountsAndPersonAnswersGiveNoHintOfRefusedMatters() async throws {
    let owner = ScriptedOwner()
    let service = service(try AgentFixture.snapshot(), owner: owner)
    await owner.queue(allowAll(spaces: ["personal", "lab"], ask: true))
    await owner.queueApproval([
      AgentFixture.twin.uppercased(): false, AgentFixture.labWeekly.uppercased(): false,
    ])
    let client = await AgentTestClient(service: service)
    let search = await client.call("search_matters", ["query": "韩策"])
    XCTAssertEqual(search.matterIDs, [])
    XCTAssertEqual(search["structuredContent"]?["total_matched"], .int(0))
    // 韩策 is only in refused matters: the same answer as someone unknown.
    let person = await client.call("get_person", ["name": "韩策"])
    let nobody = await client.call("get_person", ["name": "没有这个人"])
    XCTAssertEqual(person.errorCode, "not_found")
    XCTAssertEqual(person.text, nobody.text)
  }

  // MARK: - V7-A5: a revocation during a wait wins

  func testARevocationWhileACallWaitsForApprovalWins() async throws {
    let owner = ScriptedOwner()
    let service = service(try AgentFixture.snapshot(), owner: owner, timeout: .seconds(5))
    await owner.queue(allowAll(ask: true))
    let client = await AgentTestClient(service: service)
    // The first call creates the grant and waits on the matter approval.
    let call = Task { await client.call("get_matter", ["id": .string(AgentFixture.twin)]) }
    var grants: [AgentAccessService.GrantSummary] = []
    for _ in 0..<200 {
      let asked = await owner.approvalRequests
      if !grants.isEmpty, !asked.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
      grants = await service.grants()
    }
    let grant = try XCTUnwrap(grants.first)
    await service.revoke(grant.grantID)
    await owner.queueApproval([AgentFixture.twin.uppercased(): true])
    let result = await call.value
    XCTAssertTrue(result.isErrorResult)
    XCTAssertEqual(result.errorCode, "denied")
    XCTAssertFalse(result.text.contains("第三组"))
  }
}
