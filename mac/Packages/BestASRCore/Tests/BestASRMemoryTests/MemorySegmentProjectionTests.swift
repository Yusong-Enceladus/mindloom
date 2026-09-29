import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// A meeting the organizing device split over several events, and the read
/// model at scale. Synthetic data only.
final class MemorySegmentProjectionTests: XCTestCase {
  private let zone = TimeZone(secondsFromGMT: 8 * 3_600)!
  // 2026-09-21 14:00:00 +08:00
  private let base = Date(timeIntervalSince1970: 1_789_970_400)

  private func id(_ n: Int) -> SessionID {
    SessionID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
  }

  static let meeting = """
    虚构项目周会

    苗青禾(00:00:03):
    先说展会：展位定在二号馆，三米乘三米。

    欧阳帆(00:00:40):
    海报我周三前出两版。

    苗青禾(00:01:20):
    另一件事，仓库下月搬家，周五前把清单给我。

    欧阳帆(00:02:05):
    好，我列一下要搬的货架。
    """

  /// Offsets of the turns, so the parts are turn-aligned.
  private var turns: [MemoryTranscriptText.Turn] {
    MemoryTranscriptText.parse(Self.meeting)!.turns
  }

  private func projection() -> MemoryProjection {
    let meetingID = id(1).rawValue.uuidString
    let expo = MemoryItemSegment(
      itemID: meetingID, segID: "s1", start: turns[0].start, end: turns[1].end, gist: "展会展位和海报")
    let move = MemoryItemSegment(
      itemID: meetingID, segID: "s2", start: turns[2].start, end: turns[3].end, gist: "仓库搬家清单")
    let records = [
      MemoryItemRecord(
        sessionID: id(1), inputMode: .userItem, itemKind: .document, title: "周会.txt",
        startedAt: base, updatedAt: base, sourceBundleID: "com.tencent.meeting",
        sourceDisplayName: "腾讯会议", sourceIdentifier: "周会.txt", text: Self.meeting),
      MemoryItemRecord(
        sessionID: id(2), inputMode: .userItem, itemKind: .text, title: "海报",
        startedAt: base.addingTimeInterval(3_600), updatedAt: base.addingTimeInterval(3_600),
        sourceBundleID: "com.tencent.xinWeChat", sourceDisplayName: "微信", sourceIdentifier: nil,
        text: "欧阳帆：海报初稿发你了"),
    ]
    let events = [
      MemoryEventSource(
        eventID: "ev-expo", origin: .spark, title: "秋季展会", statusLine: "", pinned: false,
        updatedAt: base, itemIDs: [meetingID, id(2).rawValue.uuidString], personIDs: [],
        segments: [expo]),
      MemoryEventSource(
        eventID: "ev-move", origin: .spark, title: "仓库搬家", statusLine: "", pinned: false,
        updatedAt: base, itemIDs: [meetingID], personIDs: [], segments: [move]),
    ]
    return MemoryProjection(events: events, records: records, now: base)
  }

  func testEachEventShowsOnlyItsPartAndLinksTheOthers() throws {
    let projection = projection()
    let expo = try XCTUnwrap(projection.event(id: "ev-expo"))
    let part = try XCTUnwrap(expo.items.first { $0.segment != nil })
    XCTAssertEqual(part.segment?.segID, "s1")
    XCTAssertEqual(part.id, "\(id(1).rawValue.uuidString)#s1")
    XCTAssertEqual(part.siblings.map(\.eventID), ["ev-move"])
    XCTAssertEqual(part.siblings.first?.title, "仓库搬家")
    let shown = try XCTUnwrap(part.shownText)
    XCTAssertTrue(shown.hasPrefix("苗青禾(00:00:03):"), shown)
    XCTAssertTrue(shown.contains("海报我周三前出两版。"))
    XCTAssertFalse(shown.contains("仓库"), "the other matter stays in its own event")
    // Its part still reads as a transcript (turn-aligned).
    XCTAssertEqual(MemoryTranscriptText.parse(shown)?.turns.map(\.speaker), ["苗青禾", "欧阳帆"])

    let move = try XCTUnwrap(projection.event(id: "ev-move"))
    XCTAssertEqual(move.items.count, 1)
    XCTAssertTrue(move.items[0].shownText?.contains("仓库下月搬家") == true)
    XCTAssertEqual(move.items[0].siblings.map(\.eventID), ["ev-expo"])

    // Search and the card's text only see this event's part.
    let home = projection.home()
    let expoCard = try XCTUnwrap(home.first { $0.eventID == "ev-expo" })
    let moveCard = try XCTUnwrap(home.first { $0.eventID == "ev-move" })
    XCTAssertTrue(expoCard.matches("二号馆"))
    XCTAssertFalse(expoCard.matches("货架"))
    XCTAssertTrue(moveCard.matches("货架"))
    XCTAssertFalse(moveCard.matches("二号馆"))
    XCTAssertEqual(moveCard.coverText?.lines.first, "苗青禾(00:01:20):")
    // The whole item (as a question shows it) is not cut.
    XCTAssertNil(projection.item(id(1).rawValue.uuidString).segment)
  }

  func testExportHasOnlyThePartWithAReferenceToTheRest() throws {
    let detail = try XCTUnwrap(projection().event(id: "ev-move"))
    let text = EventPlainTextFormatter(timeZone: zone).format(detail)
    XCTAssertTrue(text.contains(EventPlainTextFormatter.preambleWithSegments), text)
    XCTAssertTrue(
      text.contains(
        "14:00 · 来源：腾讯会议 · 周会.txt\n节选：仓库搬家清单；同一段记录还涉及：「秋季展会」\n"
          + "> 苗青禾（00:01:20）：另一件事，仓库下月搬家，周五前把清单给我。\n"
          + "> 欧阳帆（00:02:05）：好，我列一下要搬的货架。\n"), text)
    XCTAssertFalse(text.contains("二号馆"), text)
  }

  func testAnUnsplitTranscriptExportsAsTurns() throws {
    let record = MemoryItemRecord(
      sessionID: id(9), inputMode: .userItem, itemKind: .text, title: "会议",
      startedAt: base, updatedAt: base, sourceBundleID: nil, sourceDisplayName: "飞书",
      sourceIdentifier: nil, text: "石磊 00:00:40\n三米乘三米。\n\n石磊 00:01:00\n靠近入口。\n\n韩溪 00:01:30\n好。")
    let source = MemoryEventSource(
      eventID: "ev", origin: .spark, title: "展位", statusLine: "", pinned: false,
      updatedAt: base, itemIDs: [id(9).rawValue.uuidString], personIDs: [])
    let detail = try XCTUnwrap(
      MemoryProjection(events: [source], records: [record]).event(id: "ev"))
    let text = EventPlainTextFormatter(timeZone: zone).format(detail)
    XCTAssertTrue(
      text.contains("> 石磊（00:00:40）：三米乘三米。\n> 石磊（00:01:00）：靠近入口。\n> 韩溪（00:01:30）：好。"), text)
    XCTAssertTrue(text.contains(EventPlainTextFormatter.preamble), text)
  }

  func testSegmentCorrectionsCarryTheSegID() {
    let remove = MemoryDecisions.remove(itemID: "I", from: "ev", segID: "s2")
    XCTAssertEqual(remove.segID, "s2")
    XCTAssertTrue(remove.isWellFormed)
    XCTAssertEqual(MemoryDecisions.move(itemID: "I", to: "ev", segID: "s3").segID, "s3")
    XCTAssertNil(MemoryDecisions.move(itemID: "I", to: "ev").segID)
  }

  /// 2000 items in 60 events with 40 people: the read model the pages use
  /// is built in well under a second, so the App can build it off the main
  /// thread on every change without the window waiting.
  func testReadModelFor2000ItemsAnd60Events() throws {
    let itemCount = 2_000
    let eventCount = 60
    var records: [MemoryItemRecord] = []
    var persons: [String] = []
    for n in 0..<40 { persons.append(String(format: "20000000-0000-0000-0000-%012d", n)) }
    for n in 0..<itemCount {
      let started = base.addingTimeInterval(Double(n) * 600)
      let isImage = n % 17 == 0
      records.append(
        MemoryItemRecord(
          sessionID: id(10_000 + n), inputMode: .userItem, itemKind: isImage ? .image : .text,
          title: "条目 \(n)", startedAt: started, updatedAt: started,
          sourceBundleID: "com.tencent.xinWeChat", sourceDisplayName: "微信", sourceIdentifier: nil,
          text: isImage ? "" : "虚构人物\(n % 40)：第 \(n) 条消息，关于事情 \(n % eventCount)。\n我：收到。",
          thumbnailAssetPath: isImage ? "sessions/\(n)/source/normalized.png" : nil))
    }
    var remoteEvents: [RemoteOrganizerEvent] = []
    for e in 0..<eventCount {
      let items = stride(from: e, to: itemCount, by: eventCount).map {
        id(10_000 + $0).rawValue.uuidString
      }
      remoteEvents.append(
        RemoteOrganizerEvent(
          eventID: "ev-\(e)", title: "事情 \(e)", statusLine: e % 3 == 0 ? "" : "进展 \(e)",
          importance: Double(eventCount - e) / Double(eventCount),
          updatedAt: "2026-09-2\(e % 7)T10:00:00+08:00", itemIDs: items,
          personIDs: [persons[e % 40], persons[(e * 7) % 40]]))
    }
    let people = persons.enumerated().map { index, id in
      try! JSONDecoder().decode(
        RemoteOrganizerPerson.self,
        from: Data(
          #"{"person_id": "\#(id)", "display_name": "虚构人物\#(index)", "aliases": []}"#.utf8))
    }
    let remote = RemoteOrganizerProjection(
      cursor: 9, events: remoteEvents, questions: [], persons: people,
      unfiled: (0..<50).map { RemoteOrganizerUnfiledItem(itemID: "missing-\($0)", reason: "none") })
    let clock = ContinuousClock()
    let started = clock.now
    let model = MemoryReadModel(
      MemoryProjection(remote: remote, records: records, now: base))
    let detail = model.projection.event(id: "ev-0")
    let elapsed = clock.now - started
    XCTAssertEqual(model.home.count, eventCount)
    XCTAssertEqual(model.people.count, 40)
    XCTAssertEqual(detail?.items.count, itemCount / eventCount + 1)
    XCTAssertEqual(model.recentPeople.count, 40)
    XCTAssertTrue(model.home[0].matches("第 60 条消息"))
    // Generous for an unoptimized debug build on a busy machine.
    XCTAssertLessThan(elapsed, .seconds(3), "read model took \(elapsed)")
    print("bestASR read model: 2000 items / 60 events in \(elapsed)")
  }
}
