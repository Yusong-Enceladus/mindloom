import AppKit
import BestASRDomain
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// v7 (MAP-CONTRACT §3): the matter lenses and the Home lenses on a
/// lab-sized synthetic library: what they show, their spoken labels, the
/// decisions they send, and how long they take to draw. Snapshots are
/// written to `BESTASR_UI_SNAPSHOT_DIR` when it is set.
@MainActor
final class MemoryLensTests: XCTestCase {
  typealias Lab = MemoryLabFixture
  typealias F = MemorySnapshotFixture

  private static let model = MemoryReadModel(Lab.projection, calendar: F.calendar)

  private func screen(_ model: MemoryReadModel = MemoryLensTests.model) -> MemoryScreenState {
    MemoryScreenState(
      mode: .spark, readModel: model, now: Lab.now, calendar: F.calendar,
      thumbnail: F.thumbnail)
  }

  private func render(
    _ navigation: MemoryNavigation, state: MemoryScreenState, dark: Bool = false,
    height: CGFloat = 900, actions: MemoryActions = .inert
  ) throws -> CGImage {
    let view = ZhijiShell(navigation: .constant(navigation), state: state, actions: actions)
      .frame(width: 1280, height: height)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.zhijiSnapshot, true)
      .environment(\.locale, Locale(identifier: "zh-Hans"))
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: 1280, height: height)
    renderer.scale = 1
    return try XCTUnwrap(renderer.cgImage)
  }

  // MARK: - What the lenses show

  func testLabFixtureDrivesTheHomeLenses() throws {
    let model = Self.model
    XCTAssertEqual(model.home.count, Lab.eventCount)
    let lenses = model.lenses
    // Seven ropes, one inside the first: six bands at the top.
    XCTAssertEqual(lenses.bands.count, 6)
    let grip = try XCTUnwrap(lenses.bands.first { $0.rope.title == "GripDiff论文" })
    XCTAssertEqual(grip.children.map(\.rope.title), ["数据采集"])
    XCTAssertEqual(grip.total, 5)
    // The confirmed rope comes first.
    XCTAssertFalse(try XCTUnwrap(lenses.bands.first).rope.proposed)
    let placed = Set(
      lenses.bands.flatMap { band in
        band.entries.map(\.eventID) + band.children.flatMap { $0.entries.map(\.eventID) }
      })
    XCTAssertEqual(placed.count + lenses.unroped.count, Lab.eventCount)
    XCTAssertTrue(Set(lenses.unroped.map(\.eventID)).isDisjoint(with: placed))
    // The ladder: matter 0's baseline is tomorrow (9/21), from its facts.
    XCTAssertEqual(lenses.rungs.map(\.kind), MemoryHomeLenses.Rung.Kind.allCases)
    let tomorrow = try XCTUnwrap(lenses.rungs.first { $0.kind == .tomorrow })
    XCTAssertTrue(tomorrow.deadlines.contains { $0.eventID == Lab.eventID(0) && !$0.fromMap })
    for rung in lenses.rungs {
      let days = rung.deadlines.map(\.daysAway)
      XCTAssertEqual(days, days.sorted(), "\(rung.kind) is in date order")
    }
    // 按人: at most eight people, the most matters first.
    XCTAssertLessThanOrEqual(lenses.people.count, MemoryHomeLenses.maximumPeople)
    let totals = lenses.people.map(\.total)
    XCTAssertEqual(totals, totals.sorted(by: >))
    XCTAssertTrue(
      lenses.people.allSatisfy { $0.entries.count <= MemoryHomeLenses.PersonLane.shown })
    // Every Home matter has an activity strip; matter 0 moved on many days.
    XCTAssertEqual(lenses.activity.count, Lab.eventCount)
    XCTAssertGreaterThan(lenses.activity[Lab.eventID(0)]?.days.count ?? 0, 20)
  }

  func testTheBigMatterDrawsItsStrandsKnotsAndStatus() throws {
    let projection = Self.model.projection
    let model = try XCTUnwrap(
      MemoryStrandModel(
        projection: projection, eventID: Lab.eventID(0), now: Self.model.lenses.now,
        calendar: F.calendar))
    XCTAssertTrue(model.hasMap)
    XCTAssertEqual(model.itemCount, Lab.twinItems)
    XCTAssertEqual(model.strands.map(\.name), ["真机实验与调试", "9/12 学院开放日"])
    XCTAssertEqual(model.strands.map(\.itemCount), [Lab.twinStrand.count, Lab.twinDemo.count])
    XCTAssertEqual(model.mainItemCount, Lab.twinItems - 72)
    XCTAssertEqual(model.strands[1].closed, true)
    XCTAssertEqual(model.allKnots.count, 9)
    let question = try XCTUnwrap(model.knot("k2"))
    XCTAssertEqual(question.glyph, .question)
    XCTAssertTrue(question.dateIsInferred)
    let baseline = try XCTUnwrap(model.knot("k7"))
    XCTAssertEqual(baseline.glyph, .planned)
    XCTAssertEqual(baseline.day - model.today, 1)
    XCTAssertEqual(baseline.who.map(\.name), ["林知远"])
    // The quote's item first, and it holds the quote.
    let repaired = try XCTUnwrap(model.knot("k6"))
    XCTAssertTrue(try XCTUnwrap(repaired.evidence.first).holdsQuote)
    XCTAssertEqual(repaired.evidence.first?.snippet, repaired.quote)

    let status = MemoryMatterStatus(
      model: model, statusLine: "数据已定", facts: projection.events[0].statusFacts,
      projection: projection, calendar: F.calendar)
    XCTAssertEqual(status.flag?.daysAway, 1)
    XCTAssertEqual(status.commitments.map(\.knotID), ["k7"])
    XCTAssertEqual(status.waitsOn.map(\.eventID), [Lab.eventID(2)])
    XCTAssertEqual(status.waitedBy, [])
    XCTAssertEqual(status.health?.level, .ok)

    // Every knot speaks its state, words and evidence.
    let state = screen()
    for knot in model.allKnots {
      let spoken = StrandMapView.spoken(knot, model: model, state: state)
      XCTAssertTrue(spoken.hasPrefix(ZhijiCopy.knotState(knot.glyph.rawValue)), spoken)
      XCTAssertTrue(spoken.contains(knot.text), spoken)
      XCTAssertTrue(spoken.contains(ZhijiCopy.evidenceCount(knot.evidence.count)), spoken)
    }
  }

  func testAMatterWithoutAMapShowsItsFactsOnOneThread() throws {
    let projection = Self.model.projection
    // Matter 29 has a planned fact and no map.
    let model = try XCTUnwrap(
      MemoryStrandModel(
        projection: projection, eventID: Lab.eventID(29), now: Self.model.lenses.now,
        calendar: F.calendar))
    XCTAssertFalse(model.hasMap)
    XCTAssertTrue(model.strands.isEmpty)
    XCTAssertEqual(model.mainKnots.map(\.glyph), [.planned])
    XCTAssertGreaterThan(model.mainItemCount, 0)
    let image = try render(
      MemoryNavigation(path: [.event(Lab.eventID(29))], eventLens: .strands), state: screen())
    XCTAssertEqual(image.width, 1280)
  }

  // MARK: - Decisions

  func testRelationDecisionsLeaveThroughTheActions() {
    var sent: [MemoryRelationDecision] = []
    var maps: [String] = []
    let actions = MemoryActions(
      relation: { sent.append($0) }, requestMap: { maps.append($0) })
    actions.relation(.confirmRope(Lab.ropeID(1)))
    actions.relation(.moveToRope(eventID: Lab.eventID(5), ropeID: nil))
    actions.relation(.hideCrossing(a: Lab.eventID(0), b: Lab.eventID(1)))
    actions.requestMap(Lab.eventID(40))
    XCTAssertEqual(sent.count, 3)
    XCTAssertEqual(maps, [Lab.eventID(40)])
    // As stored and sent.
    let wire = sent.map(MemoryDecisions.relation)
    XCTAssertEqual(wire.map(\.kind), ["confirm_rope", "move_to_rope", "hide_crossing"])
    XCTAssertTrue(wire.allSatisfy(\.isWellFormed))
    XCTAssertEqual(wire[0].ropeID, Lab.ropeID(1))
    XCTAssertNil(wire[1].ropeID)
    XCTAssertEqual(wire[2].a, Lab.eventID(0))
  }

  // MARK: - Performance

  /// Home and the 214-item matter, every lens, drawn off screen at 1×: the
  /// time each takes (median of three), and Home without the v7 data for
  /// comparison. Budgets are loose (debug build, shared machine); the
  /// numbers are printed for the record.
  func testLensesStayFastOnTheLabFixture() throws {
    func median(_ body: () throws -> Void) rethrows -> Double {
      var times: [Double] = []
      for _ in 0..<3 {
        let start = Date()
        try body()
        times.append(Date().timeIntervalSince(start) * 1_000)
      }
      return times.sorted()[1]
    }
    let derive = median { _ = MemoryReadModel(Lab.projection, calendar: F.calendar) }
    let deriveOld = median { _ = MemoryReadModel(Lab.projectionWithoutV7, calendar: F.calendar) }
    let state = screen()
    let old = screen(MemoryReadModel(Lab.projectionWithoutV7, calendar: F.calendar))
    var numbers: [String: Double] = ["derive_ms": derive, "derive_without_v7_ms": deriveOld]
    numbers["home_time_without_v7_ms"] = try median {
      _ = try render(MemoryNavigation(), state: old)
    }
    for lens in MemoryHomeLens.allCases {
      numbers["home_\(lens.rawValue)_ms"] = try median {
        _ = try render(MemoryNavigation(homeLens: lens), state: state)
      }
    }
    for lens in MemoryEventLens.allCases {
      numbers["matter_\(lens.rawValue)_ms"] = try median {
        _ = try render(
          MemoryNavigation(path: [.event(Lab.eventID(0))], eventLens: lens), state: state,
          height: 1_100)
      }
    }
    numbers["strand_model_and_layout_ms"] = median {
      let model = MemoryStrandModel(
        projection: state.projection!, eventID: Lab.eventID(0), now: state.libraryNow,
        calendar: F.calendar)!
      _ = MemoryStrandLayout(model: model, width: 760, calendar: F.calendar)
    }
    let line = numbers.sorted { $0.key < $1.key }
      .map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " ")
    print("bestASR v7 lens timings: \(line)")
    XCTAssertLessThan(derive, 3_000)
    XCTAssertLessThan(numbers["strand_model_and_layout_ms"]!, 150)
    for (key, value) in numbers where key.hasPrefix("home_") || key.hasPrefix("matter_") {
      XCTAssertLessThan(value, 4_000, key)
    }
    // Home as it was does not get slower by more than the new lens data.
    XCTAssertLessThan(numbers["home_time_ms"]!, numbers["home_time_without_v7_ms"]! * 2 + 300)
  }

  // MARK: - Snapshots

  func testRenderLensSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["BESTASR_UI_SNAPSHOT_DIR"],
      !directory.isEmpty
    else {
      throw XCTSkip("Set BESTASR_UI_SNAPSHOT_DIR to render the lens snapshots.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let state = screen()
    var scenes: [(String, MemoryNavigation, CGFloat)] = MemoryHomeLens.allCases.map {
      ("lab-home-\($0.rawValue)", MemoryNavigation(homeLens: $0), 1_000)
    }
    for lens in MemoryEventLens.allCases {
      scenes.append(
        (
          "lab-twin-\(lens.rawValue)",
          MemoryNavigation(path: [.event(Lab.eventID(0))], eventLens: lens), 1_100
        ))
    }
    scenes.append(
      (
        "lab-twin-strands-knot",
        MemoryNavigation(path: [.event(Lab.eventID(0))], eventLens: .strands, focusedKnot: "k4"),
        1_100
      ))
    scenes.append(
      (
        "lab-nomap-strands",
        MemoryNavigation(path: [.event(Lab.eventID(29))], eventLens: .strands), 900
      ))
    for (name, navigation, height) in scenes {
      for dark in [false, true] {
        let image = try render(navigation, state: state, dark: dark, height: height)
        let png = try XCTUnwrap(
          NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(
          to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"),
          options: .atomic)
      }
    }
  }
}
