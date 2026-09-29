import AppKit
import XCTest

@testable import bestASR

/// The panel exists to be read. Its first version measured the answer through
/// a text view whose container width was reset to zero as it was configured,
/// so every answer was clipped to a line and a half with a scrollbar floating
/// over it — the content was there and could not be seen.
@MainActor
final class SpokenAnswerPanelTests: XCTestCase {
  func testAShortAnswerIsShownWhole() {
    _ = NSApplication.shared
    let controller = SpokenAnswerPanelController()
    let answer = "We'll go over this plan together next week."

    controller.present(answer: answer, question: "翻译成英语")
    let geometry = controller.laidOutGeometry

    XCTAssertGreaterThan(geometry.answerContent, 0)
    XCTAssertEqual(
      geometry.visibleAnswer, geometry.answerContent, accuracy: 0.5,
      "A short answer must not be scrolled: all of it is visible."
    )
    XCTAssertGreaterThan(
      geometry.panelHeight, geometry.answerContent,
      "The panel has to be taller than the answer it carries."
    )
    controller.dismiss()
  }

  func testAMultiParagraphAnswerGrowsThePanelRatherThanBeingCut() {
    _ = NSApplication.shared
    let controller = SpokenAnswerPanelController()
    let short = "一行。"
    let long = String(repeating: "这是一段足够长的答案，需要换行才能放下。", count: 4)

    controller.present(answer: short, question: "问题")
    let shortHeight = controller.laidOutGeometry.panelHeight
    controller.present(answer: long, question: "问题")
    let longGeometry = controller.laidOutGeometry

    XCTAssertGreaterThan(longGeometry.panelHeight, shortHeight)
    XCTAssertEqual(
      longGeometry.visibleAnswer, longGeometry.answerContent, accuracy: 0.5,
      "Anything inside the cap is shown whole."
    )
    controller.dismiss()
  }

  /// Past the cap it scrolls instead of covering the window underneath.
  func testAVeryLongAnswerStopsGrowingAndScrolls() {
    _ = NSApplication.shared
    let controller = SpokenAnswerPanelController()
    let veryLong = String(
      repeating: "这一段会一直写下去，直到超过面板允许覆盖的高度为止。", count: 60)

    controller.present(answer: veryLong, question: "问题")
    let geometry = controller.laidOutGeometry

    XCTAssertEqual(
      geometry.visibleAnswer,
      SpokenAnswerPanelController.maximumAnswerContentHeight,
      accuracy: 0.5
    )
    XCTAssertGreaterThan(
      geometry.answerContent, geometry.visibleAnswer,
      "The rest is reachable by scrolling, not thrown away."
    )
    controller.dismiss()
  }
}
