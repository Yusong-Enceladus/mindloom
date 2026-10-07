import BestASRAgentAccess
import BestASRDomain
import Foundation
import MindloomAgentProtocol
import XCTest

/// End-to-end run with Claude Code 2.1 (2026-10-06, regression): Claude Code
/// hands a tool result's `structuredContent` to the model in place of its
/// text, so the model read the library outside the fence (F12) and `today`
/// without the matters' titles; and it repeated 「Mindloom（织机）」 from the
/// server's instructions to the owner. Every result is now the fenced text
/// alone; a script or test that asks gets the same data in `_meta`.
final class AgentResultShapeTests: XCTestCase {
  private func service(owner: ScriptedOwner) throws -> AgentAccessService {
    let clock = MutableClock(AgentFixture.now)
    return AgentAccessService(
      // A status line with a dated step tomorrow, so `today` lists one.
      memory: FixedMemory(snapshot: try AgentFixture.snapshot(twinStatus: "10月1日交第三组数据")),
      records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner, changes: RecordingChanges(),
      configuration: .init(consentTimeout: .seconds(5), denialCooldown: 60, limits: .init()),
      timeZone: AgentFixture.timeZone, clock: { clock.now })
  }

  func testEveryToolResultIsTheFencedTextWithTheDataInMeta() async throws {
    let owner = ScriptedOwner()
    await owner.queue(allowAll(change: true))
    let client = await AgentTestClient(service: try service(owner: owner))
    _ = await client.request(
      "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code"]])
    let calls: [(String, [String: JSONValue])] = [
      ("today", [:]), ("search", ["query": "Twin"]),
      ("get_matter", ["id": .string(AgentFixture.twin)]),
      ("get_matter", ["id": .string(AgentFixture.twin), "detail": "full"]),
      ("get_person", ["name": "林晓"]), ("list_deadlines", ["days": 14]),
      ("list_recent", ["days": 7]),
    ]
    for (tool, arguments) in calls {
      let result = await client.call(tool, .object(arguments))
      XCTAssertFalse(result.isErrorResult, "\(tool): \(result.text)")
      XCTAssertNil(result["structuredContent"], tool)
      XCTAssertNotNil(result.structured, tool)
      XCTAssertFalse(result.text.fenced.isEmpty, "\(tool): \(result.text)")
    }

    // `today` names each matter it lists, inside the fence.
    let today = await client.call("today")
    let rows = (today.structured?["due"]?.arrayValue ?? [])
      + (today.structured?["overdue"]?.arrayValue ?? [])
    XCTAssertFalse(rows.isEmpty, today.text)
    for row in rows {
      let title = try XCTUnwrap(row["title"]?.stringValue)
      XCTAssertTrue(today.text.fenced.contains("“\(title)”"), today.text)
    }

    // As an agent calls it (no request `_meta`): the text alone.
    for (tool, arguments) in calls {
      let plain = await client.plainCall(tool, .object(arguments))
      XCTAssertNil(plain["structuredContent"], tool)
      XCTAssertNil(plain["_meta"], tool)
      XCTAssertFalse(plain.text.fenced.isEmpty, "\(tool): \(plain.text)")
    }

    // A change's answer and a refusal are text too.
    let note = await client.call("add_note", ["text": "交接说明正文", "title": "交接"])
    XCTAssertFalse(note.isErrorResult, note.text)
    XCTAssertNil(note["structuredContent"])
    XCTAssertEqual(note.structured?["item_id"]?.stringValue, RecordingChanges.noteItemID)
    let missing = await client.call("get_matter", ["id": "no-such-matter"])
    XCTAssertTrue(missing.isErrorResult)
    XCTAssertNil(missing["structuredContent"])
    XCTAssertEqual(missing.errorCode, "not_found")
    XCTAssertEqual(missing.text, AgentCopy.notFound)
  }

  /// The helper's own replies (Mindloom not running, 允许其他 App 读 off).
  func testTheHelpersOwnRepliesHaveNoStructuredContent() throws {
    let offline = AgentOfflineResponder.notRunningToolResult
    XCTAssertNil(offline["structuredContent"])
    XCTAssertEqual(AgentToolResult.data(of: offline)?["error"], "not_running")
    XCTAssertEqual(offline.text, AgentCopy.notRunning)
    let call = MCPMessage.decode(
      MCPMessage.request(id: 7, method: "tools/call", params: ["name": "today", "arguments": [:]]))
    let reply = try XCTUnwrap(AgentOfflineResponder.switchedOffReply(to: call))
    XCTAssertNil(reply["result"]?["structuredContent"])
    XCTAssertEqual(reply["result"]?.structured?["error"], "switched_off")
    XCTAssertEqual(reply["result"]?.text, AgentCopy.switchedOff)
  }

  /// Asked who said something, the model answered with the nickname in the
  /// search excerpt and stopped (2 of 4 runs); the search tool now says the
  /// excerpt is partial and where to read the item in full.
  func testSearchSaysWhereToConfirmWhoSaidSomething() {
    let summary = AgentTool.search.summary
    XCTAssertTrue(summary.contains("“为什么找到”只是一小段摘录"), summary)
    // Review 10-5d R8: one item, not the matter's whole text.
    XCTAssertTrue(summary.contains("get_matter 加 item_id"), summary)
    XCTAssertFalse(summary.contains("get_matter 加 detail=full"), summary)
  }

  /// The model tells the owner 「Mindloom」; 「织机」 is only how the owner
  /// may still call it (UI-COPY §1 and §4).
  func testTheServerInstructionsNameMindloom() {
    let text = MCPServerInfo.instructions
    XCTAssertTrue(text.hasPrefix("Mindloom 是"), text)
    XCTAssertFalse(text.contains("Mindloom（织机）"), text)
    XCTAssertTrue(text.contains("回答主人时写 Mindloom"), text)
    XCTAssertTrue(text.contains("织机"), "the owner's other word stays recognisable")
  }
}
