import AppKit
import BestASRDictation
import BestASRDomain
import BestASRMacUI
import Foundation
import XCTest

final class RecordingStatusPresentationTests: XCTestCase {
  @MainActor
  func testCapsuleIsNonActivatingAcrossVisibleDictationPhases() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    for phase in [
      DictationPhase.preparing, .recording, .paused, .finalizing, .recognizing,
      .polishing, .inserting, .cancelling, .completed, .failedRecoverable,
    ] {
      controller.render(try panelSnapshot(phase: phase))
      XCTAssertTrue(controller.panel.isVisible, "Expected visible capsule for \(phase)")
      XCTAssertFalse(controller.panel.canBecomeKey)
      XCTAssertFalse(controller.panel.canBecomeMain)
      XCTAssertFalse(controller.panel.isKeyWindow)
    }
    controller.render(try panelSnapshot(phase: .idle))
    XCTAssertFalse(controller.panel.isVisible)
    controller.dismiss()
  }

  @MainActor
  func testCapsuleStaysSmallAtTheBottomAndDoesNotGrowOnHover() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording))
    let collapsed = controller.panel.frame
    XCTAssertLessThanOrEqual(collapsed.width, 80)
    XCTAssertLessThanOrEqual(collapsed.height, 32)
    if let screen = NSScreen.main?.visibleFrame {
      XCTAssertLessThan(collapsed.minY - screen.minY, 40, "Capsule must sit at the bottom")
    }
    // Hovering reveals nothing while a dictation runs: the capsule carries no
    // controls, so it must not change size under the pointer.
    controller.setHovering(true)
    XCTAssertEqual(controller.panel.frame.width, collapsed.width)
    controller.setHovering(false)
    XCTAssertEqual(controller.panel.frame.width, collapsed.width)
    controller.dismiss()
  }

  @MainActor
  func testSubtitleShowsByDefaultAndCanRequireHover() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording), liveText: "第一句。第二句正在说")
    let draft = try draftLabel(controller)
    XCTAssertFalse(draft.superview?.isHidden ?? true, "Subtitle is visible without hover")
    XCTAssertEqual(draft.stringValue, "第二句正在说")

    controller.subtitlesRequireHover = true
    XCTAssertTrue(draft.superview?.isHidden ?? false)
    controller.setHovering(true)
    XCTAssertFalse(draft.superview?.isHidden ?? true)
    controller.dismiss()
  }

  /// A result that did not reach its field is already on the clipboard by
  /// the time the capsule says so. A copy button beside "已复制" repeated
  /// what had happened and made the user wonder whether it had.
  @MainActor
  func testUninsertedResultSaysSoWithoutAButton() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    let retained = try panelSnapshot(
      phase: .completed,
      insertion: DictationInsertionResult(
        idempotencyKey: try DictationIdempotencyKey("capsule-copy"),
        method: .retainedForCopy,
        inserted: false,
        failureReason: .nowhere
      )
    )
    controller.render(retained, compactStatus: "已复制 · ⌘V 粘贴")
    XCTAssertEqual(
      controller.renderedMode,
      .message(symbol: "doc.on.clipboard", text: "已复制 · ⌘V 粘贴", opensRecord: true))
    let views = controller.panel.contentView?.subviewsRecursive ?? []
    let identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })
    XCTAssertFalse(identifiers.contains("bestASR.copyTranscript"))
    controller.dismiss()
  }

  @MainActor
  func testRunningDictationOffersNoPointerControls() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording))
    controller.setHovering(true)
    // Cancel, pause and finish were removed: everything they did is on the
    // keyboard, and a 22-point target in the corner of the screen is not a
    // control anyone reaches for mid-sentence.
    let views = controller.panel.contentView?.subviewsRecursive ?? []
    let identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })
    for identifier in ["bestASR.pauseResume", "bestASR.end", "bestASR.cancel"] {
      XCTAssertFalse(identifiers.contains(identifier), "\(identifier) should be gone")
    }
    controller.render(try panelSnapshot(phase: .finalizing))
    XCTAssertEqual(controller.renderedMode, .processing)
    controller.dismiss()
  }

  @MainActor
  func testFinishedStatesUseCompactMessages() throws {
    let inserted = try panelSnapshot(
      phase: .completed,
      insertion: DictationInsertionResult(
        idempotencyKey: try DictationIdempotencyKey("capsule-inserted"),
        method: .accessibilityReplacement,
        inserted: true
      )
    )
    XCTAssertEqual(RecordingCapsuleMode.resolve(inserted, compactStatus: ""), .inserted)

    let copied = try panelSnapshot(
      phase: .completed,
      insertion: DictationInsertionResult(
        idempotencyKey: try DictationIdempotencyKey("capsule-copied"),
        method: .retainedForCopy,
        inserted: false,
        failureReason: .nowhere
      )
    )
    XCTAssertEqual(
      RecordingCapsuleMode.resolve(copied, compactStatus: "已复制 · ⌘V 粘贴"),
      .message(symbol: "doc.on.clipboard", text: "已复制 · ⌘V 粘贴", opensRecord: true)
    )
    XCTAssertEqual(
      RecordingCapsuleMode.resolve(try panelSnapshot(phase: .failedRecoverable), compactStatus: ""),
      .message(symbol: "exclamationmark.circle", text: "处理失败，原音已保存", opensRecord: true)
    )
  }
}

final class DictationAccessibilityTests: XCTestCase {
  @MainActor
  func testCapsuleControlsKeepStableAccessibleNames() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording), liveText: "Committed local draft")
    controller.setHovering(true)
    let views = controller.panel.contentView?.subviewsRecursive ?? []
    let identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })
    for identifier in ["bestASR.liveTranscript", "bestASR.recordingState"] {
      XCTAssertTrue(identifiers.contains(identifier), "Missing \(identifier)")
    }
    XCTAssertEqual(try draftLabel(controller).accessibilityLabel(), "本机实时草稿")
    controller.dismiss()
  }

  func testLatestSentenceKeepsOnlyTheTail() {
    XCTAssertEqual(RecordingStatusPanelController.latestSentence("你好。今天开会"), "今天开会")
    XCTAssertEqual(
      RecordingStatusPanelController.latestSentence(String(repeating: "长", count: 50)).count, 40)
  }
}

extension NSView {
  fileprivate var subviewsRecursive: [NSView] {
    subviews + subviews.flatMap(\.subviewsRecursive)
  }
}

@MainActor
private func button(
  _ controller: RecordingStatusPanelController,
  _ identifier: String
) throws -> NSButton {
  try XCTUnwrap(
    (controller.panel.contentView?.subviewsRecursive ?? [])
      .compactMap { $0 as? NSButton }
      .first { $0.accessibilityIdentifier() == identifier }
  )
}

@MainActor
private func draftLabel(_ controller: RecordingStatusPanelController) throws -> NSTextField {
  try XCTUnwrap(
    (controller.panel.contentView?.subviewsRecursive ?? [])
      .compactMap { $0 as? NSTextField }
      .first { $0.accessibilityIdentifier() == "bestASR.liveTranscript" }
  )
}

private func panelSnapshot(
  phase: DictationPhase,
  insertion: DictationInsertionResult? = nil
) throws -> DictationSessionSnapshot {
  let target = DictationTargetSnapshot(
    processIdentifier: 42, bundleIdentifier: "com.example.editor", isSecure: false)
  return DictationSessionSnapshot(
    sessionID: SessionID(
      UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    ),
    revision: 1,
    phase: phase,
    target: target,
    transcript: phase == .completed
      ? DictationTranscriptResult(
        revisionID: TranscriptRevisionID(),
        segmentIDs: [],
        text: "fixture",
        modelArtifactID: "fixture"
      ) : nil,
    polish: nil,
    insertion: insertion
  )
}
