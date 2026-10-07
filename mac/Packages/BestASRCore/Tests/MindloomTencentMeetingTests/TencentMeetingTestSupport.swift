import BestASRDomain
import Foundation
import XCTest

@testable import MindloomTencentMeeting

enum Fixture {
  static func data(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
  }

  static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

  static func ok(_ name: String) -> TencentMeetingRunResult {
    TencentMeetingRunResult(exitStatus: 0, stdout: data(name), stderr: Data())
  }

  static func error(_ name: String) -> TencentMeetingRunResult {
    TencentMeetingRunResult(exitStatus: 1, stdout: Data(), stderr: data(name))
  }

  static func dataObject(_ name: String) -> [String: Any] {
    let object = try! JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    return object["data"] as! [String: Any]
  }

  /// 2026-10-05 12:00 in China (after every fixture meeting).
  static let now = ISO8601DateFormatter().date(from: "2026-10-05T04:00:00Z")!

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }
}

/// Answers tmeet commands from canned results; records every command.
actor FakeTmeet: TencentMeetingRunning {
  typealias Answer = @Sendable (TencentMeetingCommand) -> TencentMeetingRunResult?

  private var answer: Answer
  private(set) var commands: [TencentMeetingCommand] = []

  init(_ answer: @escaping Answer) { self.answer = answer }

  func set(_ answer: @escaping Answer) { self.answer = answer }

  func run(_ command: TencentMeetingCommand, timeout: Duration) async -> TencentMeetingRunResult {
    commands.append(command)
    return answer(command)
      ?? TencentMeetingRunResult(
        exitStatus: 1, stdout: Data(), stderr: Data("Error: unexpected".utf8))
  }

  nonisolated func login(
    onLine: @escaping @Sendable (String) -> Void, cancellation: TencentMeetingCancellation
  ) async -> TencentMeetingRunResult {
    .notLaunched(.helper)
  }

  func transcriptCalls() -> [String] {
    commands.compactMap {
      if case .transcriptGet(let id, _, let pid, _) = $0 { return id + "@" + (pid ?? "-") }
      return nil
    }
  }

  func meetingGets() -> [String] {
    commands.compactMap {
      if case .meetingGet(let id) = $0 { return id }
      return nil
    }
  }

  func reset() { commands = [] }

  /// The fixture account: two listing pages, list-ended, the two meetings
  /// list-ended lists only part of in full, and the transcripts of the
  /// viewable recordings (the second page of 12 starts at the last
  /// paragraph of the first, as Tencent's `--pid` does).
  static let standard: Answer = { command in
    switch command {
    case .authStatus: return Fixture.ok("auth-status.txt")
    case .recordList(_, _, nil): return Fixture.ok("record-list-p1.json")
    case .recordList(_, _, "page-two_token="?): return Fixture.ok("record-list-p2.json")
    case .meetingListEnded: return Fixture.ok("list-ended.json")
    case .meetingGet("8000000000000000002"): return Fixture.ok("meeting-get-2.json")
    case .meetingGet("8000000000000000005"): return Fixture.ok("meeting-get-5.json")
    case .transcriptGet("6000000000000000012", _, nil, _):
      return Fixture.ok("transcript-12-p1.json")
    case .transcriptGet("6000000000000000012", _, "2"?, _):
      return Fixture.ok("transcript-12-p2.json")
    case .transcriptGet("6000000000000000021", _, nil, _): return Fixture.ok("transcript-21.json")
    case .transcriptGet("6000000000000000041", _, nil, _): return Fixture.ok("transcript-41.json")
    case .transcriptGet("6000000000000000011", _, nil, _): return Fixture.ok("transcript-11.json")
    default: return nil
    }
  }
}

/// A library in memory: what was added, and what the owner deleted.
actor MemoryWriter: TencentMeetingItemWriting {
  private(set) var items: [SessionID: TencentMeetingItem] = [:]
  private(set) var order: [SessionID] = []

  func existing(_ ids: [SessionID]) async -> Set<SessionID> {
    Set(ids.filter { items[$0] != nil })
  }

  func add(_ item: TencentMeetingItem) async throws {
    guard items[item.id] == nil else { throw TencentMeetingWriteError.alreadyThere }
    items[item.id] = item
    order.append(item.id)
  }

  func delete(_ id: SessionID) { items[id] = nil }

  var added: [TencentMeetingItem] { order.compactMap { items[$0] } }
}

final class StateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TencentMeetingState?
  private(set) var saves = 0

  func set(_ state: TencentMeetingState) {
    lock.withLock {
      value = state
      saves += 1
    }
  }

  var state: TencentMeetingState? { lock.withLock { value } }
}

func makeSync(
  _ tmeet: FakeTmeet, writer: MemoryWriter, state: TencentMeetingState? = nil,
  box: StateBox = StateBox(), budget: Int = 150, reserve: Int = 50
) -> TencentMeetingSync {
  var initial = state ?? TencentMeetingState()
  if state == nil {
    initial.connectedAt = Fixture.now
    initial.backfill = .add
  }
  var configuration = TencentMeetingSync.Configuration(tmeetVersion: "test")
  configuration.dailyBudget = budget
  configuration.transcriptReserve = reserve
  return TencentMeetingSync(
    state: initial, runner: tmeet, writer: writer, configuration: configuration,
    calendar: Fixture.calendar, save: { box.set($0) })
}

extension TencentMeetingRunResult {
  static func json(_ text: String) -> TencentMeetingRunResult {
    TencentMeetingRunResult(exitStatus: 0, stdout: Data(text.utf8), stderr: Data())
  }
}

/// Synthetic tmeet output built in a test.
enum Synthetic {
  /// A `record list` page: one meeting per entry, hosted by `host`.
  static func recordList(
    _ meetings: [(meeting: String, file: String, day: Int, host: String, type: String)]
  ) -> TencentMeetingRunResult {
    let entries = meetings.map { m in
      """
      {"host_user_id":"\(m.host)","media_start_time":"2026-10-0\(m.day)T09:00:00+08:00",\
      "meeting_code":"9\(m.meeting.suffix(8))","meeting_id":"\(m.meeting)",\
      "record_files":[{"record_end_time":"2026-10-0\(m.day)T09:30:00+08:00",\
      "record_file_id":"\(m.file)","record_start_time":"2026-10-0\(m.day)T09:00:00+08:00",\
      "record_size":1000}],"record_type":"\(m.type)","state":"转码完成，可根据录制文件权限进行下一步",\
      "state_int":3,"subject":"示例会议 \(m.file.suffix(2))"}
      """
    }
    return .json(
      #"{"trace_id":"t","message":"success","data":{"has_more":false,"record_meetings":["#
        + entries.joined(separator: ",") + "]}}")
  }

  static let noMeetings = TencentMeetingRunResult.json(
    #"{"trace_id":"t","message":"success","data":{"has_more":false,"meeting_info_list":[]}}"#)

  /// A one-page transcript: one paragraph per speaker, in order.
  static func transcript(_ speakers: [(id: String, name: String)], first pid: Int = 0)
    -> TencentMeetingRunResult
  {
    paragraphs(speakers.enumerated().map { (pid + $0.offset, $0.element.id, $0.element.name) })
  }

  /// A transcript page with these paragraphs (number, speaker number, name).
  static func paragraphs(_ list: [(pid: Int, id: String, name: String)], more: Bool = false)
    -> TencentMeetingRunResult
  {
    let paragraphs = list.map { p in
      """
      {"end_time":"00:\(String(format: "%02d", p.pid % 60))","pid":"\(p.pid)",\
      "sentences":[{"words":[{"text":"第\(p.pid)句。"}]}],\
      "speaker":{"user_id":"\(p.id)","user_name":"\(p.name)"},"start_time":"00:\(String(format: "%02d", p.pid % 60))"}
      """
    }
    return .json(
      #"{"trace_id":"t","message":"success","data":{"code":0,"minutes":{"paragraphs":["#
        + paragraphs.joined(separator: ",") + "]},\"more\":\(more)}}")
  }
}
