import BestASRDomain
import Foundation
import XCTest

@testable import BestASRMemory

/// v12 people (ALIGNMENT 理3-1, 理3-5): voices this Mac knows are listed
/// without a matter, the people nobody named carry one number everywhere,
/// naming / merging / 不是他 show at once while held, and a recording split
/// across matters keeps who said each sentence. Synthetic data only.
final class MemoryPeopleV12Tests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
  }()

  private let base = Date(timeIntervalSince1970: 1_790_470_800)

  private func item(_ n: Int) -> SessionID {
    SessionID(UUID(uuidString: String(format: "A0000000-0000-4000-8000-%012d", n))!)
  }

  private func person(_ n: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "B0000000-0000-4000-8000-%012d", n))!)
  }

  private func key(_ n: Int) -> String { person(n).rawValue.uuidString }

  private func local(_ n: Int, _ name: String?, created minutes: Double, records: Int = 1)
    -> MemoryLocalPerson
  {
    MemoryLocalPerson(
      personID: key(n), name: name, createdAt: base.addingTimeInterval(minutes * 60),
      recordCount: records, lastHeardAt: base.addingTimeInterval(minutes * 60), hasVoice: true)
  }

  /// A meeting recorded on this Mac: sentences by `speakers` (person,
  /// name, words) in order, each 2 s long on the monotonic clock.
  private func meeting(_ n: Int, _ speakers: [(Int?, String?, String)], playable: Bool = true)
    -> MemoryItemRecord
  {
    var segments: [MemoryItemRecord.Segment] = []
    var people: [MemoryItemRecord.Person] = []
    for (index, turn) in speakers.enumerated() {
      let start = UInt64(index) * 2_000_000_000 + 1_000
      segments.append(
        .init(
          startMilliseconds: Int64(index) * 2_000, endMilliseconds: Int64(index + 1) * 2_000,
          personID: turn.0.map(person), personName: turn.1 ?? (turn.0 == nil ? nil : ""),
          text: turn.2, monotonicStartNanoseconds: start,
          monotonicEndNanoseconds: start + 2_000_000_000))
      if let p = turn.0, !people.contains(where: { $0.id == person(p) }) {
        people.append(.init(id: person(p), name: turn.1 ?? ""))
      }
    }
    return MemoryItemRecord(
      sessionID: item(n), inputMode: .roomMicrophone, itemKind: nil, title: "会议录音",
      startedAt: base.addingTimeInterval(Double(n) * 3_600), updatedAt: base, sourceBundleID: nil,
      sourceDisplayName: "内建麦克风", sourceIdentifier: nil,
      text: speakers.map(\.2).joined(separator: "\n"), segments: segments, people: people,
      playbackAvailable: playable)
  }

  // MARK: - Numbering and the people list

  func testUnnamedVoicesShareOneNumberingByWhenTheyWereFirstKnown() throws {
    let projection = MemoryProjection(
      events: [], records: [],
      ownerPersonIDs: [key(9)],
      localPeople: [
        local(3, nil, created: 30), local(1, nil, created: 10), local(4, "虚构甲", created: 5),
        local(2, nil, created: 20), local(9, nil, created: 1),
      ])
    let people = projection.people()
    // Voices with no matter are listed; the owner never is.
    XCTAssertEqual(Set(people.map(\.personID)), Set([1, 2, 3, 4].map(key)))
    let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.personID, $0) })
    XCTAssertEqual(byID[key(1)]?.name, "未命名 1")
    XCTAssertEqual(byID[key(2)]?.name, "未命名 2")
    XCTAssertEqual(byID[key(3)]?.name, "未命名 3")
    XCTAssertEqual(byID[key(1)]?.unnamedNumber, 1)
    XCTAssertEqual(byID[key(1)]?.isNamed, false)
    XCTAssertEqual(byID[key(4)]?.name, "虚构甲")
    XCTAssertNil(byID[key(4)]?.unnamedNumber)
    XCTAssertTrue(people.allSatisfy(\.hasVoice))
    XCTAssertEqual(byID[key(3)]?.voiceRecords, 1)
    XCTAssertEqual(projection.unnamedName(key(2)), "未命名 2")
  }

  func testAMatterAndItsSentencesUseTheSameNumberAsThePeopleList() throws {
    let record = meeting(1, [(1, nil, "这周把海报定下来。"), (2, "虚构乙", "好的。")])
    let event = MemoryEventSource(
      eventID: "E1", origin: .local, title: "海报", statusLine: "", pinned: false,
      updatedAt: base, itemIDs: [item(1).rawValue.uuidString], personIDs: [])
    let projection = MemoryProjection(
      events: [event], records: [record],
      localPeople: [local(1, nil, created: 1), local(2, "虚构乙", created: 2)])
    let listed = try XCTUnwrap(projection.people().first { $0.personID == key(1) })
    XCTAssertEqual(listed.name, "未命名 1")
    let detail = try XCTUnwrap(projection.event(id: "E1"))
    XCTAssertEqual(detail.people.first { $0.personID == key(1) }?.name, "未命名 1")
    XCTAssertEqual(detail.people.first { $0.personID == key(1) }?.isNamed, false)
    XCTAssertEqual(detail.items.first?.speakerNames[key(1).uppercased()], "未命名 1")
  }

  func testNumbersFollowFirstKnownAndRecordsFillInPeopleTheListLacks() {
    let numbers = MemoryUnnamedNumbers.assign([
      .init(personID: "c", firstKnown: nil),
      .init(personID: "b", firstKnown: base.addingTimeInterval(20)),
      .init(personID: "a", firstKnown: base.addingTimeInterval(30)),
      .init(personID: "a", firstKnown: base.addingTimeInterval(10)),
    ])
    XCTAssertEqual(numbers, ["A": 1, "B": 2, "C": 3])
    XCTAssertEqual(MemoryUnnamedNumbers.label(4), "未命名 4")
    // Without this Mac's people list, an unnamed speaker of a record is
    // numbered by its first record.
    let projection = MemoryProjection(
      events: [], records: [meeting(2, [(5, nil, "嗯。")]), meeting(1, [(6, nil, "好。")])])
    XCTAssertEqual(projection.unnamedName(key(6)), "未命名 1")
    XCTAssertEqual(projection.unnamedName(key(5)), "未命名 2")
  }

  // MARK: - Held corrections

  func testANameShowsAtOnceAndTheOthersMoveUp() throws {
    let record = meeting(1, [(1, nil, "第一句。"), (2, nil, "第二句。")])
    let projection = MemoryProjection(
      events: [], records: [record],
      localPeople: [local(1, nil, created: 1), local(2, nil, created: 2)])
    XCTAssertEqual(projection.unnamedName(key(2)), "未命名 2")
    let named = projection.applying([.namePerson(personID: key(1), from: "", to: "虚构丙")])
    let people = Dictionary(uniqueKeysWithValues: named.people().map { ($0.personID, $0) })
    XCTAssertEqual(people[key(1)]?.name, "虚构丙")
    XCTAssertEqual(people[key(1)]?.isNamed, true)
    XCTAssertEqual(people[key(2)]?.name, "未命名 1")
    XCTAssertEqual(named.item(item(1).rawValue.uuidString).speakerNames[key(1).uppercased()], "虚构丙")
  }

  func testAMergeShowsAtOnceAndFollowsTheOrganizersRule() throws {
    // Two voices only this Mac knows: the chosen one stays.
    let record = meeting(1, [(1, nil, "第一句。"), (2, "虚构丁", "第二句。")])
    let localOnly = MemoryProjection(
      events: [], records: [record],
      localPeople: [local(1, nil, created: 1), local(2, "虚构丁", created: 2)])
    let merged = localOnly.applying([.mergePerson(personID: key(1), into: key(2))])
    XCTAssertEqual(merged.people().map(\.personID), [key(2)])
    XCTAssertEqual(
      merged.item(item(1).rawValue.uuidString).speakerNames[key(1).uppercased()], "虚构丁")
    XCTAssertEqual(merged.canonicalPersonID(key(1)), key(2))
    // A voice joined to a person read from chats: the voice stays and takes
    // the chat person's name (as the organizer applies same_person).
    let persons = try JSONDecoder().decode(
      [RemoteOrganizerPerson].self,
      from: Data(
        """
        [{"person_id":"\(key(1))","display_name":null,"aliases":[],"origin":"voice"},
         {"person_id":"chat-x","display_name":"虚构戊","aliases":[],"origin":"chat"}]
        """.utf8))
    let outcome = MemoryPersonMerge.outcome(person: key(1), into: "chat-x", persons: persons)
    XCTAssertEqual(outcome.stays, key(1))
    XCTAssertEqual(outcome.joins, "chat-x")
    let remote = MemoryProjection(
      events: [], records: [record], persons: persons, localPeople: [local(1, nil, created: 1)]
    )
    .applying([.mergePerson(personID: key(1), into: "chat-x")])
    let voice = try XCTUnwrap(remote.people().first { $0.personID == key(1) })
    XCTAssertEqual(voice.name, "虚构戊")
    XCTAssertFalse(remote.people().contains { $0.personID == "chat-x" })
    // Two chat people: the chosen one stays.
    XCTAssertEqual(
      MemoryPersonMerge.outcome(person: "chat-x", into: key(1), persons: persons).stays, key(1))
  }

  func testNotPersonMovesTheChosenSentencesToANewUnnamedVoice() throws {
    let record = meeting(1, [(1, "虚构甲", "第一句。"), (1, "虚构甲", "第二句。"), (1, "虚构甲", "第三句。")])
    let projection = MemoryProjection(
      events: [], records: [record], localPeople: [local(1, "虚构甲", created: 1)])
    let second = try XCTUnwrap(record.segments[1].monotonicStartNanoseconds)
    let newID = UUID().uuidString
    let split = projection.applying([
      .notPerson(
        itemID: item(1).rawValue.uuidString, personID: key(1), starts: [second], newPersonID: newID)
    ])
    let segments = try XCTUnwrap(split.records[item(1).rawValue.uuidString.uppercased()]?.segments)
    XCTAssertEqual(segments.map { $0.personID?.rawValue.uuidString }, [key(1), newID, key(1)])
    let newcomer = try XCTUnwrap(split.people().first { $0.personID == newID })
    XCTAssertEqual(newcomer.name, "未命名 1")
    XCTAssertTrue(newcomer.hasVoice)
    // Their sample is their own sentence, at most three seconds.
    let sample = try XCTUnwrap(split.voiceSample(of: newID))
    XCTAssertEqual(sample.start, second)
    XCTAssertEqual(sample.end, second + 2_000_000_000)
  }

  func testPersonCorrectionsAreHeldAndUndoableInTheWindowOnly() throws {
    let corrections: [MemoryCorrection] = [
      .namePerson(personID: key(1), from: "", to: "虚构甲"),
      .namePerson(personID: key(1), from: "虚构甲", to: "虚构乙"),
      .mergePerson(personID: key(1), into: key(2)),
      .notPerson(itemID: "I", personID: key(1), starts: [1, 2], newPersonID: key(3)),
    ]
    XCTAssertTrue(corrections.allSatisfy(\.isHeld))
    XCTAssertTrue(corrections.allSatisfy(\.isUndoable))
    XCTAssertEqual(corrections.map(\.undoLabel), ["命名", "命名", "合并", "拆分"])
    // A first name cannot be sent back; a rename can.
    XCTAssertNil(corrections[0].inverse)
    XCTAssertEqual(
      corrections[1].inverse, .namePerson(personID: key(1), from: "虚构乙", to: "虚构甲"))
    XCTAssertNil(corrections[2].inverse)
    XCTAssertNil(corrections[3].inverse)
    XCTAssertEqual(corrections.map(\.personID), Array(repeating: key(1), count: 4))
    // The undo window's journal keeps them across a crash.
    let data = try JSONEncoder().encode(corrections)
    XCTAssertEqual(try JSONDecoder().decode([MemoryCorrection].self, from: data), corrections)
  }

  // MARK: - Samples and splits

  func testAVoiceSampleIsAboutThreeSecondsOfTheirOwn() throws {
    let short = MemoryVoiceStretch(itemID: "a", start: 0, end: 1_000_000_000)
    let long = MemoryVoiceStretch(itemID: "b", start: 10, end: 10 + 8_000_000_000)
    let middle = MemoryVoiceStretch(itemID: "c", start: 0, end: 1_400_000_000)
    let picked = try XCTUnwrap(MemoryVoiceSample.choose([short, long]))
    XCTAssertEqual(picked.itemID, "b")
    XCTAssertEqual(picked.nanoseconds, 3_000_000_000)
    // Nothing long enough: the longest, whole.
    XCTAssertEqual(MemoryVoiceSample.choose([short, middle])?.itemID, "c")
    XCTAssertEqual(MemoryVoiceSample.choose([short, middle])?.nanoseconds, 1_400_000_000)
    XCTAssertNil(MemoryVoiceSample.choose([]))
  }

  func testNotPersonMovesTheTurnsThatMakeTheSentencesTheirs() {
    let turns: [MemorySpeakerSplit.Turn] = [
      .init(id: "t1", start: 0, end: 5_000, personID: key(1)),
      .init(id: "t2", start: 4_000, end: 9_000, personID: key(1)),
      .init(id: "t3", start: 3_000, end: 8_000, personID: key(2)),
    ]
    // Sentence 4_500–8_500: t2 overlaps it most of person 1's turns.
    XCTAssertEqual(
      MemorySpeakerSplit.turns(
        for: [(4_500, 8_500), (100, 900), (4_600, 8_000)], among: turns, person: key(1)),
      ["t1", "t2"])
    XCTAssertEqual(
      MemorySpeakerSplit.turns(for: [(20_000, 21_000)], among: turns, person: key(1)), [])
  }

  // MARK: - 原文: who said it, also for a part (理3-5)

  func testSentenceRangesFollowTheText() {
    let text = "  第一句。\n第二句。\n第一句。"
    XCTAssertEqual(
      MemoryTranscriptText.sentenceRanges(text, sentences: ["第一句。", " 第二句。", "第一句。", ""]),
      [2..<6, 7..<11, 12..<16, 16..<16])
    XCTAssertNil(MemoryTranscriptText.sentenceRanges(text, sentences: ["改过的字"]))
  }

  func testARecordingSplitAcrossMattersKeepsItsSpeakersAndTheirSentences() throws {
    let record = meeting(
      1,
      [
        (1, nil, "海报下周二前交给印刷厂。"), (2, "虚构乙", "预算那边我来问。"), (1, nil, "海报的字号再大一点。"),
      ])
    let text = try XCTUnwrap(record.text)
    let ranges = try XCTUnwrap(
      MemoryTranscriptText.sentenceRanges(text, sentences: record.segments.map(\.text)))
    // The organizer gave the budget sentence to another matter.
    let poster = MemoryEventSource(
      eventID: "E1", origin: .spark, title: "海报印刷", statusLine: "", pinned: false,
      updatedAt: base, itemIDs: [item(1).rawValue.uuidString], personIDs: [],
      segments: [
        MemoryItemSegment(
          itemID: item(1).rawValue.uuidString, segID: "s1", start: ranges[0].lowerBound,
          end: ranges[0].upperBound, gist: "海报"),
        MemoryItemSegment(
          itemID: item(1).rawValue.uuidString, segID: "s3", start: ranges[2].lowerBound,
          end: ranges[2].upperBound, gist: "字号"),
      ])
    let budget = MemoryEventSource(
      eventID: "E2", origin: .spark, title: "预算", statusLine: "", pinned: false,
      updatedAt: base, itemIDs: [item(1).rawValue.uuidString], personIDs: [],
      segments: [
        MemoryItemSegment(
          itemID: item(1).rawValue.uuidString, segID: "s2", start: ranges[1].lowerBound,
          end: ranges[1].upperBound, gist: "预算")
      ])
    let projection = MemoryProjection(
      events: [poster, budget], records: [record],
      localPeople: [local(1, nil, created: 1), local(2, "虚构乙", created: 2)])
    let digest = MemoryDigest(projection: projection, now: base, calendar: calendar)
    let budgetLines = try XCTUnwrap(
      projection.matterTexts(try XCTUnwrap(digest.matter("E2"))).first?.lines)
    XCTAssertEqual(budgetLines.map(\.speaker), ["虚构乙"])
    XCTAssertEqual(budgetLines.first?.words, "预算那边我来问。")
    let voice = try XCTUnwrap(budgetLines.first?.voice)
    XCTAssertEqual(voice.personID, key(2).uppercased())
    XCTAssertEqual(voice.start, record.segments[1].monotonicStartNanoseconds)
    XCTAssertEqual(voice.end, record.segments[1].monotonicEndNanoseconds)
    let posterEntries = projection.matterTexts(try XCTUnwrap(digest.matter("E1")))
    XCTAssertEqual(posterEntries.count, 2)
    for entry in posterEntries {
      XCTAssertEqual(entry.lines.map(\.speaker), ["未命名 1"])
      XCTAssertNotNil(entry.lines.first?.voice)
    }
    // Not playable here: names stay, nothing to play.
    let silent = MemoryProjection(
      events: [budget],
      records: [
        meeting(
          1, [(1, nil, "海报下周二前交给印刷厂。"), (2, "虚构乙", "预算那边我来问。"), (1, nil, "海报的字号再大一点。")],
          playable: false)
      ],
      localPeople: [local(1, nil, created: 1), local(2, "虚构乙", created: 2)])
    let silentDigest = MemoryDigest(projection: silent, now: base, calendar: calendar)
    let silentLines = try XCTUnwrap(
      silent.matterTexts(try XCTUnwrap(silentDigest.matter("E2"))).first?.lines)
    XCTAssertEqual(silentLines.map(\.speaker), ["虚构乙"])
    XCTAssertNil(silentLines.first?.voice)
  }

  func testAPartOfAnEditedTextShowsItsWordsWithoutGuessingSpeakers() throws {
    var record = meeting(1, [(1, nil, "原来的第一句。"), (2, "虚构乙", "原来的第二句。")])
    record = MemoryItemRecord(
      sessionID: record.sessionID, inputMode: record.inputMode, itemKind: nil, title: record.title,
      startedAt: record.startedAt, updatedAt: record.updatedAt, sourceBundleID: nil,
      sourceDisplayName: record.sourceDisplayName, sourceIdentifier: nil,
      text: "改过的整段话，没有原来的句子。", segments: record.segments, people: record.people,
      playbackAvailable: true)
    let event = MemoryEventSource(
      eventID: "E1", origin: .spark, title: "整段话", statusLine: "", pinned: false,
      updatedAt: base, itemIDs: [item(1).rawValue.uuidString], personIDs: [],
      segments: [
        MemoryItemSegment(
          itemID: item(1).rawValue.uuidString, segID: "s1", start: 0, end: 6, gist: "")
      ])
    let projection = MemoryProjection(events: [event], records: [record])
    let digest = MemoryDigest(projection: projection, now: base, calendar: calendar)
    let lines = try XCTUnwrap(
      projection.matterTexts(try XCTUnwrap(digest.matter("E1"))).first?.lines)
    XCTAssertEqual(lines.map(\.speaker), [""])
    XCTAssertNil(lines.first?.voice)
  }

  func testWhatAPersonSaidIsListedNewestFirst() {
    let older = meeting(1, [(1, nil, "旧的一句。"), (2, "虚构乙", "别人的。")])
    let newer = meeting(3, [(1, nil, "新的一句。"), (1, nil, "又一句。"), (1, nil, "第三句。")])
    let projection = MemoryProjection(
      events: [], records: [older, newer], localPeople: [local(1, nil, created: 1)])
    let lines = projection.spokenLines(of: key(1))
    XCTAssertEqual(lines.map(\.words), ["新的一句。", "又一句。", "旧的一句。"])
    XCTAssertEqual(lines.first?.speakerID, key(1).uppercased())
    XCTAssertNotNil(lines.first?.voice)
  }
}
