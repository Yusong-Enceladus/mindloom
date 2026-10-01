import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import CryptoKit
import Foundation
import XCTest

/// Image items: bytes are read at send time from the checked asset root,
/// verified, and sent only as `image_b64`. Synthetic files only.
@MainActor
final class RemoteOrganizerItemAssetTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)
  /// A JPEG signature followed by synthetic bytes; the reader checks the
  /// signature, size, and digest, not the pixels.
  private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("synthetic-image".utf8)

  private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func write(_ data: Data, root: URL, relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  private func asset(_ relative: String, data: Data) -> RemoteOrganizerImageAsset {
    RemoteOrganizerImageAsset(
      assetID: UUID().uuidString, relativePath: relative, sha256: sha(data),
      sizeBytes: Int64(data.count), mediaType: "image/jpeg")
  }

  func testReaderVerifiesPathLinksSizeAndDigest() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-assets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let relative = "sessions/abc/source/normalized.jpg"
    try write(jpeg, root: assets, relative: relative)
    let reader = RemoteOrganizerItemAssetReader(assetRoot: assets)
    XCTAssertEqual(try reader.imageData(for: asset(relative, data: jpeg)), jpeg)

    let tampered = RemoteOrganizerImageAsset(
      assetID: "x", relativePath: relative, sha256: String(repeating: "0", count: 64),
      sizeBytes: Int64(jpeg.count), mediaType: "image/jpeg")
    XCTAssertThrowsError(try reader.imageData(for: tampered)) {
      XCTAssertEqual($0 as? RemoteOrganizerItemAssetReader.ReadError, .digestMismatch)
    }
    for bad in ["../outside.jpg", "/etc/hosts", "sessions/../x.jpg", "other/a.jpg"] {
      XCTAssertThrowsError(try reader.imageData(for: asset(bad, data: jpeg)), bad)
    }
    // A link inside the root, to a file or a directory, is refused.
    let outside = root.appendingPathComponent("outside.jpg")
    try jpeg.write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: assets.appendingPathComponent("sessions/abc/source/link.jpg"),
      withDestinationURL: outside)
    XCTAssertThrowsError(
      try reader.imageData(for: asset("sessions/abc/source/link.jpg", data: jpeg)))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("elsewhere/source"), withIntermediateDirectories: true)
    try jpeg.write(to: root.appendingPathComponent("elsewhere/source/normalized.jpg"))
    try FileManager.default.createSymbolicLink(
      at: assets.appendingPathComponent("sessions/linked"),
      withDestinationURL: root.appendingPathComponent("elsewhere"))
    XCTAssertThrowsError(
      try reader.imageData(for: asset("sessions/linked/source/normalized.jpg", data: jpeg)))

    let text = Data("not an image".utf8)
    try write(text, root: assets, relative: "sessions/abc/source/text.jpg")
    XCTAssertThrowsError(
      try reader.imageData(for: asset("sessions/abc/source/text.jpg", data: text))
    ) { XCTAssertEqual($0 as? RemoteOrganizerItemAssetReader.ReadError, .notAnImage) }
    XCTAssertThrowsError(
      try RemoteOrganizerItemAssetReader(assetRoot: assets, maximumBytes: 4)
        .imageData(for: asset(relative, data: jpeg))
    ) { XCTAssertEqual($0 as? RemoteOrganizerItemAssetReader.ReadError, .tooLarge) }
  }

  private func imageDraft(
    _ id: SessionID, digest: String, size: Int, capturedAt: Date
  ) throws -> UserItemDraft {
    let base = "sessions/\(id.rawValue.uuidString.lowercased())/source/"
    return UserItemDraft(
      id: id, kind: .image, capturedAt: capturedAt,
      source: ItemSourceApplication(bundleID: "dev.synthetic.chat", name: "虚构聊天"),
      sourceOrigin: .previousFrontmost, text: "", extractor: "imageio-normalize-v1",
      originalFilename: "SENTINEL-ORIGINAL-NAME.png",
      attachments: [
        UserItemAttachment(
          role: .original, relativePath: base + "original.png",
          originalFilename: "SENTINEL-ORIGINAL-NAME.png", mediaType: "image/png",
          digest: try SHA256Digest(String(repeating: "a", count: 64)), sizeBytes: 99),
        UserItemAttachment(
          role: .normalizedImage, relativePath: base + "normalized.jpg",
          originalFilename: "normalized.jpg", mediaType: "image/jpeg",
          digest: try SHA256Digest(digest), sizeBytes: UInt64(size)),
      ])
  }

  func testImageItemIsSentAsVerifiedBytesAndAMissingFileIsParked() async throws {
    let library = try SyntheticOrganizerLibrary()
    let assets = library.root.appendingPathComponent("assets", isDirectory: true)
    try await library.store.enableRemoteLink(at: enabledAt)
    let present = SessionID()
    try write(
      jpeg, root: assets,
      relative: "sessions/\(present.rawValue.uuidString.lowercased())/source/normalized.jpg")
    try await library.store.createUserItem(
      imageDraft(
        present, digest: sha(jpeg), size: jpeg.count,
        capturedAt: Date(timeIntervalSince1970: 1_000)))
    let missing = SessionID()
    try await library.store.createUserItem(
      imageDraft(
        missing, digest: sha(jpeg), size: jpeg.count,
        capturedAt: Date(timeIntervalSince1970: 2_000)))
    let text = SessionID()
    try await library.store.createUserItem(
      UserItemDraft(
        id: text, kind: .text, capturedAt: Date(timeIntervalSince1970: 3_000),
        source: ItemSourceApplication(bundleID: nil, name: "Claude"), sourceOrigin: .user,
        text: "虚构的回复：先确认场地", extractor: "pasteboard-text-v1"))

    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: launcher, http: spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assets),
      imageRedactor: IdentityRedactor(), timing: fastTiming
    ) { _, _ in }
    runtime.start()
    try await waitUntil { spark.items.count == 2 }
    runtime.stop()

    let image = try XCTUnwrap(spark.items.first)
    XCTAssertEqual(image["item_id"] as? String, present.rawValue.uuidString)
    XCTAssertEqual(image["kind"] as? String, "image")
    XCTAssertEqual(
      (image["image_b64"] as? String).flatMap { Data(base64Encoded: $0) }, jpeg)
    XCTAssertEqual(image["sha256"] as? String, sha(jpeg))
    XCTAssertEqual(
      Set(image.keys),
      ["item_id", "revision", "kind", "source_app", "started_at", "image_b64", "sha256"])
    let reply = try XCTUnwrap(spark.items.last)
    XCTAssertEqual(reply["kind"] as? String, "text")
    XCTAssertEqual((reply["source_app"] as? [String: Any])?["name"] as? String, "Claude")

    let bodies = spark.requests.compactMap { $0.body }.compactMap {
      String(data: $0, encoding: .utf8)
    }
    for body in bodies {
      for sentinel in [
        "SENTINEL-ORIGINAL-NAME", "local_image_asset", "original.png", "normalized.jpg",
        "sessions/",
      ] {
        XCTAssertFalse(body.contains(sentinel), sentinel)
      }
    }
    let parked = try await library.scalar(
      "SELECT state || '/' || error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
      [missing.rawValue.uuidString])
    XCTAssertEqual(parked, "failed/asset")
    await library.close()
  }

  /// v6 integration: on-device recognition refusing a request (two readings
  /// at once) must not park a phone photo for good. A failure that may pass
  /// is tried again with backoff; any other failure still parks the item.
  func testATransientRedactionFailureIsRetriedAndAPermanentOneParks() async throws {
    final class FlakyRedactor: RemoteOrganizerImageRedacting, @unchecked Sendable {
      struct Refused: RemoteOrganizerAssetErrorClassifying { let isTransient: Bool }
      private let lock = NSLock()
      private var failuresLeft: Int
      private let transient: Bool
      private(set) var calls = 0
      init(failures: Int, transient: Bool) {
        failuresLeft = failures
        self.transient = transient
      }
      func redactedSendCopy(of data: Data, mediaType: String) throws -> Data {
        try lock.withLock {
          calls += 1
          guard failuresLeft > 0 else { return data }
          failuresLeft -= 1
          throw Refused(isTransient: transient)
        }
      }
    }
    // The Vision redactor's own classification.
    XCTAssertTrue(VisionSendCopyRedactor.RedactionError.recognitionFailed.isTransient)
    XCTAssertFalse(VisionSendCopyRedactor.RedactionError.unreadableImage.isTransient)
    XCTAssertFalse(VisionSendCopyRedactor.RedactionError.encodingFailed.isTransient)
    for transient in [true, false] {
      let library = try SyntheticOrganizerLibrary()
      let assets = library.root.appendingPathComponent("assets", isDirectory: true)
      try await library.store.enableRemoteLink(at: enabledAt)
      let id = SessionID()
      try write(
        jpeg, root: assets,
        relative: "sessions/\(id.rawValue.uuidString.lowercased())/source/normalized.jpg")
      try await library.store.createUserItem(
        imageDraft(
          id, digest: sha(jpeg), size: jpeg.count, capturedAt: Date(timeIntervalSince1970: 1_000)))
      let spark = FakeSpark()
      let redactor = FlakyRedactor(failures: 1, transient: transient)
      let runtime = RemoteOrganizerRuntime(
        repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
        keys: testOrganizerKeys,
        itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assets),
        imageRedactor: redactor, timing: fastTiming
      ) { _, _ in }
      runtime.start()
      if transient {
        // The first retry comes after the shortest backoff (3 s).
        try await waitUntil(timeout: 12) { spark.items.count == 1 }
        runtime.stop()
        XCTAssertEqual(redactor.calls, 2)
        let state = try await library.scalar(
          "SELECT state FROM remote_organizer_item_jobs WHERE item_id = ?",
          [id.rawValue.uuidString])
        XCTAssertEqual(state, "delivered")
      } else {
        try await waitUntil {
          try await library.scalar(
            "SELECT state || '/' || error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
            [id.rawValue.uuidString]) == "failed/asset"
        }
        try await Task.sleep(for: .milliseconds(200))
        runtime.stop()
        XCTAssertEqual(redactor.calls, 1, "a permanent failure is not tried again")
        XCTAssertTrue(spark.items.isEmpty)
      }
      await library.close()
    }
  }

  private func fileDraft(
    _ id: SessionID, bytes: Data, filename: String, mime: String, uti: String?,
    localText: String, capturedAt: Date, sizeBytes: UInt64? = nil
  ) throws -> UserItemDraft {
    let ext = (filename as NSString).pathExtension
    return UserItemDraft(
      id: id, kind: .file, capturedAt: capturedAt,
      source: ItemSourceApplication(bundleID: "com.apple.finder", name: "访达"),
      sourceOrigin: .finder, text: localText,
      extractor: localText.isEmpty ? UserItemLimits.fileBytesExtractor : "declared-text-v1",
      originalFilename: filename,
      attachments: [
        UserItemAttachment(
          role: .original,
          relativePath: "sessions/\(id.rawValue.uuidString.lowercased())/source/original.\(ext)",
          originalFilename: filename, mediaType: mime, digest: try SHA256Digest(sha(bytes)),
          sizeBytes: sizeBytes ?? UInt64(bytes.count))
      ],
      uniformType: uti)
  }

  /// Files contract: a file item carries its bytes (verified like an image),
  /// name, type, size and the text read on the Mac; a file above 25 MiB goes
  /// as its text with the file facts, or stays on the Mac without text; a
  /// keyframe names its recording and position; a GIF sends its extra frames.
  func testFileKeyframeAndAnimationItemsCrossTheLinkAsTheContractSays() async throws {
    let library = try SyntheticOrganizerLibrary()
    let assets = library.root.appendingPathComponent("assets", isDirectory: true)
    try await library.store.enableRemoteLink(at: enabledAt)
    let sheetBytes = Data([0x50, 0x4B, 0x03, 0x04]) + Data("synthetic-xlsx".utf8)
    let sheet = SessionID()
    try write(
      sheetBytes, root: assets,
      relative: "sessions/\(sheet.rawValue.uuidString.lowercased())/source/original.xlsx")
    try await library.store.createUserItem(
      fileDraft(
        sheet, bytes: sheetBytes, filename: "虚构账单.xlsx",
        mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        uti: "org.openxmlformats.spreadsheetml.sheet", localText: "",
        capturedAt: Date(timeIntervalSince1970: 1_000)))
    let csvBytes = Data("日期,金额\n9-01,120\n".utf8)
    let csv = SessionID()
    try write(
      csvBytes, root: assets,
      relative: "sessions/\(csv.rawValue.uuidString.lowercased())/source/original.csv")
    try await library.store.createUserItem(
      fileDraft(
        csv, bytes: csvBytes, filename: "账单.csv", mime: "text/csv",
        uti: "public.comma-separated-values-text", localText: "日期,金额\n9-01,120\n",
        capturedAt: Date(timeIntervalSince1970: 1_100)))
    // Recorded as 30 MiB: over the send limit (the reader is never asked).
    let big = SessionID()
    try await library.store.createUserItem(
      fileDraft(
        big, bytes: Data("x".utf8), filename: "大文件.docx", mime: "application/msword",
        uti: "org.openxmlformats.wordprocessingml.document", localText: "虚构的长报告正文",
        capturedAt: Date(timeIntervalSince1970: 1_200), sizeBytes: 30 * 1_024 * 1_024))
    let bigSilent = SessionID()
    try await library.store.createUserItem(
      fileDraft(
        bigSilent, bytes: Data("y".utf8), filename: "大.zip", mime: "application/zip",
        uti: "public.zip-archive", localText: "", capturedAt: Date(timeIntervalSince1970: 1_300),
        sizeBytes: 30 * 1_024 * 1_024))
    // A keyframe of a recording, and a GIF with two extra frames.
    let recording = SessionID()
    let frame = SessionID()
    let frameBase = "sessions/\(frame.rawValue.uuidString.lowercased())/source/"
    try write(jpeg, root: assets, relative: frameBase + "normalized.jpg")
    try await library.store.createUserItem(
      UserItemDraft(
        id: frame, kind: .image, capturedAt: Date(timeIntervalSince1970: 1_400),
        source: nil, sourceOrigin: .unknown, text: "",
        extractor: UserItemLimits.videoKeyframeExtractor,
        originalFilename: "录像.mov · 0:12",
        attachments: [
          UserItemAttachment(
            role: .original, relativePath: frameBase + "original.jpg",
            originalFilename: "keyframe-12000.jpg", mediaType: "image/jpeg",
            digest: try SHA256Digest(sha(jpeg)), sizeBytes: UInt64(jpeg.count)),
          UserItemAttachment(
            role: .normalizedImage, relativePath: frameBase + "normalized.jpg",
            originalFilename: "normalized.jpg", mediaType: "image/jpeg",
            digest: try SHA256Digest(sha(jpeg)), sizeBytes: UInt64(jpeg.count)),
        ], parentSessionID: recording, frameMilliseconds: 12_000))
    let gif = SessionID()
    let gifBase = "sessions/\(gif.rawValue.uuidString.lowercased())/source/"
    let second = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("frame-2".utf8)
    let third = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("frame-3".utf8)
    try write(jpeg, root: assets, relative: gifBase + "normalized.jpg")
    try write(second, root: assets, relative: gifBase + "animationFrame1.jpg")
    try write(third, root: assets, relative: gifBase + "animationFrame2.jpg")
    func attachment(_ role: UserItemAttachmentRole, _ name: String, _ data: Data) throws
      -> UserItemAttachment
    {
      UserItemAttachment(
        role: role, relativePath: gifBase + name, originalFilename: name,
        mediaType: role == .original ? "image/gif" : "image/jpeg",
        digest: try SHA256Digest(sha(data)), sizeBytes: UInt64(data.count))
    }
    try await library.store.createUserItem(
      UserItemDraft(
        id: gif, kind: .image, capturedAt: Date(timeIntervalSince1970: 1_500), source: nil,
        sourceOrigin: .finder, text: "", extractor: "imageio-normalize-v1",
        originalFilename: "动图.gif",
        attachments: [
          try attachment(.original, "original.gif", jpeg),
          try attachment(.normalizedImage, "normalized.jpg", jpeg),
          try attachment(.animationFrame1, "animationFrame1.jpg", second),
          try attachment(.animationFrame2, "animationFrame2.jpg", third),
        ]))

    let spark = FakeSpark()
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assets),
      imageRedactor: IdentityRedactor(), fileSanitizer: IdentitySanitizer(), timing: fastTiming
    ) { _, _ in }
    runtime.start()
    try await waitUntil { spark.items.count == 5 }
    runtime.stop()
    func sent(_ id: SessionID) throws -> [String: Any] {
      try XCTUnwrap(spark.items.first { $0["item_id"] as? String == id.rawValue.uuidString })
    }

    let xlsx = try sent(sheet)
    XCTAssertEqual(xlsx["kind"] as? String, "file")
    XCTAssertEqual(xlsx["filename"] as? String, "虚构账单.xlsx")
    XCTAssertEqual(xlsx["uti"] as? String, "org.openxmlformats.spreadsheetml.sheet")
    XCTAssertEqual(
      xlsx["mime"] as? String, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    XCTAssertEqual(xlsx["size"] as? Int, sheetBytes.count)
    XCTAssertEqual(xlsx["sha256"] as? String, sha(sheetBytes))
    XCTAssertEqual((xlsx["bytes_b64"] as? String).flatMap { Data(base64Encoded: $0) }, sheetBytes)
    XCTAssertNotNil(xlsx["captured_at"] as? String)
    XCTAssertEqual(xlsx["captured_at"] as? String, xlsx["started_at"] as? String)
    XCTAssertNil(xlsx["local_text"])
    XCTAssertNil(xlsx["text"])
    XCTAssertEqual(
      Set(xlsx.keys),
      [
        "item_id", "revision", "kind", "source_app", "started_at", "sha256", "filename", "uti",
        "mime", "size", "bytes_b64", "captured_at",
      ])

    let table = try sent(csv)
    XCTAssertEqual(table["kind"] as? String, "file")
    XCTAssertEqual(table["local_text"] as? String, "日期,金额\n9-01,120\n")
    XCTAssertEqual((table["bytes_b64"] as? String).flatMap { Data(base64Encoded: $0) }, csvBytes)

    let large = try sent(big)
    XCTAssertEqual(large["kind"] as? String, "text")
    XCTAssertEqual(large["text"] as? String, "虚构的长报告正文")
    XCTAssertEqual(large["filename"] as? String, "大文件.docx")
    XCTAssertEqual(large["size"] as? Int, 30 * 1_024 * 1_024)
    XCTAssertNil(large["bytes_b64"])
    // Privacy review F16: it carries the digest of the text that is sent,
    // never of the file's bytes (which would let the organizing device
    // recognize the file).
    XCTAssertEqual(large["sha256"] as? String, sha(Data("虚构的长报告正文".utf8)))

    let keyframe = try sent(frame)
    XCTAssertEqual(keyframe["kind"] as? String, "image")
    XCTAssertEqual(keyframe["parent_item_id"] as? String, recording.rawValue.uuidString)
    XCTAssertEqual(keyframe["frame_ms"] as? Int, 12_000)
    XCTAssertEqual((keyframe["image_b64"] as? String).flatMap { Data(base64Encoded: $0) }, jpeg)

    let animation = try sent(gif)
    XCTAssertEqual((animation["image_b64"] as? String).flatMap { Data(base64Encoded: $0) }, jpeg)
    XCTAssertEqual(
      (animation["extra_images_b64"] as? [String])?.compactMap { Data(base64Encoded: $0) },
      [second, third])

    // Over 25 MiB with no text read here: never sent, parked as unsendable.
    XCTAssertFalse(
      spark.items.contains { $0["item_id"] as? String == bigSilent.rawValue.uuidString })
    let parked = try await library.scalar(
      "SELECT state || '/' || error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
      [bigSilent.rawValue.uuidString])
    XCTAssertEqual(parked, "failed/unsendable")

    for body in spark.requests.compactMap({ $0.body }).compactMap({
      String(data: $0, encoding: .utf8)
    }) {
      for sentinel in [
        "local_file_asset", "local_extra_image_assets", "local_image_asset", "sessions/",
      ] {
        XCTAssertFalse(body.contains(sentinel), sentinel)
      }
    }
    await library.close()
  }

  func testFileReaderVerifiesAnyTypeUpToTheFileLimit() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-files-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let bytes = Data("synthetic,csv\n".utf8)
    let relative = "sessions/abc/source/original.csv"
    try write(bytes, root: assets, relative: relative)
    let reader = RemoteOrganizerItemAssetReader(assetRoot: assets)
    XCTAssertEqual(try reader.fileData(for: asset(relative, data: bytes)), bytes)
    XCTAssertThrowsError(try reader.imageData(for: asset(relative, data: bytes)))
    XCTAssertThrowsError(
      try RemoteOrganizerItemAssetReader(assetRoot: assets, maximumFileBytes: 4)
        .fileData(for: asset(relative, data: bytes))
    ) { XCTAssertEqual($0 as? RemoteOrganizerItemAssetReader.ReadError, .tooLarge) }
    XCTAssertThrowsError(try reader.fileData(for: asset("../x.csv", data: bytes)))
  }

  /// A file reading's type, fields, counts, inner files and error are read
  /// leniently and kept with the reading; an error alone is a reading.
  func testFileReadingFactsAreDecodedLeniently() throws {
    let json = """
      {"cursor": 3, "events": [], "questions": [], "persons": [],
       "readings": {
         "A0000000-0000-4000-8000-000000000001": {
           "revision": 0, "type": "email", "text": "正文", "summary": "虚构报价邮件",
           "fields": {"subject": "报价", "from": "a@example.invalid", "date": 20260901,
                      "to": ["b@example.invalid", "c@example.invalid"]},
           "counts": {"attachments": 2, "images_read": "1", "bad": -1},
           "attachments": [{"filename": "报价.xlsx", "type": "spreadsheet", "summary": "3 行"},
                           {"name": "图.png"}, {"type": "image"}, 7],
           "source": "file-read"},
         "A0000000-0000-4000-8000-000000000002": {"revision": 0, "error": "encrypted",
           "type": "pdf"},
         "A0000000-0000-4000-8000-000000000003": {"revision": 0, "type": "nonsense",
           "text": "x", "error": "exploded", "fields": "not an object"}
       }}
      """
    let state = try JSONDecoder().decode(RemoteOrganizerState.self, from: Data(json.utf8))
    let readings = Dictionary(
      uniqueKeysWithValues: (state.readings ?? []).map { ($0.itemID.suffix(1), $0) })
    let email = try XCTUnwrap(readings["1"]?.facts)
    XCTAssertEqual(email.type, "email")
    XCTAssertEqual(email.fields.map(\.name), ["from", "to", "subject", "date"])
    XCTAssertEqual(email.fields[1].value, "b@example.invalid, c@example.invalid")
    XCTAssertEqual(email.counts, ["attachments": 2, "images_read": 1])
    XCTAssertEqual(email.attachments.map(\.filename), ["报价.xlsx", "图.png"])
    XCTAssertEqual(email.source, "file-read")
    XCTAssertEqual(readings["1"]?.summary, "虚构报价邮件")
    let locked = try XCTUnwrap(readings["2"])
    XCTAssertEqual(locked.text, "")
    XCTAssertEqual(locked.facts?.error, "encrypted")
    // Unknown values are dropped, the reading kept.
    XCTAssertEqual(readings["3"]?.text, "x")
    XCTAssertNil(readings["3"]?.facts)
  }

  /// Privacy review F6: deleting a recording deletes the keyframe items
  /// taken from it too, on this Mac and, through a queued deletion each, on
  /// the organizing device.
  func testDeletingARecordingDeletesItsKeyframesHereAndThere() async throws {
    let library = try SyntheticOrganizerLibrary()
    let assets = library.root.appendingPathComponent("assets", isDirectory: true)
    try await library.store.enableRemoteLink(at: enabledAt)
    let recording = UUID()
    try await library.seedCompletedSession(recording, createdAt: 1_000, text: "会议录音的虚构逐字稿")
    let frame = SessionID()
    let frameBase = "sessions/\(frame.rawValue.uuidString.lowercased())/source/"
    try write(jpeg, root: assets, relative: frameBase + "normalized.jpg")
    try write(jpeg, root: assets, relative: frameBase + "original.jpg")
    try await library.store.createUserItem(
      UserItemDraft(
        id: frame, kind: .image, capturedAt: Date(timeIntervalSince1970: 1_400),
        source: nil, sourceOrigin: .unknown, text: "",
        extractor: UserItemLimits.videoKeyframeExtractor,
        originalFilename: "录像.mov · 0:12",
        attachments: [
          UserItemAttachment(
            role: .original, relativePath: frameBase + "original.jpg",
            originalFilename: "keyframe-12000.jpg", mediaType: "image/jpeg",
            digest: try SHA256Digest(sha(jpeg)), sizeBytes: UInt64(jpeg.count)),
          UserItemAttachment(
            role: .normalizedImage, relativePath: frameBase + "normalized.jpg",
            originalFilename: "normalized.jpg", mediaType: "image/jpeg",
            digest: try SHA256Digest(sha(jpeg)), sizeBytes: UInt64(jpeg.count)),
        ], parentSessionID: SessionID(recording), frameMilliseconds: 12_000))
    let spark = FakeSpark()
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assets),
      imageRedactor: IdentityRedactor(), timing: fastTiming
    ) { _, _ in }
    runtime.start()
    try await waitUntil { spark.items.count == 2 }
    try await waitUntil {
      try await library.scalar(
        "SELECT CAST(COUNT(*) AS TEXT) FROM remote_organizer_item_jobs WHERE delivered_revision IS NOT NULL",
        []) == "2"
    }
    runtime.stop()
    let frames = try await library.store.keyframeSessionIDs(of: [SessionID(recording)])
    XCTAssertEqual(frames, [frame])

    try await library.store.deleteSessionRecordsExplicitly(sessionID: SessionID(recording))
    let pending = try await library.store.pendingRemoteDeletions()
    XCTAssertEqual(Set(pending), [recording.uuidString, frame.rawValue.uuidString])
    let left = try await library.scalar(
      "SELECT CAST(COUNT(*) AS TEXT) FROM sessions WHERE id IN (?, ?)",
      [recording.uuidString, frame.rawValue.uuidString])
    XCTAssertEqual(left, "0")
    await library.close()
  }
}
