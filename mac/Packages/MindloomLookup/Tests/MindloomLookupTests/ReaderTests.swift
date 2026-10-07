import Foundation
import XCTest

@testable import MindloomLookup

final class ReaderTests: XCTestCase {
  func testHiddenContentNeverReachesTheText() throws {
    let page = try XCTUnwrap(PageReader.read(Fixture.data("pages/hidden.html"), contentType: "text/html"))
    XCTAssertTrue(page.text.contains("Visible paragraph one"))
    XCTAssertTrue(page.text.contains("Visible paragraph two continues"))
    XCTAssertTrue(page.text.contains("Visible paragraph three stays"))
    XCTAssertFalse(page.text.contains("IGNORE-PREVIOUS"), page.text)
    XCTAssertTrue(page.text.contains("Zerowidth and tag characters are removed here."), page.text)
    for scalar in page.text.unicodeScalars {
      XCTAssertFalse(TextCleaner.isInvisible(scalar.value), String(format: "U+%04X", scalar.value))
    }
  }

  func testTablesAndEntities() throws {
    let page = try XCTUnwrap(PageReader.read(Fixture.data("pages/conference.html"), contentType: "text/html; charset=utf-8"))
    XCTAssertEqual(page.title, "EXCONF 2026 – Call for Papers")
    XCTAssertTrue(page.text.contains("Abstract submission deadline\tMay 11, 2026 (AoE)"), page.text)
    XCTAssertTrue(page.text.contains("December 6–12, 2026"))
    XCTAssertFalse(page.text.contains("Home"))
    XCTAssertFalse(page.text.contains("Sponsors"))
    XCTAssertFalse(page.text.contains("Privacy"))
    XCTAssertEqual(page.extractor, PageReader.htmlExtractor)
  }

  func testCharacterSets() throws {
    let gbk = try XCTUnwrap(PageReader.read(Fixture.data("pages/gbk.html"), contentType: "text/html"))
    XCTAssertEqual(gbk.title, "关于开展2026年首台套申报工作的通知")
    XCTAssertTrue(gbk.text.contains("申报截止日期：2026年4月30日17:00"))
    // A header charset wins over the page's own.
    let latin = Data("<html><head><meta charset=\"utf-8\"></head><body><p>caf\u{E9}</p></body></html>".data(using: .isoLatin1)!)
    let page = try XCTUnwrap(PageReader.read(latin, contentType: "text/html; charset=iso-8859-1"))
    XCTAssertTrue(page.text.contains("café"))
  }

  func testPlainTextAndPDF() throws {
    let text = try XCTUnwrap(PageReader.read(Data("Line one\r\n\r\n\r\nLine\u{200B} two\u{E0041}".utf8), contentType: "text/plain"))
    XCTAssertEqual(text.text, "Line one\n\nLine two")
    let pdf = try XCTUnwrap(PageReader.read(Self.minimalPDF("Public notice deadline 2026"), contentType: "application/pdf"))
    XCTAssertEqual(pdf.extractor, PageReader.pdfExtractor)
    XCTAssertTrue(pdf.text.contains("Public notice deadline 2026"), pdf.text)
    XCTAssertNil(PageReader.read(Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png"))
  }

  func testAMissingHeadEndDoesNotSwallowThePage() throws {
    let html = "<html><head><title>T</title><meta charset=utf-8><p>Body text that is visible to every reader of this page, long enough to count.</p></html>"
    let page = try XCTUnwrap(PageReader.read(Data(html.utf8), contentType: "text/html"))
    XCTAssertEqual(page.title, "T")
    XCTAssertTrue(page.text.contains("Body text that is visible"), page.text)
    let closed = "<html><head><title>T</title></head><body><p>Second body text.</p></body></html>"
    XCTAssertEqual(try XCTUnwrap(PageReader.read(Data(closed.utf8), contentType: "text/html")).text, "Second body text.")
  }

  func testParserSurvivesBrokenMarkup() {
    let html = "<p>One<p>Two<li>Three<td>Four</b></i><div>Five &amp; &#x4E2D; &unknown; &#0;</div><script>var x = '</div>';</script><!-- <p>hidden</p> --><p>Six"
    let root = HTMLParser.parse(html)
    PageCleaner.clean(root)
    let text = PageText.text(of: root)
    // A cell after text on the same line is set off by a tab.
    XCTAssertEqual(text, "One\nTwo\nThree\tFour\nFive & 中 &unknown; \u{FFFD}\nSix")
  }

  func testDeepAndLargePagesStayBounded() throws {
    let deep =
      String(repeating: "<div>", count: 50_000)
      + "<p>Deep text that is long enough to be read as a paragraph of content, with commas, too.</p>"
      + String(repeating: "</div>", count: 50_000)
    let page = try XCTUnwrap(PageReader.read(Data(deep.utf8), contentType: "text/html"))
    XCTAssertTrue(page.text.contains("Deep text"))
    var rows: [String] = ["<html><body>"]
    let row = "<p>Row with some text, a link <a href='/x'>here</a>, and more words for the reader.</p>\n"
    for _ in 0..<(2_000_000 / row.utf8.count) { rows.append(row) }
    let big = Data(rows.joined().utf8)
    let start = Date()
    let result = PageReader.read(big, contentType: "text/html")
    let seconds = Date().timeIntervalSince(start)
    XCTAssertNotNil(result)
    print("reader: \(big.count / 1024) KB page read in \(String(format: "%.2f", seconds)) s (debug build)")
    XCTAssertLessThan(seconds, 30)
  }

  func testExcerptsAreVerbatimAndFocused() {
    let text = """
      Welcome to the site.
      The EXCONF 2026 abstract deadline is May 11, 2026.
      Unrelated paragraph about travel and visas for attendees.
      Full papers are due May 18, 2026.
      """
    let excerpt = Excerpts.select(from: text, focus: ["EXCONF", "2026", "deadline", "due"])
    XCTAssertTrue(excerpt.contains("The EXCONF 2026 abstract deadline is May 11, 2026."))
    XCTAssertTrue(excerpt.contains("Full papers are due May 18, 2026."))
    XCTAssertFalse(excerpt.contains("travel"))
    XCTAssertEqual(Excerpts.locate("abstract   deadline\nis May 11", in: text).map { $0.count }, "abstract deadline is May 11".unicodeScalars.count)
    XCTAssertNil(Excerpts.locate("deadline is June 30", in: text))
    XCTAssertEqual(Excerpts.select(from: text, focus: ["OTHER", "price"]), "")
    XCTAssertTrue(Excerpts.select(from: text, focus: []).hasPrefix("Welcome to the site."))
  }

  func testSourceItemsKeepTheirBytesAndIdentity() throws {
    let raw = Data("<html>page</html>".utf8)
    func item() -> WebSourceItem {
      WebSourceItem(
        parentItemID: itemA, matterID: matterA, gap: .deadline, title: "t", requestedURL: URL(string: "https://a.example/")!,
        finalURL: URL(string: "https://a.example/x")!, retrievedAt: Date(), retrievedUptimeNanoseconds: 1,
        origin: .collectedLink, reader: .onDevice(extractor: PageReader.htmlExtractor), authority: .other,
        contentType: "text/html", text: "page", excerpt: "page", raw: raw)
    }
    let first = item()
    let second = item()
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.raw, raw)
    XCTAssertEqual(first.rawSHA256.count, 64)
    let encoded = try JSONEncoder().encode(first)
    let decoded = try JSONDecoder().decode(WebSourceItem.self, from: encoded)
    XCTAssertEqual(decoded, first)
  }

  /// A one-page PDF with one line of text in Helvetica.
  static func minimalPDF(_ line: String) -> Data {
    let stream = "BT /F1 18 Tf 72 720 Td (\(line)) Tj ET"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
    ]
    var output = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(output.utf8.count)
      output += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = output.utf8.count
    output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { output += String(format: "%010d 00000 n \n", offset) }
    output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(output.utf8)
  }
}
