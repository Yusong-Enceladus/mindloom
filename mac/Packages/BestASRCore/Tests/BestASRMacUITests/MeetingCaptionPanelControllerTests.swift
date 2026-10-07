import AppKit
import BestASRMacUI
import Foundation
import XCTest

/// The meeting's caption strip (v12 1C, ALIGNMENT 收2-3): v11 computed the
/// live text of a meeting and showed it nowhere. Synthetic text only; no
/// microphone, no recording.
final class MeetingCaptionPanelControllerTests: XCTestCase {
  private let live = """
    说话人 A  下周三之前把三组数据跑完
    我  好，周五对一下结果
    正在识别  那 cover 第一段
    """

  /// The last two lines, with who said them; the line still being
  /// recognised is marked so it can be drawn lighter.
  func testLastTwoLinesOfTheLiveText() {
    XCTAssertEqual(
      MeetingCaptionLines.last(2, of: live),
      [
        MeetingCaptionLine(speaker: "我", words: "好，周五对一下结果"),
        MeetingCaptionLine(words: "那 cover 第一段", pending: true),
      ])
    XCTAssertEqual(
      MeetingCaptionLines.last(2, of: "说话人 A  下周三之前\n\n说话人 B  好的\n"),
      [
        MeetingCaptionLine(speaker: "说话人 A", words: "下周三之前"),
        MeetingCaptionLine(speaker: "说话人 B", words: "好的"),
      ])
    // Before anyone is told apart: one running line.
    XCTAssertEqual(
      MeetingCaptionLines.last(2, of: "下周三之前把三组数据跑完"),
      [MeetingCaptionLine(words: "下周三之前把三组数据跑完")])
    // Two spaces inside a sentence are not a name.
    XCTAssertEqual(
      MeetingCaptionLines.last(2, of: "第一段  删两句"), [MeetingCaptionLine(words: "第一段  删两句")])
    XCTAssertEqual(MeetingCaptionLines.last(2, of: "  \n "), [])
  }

  /// A panel that never takes the focus from the meeting App, takes clicks
  /// (drag, ✕), and shows the live lines while it records.
  @MainActor
  func testStripShowsTheLiveLinesWithoutTakingTheFocus() {
    _ = NSApplication.shared
    let controller = MeetingCaptionPanelController()
    controller.update(.listening, text: "")
    XCTAssertTrue(controller.isShown)
    XCTAssertTrue(controller.panel.isVisible)
    XCTAssertFalse(controller.panel.canBecomeKey)
    XCTAssertFalse(controller.panel.canBecomeMain)
    XCTAssertFalse(controller.panel.ignoresMouseEvents)
    XCTAssertTrue(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertEqual(controller.presentation.lines, [])
    XCTAssertTrue(controller.presentation.live)
    XCTAssertNil(controller.presentation.status)

    controller.update(.listening, text: live)
    XCTAssertEqual(controller.presentation.lines.count, 2)
    controller.update(.paused, text: live)
    XCTAssertEqual(controller.presentation.status, "已暂停")
    XCTAssertFalse(controller.presentation.live)
    controller.hide()
    XCTAssertFalse(controller.panel.isVisible)
  }

  /// 结束并保存: 「正在转成文字」 over the last live lines, then the
  /// recomputed text with 「已收好」, gone by itself.
  @MainActor
  func testEndingShowsTheRecomputedTextThenGoes() async throws {
    _ = NSApplication.shared
    let controller = MeetingCaptionPanelController()
    controller.savedSeconds = 0.2
    controller.update(.listening, text: live)
    controller.update(.saving)
    XCTAssertEqual(controller.presentation.status, "正在转写")
    XCTAssertEqual(
      controller.presentation.lines.last, MeetingCaptionLine(words: "那 cover 第一段", pending: true),
      "the last live lines stay while it is saved")
    controller.update(.saved, text: "下周三之前把三组数据跑完。好，周五对一下结果。")
    XCTAssertEqual(controller.presentation.status, "已保存")
    XCTAssertEqual(
      controller.presentation.lines, [MeetingCaptionLine(words: "下周三之前把三组数据跑完。好，周五对一下结果。")])
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertFalse(controller.isShown)
    XCTAssertFalse(controller.panel.isVisible)
  }

  /// What happened, in two plain lines, when there is no text yet.
  @MainActor
  func testEndingWithoutTextSaysWhatHappened() {
    _ = NSApplication.shared
    let controller = MeetingCaptionPanelController()
    controller.update(.waitingForModels)
    XCTAssertEqual(
      controller.presentation.lines.map(\.words), ["录音已保存", "识别模型就绪后开始转写"])
    controller.update(.failed)
    XCTAssertEqual(
      controller.presentation.lines.map(\.words), ["无法转写，录音已保存", "可以在“历史”中重试"])
    XCTAssertNil(controller.presentation.status)
    controller.hide()
  }

  /// ✕ hides the strip and tells the App: while the meeting records it
  /// turns the strip off; on an ending it only puts that ending away.
  @MainActor
  func testCloseHidesAndTellsTheApp() {
    _ = NSApplication.shared
    let controller = MeetingCaptionPanelController()
    var closed: [Bool] = []
    controller.onClose = { closed.append($0) }
    controller.update(.listening, text: live)
    controller.close()
    XCTAssertFalse(controller.isShown)
    XCTAssertFalse(controller.panel.isVisible)
    controller.update(.paused, text: live)
    controller.close()
    controller.update(.saving)
    controller.close()
    controller.update(.saved, text: "下周三之前把三组数据跑完。")
    controller.close()
    controller.update(.failed)
    controller.close()
    XCTAssertEqual(closed, [true, true, false, false, false])
  }

  /// Bottom centre of the screen by default, above the Dock; where the user
  /// dragged it when that place is still on a screen (pulled inside it).
  func testWhereTheStripSits() {
    let screen = CGRect(x: 0, y: 80, width: 1440, height: 795)
    let size = MeetingCaptionPanelController.panelSize
    let standard = MeetingCaptionPanelController.frame(
      saved: nil, visibleFrames: [screen], active: screen)
    XCTAssertEqual(standard.midX, screen.midX, accuracy: 1)
    XCTAssertEqual(standard.minY, screen.minY + MeetingCaptionPanelController.bottomInset)
    XCTAssertEqual(standard.size, size)

    let kept = MeetingCaptionPanelController.frame(
      saved: CGPoint(x: 100, y: 600), visibleFrames: [screen], active: screen)
    XCTAssertEqual(kept.origin, CGPoint(x: 100, y: 600))
    let pulledIn = MeetingCaptionPanelController.frame(
      saved: CGPoint(x: 1400 - size.width / 2, y: 600), visibleFrames: [screen], active: screen)
    XCTAssertEqual(pulledIn.maxX, screen.maxX)
    let offScreen = MeetingCaptionPanelController.frame(
      saved: CGPoint(x: 5000, y: 5000), visibleFrames: [screen], active: screen)
    XCTAssertEqual(offScreen, standard)
  }

  /// A drag (the window server moves the panel) is kept; the controller's
  /// own placing is not.
  @MainActor
  func testAMoveIsKept() {
    _ = NSApplication.shared
    var saved: [CGPoint] = []
    let controller = MeetingCaptionPanelController(
      placement: MeetingCaptionPlacement(load: { nil }, save: { saved.append($0) }))
    controller.update(.listening, text: live)
    XCTAssertEqual(saved, [], "placing it is not a move")
    let target = CGPoint(
      x: controller.panel.frame.minX + 40, y: controller.panel.frame.minY + 120)
    controller.panel.setFrameOrigin(target)
    XCTAssertEqual(saved.last, target)
    controller.hide()
  }
}
