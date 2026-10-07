import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// AGENT-CONTRACT §4, in process: conformance, consent, scope, expiry,
/// revocation, masking, audit without content, and (v12) the change tools:
/// listed and run only with 也可以改, applied, recorded, never beyond scope.
final class AgentAccessServiceTests: XCTestCase {
  private var owner: ScriptedOwner!
  private var records: MemoryAgentRecords!
  private var secrets: MemoryAgentGrantSecretStore!
  private var clock: MutableClock!
  private var applier: RecordingChanges!

  override func setUp() async throws {
    owner = ScriptedOwner()
    records = MemoryAgentRecords()
    secrets = MemoryAgentGrantSecretStore()
    clock = MutableClock(AgentFixture.now)
    applier = RecordingChanges()
  }

  private func service(
    snapshot: AgentMemorySnapshot? = nil, timeout: Duration = .seconds(5),
    limits: AgentAccessService.Limits = .init()
  ) throws -> AgentAccessService {
    let clock = clock!
    return AgentAccessService(
      memory: FixedMemory(snapshot: try snapshot ?? AgentFixture.snapshot()), records: records,
      secrets: secrets, consent: owner, changes: applier,
      configuration: .init(consentTimeout: timeout, denialCooldown: 60, limits: limits),
      timeZone: AgentFixture.timeZone, clock: { clock.now })
  }

  // MARK: Conformance

  func testInitializeListAndCallEveryTool() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal", "lab"], change: true))
    let client = await AgentTestClient(service: service)
    let initialize = await client.request(
      "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]])
    XCTAssertEqual(initialize["result"]?["protocolVersion"], "2025-06-18")
    XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "mindloom")
    XCTAssertEqual(initialize["result"]?["capabilities"]?["tools"]?["listChanged"], true)
    XCTAssertNotNil(initialize["result"]?["capabilities"]?["resources"])
    let unknownVersion = await client.request("initialize", ["protocolVersion": "1999-01-01"])
    XCTAssertEqual(
      unknownVersion["result"]?["protocolVersion"]?.stringValue,
      MCPServerInfo.supportedProtocolVersions[0])
    // Before any grant: the read tools only (F5).
    let before = await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertEqual(
      before.compactMap { $0["name"]?.stringValue },
      ["today", "search", "get_matter", "get_person", "list_deadlines", "list_recent"])
    for tool in before {
      XCTAssertEqual(tool["inputSchema"]?["type"], "object")
      XCTAssertNotNil(tool["description"]?.stringValue)
      XCTAssertEqual(tool["annotations"]?["readOnlyHint"], true)
    }
    let value1 = await client.request("ping")["result"]
    XCTAssertEqual(value1, [:])

    let today = await client.call("today")
    XCTAssertFalse(today.isErrorResult, today.text)
    XCTAssertTrue(today.text.contains("可以念的概括："), today.text)
    XCTAssertEqual(today.structured?["date"], "2026-09-30")

    // A grant with 也可以改: now the change tools are listed too.
    let after = await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertEqual(after.compactMap { $0["name"]?.stringValue }, AgentTool.allCases.map(\.rawValue))
    for tool in after
    where tool["name"]?.stringValue.map({ AgentTool(rawValue: $0)!.isChange })
      == true
    {
      XCTAssertEqual(tool["annotations"]?["readOnlyHint"], false)
      XCTAssertEqual(tool["annotations"]?["destructiveHint"], false)
    }

    let search = await client.call("search", ["query": "Twin"])
    XCTAssertFalse(search.isErrorResult, search.text)
    XCTAssertEqual(search.matterIDs, [AgentFixture.twin, AgentFixture.openDay])
    XCTAssertTrue(search.text.fenced.contains("Twin-7 真机实验"), search.text)

    let brief = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(brief.isErrorResult, brief.text)
    XCTAssertTrue(brief.text.fenced.contains("现在：第三组数据周五前跑完"), brief.text)
    XCTAssertFalse(brief.text.contains("[条目 "), "the brief lens has no excerpts")
    XCTAssertTrue(brief.text.contains("detail=full"))
    let matter = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    XCTAssertFalse(matter.isErrorResult, matter.text)
    XCTAssertTrue(matter.text.fenced.contains("[条目 \(AgentFixture.items[0].uuidString)]"))
    XCTAssertTrue(matter.text.fenced.contains("\n> 韩策："), matter.text)
    XCTAssertTrue(
      matter.text.fenced.contains("[计划] 周五前跑完第三组（\(AgentFixture.day(2))）"))
    XCTAssertFalse(matter.text.contains("绳"), matter.text)
    let json = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full", "format": "json"])
    XCTAssertEqual(json.structured?["items"]?.arrayValue?.count, 3)
    XCTAssertEqual(try JSONValue.parse(json.text), json.structured)

    let deadlines = await client.call("list_deadlines", ["days": 14])
    XCTAssertEqual(
      deadlines.structured?["deadlines"]?.arrayValue?.compactMap {
        $0["matter_id"]?.stringValue
      }, [AgentFixture.labWeekly, AgentFixture.twin, AgentFixture.moving, AgentFixture.openDay])
    let recent = await client.call("list_recent", ["days": 1])
    XCTAssertEqual(
      recent.matterIDs,
      [AgentFixture.labWeekly, AgentFixture.twin, AgentFixture.openDay, AgentFixture.moving])
    let person = await client.call("get_person", ["name": "林晓"])
    XCTAssertFalse(person.isErrorResult, person.text)
    XCTAssertEqual(person.structured?["quotes"]?.arrayValue?.isEmpty, false)
    let note = await client.call("add_note", ["text": "交接说明正文", "title": "交接"])
    XCTAssertFalse(note.isErrorResult, note.text)
    XCTAssertEqual(note.structured?["item_id"]?.stringValue, RecordingChanges.noteItemID)

    let resources = await client.request("resources/list")["result"]?["resources"]?.arrayValue ?? []
    XCTAssertEqual(resources.count, 4)
    let read = await client.request(
      "resources/read", ["uri": .string(AgentResource.uri(matterID: AgentFixture.twin))])
    XCTAssertEqual(
      read["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue?.fenced,
      brief.text.fenced)
    let templates = await client.request("resources/templates/list")
    XCTAssertEqual(
      templates["result"]?["resourceTemplates"]?.arrayValue?.first?["uriTemplate"],
      "mindloom://matter/{id}")

    for forbidden in ["delete_matter", "add_to_inbox", "search_matters", "share", "export"] {
      let unknown = await client.request("tools/call", ["name": .string(forbidden)])
      XCTAssertEqual(unknown["error"]?["code"]?.intValue, Int64(MCPErrorCode.invalidParams))
    }
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
    let first = await client.call("search", ["query": "Twin"])
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
    let again = await updated.call("search", ["query": "Twin"])
    XCTAssertFalse(again.isErrorResult)
    let afterUpdate = await owner.consentRequests.count
    XCTAssertEqual(afterUpdate, 1)
    // Another program with the same name is another client.
    let other = await AgentTestClient(service: service, path: "/tmp/fake/claude")
    await owner.queue(.deny)
    let refused = await other.call("search", ["query": "Twin"])
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
    // Listing resources never asks; without a grant the list is empty.
    let resource = await client.request("resources/list")
    XCTAssertEqual(resource["result"]?["resources"]?.arrayValue, [])
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
    let pending = await client.call("search", ["query": "Twin"])
    XCTAssertEqual(pending.errorCode, "pending")
    XCTAssertEqual(pending.text, AgentCopy.pending)
    await owner.queue(allowAll())
    try await Task.sleep(for: .milliseconds(100))
    let later = await client.call("search", ["query": "Twin"])
    XCTAssertFalse(later.isErrorResult, later.text)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 1)
  }

  // MARK: Scope

  func testMattersOutsideTheScopeAreInvisibleEverywhere() async throws {
    let service = try service()
    // v11: a user group's matters (「这个分组」).
    await owner.queue(allowAll(spaces: ["personal"], range: .groups([AgentFixture.researchGroup])))
    let client = await AgentTestClient(service: service)
    let outside = AgentFixture.outside
    let hidden = await client.call("search", ["query": .string(outside)])
    XCTAssertEqual(hidden.matterIDs, [])
    XCTAssertFalse(hidden.serialized.contains(outside))
    let value2 = await client.call("search", ["query": "开放日"]).matterIDs
    XCTAssertEqual(value2, [])
    let value3 = await client.call("search", ["query": "Twin"]).matterIDs
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
      deadlines.structured?["deadlines"]?.arrayValue?.compactMap {
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

  /// A v8 rope grant still decodes, but v11 shows no ropes: it covers
  /// nothing (as if it had expired).
  func testAnOldRopeGrantCoversNothing() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal"], range: .ropes(["r-research"])))
    let client = await AgentTestClient(service: service)
    let found = await client.call("search", ["query": "Twin"]).matterIDs
    XCTAssertEqual(found, [])
    let recent = await client.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(recent, [])
  }

  /// The first call that names a matter asks about that matter.
  func testTheConsentNamesTheMatterTheFirstCallAsksFor() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    _ = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    let requested = await owner.consentRequests.first?.requestedMatter?.id
    XCTAssertEqual(requested?.uppercased(), AgentFixture.twin.uppercased())
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

  /// Review v12-B #2 (regression): a grant made before v12, when the stored
  /// flag meant 「可以提建议（写进收件箱）」, is no 也可以改 grant. Its v1 MAC no
  /// longer checks out: the change tools stay hidden, the row is removed and
  /// the owner is asked again (with Touch ID for 也可以改) before anything is
  /// read or changed.
  func testAPreV12ProposeGrantIsNotHonouredAsAChangeGrant() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let first = await AgentTestClient(service: service)
    let read = await first.call("list_recent").isErrorResult
    XCTAssertFalse(read)
    await first.close()
    let stored = await records.grants
    let made = try XCTUnwrap(stored.first)
    let secret = try XCTUnwrap(try secrets.secret(for: made.grantID))
    // The same grant as v10 stored it: the flag on, the MAC over the v1 text.
    var legacy = AgentGrantRecord(
      grantID: made.grantID, clientKey: made.clientKey, clientName: made.clientName,
      clientPath: made.clientPath,
      terms: AgentGrantTerms(
        spaces: made.terms.spaces, range: made.terms.range, canChange: true,
        duration: made.terms.duration, showNumbers: made.terms.showNumbers,
        askForNewMatters: made.terms.askForNewMatters),
      createdAt: made.createdAt, expiresAt: made.expiresAt, mac: "")
    XCTAssertEqual(AgentGrantRecord.canonicalVersion, "mindloom-agent-grant-v2")
    let v1 = legacy.canonicalText.replacingOccurrences(
      of: AgentGrantRecord.canonicalVersion, with: "mindloom-agent-grant-v1")
    legacy.mac = AgentGrantSecret.mac(v1, secret: secret)
    await records.replaceGrants([legacy])

    let next = await AgentTestClient(service: service)
    let listed = await next.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertEqual(
      listed.compactMap { $0["name"]?.stringValue },
      ["today", "search", "get_matter", "get_person", "list_deadlines", "list_recent"])
    await owner.queue(.deny)
    let again = await next.call("list_recent").errorCode
    XCTAssertEqual(again, "denied")
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 2, "the owner is asked again")
    let left = await records.grants
    XCTAssertEqual(left, [])
    await owner.queue(.deny)
    let renamed = await next.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "改过的名字"])
    XCTAssertTrue(renamed.isErrorResult)
    let applied = await applier.applied
    XCTAssertTrue(applied.isEmpty)
  }

  /// Review v12-B #14 (regression): the service reads the product time zone
  /// at each use, so a zone changed in Settings applies to agents at once
  /// (here: where a 今天 grant ends).
  func testTheProductTimeZoneIsReadAtEachUse() async throws {
    final class Zone: @unchecked Sendable {
      private let lock = NSLock()
      private var value = TimeZone(identifier: "Asia/Singapore")!
      var current: TimeZone {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
      }
    }
    let zone = Zone()
    let clock = clock!
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: records,
      secrets: secrets, consent: owner, changes: applier, zone: { zone.current },
      clock: { clock.now })
    func endOfToday(_ identifier: String) -> Date {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: identifier)!
      return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now))!
    }
    await owner.queue(allowAll(duration: .today))
    let client = await AgentTestClient(service: service)
    _ = await client.call("list_recent")
    let first = await records.grants.first?.expiresAt
    XCTAssertEqual(first, endOfToday("Asia/Singapore"))
    let made = await records.grants
    await service.revoke(try XCTUnwrap(made.first).grantID)
    zone.current = TimeZone(identifier: "America/Los_Angeles")!
    await owner.queue(allowAll(duration: .today))
    let next = await AgentTestClient(service: service)
    _ = await next.call("list_recent")
    let second = await records.grants.first?.expiresAt
    XCTAssertEqual(second, endOfToday("America/Los_Angeles"))
    XCTAssertNotEqual(first, second)
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
    let value20 = await client.call("search", ["query": "实验室"]).errorCode
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
    let text = await masked.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    for sentinel in [AgentFixture.phone, AgentFixture.email] {
      XCTAssertFalse(text.serialized.contains(sentinel), sentinel)
    }
    XCTAssertTrue(text.text.contains("〔手机号·"))
    XCTAssertTrue(text.text.contains("〔邮箱·"))
    XCTAssertEqual(text.structured?["numbers_masked"], true)
    let json = await masked.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full", "format": "json"])
    XCTAssertFalse(json.serialized.contains(AgentFixture.phone))
    XCTAssertEqual(json.structured?["numbers_masked"], true)
    let person = await masked.call("get_person", ["name": "韩策"])
    XCTAssertFalse(person.serialized.contains(AgentFixture.phone))

    await owner.queue(allowAll(numbers: true))
    let raw = await AgentTestClient(service: service, name: "codex-mcp-client", path: "/opt/codex")
    let original = await raw.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    XCTAssertTrue(original.text.contains(AgentFixture.phone))
    let value25 = await raw.call(
      "get_matter", ["id": .string(AgentFixture.twin), "format": "json"])
    XCTAssertEqual(
      value25.structured?["numbers_masked"], false)

    // Placeholders are keyed per grant: two agents cannot join theirs.
    await owner.queue(allowAll())
    let third = await AgentTestClient(service: service, name: "cursor-vscode", path: "/opt/cursor")
    let other = await third.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    let tagA = PrivacyUnmask.placeholders(in: text.text).first { $0.hasPrefix("〔手机号·") }
    let tagB = PrivacyUnmask.placeholders(in: other.text).first { $0.hasPrefix("〔手机号·") }
    XCTAssertNotNil(tagA)
    XCTAssertNotEqual(tagA, tagB)
  }

  // MARK: Audit

  func testEveryCallIsAuditedWithoutContent() async throws {
    let service = try service(timeout: .milliseconds(50))
    let client = await AgentTestClient(service: service)
    _ = await client.call("search", ["query": "Twin 真机"])  // pending
    await owner.queue(allowAll(change: true))
    try await Task.sleep(for: .milliseconds(80))
    _ = await client.call("search", ["query": "Twin 真机"])
    _ = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    _ = await client.call("get_matter", ["id": .string(AgentFixture.labWeekly)])
    _ = await client.call("get_person", ["name": "韩策"])
    _ = await client.call(
      "add_note", ["text": .string("SENTINEL-PROPOSAL \(AgentFixture.phone)")])
    _ = await client.request("resources/list")
    _ = await client.request(
      "resources/read", ["uri": .string(AgentResource.uri(matterID: AgentFixture.twin))])
    let rows = await records.audit
    XCTAssertEqual(rows.count, 8)
    XCTAssertEqual(
      rows.map(\.tool),
      [
        "search", "search", "get_matter", "get_matter", "get_person",
        "add_note", "resources/list", "resources/read",
      ])
    // The lab matter is outside a 我的-only grant: not found.
    XCTAssertEqual(
      rows.map(\.outcome),
      [.pending, .allowed, .allowed, .notFound, .allowed, .allowed, .allowed, .allowed])
    XCTAssertEqual(rows[3].matterIDs, [])
    XCTAssertEqual(rows[2].matterIDs, [AgentFixture.twin])
    XCTAssertTrue(rows[2].byteCount > 300)
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

  // MARK: Changes (v12, 也可以改)

  /// A read-only grant lists no change tool and refuses one called anyway;
  /// nothing reaches the App.
  func testChangeToolsNeedTheirOwnTick() async throws {
    let service = try service()
    await owner.queue(allowAll(change: false))
    let readOnly = await AgentTestClient(service: service)
    _ = await readOnly.call("today")
    let tools = await readOnly.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertFalse(tools.contains { $0["name"] == "add_note" })
    for (tool, arguments) in [
      ("add_note", ["text": "不该进来"] as JSONValue),
      ("rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "新名字"]),
      (
        "move_item",
        [
          "item_id": .string(AgentFixture.items[0].uuidString),
          "from_matter_id": .string(AgentFixture.twin),
        ]
      ),
      ("mark_step", ["matter_id": .string(AgentFixture.twin), "step_id": "st1"]),
    ] {
      let refused = await readOnly.call(tool, arguments)
      XCTAssertEqual(refused.errorCode, "read_only", tool)
      XCTAssertEqual(refused.text, AgentCopy.changeNotAllowed, tool)
    }
    let applied = await applier.applied
    XCTAssertEqual(applied, [])
    let rows = await records.changeRows
    XCTAssertEqual(rows, [])
  }

  /// Each allowed change is applied as the owner's own correction, recorded
  /// with what undoes it, and told to the owner.
  func testEachChangeIsAppliedRecordedAndUndoable() async throws {
    let service = try service(
      snapshot: try AgentFixture.snapshot(twinStatus: "10月2日提交第三组报告"))
    await owner.queue(allowAll(change: true))
    let client = await AgentTestClient(
      service: service, name: "codex-mcp-client", path: "/opt/codex")
    let brief = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(brief.text.fenced.contains("提交第三组报告〔步骤 st1〕"), brief.text)
    let item = AgentFixture.items[0].uuidString

    let note = await client.call(
      "add_note",
      ["text": "第一行\n第二行", "title": " 交接说明 ", "matter_id": .string(AgentFixture.twin)])
    XCTAssertFalse(note.isErrorResult, note.text)
    let moved = await client.call(
      "move_item",
      [
        "item_id": .string(item.lowercased()), "from_matter_id": .string(AgentFixture.twin),
        "to_matter_id": .string(AgentFixture.openDay),
      ])
    XCTAssertFalse(moved.isErrorResult, moved.text)
    let out = await client.call(
      "move_item", ["item_id": .string(item), "from_matter_id": .string(AgentFixture.twin)])
    XCTAssertFalse(out.isErrorResult, out.text)
    let renamed = await client.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "Twin-7 第三组实验"])
    XCTAssertFalse(renamed.isErrorResult, renamed.text)
    let marked = await client.call(
      "mark_step", ["matter_id": .string(AgentFixture.twin), "step_id": "st1"])
    XCTAssertFalse(marked.isErrorResult, marked.text)

    let applied = await applier.applied
    XCTAssertEqual(
      applied,
      [
        .addNote(title: "交接说明", text: "第一行\n第二行", matterID: AgentFixture.twin),
        .correction(
          .moveItem(itemID: item, segID: nil, from: AgentFixture.twin, to: AgentFixture.openDay)),
        .correction(.takeOut(itemID: item, segID: nil, from: AgentFixture.twin)),
        .correction(
          .rename(eventID: AgentFixture.twin, from: "Twin-7 真机实验", to: "Twin-7 第三组实验")),
        .correction(
          .markStep(eventID: AgentFixture.twin, stepID: "st1", state: .done, previous: nil)),
      ])
    let rows = await records.changeRows
    XCTAssertEqual(rows.map(\.kind), [.addNote, .moveItem, .takeOut, .renameMatter, .markStep])
    XCTAssertTrue(rows.allSatisfy { $0.clientName == "Codex" && $0.state == .applied })
    XCTAssertEqual(rows[0].itemID, RecordingChanges.noteItemID)
    XCTAssertEqual(rows[0].summary, "添加“交接说明”到“Twin-7 真机实验”")
    XCTAssertEqual(rows[1].summary, "将一条原文从“Twin-7 真机实验”移到“开放日演示”")
    XCTAssertEqual(rows[3].summary, "将“Twin-7 真机实验”重新命名为“Twin-7 第三组实验”")
    // What undoes it is in the record: the page correction, as JSON.
    let rename = try JSONDecoder().decode(MemoryCorrection.self, from: Data(rows[3].payload.utf8))
    XCTAssertEqual(
      rename.inverse,
      .rename(eventID: AgentFixture.twin, from: "Twin-7 第三组实验", to: "Twin-7 真机实验"))
    let step = try JSONDecoder().decode(MemoryCorrection.self, from: Data(rows[4].payload.utf8))
    XCTAssertEqual(
      step.inverse,
      .markStep(eventID: AgentFixture.twin, stepID: "st1", state: nil, previous: .done))
    let told = await owner.made.count
    XCTAssertEqual(told, 5)
    let audit = await records.audit.filter { AgentTool(rawValue: $0.tool)?.isChange == true }
    XCTAssertEqual(audit.map(\.outcome), Array(repeating: .allowed, count: 5))

    // Bad requests change nothing.
    let sameName = await client.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "Twin-7 真机实验"])
    XCTAssertEqual(sameName.structured?["changed"], false)
    let noStep = await client.call(
      "mark_step", ["matter_id": .string(AgentFixture.twin), "step_id": "st9"])
    XCTAssertEqual(noStep.errorCode, "not_found")
    let settled = await client.call(
      "mark_step",
      ["matter_id": .string(AgentFixture.twin), "step_id": "st1", "state": "settled"])
    XCTAssertEqual(settled.errorCode, "invalid_arguments")
    let notThere = await client.call(
      "move_item",
      [
        "item_id": .string(AgentFixture.items[3].uuidString),
        "from_matter_id": .string(AgentFixture.twin),
      ])
    XCTAssertEqual(notThere.errorCode, "not_found")
    let tooLong = await client.call(
      "add_note",
      ["text": .string(String(repeating: "长", count: AgentTool.maximumNoteCharacters + 1))])
    XCTAssertEqual(tooLong.errorCode, "invalid_arguments")
    let empty = await client.call("add_note", ["text": "  \n "])
    XCTAssertEqual(empty.errorCode, "invalid_arguments")
    let after = await applier.applied.count
    XCTAssertEqual(after, 5)
  }

  /// A change never reaches a matter outside the grant or in a shared space.
  func testChangesStayInsideTheGrantAndOffSharedSpaces() async throws {
    let service = try service()
    await owner.queue(allowAll(range: .matters([AgentFixture.twin]), change: true))
    let narrow = await AgentTestClient(service: service)
    let item = AgentFixture.items[0].uuidString
    let outside = await narrow.call(
      "move_item",
      [
        "item_id": .string(item), "from_matter_id": .string(AgentFixture.twin),
        "to_matter_id": .string(AgentFixture.openDay),
      ])
    XCTAssertEqual(outside.errorCode, "not_found")
    let rename = await narrow.call(
      "rename_matter", ["matter_id": .string(AgentFixture.moving), "title": "x"])
    XCTAssertEqual(rename.errorCode, "not_found")
    let note = await narrow.call(
      "add_note", ["text": "x", "matter_id": .string(AgentFixture.openDay)])
    XCTAssertEqual(note.errorCode, "not_found")
    await owner.queue(allowAll(spaces: ["personal", "lab"], change: true))
    let wide = await AgentTestClient(service: service, name: "codex-mcp-client", path: "/opt/codex")
    let shared = await wide.call(
      "rename_matter", ["matter_id": .string(AgentFixture.labWeekly), "title": "周会"])
    XCTAssertEqual(shared.errorCode, "read_only")
    XCTAssertEqual(shared.text, AgentCopy.sharedNotChangeable)
    let applied = await applier.applied
    XCTAssertEqual(applied, [])
  }

  /// When the App could not apply it, nothing is recorded and the agent is
  /// told so.
  func testAChangeTheAppCouldNotApplyIsNotRecorded() async throws {
    let service = try service()
    await owner.queue(allowAll(change: true))
    let client = await AgentTestClient(service: service)
    await applier.fail(true)
    let result = await client.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "新名字"])
    XCTAssertEqual(result.errorCode, "failed")
    let rows = await records.changeRows
    XCTAssertEqual(rows, [])
  }

  // MARK: Limits (F7)

  func testHourlyLimitsPauseAGrantAndTellTheOwnerOnce() async throws {
    let service = try service(limits: .init(mattersPerHour: 3, changesPerHour: 1))
    await owner.queue(allowAll(change: true))
    let client = await AgentTestClient(service: service)
    let first = await client.call("list_recent", ["days": 14])
    XCTAssertEqual(first.matterIDs.count, 3)
    let paused = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertEqual(paused.errorCode, "limited")
    XCTAssertEqual(paused.text, AgentCopy.limited)
    _ = await client.call("search", ["query": "Twin"])
    let told = await owner.limited
    XCTAssertEqual(told, ["Claude Code"])
    let lastOutcome = await records.audit.last?.outcome
    XCTAssertEqual(lastOutcome, .limited)
    // Changes have their own limit.
    let renamed = await client.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "一"])
    XCTAssertFalse(renamed.isErrorResult, renamed.text)
    let again = await client.call(
      "rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "二"])
    XCTAssertEqual(again.errorCode, "limited")
    // An hour later it reads again.
    clock.advance(3_601)
    let later = await client.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(later.isErrorResult, later.text)
  }

  // MARK: The tool list follows the grant

  func testTheToolListFollowsTheGrantAndTheClientIsTold() async throws {
    let service = try service()
    let pushed = PushedLines()
    let session = await service.openSession(
      peer: AgentConnectionPeer(
        pid: 4242, uid: getuid(), clientExecutablePath: "/opt/claude",
        clientSigner: AgentTestClient.claudeSigner),
      push: { pushed.append($0) })
    func request(_ method: String, _ params: JSONValue? = nil) async -> JSONValue {
      await service.handle(.request(id: 1, method: method, params: params), session: session)
        ?? .null
    }
    _ = await request("initialize", ["clientInfo": ["name": "claude-code"]])
    let before = await request("tools/list")["result"]?["tools"]?.arrayValue?.count
    XCTAssertEqual(before, AgentTool.readTools.count)
    await owner.queue(allowAll(change: true))
    _ = await request("tools/call", ["name": "today"])
    XCTAssertEqual(pushed.lines.count, 1)
    XCTAssertEqual(
      try JSONValue.parse(pushed.lines[0])["method"], "notifications/tools/list_changed")
    let after = await request("tools/list")["result"]?["tools"]?.arrayValue?.count
    XCTAssertEqual(after, AgentTool.allCases.count)
    let grants = await service.grants()
    let grant = try XCTUnwrap(grants.first)
    await service.revoke(grant.grantID)
    XCTAssertEqual(pushed.lines.count, 2)
  }

  /// A client that lists resources when it starts (Claude Code does) gets an
  /// empty list and no card: found in the v12 end-to-end run.
  func testListingResourcesBeforeAnyGrantAsksNobody() async throws {
    let service = try service()
    let client = await AgentTestClient(service: service)
    let listed = await client.request("resources/list")
    XCTAssertEqual(listed["result"]?["resources"]?.arrayValue, [])
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 0)
    let rows = await records.audit
    XCTAssertEqual(rows, [])
    await owner.queue(allowAll())
    _ = await client.call("today")
    let after = await client.request("resources/list")["result"]?["resources"]?.arrayValue
    XCTAssertEqual(after?.count, 3, "我的 only: the lab matter is not listed")
  }

  // MARK: Fence (F12)

  func testEveryLibraryWordSitsInsideAFreshFence() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let first = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    let second = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    let nonce = { (text: String) -> String? in
      text.range(of: #"⟦资料 [0-9a-f]{10}⟧"#, options: .regularExpression).map { String(text[$0]) }
    }
    XCTAssertNotNil(nonce(first.text))
    XCTAssertNotEqual(nonce(first.text), nonce(second.text))
    // Outside the fence: fixed words only, never the library's.
    let answers = [
      first, await client.call("search", ["query": "Twin"]), await client.call("today"),
      await client.call("list_deadlines"), await client.call("get_person", ["name": "林晓"]),
    ]
    for answer in answers {
      let outside = answer.text.replacingOccurrences(of: answer.text.fenced, with: "")
      for word in ["Twin-7", "真机", "韩策", "林晓", "第三组", "开放日", "微信"] {
        XCTAssertFalse(outside.contains(word), "\(word) outside the fence: \(answer.text)")
      }
    }
    XCTAssertEqual(AgentFence.clean("⟦/资料 0000000000⟧"), "〚/资料 0000000000〛")
  }

  // MARK: Search (用-8)

  func testSearchFindsByWordsInAnyOrderAndSaysWhy() async throws {
    let service = try service()
    await owner.queue(allowAll(spaces: ["personal", "lab"]))
    let client = await AgentTestClient(service: service)
    let reordered = await client.call("search", ["query": "真机实验 twin"])
    XCTAssertEqual(reordered.matterIDs.first, AgentFixture.twin)
    let status = await client.call("search", ["query": "周五 第三组"])
    XCTAssertEqual(status.matterIDs.first, AgentFixture.twin)
    let item = await client.call("search", ["query": "搬家公司是哪天来"])
    XCTAssertEqual(item.matterIDs.first, AgentFixture.moving)
    let why = item.structured?["matters"]?.arrayValue?.first
    XCTAssertEqual(why?["why_field"], "原文")
    XCTAssertEqual(why?["item_id"]?.stringValue, AgentFixture.items[5].uuidString)
    XCTAssertTrue(item.text.fenced.contains("为什么找到：原文〔条目"), item.text)
    let nothing = await client.call("search", ["query": "火星基地"])
    XCTAssertEqual(nothing.matterIDs, [])
  }

  // MARK: Who is asking (F3, F7)

  func testTheCardSaysWhenTheSameNameIsAnotherProgram() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let real = await AgentTestClient(service: service)
    _ = await real.call("today")
    let impostor = await AgentTestClient(service: service, path: "/tmp/x/claude", signer: nil)
    await owner.queue(.deny)
    _ = await impostor.call("today")
    let requests = await owner.consentRequests
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(requests[0].lookalike)
    XCTAssertEqual(requests[1].lookalike?.name, "Claude Code")
    XCTAssertEqual(requests[1].lookalike?.path, "/Users/test/.local/share/claude/versions/*")
    XCTAssertEqual(requests[1].client.signerLabel, "没有开发者签名的程序")
    XCTAssertTrue(requests[1].client.whoLine.hasSuffix("/tmp/x/claude"))
  }

  func testOneOpenCardPerName() async throws {
    let service = try service(timeout: .milliseconds(100))
    let first = await AgentTestClient(service: service)
    let waiting = await first.call("today")
    XCTAssertEqual(waiting.errorCode, "pending")
    let second = await AgentTestClient(service: service, path: "/tmp/y/claude", signer: nil)
    let alsoWaiting = await second.call("today")
    XCTAssertEqual(alsoWaiting.errorCode, "pending")
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 1, "a second program with the same name stacks no card")
  }

  // MARK: Ask for each new matter

  func testNewMattersAreApprovedOneByOne() async throws {
    let service = try service(timeout: .milliseconds(200))
    await owner.queue(allowAll(spaces: ["personal", "lab"], ask: true))
    let client = await AgentTestClient(service: service)
    await owner.queueApproval([AgentFixture.twin: true, AgentFixture.openDay: false])
    let search = await client.call("search", ["query": "Twin"])
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
    XCTAssertTrue(recent.text.contains("要等主人在 Mindloom 里批准"))
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
