import BestASRDomain
import Foundation
import MindloomAgentProtocol
import XCTest

@testable import BestASRAgentAccess

/// Review 10-5d R8 (regression): `search` told the agent to read a matter's
/// whole text (`get_matter` with `detail=full`) to see who said a sentence.
/// The end-to-end run measured one such read at 49.6 KB and Claude Code's
/// `resources/list` at every start at 11.4 KB, against 200 KB per grant and
/// hour: a few questions an hour and the agent was refused. One item now
/// reads with its speaker and the two sentences around the one asked about,
/// and the resource list names each matter by its title and id only.
final class AgentItemReadTests: XCTestCase {
  private func client() async throws -> AgentTestClient {
    let owner = ScriptedOwner()
    await owner.queue(allowAll())
    let clock = MutableClock(AgentFixture.now)
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner, changes: RecordingChanges(),
      configuration: .init(consentTimeout: .seconds(5), denialCooldown: 60, limits: .init()),
      timeZone: AgentFixture.timeZone, clock: { clock.now })
    let client = await AgentTestClient(service: service)
    _ = await client.request(
      "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code"]])
    return client
  }

  func testWhoSaidItIsReadFromOneItemNotTheWholeMatter() async throws {
    let client = try await client()
    XCTAssertTrue(AgentTool.search.summary.contains("item_id"), AgentTool.search.summary)
    XCTAssertFalse(AgentTool.search.summary.contains("detail=full 读那条原文"))
    XCTAssertNotNil(AgentTool.getMatter.inputSchema["properties"]?["item_id"])
    XCTAssertNotNil(AgentTool.getMatter.inputSchema["properties"]?["around"])

    let search = await client.call("search", ["query": "把表更新好"])
    XCTAssertFalse(search.isErrorResult, search.text)
    let hit = try XCTUnwrap(
      search.structured?["matters"]?.arrayValue?.first { $0["item_id"]?.stringValue != nil },
      search.text)
    let itemID = try XCTUnwrap(hit["item_id"]?.stringValue)
    let why = try XCTUnwrap(hit["why"]?.stringValue)
    XCTAssertEqual(itemID.uppercased(), AgentFixture.items[0].uuidString.uppercased())

    let one = await client.call(
      "get_matter",
      ["id": .string(AgentFixture.twin), "item_id": .string(itemID), "around": .string(why)])
    XCTAssertFalse(one.isErrorResult, one.text)
    XCTAssertTrue(one.text.fenced.contains("林晓：好的，我把表更新好"), one.text)
    XCTAssertTrue(one.text.fenced.contains("韩策："), "the line before, with its speaker")
    XCTAssertEqual(one.structured?["matched"], true)
    XCTAssertFalse(one.serialized.contains(AgentFixture.phone), "numbers stay hidden")
    let full = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "detail": "full"])
    XCTAssertLessThan(
      one.text.utf8.count, full.text.utf8.count,
      "one item is a fraction of the matter's whole text")

    // The item must be in that matter; `around` goes with `item_id`.
    let elsewhere = await client.call(
      "get_matter",
      ["id": .string(AgentFixture.twin), "item_id": .string(AgentFixture.items[3].uuidString)])
    XCTAssertEqual(elsewhere.errorCode, "not_found")
    let lonely = await client.call(
      "get_matter", ["id": .string(AgentFixture.twin), "around": "表"])
    XCTAssertEqual(lonely.errorCode, "invalid_arguments")

    // The list Claude Code reads at every start: titles and ids.
    let resources = await client.request("resources/list")["result"]?["resources"]?.arrayValue
    XCTAssertFalse(resources?.isEmpty ?? true)
    for resource in resources ?? [] {
      XCTAssertNotNil(resource["title"]?.stringValue)
      XCTAssertNotNil(resource["uri"]?.stringValue)
      XCTAssertNil(resource["description"], "no status line")
    }
  }

  /// The lines an item read shows: the closest line to `around` and two on
  /// each side; the first lines when nothing is close.
  func testAnItemReadCentresOnTheClosestLine() {
    let lines = (1...9).map { "说话人\($0)：第\($0)句，内容\($0 * 11)" }
    let centred = AgentReader.window(lines, around: "第5句，内容55", context: 2)
    XCTAssertTrue(centred.matched)
    XCTAssertEqual(centred.range, 2..<7)
    let cut = AgentReader.window(lines, around: "…第9句，内容99…", context: 2)
    XCTAssertEqual(cut.range, 6..<9, "an excerpt's 「…」 is ignored; the window stops at the end")
    let nothing = AgentReader.window(lines, around: "完全无关", context: 2)
    XCTAssertFalse(nothing.matched)
    XCTAssertEqual(nothing.range, 0..<5)
    XCTAssertEqual(AgentReader.window(lines, around: nil, context: 2).range, 0..<5)
    XCTAssertEqual(AgentReader.window([], around: "x", context: 2).range, 0..<0)
    XCTAssertEqual(AgentReader.window(["只有一句"], around: "只有", context: 2).range, 0..<1)
  }
}
