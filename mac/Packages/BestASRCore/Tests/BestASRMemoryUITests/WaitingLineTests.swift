import BestASRDomain
import BestASRMemory
import XCTest

@testable import BestASRMemoryUI

/// v12 integration live walk: 「刚收进来」 lists 收进会议记录 items while the
/// DGX Spark is not organizing; their first line is words, not the file's
/// marks (「WEBVTT」, a cue number, 「林知夏(00:00:03):」).
final class WaitingLineTests: XCTestCase {
  func testAWaitingTranscriptShowsItsTitleOrFirstWords() {
    XCTAssertEqual(
      MemoryWaitingCapture.firstLine(of: "WEBVTT\n\n00:00:05.000 --> 00:00:09.000\n<v 林知夏>复盘先说柚子那次的延误。\n\n00:00:10.000 --> 00:00:14.000\n<v 宋雨桐>下次提前一周确认。"),
      "林知夏：复盘先说柚子那次的延误。")
    XCTAssertEqual(
      MemoryWaitingCapture.firstLine(of: "1\n00:00:05,000 --> 00:00:09,000\n林知夏: 柚子的访谈先约在周四下午。\n\n2\n00:00:10,000 --> 00:00:14,000\n高原: 好。"),
      "林知夏：柚子的访谈先约在周四下午。")
    XCTAssertEqual(
      MemoryWaitingCapture.firstLine(of: "Twin-7 周会（合成样例）\n\n林知夏(00:00:05):\n这周先把三组数据跑完。\n\n高原(00:01:10):\n好。"),
      "Twin-7 周会（合成样例）")
    XCTAssertEqual(MemoryWaitingCapture.firstLine(of: "\n  柚子报价单记得打印两份。\n"), "柚子报价单记得打印两份。")
    XCTAssertNil(MemoryWaitingCapture.firstLine(of: "  \n"))
  }

  /// The record-based builder (the organizer's unfiled list) reads the same.
  func testTheRecordBuilderReadsTheSame() {
    let record = MemoryItemRecord(
      sessionID: SessionID(), inputMode: .userItem, itemKind: .document, title: "t",
      startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
      sourceBundleID: nil, sourceDisplayName: nil, sourceIdentifier: "访谈.srt",
      text: "1\n00:00:05,000 --> 00:00:09,000\n林知夏: 柚子的访谈先约在周四下午。\n\n2\n00:00:10,000 --> 00:00:14,000\n高原: 好。")
    XCTAssertEqual(MemoryWaitingCapture(record: record).firstLine, "林知夏：柚子的访谈先约在周四下午。")
  }
}
