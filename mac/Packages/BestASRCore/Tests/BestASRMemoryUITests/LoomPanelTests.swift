import AppKit
import BestASRDomain
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// 「最近在动的事」 on Home with the synthetic fixtures: the split meeting is
/// one weft over its three matters, the pointer finds days and what a click
/// opens, chips never overlap, and the panel and Home render in light and
/// dark (to `BESTASR_UI_SNAPSHOT_DIR`).
@MainActor
final class LoomPanelTests: XCTestCase {
  private typealias F = MemorySnapshotFixture

  private var scale: MemoryScreenState {
    MemoryScreenState(
      mode: .spark,
      readModel: MemoryReadModel(MemoryScaleFixture.projection, calendar: F.calendar),
      now: F.now, calendar: F.calendar, thumbnail: F.thumbnail)
  }

  func testTheSplitMeetingIsOneWeftOverItsThreeMatters() throws {
    let loom = try XCTUnwrap(scale.looms[.twoWeeks])
    XCTAssertTrue(loom.isShown)
    XCTAssertEqual(loom.lanes.count, MemoryLoom.maximumLanes)
    XCTAssertEqual(Array(loom.lanes.prefix(3)).map(\.eventID), ["ev-0", "ev-1", "ev-2"])
    let meeting = F.item(MemoryScaleFixture.meetingItem).uppercased()
    let weft = try XCTUnwrap(loom.wefts.first { $0.itemID == meeting })
    XCTAssertEqual(weft.lanes, [0, 1, 2])
    XCTAssertEqual(weft.kind, .meeting)
    for lane in 0..<3 {
      XCTAssertEqual(loom.lanes[lane].knots.first { $0.day == weft.day }?.kind, .meeting)
    }
    // "Now" is the newest item in the library, not the clock.
    XCTAssertEqual(
      F.calendar.startOfDay(for: loom.now), F.calendar.startOfDay(for: F.date(9, 27, 12, 0)))
  }

  func testThePointerFindsDaysAndAClickOpensTheirRows() throws {
    let loom = try XCTUnwrap(scale.looms[.twoWeeks])
    let layout = LoomLayout(loom: loom, width: 780)
    let knot = try XCTUnwrap(loom.lanes[0].knots.first)
    let point = CGPoint(x: layout.x(knot.day), y: layout.y(0))
    XCTAssertEqual(layout.hit(point), .day(lane: 0, day: knot.day))
    XCTAssertEqual(layout.target(point)?.lane, 0)
    XCTAssertEqual(layout.target(point)?.rows, knot.items.map(\.rowID))
    XCTAssertFalse(knot.items.isEmpty)
    // The card is headed by the day, not a count.
    XCTAssertEqual(LoomPanel.monthDay(F.date(9, 16, 12, 0), F.calendar, weekday: true), "9月16日 周三")
    // A day that took nothing in: no card, and a click opens the matter.
    let quiet = try XCTUnwrap(
      (0..<loom.todayIndex).first { day in !loom.lanes[0].knots.contains { $0.day == day } })
    let empty = CGPoint(x: layout.x(quiet), y: layout.y(0))
    XCTAssertNil(layout.hit(empty))
    XCTAssertEqual(layout.target(empty)?.rows, [])
    // Rows, the header, and outside the axis.
    XCTAssertEqual(layout.lane(atY: layout.y(4)), 4)
    XCTAssertEqual(layout.lane(atY: layout.laneTop(1) + 1), 1)
    XCTAssertNil(layout.lane(atY: 10))
    XCTAssertNil(layout.lane(atY: layout.height + 20))
    XCTAssertNil(layout.hit(CGPoint(x: -4, y: layout.y(0))))
    // The first lane is taller; the axis spans the past and the next week.
    XCTAssertGreaterThan(layout.laneHeight(0), layout.laneHeight(1))
    XCTAssertEqual(layout.dayWidth * CGFloat(loom.totalDays), 780, accuracy: 0.01)
    XCTAssertEqual(layout.todayX, layout.x(loom.days - 1), accuracy: 0.01)
  }

  // MARK: - Chips

  private func record(_ n: Int, at: Date) -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: F.item(n))!), inputMode: .userItem,
      itemKind: .text, title: "记录", startedAt: at, updatedAt: at,
      sourceBundleID: "com.tencent.xinWeChat", sourceDisplayName: "微信", sourceIdentifier: nil,
      text: "周经理：好的")
  }

  private func fact(_ text: String, _ state: MemoryStatusFact.State, _ day: Int)
    -> MemoryStatusFact
  {
    MemoryStatusFact(
      text: text, state: state, day: DateComponents(year: 2026, month: 9, day: day))
  }

  /// Four milestones on four days in a row and two flags a day apart.
  private var crowded: MemoryLoom {
    let records = (0..<6).map { record(900 + $0, at: F.date(9, 21 + $0, 10, 0)) }
    let facts = [
      fact("初稿写完了", .done, 21), fact("导师看过初稿", .done, 22),
      fact("改完第二轮了", .done, 23), fact("终稿定下来了", .done, 24),
      fact("交回复信", .planned, 26), fact("中期汇报", .planned, 27),
    ]
    let events = [
      MemoryEventSource(
        eventID: "a", origin: .spark, title: "事 a", statusLine: "进行中", pinned: false,
        updatedAt: nil, itemIDs: (900..<905).map { F.item($0) }, personIDs: [],
        statusFacts: facts),
      MemoryEventSource(
        eventID: "b", origin: .spark, title: "事 b", statusLine: "进行中", pinned: false,
        updatedAt: nil, itemIDs: [F.item(905)], personIDs: []),
    ]
    let projection = MemoryProjection(events: events, records: records, now: F.date(9, 26, 0, 0))
    return MemoryReadModel(projection, calendar: F.calendar).looms[.twoWeeks]!
  }

  func testChipsNeverOverlapAndTheLatestMilestoneKeepsItsChip() throws {
    let loom = crowded
    XCTAssertEqual(loom.lanes[0].milestones.count, MemoryLoom.maximumMilestones)
    for width in [420.0, 780.0] {
      let layout = LoomLayout(loom: loom, width: width)
      let chips = layout.milestoneChips(0)
      let flags = layout.flagChips(0, calendar: F.calendar)
      let rects = chips.map(\.rect) + flags.map(\.rect)
      for (i, a) in rects.enumerated() {
        for b in rects[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(width): \(a) \(b)") }
        XCTAssertGreaterThanOrEqual(a.minX, 0)
        XCTAssertLessThanOrEqual(a.maxX, width)
      }
      XCTAssertEqual(chips.last?.index, loom.lanes[0].milestones.count - 1)
      // The first flag's chip sits under the line.
      let first = try XCTUnwrap(flags.first)
      XCTAssertEqual(first.index, 0)
      XCTAssertGreaterThan(first.rect.midY, layout.y(0))
    }
    // Narrow: the middle milestone gives up its chip, the second flag goes above.
    let narrow = LoomLayout(loom: loom, width: 420)
    XCTAssertLessThan(narrow.milestoneChips(0).count, 3)
    // Wide: every chip fits.
    let wide = LoomLayout(loom: loom, width: 2000)
    XCTAssertEqual(wide.milestoneChips(0).count, 3)
    // The flag a day later goes above the line.
    let mid = LoomLayout(loom: loom, width: 780)
    let flags = mid.flagChips(0, calendar: F.calendar)
    XCTAssertEqual(flags.map(\.index), [0, 1])
    XCTAssertLessThan(flags[1].rect.midY, mid.y(0))
    XCTAssertEqual(wide.flagWords(loom.lanes[0].flags[0], calendar: F.calendar).day, "今天")
    XCTAssertEqual(wide.flagWords(loom.lanes[0].flags[1], calendar: F.calendar).day, "明天")
  }

  /// The small fixture's Home has its matters on the axis too, in light and
  /// dark, and with one person chosen.
  func testRenderLoomSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["BESTASR_UI_SNAPSHOT_DIR"],
      !directory.isEmpty
    else {
      throw XCTSkip("Set BESTASR_UI_SNAPSHOT_DIR to render the time axis snapshots.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let state = scale
    let loom = try XCTUnwrap(state.looms[.twoWeeks])
    let person = state.featuredPeople.first(where: \.isNamed)?.personID.uppercased()
    let meeting = F.item(MemoryScaleFixture.meetingItem).uppercased()
    let day = try XCTUnwrap(loom.wefts.first { $0.itemID == meeting }).day
    for (name, chosen, span, hover) in [
      ("loom-scale", nil as String?, MemoryLoom.Span.twoWeeks, nil as LoomHover?),
      ("loom-scale-person", person, .twoWeeks, nil),
      ("loom-scale-5w", nil, .fiveWeeks, nil),
      // The pointer on the split meeting's day: its card and the weft.
      ("loom-scale-hover", nil, .twoWeeks, .day(lane: 1, day: day)),
    ] {
      for scheme in [ColorScheme.light, .dark] {
        let view = ZhijiThemed {
          LoomPanel(
            loom: state.looms[span]!, span: .constant(span), state: state,
            person: .constant(chosen), people: state.featuredPeople.filter(\.isNamed),
            open: { _, _ in }, hover: hover
          )
          .padding(24)
          .frame(width: 1004 + 48)
          .background(HomeTones(ZhijiPalette.of(scheme)).page)
        }
        .environment(\.colorScheme, scheme)
        .environment(\.zhijiSnapshot, true)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, name)
        let png = try XCTUnwrap(
          NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(
          to: output.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"),
          options: .atomic)
      }
    }
  }
}
