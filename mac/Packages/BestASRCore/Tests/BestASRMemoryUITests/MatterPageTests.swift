import BestASRDomain
import Foundation
import SwiftUI
import XCTest

@testable import BestASRMemory
@testable import BestASRMemoryUI

/// The matter page's logic (MAC-SPEC §4.6–§4.9, §7.1–§7.4): the time view's
/// layout (true days, one ● per lane, a ● gives way to a coming mark, far
/// marks, labels never overlap), popover placement, rename clean-up, the
/// move picker, the small page's rows. Synthetic data, plus the v10 fixture
/// when it is on this Mac.
@MainActor
final class MatterPageTests: XCTestCase {
  private var calendar: Calendar { V11Fixture.calendar }
  private var today: Date { calendar.startOfDay(for: V11Fixture.now) }

  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: today)!
  }

  private func step(
    _ id: String, part: String?, _ offset: Int, kind: String = "progress", state: String = "done",
    glyph: MatterStepGlyph = .done, text: String? = nil, due: Bool = false, over: Bool = false
  ) -> MatterStep {
    MatterStep(
      id: id, partID: part, kind: kind, state: state, glyph: glyph, date: day(offset),
      inferred: false, text: text ?? "步骤\(id)", who: [], due: due, over: over, fromStatus: false,
      evidence: nil, override: nil)
  }

  private func matter(parts: [MatterPart], steps: [MatterStep], facts: [MatterFact] = [])
    -> MatterDigest
  {
    MatterDigest(
      eventID: "M1", handle: nil, origin: .spark, rank: 0, title: "测试的事", status: "", risk: nil,
      firstDay: day(-30), lastDay: day(0), days: [day(-30), day(0)], itemIDs: [], people: [],
      parts: parts, steps: steps, facts: facts)
  }

  private func part(_ id: String, _ name: String, from: Int = -30, closed: Bool = false) -> MatterPart {
    MatterPart(
      id: id, name: name, summary: "", closed: closed, days: [day(from), day(-1)], itemIDs: [])
  }

  private func layout(_ matter: MatterDigest, width: CGFloat = 884) -> MatterTimeLayout {
    MatterTimeLayout(matter: matter, width: width, today: today, calendar: calendar)
  }

  // MARK: - Time view

  func testOneFinishedMarkPerLaneAndTheRestFolds() {
    var steps: [MatterStep] = []
    for n in 0..<46 { steps.append(step("x\(n)", part: n % 2 == 0 ? "s1" : "s2", -(n % 20) - 1)) }
    let m = matter(parts: [part("s1", "写作"), part("s2", "实验")], steps: steps)
    let l = layout(m)
    for lane in l.lanes {
      XCTAssertEqual(l.marks.filter { $0.laneID == lane.id && $0.kind == .done }.count, 1, lane.name)
    }
    XCTAssertEqual(
      l.marks.flatMap(\.steps).count + l.folded.values.map(\.count).reduce(0, +), 46,
      "every step is a mark or in 经过")
    assertLabelsDoNotOverlap(l)
  }

  func testAFinishedStepGivesWayToADueOneOnTheSameDay() throws {
    let m = matter(
      parts: [part("s1", "回复信")],
      steps: [
        step("a", part: "s1", 0, text: "拟好初稿"),
        step(
          "b", part: "s1", 1, kind: "deadline", state: "planned", glyph: .next, text: "交回复信",
          due: true),
      ])
    let l = layout(m)
    let done = try XCTUnwrap(l.marks.first { $0.kind == .done })
    let due = try XCTUnwrap(l.marks.first { $0.kind == .due })
    XCTAssertEqual(due.x, l.x(1), accuracy: 0.01, "a deadline never moves")
    XCTAssertLessThanOrEqual(done.x, due.x - 12 + 0.01)
    XCTAssertEqual(due.label?.when, "明天")
    XCTAssertEqual(due.label?.whenAlert, true)
  }

  func testFarStepsSitAtTheRowEndWithTheirDate() throws {
    let m = matter(
      parts: [part("s1", "整体进度")],
      steps: [
        step(
          "f", part: "s1", 26, kind: "deadline", state: "planned", glyph: .next, text: "期刊正式截止")
      ])
    let l = layout(m)
    let far = try XCTUnwrap(l.marks.first { $0.far })
    XCTAssertEqual(far.x, 884 - 8)
    XCTAssertEqual(far.label?.when, "10月16日")
    XCTAssertEqual(l.l1, 884 - 56)
    XCTAssertEqual(l.dashes.last?.x1, l.l1, "the dash stops before the far mark (a gap, no 「//」)")
  }

  func testStepsWithoutAPartGoToOtherWhenThereAreSeveralLanes() {
    let m = matter(
      parts: [part("s1", "甲"), part("s2", "乙")],
      steps: [step("o", part: nil, -2), step("q", part: "s1", -3, kind: "question", state: "open", glyph: .open)])
    let l = layout(m)
    XCTAssertEqual(l.lanes.map(\.name), ["甲", "乙", "其他"])
    XCTAssertEqual(l.laneOf["o"], "_m")
    XCTAssertEqual(l.open.map(\.id), ["q"], "an open question is never on the axis")
    XCTAssertNil(l.mark(holding: "q"))
  }

  func testSameDayStepsShareOneMark() throws {
    let m = matter(
      parts: [part("s1", "理论")],
      steps: [step("k6", part: "s1", -2), step("k7", part: "s1", -2, kind: "decision")])
    let mark = try XCTUnwrap(layout(m).marks.first)
    XCTAssertEqual(mark.steps.map(\.id), ["k7", "k6"], "decisions first on a tie")
    XCTAssertEqual(mark.label?.more, 1)
  }

  func testTheFixtureMattersLayOutWithoutOverlaps() throws {
    guard V11Fixture.isAvailable else { throw XCTSkip("The v10 fixture files are not on this Mac.") }
    let state = V11Fixture.state(try V11Fixture.load())
    let digest = try XCTUnwrap(state.digest)
    var checked = 0
    for matter in digest.matters where !matter.parts.isEmpty {
      for width in [884, 640] as [CGFloat] {
        assertLabelsDoNotOverlap(layout(matter, width: width), matter.title)
      }
      checked += 1
    }
    XCTAssertGreaterThan(checked, 10)
    // E6 as the prototype draws it.
    let loaded = try V11Fixture.load()
    let e6 = try XCTUnwrap(digest.matter(loaded.handles["E6"] ?? ""))
    let l = layout(e6)
    XCTAssertEqual(l.lanes.map(\.name), ["R1 补实验与仿真", "整体进度与协调", "R3 写作与回复信", "R2 理论推导"])
    XCTAssertEqual(l.mark(holding: "st1")?.kind, .due)
    XCTAssertEqual(l.mark(holding: "k6")?.label?.more, 1)
    XCTAssertTrue(l.mark(holding: "k1")?.far ?? false)
    XCTAssertNil(l.mark(holding: "k8"), "雨桐完成 R3 写作修改 folds into 经过")
    XCTAssertEqual(l.foldedSteps("s3").map(\.id), ["k8"])
    XCTAssertEqual(l.open.map(\.id), ["k5"])
  }

  private func assertLabelsDoNotOverlap(
    _ l: MatterTimeLayout, _ name: String = "", file: StaticString = #filePath, line: UInt = #line
  ) {
    for lane in l.lanes {
      let marks = l.marks.filter { $0.laneID == lane.id }.sorted { $0.x < $1.x }
      for (a, b) in zip(marks, marks.dropFirst()) {
        XCTAssertGreaterThanOrEqual(b.x - a.x, 10, "\(name): marks too close", file: file, line: line)
      }
      let labels = marks.compactMap(\.label).filter { !$0.squeezed }
      for (i, a) in labels.enumerated() {
        for b in labels.dropFirst(i + 1) where a.row == b.row {
          XCTAssertFalse(
            a.x0 < b.x0 + b.width && a.x0 + a.width > b.x0,
            "\(name): \(a.text) overlaps \(b.text)", file: file, line: line)
        }
      }
    }
  }

  // MARK: - Popover placement

  func testThePopoverGoesBelowUnlessAboveCoversLess() {
    let size = CGSize(width: 352, height: 200)
    let bounds = CGSize(width: 948, height: 848)
    let below = MatterPopoverLayout.place(
      size: size, anchor: CGRect(x: 500, y: 300, width: 21, height: 21), ownLabel: nil, labels: [],
      in: bounds)
    XCTAssertFalse(below.up)
    XCTAssertEqual(below.frame.minY, 333)
    // Near the bottom of the window it goes above.
    let above = MatterPopoverLayout.place(
      size: size, anchor: CGRect(x: 500, y: 700, width: 21, height: 21), ownLabel: nil, labels: [],
      in: bounds)
    XCTAssertTrue(above.up)
    XCTAssertEqual(above.frame.maxY, 688)
    // Never over the label of what it opens.
    let own = CGRect(x: 420, y: 330, width: 200, height: 18)
    let avoid = MatterPopoverLayout.place(
      size: size, anchor: CGRect(x: 500, y: 350, width: 21, height: 21), ownLabel: own, labels: [],
      in: bounds)
    XCTAssertTrue(own.intersection(avoid.frame).isNull)
    // Kept off the sidebar and inside the window; the arrow points at the anchor.
    let left = MatterPopoverLayout.place(
      size: size, anchor: CGRect(x: 0, y: 300, width: 10, height: 10), ownLabel: nil, labels: [],
      in: bounds)
    XCTAssertEqual(left.frame.minX, 10)
    XCTAssertEqual(left.arrowX, 18)
  }

  // MARK: - Rename, move, small page

  func testRenameCleansSpacing() {
    XCTAssertEqual(MatterHeader.cleanName("  TES 论文\u{2005}RoboPrior   大修 返修 "), "TES论文RoboPrior大修 返修")
    XCTAssertEqual(MatterHeader.cleanName("CoRA 2026 新加坡"), "CoRA 2026新加坡")
  }

  func testTheMovePicker() {
    XCTAssertEqual(MoveThing.firstClause("表2重跑完了，结果稳定"), "表2重跑完了")
    XCTAssertEqual(MoveThing.firstClause("一二三四五六七八九十一二三四五六七八九十"), "一二三四五六七八九十一二三四五六七八")
    XCTAssertEqual(MoveThing.firstClause("  "), "新的事")
    XCTAssertTrue(MovePicker.matches("Skill\u{2005}Knit 论文投稿", "skillknit"))
    XCTAssertFalse(MovePicker.matches("TES 论文", "Skill"))
    let a = MatterDigest(
      eventID: "A", handle: nil, origin: .spark, rank: 1, title: "SkillKnit论文投稿", status: "", risk: nil,
      firstDay: nil, lastDay: nil, days: [], itemIDs: [], people: [], parts: [], steps: [], facts: [])
    let b = MatterDigest(
      eventID: "B", handle: nil, origin: .spark, rank: 0, title: "租房续约", status: "", risk: nil,
      firstDay: nil, lastDay: nil, days: [], itemIDs: [], people: [], parts: [], steps: [], facts: [])
    XCTAssertEqual(MovePicker.likely("SkillKnit 的论文投稿材料", among: [a, b]).map(\.eventID), ["A"])
    XCTAssertEqual(MovePicker.byUrgency([a, b], today: today, calendar: calendar).map(\.eventID), ["B", "A"])
  }

  func testTheSmallPageRows() {
    let m = matter(
      parts: [],
      steps: [
        step("past", part: nil, -5, text: "拟录取"),
        step(
          "over", part: nil, -1, kind: "step", state: "planned", glyph: .next, text: "截稿", over: true),
        step("next", part: nil, 5, state: "planned", glyph: .next, text: "提交推荐信"),
      ],
      facts: [
        MatterFact(text: "领取门禁卡", state: .done, date: day(-5)),
        MatterFact(text: "确认导师", state: .planned, date: nil),
      ])
    let rows = SmallPageRow.rows(m, today: today, calendar: calendar)
    XCTAssertEqual(rows.next.map(\.text), ["截稿", "提交推荐信", "确认导师"], "soonest first, undated last")
    XCTAssertEqual(rows.next.first?.glyph, .over)
    XCTAssertNil(rows.next.last?.day, "「待定」")
    XCTAssertEqual(rows.past.map(\.text).sorted(), ["拟录取", "领取门禁卡"])
  }
}
