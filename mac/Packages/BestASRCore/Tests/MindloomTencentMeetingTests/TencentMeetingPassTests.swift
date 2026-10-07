import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

@testable import MindloomTencentMeeting

/// Regression tests for the 2026-10-06 review of the Tencent Meeting entry
/// (synthetic tmeet output only): recordings beyond list-ended's five,
/// retries that never end in silence, server errors, a refusal of a
/// viewable recording, failed listings, the owner by number, paging in
/// Tencent's order, the schedule and the budget, and state written by
/// another version.
final class TencentMeetingPassTests: XCTestCase {
  let owner = "10000000000000000000001"

  // MARK: Recordings of meetings others host

  static func record(
    _ id: String, start: String, type: String = "文字转写", permission: String = "can_view"
  ) -> String {
    """
    {"duration":"30:00","media_start_time":"\(start)","meeting_record_id":"7\(id.dropFirst())",\
    "permission_status":"\(permission)","record_file_count":1,"record_file_id":"\(id)",\
    "state":"转码完成，可根据录制文件权限进行下一步","subject":"他人主持的会","type":"\(type)",\
    "url":"https://meeting.tencent.com/ctm/X\(id.suffix(3))"}
    """
  }

  static func meeting(_ records: [String], total: Int, key: String) -> TencentMeetingRunResult {
    .json(
      """
      {"trace_id":"t","message":"success","data":{"has_more":false,"\(key)":[{"end_time":"2026-10-02T12:00:00+08:00",\
      "meeting_code":"900000020","meeting_id":"8000000000000000020","meeting_type":"普通会议",\
      "records_total_count":\(total),"start_time":"2026-10-02T10:00:00+08:00","sub_meeting_id":"",\
      "subject":"他人主持的会","records":[\(records.joined(separator: ","))]}]}}
      """)
  }

  /// list-ended gives at most five recordings per meeting (here one of
  /// four); `meeting get` lists the rest, and the viewable ones are added.
  /// It runs again a day later, so a recording shared later comes in.
  func testRecordingsBeyondListEndedsFiveComeFromMeetingGet() async throws {
    let first = Self.record("6000000000000000201", start: "2026-10-02T10:00:00+08:00")
    let second = Self.record("6000000000000000202", start: "2026-10-02T11:00:00+08:00")
    let asking = Self.record(
      "6000000000000000203", start: "2026-10-02T11:30:00+08:00", permission: "can_apply")
    let shared = Self.record("6000000000000000203", start: "2026-10-02T11:30:00+08:00")
    let old = Self.record("6000000000000000204", start: "2026-08-20T10:00:00+08:00")
    let tmeet = FakeTmeet { command in
      switch command {
      case .authStatus: return Fixture.ok("auth-status.txt")
      case .recordList:
        return Synthetic.recordList([
          ("8000000000000000010", "6000000000000000101", 3, "10000000000000000000001", "文字转写")
        ])
      case .meetingListEnded:
        return Self.meeting([first], total: 4, key: "meeting_info_list")
      case .meetingGet("8000000000000000020"):
        return Self.meeting([first, second, asking, old], total: 4, key: "meeting_info_list")
      case .transcriptGet(let id, _, nil, _):
        return Synthetic.transcript([(id: "10000000000000000000003", name: "周样本 \(id.suffix(1))")])
      default: return nil
      }
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    var report = await sync.pass(.full, now: Fixture.now)
    XCTAssertNil(report.failure)
    XCTAssertEqual(report.listedInFull, 1)
    XCTAssertEqual(report.added, 3)
    var calls = await tmeet.transcriptCalls()
    XCTAssertEqual(
      Set(calls),
      ["6000000000000000101@-", "6000000000000000201@-", "6000000000000000202@-"])
    var state = await sync.snapshot
    XCTAssertEqual(state.recordings["6000000000000000202"]?.status, .imported)
    XCTAssertEqual(state.recordings["6000000000000000203"]?.status, .needsPermission)
    // Before the window: left out.
    XCTAssertNil(state.recordings["6000000000000000204"])
    XCTAssertEqual(report.truncatedMeetings, 0)
    XCTAssertNil(TencentMeetingStatus.incompleteLine(state: state, now: Fixture.now))

    // An hour later: listed in full already.
    await tmeet.reset()
    report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(3_600))
    var gets = await tmeet.meetingGets()
    XCTAssertEqual(gets, [])

    // A day later the host has shared the third: it comes in.
    await tmeet.set { command in
      if case .meetingGet = command {
        return Self.meeting([first, second, shared, old], total: 4, key: "meeting_info_list")
      }
      if case .transcriptGet(let id, _, nil, _) = command {
        return Synthetic.transcript([(id: "10000000000000000000003", name: "周样本 \(id.suffix(1))")])
      }
      if case .recordList = command {
        return Synthetic.recordList([
          ("8000000000000000010", "6000000000000000101", 3, "10000000000000000000001", "文字转写")
        ])
      }
      if case .meetingListEnded = command {
        return Self.meeting([first], total: 4, key: "meeting_info_list")
      }
      return Fixture.ok("auth-status.txt")
    }
    await tmeet.reset()
    report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(25 * 3_600))
    gets = await tmeet.meetingGets()
    XCTAssertEqual(gets, ["8000000000000000020"])
    calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, ["6000000000000000203@-"])
    state = await sync.snapshot
    XCTAssertEqual(state.recordings["6000000000000000203"]?.status, .imported)
  }

  /// Tencent keeps some recordings back even from `meeting get`: Settings
  /// says so, once per meeting.
  func testAMeetingStillListedInPartIsShown() async {
    let first = Self.record("6000000000000000201", start: "2026-10-02T10:00:00+08:00")
    let tmeet = FakeTmeet { command in
      switch command {
      case .authStatus: return Fixture.ok("auth-status.txt")
      case .recordList: return Synthetic.recordList([])
      case .meetingListEnded, .meetingGet:
        return Self.meeting([first], total: 2, key: "meeting_info_list")
      case .transcriptGet: return Synthetic.transcript([(id: "3", name: "周样本")])
      default: return nil
      }
    }
    let sync = makeSync(tmeet, writer: MemoryWriter())
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.listedInFull, 1)
    XCTAssertEqual(report.truncatedMeetings, 1)
    let state = await sync.snapshot
    XCTAssertEqual(
      TencentMeetingStatus.incompleteLine(state: state, now: Fixture.now), "腾讯会议未列出 1 个会议的全部录制")
  }

  // MARK: Failures

  /// A gateway error on one transcript passes like the network: the pass
  /// stops and the recording keeps its place; three in a row count as one
  /// attempt, so it cannot hold up the others for ever.
  func testServerErrorsWhileFetchingDoNotCountAgainstTheRecording() async {
    let tmeet = FakeTmeet { command in
      if case .transcriptGet("6000000000000000021", _, _, _) = command {
        return Fixture.error("error-502.txt")
      }
      return FakeTmeet.standard(command)
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    var now = Fixture.now
    var report = await sync.pass(.full, now: now)
    XCTAssertEqual(report.failure, .network)
    var state = await sync.snapshot
    XCTAssertEqual(state.recordings["6000000000000000021"]?.status, .pending)
    XCTAssertEqual(state.recordings["6000000000000000021"]?.attempts, 0)
    XCTAssertEqual(state.recordings["6000000000000000021"]?.transientFailures, 1)
    XCTAssertNil(state.lastSuccess)
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: now).text,
      "无法连接腾讯会议。稍后将重试。")
    for _ in 0..<2 {
      now = now.addingTimeInterval(600)
      report = await sync.pass(.light, now: now)
    }
    state = await sync.snapshot
    XCTAssertEqual(state.recordings["6000000000000000021"]?.attempts, 1)
    XCTAssertEqual(state.recordings["6000000000000000021"]?.transientFailures, 0)
    // Now the others come in while it waits.
    report = await sync.pass(.full, now: now.addingTimeInterval(60))
    XCTAssertNil(report.failure)
    let added = await writer.added.count
    XCTAssertEqual(added, 2)
  }

  /// A recording the listing says the account may view, refused when its
  /// transcript is fetched: retried with the usual waits, never every pass
  /// and never offered as 「申请查看…」.
  func testAFetchRefusedForAViewableRecordingIsRetriedAndNeverAskedFor() async {
    let shared = "6000000000000000021"
    let tmeet = FakeTmeet { command in
      if case .transcriptGet("6000000000000000021", _, _, _) = command {
        return Fixture.error("error-403.txt")
      }
      return FakeTmeet.standard(command)
    }
    let sync = makeSync(tmeet, writer: MemoryWriter())
    var now = Fixture.now
    _ = await sync.pass(.full, now: now)
    var state = await sync.snapshot
    XCTAssertEqual(state.recordings[shared]?.status, .pending)
    XCTAssertEqual(state.recordings[shared]?.lastError, .noPermission)
    XCTAssertEqual(state.recordings[shared]?.attempts, 1)
    await tmeet.reset()
    for _ in 0..<5 {
      now = now.addingTimeInterval(120)
      _ = await sync.pass(.light, now: now)
    }
    // Ten minutes: only the second try (after five) was due.
    let calls = await tmeet.transcriptCalls().filter { $0.hasPrefix(shared) }
    XCTAssertEqual(calls.count, 1)
    state = await sync.snapshot
    let asking = TencentMeetingStatus.rows(state: state, now: now).filter { $0.kind == .canApply }
    XCTAssertFalse(asking.contains { $0.id == shared })
    XCTAssertEqual(asking.map(\.id), ["6000000000000000051"])

    // State written before this fix: 「需要申请」 for a viewable recording.
    var legacy = state
    legacy.recordings[shared]?.status = .needsPermission
    XCTAssertFalse(
      TencentMeetingStatus.rows(state: legacy, now: now).contains {
        $0.kind == .canApply && $0.id == shared
      })
  }

  /// A listing that fails is not a successful pass: no 「上次检查」 time and
  /// no full pass recorded; what the other listing gave is still used.
  func testAListingThatFailsIsNotASuccess() async {
    let tmeet = FakeTmeet { command in
      switch command {
      case .recordList, .meetingListEnded: return Fixture.error("error-502.txt")
      default: return FakeTmeet.standard(command)
      }
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    var report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.failure, .network)
    var state = await sync.snapshot
    XCTAssertNil(state.lastFullPass)
    XCTAssertNil(state.lastSuccess)

    // list-ended answers with something that is not tmeet's output: the
    // record list's recordings are added, the pass is still not a success.
    await tmeet.set { command in
      if case .meetingListEnded = command {
        return TencentMeetingRunResult(exitStatus: 0, stdout: Data("<html>".utf8), stderr: Data())
      }
      return FakeTmeet.standard(command)
    }
    report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(600))
    XCTAssertEqual(report.failure, .unreadable)
    XCTAssertEqual(report.added, 3)
    state = await sync.snapshot
    XCTAssertNil(state.lastFullPass)
    XCTAssertNil(state.lastSuccess)
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text,
      TencentMeetingStatus.listingUnreadable)
    // The regular check after it is a full one again.
    XCTAssertEqual(
      TencentMeetingSync.kind(
        for: .regular, state: state, now: Fixture.now.addingTimeInterval(1_800)), .full)

    await tmeet.set(FakeTmeet.standard)
    report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(1_200))
    XCTAssertNil(report.failure)
    state = await sync.snapshot
    XCTAssertEqual(state.lastFullPass, Fixture.now.addingTimeInterval(1_200))
  }

  /// The login's key could not be read: the pass stops with its own
  /// failure and Settings offers to try again (not to reinstall).
  func testAKeyThatCannotBeReadIsNotAMissingHelper() async {
    let tmeet = FakeTmeet { _ in .notLaunched(.key) }
    let sync = makeSync(tmeet, writer: MemoryWriter())
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.failure, .keyUnavailable)
    let state = await sync.snapshot
    let line = TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now)
    XCTAssertEqual(line.text, TencentMeetingStatus.keyUnavailable)
    XCTAssertEqual(line.action, .retry)
  }

  // MARK: The owner

  func ownerSync(
    _ recordings: [(meeting: String, file: String, day: Int, host: String, type: String)],
    transcripts: [String: TencentMeetingRunResult], state: TencentMeetingState? = nil
  ) -> (FakeTmeet, MemoryWriter, TencentMeetingSync) {
    let tmeet = FakeTmeet { command in
      switch command {
      case .authStatus: return Fixture.ok("auth-status.txt")
      case .recordList: return Synthetic.recordList(recordings)
      case .meetingListEnded: return Synthetic.noMeetings
      case .transcriptGet(let id, _, nil, _): return transcripts[id]
      default: return nil
      }
    }
    let writer = MemoryWriter()
    return (tmeet, writer, makeSync(tmeet, writer: writer, state: state))
  }

  func turns(_ writer: MemoryWriter, _ file: String) async throws -> [String] {
    let id = TencentMeetingItem.id(recordFileID: file, version: 0, digest: nil)
    let added = await writer.added
    let item = try XCTUnwrap(added.first { $0.id == id })
    return try XCTUnwrap(MemoryTranscriptText.parse(item.text)).turns.map(\.speaker)
  }

  /// The newest meeting has a participant with the account's display name
  /// and the account does not speak in it: the account is the host of its
  /// own recordings, so that participant is never 「我」.
  func testTheOwnerIsTheHostNotANamesake() async throws {
    let (_, writer, sync) = ownerSync(
      [
        ("8000000000000000071", "6000000000000000071", 1, "11", "文字转写"),
        ("8000000000000000072", "6000000000000000072", 3, "11", "文字转写"),
      ],
      transcripts: [
        "6000000000000000072": Synthetic.transcript([
          (id: "19", name: "林示例"), (id: "4", name: "周样本"),
        ]),
        "6000000000000000071": Synthetic.transcript([
          (id: "11", name: "林示例"), (id: "4", name: "周样本"),
        ]),
      ])
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.added, 2)
    let newer = try await turns(writer, "6000000000000000072")
    let older = try await turns(writer, "6000000000000000071")
    XCTAssertEqual(newer, ["林示例", "周样本"])
    XCTAssertEqual(older, ["我", "周样本"])
    let state = await sync.snapshot
    XCTAssertEqual(state.ownerUserIDs, ["11"])
    XCTAssertEqual(state.ownerEvidence, .hostAndName)
  }

  /// No host decides and two numbers speak under the account's name:
  /// nobody is 「我」 from then on (not the first one seen).
  func testTwoNumbersWithTheAccountsNameAndNoHostMeanNobodyIsMe() async throws {
    let (_, writer, sync) = ownerSync(
      [
        ("8000000000000000071", "6000000000000000071", 1, "30", "文字转写"),
        ("8000000000000000072", "6000000000000000072", 3, "31", "文字转写"),
      ],
      transcripts: [
        "6000000000000000072": Synthetic.transcript([
          (id: "19", name: "林示例"), (id: "4", name: "周样本"),
        ]),
        "6000000000000000071": Synthetic.transcript([
          (id: "11", name: "林示例"), (id: "4", name: "周样本"),
        ]),
      ])
    _ = await sync.pass(.full, now: Fixture.now)
    let state = await sync.snapshot
    XCTAssertEqual(state.ownerUserIDs, [])
    let older = try await turns(writer, "6000000000000000071")
    XCTAssertFalse(older.contains("我"))
  }

  /// The account renamed itself and has not spoken under the new name
  /// yet: the owner known by number stays.
  func testAKnownOwnerStaysAfterTheAccountIsRenamed() async throws {
    var state = TencentMeetingState()
    state.connectedAt = Fixture.now
    state.backfill = .add
    state.ownerUserIDs = ["11"]
    state.ownerEvidence = .hostAndName
    state.people["11"] = TencentMeetingSpeaker(
      names: ["旧名字"], firstSeen: Fixture.now.addingTimeInterval(-86_400),
      lastSeen: Fixture.now.addingTimeInterval(-86_400), recordings: 1, label: "旧名字")
    let (_, _, sync) = ownerSync(
      [("8000000000000000072", "6000000000000000072", 3, "11", "文字转写")],
      transcripts: [
        "6000000000000000072": Synthetic.transcript([(id: "4", name: "周样本")])
      ], state: state)
    _ = await sync.pass(.full, now: Fixture.now)
    let after = await sync.snapshot
    XCTAssertEqual(after.accountName, "林示例")
    XCTAssertEqual(after.ownerUserIDs, ["11"])
  }

  // MARK: Paging

  /// Tencent's `--pid` starts the page at that paragraph in its own order,
  /// which is not always by number (…, 98, 100, 99, 101, …). Every
  /// paragraph is kept when a page boundary falls between the two.
  func testPagingStartsAtTheLastParagraphGiven() async throws {
    let order = Array(0...98) + [100, 99] + Array(101...149)
    let file = "6000000000000000301"
    let tmeet = FakeTmeet { command in
      switch command {
      case .authStatus: return Fixture.ok("auth-status.txt")
      case .recordList:
        return Synthetic.recordList([("8000000000000000301", file, 4, "11", "文字转写")])
      case .meetingListEnded: return Synthetic.noMeetings
      case .transcriptGet(_, _, let pid, let limit):
        let start = pid.flatMap { Int($0) }.flatMap { order.firstIndex(of: $0) } ?? 0
        let page = Array(order[start..<min(order.count, start + limit)])
        return Synthetic.paragraphs(
          page.map { (pid: $0, id: "4", name: "周样本") }, more: start + limit < order.count)
      default: return nil
      }
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    _ = await sync.pass(.full, now: Fixture.now)
    let calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [file + "@-", file + "@100"])
    let state = await sync.snapshot
    XCTAssertEqual(state.recordings[file]?.paragraphs, 150)
    let added = await writer.added
    let item = try XCTUnwrap(added.first)
    XCTAssertEqual(TencentMeetingSourceDocument.parse(item.source)?.paragraphs.count, 150)
  }

  // MARK: Schedule and budget

  func testTheScheduleThrottlesWakesAndLaunches() {
    let now = Fixture.now
    var state = TencentMeetingState()
    func kind(_ trigger: TencentMeetingSync.Trigger) -> TencentMeetingSync.PassKind? {
      TencentMeetingSync.kind(for: trigger, state: state, now: now)
    }
    // Never checked: full.
    XCTAssertEqual(kind(.regular), .full)
    XCTAssertEqual(kind(.wake), .full)
    XCTAssertEqual(kind(.launch), .full)
    // Five minutes after a full pass.
    state.lastPass = now.addingTimeInterval(-300)
    state.lastFullPass = state.lastPass
    XCTAssertNil(kind(.regular))
    XCTAssertNil(kind(.wake))
    XCTAssertNil(kind(.launch))
    XCTAssertEqual(kind(.checkNow), .light)
    XCTAssertEqual(kind(.connected), .full)
    XCTAssertEqual(kind(.answered), .full)
    // Twenty minutes after.
    state.lastPass = now.addingTimeInterval(-1_200)
    state.lastFullPass = state.lastPass
    XCTAssertEqual(kind(.regular), .light)
    XCTAssertNil(kind(.wake))
    XCTAssertEqual(kind(.checkNow), .full)
    // Forty minutes after a light pass, two hours after a full one.
    state.lastPass = now.addingTimeInterval(-2_400)
    state.lastFullPass = now.addingTimeInterval(-7_200)
    XCTAssertEqual(kind(.wake), .light)
    // Four hours after the full one.
    state.lastFullPass = now.addingTimeInterval(-4 * 3_600)
    XCTAssertEqual(kind(.wake), .full)
    XCTAssertEqual(kind(.regular), .full)
  }

  /// A day of waking the Mac every quarter hour, with the regular checks:
  /// the listings never use the day's budget, and a meeting that ends at
  /// nine in the evening is added the same evening. Without the schedule
  /// (a full pass on every wake) the same day runs out before then.
  func testManyWakesInADayLeaveTheBudgetForTheDaysMeetings() async throws {
    let day = ISO8601DateFormatter().date(from: "2026-10-05T23:00:00Z")!  // 07:00 in China
    let late = day.addingTimeInterval(14 * 3_600)  // 21:00
    let own: [(meeting: String, file: String, day: Int, host: String, type: String)] = [
      ("8000000000000000081", "6000000000000000081", 4, owner, "文字转写"),
      ("8000000000000000082", "6000000000000000082", 5, owner, "文字转写"),
    ]
    let evening: (meeting: String, file: String, day: Int, host: String, type: String) = (
      "8000000000000000083", "6000000000000000083", 6, owner, "文字转写"
    )
    func tmeet() -> FakeTmeet {
      FakeTmeet { command in
        switch command {
        case .authStatus: return Fixture.ok("auth-status.txt")
        case .recordList: return Synthetic.recordList(own)
        case .meetingListEnded: return Synthetic.noMeetings
        case .transcriptGet: return Synthetic.transcript([(id: "4", name: "周样本")])
        default: return nil
        }
      }
    }
    // Wakes every 15 minutes from 07:00 to 23:00; the regular check every
    // 90 minutes from 07:00.
    var events: [(Date, TencentMeetingSync.Trigger)] = []
    for minute in stride(from: 0, through: 16 * 60, by: 15) {
      events.append((day.addingTimeInterval(TimeInterval(minute * 60)), .wake))
    }
    for minute in stride(from: 0, through: 16 * 60, by: 90) {
      events.append((day.addingTimeInterval(TimeInterval(minute * 60) + 1), .regular))
    }
    events.sort { $0.0 < $1.0 }

    func run(scheduled: Bool) async throws -> (added: Date?, limited: Bool, requests: Int) {
      let fake = tmeet()
      let writer = MemoryWriter()
      let sync = makeSync(fake, writer: writer)
      var addedAt: Date?
      var limited = false
      var switched = false
      for (time, trigger) in events {
        if !switched, time >= late {
          switched = true
          await fake.set { command in
            switch command {
            case .authStatus: return Fixture.ok("auth-status.txt")
            case .recordList: return Synthetic.recordList(own + [evening])
            case .meetingListEnded: return Synthetic.noMeetings
            case .transcriptGet: return Synthetic.transcript([(id: "4", name: "周样本")])
            default: return nil
            }
          }
        }
        let state = await sync.snapshot
        let kind: TencentMeetingSync.PassKind? =
          scheduled
          ? TencentMeetingSync.kind(for: trigger, state: state, now: time)
          : (trigger == .wake ? .full : .light)
        guard let kind else { continue }
        let report = await sync.pass(kind, now: time)
        if report.failure == .rateLimited { limited = true }
        let found = await writer.existing([
          TencentMeetingItem.id(recordFileID: evening.file, version: 0, digest: nil)
        ])
        if addedAt == nil, !found.isEmpty { addedAt = time }
      }
      let state = await sync.snapshot
      return (addedAt, limited, state.requestsToday)
    }

    let scheduled = try await run(scheduled: true)
    XCTAssertFalse(scheduled.limited)
    let addedAt = try XCTUnwrap(scheduled.added)
    XCTAssertLessThanOrEqual(addedAt.timeIntervalSince(late), 45 * 60)
    XCTAssertLessThanOrEqual(scheduled.requests, 100)

    let unscheduled = try await run(scheduled: false)
    XCTAssertTrue(unscheduled.limited)
    XCTAssertNil(unscheduled.added)
  }

  // MARK: State written by another version

  /// One job this version cannot read (an unknown status, missing fields)
  /// loses no other job, so a transcript the owner deleted does not come
  /// back; the unknown status is written back as it was.
  func testOneJobThisVersionCannotReadLosesNoOther() async throws {
    let writer = MemoryWriter()
    let first = makeSync(FakeTmeet(FakeTmeet.standard), writer: writer)
    _ = await first.pass(.full, now: Fixture.now)
    let deleted = TencentMeetingItem.id(
      recordFileID: "6000000000000000021", version: 0, digest: nil)
    await writer.delete(deleted)
    let snapshot = await first.snapshot
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
    var recordings = object["recordings"] as! [String: Any]
    let known = recordings.count
    recordings["6000000000000000999"] = [
      "meeting_id": "8000000000000000999", "status": "archived", "type": "云录制", "title": "示例",
      "permission": "can_view",
    ]
    recordings["6000000000000000998"] = ["status": "imported", "item_ids": []]
    recordings["6000000000000000997"] = "not a job"
    object["recordings"] = recordings
    let data = try JSONSerialization.data(withJSONObject: object)
    let state = try JSONDecoder().decode(TencentMeetingState.self, from: data)
    XCTAssertEqual(state.recordings.count, known + 2)
    XCTAssertEqual(state.recordings["6000000000000000999"]?.status, .unrecognized)
    XCTAssertEqual(state.recordings["6000000000000000998"]?.permission, .unknown)
    let again =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    XCTAssertEqual(
      ((again["recordings"] as! [String: Any])["6000000000000000999"] as! [String: Any])["status"]
        as? String, "archived")

    let tmeet = FakeTmeet(FakeTmeet.standard)
    let second = makeSync(tmeet, writer: writer, state: state)
    let report = await second.pass(.full, now: Fixture.now.addingTimeInterval(3_600))
    XCTAssertEqual(report.added, 0)
    let back = await writer.existing([deleted])
    XCTAssertEqual(back, [])
    let calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [])
  }
}
