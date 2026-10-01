import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import Compression
import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Privacy contract v6 on the intake side: screenshot send copies are
/// redacted on this Mac, zips are expanded in process under limits, audio,
/// video, archives and unreadable binaries stay here, and identical bytes
/// are stored once. Synthetic files only.
final class IntakePrivacyTests: XCTestCase {
  private var root: URL!
  private let at = Date(timeIntervalSince1970: 1_000)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-intake-privacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }

  private func processor() -> IntakeProcessor {
    IntakeProcessor(assetStore: IntakeAssetStore(assetRoot: assets), pathPolicy: .none)
  }

  // MARK: - Screenshot redaction

  /// White lines of black text, large enough for Vision to read reliably.
  private func textImage(_ lines: [String], png: Bool = true, pitch: Int = 140) throws -> Data {
    let width = 1_800
    let height = pitch * lines.count + 60
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
    for (index, text) in lines.enumerated() {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
      context.textPosition = CGPoint(x: 40, y: height - 120 - index * pitch)
      CTLineDraw(line, context)
    }
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  func testScreenshotSendCopyCoversThePhoneNumberAndKeepsTheRestReadable() throws {
    let original = try textImage([
      "Call 13812345678 about Friday", "Budget review at the office",
    ])
    let reader = VisionImageTextReader()
    let before = try XCTUnwrap(reader.readText(imageData: original))
    XCTAssertTrue(
      before.contains("13812345678"), "Vision must read the synthetic number: \(before)")

    let redactor = VisionSendCopyRedactor()
    let sent = try redactor.redactedSendCopy(of: original, mediaType: "image/png")
    XCTAssertNotEqual(sent, original)
    XCTAssertTrue(sent.starts(with: [0x89, 0x50, 0x4E, 0x47]), "still a PNG")
    let after = reader.readText(imageData: sent) ?? ""
    let digits = after.filter(\.isNumber)
    XCTAssertFalse(after.contains("13812345678"), after)
    XCTAssertFalse(digits.contains("1381234"), after)
    XCTAssertTrue(after.contains("Budget review"), after)
    XCTAssertTrue(after.contains("Friday"), "only the number is covered: \(after)")
    // Same pixel size, no metadata.
    let source = try XCTUnwrap(CGImageSourceCreateWithData(sent as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1_800)
    // Nothing but what ImageIO derives from the pixels: no place, no device.
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
    XCTAssertNil(tiff[kCGImagePropertyTIFFModel])

    // A JPEG stays a JPEG; a screenshot with nothing to cover is sent as is.
    let jpeg = try textImage(["Email zhang.san@example.com today"], png: false)
    let sentJPEG = try redactor.redactedSendCopy(of: jpeg, mediaType: "image/jpeg")
    XCTAssertTrue(sentJPEG.starts(with: [0xFF, 0xD8]))
    XCTAssertFalse((reader.readText(imageData: sentJPEG) ?? "").contains("example.com"))
    let plain = try textImage(["Lunch at noon"])
    XCTAssertEqual(try redactor.redactedSendCopy(of: plain, mediaType: "image/png"), plain)
    XCTAssertThrowsError(
      try redactor.redactedSendCopy(of: Data("not an image".utf8), mediaType: "image/png"))
  }

  /// Regression (privacy E2E, 2026-09-30): a chat bubble wrapped a card
  /// number and an API key onto the next line; no single recognized line
  /// held the whole value, so both were sent unredacted.
  func testScreenshotSendCopyCoversNumbersWrappedOntoTheNextLine() throws {
    let original = try textImage(
      [
        "Refund to card 6222 0212", "3456 7894 by Friday", "key sk-proj-",
        "Ab3dEf6hIj9kLm2nOp5q", "",
        "Budget review at the office",
      ], pitch: 84)
    let reader = VisionImageTextReader()
    let before = try XCTUnwrap(reader.readText(imageData: original))
    let compactBefore = before.filter { !$0.isWhitespace }
    XCTAssertTrue(compactBefore.contains("62220212"), before)
    XCTAssertTrue(compactBefore.contains("34567894"), before)
    XCTAssertTrue(before.lowercased().contains("sk-proj-"), before)

    let redactor = VisionSendCopyRedactor()
    let sent = try redactor.redactedSendCopy(of: original, mediaType: "image/png")
    let after = reader.readText(imageData: sent) ?? ""
    let compact = after.filter { !$0.isWhitespace }.lowercased()
    for fragment in ["6222", "0212", "3456", "7894", "sk-proj", "ab3def", "lm2nop5q"] {
      XCTAssertFalse(compact.contains(fragment), "\(fragment) still readable: \(after)")
    }
    XCTAssertTrue(after.contains("review at the office"), after)
    XCTAssertTrue(after.contains("Friday"), "only the values are covered: \(after)")
    XCTAssertTrue(after.contains("Refund"), after)
  }

  /// v6 integration: a reading and a send copy made at the same moment (a
  /// phone photo taken in while another is redacted) both succeed; Vision
  /// runs them one at a time and falls back to the GPU or CPU if the default
  /// device fails.
  func testReadingsAndSendCopiesAtTheSameTimeAllSucceed() async throws {
    let image = try textImage(["虚构的会议记录 MLCONCURRENT", "电话 138 1234 5678"])
    let results = await withTaskGroup(of: Bool.self) { group in
      for lane in 0..<6 {
        group.addTask {
          if lane.isMultiple(of: 2) {
            return VisionImageTextReader().readText(imageData: image)?.contains("MLCONCURRENT")
              == true
          }
          return (try? VisionSendCopyRedactor().redactedSendCopy(of: image, mediaType: "image/png"))
            != nil
        }
      }
      var all: [Bool] = []
      for await result in group { all.append(result) }
      return all
    }
    XCTAssertEqual(results, Array(repeating: true, count: 6))
  }

  func testASecretPrefixReadWithTheWrongCaseIsStillFound() {
    XCTAssertEqual(
      VisionSendCopyRedactor.canonicalSecretPrefixes("key Sk-proj-Ab3dEf6hIj9kLm2nOp5q and GHP_x"),
      "key sk-proj-Ab3dEf6hIj9kLm2nOp5q and ghp_x")
    XCTAssertEqual(VisionSendCopyRedactor.canonicalSecretPrefixes("电话 138"), "电话 138")
  }

  func testOnlyLinesStackedDirectlyUnderOneAnotherAreReadJoined() {
    // Normalized boxes, origin at the bottom left: two wrapped lines, a line
    // far below them, and a column to the right at the same height.
    let blocks = VisionSendCopyRedactor.stackedBlocks([
      CGRect(x: 0.10, y: 0.80, width: 0.50, height: 0.04),
      CGRect(x: 0.10, y: 0.75, width: 0.30, height: 0.04),
      CGRect(x: 0.10, y: 0.40, width: 0.50, height: 0.04),
      CGRect(x: 0.70, y: 0.75, width: 0.20, height: 0.04),
    ])
    XCTAssertEqual(Set(blocks.map { $0 }), Set([[0, 1], [2], [3]]))
  }

  // MARK: - Zip

  private static func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var crc = UInt32(index)
      for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
      table[index] = crc
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }

  private static func rawDeflate(_ data: Data) -> Data {
    let input = [UInt8](data)
    var output = [UInt8](repeating: 0, count: max(64, input.count + 1_024))
    let written = output.withUnsafeMutableBufferPointer { destination in
      input.withUnsafeBufferPointer { source in
        compression_encode_buffer(
          destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil,
          COMPRESSION_ZLIB)
      }
    }
    return Data(output.prefix(written))
  }

  struct ZipEntry {
    var name: String
    var data: Data
    var deflate = true
    var declaredSize: Int? = nil
    var crc: UInt32? = nil
    var encrypted = false
  }

  /// A minimal zip writer: stored or raw-DEFLATE entries, UTF-8 names.
  static func makeZip(_ entries: [ZipEntry]) -> Data {
    func u16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var body = Data()
    var central = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      let payload = entry.deflate ? rawDeflate(entry.data) : entry.data
      let crc = entry.crc ?? crc32(entry.data)
      let size = UInt32(entry.declaredSize ?? entry.data.count)
      let flags = 0x0800 | (entry.encrypted ? 1 : 0)
      let method = entry.deflate ? 8 : 0
      let offset = UInt32(body.count)
      body += u32(0x0403_4B50) + u16(20) + u16(flags) + u16(method) + u16(0) + u16(0)
      body += u32(crc) + u32(UInt32(payload.count)) + u32(size) + u16(name.count) + u16(0)
      body += name + payload
      central += u32(0x0201_4B50) + u16(20) + u16(20) + u16(flags) + u16(method) + u16(0)
      central += u16(0) + u32(crc) + u32(UInt32(payload.count)) + u32(size) + u16(name.count)
      central += u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + name
    }
    let end =
      u32(0x0605_4B50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count)
      + u32(UInt32(central.count)) + u32(UInt32(body.count)) + u16(0)
    return body + central + end
  }

  private let m4a = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(repeating: 3, count: 200)

  private func label(_ outcome: IntakeOutcome) -> String {
    switch outcome {
    case .item(let draft):
      "\(draft.originalFilename ?? "-") [\(draft.kind.rawValue)\(draft.isLocalOnly ? ", local" : "")]"
    case .media(let url): "media \(url.lastPathComponent)"
    case .rejected(let message): "rejected \(message)"
    }
  }

  func testAZipIsExpandedHereItsAudioStaysAndOnlyReadableMembersCanBeSent() async throws {
    let deeper = Self.makeZip([ZipEntry(name: "x.txt", data: Data("最深处".utf8))])
    let inner = Self.makeZip([
      ZipEntry(name: "deep.txt", data: Data("第二层的虚构说明".utf8)),
      ZipEntry(name: "deeper.zip", data: deeper, deflate: false),
    ])
    let bundle = Self.makeZip([
      ZipEntry(name: "notes/readme.txt", data: Data("虚构说明：请回电 13812345678".utf8)),
      ZipEntry(name: "audio/voice.m4a", data: m4a),
      ZipEntry(name: "photo.png", data: try syntheticPNG(width: 40, height: 30), deflate: false),
      ZipEntry(name: "inner.zip", data: inner, deflate: false),
      ZipEntry(name: "blob.bin", data: Data((0..<64).map { UInt8($0) })),
      ZipEntry(name: "secret.txt", data: Data("x".utf8), encrypted: true),
    ])
    let url = root.appendingPathComponent("bundle.zip")
    try bundle.write(to: url)
    let processor = processor()
    let outcomes = processor.prepareAll(.file(url), capturedAt: at, source: nil, origin: .finder)
    XCTAssertEqual(
      outcomes.map(label),
      [
        "bundle.zip [file, local]",
        "bundle.zip › notes/readme.txt [document]",
        "bundle.zip › audio/voice.m4a [file, local]",
        "bundle.zip › photo.png [image]",
        "bundle.zip › inner.zip [file, local]",
        "bundle.zip › inner.zip › deep.txt [document]",
        "bundle.zip › inner.zip › deeper.zip [file, local]",
        "bundle.zip › blob.bin [file, local]",
        "rejected bundle.zip › secret.txt：加密或无法读取，只保存在压缩包里",
      ])

    // Through the real store with the link on: only the readable members
    // ever get a payload; the zip, its audio and its binary never do.
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("h.sqlite"))
    try await store.enableRemoteLink(at: Date(timeIntervalSince1970: 1))
    var sendable = Set<String>()
    for case .item(let draft) in outcomes {
      try await store.createUserItem(draft)
      processor.assetStore.commit(sessionID: draft.id)
      if !draft.isLocalOnly { sendable.insert(draft.id.rawValue.uuidString) }
    }
    _ = try await store.reconcileRemoteItems()
    var claimed = Set<String>()
    while let delivery = try await store.claimNextRemoteItem(now: Date()) {
      claimed.insert(delivery.itemID.uuidString)
      let item = try JSONDecoder().decode(RemoteOrganizerItem.self, from: delivery.payload)
      XCTAssertFalse(item.filename?.hasSuffix(".m4a") ?? false)
      try await store.markRemoteItemDelivered(delivery)
    }
    XCTAssertEqual(claimed, sendable)
    XCTAssertEqual(claimed.count, 3)
    try await store.checkpointAndClose()
  }

  func testZipLimitsStopBombsDeepNestingAndLyingHeaders() throws {
    let reader = ZipArchiveReader()
    // Ratio: 5 MB of zeros compress about a thousandfold.
    let bomb = Self.makeZip([ZipEntry(name: "zeros.txt", data: Data(count: 5_000_000))])
    XCTAssertThrowsError(try reader.read(bomb)) {
      XCTAssertEqual($0 as? ZipArchiveReader.ReadError, .ratioExceeded)
    }
    // Entries.
    let many = Self.makeZip((0..<3).map { ZipEntry(name: "\($0).txt", data: Data("a".utf8)) })
    XCTAssertThrowsError(
      try ZipArchiveReader(limits: .init(maximumEntries: 2)).read(many)
    ) { XCTAssertEqual($0 as? ZipArchiveReader.ReadError, .tooManyEntries) }
    // Total size.
    let big = Self.makeZip([
      ZipEntry(name: "a.bin", data: Data((0..<4_000).map { UInt8($0 % 251) }), deflate: false)
    ])
    XCTAssertThrowsError(
      try ZipArchiveReader(limits: .init(maximumTotalBytes: 1_000)).read(big)
    ) { XCTAssertEqual($0 as? ZipArchiveReader.ReadError, .tooLarge) }
    // Depth.
    XCTAssertThrowsError(try reader.read(many, depth: 3)) {
      XCTAssertEqual($0 as? ZipArchiveReader.ReadError, .tooDeep)
    }
    // A header that declares less than the data holds, and a wrong CRC.
    let text = Data(String(repeating: "虚构文本", count: 200).utf8)
    let lying = Self.makeZip([ZipEntry(name: "a.txt", data: text, declaredSize: 100)])
    XCTAssertThrowsError(try reader.read(lying))
    let damaged = Self.makeZip([ZipEntry(name: "a.txt", data: text, crc: 1)])
    XCTAssertThrowsError(try reader.read(damaged)) {
      XCTAssertEqual($0 as? ZipArchiveReader.ReadError, .corrupt)
    }
    XCTAssertThrowsError(try reader.read(Data("PK\u{3}\u{4}not really".utf8)))
    // A readable one: stored and deflated members come back exactly.
    let fine = Self.makeZip([
      ZipEntry(name: "a.txt", data: text), ZipEntry(name: "b.bin", data: m4a, deflate: false),
      ZipEntry(name: "folder/", data: Data(), deflate: false),
    ])
    let contents = try reader.read(fine)
    XCTAssertEqual(contents.members.map(\.path), ["a.txt", "b.bin"])
    XCTAssertEqual(contents.members.map(\.data), [text, m4a])

    // A zip over the limits is kept whole on this Mac and not expanded.
    let url = root.appendingPathComponent("bomb.zip")
    try bomb.write(to: url)
    let outcomes = processor().prepareAll(.file(url), capturedAt: at, source: nil, origin: .finder)
    XCTAssertEqual(outcomes.count, 2)
    XCTAssertEqual(label(outcomes[0]), "bomb.zip [file, local]")
    XCTAssertTrue(label(outcomes[1]).contains("压缩比异常"), label(outcomes[1]))
  }

  // MARK: - Media and archives

  func testAudioVideoArchivesAndUnreadableBinariesStayOnThisMac() throws {
    let processor = processor()
    func outcome(_ name: String, _ data: Data) throws -> IntakeOutcome {
      let url = root.appendingPathComponent(name)
      try data.write(to: url)
      return processor.prepare(.file(url), capturedAt: at, source: nil, origin: .finder)
    }
    func localOnly(_ name: String, _ data: Data) throws {
      guard case .item(let draft) = try outcome(name, data) else { return XCTFail(name) }
      XCTAssertTrue(draft.isLocalOnly, name)
      XCTAssertEqual(draft.kind, .file, name)
      XCTAssertEqual(draft.text, "", name)
    }
    // `.avi` is video whatever this Mac can do with it: imported as a
    // recording when AVFoundation reads it, else kept here; never sent.
    let avi = Data("RIFF".utf8) + Data(count: 4) + Data("AVI LIST".utf8) + Data(count: 64)
    let aviURL = root.appendingPathComponent("old.avi")
    if IntakeProcessor.canDecodeMedia(aviURL) {
      XCTAssertEqual(try outcome("old.avi", avi), .media(aviURL))
    } else {
      try localOnly("old.avi", avi)
    }
    try localOnly(
      "voice.wma", Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) + Data(count: 64))
    // Audio by content, whatever the name says.
    try localOnly("clip.dat", m4a)
    try localOnly("clip.bin", Data("ID3".utf8) + Data(count: 64))
    for archive in ["a.tar", "a.tgz", "a.7z", "a.rar", "a.gz"] {
      try localOnly(archive, Data([0x1F, 0x8B, 0, 0]) + Data(count: 32))
    }
    try localOnly("firmware.unknownbin", Data((0..<64).map { UInt8($0) }))
    // Decodable audio goes to the recording import (transcribed here).
    let url = root.appendingPathComponent("memo.m4a")
    try m4a.write(to: url)
    XCTAssertEqual(
      processor.prepare(.file(url), capturedAt: at, source: nil, origin: .finder), .media(url))
    // Documents the organizing device reads still go as their bytes.
    guard case .item(let sheet) = try outcome("表.xlsx", Data([0x50, 0x4B, 3, 4]) + Data(count: 40))
    else { return XCTFail("xlsx") }
    XCTAssertFalse(sheet.isLocalOnly)
    // Camera RAW and other declared images take the image path.
    XCTAssertEqual(IntakeFileClass.classify(URL(fileURLWithPath: "/tmp/a.dng")), .image)
    XCTAssertEqual(IntakeFileClass.classify(URL(fileURLWithPath: "/tmp/a.avi")), .video)
    XCTAssertEqual(IntakeFileClass.classify(URL(fileURLWithPath: "/tmp/a.wma")), .audio)
    XCTAssertTrue(MediaContentSniffer.isAudioOrVideo(m4a))
    XCTAssertFalse(MediaContentSniffer.isAudioOrVideo(try syntheticPNG(width: 4, height: 4)))
    // UTF-16 text (FF FE) and a HEIF image (ftyp heic) are not media.
    XCTAssertFalse(MediaContentSniffer.isAudioOrVideo(Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])))
    XCTAssertFalse(
      MediaContentSniffer.isAudioOrVideo(Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8)))
  }

  // MARK: - Storage

  /// Opt-in measurement (privacy contract §7): the lab scenario's asset
  /// files taken in through the real intake twice, as when the same file is
  /// dropped again. Set `BESTASR_LAB_ASSETS` to a directory of synthetic
  /// assets; the numbers are printed as one `LAB-LIBRARY-BYTES` line.
  func testLabScenarioLibraryBytes() throws {
    guard let path = ProcessInfo.processInfo.environment["BESTASR_LAB_ASSETS"] else {
      throw XCTSkip("set BESTASR_LAB_ASSETS to measure")
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]
    ).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
    let sourceBytes = try files.reduce(Int64(0)) {
      $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    let processor = processor()
    var items = 0
    func takeIn() {
      for file in files {
        for case .item(let draft) in processor.prepareAll(
          .file(file), capturedAt: at, source: nil, origin: .finder)
        {
          processor.assetStore.commit(sessionID: draft.id)
          items += 1
        }
      }
    }
    takeIn()
    let once = ContentAddressedAssets.uniqueBytes(under: assets)
    takeIn()
    let twice = ContentAddressedAssets.uniqueBytes(under: assets)
    print(
      "LAB-LIBRARY-BYTES files=\(files.count) source_bytes=\(sourceBytes) items=\(items) "
        + "stored_files_once=\(once.files) library_bytes_once=\(once.bytes) "
        + "stored_files_twice=\(twice.files) library_bytes_twice=\(twice.bytes)")
    XCTAssertEqual(once.bytes, twice.bytes, "taking the same files in again stores nothing new")
  }

  private func inode(_ url: URL) -> (ino: UInt64, links: UInt16) {
    var entry = stat()
    XCTAssertEqual(lstat(url.path, &entry), 0, url.path)
    return (UInt64(entry.st_ino), UInt16(entry.st_nlink))
  }

  func testIdenticalFilesAreStoredOnceAndLeaveWithTheirLastItem() throws {
    let store = IntakeAssetStore(assetRoot: assets)
    let bytes = Data((0..<100_000).map { UInt8($0 % 253) })
    func stage(_ id: SessionID, _ data: Data) throws -> URL {
      let attachment = try XCTUnwrap(
        try store.stage(
          sessionID: id,
          requests: [
            .init(
              role: .original, source: .data(data), originalFilename: "报表.xlsx",
              mediaType: "application/octet-stream", fileExtension: "xlsx")
          ]
        ).first)
      store.commit(sessionID: id)
      return assets.appendingPathComponent(attachment.relativePath)
    }
    let first = SessionID()
    let second = SessionID()
    let a = try stage(first, bytes)
    let b = try stage(second, bytes)
    let other = try stage(SessionID(), bytes + Data([1]))
    XCTAssertEqual(inode(a).ino, inode(b).ino, "the second copy is the same file")
    XCTAssertEqual(inode(a).links, 3, "two items and the content index")
    XCTAssertNotEqual(inode(other).ino, inode(a).ino)
    XCTAssertEqual(try Data(contentsOf: b), bytes)
    let usage = ContentAddressedAssets.uniqueBytes(under: assets)
    XCTAssertEqual(usage.bytes, Int64(bytes.count * 2 + 1))

    // Deleting one item keeps the other's bytes; the last one takes them.
    try FileManager.default.removeItem(at: store.sessionDirectory(first))
    XCTAssertEqual(ContentAddressedAssets.prune(assetRoot: assets), 0)
    XCTAssertEqual(try Data(contentsOf: b), bytes)
    try FileManager.default.removeItem(at: store.sessionDirectory(second))
    XCTAssertEqual(ContentAddressedAssets.prune(assetRoot: assets), 1)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let anchor = try XCTUnwrap(ContentAddressedAssets.anchor(assetRoot: assets, digest: digest))
    XCTAssertFalse(FileManager.default.fileExists(atPath: anchor.path))
    XCTAssertEqual(ContentAddressedAssets.uniqueBytes(under: assets).bytes, Int64(bytes.count + 1))
  }
}
