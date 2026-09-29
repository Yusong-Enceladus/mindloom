import BestASRMemory
import Foundation
import XCTest

/// Meeting-App transcript exports read as turns. Every name and sentence is
/// invented for the test.
final class MemoryTranscriptTextTests: XCTestCase {
  private func scalars(_ text: String, _ turn: MemoryTranscriptText.Turn) -> String {
    MemoryTranscriptText.slice(text, start: turn.start, end: turn.end)
  }

  func testTencentMeetingExport() throws {
    let text = """
      虚构周会纪要
      2026年9月21日

      苗青禾 Miao QINGHE(00:00:03):
      大家好，今天先过一下灯具样品。

      欧阳帆(00:01:15):
      样品周三到，我去仓库取。
      顺便把色温表带上。

      苗青禾 Miao QINGHE（00:02:40）：
      好，那周四上午定型号。
      """
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.format, .tencent)
    XCTAssertEqual(
      transcript.turns.map(\.speaker), ["苗青禾 Miao QINGHE", "欧阳帆", "苗青禾 Miao QINGHE"])
    XCTAssertEqual(transcript.turns.map(\.time), ["00:00:03", "00:01:15", "00:02:40"])
    XCTAssertEqual(transcript.turns[1].text, "样品周三到，我去仓库取。\n顺便把色温表带上。")
    // Offsets run from the header line to the end of the last spoken line.
    XCTAssertEqual(
      scalars(text, transcript.turns[1]), "欧阳帆(00:01:15):\n样品周三到，我去仓库取。\n顺便把色温表带上。")
    XCTAssertTrue(scalars(text, transcript.turns[0]).hasPrefix("苗青禾 Miao QINGHE(00:00:03):"))
    XCTAssertTrue(scalars(text, transcript.turns[2]).hasSuffix("好，那周四上午定型号。"))
  }

  func testFeishuExport() throws {
    let text = """
      说话人 1 00:00:02
      先对一下展位的尺寸。

      石磊 00:00:40
      三米乘三米，靠近入口。

      说话人 1 00:01:05
      那海报做两张就够了。
      """
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.format, .feishu)
    XCTAssertEqual(transcript.turns.map(\.speaker), ["说话人 1", "石磊", "说话人 1"])
    XCTAssertEqual(transcript.turns.last?.text, "那海报做两张就够了。")
  }

  func testZoomTranscript() throws {
    let text =
      "[00:00:05] Dana Ruiz: Can we move the review to Friday?\n"
      + "[00:00:09] 韩小溪: 可以，周五下午。\n还要带上预算表。\n"
      + "[00:00:20] Dana Ruiz: Great, thanks."
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.format, .zoom)
    XCTAssertEqual(transcript.turns.map(\.speaker), ["Dana Ruiz", "韩小溪", "Dana Ruiz"])
    XCTAssertEqual(transcript.turns[1].text, "可以，周五下午。\n还要带上预算表。")
  }

  func testWebVTTAndSRT() throws {
    let vtt = """
      WEBVTT

      00:00:01.000 --> 00:00:03.500
      <v 顾一鸣>下周的样机什么时候到？

      00:00:04.000 --> 00:00:06.000
      <v 林青>周二，我来签收。
      """
    let parsedVTT = try XCTUnwrap(MemoryTranscriptText.parse(vtt))
    XCTAssertEqual(parsedVTT.format, .subtitles)
    XCTAssertEqual(parsedVTT.turns.map(\.speaker), ["顾一鸣", "林青"])
    XCTAssertEqual(parsedVTT.turns.map(\.time), ["00:00:01", "00:00:04"])
    let srt = """
      1
      00:00:01,000 --> 00:00:02,000
      顾一鸣: 先说场地。

      2
      00:00:02,500 --> 00:00:04,000
      顾一鸣: 再说人员。

      3
      00:00:04,500 --> 00:00:06,000
      林青: 好的。
      """
    let parsedSRT = try XCTUnwrap(MemoryTranscriptText.parse(srt))
    // Consecutive cues of one speaker are one turn; the cue number belongs to it.
    XCTAssertEqual(parsedSRT.turns.map(\.speaker), ["顾一鸣", "林青"])
    XCTAssertEqual(parsedSRT.turns[0].text, "先说场地。\n再说人员。")
    XCTAssertTrue(scalars(srt, parsedSRT.turns[0]).hasPrefix("1\n00:00:01,000"))
  }

  func testOrdinaryNotesAndChatsAreNotTranscripts() {
    // A note with two timed lines is not a Feishu export.
    XCTAssertNil(MemoryTranscriptText.parse("会议开始 10:00\n先讨论预算\n结束 11:30\n散会"))
    XCTAssertNil(MemoryTranscriptText.parse("明天 9:30 到公司"))
    // One header is not a conversation.
    XCTAssertNil(MemoryTranscriptText.parse("苗青禾(00:00:03):\n只有一段。"))
    // A pasted chat has no header lines of these shapes.
    XCTAssertNil(MemoryTranscriptText.parse("王姐：房租涨 200\n我：能商量吗？"))
    // A sentence with a time in brackets is not a speaker.
    XCTAssertNil(
      MemoryTranscriptText.parse("记得带上报告，明天(09:00):\n好的\n另外，后天(10:00):\n行"))
  }

  /// The organizer's own case file (a copy of
  /// `spark/tests/fixtures/transcript_formats.json`): the same turns, times
  /// and offsets as its parser, or no transcript where it finds none.
  func testSharedCasesMatchTheOrganizer() throws {
    struct Case: Decodable {
      struct Expected: Decodable {
        let speaker: String
        let t: String
        let text: String
        let start: Int
        let end: Int
      }
      let name: String
      let format: String?
      let text: String
      let turns: [Expected]
    }
    struct File: Decodable { let cases: [Case] }
    let url = repositoryRoot.appendingPathComponent(
      "Tests/Fixtures/RemoteOrganizer/transcript_formats.json")
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    XCTAssertGreaterThanOrEqual(file.cases.count, 10)
    for item in file.cases {
      let parsed = MemoryTranscriptText.parse(item.text)
      guard let format = item.format else {
        XCTAssertNil(parsed, item.name)
        continue
      }
      let transcript = try XCTUnwrap(parsed, item.name)
      let expectedFormat: MemoryTranscriptText.Format =
        format == "vtt" || format == "srt"
        ? .subtitles : try XCTUnwrap(MemoryTranscriptText.Format(rawValue: format), item.name)
      XCTAssertEqual(transcript.format, expectedFormat, item.name)
      XCTAssertEqual(transcript.turns.map(\.speaker), item.turns.map(\.speaker), item.name)
      XCTAssertEqual(transcript.turns.map(\.time), item.turns.map(\.t), item.name)
      XCTAssertEqual(transcript.turns.map(\.text), item.turns.map(\.text), item.name)
      XCTAssertEqual(transcript.turns.map(\.start), item.turns.map(\.start), item.name)
      XCTAssertEqual(transcript.turns.map(\.end), item.turns.map(\.end), item.name)
    }
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md").path)
      {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root")
  }

  /// Offsets are Unicode scalars, as the organizing device counts characters:
  /// a CRLF export and emoji keep the same positions as in Python.
  func testOffsetsCountUnicodeScalarsAcrossCRLF() throws {
    let text = "甲(00:00:01):\r\n你好 👋🏽\r\n\r\n乙(00:00:02):\r\n收到\r\n"
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.turns.map(\.speaker), ["甲", "乙"])
    let first = transcript.turns[0]
    XCTAssertEqual(first.start, 0)
    // "甲(00:00:01):" 12 + "\r\n" 2 + "你好 👋🏽" 5 scalars = 19.
    XCTAssertEqual(first.end, 19)
    XCTAssertEqual(transcript.turns[1].start, 23)
    XCTAssertEqual(MemoryTranscriptText.slice(text, start: 23, end: 35), "乙(00:00:02):")
    XCTAssertEqual(MemoryTranscriptText.slice(text, start: -5, end: 1), "甲")
    XCTAssertEqual(MemoryTranscriptText.slice(text, start: 30, end: 10), "")
    XCTAssertEqual(MemoryTranscriptText.slice(text, start: 1_000, end: 2_000), "")
  }
}
