import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// Agent-tool practice (notes: AGENT-TOOLS.md, 2026-10-06), as regressions:
///
/// - MCP tools are model-controlled and the host keeps the human in the loop
///   (MCP 2026-07-28, Tools › User Interaction Model). Nothing Mindloom gives
///   an agent tells its model to ask the owner before reading; the
///   instructions say when the tools help and when not, and consent is the
///   host's permission prompt plus Mindloom's grant card.
/// - `resources/list` gives nothing before a grant, then cursor-paginated
///   pages of titles and ids. Pages use no content quota; each is audited
///   and counted against its own hourly limit. The content quota counts the
///   text reads and searches return.
/// - The change tools refuse without a grant that allows changes; nothing
///   offered deletes.
/// - No answer is larger than what the agent's host passes to its model:
///   a matter's full text comes in pages (verification with Claude Code,
///   2026-10-06).
final class AgentToolPracticeTests: XCTestCase {
  private var owner: ScriptedOwner!
  private var records: MemoryAgentRecords!
  private var clock: MutableClock!
  private var applier: RecordingChanges!

  override func setUp() async throws {
    owner = ScriptedOwner()
    records = MemoryAgentRecords()
    clock = MutableClock(AgentFixture.now)
    applier = RecordingChanges()
  }

  private func service(
    limits: AgentAccessService.Limits = .init(), pageSize: Int = AgentResource.pageSize,
    maximum: Int = AgentResource.maximumListed, snapshot: AgentMemorySnapshot? = nil
  ) throws -> AgentAccessService {
    let clock = clock!
    return AgentAccessService(
      memory: FixedMemory(snapshot: try snapshot ?? AgentFixture.snapshot()), records: records,
      secrets: MemoryAgentGrantSecretStore(), consent: owner, changes: applier,
      configuration: .init(
        consentTimeout: .seconds(5), denialCooldown: 60, limits: limits, listPageSize: pageSize,
        listMaximum: maximum),
      timeZone: AgentFixture.timeZone, clock: { clock.now })
  }

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  /// Words that gate reading on the owner naming Mindloom or on asking
  /// first (the server instructions and the skill said so until 1.4.0).
  static let readGating = [
    "只在主人提到", "或明确要你用它时才用", "主人没有提到时不要", "没有提到时不要使用", "先问主人要不要", "要不要在 Mindloom 里找",
    "要不要用 Mindloom", "主人提到 Mindloom（或织机）", "only when the owner mentions",
    "ask the owner before", "ask the user before",
  ]

  // MARK: 1. No read gating; when to use, when not

  func testNothingTellsTheModelToAskBeforeReading() throws {
    var texts: [(String, String)] = [("MCPServerInfo.instructions", MCPServerInfo.instructions)]
    for tool in AgentTool.allCases { texts.append(("tool \(tool.rawValue)", tool.summary)) }
    for file in [
      "integrations/claude-code-plugin/skills/mindloom/SKILL.md",
      "integrations/claude-code-plugin/commands/context.md",
      "integrations/claude-code-plugin/commands/handoff.md",
      "integrations/claude-code-plugin/README.md",
      "integrations/claude-code-plugin/.claude-plugin/plugin.json",
      "integrations/claude-desktop/manifest.json",
      "docs/AGENTS.md",
    ] {
      let url = Self.repositoryRoot.appendingPathComponent(file)
      texts.append((file, try String(contentsOf: url, encoding: .utf8)))
    }
    for (name, text) in texts {
      for phrase in Self.readGating {
        XCTAssertFalse(
          text.localizedCaseInsensitiveContains(phrase), "\(name) gates reading: \(phrase)")
      }
    }

    // The instructions say when the tools help and when not, where consent
    // comes from, and fit what Claude Code keeps (2,048 characters).
    let instructions = MCPServerInfo.instructions
    for needed in [
      "什么时候用", "什么时候不用", "主人不必提到 Mindloom", "权限提示", "授权卡", "会议", "截止日期", "和主人的事无关",
      "主人明确要你改",
      // Verification 10-6: two of three plain coding questions were answered
      // with "this has nothing to do with Mindloom" first.
      "回答里不要提到 Mindloom",
    ] {
      XCTAssertTrue(instructions.contains(needed), "instructions lack 「\(needed)」")
    }
    XCTAssertLessThanOrEqual(instructions.count, 2_048)
    for tool in AgentTool.allCases {
      XCTAssertLessThanOrEqual(tool.summary.count, 2_048, tool.rawValue)
    }

    // The skill's description says what it does and when to use it (the
    // only part Claude Code loads before the skill is picked).
    let skill = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent(
        "integrations/claude-code-plugin/skills/mindloom/SKILL.md"), encoding: .utf8)
    let description = try XCTUnwrap(
      skill.split(separator: "\n").first { $0.hasPrefix("description:") })
    XCTAssertLessThanOrEqual(description.count, 1_024 + "description: ".count)
    XCTAssertTrue(description.contains("问到自己的事"), String(description))
    XCTAssertTrue(description.contains("不必提到 Mindloom"), String(description))
    XCTAssertTrue(description.contains("无关的任务不使用"), String(description))
    XCTAssertTrue(skill.contains("回答里不要提到 Mindloom"))
  }

  // MARK: 2. Listing: nothing before a grant, then paged titles and ids

  func testListingIsEmptyBeforeAGrantThenPagesOfTitlesAndIDs() async throws {
    // Both spaces: four matters; at most three listed, two a page.
    let service = try service(pageSize: 2, maximum: 3)
    let client = await AgentTestClient(service: service)
    let before = await client.request("resources/list")
    XCTAssertEqual(before["result"]?["resources"]?.arrayValue, [])
    XCTAssertNil(before["result"]?["nextCursor"])
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 0, "listing never asks")
    let audited = await records.audit
    XCTAssertEqual(audited, [], "nothing was listed, nothing is recorded")

    await owner.queue(allowAll(spaces: ["personal", "lab"]))
    _ = await client.call("today")
    let first = await client.request("resources/list")["result"]
    let firstPage = try XCTUnwrap(first?["resources"]?.arrayValue)
    XCTAssertEqual(firstPage.count, 2)
    let cursor = try XCTUnwrap(first?["nextCursor"]?.stringValue)
    for resource in firstPage {
      XCTAssertEqual(
        Set(resource.objectValue?.keys.map { $0 } ?? []), ["uri", "name", "title"],
        "titles and ids only")
    }
    let second = await client.request("resources/list", ["cursor": .string(cursor)])["result"]
    let secondPage = try XCTUnwrap(second?["resources"]?.arrayValue)
    XCTAssertEqual(secondPage.count, 1, "the cap, not the page size, ends the list")
    XCTAssertNil(second?["nextCursor"])
    let names = (firstPage + secondPage).compactMap { $0["name"]?.stringValue }
    XCTAssertEqual(Set(names).count, 3, "no matter twice")
    let serialized = (first?.serialized ?? "") + (second?.serialized ?? "")
    XCTAssertFalse(serialized.contains("第三组数据周五前跑完"), "no status line")
    XCTAssertFalse(serialized.contains(AgentFixture.phone))

    // A cursor this server did not make is invalid params (MCP pagination).
    for bad in ["abc", Data("p1|x|E-TWIN7".utf8).base64EncodedString()] {
      let invalid = await client.request("resources/list", ["cursor": .string(bad)])
      XCTAssertEqual(invalid["error"]?["code"]?.intValue, Int64(MCPErrorCode.invalidParams))
    }

    // Without the App, or with 允许其他 App 读 off: nothing, and no error
    // for a client to retry at every start.
    let list = MCPMessage.decode(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
    XCTAssertEqual(AgentOfflineResponder.reply(to: list)?["result"]?["resources"]?.arrayValue, [])
    XCTAssertEqual(
      AgentOfflineResponder.switchedOffReply(to: list)?["result"]?["resources"]?.arrayValue, [])
  }

  // MARK: 3. Listing uses no content quota; audited; its own limit

  func testListingUsesNoContentQuotaButIsAuditedAndHasItsOwnLimit() async throws {
    // One byte of content an hour: any read counted at all fills it.
    let service = try service(limits: .init(bytesPerHour: 1, listingsPerHour: 3))
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let first = await client.plainCall("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(first.isErrorResult, first.text)
    // The content quota counts the text the model reads, nothing else.
    let last = await records.audit.last
    let read = try XCTUnwrap(last)
    XCTAssertEqual(read.tool, "get_matter")
    XCTAssertEqual(read.byteCount, first.text.utf8.count)
    clock.advance(3_601)

    for _ in 0..<3 {
      let page = await client.request("resources/list")
      XCTAssertEqual(page["result"]?["resources"]?.arrayValue?.count, 3, page.serialized)
    }
    let over = await client.request("resources/list")
    XCTAssertEqual(over["error"]?["code"]?.intValue, Int64(MCPErrorCode.notAllowed))
    XCTAssertEqual(over["error"]?["message"]?.stringValue, AgentCopy.listingLimited)
    let toldForListing = await owner.limited
    XCTAssertEqual(toldForListing, [], "a client listing at its start is not news to the owner")

    // Three pages of titles later, the one-byte content quota is untouched.
    let second = await client.plainCall("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertFalse(second.isErrorResult, second.text)
    let third = await client.plainCall("search", ["query": "Twin"])
    XCTAssertTrue(third.isErrorResult)
    XCTAssertEqual(third.text, AgentCopy.limited)
    let told = await owner.limited
    XCTAssertEqual(told, ["Claude Code"])

    let rows = await records.audit.filter { $0.tool == "resources/list" }
    XCTAssertEqual(rows.map(\.outcome), [.allowed, .allowed, .allowed, .limited])
    for row in rows.prefix(3) {
      XCTAssertGreaterThan(row.byteCount, 0)
      XCTAssertEqual(row.matterIDs.count, 3)
    }
  }

  // MARK: 4. Changes only with a grant that allows them; nothing deletes

  func testChangeToolsRefuseWithoutAGrantForChanges() async throws {
    let service = try service()
    let client = await AgentTestClient(service: service)
    // The first call is a change: the card says so; the owner allows reading only.
    await owner.queue(allowAll(change: false))
    let note = await client.call(
      "add_note", ["text": "交接说明", "matter_id": .string(AgentFixture.twin)])
    XCTAssertEqual(note.errorCode, "read_only", note.text)
    XCTAssertEqual(note.text, AgentCopy.changeNotAllowed)
    let request = await owner.consentRequests.first
    XCTAssertEqual(request?.wantsToChange, true)

    let listed = await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    XCTAssertEqual(
      listed.compactMap { $0["name"]?.stringValue }, AgentTool.readTools.map(\.rawValue))

    // Called anyway, by name: each one refuses.
    let calls: [(String, JSONValue)] = [
      ("add_note", ["text": "x"]),
      (
        "move_item",
        [
          "item_id": .string(AgentFixture.items[0].uuidString),
          "from_matter_id": .string(AgentFixture.twin),
          "to_matter_id": .string(AgentFixture.moving),
        ]
      ),
      ("rename_matter", ["matter_id": .string(AgentFixture.twin), "title": "新名字"]),
      ("mark_step", ["matter_id": .string(AgentFixture.twin), "step_id": "k1"]),
    ]
    for (tool, arguments) in calls {
      let refused = await client.call(tool, arguments)
      XCTAssertTrue(refused.isErrorResult, tool)
      XCTAssertEqual(refused.errorCode, "read_only", tool)
    }
    let applied = await applier.applied
    XCTAssertTrue(applied.isEmpty, "nothing changed")
    let changeRows = await records.changeRows
    XCTAssertEqual(changeRows, [])
    let outcomes = await records.audit.filter { AgentTool(rawValue: $0.tool)?.isChange == true }
      .map(\.outcome)
    XCTAssertEqual(outcomes, [.denied, .denied, .denied, .denied, .denied])

    // Nothing offered deletes, shares, exports or sends; each change says
    // it is for when the owner asks for it.
    for tool in AgentTool.allCases {
      for word in ["delete", "remove", "clear", "share", "export", "send", "record", "setting"] {
        XCTAssertFalse(tool.rawValue.contains(word), tool.rawValue)
      }
      XCTAssertEqual(tool.annotations["destructiveHint"], false)
      if tool.isChange {
        XCTAssertTrue(tool.summary.hasPrefix("主人明确要你"), tool.summary)
        XCTAssertTrue(tool.summary.contains("撤销"), tool.summary)
      }
    }
  }

  // MARK: 5. Concise by default, more on request

  func testListToolsAreShortByDefaultAndSayHowManyMore() async throws {
    let service = try service()
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let all = await client.call("list_recent", ["days": 14])
    XCTAssertEqual(all.matterIDs.count, 3)
    XCTAssertEqual(all.structured?["more"], 0)
    XCTAssertFalse(all.text.contains("另有"), all.text)
    let one = await client.call("list_recent", ["days": 14, "limit": 1])
    XCTAssertEqual(one.matterIDs.count, 1)
    XCTAssertEqual(one.structured?["more"], 2)
    XCTAssertTrue(one.text.contains(AgentCopy.more(2)), one.text)
    let deadlines = await client.call("list_deadlines", ["days": 14, "limit": 1])
    XCTAssertEqual(deadlines.structured?["deadlines"]?.arrayValue?.count, 1)
    XCTAssertTrue(deadlines.text.contains("另有"), deadlines.text)
    for bad: JSONValue in [0, .int(Int64(AgentTool.maximumListLimit + 1)), "ten"] {
      let refused = await client.call("list_recent", ["limit": bad])
      XCTAssertEqual(refused.errorCode, "invalid_arguments")
    }
    for tool in [AgentTool.listRecent, .listDeadlines, .getPerson] {
      XCTAssertEqual(
        tool.inputSchema["properties"]?["limit"]?["default"],
        .int(Int64(AgentTool.defaultListLimit)), tool.rawValue)
    }
  }

  // MARK: 6. A large matter's full text comes in pages

  /// One matter of `count` items, each about 880 characters, an hour apart
  /// (the newest is the last).
  static func largeMatter(_ id: String, count: Int) -> AgentMemorySnapshot {
    let items = (0..<count).map {
      UUID(uuidString: String(format: "7B1E0000-0000-4000-8000-1%011d", $0))!
    }
    let records = items.enumerated().map { index, item in
      let at = AgentFixture.now.addingTimeInterval(-Double(count - index) * 3_600)
      return MemoryItemRecord(
        sessionID: SessionID(item), inputMode: .userItem, itemKind: .text, title: "",
        startedAt: at, updatedAt: at, sourceBundleID: nil, sourceDisplayName: "备忘录",
        sourceIdentifier: nil,
        text: "第 \(index) 条：" + String(repeating: "夹爪在灰狼平台上抓纸杯，记下成功次数。", count: 46),
        segments: [])
    }
    let event = MemoryEventSource(
      eventID: id, origin: .spark, title: "灰狼平台抓取实验", statusLine: "纸杯实验推迟", pinned: false,
      updatedAt: AgentFixture.now, itemIDs: items.map(\.uuidString), personIDs: [],
      statusFacts: [])
    let projection = MemoryProjection(
      events: [event], records: records, persons: [], now: AgentFixture.now)
    return AgentMemorySnapshot(
      projection: projection, spaces: [.personal], ropes: [], spaceOfMatter: [:],
      timeZone: AgentFixture.timeZone)
  }

  /// Verification 2026-10-06 with Claude Code 2.1.260: `get_matter
  /// detail=full` of a 127-item demo matter answered 59,832 characters
  /// (119,752 bytes). Claude Code dropped it unread (over its 25,000-token
  /// limit, saving it to a file instead) after the content quota had counted
  /// it, and the second such read stopped the agent for the hour. Now the
  /// items come newest first in pages of at most about 10,000 characters;
  /// every item is on exactly one page; each answer says which page and how
  /// to get the next; the audit counts each page's own text.
  func testALargeMattersFullTextComesInPagesUnderTheHostLimit() async throws {
    let big = "E-BIG"
    let count = 130
    // Reading every page is more than the default hourly quota: that is the
    // quota's job, not this test's.
    let service = try service(
      limits: .init(bytesPerHour: 2_000_000), snapshot: Self.largeMatter(big, count: count))
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)

    let first = await client.plainCall("get_matter", ["id": .string(big), "detail": "full"])
    XCTAssertFalse(first.isErrorResult, first.text)
    XCTAssertLessThan(first.text.count, 12_000, "a page stays far under 25,000 tokens")
    let pageCount = try XCTUnwrap(
      first.text.range(of: #"第 1/(\d+) 页"#, options: .regularExpression).map {
        Int(first.text[$0].dropFirst(4).dropLast(2))
      } ?? nil, first.text)
    XCTAssertGreaterThan(pageCount, 5)
    XCTAssertTrue(first.text.contains("更早的用 page=2"), first.text)
    XCTAssertTrue(first.text.fenced.contains("现在：纸杯实验推迟"), "page 1 starts as the brief lens")

    func itemIDs(_ text: String) -> [String] {
      text.fenced.components(separatedBy: "\n").compactMap { line -> String? in
        guard line.hasPrefix("[条目 "), let end = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 4)..<end])
      }
    }
    var seen: [String] = []
    for page in 1...pageCount {
      let answer =
        page == 1
        ? first
        : await client.plainCall(
          "get_matter", ["id": .string(big), "detail": "full", "page": .int(Int64(page))])
      XCTAssertFalse(answer.isErrorResult, answer.text)
      XCTAssertLessThan(answer.text.count, 12_000, "page \(page)")
      XCTAssertTrue(answer.text.contains("第 \(page)/\(pageCount) 页"), answer.text)
      if page > 1 { XCTAssertFalse(answer.text.fenced.contains("现在："), "page \(page)") }
      seen += itemIDs(answer.text)
    }
    XCTAssertTrue(seen.count == count, "every item once: \(seen.count)")
    XCTAssertEqual(Set(seen).count, count)
    let newestFirst = (0..<count).reversed().map {
      String(format: "7B1E0000-0000-4000-8000-1%011d", $0)
    }
    XCTAssertEqual(seen.map { $0.uppercased() }, newestFirst)

    // The audit and the quota count each page's own text.
    let reads = await records.audit.filter { $0.tool == "get_matter" }
    XCTAssertEqual(reads.count, pageCount)
    XCTAssertEqual(reads.first?.byteCount, first.text.utf8.count)
    XCTAssertTrue(reads.allSatisfy { $0.byteCount < 36_000 }, "\(reads.map(\.byteCount))")

    // A page past the last, page 0, and page without detail=full are argument errors.
    let past = await client.call(
      "get_matter", ["id": .string(big), "detail": "full", "page": .int(Int64(pageCount + 1))])
    XCTAssertEqual(past.errorCode, "invalid_arguments")
    XCTAssertTrue(past.text.contains("共 \(pageCount) 页"), past.text)
    for arguments: JSONValue in [
      ["id": .string(big), "detail": "full", "page": 0],
      ["id": .string(big), "page": 2],
      ["id": .string(big), "detail": "full", "page": "2"],
    ] {
      let refused = await client.call("get_matter", arguments)
      XCTAssertEqual(refused.errorCode, "invalid_arguments", "\(arguments)")
    }
    // A small matter is one page and says nothing about pages.
    let small = try self.service()
    await owner.queue(allowAll())
    let other = await AgentTestClient(service: small)
    let twin = await other.plainCall(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    XCTAssertFalse(twin.isErrorResult, twin.text)
    XCTAssertFalse(twin.text.contains("页："), twin.text)
    XCTAssertEqual(itemIDs(twin.text).count, 3)
    // The description says how to page.
    XCTAssertTrue(AgentTool.getMatter.summary.contains("page"))
    XCTAssertNotNil(AgentTool.getMatter.inputSchema["properties"]?["page"])
    XCTAssertTrue(MCPServerInfo.instructions.contains("page"))
  }
}
