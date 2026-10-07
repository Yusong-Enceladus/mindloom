import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

@testable import MindloomTencentMeeting

/// One pass of the Tencent Meeting entry against a fake tmeet answering
/// with the synthetic fixtures (ARCH v3 §6, TENCENT-V2 §9).
final class TencentMeetingSyncTests: XCTestCase {
  let cloud = "6000000000000000011"
  let text = "6000000000000000012"
  let shared = "6000000000000000021"
  let transcoding = "6000000000000000031"
  let older = "6000000000000000041"

  func testAFullPassAddsEveryViewableTranscriptOnceAndListsTheRest() async throws {
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    let box = StateBox()
    let sync = makeSync(tmeet, writer: writer, box: box)
    let report = await sync.pass(.full, now: Fixture.now)

    XCTAssertNil(report.failure)
    XCTAssertEqual(report.added, 3)
    // status, 2 + 1 listing pages, the two meetings listed in full, 4
    // transcript pages; list-ended is three requests, meeting get four.
    XCTAssertEqual(report.calls, 10)
    XCTAssertEqual(report.requests, 1 + 2 + 3 + 2 * 4 + 4)
    XCTAssertEqual(report.listedInFull, 2)
    let meetingGets = await tmeet.meetingGets()
    XCTAssertEqual(meetingGets, ["8000000000000000002", "8000000000000000005"])
    // The cloud recording of meeting 1 and the one meeting get found in
    // meeting 2, each covered by its meeting's text transcription.
    XCTAssertEqual(report.covered, 2)
    XCTAssertEqual(report.needsPermission, 2)
    // Meeting 2: Tencent counts 5, meeting get lists 2.
    XCTAssertEqual(report.truncatedMeetings, 1)
    let transcriptCalls = await tmeet.transcriptCalls()
    // Newest first; the text transcription in two pages (the second from
    // the last paragraph of the first); the cloud recording of the same
    // meeting not at all.
    XCTAssertEqual(transcriptCalls, [shared + "@-", text + "@-", text + "@2", older + "@-"])

    let state = await sync.snapshot
    XCTAssertEqual(state.recordings[cloud]?.status, .covered)
    XCTAssertEqual(state.recordings[cloud]?.coveredBy, text)
    XCTAssertEqual(state.recordings[text]?.status, .imported)
    XCTAssertEqual(state.recordings[text]?.paragraphs, 5)
    XCTAssertEqual(state.recordings[shared]?.status, .imported)
    XCTAssertEqual(state.recordings[transcoding]?.status, .waiting)
    XCTAssertEqual(state.recordings["6000000000000000051"]?.status, .needsPermission)
    XCTAssertEqual(state.recordings["6000000000000000052"]?.status, .needsPermission)
    XCTAssertEqual(state.recordings["6000000000000000061"]?.status, .unavailable)
    XCTAssertEqual(state.recordings["6000000000000000022"]?.status, .covered)
    XCTAssertEqual(state.recordings["6000000000000000053"]?.status, .unavailable)
    XCTAssertEqual(state.recordCounts["8000000000000000002"]?.isIncomplete, true)
    XCTAssertEqual(state.recordCounts["8000000000000000005"]?.isIncomplete, false)
    XCTAssertEqual(
      TencentMeetingStatus.incompleteLine(state: state, now: Fixture.now), "腾讯会议未列出 1 个会议的全部录制")
    XCTAssertEqual(state.requestsToday, 18)
    XCTAssertEqual(state.addedToday, 3)
    XCTAssertEqual(box.state, state)

    // Items: fixed numbers, the meeting's start, the export format.
    let items = await writer.added
    XCTAssertEqual(items.count, 3)
    let item = try XCTUnwrap(
      items.first { $0.id == TencentMeetingItem.id(recordFileID: text, version: 0, digest: nil) })
    XCTAssertEqual(item.capturedAt, ISO8601DateFormatter().date(from: "2026-09-29T12:00:10Z"))
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(item.text))
    XCTAssertEqual(transcript.format.meetingApp, "腾讯会议")
    XCTAssertEqual(transcript.turns.first?.speaker, "我")
    let source = try XCTUnwrap(TencentMeetingSourceDocument.parse(item.source))
    XCTAssertEqual(source.paragraphs.count, 5)
    XCTAssertTrue(
      item.source.range(
        of: Data(
          Fixture.text("transcript-12-p2.json").trimmingCharacters(in: .whitespacesAndNewlines).utf8
        )) != nil)
    let titled = try XCTUnwrap(
      items.first { $0.id == TencentMeetingItem.id(recordFileID: older, version: 0, digest: nil) })
    XCTAssertTrue(titled.text.hasPrefix("会议：示例(14:00)\n"))
    XCTAssertEqual(MemoryTranscriptText.parse(titled.text)?.turns.map(\.speaker), ["周样本", "发言人 1"])

    // People: one per user number; the account is the owner (host of its
    // own recording, speaking under its name).
    XCTAssertEqual(state.ownerUserIDs, ["10000000000000000000001"])
    XCTAssertEqual(state.ownerEvidence, .hostAndName)
    XCTAssertEqual(state.people.count, 3)
    XCTAssertEqual(state.people["10000000000000000000002"]?.recordings, 3)
    XCTAssertEqual(state.people["10000000000000000000004"]?.name, "周样本")
  }

  func testTheNextPassFetchesNothingAgainAndALightPassListsOnlyViewable() async {
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    _ = await sync.pass(.full, now: Fixture.now)
    await tmeet.reset()
    let later = Fixture.now.addingTimeInterval(3_600)
    let report = await sync.pass(.full, now: later)
    XCTAssertEqual(report.added, 0)
    let transcriptCalls = await tmeet.transcriptCalls()
    XCTAssertEqual(transcriptCalls, [])
    // The login was checked an hour ago, the meetings listed in full too:
    // listings only.
    XCTAssertEqual(report.calls, 3)
    let gets = await tmeet.meetingGets()
    XCTAssertEqual(gets, [])
    await tmeet.reset()
    let light = await sync.pass(.light, now: later.addingTimeInterval(600))
    XCTAssertEqual(light.calls, 2)
    let commands = await tmeet.commands
    XCTAssertTrue(commands.allSatisfy { if case .recordList = $0 { true } else { false } })
    let count = await writer.added.count
    XCTAssertEqual(count, 3)
  }

  func testAChangedListingRefetchesAndOnlyChangedWordsMakeANewItem() async throws {
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    _ = await sync.pass(.full, now: Fixture.now)

    // Tencent changed the recording's listing; the words are the same.
    let changedListing = Data(
      Fixture.text("record-list-p1.json").replacingOccurrences(
        of: "\"record_size\":12345678", with: "\"record_size\":12345679"
      )
      .replacingOccurrences(of: "2026-09-30T10:25:00+08:00", with: "2026-09-30T10:26:00+08:00").utf8
    )
    await tmeet.set { command in
      if case .recordList(_, _, nil) = command {
        return TencentMeetingRunResult(exitStatus: 0, stdout: changedListing, stderr: Data())
      }
      return FakeTmeet.standard(command)
    }
    await tmeet.reset()
    var report = await sync.pass(.light, now: Fixture.now.addingTimeInterval(600))
    XCTAssertEqual(report.unchanged, 1)
    XCTAssertEqual(report.added, 0)
    var calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [shared + "@-"])

    // Changed again, and now the words differ: a second item; the first stays.
    let changedAgain = Data(
      String(decoding: changedListing, as: UTF8.self).replacingOccurrences(
        of: "2026-09-30T10:26:00+08:00", with: "2026-09-30T10:27:00+08:00"
      ).utf8)
    let editedWords = Data(
      Fixture.text("transcript-21.json").replacingOccurrences(of: "讨论开始。", with: "讨论现在开始。").utf8)
    await tmeet.set { command in
      switch command {
      case .recordList(_, _, nil):
        return TencentMeetingRunResult(exitStatus: 0, stdout: changedAgain, stderr: Data())
      case .transcriptGet("6000000000000000021", _, _, _):
        return TencentMeetingRunResult(exitStatus: 0, stdout: editedWords, stderr: Data())
      default: return FakeTmeet.standard(command)
      }
    }
    report = await sync.pass(.light, now: Fixture.now.addingTimeInterval(1_200))
    XCTAssertEqual(report.added, 1)
    let state = await sync.snapshot
    XCTAssertEqual(state.recordings[shared]?.itemIDs.count, 2)
    let first = TencentMeetingItem.id(recordFileID: shared, version: 0, digest: nil)
    let firstStill = await writer.existing([first])
    XCTAssertEqual(firstStill, [first])

    // The owner deleted both; a third change adds nothing back.
    for id in state.recordings[shared]!.itemIDs {
      await writer.delete(SessionID(UUID(uuidString: id)!))
    }
    let thirdWords = Data(
      Fixture.text("transcript-21.json").replacingOccurrences(of: "讨论开始。", with: "第三版。").utf8)
    let changedThird = Data(
      String(decoding: changedAgain, as: UTF8.self).replacingOccurrences(
        of: "2026-09-30T10:27:00+08:00", with: "2026-09-30T10:28:00+08:00"
      ).utf8)
    await tmeet.set { command in
      switch command {
      case .recordList(_, _, nil):
        return TencentMeetingRunResult(exitStatus: 0, stdout: changedThird, stderr: Data())
      case .transcriptGet("6000000000000000021", _, _, _):
        return TencentMeetingRunResult(exitStatus: 0, stdout: thirdWords, stderr: Data())
      default: return FakeTmeet.standard(command)
      }
    }
    await tmeet.reset()
    report = await sync.pass(.light, now: Fixture.now.addingTimeInterval(1_800))
    XCTAssertEqual(report.added, 0)
    calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [shared + "@-"])
    let remaining = await writer.added.filter { $0.id.rawValue.uuidString.isEmpty == false }.count
    XCTAssertEqual(remaining, 2)  // the two other meetings' items
  }

  func testAnEmptyTextTranscriptionLetsTheCloudRecordingIn() async throws {
    let tmeet = FakeTmeet { command in
      if case .transcriptGet("6000000000000000012", _, _, _) = command {
        return Fixture.error("error-30002.txt")
      }
      return FakeTmeet.standard(command)
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.noContent, 1)
    let state = await sync.snapshot
    XCTAssertEqual(state.recordings[text]?.status, .noContent)
    XCTAssertEqual(state.recordings[cloud]?.status, .imported)
    XCTAssertEqual(report.added, 3)
    let rows = TencentMeetingStatus.rows(state: state, now: Fixture.now)
    XCTAssertEqual(rows.filter { $0.kind == .noTranscript }.map(\.id), [text])
  }

  func testATranscriptStillBeingMadeIsRetriedLaterThenDailyUntilItIsAdded() async throws {
    // The meeting's cloud recording (found by meeting get) has no text: it
    // is tried once the text transcription has failed, and stays out.
    let cloudOfMeeting2 = "6000000000000000022"
    let tmeet = FakeTmeet { command in
      if case .transcriptGet("6000000000000000021", _, _, _) = command {
        return Fixture.error("error-30003.txt")
      }
      if case .transcriptGet("6000000000000000022", _, _, _) = command {
        return Fixture.error("error-30002.txt")
      }
      return FakeTmeet.standard(command)
    }
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer, budget: 500, reserve: 100)
    var now = Fixture.now
    var report = await sync.pass(.full, now: now)
    XCTAssertEqual(report.generating, 1)
    var state = await sync.snapshot
    XCTAssertEqual(state.recordings[shared]?.status, .pending)
    XCTAssertEqual(state.recordings[shared]?.nextAttempt, now.addingTimeInterval(300))
    XCTAssertEqual(
      TencentMeetingStatus.line(
        state: state, helperAvailable: true, now: now, calendar: Fixture.calendar
      ).text, "腾讯会议正在生成转写，完成后自动添加")
    // Not due yet: not asked again.
    await tmeet.reset()
    report = await sync.pass(.light, now: now.addingTimeInterval(60))
    var calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [])
    for _ in 0..<6 {
      now = now.addingTimeInterval(90 * 60)
      report = await sync.pass(.full, now: now)
    }
    state = await sync.snapshot
    XCTAssertEqual(state.recordings[shared]?.status, .failed)
    XCTAssertEqual(state.recordings[shared]?.attempts, TencentMeetingRecordingJob.maximumAttempts)
    XCTAssertEqual(state.recordings[shared]?.lastError, .generating)
    // Shown: one meeting whose transcript is not added yet.
    XCTAssertEqual(report.notAdded, 1)
    let rows = TencentMeetingStatus.rows(state: state, now: now).filter { $0.kind == .notAdded }
    XCTAssertEqual(rows.map(\.id), [shared])
    XCTAssertEqual(TencentMeetingStatus.rowLabel(.notAdded), "未能添加，稍后将重试")
    // Not again the same day; the meeting's cloud recording (only meeting
    // get lists it, so the next full pass lists the meeting in full) is
    // tried instead, and has no text.
    await tmeet.reset()
    _ = await sync.pass(.full, now: now.addingTimeInterval(3 * 3_600))
    calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [cloudOfMeeting2 + "@-"])
    state = await sync.snapshot
    XCTAssertEqual(state.recordings[cloudOfMeeting2]?.status, .noContent)
    // …but the next day, and Tencent has finished it: added.
    await tmeet.set(FakeTmeet.standard)
    await tmeet.reset()
    report = await sync.pass(.full, now: now.addingTimeInterval(86_400))
    calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [shared + "@-"])
    XCTAssertEqual(report.added, 1)
    state = await sync.snapshot
    XCTAssertEqual(state.recordings[shared]?.status, .imported)
    XCTAssertEqual(
      TencentMeetingStatus.rows(state: state, now: now).filter { $0.kind == .notAdded }, [])
  }

  func testTencentsCallLimitPausesUntilTomorrow() async {
    let tmeet = FakeTmeet { command in
      if case .transcriptGet = command { return Fixture.error("error-500246.txt") }
      return FakeTmeet.standard(command)
    }
    let sync = makeSync(tmeet, writer: MemoryWriter())
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.failure, .rateLimited)
    let state = await sync.snapshot
    let paused = try! XCTUnwrap(state.pausedUntil)
    XCTAssertEqual(
      Fixture.calendar.dateComponents([.day, .hour, .minute], from: paused),
      DateComponents(day: 6, hour: 0, minute: 5))
    XCTAssertEqual(
      TencentMeetingStatus.line(
        state: state, helperAvailable: true, now: Fixture.now, calendar: Fixture.calendar
      ).text,
      "今天的查询次数已用完，明天继续")
    await tmeet.reset()
    let again = await sync.pass(.full, now: Fixture.now.addingTimeInterval(3_600))
    XCTAssertEqual(again.failure, .rateLimited)
    let commands = await tmeet.commands
    XCTAssertEqual(commands, [])
  }

  func testTheDailyBudgetStopsAPassAndTheNextDayGoesOn() async {
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    // Listings may use 6 requests: the status, record list and list-ended;
    // meeting get waits. Transcripts the remaining 3.
    let sync = makeSync(tmeet, writer: writer, budget: 9, reserve: 3)
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.calls, 7)
    XCTAssertEqual(report.requests, 9)
    let gets = await tmeet.meetingGets()
    XCTAssertEqual(gets, [])
    let first = await writer.added.count
    XCTAssertEqual(first, 2)
    XCTAssertEqual(report.failure, .rateLimited)
    let tomorrow = Fixture.now.addingTimeInterval(86_400)
    let next = await sync.pass(.full, now: tomorrow)
    XCTAssertNil(next.failure)
    let count = await writer.added.count
    XCTAssertEqual(count, 3)
  }

  func testARefusedLoginAsksToReconnectAndANetworkFailureKeepsItsPlace() async {
    let tmeet = FakeTmeet { command in
      if case .authStatus = command { return Fixture.error("error-token.txt") }
      return FakeTmeet.standard(command)
    }
    let sync = makeSync(tmeet, writer: MemoryWriter())
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.failure, .notConnected)
    var state = await sync.snapshot
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text,
      "需要重新连接")
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).action,
      .reconnect)

    await tmeet.set { command in
      if case .transcriptGet("6000000000000000012", _, _, _) = command {
        return Fixture.error("error-network.txt")
      }
      return FakeTmeet.standard(command)
    }
    let network = await sync.pass(.full, now: Fixture.now.addingTimeInterval(60))
    XCTAssertEqual(network.failure, .network)
    state = await sync.snapshot
    // What was done before the failure stays; the failed one is retried
    // without counting it against the recording.
    XCTAssertEqual(state.recordings[shared]?.status, .imported)
    XCTAssertEqual(state.recordings[text]?.status, .pending)
    XCTAssertEqual(state.recordings[text]?.attempts, 0)
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text,
      "无法连接腾讯会议。稍后将重试。")
  }

  func testTheFirstQuestionHoldsEarlierMeetingsAndItsAnswerStands() async {
    var state = TencentMeetingState()
    state.connectedAt = ISO8601DateFormatter().date(from: "2026-09-29T13:00:00Z")  // 21:00 in China
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer, state: state)
    var report = await sync.pass(.full, now: Fixture.now)
    // Only the meeting after the connection (09-30) is added.
    XCTAssertEqual(report.added, 1)
    XCTAssertEqual(report.waitingForAnswer, 2)
    await sync.answerBackfill(add: false, now: Fixture.now)
    report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(60))
    XCTAssertEqual(report.added, 0)
    let snapshot = await sync.snapshot
    XCTAssertEqual(snapshot.recordings[text]?.status, .skipped)
    XCTAssertEqual(snapshot.recordings[older]?.status, .skipped)

    let other = makeSync(FakeTmeet(FakeTmeet.standard), writer: MemoryWriter(), state: state)
    _ = await other.pass(.full, now: Fixture.now)
    await other.answerBackfill(add: true, now: Fixture.now)
    let added = await other.pass(.full, now: Fixture.now.addingTimeInterval(60))
    XCTAssertEqual(added.added, 2)
  }

  /// One user number is one name in every meeting: a changed display name
  /// keeps it, a second person with the same display name gets “ 2” in
  /// every meeting, the account is 「我」 everywhere.
  func testEachUserNumberIsWrittenUnderOneNameInEveryMeeting() async throws {
    func meeting(_ n: Int, day: Int) -> String {
      """
      {"host_user_id":"10000000000000000000001","media_start_time":"2026-10-0\(day)T09:00:00+08:00",\
      "meeting_code":"90000007\(n)","meeting_id":"800000000000000007\(n)",\
      "meeting_record_id":"700000000000000007\(n)","record_files":[{"record_end_time":"2026-10-0\(day)T09:30:00+08:00",\
      "record_file_id":"600000000000000007\(n)","record_start_time":"2026-10-0\(day)T09:00:00+08:00",\
      "record_size":1000}],"record_type":"文字转写","state":"转码完成，可根据录制文件权限进行下一步",\
      "state_int":3,"subject":"示例会议 \(n)"}
      """
    }
    func transcript(_ speakers: [(id: String, name: String)]) -> Data {
      let paragraphs = speakers.enumerated().map { index, speaker in
        """
        {"end_time":"00:\(10 + index * 10)","pid":"\(index)","sentences":[{"words":[{"text":"第\(index + 1)句。"}]}],\
        "speaker":{"user_id":"\(speaker.id)","user_name":"\(speaker.name)"},"start_time":"00:\(index)1"}
        """
      }
      return Data(
        """
        {"trace_id":"t","message":"success","data":{"code":0,"minutes":{"paragraphs":[\(paragraphs.joined(separator: ","))]},"more":false}}
        """.utf8)
    }
    let owner = "10000000000000000000001"
    let wang = "10000000000000000000007"
    let li = "10000000000000000000008"
    let otherLi = "10000000000000000000009"
    let listing = Data(
      """
      {"trace_id":"t","message":"success","data":{"has_more":false,"record_meetings":[\(meeting(1, day: 1)),\(meeting(2, day: 3))]}}
      """.utf8)
    let ended = Data(
      #"{"trace_id":"t","message":"success","data":{"has_more":false,"meeting_info_list":[]}}"#.utf8
    )
    // Meeting 2 (the newer, fetched first): 王 under a new display name, a
    // second 李示例, then the first 李示例.
    let first = transcript([(wang, "王示例"), (li, "李示例"), (owner, "林示例")])
    let second = transcript([(wang, "王老师"), (otherLi, "李示例"), (li, "李示例"), (owner, "林示例")])
    let tmeet = FakeTmeet { command in
      switch command {
      case .authStatus: return Fixture.ok("auth-status.txt")
      case .recordList:
        return TencentMeetingRunResult(exitStatus: 0, stdout: listing, stderr: Data())
      case .meetingListEnded:
        return TencentMeetingRunResult(exitStatus: 0, stdout: ended, stderr: Data())
      case .transcriptGet("6000000000000000071", _, nil, _):
        return TencentMeetingRunResult(exitStatus: 0, stdout: first, stderr: Data())
      case .transcriptGet("6000000000000000072", _, nil, _):
        return TencentMeetingRunResult(exitStatus: 0, stdout: second, stderr: Data())
      default: return nil
      }
    }
    let writer = MemoryWriter()
    let box = StateBox()
    let sync = makeSync(tmeet, writer: writer, box: box)
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertNil(report.failure)
    XCTAssertEqual(report.added, 2)

    func turns(_ recordFileID: String) async throws -> [String] {
      let id = TencentMeetingItem.id(recordFileID: recordFileID, version: 0, digest: nil)
      let added = await writer.added
      let item = try XCTUnwrap(added.first { $0.id == id })
      return try XCTUnwrap(MemoryTranscriptText.parse(item.text)).turns.map(\.speaker)
    }
    let newer = try await turns("6000000000000000072")
    let older = try await turns("6000000000000000071")
    XCTAssertEqual(newer, ["王老师", "李示例", "李示例 2", "我"])
    XCTAssertEqual(older, ["王老师", "李示例 2", "我"])

    let state = await sync.snapshot
    XCTAssertEqual(state.ownerUserIDs, [owner])
    XCTAssertEqual(state.people[wang]?.label, "王老师")
    XCTAssertEqual(state.people[wang]?.names, ["王老师", "王示例"])
    XCTAssertEqual(state.people[wang]?.recordings, 2)
    XCTAssertEqual(state.people[otherLi]?.label, "李示例")
    XCTAssertEqual(state.people[li]?.label, "李示例 2")
    let labels = state.people.values.compactMap(\.label)
    XCTAssertEqual(Set(labels).count, labels.count)
    // The labels are saved with the state and read back.
    let saved = try JSONEncoder().encode(XCTUnwrap(box.state))
    XCTAssertEqual(
      try JSONDecoder().decode(TencentMeetingState.self, from: saved).people[li]?.label, "李示例 2")
  }

  /// State written before labels existed: the numbers get them on the next
  /// transcript, the earliest name each used, in the order first seen.
  func testSpeakersSavedWithoutLabelsGetTheirEarliestName() {
    let day = 86_400.0
    var people: [String: TencentMeetingSpeaker] = [
      "7": TencentMeetingSpeaker(
        names: ["新名字", "旧名字"], firstSeen: Fixture.now.addingTimeInterval(-3 * day),
        lastSeen: Fixture.now.addingTimeInterval(-day), recordings: 2),
      "8": TencentMeetingSpeaker(
        names: ["旧名字"], firstSeen: Fixture.now.addingTimeInterval(-2 * day),
        lastSeen: Fixture.now.addingTimeInterval(-2 * day), recordings: 1),
    ]
    TencentMeetingSpeakers.learn(
      [
        TencentMeetingParagraph(
          pid: 0, startMilliseconds: 0, endMilliseconds: 1_000, speakerUserID: "9",
          speakerName: "第三人", text: "一句。")
      ], at: Fixture.now, people: &people)
    XCTAssertEqual(people["9"]?.label, "第三人")
    XCTAssertEqual(people["7"]?.label, "旧名字")
    XCTAssertEqual(people["8"]?.label, "旧名字 2")
  }

  func testAPassCutShortAfterAddingFindsTheItemWithoutFetchingIt() async {
    let writer = MemoryWriter()
    let first = makeSync(FakeTmeet(FakeTmeet.standard), writer: writer)
    _ = await first.pass(.full, now: Fixture.now)
    // The jobs were lost (the state file was not saved); the items exist.
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let second = makeSync(tmeet, writer: writer)
    let report = await second.pass(.full, now: Fixture.now.addingTimeInterval(60))
    XCTAssertEqual(report.added, 0)
    let calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [])
    let state = await second.snapshot
    XCTAssertEqual(state.recordings[text]?.status, .imported)
    let count = await writer.added.count
    XCTAssertEqual(count, 3)
  }

  func testDisconnectingKeepsWhatWasAddedSoNothingComesBackTwice() async {
    let tmeet = FakeTmeet(FakeTmeet.standard)
    let writer = MemoryWriter()
    let sync = makeSync(tmeet, writer: writer)
    _ = await sync.pass(.full, now: Fixture.now)
    let added = await writer.added
    await writer.delete(added[0].id)
    await sync.disconnected()
    var state = await sync.snapshot
    XCTAssertNil(state.connectedAt)
    XCTAssertNil(state.accountName)
    XCTAssertEqual(TencentMeetingStatus.line(state: state, helperAvailable: true).action, .connect)
    await sync.connected(at: Fixture.now.addingTimeInterval(600))
    await tmeet.reset()
    let report = await sync.pass(.full, now: Fixture.now.addingTimeInterval(700))
    XCTAssertEqual(report.added, 0)
    let calls = await tmeet.transcriptCalls()
    XCTAssertEqual(calls, [])
    state = await sync.snapshot
    XCTAssertEqual(state.recordings.values.filter { $0.status == .imported }.count, 3)
  }

  func testTheStateFileReadsBackAndIgnoresWhatItDoesNotKnow() throws {
    var state = TencentMeetingState()
    state.connectedAt = Fixture.now
    state.backfill = .skip(before: Fixture.now)
    state.recordings["1"] = TencentMeetingRecordingJob(
      meetingID: "2", type: .textTranscription, title: "示例", permission: .canView, status: .imported
    )
    state.people["3"] = TencentMeetingSpeaker(
      names: ["甲"], firstSeen: Fixture.now, lastSeen: Fixture.now, recordings: 1)
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(TencentMeetingState.self, from: data), state)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["unknown_field"] = 1
    object["backfill"] = "garbage"
    let decoded = try JSONDecoder().decode(
      TencentMeetingState.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded.backfill, .notAsked)
    XCTAssertEqual(decoded.recordings.count, 1)
  }

  func testStatusLinesFollowTheLoginsEnd() {
    var state = TencentMeetingState()
    XCTAssertEqual(TencentMeetingStatus.line(state: state, helperAvailable: true).text, "未连接")
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: false).text,
      TencentMeetingStatus.helperMissing)
    state.connectedAt = Fixture.now
    state.refreshTokenExpires = Fixture.now.addingTimeInterval(2.4 * 86_400)
    let line = TencentMeetingStatus.line(
      state: state, helperAvailable: true, now: Fixture.now, calendar: Fixture.calendar)
    XCTAssertEqual(line.text, "腾讯会议的连接将在 2 天后过期")
    XCTAssertEqual(line.action, .reconnect)
    state.refreshExtendsLogin = true
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text, "已连接")
    state.lastFailure = .accountNotAvailable
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).action,
      .learnMore)
    state.lastFailure = nil
    state.day = TencentMeetingSync.dayKey(Fixture.now, calendar: .current)
    state.addedToday = 3
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text,
      "已连接 · 今天添加了 3 个会议转写")
    state.recordings["5"] = TencentMeetingRecordingJob(
      meetingID: "6", type: .cloudRecording, title: "示例", start: Fixture.now, end: nil,
      permission: .canApply,
      status: .needsPermission)
    XCTAssertEqual(
      TencentMeetingStatus.permissionLine(state: state, now: Fixture.now), "有 1 个会议需要申请查看")
    // A second recording of the same meeting: still one meeting, one row.
    state.recordings["7"] = TencentMeetingRecordingJob(
      meetingID: "6", type: .textTranscription, title: "示例", start: Fixture.now, end: nil,
      permission: .canApply, status: .needsPermission)
    XCTAssertEqual(
      TencentMeetingStatus.permissionLine(state: state, now: Fixture.now), "有 1 个会议需要申请查看")
    XCTAssertEqual(TencentMeetingStatus.rows(state: state, now: Fixture.now).count, 1)
    XCTAssertEqual(
      TencentMeetingStatus.listTitle(state: state, now: Fixture.now), "有 1 个会议需要申请查看")
    // The key could not be read: say so, and offer to try again.
    state.lastFailure = .keyUnavailable
    let keyLine = TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now)
    XCTAssertEqual(keyLine.text, "无法读取这台 Mac 上的腾讯会议登录信息。")
    XCTAssertEqual(keyLine.action, .retry)
    XCTAssertTrue(keyLine.isProblem)
    // A listing that could not be read.
    state.lastFailure = .unreadable
    XCTAssertEqual(
      TencentMeetingStatus.line(state: state, helperAvailable: true, now: Fixture.now).text,
      TencentMeetingStatus.listingUnreadable)
  }
}
