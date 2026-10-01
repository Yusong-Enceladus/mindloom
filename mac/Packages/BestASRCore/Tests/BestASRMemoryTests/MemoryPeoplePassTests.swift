import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// The organizer's people pass (v6 quality): people linked because a text
/// names them (`mention`) show as people but never relate two matters;
/// labels it found are not people (`not_person`) are never shown; an event's
/// people come most involved first. Synthetic names only.
final class MemoryPeoplePassTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_790_470_800)

  private func id(_ n: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012d", n)
  }

  private func person(_ n: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", n))!)
  }

  private func key(_ n: Int) -> String { person(n).rawValue.uuidString }

  private func text(_ n: Int, _ body: String, at offset: TimeInterval = 0) -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: .userItem, itemKind: .text,
      title: "粘贴", startedAt: base.addingTimeInterval(offset),
      updatedAt: base.addingTimeInterval(offset), sourceBundleID: nil,
      sourceDisplayName: "微信", sourceIdentifier: nil, text: body, segments: [], people: [])
  }

  private func recording(_ n: Int, speakers: [Int], at offset: TimeInterval = 0)
    -> MemoryItemRecord
  {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: .roomMicrophone, itemKind: nil,
      title: "录音", startedAt: base.addingTimeInterval(offset),
      updatedAt: base.addingTimeInterval(offset), sourceBundleID: nil,
      sourceDisplayName: "内建麦克风", sourceIdentifier: nil, text: "好。",
      segments: speakers.map {
        .init(
          startMilliseconds: 0, endMilliseconds: 500, personID: person($0), personName: nil,
          text: "好。")
      },
      people: speakers.map { .init(id: person($0), name: "虚构\($0)") }, playbackAvailable: true)
  }

  private func event(
    _ name: String, _ items: [Int], people: [Int], origin: MemoryEventSource.Origin = .spark
  ) -> MemoryEventSource {
    MemoryEventSource(
      eventID: name, origin: origin, title: name, statusLine: "", pinned: false,
      updatedAt: base, itemIDs: items.map(id), personIDs: people.map(key))
  }

  private func persons(_ json: String) -> [RemoteOrganizerPerson] {
    try! JSONDecoder().decode([RemoteOrganizerPerson].self, from: Data(json.utf8))
  }

  /// 虚构甲 writes in 装修 and in 报销; 虚构乙 is only named in 报销 (the
  /// organizer's mention); 全文 is a label the people pass marked.
  private func projection() -> MemoryProjection {
    MemoryProjection(
      events: [
        event("装修", [1], people: [1, 3]),
        event("报销", [2, 3], people: [2, 1, 3]),
        event("旅行", [4], people: [2]),
      ],
      records: [
        text(1, "[08-17 12:29] 虚构甲：瓷砖周五到\n全文：见附件", at: 0),
        text(2, "虚构甲-财务 10:05\n发票记得贴好", at: 60),
        text(3, "我：虚构乙说周四前交齐", at: 120),
        text(4, "我：虚构乙订了票", at: 180),
      ],
      persons: persons(
        """
        [{"person_id":"\(key(1))","display_name":"虚构甲","aliases":["Jia Xugou"],"origin":"chat","status":null},
         {"person_id":"\(key(2))","display_name":"虚构乙","aliases":[],"origin":"chat"},
         {"person_id":"\(key(3))","display_name":"全文","aliases":[],"origin":"chat","status":"not_person"}]
        """),
      now: base)
  }

  func testStatusIsDecodedAndOptional() {
    let decoded = persons(
      """
      [{"person_id":"a","display_name":"甲","aliases":[],"origin":"chat","status":"not_person"},
       {"person_id":"b","display_name":"乙","aliases":[],"origin":"chat","status":"role"},
       {"person_id":"c","display_name":"丙","aliases":[],"origin":"chat"}]
      """)
    XCTAssertEqual(decoded.map(\.status), ["not_person", "role", nil])
    XCTAssertEqual(decoded.map(\.isNotPerson), [true, false, false])
    // Kept through unmasking and a JSON round trip (the Mac stores persons as JSON).
    XCTAssertEqual(decoded[0].unmasked { $0 }.status, "not_person")
    let again = try! JSONDecoder().decode(
      [RemoteOrganizerPerson].self, from: try! JSONEncoder().encode(decoded))
    XCTAssertEqual(again, decoded)
  }

  func testANotPersonIsNeverShown() throws {
    let projection = projection()
    let notPerson = key(3)
    XCTAssertFalse(projection.home().contains { $0.people.contains { $0.personID == notPerson } })
    let detail = try XCTUnwrap(projection.event(id: "报销"))
    XCTAssertEqual(detail.shownPeople.map(\.name), ["虚构乙", "虚构甲"])
    XCTAssertFalse(detail.people.contains { $0.personID == notPerson })
    XCTAssertFalse(projection.people().contains { $0.personID == notPerson })
    XCTAssertFalse(projection.featuredPeople().contains { $0.personID == notPerson })
    XCTAssertFalse(projection.recentPeople().contains { $0.personID == notPerson })
  }

  /// The organizer lists 报销's people most involved first; the page keeps
  /// that order (a mention is still a person on the page).
  func testSparkEventPeopleKeepTheOrganizersOrder() throws {
    let detail = try XCTUnwrap(projection().event(id: "报销"))
    XCTAssertEqual(detail.people.map(\.name), ["虚构乙", "虚构甲"])
  }

  func testOnlyPeopleWhoTakePartRelateMatters() throws {
    let projection = projection()
    let home = projection.home()
    let byID = Dictionary(uniqueKeysWithValues: home.map { ($0.eventID, $0) })
    // 虚构甲 writes in both (a stamped speaker line; a byline with a remark).
    XCTAssertEqual(byID["装修"]?.participantIDs, [key(1)])
    XCTAssertEqual(byID["报销"]?.participantIDs, [key(1)])
    // 虚构乙 is only named ("虚构乙说…", "虚构乙订了票").
    XCTAssertEqual(byID["旅行"]?.participantIDs, [])
    XCTAssertEqual(projection.related(to: "装修").map(\.eventID), ["报销"])
    XCTAssertEqual(projection.related(to: "报销").map(\.eventID), ["装修"])
    // 报销 and 旅行 share 虚构乙, who is only named in both: not related.
    XCTAssertEqual(projection.related(to: "旅行"), [])
    // Still a person on both pages and in 虚构乙's matters.
    let yi = try XCTUnwrap(projection.people().first { $0.personID == key(2) })
    XCTAssertEqual(Set(yi.events.map(\.eventID)), ["报销", "旅行"])
  }

  func testAVoiceHeardOnThisMacTakesPart() {
    let projection = MemoryProjection(
      events: [
        event("会议甲", [1], people: [5]),
        event("会议乙", [2], people: [5]),
      ],
      records: [recording(1, speakers: [5]), recording(2, speakers: [5], at: 60)],
      now: base)
    XCTAssertEqual(projection.related(to: "会议甲").map(\.eventID), ["会议乙"])
  }

  /// A local event's people: most recordings spoken in first.
  func testLocalEventPeopleComeMostInvolvedFirst() throws {
    let projection = MemoryProjection(
      events: [event("本地", [1, 2, 3], people: [], origin: .local)],
      records: [
        recording(1, speakers: [7], at: 0),
        recording(2, speakers: [8, 7], at: 60),
        recording(3, speakers: [8], at: 120),
        recording(4, speakers: [9], at: 180),
      ],
      now: base)
    let detail = try XCTUnwrap(projection.event(id: "本地"))
    XCTAssertEqual(detail.people.map(\.personID), [key(7), key(8)])
    let busier = MemoryProjection(
      events: [event("本地", [1, 2, 3], people: [], origin: .local)],
      records: [
        recording(1, speakers: [7], at: 0),
        recording(2, speakers: [8], at: 60),
        recording(3, speakers: [8], at: 120),
      ],
      now: base)
    XCTAssertEqual(
      try XCTUnwrap(busier.event(id: "本地")).people.map(\.personID), [key(8), key(7)])
  }

  func testSpeakerLineShapes() {
    let labels = MemorySpeakerLines.labels(
      in: """
        虚构丙：好的
        [2026-08-17 12:29:05] 虚构丁: 收到
        【09:30】Ann Gu：on my way
        周建国-装修 2026/9/24 10:05
        周五来量尺寸
        会议纪要：
        虚构戊说：周五见
        时间 10:05
        """)
    XCTAssertTrue(labels.isSuperset(of: ["虚构丙", "虚构丁", "ann gu", "周建国-装修", "周建国"]))
    // A heading with nothing after it, and a byline with no message under it,
    // are not speaker lines.
    XCTAssertFalse(labels.contains("会议纪要"))
    XCTAssertFalse(labels.contains("时间"))
    // "虚构戊说" is a label but not the name 虚构戊.
    XCTAssertFalse(labels.contains("虚构戊"))
  }
}
