import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// AGENT-CONTRACT §4, in process: conformance, consent, scope, expiry,
/// revocation, masking, audit without content, and proposals that never
/// file anything.
final class AgentAccessServiceTests: XCTestCase {
  private var owner: ScriptedOwner!
  private var records: MemoryAgentRecords!
  private var secrets: MemoryAgentGrantSecretStore!
  private var clock: MutableClock!

  override func setUp() async throws {
    owner = ScriptedOwner()
    records = MemoryAgentRecords()
    secrets = MemoryAgentGrantSecretStore()
    clock = MutableClock(AgentFixture.now)
  }

  private func service(
    snapshot: AgentMemorySnapshot? = nil, timeout: Duration = .seconds(5)
  ) throws -> AgentAccessService {
    let clock = clock!
    return AgentAccessService(
      memory: FixedMemory(snapshot: try snapshot ?? AgentFixture.snapshot()), records: records,
      secrets: secrets, consent: owner,
      configuration: .init(consentTimeout: timeout, denialCooldown: 60),
      timeZone: AgentFixture.timeZone, clock: { clock.now })
  }

  // MARK: Conformance

  func testInitializeListAndCallEveryTool() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal", "lab"], propose: true))
    let client = await AgentTestClient(service: service)
    let initialize = await client.request(
      "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]])
    XCTAssertEqual(initialize["result"]?["protocolVersion"], "2025-06-18")
    XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "mindloom")
    XCTAssertNotNil(initialize["result"]?["capabilities"]?["tools"])
    XCTAssertNotNil(initialize["result"]?["capabilities"]?["resources"])
    let unknownVersion = await client.request("initialize", ["protocolVersion": "1999-01-01"])
    XCTAssertEqual(
      unknownVersion["result"]?["protocolVersion"]?.stringValue,
      MCPServerInfo.supportedProtocolVersions[0])
    let tools = await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertEqual(
      tools.compactMap { $0["name"]?.stringValue }, AgentTool.allCases.map(\.rawValue))
    for tool in tools {
      XCTAssertEqual(tool["inputSchema"]?["type"], "object")
      XCTAssertNotNil(tool["description"]?.stringValue)
    }
    let value1 = await client.request("ping")["result"]
    XCTAssertEqual(value1, [:])

    let search = await client.call("search_matters", ["query": "Twin"])
    XCTAssertFalse(search.isErrorResult, search.text)
    XCTAssertEqual(search.matterIDs, [AgentFixture.twin, AgentFixture.openDay])
    XCTAssertTrue(search.text.hasPrefix(AgentCopy.dataHeader))

    let matter = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(matter.isErrorResult, matter.text)
    XCTAssertTrue(matter.text.contains(AgentCopy.dataHeader))
    XCTAssertTrue(matter.text.contains("[条目 \(AgentFixture.items[0].uuidString)]"))
    XCTAssertTrue(matter.text.contains("\n> 韩策："), matter.text)
    XCTAssertTrue(matter.text.contains("[计划] 周五前跑完第三组（\(AgentFixture.day(2))）"))
    XCTAssertTrue(matter.text.contains("绳：科研"))
    let json = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "format": "json"])
    XCTAssertEqual(json["structuredContent"]?["items"]?.arrayValue?.count, 3)
    XCTAssertEqual(try JSONValue.parse(json.text), json["structuredContent"])

    let deadlines = await client.call("list_deadlines", ["days": 14])
    XCTAssertEqual(
      deadlines["structuredContent"]?["deadlines"]?.arrayValue?.compactMap {
        $0["matter_id"]?.stringValue
      }, [AgentFixture.labWeekly, AgentFixture.twin, AgentFixture.moving, AgentFixture.openDay])
    let recent = await client.call("list_recent", ["days": 1])
    XCTAssertEqual(
      recent.matterIDs,
      [AgentFixture.labWeekly, AgentFixture.twin, AgentFixture.openDay, AgentFixture.moving])
    let person = await client.call("get_person", ["name": "林晓"])
    XCTAssertFalse(person.isErrorResult, person.text)
    XCTAssertEqual(person["structuredContent"]?["quotes"]?.arrayValue?.isEmpty, false)
    let proposal = await client.call("add_to_inbox", ["text": "交接说明正文", "title": "交接"])
    XCTAssertEqual(proposal["structuredContent"]?["state"], "pending")

    let resources = await client.request("resources/list")["result"]?["resources"]?.arrayValue ?? []
    XCTAssertEqual(resources.count, 4)
    let read = await client.request(
      "resources/read", ["uri": .string(AgentResource.uri(matterID: AgentFixture.twin))])
    XCTAssertEqual(
      read["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue, matter.text)
    let templates = await client.request("resources/templates/list")
    XCTAssertEqual(
      templates["result"]?["resourceTemplates"]?.arrayValue?.first?["uriTemplate"],
      "mindloom://matter/{id}")

    let unknown = await client.request("tools/call", ["name": "delete_everything"])
    XCTAssertEqual(unknown["error"]?["code"]?.intValue, Int64(MCPErrorCode.invalidParams))
    let method = await client.request("sampling/createMessage")
    XCTAssertEqual(method["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    let bad = await client.call("list_deadlines", ["days": 99])
    XCTAssertEqual(bad.errorCode, "invalid_arguments")
  }

  // MARK: Consent

  func testUnknownClientNeedsConsentAndIsAskedOnce() async throws {
    let service = try service()
    let client = await AgentTestClient(service: service)
    // Listing tools needs nothing.
    let tools = await client.request("tools/list")
    XCTAssertNotNil(tools["result"])
    let consentCount = await owner.consentRequests.count
    XCTAssertEqual(consentCount, 0)
    await owner.queue(allowAll())
    let first = await client.call("search_matters", ["query": "Twin"])
    XCTAssertFalse(first.isErrorResult, first.text)
    let requests = await owner.consentRequests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.client.displayName, "Claude Code")
    XCTAssertEqual(requests.first?.client.path, "/Users/test/.local/share/claude/versions/*")
    XCTAssertEqual(requests.first?.options.spaces.map(\.id), ["personal", "lab"])
    _ = await client.call("list_recent")
    let count = await owner.consentRequests.count
    XCTAssertEqual(count, 1)
    // After an update the version folder changes; it is the same client.
    let updated = await AgentTestClient(
      service: service, path: "/Users/test/.local/share/claude/versions/2.1.300")
    let again = await updated.call("search_matters", ["query": "Twin"])
    XCTAssertFalse(again.isErrorResult)
    let afterUpdate = await owner.consentRequests.count
    XCTAssertEqual(afterUpdate, 1)
    // Another program with the same name is another client.
    let other = await AgentTestClient(service: service, path: "/tmp/fake/claude")
    await owner.queue(.deny)
    let refused = await other.call("search_matters", ["query": "Twin"])
    XCTAssertEqual(refused.errorCode, "denied")
    XCTAssertEqual(refused.text, AgentCopy.denied)
  }

  func testDenialIsAClearErrorAndNotAskedAgainAtOnce() async throws {
    let service = try service()
    let client = await AgentTestClient(service: service)
    await owner.queue(.deny)
    let denied = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(denied.isErrorResult)
    XCTAssertEqual(denied.errorCode, "denied")
    let resource = await client.request("resources/list")
    XCTAssertEqual(resource["error"]?["code"]?.intValue, Int64(MCPErrorCode.notAllowed))
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 1)
    // Closing the sheet without an answer is not a yes either.
    let second = await AgentTestClient(
      service: service, name: "codex-mcp-client", path: "/opt/codex")
    await owner.queue(nil)
    let closed = await second.call("list_recent")
    XCTAssertEqual(closed.errorCode, "denied")
  }

  func testAnUnansweredSheetIsPendingAndALaterAnswerCounts() async throws {
    let service = try service(timeout: .milliseconds(100))
    let client = await AgentTestClient(service: service)
    let pending = await client.call("search_matters", ["query": "Twin"])
    XCTAssertEqual(pending.errorCode, "pending")
    XCTAssertEqual(pending.text, AgentCopy.pending)
    await owner.queue(allowAll())
    try await Task.sleep(for: .milliseconds(100))
    let later = await client.call("search_matters", ["query": "Twin"])
    XCTAssertFalse(later.isErrorResult, later.text)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 1)
  }

  // MARK: Scope

  func testMattersOutsideTheScopeAreInvisibleEverywhere() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal"], range: .ropes(["r-research"])))
    let client = await AgentTestClient(service: service)
    let outside = AgentFixture.outside
    let hidden = await client.call("search_matters", ["query": .string(outside)])
    XCTAssertEqual(hidden.matterIDs, [])
    XCTAssertFalse(hidden.serialized.contains(outside))
    let value2 = await client.call("search_matters", ["query": "开放日"]).matterIDs
    XCTAssertEqual(value2, [])
    let value3 = await client.call("search_matters", ["query": "Twin"]).matterIDs
    XCTAssertEqual(value3, [AgentFixture.twin])
    for matter in [AgentFixture.openDay, AgentFixture.labWeekly, AgentFixture.moving] {
      let read = await client.call("get_matter", ["id": .string(matter)])
      XCTAssertEqual(read.errorCode, "not_found", matter)
      XCTAssertEqual(read.text, AgentCopy.notFound)
      let resource = await client.request(
        "resources/read", ["uri": .string(AgentResource.uri(matterID: matter))])
      XCTAssertEqual(resource["error"]?["code"]?.intValue, Int64(MCPErrorCode.resourceNotFound))
    }
    // Not found reads the same whether the matter exists or not.
    let value4 = await client.call("get_matter", ["id": "E-NOPE"]).text
    let value5 = await client.call("get_matter", ["id": .string(AgentFixture.labWeekly)]).text
    XCTAssertEqual(
      value4,
      value5)
    let deadlines = await client.call("list_deadlines", ["days": 30])
    XCTAssertEqual(
      deadlines["structuredContent"]?["deadlines"]?.arrayValue?.compactMap {
        $0["matter_id"]?.stringValue
      },
      [AgentFixture.twin])
    let value6 = await client.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(value6, [AgentFixture.twin])
    let person = await client.call("get_person", ["name": "韩策"])
    XCTAssertEqual(person.matterIDs, [AgentFixture.twin])
    XCTAssertFalse(person.serialized.contains(outside))
    let resources = await client.request("resources/list")["result"]?["resources"]?.arrayValue ?? []
    XCTAssertEqual(resources.compactMap { $0["name"]?.stringValue }, [AgentFixture.twin])
  }

  func testSpaceAndMatterScopes() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["lab"]))
    let lab = await AgentTestClient(
      service: service, name: "cursor-vscode", path: "/Applications/Cursor.app/x")
    let value7 = await lab.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(value7, [AgentFixture.labWeekly])
    let value8 = await lab.call("list_recent", ["days": 14, "space": "我的"]).matterIDs
    XCTAssertEqual(
      value8, [])
    await owner.queue(
      allowAll(spaces: ["personal", "lab"], range: .matters([AgentFixture.moving])))
    let one = await AgentTestClient(service: service, name: "codex-mcp-client", path: "/opt/codex")
    let value9 = await one.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(value9, [AgentFixture.moving])
    let value10 = await one.call("get_person", ["name": "韩策"]).errorCode
    XCTAssertEqual(value10, "not_found")
  }

  // MARK: Expiry and revocation

  func testTodayGrantExpiresAtMidnight() async throws {
    let service = try service()
    await owner.queue(allowAll(duration: .today))
    let client = await AgentTestClient(service: service)
    let value11 = await client.call("list_recent").isErrorResult
    XCTAssertFalse(value11)
    let stored = await records.grants
    XCTAssertEqual(stored.count, 1)
    // 10:00 → 23:59 the same day: still allowed.
    clock.advance(13 * 3_600 + 59 * 60)
    let value12 = await client.call("list_recent").isErrorResult
    XCTAssertFalse(value12)
    // Past midnight: the grant is gone and the owner is asked again.
    clock.advance(2 * 60)
    await owner.queue(.deny)
    let expired = await client.call("list_recent")
    XCTAssertEqual(expired.errorCode, "denied")
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 2)
    let left = await records.grants
    XCTAssertEqual(left.count, 0)
    XCTAssertEqual(secrets.count, 0)
  }

  func testOnceLastsForTheConnectionOnly() async throws {
    let service = try service()
    await owner.queue(allowAll(duration: .once))
    let client = await AgentTestClient(service: service)
    let value13 = await client.call("list_recent").isErrorResult
    XCTAssertFalse(value13)
    let stored = await records.grants
    XCTAssertEqual(stored, [], "这一次 is never written to the library")
    let value14 = await service.grants().count
    XCTAssertEqual(value14, 1)
    await client.close()
    let value15 = await service.grants().count
    XCTAssertEqual(value15, 0)
    let next = await AgentTestClient(service: service)
    await owner.queue(.deny)
    let value16 = await next.call("list_recent").errorCode
    XCTAssertEqual(value16, "denied")
  }

  func testRevocationTakesEffectOnTheNextCall() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let value17 = await client.call("list_recent").isErrorResult
    XCTAssertFalse(value17)
    let grants = await service.grants()
    XCTAssertEqual(grants.count, 1)
    XCTAssertEqual(secrets.count, 1)
    await service.revoke(grants[0].grantID)
    XCTAssertEqual(secrets.count, 0)
    let stored = await records.grants
    XCTAssertEqual(stored, [])
    await owner.queue(.deny)
    let value18 = await client.call("list_recent").errorCode
    XCTAssertEqual(value18, "denied")
  }

  func testAGrantEditedInTheLibraryOrMissingItsSecretIsNoGrant() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal"]))
    let client = await AgentTestClient(service: service)
    let value19 = await client.call("list_recent").isErrorResult
    XCTAssertFalse(value19)
    // Someone widens the scope in the database: the MAC no longer matches.
    await records.tamperFirstGrant()
    await owner.queue(.deny)
    let value20 = await client.call("search_matters", ["query": "实验室"]).errorCode
    XCTAssertEqual(value20, "denied")
    let left = await records.grants
    XCTAssertEqual(left, [])
    // A grant whose Keychain secret is gone is no grant either.
    let second = await AgentTestClient(
      service: service, name: "codex-mcp-client", path: "/opt/codex")
    await owner.queue(allowAll())
    let value21 = await second.call("list_recent").isErrorResult
    XCTAssertFalse(value21)
    let storedGrants = await records.grants
    let grant = try XCTUnwrap(storedGrants.first)
    try secrets.delete(for: grant.grantID)
    await owner.queue(.deny)
    let value22 = await second.call("list_recent").errorCode
    XCTAssertEqual(value22, "denied")
    // A Keychain that cannot be read fails closed.
    let third = await AgentTestClient(
      service: service, name: "claude-ai", path: "/Applications/Claude.app/x")
    await owner.queue(allowAll())
    let value23 = await third.call("list_recent").isErrorResult
    XCTAssertFalse(value23)
    secrets.failReads = true
    let value24 = await third.call("list_recent").errorCode
    XCTAssertEqual(value24, "unavailable")
  }

  // MARK: Masking

  func testNumbersAreMaskedByDefaultAndShownWhenGranted() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let masked = await AgentTestClient(service: service)
    let text = await masked.call("get_matter", ["id": .string(AgentFixture.twin)])
    for sentinel in [AgentFixture.phone, AgentFixture.email] {
      XCTAssertFalse(text.serialized.contains(sentinel), sentinel)
    }
    XCTAssertTrue(text.text.contains("〔手机号·"))
    XCTAssertTrue(text.text.contains("〔邮箱·"))
    XCTAssertEqual(text["structuredContent"]?["numbers_masked"], true)
    let json = await masked.call(
      "get_matter", ["id": .string(AgentFixture.twin), "format": "json"])
    XCTAssertFalse(json.serialized.contains(AgentFixture.phone))
    XCTAssertEqual(json["structuredContent"]?["numbers_masked"], true)
    let person = await masked.call("get_person", ["name": "韩策"])
    XCTAssertFalse(person.serialized.contains(AgentFixture.phone))

    await owner.queue(allowAll(numbers: true))
    let raw = await AgentTestClient(service: service, name: "codex-mcp-client", path: "/opt/codex")
    let original = await raw.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(original.text.contains(AgentFixture.phone))
    let value25 = await raw.call(
      "get_matter", ["id": .string(AgentFixture.twin), "format": "json"])
    XCTAssertEqual(
      (value25)[
        "structuredContent"]?["numbers_masked"], false)

    // Placeholders are keyed per grant: two agents cannot join theirs.
    await owner.queue(allowAll())
    let third = await AgentTestClient(service: service, name: "cursor-vscode", path: "/opt/cursor")
    let other = await third.call("get_matter", ["id": .string(AgentFixture.twin)])
    let tagA = PrivacyUnmask.placeholders(in: text.text).first { $0.hasPrefix("〔手机号·") }
    let tagB = PrivacyUnmask.placeholders(in: other.text).first { $0.hasPrefix("〔手机号·") }
    XCTAssertNotNil(tagA)
    XCTAssertNotEqual(tagA, tagB)
  }

  // MARK: Audit

  func testEveryCallIsAuditedWithoutContent() async throws {
    let service = try service(timeout: .milliseconds(50))
    let client = await AgentTestClient(service: service)
    _ = await client.call("search_matters", ["query": "Twin 真机"])  // pending
    await owner.queue(allowAll(propose: true))
    try await Task.sleep(for: .milliseconds(80))
    _ = await client.call("search_matters", ["query": "Twin 真机"])
    _ = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    _ = await client.call("get_matter", ["id": .string(AgentFixture.labWeekly)])
    _ = await client.call("get_person", ["name": "韩策"])
    _ = await client.call(
      "add_to_inbox", ["text": .string("SENTINEL-PROPOSAL \(AgentFixture.phone)")])
    _ = await client.request("resources/list")
    _ = await client.request(
      "resources/read", ["uri": .string(AgentResource.uri(matterID: AgentFixture.twin))])
    let rows = await records.audit
    XCTAssertEqual(rows.count, 8)
    XCTAssertEqual(
      rows.map(\.tool),
      [
        "search_matters", "search_matters", "get_matter", "get_matter", "get_person",
        "add_to_inbox", "resources/list", "resources/read",
      ])
    // The lab matter is outside a 我的-only grant: not found.
    XCTAssertEqual(
      rows.map(\.outcome),
      [.pending, .allowed, .allowed, .notFound, .allowed, .allowed, .allowed, .allowed])
    XCTAssertEqual(rows[3].matterIDs, [])
    XCTAssertEqual(rows[2].matterIDs, [AgentFixture.twin])
    XCTAssertTrue(rows[2].byteCount > 500)
    XCTAssertTrue(rows.allSatisfy { $0.clientName == "Claude Code" })
    let dump = rows.map {
      [$0.clientKey, $0.clientName, $0.tool, $0.outcome.rawValue, $0.matterIDs.joined()].joined(
        separator: "|")
    }.joined(separator: "\n")
    for content in [
      "Twin", "真机", AgentFixture.phone, "SENTINEL", "韩策", "实验", AgentFixture.outside,
    ] {
      XCTAssertFalse(dump.contains(content), content)
    }
  }

  // MARK: Proposals

  func testAddToInboxOnlyProposes() async throws {
    let service = try service()
    await owner.queue(allowAll(propose: false))
    let readOnly = await AgentTestClient(service: service)
    let refused = await readOnly.call("add_to_inbox", ["text": "不该进来"])
    XCTAssertEqual(refused.errorCode, "read_only")
    XCTAssertEqual(refused.text, AgentCopy.proposeNotAllowed)
    let none = await records.inbox
    XCTAssertEqual(none, [])

    await owner.queue(allowAll(propose: true))
    let writer = await AgentTestClient(
      service: service, name: "codex-mcp-client", path: "/opt/codex")
    let ok = await writer.call(
      "add_to_inbox",
      ["text": "第一行\n第二行", "title": " 交接说明 ", "matter_hint": .string(AgentFixture.twin)])
    XCTAssertFalse(ok.isErrorResult, ok.text)
    let inbox = await records.inbox
    XCTAssertEqual(inbox.count, 1)
    XCTAssertEqual(inbox.first?.state, .pending)
    XCTAssertEqual(inbox.first?.text, "第一行\n第二行")
    XCTAssertEqual(inbox.first?.title, "交接说明")
    XCTAssertEqual(inbox.first?.clientName, "Codex")
    XCTAssertEqual(
      AgentInboxProposal.sourceName(clientName: inbox.first!.clientName), "agent:Codex")
    let notified = await owner.proposals.count
    XCTAssertEqual(notified, 1)
    let tooLong = await writer.call(
      "add_to_inbox",
      ["text": .string(String(repeating: "长", count: AgentTool.maximumInboxTextCharacters + 1))])
    XCTAssertEqual(tooLong.errorCode, "invalid_arguments")
    let value26 = await writer.call("add_to_inbox", ["text": "  \n "]).errorCode
    XCTAssertEqual(value26, "invalid_arguments")
  }

  // MARK: Ask for each new matter

  func testNewMattersAreApprovedOneByOne() async throws {
    let service = try service(timeout: .milliseconds(200))
    await owner.queue(allowAll(spaces: ["personal", "lab"], ask: true))
    let client = await AgentTestClient(service: service)
    await owner.queueApproval([AgentFixture.twin: true, AgentFixture.openDay: false])
    let search = await client.call("search_matters", ["query": "Twin"])
    XCTAssertEqual(search.matterIDs, [AgentFixture.twin])
    let asked = await owner.approvalRequests
    XCTAssertEqual(asked.count, 1)
    XCTAssertEqual(asked.first?.matters.map(\.id), [AgentFixture.twin, AgentFixture.openDay])
    XCTAssertEqual(asked.first?.matters.first?.title, "Twin-7 真机实验")
    // Approved: read without asking; refused: stays closed.
    let value27 = await client.call("get_matter", ["id": .string(AgentFixture.twin)]).isErrorResult
    XCTAssertFalse(value27)
    let value28 = await client.call("get_matter", ["id": .string(AgentFixture.openDay)]).errorCode
    XCTAssertEqual(value28, "denied")
    let count = await owner.approvalRequests.count
    XCTAssertEqual(count, 1)
    // Not answered in time: waits, and says so.
    let waiting = await client.call("get_matter", ["id": .string(AgentFixture.labWeekly)])
    XCTAssertEqual(waiting.errorCode, "pending")
    let recent = await client.call("list_recent", ["days": 14])
    XCTAssertEqual(recent.matterIDs, [AgentFixture.twin])
    XCTAssertTrue(recent.text.contains("要等主人在织机里批准"))
    // Resources name only approved matters and never ask.
    let resources = await client.request("resources/list")["result"]?["resources"]?.arrayValue ?? []
    XCTAssertEqual(resources.compactMap { $0["name"]?.stringValue }, [AgentFixture.twin])
  }

  func testUnavailableLibraryIsAFriendlyError() async throws {
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: nil), records: records, secrets: secrets, consent: owner,
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let result = await client.call("list_recent")
    XCTAssertEqual(result.errorCode, "unavailable")
    XCTAssertEqual(result.text, AgentCopy.unavailable)
  }
}
