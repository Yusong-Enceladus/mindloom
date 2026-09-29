import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// Who the Home row, the loom lanes and the event chips draw. Synthetic
/// names only.
final class MemoryShownPeopleTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_790_470_800)

  private func id(_ n: Int) -> SessionID {
    SessionID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
  }

  private func person(_ n: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!)
  }

  private func key(_ n: Int) -> String { person(n).rawValue.uuidString }

  /// A pasted text whose "名：" lines became speakers on this Mac.
  private func pasted(_ n: Int, speakers: [(Int, String)], at offset: TimeInterval)
    -> MemoryItemRecord
  {
    MemoryItemRecord(
      sessionID: id(n), inputMode: .userItem, itemKind: .text, title: "粘贴",
      startedAt: base.addingTimeInterval(offset), updatedAt: base.addingTimeInterval(offset),
      sourceBundleID: nil, sourceDisplayName: "微信", sourceIdentifier: nil, text: "……",
      segments: speakers.map {
        .init(startMilliseconds: 0, endMilliseconds: 0, personID: person($0.0),
          personName: $0.1, text: "……")
      },
      people: speakers.map { .init(id: person($0.0), name: $0.1) })
  }

  private func recording(_ n: Int, speaker: (Int, String), at offset: TimeInterval)
    -> MemoryItemRecord
  {
    MemoryItemRecord(
      sessionID: id(n), inputMode: .roomMicrophone, itemKind: nil, title: "录音",
      startedAt: base.addingTimeInterval(offset), updatedAt: base.addingTimeInterval(offset),
      sourceBundleID: nil, sourceDisplayName: "内建麦克风", sourceIdentifier: nil, text: "好。",
      segments: [
        .init(startMilliseconds: 0, endMilliseconds: 500, personID: person(speaker.0),
          personName: speaker.1, text: "好。")
      ],
      people: [.init(id: person(speaker.0), name: speaker.1)], playbackAvailable: true)
  }

  private func event(_ name: String, _ items: [Int], people: [Int] = []) -> MemoryEventSource {
    MemoryEventSource(
      eventID: name, origin: .spark, title: name, statusLine: "", pinned: false,
      updatedAt: nil, itemIDs: items.map { id($0).rawValue.uuidString },
      personIDs: people.map(key))
  }

  private func projection() -> MemoryProjection {
    let persons = try! JSONDecoder().decode(
      [RemoteOrganizerPerson].self,
      from: Data(
        """
        [{"person_id":"\(key(20))","display_name":"Mobile","aliases":[],"origin":"chat"},
         {"person_id":"\(key(21))","display_name":"虚构丁","aliases":[],"origin":"chat"}]
        """.utf8))
    return MemoryProjection(
      events: [
        event("A", [1, 2], people: [20, 21]),
        event("B", [3, 4], people: [20]),
        event("C", [5, 6], people: [21]),
      ],
      records: [
        // 虚构甲 speaks in three matters, 虚构乙 in two; 全文 and a phrase
        // come from one pasted text; Archive and 先确认一下 turn up twice.
        pasted(1, speakers: [(1, "虚构甲"), (2, "虚构乙"), (3, "全文"), (4, "Archive")], at: 0),
        pasted(2, speakers: [(5, "先确认一下"), (6, "GaoYuan-虚构组")], at: 60),
        pasted(3, speakers: [(1, "虚构甲"), (2, "虚构乙"), (4, "Archive"), (5, "先确认一下")],
          at: 120),
        pasted(4, speakers: [(6, "GaoYuan-虚构组"), (7, "Ann Gu")], at: 180),
        pasted(5, speakers: [(1, "虚构甲"), (7, "Ann Gu")], at: 240),
        // Heard once, in a recording: shown although in one matter only.
        recording(6, speaker: (8, "虚构丙"), at: 300),
      ],
      persons: persons, now: base.addingTimeInterval(3_600))
  }

  func testHomeRowRanksPeopleByTheMattersTheyAreIn() {
    let row = projection().featuredPeople()
    XCTAssertEqual(row.map(\.name), ["虚构甲", "虚构丁", "Ann Gu", "虚构乙", "虚构丙"])
    XCTAssertEqual(row.map(\.events.count), [3, 2, 2, 2, 1])
  }

  func testLabelsAndOneOffSpeakersStayOffTheAvatarsButKeepTheirPages() throws {
    let projection = projection()
    let hidden = ["全文", "Archive", "先确认一下", "GaoYuan-虚构组", "Mobile"]
    let everyone = projection.people().map(\.name)
    for name in hidden { XCTAssertTrue(everyone.contains(name), name) }
    let home = projection.home()
    for entry in home {
      XCTAssertTrue(Set(entry.shownPeople.map(\.name)).isDisjoint(with: hidden), entry.title)
    }
    let a = try XCTUnwrap(home.first { $0.eventID == "A" })
    XCTAssertTrue(a.people.map(\.name).contains("全文"))
    XCTAssertEqual(a.shownPeople.map(\.name), ["虚构丁", "虚构甲", "虚构乙"])
    let detail = try XCTUnwrap(projection.event(id: "A"))
    XCTAssertEqual(detail.shownPeople.map(\.name), a.shownPeople.map(\.name))
    XCTAssertTrue(detail.people.map(\.name).contains("Archive"))
    // Copy as text names the same people.
    XCTAssertTrue(
      EventPlainTextFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!).format(detail)
        .contains("人物：虚构丁、虚构甲、虚构乙\n"))
    // The loom lane draws the same people.
    let loom = MemoryLoom(
      projection: projection, home: home, span: .twoWeeks,
      calendar: Calendar(identifier: .gregorian))
    for lane in loom.lanes {
      XCTAssertTrue(Set(lane.people.map(\.name)).isDisjoint(with: hidden), lane.title)
    }
  }

  func testWhatReadsAsAPersonsName() {
    for name in ["虚构甲", "林哥", "欧阳某某", "温治疗师", "Ann Gu", "Mary Ann Lee"] {
      XCTAssertTrue(MemoryProjection.looksLikePersonName(name), name)
    }
    for name in [
      "全文某某", "先确认一下", "关于签字流程", "另", "Archive", "Mobile", "Files in zip", "TES",
      "GaoYuan-虚构组", "雨桐 (Tina)", "Tel", "2026", "",
    ] {
      XCTAssertFalse(MemoryProjection.looksLikePersonName(name), name)
    }
  }
}
