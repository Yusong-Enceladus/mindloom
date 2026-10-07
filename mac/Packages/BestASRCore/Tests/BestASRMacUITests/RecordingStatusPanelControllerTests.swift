import AppKit
import BestASRDictation
import BestASRDomain
import BestASRMacUI
import Foundation
import XCTest

/// The fn HUD (MAC-SPEC §8; v12 B1, ALIGNMENT 收1-9 – 收1-21). Driven by
/// snapshots and a synthetic level only: no microphone.
final class RecordingStatusPresentationTests: XCTestCase {
  /// A non-activating, click-through panel; the listener is pressed when
  /// listening starts and cancelled when the take goes away.
  @MainActor
  func testHUDIsNonActivatingAndFollowsTheTake() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording))
    controller.updateInputLevel(dBFS: -24)
    XCTAssertTrue(controller.panel.isVisible)
    XCTAssertFalse(controller.panel.canBecomeKey)
    XCTAssertFalse(controller.panel.canBecomeMain)
    XCTAssertTrue(controller.panel.ignoresMouseEvents)
    XCTAssertNotNil(controller.presentation.listener.pressedAt)
    XCTAssertNil(controller.presentation.listener.releasedAt)
    controller.render(try panelSnapshot(phase: .finalizing))
    XCTAssertEqual(controller.renderedMode, .processing)
    XCTAssertNotNil(controller.presentation.listener.releasedAt)
    XCTAssertFalse(controller.presentation.listener.isCancelled)
    controller.dismiss()

    controller.render(try panelSnapshot(phase: .recording))
    controller.render(try panelSnapshot(phase: .idle))
    XCTAssertTrue(controller.presentation.listener.isCancelled)
    controller.dismiss()
    XCTAssertFalse(controller.panel.isVisible)
  }

  /// The capsule's centre sits 102 pt above the bottom of the screen.
  @MainActor
  func testHUDSitsAboveTheBottomOfTheScreen() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(try panelSnapshot(phase: .recording))
    let frame = controller.panel.frame
    let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.intersects(frame) })
    let centre =
      frame.minY + RecordingStatusPanelController.panelSize.height
      - RecordingStatusPanelController.hudCentreFromTop
    XCTAssertEqual(centre - screen.frame.minY, 102, accuracy: 1)
    XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 1)
    controller.dismiss()
  }

  /// 收1-17 / 收1-18 (regression): the words show above the HUD during every
  /// take — they used to be hidden whenever a text field had focus at the
  /// press — and the final text replaces them at the end. 口述时显示文字 off
  /// hides them.
  @MainActor
  func testCaptionsShowByDefaultAndEndWithTheFinalText() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    XCTAssertTrue(controller.showsCaptions)
    controller.render(try panelSnapshot(phase: .recording), liveText: "跟高原说一声，cover")
    XCTAssertTrue(controller.presentation.captionShown)
    XCTAssertEqual(controller.presentation.pending, "跟高原说一声，cover")
    XCTAssertEqual(controller.presentation.committed, "")
    controller.render(try panelSnapshot(phase: .recognizing), liveText: "跟高原说一声，cover 第一段")
    controller.render(
      try panelSnapshot(phase: .completed, insertion: insertion(inserted: true)),
      liveText: "跟高原说一声，cover 第一段我又删了两句。")
    XCTAssertTrue(controller.presentation.captionShown)
    XCTAssertEqual(controller.presentation.committed, "跟高原说一声，cover 第一段我又删了两句。")
    XCTAssertEqual(controller.presentation.pending, "")
    controller.dismiss()

    controller.showsCaptions = false
    controller.render(try panelSnapshot(phase: .recording), liveText: "写进备忘录")
    XCTAssertFalse(controller.presentation.captionShown)
    XCTAssertEqual(controller.presentation.pending, "")
    controller.dismiss()
  }

  /// 收1-13: typed in → the HUD closes quietly; only copied → 「已复制 ·
  /// ⌘V 粘贴」 for 2.5 s; nothing heard → 「没有听到」 (and no caption); an
  /// error → one sentence.
  @MainActor
  func testHowATakeEndsIsSaid() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()

    try live(controller) {
      controller.render(
        try panelSnapshot(phase: .completed, insertion: insertion(inserted: true)), liveText: "好")
    }
    XCTAssertEqual(controller.renderedMode, .finished(notice: nil))
    XCTAssertNil(controller.presentation.notice)

    try live(controller) {
      controller.render(
        try panelSnapshot(
          phase: .completed, insertion: insertion(inserted: false, reason: .nowhere)),
        liveText: "好", facts: FnHUDTakeFacts(copied: true))
    }
    let copied = try XCTUnwrap(controller.presentation.notice)
    XCTAssertEqual(copied.kind, .copied)
    XCTAssertEqual("\(copied.text) · \(copied.detail ?? "")", "已拷贝 · ⌘V 粘贴")
    XCTAssertEqual(copied.seconds, 2.5)
    XCTAssertTrue(controller.panel.isVisible)
    XCTAssertTrue(controller.panel.ignoresMouseEvents)

    try live(controller) {
      controller.render(try panelSnapshot(phase: .failedRecoverable, silent: true), liveText: "嗯")
    }
    XCTAssertEqual(controller.presentation.notice?.text, "未检测到语音")
    XCTAssertFalse(controller.presentation.captionShown)

    try live(controller) {
      controller.render(try panelSnapshot(phase: .failedRecoverable), liveText: "")
    }
    XCTAssertEqual(controller.presentation.notice?.kind, .failed)
    XCTAssertEqual(controller.presentation.notice?.text, "无法转写，录音已保存。可以在“历史”中重试")
    controller.dismiss()
  }

  /// "Never show success when nothing was inserted": every finished take
  /// that was not typed in says something, except an 指令 whose answer is
  /// shown in its own panel.
  func testNothingButATypedInTakeClosesQuietly() throws {
    for copied in [false, true] {
      for draft in [false, true] {
        let facts = FnHUDTakeFacts(copied: copied, copiedDraft: draft)
        for reason in [
          DictationInsertionFailureReason.nowhere, .unconfirmed, .secureInput, .applicationChanged,
          .permissionDenied, .unavailable, .ambiguousReservation,
        ] {
          let kept = try panelSnapshot(
            phase: .completed, insertion: insertion(inserted: false, reason: reason))
          XCTAssertNotNil(
            FnHUDPresentation.Notice.ending(for: kept, facts: facts), "\(reason) \(facts)")
        }
        XCTAssertNotNil(
          FnHUDPresentation.Notice.ending(
            for: try panelSnapshot(phase: .failedRecoverable), facts: facts))
        XCTAssertNotNil(
          FnHUDPresentation.Notice.ending(
            for: try panelSnapshot(phase: .failedRecoverable, silent: true), facts: facts))
      }
    }
    let answered = try panelSnapshot(
      phase: .completed, insertion: insertion(inserted: false, reason: .nothingToInsert))
    XCTAssertNil(
      FnHUDPresentation.Notice.ending(for: answered, facts: FnHUDTakeFacts(copied: true)))
    let typed = try panelSnapshot(phase: .completed, insertion: insertion(inserted: true))
    XCTAssertNil(FnHUDPresentation.Notice.ending(for: typed, facts: FnHUDTakeFacts()))
    // Copied without a final text: the draft, said as such.
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(
        for: try panelSnapshot(phase: .failedRecoverable),
        facts: FnHUDTakeFacts(copied: true, copiedDraft: true)),
      .copiedDraft)
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(
        for: try panelSnapshot(
          phase: .completed, insertion: insertion(inserted: false, reason: .nowhere)),
        facts: FnHUDTakeFacts()),
      .notTypedIn)
  }

  /// Review 10-5c S1/S5 (regression): words that were asked for and not
  /// seen in the field may have gone in. Copied, the HUD says 已拷贝; not
  /// copied (the user copied something else since), it says it cannot tell,
  /// never that the words were not typed in.
  func testAnUnconfirmedTakeNeverSaysItWasNotTypedIn() throws {
    let unconfirmed = try panelSnapshot(
      phase: .completed, insertion: insertion(inserted: false, reason: .unconfirmed))
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(for: unconfirmed, facts: FnHUDTakeFacts(copied: true)),
      .copied)
    let kept = try XCTUnwrap(
      FnHUDPresentation.Notice.ending(for: unconfirmed, facts: FnHUDTakeFacts()))
    XCTAssertEqual(kept, .unconfirmedNotCopied)
    XCTAssertEqual(kept.text, "无法确认文字是否已输入，文字已保存在“历史”中")
    XCTAssertFalse(kept.text.contains("未能输入"))
  }

  /// 收1-9: a translation into a language that is not installed went in as
  /// said; the HUD says so (the system's download is offered next).
  func testAnUntranslatedTakeSaysSo() throws {
    let typed = try panelSnapshot(phase: .completed, insertion: insertion(inserted: true))
    let note = try XCTUnwrap(
      FnHUDPresentation.Notice.ending(for: typed, facts: FnHUDTakeFacts(untranslatedLanguage: "日语"))
    )
    XCTAssertEqual(note.kind, .note)
    XCTAssertEqual(note.text, "日语尚未下载，已输入原文")
  }

  /// A record finished from the window (a retry), not a take the HUD
  /// showed, does not pop the HUD.
  @MainActor
  func testOnlyALiveTakeSaysHowItEnded() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.render(
      try panelSnapshot(phase: .completed, insertion: insertion(inserted: false, reason: .nowhere)),
      facts: FnHUDTakeFacts(copied: true))
    XCTAssertNil(controller.presentation.notice)
    XCTAssertFalse(controller.panel.isVisible)
    controller.dismiss()
  }

  /// 收1-9 / 收1-10: the target language (「英」) or 「指令」 on the capsule's
  /// left, changed at once when ⇧ moves to the next language; gone when the
  /// take ends.
  @MainActor
  func testTheModeShowsBesideTheCapsule() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    let recording = try panelSnapshot(phase: .recording)
    controller.render(recording)
    XCTAssertNil(controller.presentation.badge)
    controller.badge = .translation(into: "英语", ready: true)
    controller.render(recording)
    XCTAssertEqual(controller.presentation.badge?.text, "英")
    XCTAssertNil(controller.presentation.badge?.note)
    // ⇧ again while fn is held: the next language, at the next render.
    controller.badge = .translation(into: "日语", ready: false)
    controller.render(recording)
    XCTAssertEqual(controller.presentation.badge?.text, "日")
    XCTAssertEqual(controller.presentation.badge?.note, "未下载")
    XCTAssertEqual(controller.presentation.badge?.label, "翻译成日语，日语尚未下载")
    XCTAssertNotNil(controller.presentation.listener.pressedAt, "the take was not restarted")
    controller.render(try panelSnapshot(phase: .recognizing))
    XCTAssertEqual(controller.presentation.badge?.text, "日")
    controller.render(try panelSnapshot(phase: .completed, insertion: insertion(inserted: true)))
    XCTAssertNil(controller.presentation.badge)
    controller.dismiss()

    XCTAssertEqual(FnHUDPresentation.Badge.command.text, "指令")
    XCTAssertEqual(FnHUDPresentation.Badge.shortName("英语"), "英")
    XCTAssertEqual(FnHUDPresentation.Badge.shortName("简体中文"), "简")
    XCTAssertEqual(FnHUDPresentation.Badge.shortName("繁体中文"), "繁")
    XCTAssertEqual(FnHUDPresentation.Badge.shortName("西班牙语"), "西")
  }

  /// 收1-21 (regression, decided 10/5): a tap shorter than 0.35 s keeps the
  /// take listening hands-free (it used to drop it and show a hint); a hold
  /// ends it on release.
  func testAShortTapKeepsListening() {
    XCTAssertEqual(DictationKeyRelease.after(held: .milliseconds(120)), .keepsListening)
    XCTAssertEqual(DictationKeyRelease.after(held: .milliseconds(349)), .keepsListening)
    XCTAssertEqual(DictationKeyRelease.after(held: .milliseconds(350)), .endsTake)
    XCTAssertEqual(DictationKeyRelease.after(held: .seconds(4)), .endsTake)
    XCTAssertEqual(DictationKeyRelease.holdThreshold, .milliseconds(350))
  }

  /// Review v12-B #11 (regression): a 0.2 s tap whose release is handled
  /// 0.6 s after the press (main-thread work between them) is still a tap:
  /// the key events' own times decide. Without them, the handling times do.
  func testATapDelayedOnTheMainThreadIsStillATap() {
    let held = DictationKeyRelease.heldDuration(
      pressedAt: 100.00, releasedAt: 100.20, handledApart: .milliseconds(600))
    XCTAssertEqual(held, .milliseconds(200))
    XCTAssertEqual(DictationKeyRelease.after(held: held), .keepsListening)
    // A real hold stays a hold however quickly it was handled.
    XCTAssertEqual(
      DictationKeyRelease.after(
        held: DictationKeyRelease.heldDuration(
          pressedAt: 100.0, releasedAt: 101.2, handledApart: .milliseconds(30))), .endsTake)
    // Unknown or impossible times: the handling times.
    XCTAssertEqual(
      DictationKeyRelease.heldDuration(
        pressedAt: nil, releasedAt: 100.2, handledApart: .milliseconds(600)), .milliseconds(600))
    XCTAssertEqual(
      DictationKeyRelease.heldDuration(
        pressedAt: 100.5, releasedAt: 100.2, handledApart: .milliseconds(40)), .milliseconds(40))
  }

  /// Esc: the HUD closes quietly, nothing is said.
  @MainActor
  func testCancellingClosesQuietly() throws {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.badge = .command
    controller.render(try panelSnapshot(phase: .recording), liveText: "算了")
    controller.render(try panelSnapshot(phase: .cancelling))
    XCTAssertTrue(controller.presentation.listener.isCancelled)
    XCTAssertNil(controller.presentation.notice)
    XCTAssertNil(controller.presentation.badge)
    XCTAssertFalse(controller.presentation.captionShown)
    controller.dismiss()
  }

  /// Hints take the HUD's place; only 「去设置」 takes a click.
  @MainActor
  func testHintsAndTheirClicks() {
    _ = NSApplication.shared
    let controller = RecordingStatusPanelController()
    controller.showHint(.fnTaken)
    XCTAssertEqual(controller.presentation.hint, .fnTaken)
    XCTAssertTrue(controller.panel.ignoresMouseEvents)
    XCTAssertTrue(controller.panel.isVisible)
    controller.showHint(.microphoneOff)
    XCTAssertEqual(controller.presentation.hint, .microphoneOff)
    XCTAssertFalse(controller.panel.ignoresMouseEvents)
    controller.dismiss()
    XCTAssertNil(controller.presentation.hint)
  }

  /// The capture's 0…1 level (−50…−10 dBFS) goes back to dBFS for the
  /// listener's gate (−50) and span (34).
  func testLevelMapsBackToDecibels() {
    XCTAssertEqual(RecordingStatusPanelController.dBFS(fromNormalized: 0.5), -30, accuracy: 0.001)
    XCTAssertEqual(RecordingStatusPanelController.dBFS(fromNormalized: 1), -10, accuracy: 0.001)
    XCTAssertLessThan(RecordingStatusPanelController.dBFS(fromNormalized: 0), -50)
  }

  func testLatestSentenceKeepsOnlyTheTail() {
    XCTAssertEqual(
      RecordingStatusPanelController.latestSentence("你好。今天开会", limit: 4), "今天开会")
    XCTAssertEqual(
      RecordingStatusPanelController.latestSentence(String(repeating: "长", count: 50)).count, 40)
    XCTAssertEqual(RecordingStatusPanelController.latestSentence("短句"), "短句")
  }

  /// One live take: listening, then processing, then `end`.
  @MainActor
  private func live(_ controller: RecordingStatusPanelController, end: () throws -> Void) throws {
    controller.dismiss()
    controller.render(try panelSnapshot(phase: .recording), liveText: "说话")
    controller.updateInputLevel(dBFS: -20)
    controller.render(try panelSnapshot(phase: .recognizing), liveText: "说话")
    try end()
  }
}

private func insertion(
  inserted: Bool, reason: DictationInsertionFailureReason? = nil
) throws -> DictationInsertionResult {
  DictationInsertionResult(
    idempotencyKey: try DictationIdempotencyKey("hud-\(inserted)-\(reason?.rawValue ?? "-")"),
    method: inserted ? .clipboardPaste : .retainedForCopy, inserted: inserted, failureReason: reason
  )
}

private func panelSnapshot(
  phase: DictationPhase,
  insertion: DictationInsertionResult? = nil,
  silent: Bool = false
) throws -> DictationSessionSnapshot {
  let target = DictationTargetSnapshot(
    processIdentifier: 42, bundleIdentifier: "com.example.editor", isSecure: false)
  let failure =
    phase == .failedRecoverable
    ? try DictationFailure(
      stage: .recognition, category: silent ? .corruptInput : .transientRuntime,
      code: silent ? "recognition.no-speech-detected" : "recognition.engine-failed",
      retryable: true, recoveryPhase: .recognizing)
    : nil
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
    insertion: insertion,
    failure: failure
  )
}

/// Review v12-B #7: in demo mode the HUD says when a take is not kept; a
/// demo take that is kept says what any take says.
final class DemoHUDNoticeTests: XCTestCase {
  func testADemoTakeSaysWhetherItIsKept() throws {
    let typed = try panelSnapshot(phase: .completed, insertion: insertion(inserted: true))
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(for: typed, facts: FnHUDTakeFacts(leavesLibrary: true)),
      .demoTypedIn)
    XCTAssertEqual(FnHUDPresentation.Notice.demoTypedIn.text, "演示中，此段不保存到历史")
    // Outside demo mode a typed-in take still closes quietly.
    XCTAssertNil(FnHUDPresentation.Notice.ending(for: typed, facts: FnHUDTakeFacts()))
    // The language note matters more.
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(
        for: typed, facts: FnHUDTakeFacts(untranslatedLanguage: "日语", leavesLibrary: true))?.text,
      "日语尚未下载，已输入原文")

    let notTyped = try panelSnapshot(
      phase: .completed, insertion: insertion(inserted: false, reason: .nowhere))
    let copied = try XCTUnwrap(
      FnHUDPresentation.Notice.ending(
        for: notTyped, facts: FnHUDTakeFacts(copied: true, leavesLibrary: true)))
    XCTAssertEqual(copied.kind, .copied)
    XCTAssertEqual("\(copied.text) · \(copied.detail ?? "")", "已拷贝；演示中，此段不保存到历史 · ⌘V 粘贴")
    // Kept demo takes (not typed in, not copied; failed) say what they say anywhere.
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(for: notTyped, facts: FnHUDTakeFacts()), .notTypedIn)
    XCTAssertEqual(
      FnHUDPresentation.Notice.ending(
        for: try panelSnapshot(phase: .failedRecoverable), facts: FnHUDTakeFacts()), .failed)
    for notice in [FnHUDPresentation.Notice.demoTypedIn, .demoCopied] {
      for banned in ["不会", "从不", "安全"] { XCTAssertFalse(notice.text.contains(banned)) }
    }
  }
}
