import BestASRDomain
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// v12 phase B task 2B (ALIGNMENT 理3-1, 理3-5, 理1-4, 理1-6): 按人 lists
/// everyone once with the unnamed voices last, person changes wait 8 s and
/// can be taken back, a page visit never organizes the library, and Home
/// says how many records wait while the DGX Spark is not organizing.
/// Synthetic data only.
@MainActor
final class PeopleAndHomeV12Tests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
  }()

  private let base = Date(timeIntervalSince1970: 1_790_470_800)

  private func item(_ n: Int) -> String {
    String(format: "C0000000-0000-4000-8000-%012d", n)
  }

  private func person(_ n: Int) -> String {
    String(format: "D0000000-0000-4000-8000-%012d", n)
  }

  private func recording(_ n: Int, hoursAgo: Double, speakers: [(Int, String?)])
    -> MemoryItemRecord
  {
    let at = base.addingTimeInterval(-hoursAgo * 3_600)
    return MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: item(n))!), inputMode: .roomMicrophone, itemKind: nil,
      title: "录音", startedAt: at, updatedAt: at, sourceBundleID: nil,
      sourceDisplayName: "内建麦克风", sourceIdentifier: nil,
      text: speakers.map { _ in "好的。" }.joined(separator: "\n"),
      segments: speakers.enumerated().map { index, speaker in
        let start = UInt64(index) * 2_000_000_000
        return .init(
          startMilliseconds: Int64(index) * 2_000, endMilliseconds: Int64(index + 1) * 2_000,
          personID: PersonID(UUID(uuidString: person(speaker.0))!), personName: speaker.1 ?? "",
          text: "好的。", monotonicStartNanoseconds: start,
          monotonicEndNanoseconds: start + 2_000_000_000)
      },
      people: speakers.map {
        .init(id: PersonID(UUID(uuidString: person($0.0))!), name: $0.1 ?? "")
      },
      playbackAvailable: true)
  }

  private func event(_ id: String, _ items: [Int]) -> MemoryEventSource {
    MemoryEventSource(
      eventID: id, origin: .local, title: "事情" + id, statusLine: "", pinned: false,
      updatedAt: base, itemIDs: items.map(item), personIDs: [])
  }

  private func state() -> MemoryScreenState {
    let projection = MemoryProjection(
      events: [event("A", [1, 2]), event("B", [3]), event("C", [4])],
      records: [
        recording(1, hoursAgo: 2, speakers: [(1, "虚构甲"), (2, nil)]),
        recording(2, hoursAgo: 30, speakers: [(1, "虚构甲")]),
        recording(3, hoursAgo: 5, speakers: [(1, "虚构甲"), (5, "虚构丁")]),
        recording(4, hoursAgo: 50, speakers: [(6, "虚构戊")]),
      ],
      now: base,
      localPeople: [
        MemoryLocalPerson(
          personID: person(3), name: nil, createdAt: base.addingTimeInterval(-90_000),
          recordCount: 2, lastHeardAt: base.addingTimeInterval(-7_200)),
        MemoryLocalPerson(
          personID: person(4), name: "虚构乙", createdAt: base.addingTimeInterval(-80_000),
          recordCount: 1, lastHeardAt: base.addingTimeInterval(-3_600)),
        MemoryLocalPerson(
          personID: person(2), name: nil, createdAt: base.addingTimeInterval(-50_000),
          recordCount: 1, lastHeardAt: base.addingTimeInterval(-7_200)),
      ])
    return MemoryScreenState(projection: projection, now: base, calendar: calendar)
  }

  // MARK: - 按人

  func testPeopleListEveryoneOnceWithTheUnnamedVoicesLastByNumber() throws {
    let state = state()
    let groups = HomeDerivation.peopleGroups(state)
    let all = groups.flatMap(\.rows)
    XCTAssertEqual(Set(all.map(\.id)).count, all.count, "each person once")
    XCTAssertEqual(groups.map(\.title), [nil, "未命名"])
    // Heard here: newest first (虚构乙 1 h ago, 虚构甲 2 h, 虚构丁 5 h, 虚构戊 50 h).
    XCTAssertEqual(groups[0].rows.map(\.person.name), ["虚构乙", "虚构甲", "虚构丁", "虚构戊"])
    let first = try XCTUnwrap(groups[0].rows.first { $0.person.name == "虚构甲" })
    XCTAssertEqual(first.matterCount, 2)
    XCTAssertEqual(HomeDerivation.personSecondLine(first).hasSuffix("等 2 件事"), true)
    // A voice no matter holds: how often it was heard.
    let voice = try XCTUnwrap(groups[0].rows.first { $0.person.name == "虚构乙" })
    XCTAssertNil(voice.matter)
    XCTAssertEqual(HomeDerivation.personSecondLine(voice), "1 段录音中有此声音")
    // 没起名: by their one number (made earlier, smaller number).
    XCTAssertEqual(groups[1].rows.map(\.person.name), ["未命名 1", "未命名 2"])
    XCTAssertEqual(groups[1].rows.map(\.person.personID), [person(3), person(2)])
    XCTAssertTrue(groups[1].rows.allSatisfy(\.person.hasVoice))
    // The merge sheet offers everyone but the person.
    let targets = HomeDerivation.mergeTargets(state, excluding: person(2))
    XCTAssertFalse(targets.contains { $0.personID == person(2) })
    XCTAssertEqual(targets.last?.name, "未命名 1")
    XCTAssertTrue(PersonPicker.matches(try XCTUnwrap(targets.last), "1"))
    // People with a page keep the lens and the sidebar.
    XCTAssertFalse(state.isEmptyLibrary)
  }

  func testOnlyPeopleKnownWithoutAnyMatterStillHaveAHome() {
    let projection = MemoryProjection(
      events: [], records: [], now: base,
      localPeople: [
        MemoryLocalPerson(personID: person(7), name: nil, createdAt: base, recordCount: 3)
      ])
    let state = MemoryScreenState(projection: projection, now: base, calendar: calendar)
    XCTAssertFalse(state.isEmptyLibrary, "the lens control stays to reach 按人")
    XCTAssertEqual(HomeDerivation.peopleGroups(state).flatMap(\.rows).map(\.person.name), ["未命名 1"])
    XCTAssertEqual(
      HomeDerivation.personSecondLine(HomeDerivation.peopleGroups(state)[0].rows[0]),
      "3 段录音中有此声音")
  }

  func testPersonChangesWaitEightSecondsAndCanBeTakenBack() async {
    var sent: [MemoryCorrection] = []
    var due: [(TimeInterval, @MainActor () -> Void)] = []
    let schedule: MemoryCorrectionQueue.Schedule = { delay, work in
      due.append((delay, work))
      return MemoryCorrectionQueue.Scheduled(cancel: {})
    }
    let queue = MemoryCorrectionQueue(schedule: schedule, commit: { sent.append($0) })
    let name = MemoryCorrection.namePerson(personID: person(1), from: "", to: "虚构丙")
    queue.submit(name)
    XCTAssertEqual(queue.held, [name], "shown at once")
    XCTAssertEqual(due.first?.0, 8)
    XCTAssertEqual(queue.undoState, MemoryUndoState(label: "命名", pending: true))
    XCTAssertEqual(queue.undo(), name)
    XCTAssertEqual(queue.held, [])
    let merge = MemoryCorrection.mergePerson(personID: person(2), into: person(1))
    queue.submit(merge)
    due.last?.1()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(sent, [merge], "sent after the window, never the undone name")
    XCTAssertNil(queue.undoState, "a merge has no way back once sent")
  }

  func testPersonToasts() {
    let id = UUID()
    XCTAssertEqual(
      MemoryCorrectionToast.toast(
        for: .namePerson(personID: "p", from: "", to: "虚构丙"), id: id, titles: [:], groups: [:])?
        .text, "已重新命名为“虚构丙”")
    XCTAssertEqual(
      MemoryCorrectionToast.toast(
        for: .mergePerson(personID: "p", into: "q"), id: id, titles: [:], groups: [:],
        names: ["q": "虚构甲"])?.text, "已合并到“虚构甲”")
    let split = MemoryCorrectionToast.toast(
      for: .notPerson(itemID: "i", personID: "p", starts: [1, 2], newPersonID: "n"), id: id,
      titles: [:], groups: [:])
    XCTAssertEqual(split?.text, "已分出 2 句，归为一个未命名的声音")
    XCTAssertEqual(split?.action, .undo)
  }

  func testNotPersonSheetListsThatSpeakersSentencesOnly() {
    let state = state()
    let subject = NotPersonSubject(
      eventID: "A", itemID: item(1), segID: nil, personID: person(1), name: "虚构甲", start: nil)
    let sentences = NotPersonSheet.sentences(subject, state: state)
    XCTAssertEqual(sentences.count, 1)
    XCTAssertEqual(sentences.first?.start, 0)
    XCTAssertEqual(NotPersonSheet.clock(62_000), "1:02")
    XCTAssertEqual(NotPersonSheet.clock(3_723_000), "1:02:03")
  }

  // MARK: - Home (理1-4)

  func testAPageVisitOnlyReadsTheLibraryAgainAtMostOnceAMinute() {
    var refresh = MemoryPageRefresh()
    XCTAssertEqual(refresh.visit(at: base), .reload)
    XCTAssertNil(refresh.visit(at: base.addingTimeInterval(30)))
    XCTAssertNil(refresh.visit(at: base.addingTimeInterval(59)))
    XCTAssertEqual(refresh.visit(at: base.addingTimeInterval(61)), .reload)
    // A clock set back does not stop reloads.
    XCTAssertEqual(refresh.visit(at: base), .reload)
  }

  func testWaitingRecordsAreEverythingNotOrganizedSinceTheOrganizerLastSawAnything() {
    let now = base
    // Never set up: the last 14 days.
    let local = MemoryWaitingRecords.since(
      mirror: false, lastOrganizedAt: nil, newestKnown: nil, now: now, calendar: calendar)
    XCTAssertEqual(local, now.addingTimeInterval(-14 * 86_400))
    // A mirror: after its last pull, else after the newest record it knows.
    let pulled = now.addingTimeInterval(-600)
    XCTAssertEqual(
      MemoryWaitingRecords.since(
        mirror: true, lastOrganizedAt: pulled, newestKnown: now.addingTimeInterval(-9_000),
        now: now, calendar: calendar), pulled)
    let known = now.addingTimeInterval(-9_000)
    XCTAssertEqual(
      MemoryWaitingRecords.since(
        mirror: true, lastOrganizedAt: nil, newestKnown: known, now: now, calendar: calendar),
      known)
    XCTAssertEqual(
      MemoryWaitingRecords.since(
        mirror: true, lastOrganizedAt: nil, newestKnown: nil, now: now, calendar: calendar),
      calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
    let candidates: [MemoryWaitingRecords.Candidate] = [
      .init(id: "a", createdAt: now.addingTimeInterval(-100)),
      .init(id: "b", createdAt: now.addingTimeInterval(-50)),
      .init(id: "c", createdAt: now.addingTimeInterval(-20), failed: true),
      .init(id: "d", createdAt: now.addingTimeInterval(-10)),
      .init(id: "a", createdAt: now.addingTimeInterval(-100)),
      .init(id: "e", createdAt: now.addingTimeInterval(-20_000)),
    ]
    let waiting = MemoryWaitingRecords.waiting(
      candidates, organized: ["D"], since: now.addingTimeInterval(-9_000))
    // Dictations count like everything else; organized, failed, older and
    // repeated records do not.
    XCTAssertEqual(waiting.map(\.id), ["B", "A"])
  }
}
