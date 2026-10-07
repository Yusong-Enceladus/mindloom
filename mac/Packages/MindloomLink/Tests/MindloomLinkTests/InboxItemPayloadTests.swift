import Foundation
import MindloomLink
import XCTest

final class InboxItemPayloadTests: XCTestCase {
  private typealias Failure = InboxItemPayload.ValidationError

  private func json(_ payload: InboxItemPayload) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
  }

  private func decode(_ object: [String: Any]) throws -> InboxItemPayload {
    try InboxItemPayload.decode(JSONSerialization.data(withJSONObject: object))
  }

  private var pngBytes: Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 40))
  }

  private var jpegBytes: Data { Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 1, count: 40)) }

  func testTextPayloadHasTheContractShape() throws {
    let payload = try InboxItemPayload.text(
      "明天下午三点开会", source: .keyboard, createdAt: fixedDate, timeZone: shanghai)
    let object = try json(payload)
    XCTAssertEqual(Set(object.keys), ["v", "kind", "source", "created_at", "text"])
    XCTAssertEqual(object["v"] as? Int, 1)
    XCTAssertEqual(object["kind"] as? String, "text")
    XCTAssertEqual(object["source"] as? String, "iPhone 键盘")
    XCTAssertEqual(object["created_at"] as? String, "2026-09-30T09:15:02.500+08:00")
    XCTAssertEqual(try InboxItemPayload.decode(payload.encoded()), payload)
    // Sorted keys: the encoding is deterministic.
    XCTAssertEqual(
      String(decoding: try payload.encoded(), as: UTF8.self),
      #"{"created_at":"2026-09-30T09:15:02.500+08:00","kind":"text","source":"iPhone 键盘","text":"明天下午三点开会","v":1}"#
    )
  }

  /// WATCH-005: a recording from Apple Watch reaches the Mac as text whose `source` is one every
  /// Mac since v11 knows ("iPhone 口述"), with `origin` "Apple Watch", which a Mac from v12 on
  /// shows as the source.
  func testWatchTextKeepsAKnownSourceAndCarriesItsOrigin() throws {
    let payload = try InboxItemPayload.text(
      "合成：下周一交周报。", source: .voice, origin: .appleWatch, createdAt: fixedDate,
      timeZone: shanghai)
    let object = try json(payload)
    XCTAssertEqual(object["source"] as? String, "iPhone 口述")
    XCTAssertEqual(object["origin"] as? String, "Apple Watch")
    let decoded = try InboxItemPayload.decode(payload.encoded())
    XCTAssertEqual(decoded, payload)
    XCTAssertEqual(decoded.shownSource, "Apple Watch")
    XCTAssertEqual(
      try InboxItemPayload.text("合成", source: .keyboard, createdAt: fixedDate).shownSource,
      "iPhone 键盘")
    XCTAssertEqual(
      InboxItemSource.allCases.map(\.rawValue), ["iPhone 键盘", "iPhone 分享", "iPhone 口述"],
      "a phone only ever sends the names every Mac since v11 knows")
  }

  /// Regression (review of the Apple Watch stream, 10-06): a Mac before v12 decoded `source` as a
  /// closed list, and an entry with a name it did not know failed to decode, was acknowledged as
  /// unusable and so deleted from the organizing device for good. A watch payload must decode with
  /// exactly that older decoder (unknown keys are skipped), under a source it knows.
  func testAMacBeforeV12OpensAnAppleWatchEntry() throws {
    struct V11Payload: Decodable {
      enum Source: String, Decodable {
        case keyboard = "iPhone 键盘"
        case share = "iPhone 分享"
        case voice = "iPhone 口述"
      }
      let v: Int
      let kind: InboxItemKind
      let source: Source
      let createdAt: String
      let text: String?

      enum CodingKeys: String, CodingKey {
        case v, kind, source, text
        case createdAt = "created_at"
      }
    }
    let payload = try InboxItemPayload.text(
      "合成：周五前回邮件。", source: .voice, origin: .appleWatch, createdAt: fixedDate,
      timeZone: shanghai)
    let old = try JSONDecoder().decode(V11Payload.self, from: payload.encoded())
    XCTAssertEqual(old.source, .voice)
    XCTAssertEqual(old.text, "合成：周五前回邮件。")
  }

  /// A Mac from v12 on opens an entry whose source it does not know and shows that name, instead
  /// of deleting it (the Mac path: `IntakeInboxIngestor.open` decodes with `decode`).
  func testAnUnknownSourceIsKeptAsItsName() throws {
    let entry: [String: Any] = [
      "v": 1, "kind": "text", "source": "iPad 口述", "created_at": "2026-09-30T09:15:02+08:00",
      "text": "合成",
    ]
    let decoded = try decode(entry)
    XCTAssertEqual(decoded.source.rawValue, "iPad 口述")
    XCTAssertNil(decoded.origin)
    XCTAssertEqual(decoded.shownSource, "iPad 口述")
    XCTAssertEqual(
      try decode(entry.merging(["origin": "Apple Watch Ultra"]) { $1 }).shownSource,
      "Apple Watch Ultra")
    for bad in ["", "   ", "a\nb", "a\u{0007}", String(repeating: "长", count: 65)] {
      assertThrows(Failure.invalidSource) { try self.decode(entry.merging(["source": bad]) { $1 }) }
      assertThrows(Failure.invalidSource) { try self.decode(entry.merging(["origin": bad]) { $1 }) }
    }
    XCTAssertNoThrow(
      try decode(entry.merging(["source": String(repeating: "长", count: 64)]) { $1 }))
    assertThrows(Failure.malformedJSON) { try self.decode(entry.merging(["source": 7]) { $1 }) }
  }

  func testLinkPayloadKeepsURLAndTitleAndIsNeverFetched() throws {
    let url = URL(string: "https://example.com/a/b?c=1")!
    let payload = try InboxItemPayload.link(
      url, title: "示例", text: "看看这个", source: .share, createdAt: fixedDate, timeZone: shanghai)
    let object = try json(payload)
    XCTAssertEqual(object["url"] as? String, "https://example.com/a/b?c=1")
    XCTAssertEqual(object["title"] as? String, "示例")
    XCTAssertEqual(object["source"] as? String, "iPhone 分享")
    XCTAssertEqual(payload.preview, "示例")
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "", "not a url"] {
      XCTAssertThrowsError(
        try decode([
          "v": 1, "kind": "link", "source": "iPhone 分享", "created_at": "2026-09-30T09:15:02+08:00",
          "url": bad,
        ]), bad)
    }
  }

  func testImagePayloadChecksTypeAndContent() throws {
    let payload = try InboxItemPayload.image(
      pngBytes, mime: "image/png", source: .share, createdAt: fixedDate, timeZone: shanghai)
    XCTAssertEqual(payload.bytes, pngBytes)
    XCTAssertNil(payload.preview, "the phone keeps no preview of an image")
    XCTAssertEqual(try InboxItemPayload.decode(payload.encoded()), payload)

    assertThrows(Failure.unsupportedImageType) {
      try InboxItemPayload.image(self.jpegBytes, mime: "image/png", source: .share)
    }
    assertThrows(Failure.unsupportedImageType) {
      try InboxItemPayload.image(self.pngBytes, mime: "image/gif", source: .share)
    }
    assertThrows(Failure.audioOrVideoRefused) {
      try InboxItemPayload.image(self.pngBytes, mime: "video/mp4", source: .share)
    }
    let mp4 = Data([0, 0, 0, 0x18] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 20))
    assertThrows(Failure.audioOrVideoRefused) {
      try InboxItemPayload.image(mp4, mime: "image/heic", source: .share)
    }
    let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [UInt8](repeating: 0, count: 20))
    XCTAssertNoThrow(try InboxItemPayload.image(heic, mime: "image/heic", source: .share))
    assertThrows(Failure.imageTooLarge) {
      try InboxItemPayload.image(
        self.jpegBytes + Data(count: InboxLimits.maximumImageBytes), mime: "image/jpeg",
        source: .share)
    }
  }

  func testFilePayloadRefusesAudioAndVideo() throws {
    let pdf = Data("%PDF-1.7 synthetic".utf8)
    let payload = try InboxItemPayload.file(
      pdf, filename: "合成.pdf", mime: "application/pdf", source: .share,
      createdAt: fixedDate, timeZone: shanghai)
    XCTAssertEqual(payload.preview, "合成.pdf")
    XCTAssertEqual(try InboxItemPayload.decode(payload.encoded()).bytes, pdf)

    // By MIME type.
    for mime in ["audio/mp4", "video/quicktime", "audio/x-m4a", "application/ogg"] {
      assertThrows(Failure.audioOrVideoRefused) {
        try InboxItemPayload.file(pdf, filename: "a.bin", mime: mime, source: .share)
      }
    }
    // By file name.
    for name in ["录音.m4a", "clip.MOV", "voice.opus", "a.mp3", "b.wav", "c.webm"] {
      assertThrows(Failure.audioOrVideoRefused) {
        try InboxItemPayload.file(pdf, filename: name, source: .share)
      }
    }
    // By content, whatever the name and type claim.
    let disguised: [Data] = [
      Data([0, 0, 0, 0x20] + Array("ftypM4A ".utf8) + [UInt8](repeating: 0, count: 20)),
      Data([0, 0, 0, 0x14] + Array("ftypqt  ".utf8) + [UInt8](repeating: 0, count: 20)),
      Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8)),
      Data(Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0]),
      Data(Array("OggS".utf8) + [0, 2, 0, 0]),
      Data([0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42]),
      Data(Array("caff".utf8) + [0, 1, 0, 0]),
      Data([0xFF, 0xFB, 0x90, 0x64, 0x00]),  // MP3 frame
      Data([0xFF, 0xF1, 0x50, 0x80, 0x00]),  // AAC ADTS
    ]
    for bytes in disguised {
      assertThrows(Failure.audioOrVideoRefused) {
        try InboxItemPayload.file(bytes, filename: "notes.txt", mime: "text/plain", source: .share)
      }
    }
    // Things that merely look similar stay accepted.
    let utf16 = Data([0xFF, 0xFE] + Array("h\0i\0".utf8))
    XCTAssertNoThrow(
      try InboxItemPayload.file(utf16, filename: "u.txt", mime: "text/plain", source: .share))
    let heif = Data([0, 0, 0, 0x18] + Array("ftypavif".utf8) + [UInt8](repeating: 0, count: 20))
    XCTAssertNoThrow(
      try InboxItemPayload.file(heif, filename: "p.avif", mime: "image/avif", source: .share))

    assertThrows(Failure.fileTooLarge) {
      try InboxItemPayload.file(
        Data(count: InboxLimits.maximumFileBytes + 1), filename: "big.bin", source: .share)
    }
  }

  func testFilenames() {
    for bad in [
      "", ".", "..", "a/b", "a\\b", "a:b", "a\u{0}b", "line\nbreak",
      String(repeating: "长", count: 86),
    ] {
      assertThrows(Failure.invalidFilename) { try InboxItemPayload.validateFilename(bad) }
    }
    XCTAssertNoThrow(try InboxItemPayload.validateFilename("周报 v2 (final).docx"))
    XCTAssertEqual(InboxItemPayload.sanitizedFilename("../../etc/passwd"), ".._.._etc_passwd")
    XCTAssertEqual(InboxItemPayload.sanitizedFilename("  \n"), "文件")
    XCTAssertEqual(InboxItemPayload.sanitizedFilename(".."), "文件")
    let long = InboxItemPayload.sanitizedFilename(String(repeating: "长", count: 200) + ".pdf")
    XCTAssertLessThanOrEqual(long.utf8.count, InboxLimits.maximumFilenameBytes)
    XCTAssertTrue(long.hasSuffix(".pdf"))
    XCTAssertNoThrow(try InboxItemPayload.validateFilename(long))
  }

  func testTextRules() throws {
    assertThrows(Failure.emptyText) { try InboxItemPayload.text(" \n\t", source: .keyboard) }
    let limit = InboxLimits.maximumTextCharacters
    XCTAssertNoThrow(
      try InboxItemPayload.text(String(repeating: "字", count: limit), source: .share))
    assertThrows(Failure.textTooLong) {
      try InboxItemPayload.text(String(repeating: "a", count: limit + 1), source: .share)
    }
  }

  func testDecodeIsStrict() throws {
    let base: [String: Any] = [
      "v": 1, "kind": "text", "source": "iPhone 键盘", "created_at": "2026-09-30T09:15:02+08:00",
      "text": "hi",
    ]
    XCTAssertNoThrow(try decode(base))
    XCTAssertNoThrow(try decode(base.merging(["created_at": "2026-09-30T01:15:02.123Z"]) { $1 }))

    var wrongVersion = base
    wrongVersion["v"] = 2
    assertThrows(Failure.unsupportedVersion(2)) { try self.decode(wrongVersion) }
    for bad in ["2026-09-30 09:15:02", "2026-09-30T09:15:02", "yesterday", ""] {
      assertThrows(Failure.invalidCreatedAt) {
        try self.decode(base.merging(["created_at": bad]) { $1 })
      }
    }
    assertThrows(Failure.unexpectedField("bytes_b64")) {
      try self.decode(base.merging(["bytes_b64": "AAAA"]) { $1 })
    }
    assertThrows(Failure.unexpectedField("url")) {
      try self.decode(base.merging(["url": "https://example.com"]) { $1 })
    }
    // An unknown source is a name (see `testAnUnknownSourceIsKeptAsItsName`); an unknown kind
    // still is not.
    XCTAssertEqual(
      try decode(base.merging(["source": "Android"]) { $1 }).source.rawValue, "Android")
    assertThrows(Failure.malformedJSON) {
      try self.decode(base.merging(["kind": "audio"]) { $1 })
    }
    assertThrows(Failure.malformedJSON) { try InboxItemPayload.decode(Data("not json".utf8)) }

    var image = base
    image["kind"] = "image"
    image["text"] = nil
    image["mime"] = "image/png"
    image["bytes_b64"] = "iVBORw0KGgo=\n"
    assertThrows(Failure.invalidBytes) { try self.decode(image) }
    image["bytes_b64"] = nil
    assertThrows(Failure.missingBytes) { try self.decode(image) }
  }

  func testTimestampsCarryTheLocalOffset() {
    XCTAssertEqual(
      InboxTimestamp.string(from: fixedDate, timeZone: shanghai), "2026-09-30T09:15:02.500+08:00")
    XCTAssertEqual(
      InboxTimestamp.string(from: fixedDate, timeZone: TimeZone(identifier: "UTC")!),
      "2026-09-30T01:15:02.500+00:00")
    XCTAssertEqual(
      InboxTimestamp.string(
        from: fixedDate, timeZone: TimeZone(identifier: "America/Los_Angeles")!),
      "2026-09-29T18:15:02.500-07:00")
    XCTAssertEqual(
      InboxTimestamp.string(from: fixedDate, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
      "2026-09-30T06:45:02.500+05:30")
    XCTAssertEqual(
      InboxTimestamp.string(
        from: Date(timeIntervalSince1970: 1_790_730_902.345), timeZone: shanghai),
      "2026-09-30T09:15:02.345+08:00", "rounds to the nearest millisecond")
    let parsed = InboxTimestamp.date(from: "2026-09-30T09:15:02.500+08:00")
    XCTAssertEqual(parsed?.timeIntervalSince1970, fixedDate.timeIntervalSince1970)
    XCTAssertEqual(
      InboxTimestamp.date(from: "2026-09-30T01:15:02Z")?.timeIntervalSince1970, 1_790_730_902)
    XCTAssertNil(InboxTimestamp.date(from: "2026-09-30T09:15:02"))
  }

  func testPreviewIsShortAndSingleLine() throws {
    let long = String(repeating: "很长的一段话。\n", count: 40)
    let payload = try InboxItemPayload.text(long, source: .keyboard)
    let preview = try XCTUnwrap(payload.preview)
    XCTAssertEqual(preview.count, InboxItemPayload.previewCharacters + 1)
    XCTAssertTrue(preview.hasSuffix("…"))
    XCTAssertFalse(preview.contains("\n"))
    XCTAssertEqual(try InboxItemPayload.text("短句", source: .keyboard).preview, "短句")
  }
}
