import CoreText
import UIKit
import XCTest

@testable import MindloomPhone

/// Titles at display sizes draw Chinese at the designed size (the prototype's 「最近」 is 53.5 pt of
/// ink at 28 pt; the system font's own fallback gave 49.7).
final class TitleFontTests: XCTestCase {
  private func inkWidth(_ text: String, _ font: UIFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
  }

  func testChineseTitleInkMatchesThePrototype() {
    let title = PhoneTitleFont.uiFont(28)
    let system = UIFont.systemFont(ofSize: 28, weight: .semibold)
    let ours = inkWidth("最近", title)
    print("ink 最近: title font \(ours), system \(inkWidth("最近", system))")
    XCTAssertEqual(ours, 53.5, accuracy: 1.5)
  }

  func testLatinStaysSF() {
    let title = PhoneTitleFont.uiFont(20)
    let system = UIFont.systemFont(ofSize: 20, weight: .semibold)
    XCTAssertEqual(inkWidth("MacBook Pro", title), inkWidth("MacBook Pro", system), accuracy: 0.5)
  }

  /// iOS's PingFang 「？」 has almost no blank after its ink (0.8 pt at 20), not the half em the
  /// old fixed −0.6 em trim assumed: the trim is measured, so 「与 Mac 断开？」 centres on its ink.
  func testTrailingQuestionMarkBlankIsMeasured() {
    let blank = PhoneTitleFont.trailingBlank(of: "？", size: 20)
    print("？ trailing blank at 20: \(blank)")
    XCTAssertGreaterThanOrEqual(blank, 0)
    XCTAssertLessThan(blank, 3)
    let blanks = PhoneTitleFont.inkBlanks("与 Mac 断开连接？", size: 20)
    XCTAssertEqual(blanks.trailing, blank, accuracy: 0.01)
  }
}
