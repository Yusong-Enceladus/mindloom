import AppKit
import BestASRDomain
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import BestASRIntake

/// Regression tests for the v6 privacy review (review/FINDINGS.md): screenshot
/// redaction across table cells, dotted numbers, wraps without overlap,
/// codes written first and long screenshots (F2); send copies of file bytes
/// with pictures redacted and recordings emptied, and pictures taken in
/// under another name (F3). Every number here is invented.
final class IntakeReviewFixTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-review-fixes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Drawing

  /// Black text on white at the given top-left positions (points = pixels).
  private func drawing(
    width: Int, height: Int, size: CGFloat = 44, _ texts: [(String, CGFloat, CGFloat)],
    boxes: [CGRect] = []
  ) throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.setLineWidth(2)
    for box in boxes {
      context.stroke(
        CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height))
    }
    let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
    for (text, x, top) in texts {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
      context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - size)
      CTLineDraw(line, context)
    }
    return try XCTUnwrap(context.makeImage())
  }

  private func png(_ image: CGImage) throws -> Data {
    try VisionSendCopyRedactor.encode(image, png: true)
  }

  private func image(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  /// Everything the redactor's own readings find (whole image both ways,
  /// and enlarged), without spaces.
  private func readAll(_ image: CGImage) -> String {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var texts: [String] = []
    for correction in [true, false] {
      texts +=
        ((try? VisionSendCopyRedactor.recognize(
          image, languageCorrection: correction, placedIn: bounds)) ?? []).map(\.text)
    }
    texts += VisionSendCopyRedactor.enlargedPass(image).map(\.text)
    return texts.joined(separator: "|").filter { !$0.isWhitespace }
  }

  private func digits(_ text: String) -> String { text.filter(\.isASCII).filter(\.isNumber) }

  // MARK: - F2 redaction

  func testNumbersSplitAcrossTableCellsAreCovered() throws {
    let cells = [
      CGRect(x: 30, y: 100, width: 280, height: 100),
      CGRect(x: 330, y: 100, width: 280, height: 100),
      CGRect(x: 630, y: 100, width: 280, height: 100),
      CGRect(x: 930, y: 100, width: 280, height: 100),
    ]
    let original = try drawing(
      width: 1_400, height: 300, size: 48,
      [("手机", 70, 120), ("138", 370, 120), ("1234", 670, 120), ("5678", 970, 120)],
      boxes: cells)
    XCTAssertTrue(readAll(original).contains("1234"), "Vision reads the cells")
    let sent = try image(
      VisionSendCopyRedactor().redactedSendCopy(of: png(original), mediaType: "image/png"))
    let after = readAll(sent)
    for fragment in ["138", "1234", "5678"] {
      XCTAssertFalse(after.contains(fragment), "\(fragment) still readable: \(after)")
    }
    XCTAssertTrue(after.contains("手机"), after)
  }

  func testDottedNumbersCodesWrittenFirstAndWrapsWithoutOverlapAreCovered() throws {
    let redactor = VisionSendCopyRedactor()
    let dotted = try drawing(
      width: 1_200, height: 300, [("联系电话 138·1234·5678", 40, 60), ("备用 138.8765.4321", 40, 180)])
    let code = try drawing(width: 1_200, height: 200, [("【招商银行】739146（动态验证码）请勿泄露", 40, 60)])
    let wrapped = try drawing(
      width: 1_200, height: 300, [("卡号 6222 0212", 600, 60), ("3456 7894 请尽快转账", 40, 130)])
    for (original, secrets, kept) in [
      (dotted, ["1234", "5678", "8765", "4321"], "联系电话"),
      (code, ["739146"], "请勿泄露"),
      (wrapped, ["6222", "0212", "3456", "7894"], "请尽快转账"),
    ] {
      let before = digits(readAll(original))
      XCTAssertTrue(secrets.allSatisfy { before.contains($0) }, "read before: \(before)")
      let sent = try image(redactor.redactedSendCopy(of: png(original), mediaType: "image/png"))
      let after = readAll(sent)
      for secret in secrets {
        XCTAssertFalse(digits(after).contains(secret), "\(secret) still readable: \(after)")
      }
      XCTAssertTrue(after.contains(kept), "the rest stays readable: \(after)")
    }
  }

  /// A long chat screenshot normalized to 2,560 px has text too small for
  /// Vision at its size; the enlarged tiles read and cover it.
  func testALongScreenshotIsReadInEnlargedTilesAndCovered() throws {
    var lines: [(String, CGFloat, CGFloat)] = []
    var top: CGFloat = 80
    var index = 0
    while top < 13_900 {
      lines.append(
        index == 43 ? ("王师傅手机 13812345678", 60, top) : ("今天的会议纪要第 \(index) 条，大家按计划推进", 60, top))
      top += 160
      index += 1
    }
    let long = try drawing(width: 1_170, height: 14_000, size: 38, lines)
    let normalized = try ImageNormalizer().normalize(png(long))
    XCTAssertEqual(normalized.pixelHeight, 2_560)
    let sendCopy = try image(normalized.data)
    XCTAssertTrue(
      digits(readAll(sendCopy)).contains("13812345678"), "the enlarged reading finds it")
    let redactor = VisionSendCopyRedactor()
    XCTAssertFalse(try redactor.regions(in: sendCopy).isEmpty)
    let sent = try image(
      redactor.redactedSendCopy(of: normalized.data, mediaType: normalized.mediaType))
    XCTAssertFalse(digits(readAll(sent)).contains("1381234"))
  }

  func testDigitRunsSkipDatesTimesAndAmounts() {
    func runs(_ text: String) -> [String] {
      VisionSendCopyRedactor.digitRuns(text).map {
        (text as NSString).substring(with: NSRange(location: $0.0, length: $0.1 - $0.0))
      }
    }
    XCTAssertEqual(runs("订单 12345678 已发货"), ["12345678"])
    XCTAssertEqual(runs("ID 1101 0519 4912"), ["1101 0519 4912"])
    XCTAssertEqual(runs("会议 2026-09-30 14:30，截止 20260929"), [])
    XCTAssertEqual(runs("尾款 1234567.89 元，第 3 条"), [])
    XCTAssertEqual(runs("短号 123456"), [])
    XCTAssertEqual(VisionSendCopyRedactor.canonicalSeparators("138・1234•5678"), "138·1234·5678")
  }

  func testRowsColumnsAndReadingPairs() {
    // Two cells on one baseline, a line under them starting further left,
    // and a column of single characters.
    let rects = [
      CGRect(x: 400, y: 100, width: 100, height: 40),
      CGRect(x: 600, y: 102, width: 100, height: 40),
      CGRect(x: 40, y: 150, width: 300, height: 40),
      CGRect(x: 900, y: 100, width: 40, height: 40), CGRect(x: 902, y: 160, width: 36, height: 40),
      CGRect(x: 901, y: 220, width: 38, height: 40),
    ]
    let rows = VisionSendCopyRedactor.rows(rects)
    XCTAssertTrue(rows.contains { Set($0).isSuperset(of: [0, 1]) && $0.first == 0 })
    let pairs = VisionSendCopyRedactor.readingPairs(rects)
    XCTAssertTrue(pairs.contains([1, 2]) || pairs.contains([0, 2]), "\(pairs)")
    let columns = VisionSendCopyRedactor.columns(
      rects, texts: ["手机", "138", "长长的一行文字", "1", "3", "8"])
    XCTAssertTrue(columns.contains([3, 4, 5]), "\(columns)")
  }

  // MARK: - F3 file send copies

  private func picture(_ text: String) throws -> Data {
    try png(drawing(width: 1_200, height: 240, [(text, 40, 80)]))
  }

  func testAPictureUnderADocumentNameGoesRedacted() throws {
    let copy = try FileSendCopySanitizer().sendCopy(
      of: picture("王师傅手机 13812345678 周五来装"), filename: "报销.xlsx")
    XCTAssertTrue(copy.picturesRedacted)
    let after = readAll(try image(copy.data))
    XCTAssertFalse(digits(after).contains("1381234"), after)
    XCTAssertTrue(after.contains("周五来装"), after)
  }

  func testAPackageIsRebuiltWithPicturesRedactedAndRecordingsEmptied() throws {
    let screenshot = try picture("回电 13812345678 确认")
    let m4a = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(repeating: 3, count: 200)
    let ole =
      Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 1, count: 64)
    let package = IntakePrivacyTests.makeZip([
      .init(name: "[Content_Types].xml", data: Data("<Types/>".utf8)),
      .init(name: "word/document.xml", data: Data("<w:t>报销说明，截图见下</w:t>".utf8)),
      .init(name: "word/media/image1.png", data: screenshot, deflate: false),
      .init(name: "ppt/media/media1.m4a", data: m4a),
      .init(name: "word/embeddings/oleObject1.bin", data: ole),
      .init(name: "word/media/image2.emf", data: Data("synthetic-emf".utf8)),
      .init(name: "secret.txt", data: Data("x".utf8), encrypted: true),
    ])
    let copy = try FileSendCopySanitizer().sendCopy(of: package, filename: "报销说明.docx")
    XCTAssertTrue(copy.picturesRedacted)
    let members = try ZipArchiveReader().read(copy.data).members
    let byPath = Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0.data) })
    XCTAssertEqual(byPath["word/document.xml"], Data("<w:t>报销说明，截图见下</w:t>".utf8))
    XCTAssertEqual(byPath["ppt/media/media1.m4a"], Data(), "a recording never leaves")
    XCTAssertEqual(byPath["word/embeddings/oleObject1.bin"], Data())
    XCTAssertEqual(byPath["word/media/image2.emf"], Data())
    XCTAssertNil(byPath["secret.txt"], "an entry this Mac cannot read is left out")
    let redacted = try XCTUnwrap(byPath["word/media/image1.png"])
    let after = readAll(try image(redacted))
    XCTAssertFalse(digits(after).contains("1381234"), after)
    XCTAssertTrue(after.contains("确认"), after)
  }

  func testAScannedPDFIsSentWithItsPagesRedactedAndTextPagesKept() throws {
    let scan = try drawing(
      width: 1_240, height: 1_754, size: 40, [("身份证 11010519491231002X 请核对", 80, 200)])
    let output = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPage(mediaBox: &box)
    context.draw(scan, in: box)
    context.endPage()
    context.beginPage(mediaBox: &box)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "Typed page: budget review on Friday",
        attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(line, context)
    context.endPage()
    context.closePDF()
    let copy = try FileSendCopySanitizer().sendCopy(of: output as Data, filename: "扫描件.pdf")
    XCTAssertTrue(copy.picturesRedacted)
    let document = try XCTUnwrap(PDFDocument(data: copy.data))
    XCTAssertEqual(document.pageCount, 2)
    XCTAssertTrue(document.page(at: 1)?.string?.contains("budget review") == true, "text page kept")
    // The scanned page as the organizing device would render it.
    let page = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: copy.data as CFData)!)?.page(at: 1))
    let pageBox = page.getBoxRect(.cropBox)
    let width = Int(pageBox.width * 2.5)
    let height = Int(pageBox.height * 2.5)
    let render = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    render.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    render.fill(CGRect(x: 0, y: 0, width: width, height: height))
    render.scaleBy(x: 2.5, y: 2.5)
    render.drawPDFPage(page)
    let after = readAll(try XCTUnwrap(render.makeImage()))
    XCTAssertFalse(digits(after).contains("1101051949"), after)
    XCTAssertTrue(after.contains("请核对"), after)
  }

  func testOtherBytesGoAsTheyAreAndRecordingsNeverGo() throws {
    let csv = Data("日期,金额\n9-01,120\n".utf8)
    let copy = try FileSendCopySanitizer().sendCopy(of: csv, filename: "账单.csv")
    XCTAssertEqual(copy, RemoteOrganizerFileSendCopy(data: csv, picturesRedacted: false))
    let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 7, count: 64)
    XCTAssertThrowsError(try FileSendCopySanitizer().sendCopy(of: mp4, filename: "报告.xlsx"))
  }

  func testAPictureUnderAnotherNameIsTakenInAsAPicture() throws {
    let url = root.appendingPathComponent("报销.xlsx")
    try picture("尾款 1,280 元").write(to: url)
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
      pathPolicy: .none)
    let outcome = processor.prepare(
      .file(url), capturedAt: Date(timeIntervalSince1970: 1_000), source: nil, origin: .finder)
    guard case .item(let draft) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(draft.kind, .image)
    XCTAssertEqual(draft.originalFilename, "报销.xlsx")
  }
}
