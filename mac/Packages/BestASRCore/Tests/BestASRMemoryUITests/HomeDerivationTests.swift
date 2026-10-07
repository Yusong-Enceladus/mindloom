import BestASRDomain
import BestASRMemory
import XCTest

@testable import BestASRMemoryUI

/// Home's derivations (MAC-SPEC §4.1–§4.5, §4.11) against the prototype's own
/// data (v10 fixture, "now" = 2026-09-20 22:46 Asia/Shanghai, a Sunday).
@MainActor
final class HomeDerivationTests: XCTestCase {
  private func state() throws -> MemoryScreenState {
    guard V11Fixture.isAvailable else { throw XCTSkip("The v10 fixture files are not on this Mac.") }
    return V11Fixture.state(try V11Fixture.load())
  }

  private func title(_ m: MatterDigest) -> String { MLAutospaceStrip.strip(m.title) }

  func testTrackWindowAndAxis() {
    XCTAssertEqual(HomeTrackWindow.x(0), 202.14, accuracy: 0.01)
    XCTAssertEqual(HomeTrackWindow.x(-19), 4)
    XCTAssertEqual(HomeTrackWindow.x(9), 296)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let days = HomeDays(today: V11Fixture.now, calendar: calendar)
    XCTAssertEqual(days.monday, -6)
    XCTAssertEqual(HomeTrackWindow.axis(days).map(\.text), ["9月7日", "9月14日", "9月28日", "今天"])
  }

  func testTimeGroupsFollowThePrototype() throws {
    let state = try state()
    let days = HomeDays(state)
    let groups = HomeDerivation.timeGroups(state.digest!.matters, days: days)
    XCTAssertEqual(groups.map(\.kind), [.overdue, .due, .thisWeek, .lastWeek, .earlier])
    // The prototype has the two NeurCon rows; the native digest also flags
    // 「9月16日组会进度同步」 (its status line 「9月15日交报告」 passed; see
    // notes/mac-home.md), so check order and membership, not the count.
    let overdue = groups[0].matters.map(title)
    XCTAssertEqual(overdue.first, "NeurCon论文返修")
    XCTAssertTrue(overdue.contains("NeurCon论文补实验"))
    XCTAssertEqual(groups[1].matters.first.map(title), "Workshop Short Paper")
    let tes = try XCTUnwrap(groups[1].matters.first { title($0).hasPrefix("TES论文RoboPrior") })
    let line = HomeDerivation.secondLine(tes, days: days, withRisk: true)
    XCTAssertEqual(line.alertWord, "明天")
    XCTAssertEqual(line.words, "交回复信")
    XCTAssertEqual(line.risk, "目前仅完成四成，表2数据待核对")
    // No risk outside 已过期 / 快到期.
    XCTAssertNil(HomeDerivation.secondLine(tes, days: days, withRisk: false).risk)
    let over = HomeDerivation.secondLine(groups[0].matters[0], days: days)
    XCTAssertEqual(over.alertWord, "已过期")
    XCTAssertEqual(over.words, "9月15日投稿")
  }

  func testTrackMarks() throws {
    let state = try state()
    let days = HomeDays(state)
    for matter in state.digest!.matters {
      let track = HomeDerivation.track(matter, days: days)
      if track.isDrawn {
        XCTAssertLessThanOrEqual(track.dots.filter { $0.style == .done }.count, 1)
        let future = track.dots.filter { $0.style == .next }
        XCTAssertLessThanOrEqual(future.count, 2)
        if future.count == 2 { XCTAssertGreaterThanOrEqual(abs(future[0].x - future[1].x), 15) }
        for dot in track.dots {
          XCTAssertGreaterThanOrEqual(dot.x, 0)
          XCTAssertLessThanOrEqual(dot.x, HomeTrackWindow.width)
        }
      } else {
        XCTAssertNotNil(track.oldLabel)
        XCTAssertTrue(track.dots.isEmpty)
      }
    }
    // The overdue NeurCon row: a vermilion ○ with 「… · 已过期」.
    let neur = try XCTUnwrap(state.digest!.matters.first { title($0) == "NeurCon论文返修" })
    let track = HomeDerivation.track(neur, days: days)
    let due = try XCTUnwrap(track.dots.first { $0.style == .due })
    XCTAssertEqual(due.n, -5)
    XCTAssertTrue(due.tip.hasPrefix("9月15日 · "))
    XCTAssertTrue(due.tip.hasSuffix(" · 已过期"))
  }

  func testDeadlineGroups() throws {
    let state = try state()
    let groups = HomeDerivation.deadlineGroups(state.digest, eventIDs: nil, days: HomeDays(state))
    XCTAssertEqual(groups.first?.title, "已过期")
    XCTAssertGreaterThanOrEqual(groups.first?.entries.count ?? 0, 2)
    XCTAssertEqual(groups.dropFirst().first?.title, "即将到期")
    let next = try XCTUnwrap(groups.first { $0.title == "下周" })
    XCTAssertEqual(next.range, "9月21日–27日")
    XCTAssertEqual(groups.first { $0.title == "下下周" }?.range, "9月28日–10月4日")
    // Sorted by date, nothing done.
    let all = groups.flatMap(\.entries)
    XCTAssertEqual(all.map(\.n), all.map(\.n).sorted())
  }

  /// v12 (B7 U13): 按人 lists people, each once, not one matter per person;
  /// labels read as speakers stay out.
  func testPeopleRowsShowEachPersonOnce() throws {
    let state = try state()
    let rows = HomeDerivation.peopleGroups(state).flatMap(\.rows)
    XCTAssertFalse(rows.isEmpty)
    XCTAssertEqual(Set(rows.map(\.person.personID)).count, rows.count)
    XCTAssertTrue(rows.allSatisfy { $0.matterCount > 0 || $0.person.hasVoice })
    XCTAssertTrue(
      rows.filter(\.person.isNamed).allSatisfy {
        MemoryProjection.looksLikePersonName($0.person.name) || $0.person.hasVoice
      })
  }

  func testSearch() throws {
    let state = try state()
    let person = HomeSearch.results("雨桐", state: state)
    XCTAssertEqual(person.people.first?.person.name, "宋雨桐")
    XCTAssertFalse(person.matters.isEmpty)
    XCTAssertLessThanOrEqual(person.matters.count, 8)
    XCTAssertLessThanOrEqual(person.texts.count, 10)
    let reply = HomeSearch.results("回 复 信", state: state)
    XCTAssertFalse(reply.matters.isEmpty, "whitespace is ignored")
    XCTAssertTrue(HomeSearch.results("火星基地", state: state).isEmpty)
  }

  func testHitAndCut() {
    let text = "TES 论文 RoboPrior"
    let range = HomeSearch.hit("论文robo", in: text)
    XCTAssertEqual(range.map { String(text[$0]) }, "论文 Robo")
    let long = String(repeating: "甲", count: 80) + "火星" + String(repeating: "乙", count: 40)
    let cut = HomeSearch.cut(long, "火星")
    XCTAssertTrue(cut.hasPrefix(String(repeating: "甲", count: 20) + "火星") || cut.count <= 90 + 20)
    XCTAssertTrue(cut.contains("火星"))
    XCTAssertLessThan(cut.count, long.count)
  }

  func testGroupNameClean() {
    XCTAssertEqual(GroupName.clean("  TG-2 夹爪  "), "TG-2夹爪")
    XCTAssertEqual(GroupName.clean("找  工作"), "找 工作")
    XCTAssertEqual(GroupName.clean("论文"), "论文")
  }

  func testMatterMenuModel() throws {
    let loaded = try { () throws -> V11Fixture.Loaded in
      guard V11Fixture.isAvailable else { throw XCTSkip("fixture") }
      return try V11Fixture.load()
    }()
    let state = V11Fixture.state(loaded)
    let e6 = try XCTUnwrap(loaded.handles["E6"])
    let model = MatterMenuModel(state: state, input: MatterMenuInput(eventID: e6, memberView: false))
    XCTAssertTrue(model.pinned)
    XCTAssertTrue(model.inGroup)
    XCTAssertTrue(model.sharedByYou)
    XCTAssertEqual(model.groups.filter(\.current).map(\.name), ["论文"])
  }
}

/// Organizer titles in the digest are not autospaced; this undoes the
/// quarter-em in case a fixture already had it.
enum MLAutospaceStrip {
  static func strip(_ s: String) -> String { s.replacingOccurrences(of: "\u{2005}", with: "") }
}
