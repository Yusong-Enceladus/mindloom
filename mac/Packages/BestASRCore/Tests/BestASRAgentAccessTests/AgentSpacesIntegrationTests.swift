import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// v7 integration (AGENT- × SPACES- × MAP-CONTRACT; review note "Note on
/// integration"): what an agent sees once spaces and the map are merged. A
/// shared space's matters are labelled with their space and never folded into
/// the member's own matter, so a grant for 我的 never reaches them; ropes and
/// strands come from the maps; reads of a space are told to that space's log
/// as counts only.
final class AgentSpacesIntegrationTests: XCTestCase {
  private static let sentinel = "SENTINEL-SPACE-ONLY-4K"
  private static let cafe = "E-CAFE"
  private static let lab = "8f0c2a5e-4c1b-4d7e-9a61-0d2f3b4c5d6e"

  /// 我的: one matter with a map (two strands) on a rope. The space: the same
  /// matter assembled from the member's item and a teammate's item, under the
  /// same organizer id, with its own rope.
  private static func snapshot() -> AgentMemorySnapshot {
    let mine = AgentFixture.record(0, text: "咖啡馆招牌明天装好", source: "备忘录", hoursAgo: 3)
    let other = AgentFixture.record(
      1, text: "咖啡馆的豆子周五送到 \(sentinel)", source: "共享空间", hoursAgo: 2)
    let personalEvent = MemoryEventSource(
      eventID: cafe, origin: .spark, title: "咖啡馆开业", statusLine: "招牌明天装好", pinned: false,
      updatedAt: AgentFixture.now, itemIDs: [AgentFixture.items[0].uuidString], personIDs: [],
      map: RemoteOrganizerMatterMap(
        strands: [
          .init(id: "s1", name: "招牌", itemIDs: [AgentFixture.items[0].uuidString]),
          .init(id: "s2", name: "开业日", state: "closed"),
        ],
        knots: []))
    let personal = MemoryProjection(
      events: [personalEvent], records: [mine], now: AgentFixture.now,
      ropes: [RemoteOrganizerRope(id: "r-life", title: "生活", children: [cafe], proposed: false)])
    let spaceEvent = MemoryEventSource(
      eventID: cafe, origin: .spark, title: "咖啡馆开业（共享）", statusLine: "豆子周五到", pinned: false,
      updatedAt: AgentFixture.now, itemIDs: [0, 1].map { AgentFixture.items[$0].uuidString },
      personIDs: [])
    let space = MemoryProjection(
      events: [spaceEvent], records: [mine, other], now: AgentFixture.now,
      ropes: [RemoteOrganizerRope(id: "r-shop", title: "开店", children: [cafe])])
    return AgentMemorySnapshot(
      personal: personal,
      spaces: [
        AgentSpaceSource(space: AgentSpace(id: lab, name: "拾光咖啡馆"), projection: space)
      ],
      timeZone: AgentFixture.timeZone)
  }

  private var spaceCafe: String {
    AgentMemorySnapshot.spaceMatterID(space: Self.lab, event: Self.cafe)
  }

  func testSpaceMattersAreLabelledAndKeepTheirOwnItems() {
    let snapshot = Self.snapshot()
    XCTAssertEqual(snapshot.projection.events.map(\.eventID), [Self.cafe, spaceCafe])
    XCTAssertEqual(snapshot.space(of: Self.cafe), AgentSpaceID.personal)
    XCTAssertEqual(snapshot.space(of: spaceCafe), Self.lab)
    XCTAssertEqual(snapshot.spaces.map(\.name), ["我的", "拾光咖啡馆"])
    // my matter is not widened with the teammate's item (全部 does that, agents do not)
    XCTAssertEqual(snapshot.projection.events[0].itemIDs, [AgentFixture.items[0].uuidString])
    XCTAssertEqual(snapshot.projection.events[1].itemIDs.count, 2)
    XCTAssertNotNil(snapshot.projection.records[AgentFixture.items[1].uuidString.uppercased()])
    // ropes: mine as is, the space's renamed into the same id space
    XCTAssertEqual(snapshot.ropeChain(of: Self.cafe).map(\.title), ["生活"])
    XCTAssertEqual(snapshot.ropeChain(of: spaceCafe).map(\.title), ["开店"])
    // strands from the map
    XCTAssertEqual(snapshot.strands(of: Self.cafe).map(\.name), ["招牌", "开业日"])
    XCTAssertEqual(snapshot.strands(of: Self.cafe).map(\.isOpen), [true, false])
  }

  func testAGrantForMineNeverReachesASpaceAndASpaceGrantOnlyThatSpace() async throws {
    let owner = ScriptedOwner()
    let clock = MutableClock(AgentFixture.now)
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: Self.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner,
      configuration: .init(consentTimeout: .seconds(5), denialCooldown: 60),
      timeZone: AgentFixture.timeZone, clock: { clock.now })

    await owner.queue(allowAll(spaces: ["personal"]))
    let mine = await AgentTestClient(service: service)
    let found = await mine.call("search_matters", ["query": "咖啡馆"]).matterIDs
    XCTAssertEqual(found, [Self.cafe])
    let recent = await mine.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(recent, [Self.cafe])
    let refused = await mine.call("get_matter", ["id": .string(spaceCafe)])
    XCTAssertEqual(refused.errorCode, "not_found")
    let read = await mine.call("get_matter", ["id": .string(Self.cafe)])
    XCTAssertFalse(read.text.contains(Self.sentinel))
    XCTAssertTrue(read.text.contains("招牌"))  // its strands are part of the text lens

    await owner.queue(allowAll(spaces: [Self.lab]))
    let shared = await AgentTestClient(
      service: service, name: "cursor-vscode", path: "/Applications/Cursor.app/x")
    let inSpace = await shared.call("list_recent", ["days": 14]).matterIDs
    XCTAssertEqual(inSpace, [spaceCafe])
    let text = await shared.call("get_matter", ["id": .string(spaceCafe)]).text
    XCTAssertTrue(text.contains(Self.sentinel))
    XCTAssertTrue(text.contains("拾光咖啡馆"))
    let mineRefused = await shared.call("get_matter", ["id": .string(Self.cafe)])
    XCTAssertEqual(mineRefused.errorCode, "not_found")

    // every audited call reaches the App, which tells the space's log (counts only)
    let recorded = await owner.recorded
    let spaceReads = recorded.flatMap { record in
      AgentSpaceAccess.entries(for: record) { $0 == self.spaceCafe ? 2 : 1 }
    }
    XCTAssertFalse(spaceReads.isEmpty)
    XCTAssertTrue(spaceReads.allSatisfy { $0.spaceID == Self.lab && $0.client == "Cursor" })
    XCTAssertTrue(spaceReads.contains { $0.tool == "get_matter" && $0.items == 2 && $0.allowed })
  }

  func testOnlyAllowedOrDeniedSpaceReadsAreToldAndBytesAreShared() {
    func record(_ outcome: AgentAuditOutcome, _ ids: [String], bytes: Int = 900)
      -> AgentAuditRecord
    {
      AgentAuditRecord(
        at: AgentFixture.now, clientKey: "k", clientName: "Claude Code", grantID: nil,
        tool: "search_matters", outcome: outcome, matterIDs: ids, byteCount: bytes)
    }
    let ids = ["E1", "space:lab:E1", "space:lab:E2", "space:shop:E9"]
    let entries = AgentSpaceAccess.entries(for: record(.allowed, ids)) { _ in 3 }
    XCTAssertEqual(entries.map(\.spaceID), ["lab", "shop"])
    XCTAssertEqual(entries.map(\.matters), [2, 1])
    XCTAssertEqual(entries.map(\.items), [6, 3])
    XCTAssertEqual(entries.map(\.bytes), [450, 225])
    XCTAssertEqual(AgentSpaceAccess.entries(for: record(.denied, ids)) { _ in 0 }.count, 2)
    for outcome in [AgentAuditOutcome.pending, .notFound, .invalid, .failed] {
      XCTAssertEqual(AgentSpaceAccess.entries(for: record(outcome, ids)) { _ in 1 }, [])
    }
    XCTAssertEqual(AgentSpaceAccess.entries(for: record(.allowed, ["E1", "E2"])) { _ in 1 }, [])
    XCTAssertNil(AgentSpaceAccess.space(ofMatter: "space::E1"))
    XCTAssertNil(AgentSpaceAccess.space(ofMatter: "space:lab:"))
    XCTAssertEqual(AgentSpaceAccess.space(ofMatter: "space:lab:a:b"), "lab")
  }
}
