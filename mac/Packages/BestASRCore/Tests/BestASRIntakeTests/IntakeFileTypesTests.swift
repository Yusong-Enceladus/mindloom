import AVFoundation
import AppKit
import BestASRDomain
import CoreGraphics
import CoreVideo
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import BestASRIntake

/// The files contract on this Mac: every file type is taken in, read here
/// where macOS can do it without a model, and otherwise kept byte for byte
/// for the organizing device. Every input is synthetic and made in the test.
final class IntakeFileTypesTests: XCTestCase {
  private var root: URL!
  private var processor: IntakeProcessor!
  private let at = Date(timeIntervalSince1970: 5_000)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-files-\(UUID().uuidString)", isDirectory: true)
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

  private func draft(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws
    -> UserItemDraft
  {
    let outcome = processor.prepare(.file(url), capturedAt: at, source: nil, origin: .finder)
    guard case .item(let draft) = outcome else {
      XCTFail("\(url.lastPathComponent): \(outcome)", file: file, line: line)
      throw XCTSkip("not an item")
    }
    return draft
  }

  // MARK: - Documents and files

  func testWordProcessingFilesAreFilesWithTheirTextReadHere() throws {
    let source = NSAttributedString(string: "虚构的季度计划\n第二段")
    let range = NSRange(location: 0, length: source.length)
    for (ext, type, mime) in [
      (
        "docx", NSAttributedString.DocumentType.officeOpenXML,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ),
      ("odt", .openDocument, "application/vnd.oasis.opendocument.text"),
      ("doc", .docFormat, "application/msword"),
    ] {
      let data = try source.data(from: range, documentAttributes: [.documentType: type])
      let item = try draft(try write(data, "虚构计划.\(ext)"))
      XCTAssertEqual(item.kind, .file, ext)
      XCTAssertTrue(item.text.contains("虚构的季度计划"), "\(ext): \(item.text)")
      XCTAssertEqual(item.extractor, "\(ext)-attributed-v1")
      XCTAssertEqual(item.attachments.map(\.role), [.original])
      XCTAssertEqual(item.attachments.first?.mediaType, mime, ext)
      XCTAssertEqual(item.attachments.first?.sizeBytes, UInt64(data.count))
      XCTAssertEqual(item.originalFilename, "虚构计划.\(ext)")
      XCTAssertNotNil(item.uniformType)
      // A file is titled by its filename, not by the text read here.
      XCTAssertEqual(item.automaticTitle, "虚构计划.\(ext)")
    }
  }

  func testOfficeBooksArchivesAndUnknownBinariesAreKeptByteForByte() throws {
    // Zip-shaped synthetic bytes: the Mac does not open them.
    let zipBytes = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 60)
    let cases: [(String, String)] = [
      ("表.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
      ("表.xls", "application/vnd.ms-excel"),
      ("表.ods", "application/vnd.oasis.opendocument.spreadsheet"),
      ("稿.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
      ("稿.odp", "application/vnd.oasis.opendocument.presentation"),
      ("书.epub", "application/epub+zip"), ("包.zip", "application/zip"),
      ("旧.ppt", "application/vnd.ms-powerpoint"), ("信.msg", "application/vnd.ms-outlook"),
      ("数据.zzqq", "application/octet-stream"), ("文稿.pages", "application/vnd.apple.pages"),
    ]
    // Privacy contract v6 §5: archives and binaries the organizing device
    // cannot read are kept on this Mac only; documents go as their bytes.
    let keptHere: Set<String> = ["包.zip", "数据.zzqq"]
    for (name, mime) in cases {
      let item = try draft(try write(zipBytes, name))
      XCTAssertEqual(item.kind, .file, name)
      XCTAssertEqual(item.text, "", name)
      XCTAssertEqual(
        item.extractor,
        keptHere.contains(name)
          ? UserItemLimits.localOnlyExtractor : UserItemLimits.fileBytesExtractor, name)
      XCTAssertEqual(item.attachments.first?.mediaType, mime, name)
      XCTAssertEqual(item.attachments.first?.sizeBytes, UInt64(zipBytes.count), name)
    }
  }

  func testStructuredTextKeepsItsTextAndGoesAsAFile() throws {
    let cases: [(String, String, String)] = [
      ("账单.csv", "日期,金额\n9-01,120\n", "text/csv"),
      ("行程.ics", "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:虚构评审会\nEND:VEVENT\nEND:VCALENDAR\n",
       "text/calendar"),
      ("名片.vcf", "BEGIN:VCARD\nVERSION:3.0\nFN:虚构 张三\nEND:VCARD\n", "text/vcard"),
      ("邮件.eml", "From: a@example.invalid\nSubject: 虚构报价\n\n正文\n", "message/rfc822"),
    ]
    for (name, text, mime) in cases {
      let item = try draft(try write(Data(text.utf8), name))
      XCTAssertEqual(item.kind, .file, name)
      XCTAssertEqual(item.text, text, name)
      XCTAssertEqual(item.extractor, "declared-text-v1", name)
      XCTAssertEqual(item.attachments.first?.mediaType, mime, name)
    }
  }

  /// A binary with no zero byte early on is not read as Windows-1252 text.
  func testBinariesNeverGetGarbledLocalText() throws {
    let bytes = Data((1...200).map { UInt8($0) })
    let item = try draft(try write(bytes, "数据.xlsx"))
    XCTAssertEqual(item.text, "")
    let unknown = try draft(try write(Data("plain words".utf8), "notes.zzunknown"))
    XCTAssertEqual(unknown.text, "plain words")
    let latin = try draft(try write(bytes, "blob.zzunknown"))
    XCTAssertEqual(latin.text, "")
  }

  func testPlainTextAndCodeStayDocuments() throws {
    for (name, text) in [("笔记.md", "# 虚构\n内容"), ("run.py", "print('虚构')\n")] {
      let item = try draft(try write(Data(text.utf8), name))
      XCTAssertEqual(item.kind, .document, name)
      XCTAssertEqual(item.text, text, name)
    }
  }

  func testWebArchiveAndSavedLinksAreReadWithoutTheNetwork() throws {
    let html = Data(
      "<html><head><script>fetch('https://example.invalid')</script></head><body><h1>虚构页面</h1><p>正文段落</p><img src=\"https://example.invalid/a.png\"></body></html>"
        .utf8)
    let archive: [String: Any] = [
      "WebMainResource": [
        "WebResourceData": html, "WebResourceURL": "https://example.invalid/page",
        "WebResourceMIMEType": "text/html",
      ]
    ]
    let archiveData = try PropertyListSerialization.data(
      fromPropertyList: archive, format: .binary, options: 0)
    let page = try draft(try write(archiveData, "虚构页面.webarchive"))
    XCTAssertEqual(page.kind, .document)
    XCTAssertTrue(page.text.contains("虚构页面"), page.text)
    XCTAssertTrue(page.text.contains("正文段落"), page.text)
    XCTAssertFalse(page.text.contains("fetch("), page.text)
    XCTAssertTrue(page.text.hasPrefix("https://example.invalid/page"), page.text)

    let webloc = try PropertyListSerialization.data(
      fromPropertyList: ["URL": "https://example.invalid/doc"], format: .xml, options: 0)
    let link = try draft(try write(webloc, "虚构链接.webloc"))
    XCTAssertEqual(link.kind, .document)
    XCTAssertEqual(link.text, "虚构链接\nhttps://example.invalid/doc")
    let shortcut = try draft(
      try write(Data("[InternetShortcut]\r\nURL=https://example.invalid/w\r\n".utf8), "快捷.url"))
    XCTAssertEqual(shortcut.text, "快捷\nhttps://example.invalid/w")
  }

  // MARK: - PDF

  func testPDFsWithScannedPagesOrAPasswordAreSentAsFiles() throws {
    let full = try draft(try write(try syntheticPDF(text: "Synthetic agenda"), "议程.pdf"))
    XCTAssertEqual(full.kind, .document)

    // Two pages, one with a text layer and one scanned: a file keeping the text.
    let mixed = try twoPagePDF()
    let partly = try draft(try write(mixed, "半扫描.pdf"))
    XCTAssertEqual(partly.kind, .file)
    XCTAssertEqual(partly.pageCount, 2)
    XCTAssertTrue(partly.text.contains("Page one"), partly.text)
    XCTAssertEqual(partly.extractor, UserItemLimits.pdfExtractor)

    // A password-protected PDF is never opened; it is kept for the device,
    // which reports it as encrypted.
    let document = try XCTUnwrap(PDFDocument(data: try syntheticPDF(text: "Secret synthetic")))
    let locked = root.appendingPathComponent("加密.pdf")
    XCTAssertTrue(
      document.write(
        to: locked,
        withOptions: [.userPasswordOption: "synthetic-pw", .ownerPasswordOption: "synthetic-pw"]))
    let lockedItem = try draft(locked)
    XCTAssertEqual(lockedItem.kind, .file)
    XCTAssertEqual(lockedItem.text, "")
    XCTAssertEqual(lockedItem.attachments.first?.mediaType, "application/pdf")

    // Pasted PDF bytes of a scan follow the same rule.
    guard
      case .item(let pasted) = processor.prepare(
        .pdfData(try syntheticPDF(text: nil)), capturedAt: at, source: nil,
        origin: .previousFrontmost)
    else { return XCTFail("pasted scan") }
    XCTAssertEqual(pasted.kind, .file)
    XCTAssertEqual(pasted.originalFilename, "pasted.pdf")
  }

  func testAnIWorkPackageFolderSendsItsOwnPreview() throws {
    let package = root.appendingPathComponent("虚构方案.key", isDirectory: true)
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
    try syntheticPDF(text: "Keynote preview").write(
      to: package.appendingPathComponent("QuickLook/Preview.pdf"))
    try Data("synthetic".utf8).write(to: package.appendingPathComponent("Index.zip"))
    let item = try draft(package)
    XCTAssertEqual(item.kind, .file)
    XCTAssertEqual(item.originalFilename, "虚构方案.key-preview.pdf")
    XCTAssertEqual(item.attachments.first?.mediaType, "application/pdf")
    XCTAssertTrue(item.text.contains("Keynote preview"), item.text)

    let folder = root.appendingPathComponent("普通文件夹", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    XCTAssertEqual(
      processor.prepare(.file(folder), capturedAt: at, source: nil, origin: .finder),
      .rejected("不支持文件夹，未收进来"))
  }

  // MARK: - Size caps

  func testOriginalsAboveTheIntakeLimitAreRefusedBeforeAnyCopy() throws {
    let small = IntakeProcessor(
      assetStore: IntakeAssetStore(
        assetRoot: root.appendingPathComponent("small-assets"), maximumBytes: 1_000),
      pathPolicy: .none)
    let big = try write(Data(repeating: 7, count: 1_001), "大.xlsx")
    XCTAssertEqual(
      small.prepare(.file(big), capturedAt: at, source: nil, origin: .finder),
      .rejected("文件超过 200 MB，未收进来"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("small-assets/sessions").path))
    let fits = try write(Data(repeating: 7, count: 1_000), "刚好.xlsx")
    guard case .item = small.prepare(.file(fits), capturedAt: at, source: nil, origin: .finder)
    else { return XCTFail("a file at the limit is taken in") }
    XCTAssertEqual(UserItemLimits.maximumSendableFileBytes, 25 * 1_024 * 1_024)
  }

  // MARK: - Images

  func testImageFormatsAreNormalizedToPNGOrJPEG() throws {
    for (ext, type) in [("bmp", UTType.bmp), ("tiff", .tiff), ("heic", .heic), ("jpg", .jpeg)] {
      guard let data = try? encodedImage(type: type, width: 300, height: 200) else { continue }
      let item = try draft(try write(data, "图.\(ext)"))
      XCTAssertEqual(item.kind, .image, ext)
      let normalized = try XCTUnwrap(item.attachments.first { $0.role == .normalizedImage })
      XCTAssertTrue(["image/png", "image/jpeg"].contains(normalized.mediaType), ext)
      XCTAssertEqual(item.pixelWidth, 300, ext)
    }
  }

  func testASelfContainedSVGIsDrawnAndOneThatReachesOutIsNot() throws {
    let svg = """
      <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">
        <defs><linearGradient id="g"><stop offset="0" stop-color="#36c"/></linearGradient></defs>
        <rect width="120" height="60" fill="url(#g)"/><text x="10" y="35">虚构</text>
      </svg>
      """
    let drawn = try draft(try write(Data(svg.utf8), "图标.svg"))
    XCTAssertEqual(drawn.kind, .image)
    XCTAssertEqual(drawn.attachments.first?.mediaType, "image/svg+xml")
    XCTAssertNotNil(drawn.attachments.first { $0.role == .normalizedImage })

    for outside in [
      #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.invalid/a.png"/></svg>"#,
      #"<svg xmlns="http://www.w3.org/2000/svg"><style>@import url(x.css);</style></svg>"#,
      #"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/hosts">]><svg>&x;</svg>"#,
    ] {
      XCTAssertFalse(SVGRasterizer.isSelfContained(outside), outside)
      let kept = try draft(try write(Data(outside.utf8), "外链-\(UUID().uuidString).svg"))
      XCTAssertEqual(kept.kind, .file, outside)
      XCTAssertEqual(kept.text, outside)
    }
  }

  func testAnAnimatedGIFSendsItsFirstFrameAndUpToThreeDistinctOthers() throws {
    // Six frames: red, red, blue, green, green, white → three distinct others.
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
      (1, 0, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 0), (1, 1, 1),
    ]
    let gif = try animatedGIF(colors)
    let item = try draft(try write(gif, "动图.gif"))
    XCTAssertEqual(item.kind, .image)
    XCTAssertEqual(
      item.attachments.map(\.role),
      [.original, .normalizedImage, .animationFrame1, .animationFrame2, .animationFrame3])
    XCTAssertEqual(item.attachments.first?.mediaType, "image/gif")

    // Five distinct colours: still at most three more.
    let many = try animatedGIF([(1, 0, 0), (0, 0, 1), (0, 1, 0), (1, 1, 1), (0, 0, 0)])
    XCTAssertEqual(
      ImageNormalizer().animationFrames(data: many, maximum: 3, threshold: 0.06).count, 3)
    // A still GIF has none.
    let still = try animatedGIF([(1, 0, 0), (1, 0, 0)])
    XCTAssertTrue(ImageNormalizer().animationFrames(data: still, maximum: 3, threshold: 0.06).isEmpty)
  }

  // MARK: - Audio and video

  func testMediaGoesToTheImportOnlyWhenThisMacCanDecodeIt() throws {
    for name in ["a.m4a", "a.ogg", "a.caf", "a.mov", "a.m4v"] {
      let url = try write(Data([1, 2, 3]), name)
      XCTAssertEqual(
        processor.prepare(.file(url), capturedAt: at, source: nil, origin: .finder), .media(url),
        name)
    }
    // What this Mac cannot decode is kept here only, never sent (contract
    // v6 §5), whatever it is called.
    for name in ["a.mkv", "a.webm", "a.avi", "a.wma"] where !IntakeProcessor.canDecodeMedia(
      URL(fileURLWithPath: "/tmp/\(name)"))
    {
      let url = try write(Data([1, 2, 3]), name)
      guard
        case .item(let item) = processor.prepare(
          .file(url), capturedAt: at, source: nil, origin: .finder)
      else { return XCTFail(name) }
      XCTAssertTrue(item.isLocalOnly, name)
    }
  }

  func testKeyframeSelectionKeepsSceneChangesTwoSecondsApart() {
    typealias Sample = VideoKeyframeExtractor.Sample
    let samples: [Sample] = [
      .init(milliseconds: 0, change: 1), .init(milliseconds: 1_000, change: 0.01),
      .init(milliseconds: 2_000, change: 0.5), .init(milliseconds: 3_000, change: 0.9),
      .init(milliseconds: 4_000, change: 0.02), .init(milliseconds: 5_000, change: 0.3),
      .init(milliseconds: 9_000, change: 0.2),
    ]
    // 2 s and 3 s are one change (the stronger, 3 s); 5 s is exactly 2 s later.
    XCTAssertEqual(
      VideoKeyframeExtractor.select(samples, threshold: 0.12, spacing: 2_000, maximum: 12),
      [0, 3_000, 5_000, 9_000])
    // Over the limit, the strongest changes win, in time order.
    XCTAssertEqual(
      VideoKeyframeExtractor.select(samples, threshold: 0.12, spacing: 2_000, maximum: 3),
      [0, 3_000, 5_000])
    XCTAssertEqual(
      VideoKeyframeExtractor.select([], threshold: 0.12, spacing: 2_000, maximum: 12), [])
  }

  func testKeyframesOfASyntheticVideoBecomeImageItemsOfTheRecording() async throws {
    // 9 s at 4 fps: red 0–3 s, blue 3–3.5 s, green 3.5–6 s, white 6–9 s.
    let video = root.appendingPathComponent("会议录像.mov")
    try await writeSyntheticVideo(to: video, seconds: 9, fps: 4) { time in
      switch time {
      case ..<3: (1, 0, 0)
      case ..<3.5: (0, 0, 1)
      case ..<6: (0, 1, 0)
      default: (1, 1, 1)
      }
    }
    let frames = try await VideoKeyframeExtractor().keyframes(fileURL: video)
    let times = frames.map(\.milliseconds)
    XCTAssertEqual(times.first, 0)
    XCTAssertTrue(times.count >= 3 && times.count <= UserItemLimits.maximumVideoKeyframes, "\(times)")
    for (a, b) in zip(times, times.dropFirst()) {
      XCTAssertGreaterThanOrEqual(b - a, UserItemLimits.minimumKeyframeSpacingMilliseconds)
    }
    XCTAssertTrue(times.contains { (3_000...4_000).contains($0) }, "\(times)")
    XCTAssertTrue(times.contains { (6_000...7_000).contains($0) }, "\(times)")
    XCTAssertTrue(frames.allSatisfy { $0.image.data.starts(with: [0xFF, 0xD8]) })

    let parent = SessionID()
    let drafts = processor.keyframeDrafts(
      frames, parent: parent, videoName: "会议录像.mov", capturedAt: at, source: nil)
    XCTAssertEqual(drafts.count, frames.count)
    for (draft, frame) in zip(drafts, frames) {
      XCTAssertEqual(draft.kind, .image)
      XCTAssertEqual(draft.parentSessionID, parent)
      XCTAssertEqual(draft.frameMilliseconds, frame.milliseconds)
      XCTAssertEqual(draft.extractor, UserItemLimits.videoKeyframeExtractor)
      XCTAssertEqual(Set(draft.attachments.map(\.role)), [.original, .normalizedImage])
      XCTAssertGreaterThan(draft.capturedAt, at)
    }
    XCTAssertEqual(drafts.first?.originalFilename, "会议录像.mov · 0:00")
    XCTAssertEqual(IntakeProcessor.clock(3_723_000), "1:02:03")

    // Not a video (no video track): no keyframes, no error.
    let audioOnly = try write(Data([1, 2, 3]), "声音.m4a")
    let none = (try? await VideoKeyframeExtractor().keyframes(fileURL: audioOnly)) ?? []
    XCTAssertTrue(none.isEmpty)
  }

  // MARK: - Synthetic media

  private func twoPagePDF() throws -> Data {
    let output = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let consumer = try XCTUnwrap(CGDataConsumer(data: output))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Page one", attributes: [.font: font]))
    context.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0.3, alpha: 1)
    context.fill(CGRect(x: 20, y: 20, width: 200, height: 100))
    context.endPDFPage()
    context.closePDF()
    return output as Data
  }

  private func solid(_ color: (CGFloat, CGFloat, CGFloat), width: Int, height: Int) throws
    -> CGImage
  {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 3))
    return try XCTUnwrap(context.makeImage())
  }

  private func encodedImage(type: UTType, width: Int, height: Int) throws -> Data {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil)
    else { throw XCTSkip("\(type.identifier) cannot be written here") }
    CGImageDestinationAddImage(destination, try solid((0.2, 0.6, 0.3), width: width, height: height), nil)
    guard CGImageDestinationFinalize(destination) else { throw XCTSkip("encode failed") }
    return output as Data
  }

  private func animatedGIF(_ colors: [(CGFloat, CGFloat, CGFloat)]) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        output, UTType.gif.identifier as CFString, colors.count, nil))
    let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
    for color in colors {
      CGImageDestinationAddImage(
        destination, try solid(color, width: 64, height: 48), frame as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// A small H.264 QuickTime movie of solid colours, written with
  /// AVAssetWriter.
  private func writeSyntheticVideo(
    to url: URL, seconds: Int, fps: Int32, color: (Double) -> (CGFloat, CGFloat, CGFloat)
  ) async throws {
    let width = 160
    let height = 96
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<(seconds * Int(fps)) {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      let pixels = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      let rgb = color(Double(index) / Double(fps))
      let context = try XCTUnwrap(
        CGContext(
          data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
      context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      XCTAssertTrue(
        adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
  }
}
