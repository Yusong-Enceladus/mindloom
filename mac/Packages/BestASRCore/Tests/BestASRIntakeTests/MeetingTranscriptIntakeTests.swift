import AppKit
import BestASRDomain
import UniformTypeIdentifiers
import BestASRMemory
import BestASRPersistence
import XCTest

@testable import BestASRIntake

/// 文件 › 收进会议记录… (v12 1C, ALIGNMENT 收2-5): the menu was always grey
/// in v11; a `.srt` (no system type) was kept as an unread file. Synthetic
/// transcripts only, made in the test.
final class MeetingTranscriptIntakeTests: XCTestCase {
  private var root: URL!
  private var processor: IntakeProcessor!
  private let at = Date(timeIntervalSince1970: 5_000)

  private let tencent = """
    周会

    林知夏(00:00:05):
    这周先把三组数据跑完。

    高原(00:01:10):
    好，我周五给结果。
    """
  private let srt = """
    1
    00:00:05,000 --> 00:00:09,000
    林知夏: 这周先把三组数据跑完。

    2
    00:01:10,000 --> 00:01:14,000
    高原: 好，我周五给结果。
    """
  private let vtt = """
    WEBVTT

    00:00:05.000 --> 00:00:09.000
    <v 林知夏>这周先把三组数据跑完。

    00:01:10.000 --> 00:01:14.000
    <v 高原>好，我周五给结果。
    """

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-transcripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
      pathPolicy: .none)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func write(_ data: Data, _ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func docx(_ text: String, _ name: String) throws -> URL {
    let source = NSAttributedString(string: text)
    let data = try source.data(
      from: NSRange(location: 0, length: source.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    return try write(data, name)
  }

  /// Subtitles are text: an `.srt` (even in GB 18030) and a `.vtt` become
  /// documents with their words, read into turns.
  func testSubtitlesAreTakenInAsText() throws {
    let gb = CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    for (name, data) in [
      ("周会.srt", Data(srt.utf8)),
      ("周会-gb.srt", try XCTUnwrap(srt.data(using: String.Encoding(rawValue: gb)))),
      ("周会.vtt", Data(vtt.utf8)),
    ] {
      let url = try write(data, name)
      XCTAssertEqual(IntakeFileClass.classify(url), .plainText, name)
      let outcome = processor.prepare(.file(url), capturedAt: at, source: nil, origin: .unknown)
      guard case .item(let draft) = outcome else { return XCTFail("\(name): \(outcome)") }
      XCTAssertEqual(draft.kind, .document, name)
      XCTAssertTrue(draft.text.contains("这周先把三组数据跑完"), name)
      XCTAssertEqual(
        MemoryTranscriptText.parse(draft.text)?.turns.map(\.speaker), ["林知夏", "高原"], name)
    }
  }

  /// Tencent Meeting's web page downloads its transcript as `.md`
  /// (TENCENT-V2.md §5): no title block, one `Name(HH:MM:SS):` line per turn
  /// with ASCII brackets and colon, the words on the next line, a blank line
  /// between turns, now and then `**bold**`, a bracketed note or a line
  /// ending in a full-width colon inside the words. Synthetic, in that shape.
  private let tencentWebMarkdown = """
    林知夏(00:00:05):
    这周先把**三组数据**跑完。

    高原(00:01:10):
    好，我周五给结果。

    Lin Zhixia(00:02:03):
    结论如下：

    高原(00:02:40):
    [图片]

    """

  /// Regression (TENCENT-V2.md §5): the menu did not offer `.md`, the only
  /// format the owner's Tencent Meeting downloads came in. It is offered,
  /// read on this Mac, and its speakers and times are the parser's.
  func testTencentMeetingsMarkdownDownloadIsATranscript() throws {
    XCTAssertTrue(IntakeFileClass.meetingTranscriptExtensions.contains("md"))
    for ext in IntakeFileClass.meetingTranscriptExtensions {
      XCTAssertNotNil(UTType(filenameExtension: ext), "the open panel offers .\(ext)")
    }
    let url = try write(Data(tencentWebMarkdown.utf8), "周会转写.md")
    XCTAssertEqual(IntakeFileClass.classify(url), .plainText)
    let text = try XCTUnwrap(IntakeTextExtractor.meetingTranscriptText(fileURL: url))
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.format, .tencent)
    XCTAssertEqual(transcript.format.meetingApp, "腾讯会议")
    XCTAssertEqual(transcript.turns.map(\.speaker), ["林知夏", "高原", "Lin Zhixia", "高原"])
    XCTAssertEqual(
      transcript.turns.map(\.time), ["00:00:05", "00:01:10", "00:02:03", "00:02:40"])
    XCTAssertEqual(transcript.turns.map(\.text), ["这周先把**三组数据**跑完。", "好，我周五给结果。", "结论如下：", "[图片]"])
    // Taken in like a drop, named after its App.
    let outcome = processor.prepare(
      .file(url), capturedAt: at, source: ItemSourceApplication(bundleID: nil, name: "腾讯会议"),
      origin: .user)
    guard case .item(let draft) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(draft.kind, .document)
    XCTAssertEqual(MemoryTranscriptText.parse(draft.text)?.turns.count, 4)
  }

  /// The menu's kinds are read on this Mac; anything else is not a
  /// transcript.
  func testTheMenusFourKindsAreRead() throws {
    XCTAssertEqual(
      IntakeFileClass.meetingTranscriptExtensions, ["txt", "md", "docx", "srt", "vtt"])
    let files = [
      (try write(Data(tencent.utf8), "周会.txt"), MemoryTranscriptText.Format.tencent),
      (try write(Data(tencentWebMarkdown.utf8), "周会.md"), .tencent),
      (try docx(tencent, "周会.docx"), .tencent),
      (try write(Data(srt.utf8), "周会.srt"), .subtitles),
      (try write(Data(vtt.utf8), "周会.vtt"), .subtitles),
    ]
    for (url, format) in files {
      let text = try XCTUnwrap(
        IntakeTextExtractor.meetingTranscriptText(fileURL: url), url.lastPathComponent)
      XCTAssertEqual(MemoryTranscriptText.parse(text)?.format, format, url.lastPathComponent)
    }
    XCTAssertNil(
      IntakeTextExtractor.meetingTranscriptText(fileURL: try write(Data([0, 1, 2]), "x.bin")))
    let plain = try write(Data("只是一段文字。".utf8), "便条.txt")
    XCTAssertNil(
      MemoryTranscriptText.parse(IntakeTextExtractor.meetingTranscriptText(fileURL: plain) ?? ""))
  }

  /// Taken in with its App's name (as the App does after reading the
  /// format), it reads as 「会议记录 · 腾讯会议」 from the library; a docx too.
  func testATranscriptTakenInReadsAsAMeetingRecord() async throws {
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("h.sqlite"))
    var ids: [SessionID] = []
    for url in [try write(Data(tencent.utf8), "周会.txt"), try docx(tencent, "周会.docx")] {
      let app = MemoryTranscriptText.parse(
        IntakeTextExtractor.meetingTranscriptText(fileURL: url) ?? "")?.format.meetingApp
      XCTAssertEqual(app, "腾讯会议")
      let outcome = processor.prepare(
        .file(url), capturedAt: at, source: ItemSourceApplication(bundleID: nil, name: app),
        origin: .user)
      guard case .item(let draft) = outcome else { return XCTFail("\(outcome)") }
      try await store.createUserItem(draft)
      processor.assetStore.commit(sessionID: draft.id)
      ids.append(draft.id)
    }
    let records = try await store.memoryItemRecords(ids: ids)
    XCTAssertEqual(records.count, 2)
    for record in records {
      XCTAssertEqual(
        MemoryItemSource.words(record).line, "会议记录 · 腾讯会议", "\(String(describing: record.itemKind))"
      )
      XCTAssertEqual(MemoryTranscriptText.parse(record.text ?? "")?.turns.count, 2)
    }
    try await store.checkpointAndClose()
  }
}
