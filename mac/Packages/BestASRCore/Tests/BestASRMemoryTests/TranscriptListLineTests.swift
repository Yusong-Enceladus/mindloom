import BestASRDomain
import XCTest

@testable import BestASRMemory

/// v12 integration live walk: 收进会议记录 items now show in 「刚收进来」 and in
/// 历史 (find's lists take every record), and their first line read
/// 「WEBVTT」, 「1」 or 「林知夏(00:00:03):」 — the file's marks, not words.
final class TranscriptListLineTests: XCTestCase {
  static let srt = """
    1
    00:00:05,000 --> 00:00:09,000
    林知夏: 柚子的访谈先约在周四下午。

    2
    00:00:10,000 --> 00:00:14,000
    高原: 好，我把问题清单发过去。
    """
  static let vtt = """
    WEBVTT

    00:00:05.000 --> 00:00:09.000
    <v 林知夏>复盘先说柚子那次的延误。

    00:00:10.000 --> 00:00:14.000
    <v 宋雨桐>下次提前一周确认。
    """
  static let tencent = """
    林知夏(00:00:03):
    这周先把三组数据跑完，
    柚子那边的报价周四之前确认。

    高原(00:01:10):
    好，我周五给结果。
    """

  func testATranscriptReadsAsNamesAndWords() {
    XCTAssertEqual(
      MemoryTranscriptText.readable(Self.srt),
      "林知夏：柚子的访谈先约在周四下午。\n高原：好，我把问题清单发过去。")
    XCTAssertEqual(
      MemoryTranscriptText.readable(Self.vtt),
      "林知夏：复盘先说柚子那次的延误。\n宋雨桐：下次提前一周确认。")
    XCTAssertEqual(
      MemoryTranscriptText.readable(Self.tencent),
      "林知夏：这周先把三组数据跑完， 柚子那边的报价周四之前确认。\n高原：好，我周五给结果。")
    // A title block before the first turn stays, first.
    XCTAssertEqual(
      MemoryTranscriptText.readable("Twin-7 周会（合成样例）\n\n" + Self.tencent)?
        .split(separator: "\n").first,
      "Twin-7 周会（合成样例）")
    XCTAssertNil(MemoryTranscriptText.readable("周五前把海报初稿发给虚构甲"))
  }

  func testAHistoryRowShowsTheWordsNotTheFileMarks() {
    let record = MemoryItemRecord(
      sessionID: SessionID(), inputMode: .userItem, itemKind: .document, title: "t",
      startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
      sourceBundleID: nil, sourceDisplayName: nil, sourceIdentifier: "复盘.vtt", text: Self.vtt)
    let plain = MemoryHistoryBuilder.row(record, query: nil, matter: nil)
    XCTAssertTrue(plain.line.hasPrefix("林知夏：复盘先说柚子"), plain.line)
    XCTAssertFalse(plain.line.contains("WEBVTT"))
    let query = SearchQueryParser.parse("延误", context: SearchContext())
    let hit = MemoryHistoryBuilder.row(record, query: query, matter: nil)
    XCTAssertFalse(hit.line.contains("<v "), hit.line)
    XCTAssertTrue(hit.line.contains("延误"), hit.line)
    // What is copied or opened in place is the record's own text.
    XCTAssertEqual(hit.fullText, Self.vtt)
  }
}
