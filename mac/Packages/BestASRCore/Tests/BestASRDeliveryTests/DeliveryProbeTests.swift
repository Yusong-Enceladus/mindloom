import XCTest

@testable import BestASRDelivery

/// Review 10-5c P4: the probe is compiled into debug builds only.
final class DeliveryProbeBuildTests: XCTestCase {
  func testTheProbeIsCompiledIntoDebugBuildsOnly() {
    #if DEBUG
      #if !MINDLOOM_DELIVERY_PROBE
        XCTFail("a debug build lacks the delivery probe")
      #endif
    #else
      #if MINDLOOM_DELIVERY_PROBE
        XCTFail("a release build carries the delivery probe")
      #endif
    #endif
  }
}

#if MINDLOOM_DELIVERY_PROBE
  /// The delivery probe's plan, vocabulary and output: everything that does
  /// not need another application on the screen.
  final class DeliveryProbeTests: XCTestCase {
    private let check = DeliveryProbe.checkBundleIdentifier

    func testTheProbeRunsOnlyWithItsExplicitArgument() {
      XCTAssertNil(DeliveryProbe.outputDirectory(in: ["/A/bestASR"], bundleIdentifier: check))
      XCTAssertNil(
        DeliveryProbe.outputDirectory(
          in: ["/A/bestASR", "-MindloomDeliveryProbe"], bundleIdentifier: check))
      XCTAssertNil(
        DeliveryProbe.outputDirectory(
          in: ["/A/bestASR", "-MindloomDeliveryProbe", "relative/dir"], bundleIdentifier: check))
      XCTAssertNil(
        DeliveryProbe.outputDirectory(
          in: ["/A/bestASR", "-MindloomNoArm", "YES"], bundleIdentifier: check))
      XCTAssertEqual(
        DeliveryProbe.outputDirectory(
          in: [
            "/A/bestASR", "-BestASRDataRoot", "/tmp/clone", "-MindloomDeliveryProbe", "/tmp/out",
          ], bundleIdentifier: check)?.path,
        "/tmp/out")
    }

    /// Regression (review 10-5c P4): the argument alone started the probe in
    /// any build, so once the product holds the permission any local program
    /// could launch it with the argument and drive other applications with
    /// that permission. Only the check app runs it.
    func testOnlyTheCheckAppRunsTheProbe() {
      let arguments = ["/A/bestASR", "-MindloomDeliveryProbe", "/tmp/out"]
      for identity in [
        "app.mindloom", "app.mindloom.debug", "com.bestasr.app", "com.bestasr.app.debug",
        "com.bestasr.mindloom.preview", "", nil,
      ] as [String?] {
        XCTAssertNil(
          DeliveryProbe.outputDirectory(in: arguments, bundleIdentifier: identity),
          identity ?? "nil")
        XCTAssertFalse(DeliveryProbe.mayRun(bundleIdentifier: identity))
      }
      XCTAssertEqual(check, "com.bestasr.mindloom.check")
      XCTAssertTrue(DeliveryProbe.mayRun(bundleIdentifier: check))
    }

    /// Regression (review 10-5c P1): this build's path wrote to whatever was
    /// in front, and no delivery or clean-up key checked where the keyboard
    /// was. Nothing is sent unless the application under test is in front
    /// with the keyboard on the probe's own surface.
    func testNothingIsSentUnlessTheProbesOwnSurfaceHasTheKeyboard() {
      XCTAssertNil(DeliveryProbe.refusal(frontmost: 42, target: 42, onOwnSurface: true))
      XCTAssertNotNil(DeliveryProbe.refusal(frontmost: 7, target: 42, onOwnSurface: true))
      XCTAssertNotNil(DeliveryProbe.refusal(frontmost: nil, target: 42, onOwnSurface: true))
      XCTAssertNotNil(DeliveryProbe.refusal(frontmost: 42, target: 42, onOwnSurface: false))
    }

    /// Regression (review 10-5c P2): closing its VS Code editor, the probe
    /// pressed 「不保存」 on every sheet of every VS Code window, including a
    /// question about the user's own unsaved work that was already open.
    /// Only a question its own close raised, on the window it closed, naming
    /// its own editor, is answered.
    func testOnlyTheQuestionTheProbesOwnCloseRaisedIsAnswered() {
      typealias Facts = DeliveryProbe.DialogFacts
      let raised = Facts(
        existedBefore: false, onOwnWindow: true, isSheet: true, mentionsOwnDocument: true)
      XCTAssertTrue(DeliveryProbe.mayAnswer(raised, mustMention: true))
      var users = raised
      users.existedBefore = true
      XCTAssertFalse(DeliveryProbe.mayAnswer(users, mustMention: true), "already open: the user's")
      var elsewhere = raised
      elsewhere.onOwnWindow = false
      XCTAssertFalse(DeliveryProbe.mayAnswer(elsewhere, mustMention: true), "another window")
      var unnamed = raised
      unnamed.mentionsOwnDocument = false
      XCTAssertFalse(DeliveryProbe.mayAnswer(unnamed, mustMention: true), "names another document")
      // The probe's own new TextEdit document or Terminal window: a sheet on
      // it raised by its close needs no name (Terminal's names none).
      XCTAssertTrue(DeliveryProbe.mayAnswer(unnamed, mustMention: false))
      XCTAssertFalse(DeliveryProbe.mayAnswer(users, mustMention: false))
      // A new dialog window must name the probe's document.
      let window = Facts(
        existedBefore: false, onOwnWindow: false, isSheet: false, mentionsOwnDocument: false)
      XCTAssertFalse(DeliveryProbe.mayAnswer(window, mustMention: true))
      var namedWindow = window
      namedWindow.mentionsOwnDocument = true
      XCTAssertTrue(DeliveryProbe.mayAnswer(namedWindow, mustMention: true))
    }

    /// Regression (review 10-5c P3): every application was asked for its
    /// tree before any trial, so the daily build's first sentence after a
    /// relaunch (no tree yet) was never tried. A Chromium application is
    /// tried cold first; this build's path asks for the tree when the key
    /// goes down and delivers a dictation's length later.
    func testChromiumApplicationsAreTriedColdFirst() {
      for target in DeliveryProbe.targets {
        let phases = DeliveryProbe.phases(for: target)
        if target.chromium {
          XCTAssertEqual(phases, [.cold, .exposure, .warm, .treeDrop], target.name)
        } else {
          XCTAssertFalse(phases.contains(.cold), target.name)
          XCTAssertEqual(phases.last, .warm, target.name)
        }
      }
      XCTAssertGreaterThanOrEqual(DeliveryProbe.dictationSeconds, 1)
      XCTAssertEqual(DeliveryProbe.Phase.treeDrop.rawValue, "tree-drop")
    }

    /// Review 10-5c P5: the user's clipboard is put back after every trial,
    /// unless it holds something the user copied during the run.
    /// Regression (review 10-5d R2): a clipboard with no text — an image or
    /// a screenshot the user copied during the run — was taken for the
    /// probe's, and replaced by the clipboard from the start. Whose it is
    /// goes by the change count the probe noted after its own write; a
    /// clipboard without text is never the probe's.
    func testTheProbeKnowsItsOwnClipboard() {
      let words = DeliveryProbe.probeText(token: "abc123")
      XCTAssertFalse(DeliveryProbe.isProbeClipboard(nil), "an image has no text: not the probe's")
      XCTAssertTrue(DeliveryProbe.clipboardIsProbes(changeCount: 41, probesChangeCount: 41))
      XCTAssertFalse(
        DeliveryProbe.clipboardIsProbes(changeCount: 42, probesChangeCount: 41),
        "changed since the probe's write: the user's copy, whatever it holds")
      XCTAssertFalse(DeliveryProbe.clipboardIsProbes(changeCount: 41, probesChangeCount: nil))
      XCTAssertTrue(DeliveryProbe.isProbeClipboard(""))
      XCTAssertTrue(DeliveryProbe.isProbeClipboard("\n"), "an editor's copy of an empty line")
      XCTAssertTrue(DeliveryProbe.isProbeClipboard(words))
      XCTAssertTrue(DeliveryProbe.isProbeClipboard(DeliveryProbe.priorText(token: "abc123")))
      XCTAssertTrue(DeliveryProbe.isProbeClipboard(" " + words + "\n"))
      XCTAssertFalse(DeliveryProbe.isProbeClipboard("the user's own copy"))
    }

    /// Regression (review 10-5d R1): after a cold trial and after the tree
    /// dropped, the probe found the message box again and emptied it with
    /// ⌘A and Delete when it was not empty, so a draft in another
    /// conversation the user had switched to went with the probe's words.
    /// Keys are pressed only on the element the probe put the keyboard in,
    /// only when it holds exactly the probe's words; otherwise only the
    /// probe's words are taken out through accessibility, and when that is
    /// not possible nothing is done.
    func testOnlyTheProbesOwnWordsAreEverTakenOut() {
      let pieces = DeliveryProbe.pieces(tokens: ["abc123"])
      let words = DeliveryProbe.probeText(token: "abc123")
      let prior = DeliveryProbe.priorText(token: "abc123")
      XCTAssertEqual(
        DeliveryProbe.cleanup(of: words, pieces: pieces, sameElement: true), .selectAllAndDelete)
      XCTAssertEqual(
        DeliveryProbe.cleanup(of: " " + words + "\n", pieces: pieces, sameElement: true),
        .selectAllAndDelete)
      XCTAssertEqual(
        DeliveryProbe.cleanup(of: prior, pieces: pieces, sameElement: true), .selectAllAndDelete,
        "the stand-in for the clipboard is the probe's too")
      // A box found again: never a key, even with only the probe's words.
      XCTAssertEqual(
        DeliveryProbe.cleanup(of: words, pieces: pieces, sameElement: false), .setValue(""))
      // A draft and the probe's words: never ⌘A; the draft stays.
      for same in [true, false] {
        XCTAssertEqual(
          DeliveryProbe.cleanup(of: "明天的草稿 " + words, pieces: pieces, sameElement: same),
          .setValue("明天的草稿"))
        XCTAssertEqual(
          DeliveryProbe.cleanup(of: "draft\n" + words + " more", pieces: pieces, sameElement: same),
          .setValue("draft\n more"))
      }
      // The words re-spaced by the editor cannot be cut out of the draft
      // exactly: nothing is done.
      let respaced = "草稿" + words.replacingOccurrences(of: " ", with: "\u{00A0}")
      XCTAssertEqual(DeliveryProbe.cleanup(of: respaced, pieces: pieces, sameElement: true), .stop)
      // Unreadable: nothing is done. Nothing of the probe's: nothing to do.
      XCTAssertEqual(DeliveryProbe.cleanup(of: nil, pieces: pieces, sameElement: true), .stop)
      XCTAssertEqual(DeliveryProbe.cleanup(of: "", pieces: pieces, sameElement: true), .nothing)
      XCTAssertEqual(DeliveryProbe.cleanup(of: "草稿", pieces: pieces, sameElement: true), .nothing)
      // Two deliveries (after the tree dropped): both are the probe's.
      let two = DeliveryProbe.pieces(tokens: ["abc123", "def456"])
      XCTAssertEqual(
        DeliveryProbe.cleanup(
          of: words + DeliveryProbe.probeText(token: "def456"), pieces: two, sameElement: true),
        .selectAllAndDelete)
      XCTAssertEqual(
        DeliveryProbe.cleanup(
          of: "草稿" + DeliveryProbe.probeText(token: "def456"), pieces: pieces, sameElement: true),
        .nothing, "another trial's words are not this cleanup's")
    }

    /// Review 10-5d R1: the rows that cannot look at the keyboard (the tree
    /// is off on purpose) are sent only while nobody clicked or typed since
    /// the probe put the keyboard on its surface.
    func testABlindRowIsSentOnlyWhileNobodyTouchedTheKeyboardOrMouse() {
      XCTAssertFalse(
        DeliveryProbe.userActed(secondsSinceLastInput: 12, secondsSincePlaced: 3), "untouched")
      XCTAssertTrue(
        DeliveryProbe.userActed(secondsSinceLastInput: 1, secondsSincePlaced: 3),
        "a click or key press after the keyboard was placed")
      XCTAssertFalse(
        DeliveryProbe.userActed(secondsSinceLastInput: .infinity, secondsSincePlaced: 3))
    }

    /// Regression (review 10-5d R3): the switches were put back only when
    /// the probe finished; a probe that crashed or was ended left Claude,
    /// Codex and VS Code with their trees off. They are listed with their
    /// values as found before they are turned, and the check app puts back
    /// what is listed when started with the restore argument.
    func testTurnedSwitchesAreListedForPuttingBack() throws {
      let record = DeliveryProbe.SwitchRecord(
        app: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", processIdentifier: 4242,
        attribute: "AXManualAccessibility", original: true)
      let data = try JSONEncoder().encode([record])
      XCTAssertEqual(
        try JSONDecoder().decode([DeliveryProbe.SwitchRecord].self, from: data), [record])
      XCTAssertEqual(DeliveryProbe.switchesFileName, "switches.json")
      let arguments = ["/A/bestASR", DeliveryProbe.restoreArgument, "/tmp/out"]
      XCTAssertEqual(
        DeliveryProbe.outputDirectory(
          in: arguments, bundleIdentifier: check, argument: DeliveryProbe.restoreArgument)?.path,
        "/tmp/out")
      XCTAssertNil(
        DeliveryProbe.outputDirectory(in: arguments, bundleIdentifier: check),
        "the restore argument does not start a probe")
      XCTAssertNil(
        DeliveryProbe.outputDirectory(
          in: arguments, bundleIdentifier: "app.mindloom",
          argument: DeliveryProbe.restoreArgument), "only the check app")
    }

    /// Regression (review 10-5d R10): a cold row whose application named an
    /// element without text counted as the state after a relaunch, where the
    /// daily build's replica judges 「没写进去」 and cannot show the false
    /// success the user meets (that application names no focused element at
    /// all). Only `focus=none` rows match it, and a message-box application
    /// the probe opened itself is met as a fresh process once per build.
    func testOnlyAColdRowWithNoFocusedElementMatchesARelaunch() {
      XCTAssertTrue(DeliveryProbe.matchesRelaunch(focus: "none"))
      XCTAssertFalse(DeliveryProbe.matchesRelaunch(focus: "no-text"))
      XCTAssertFalse(DeliveryProbe.matchesRelaunch(focus: "text"))
      XCTAssertFalse(DeliveryProbe.matchesRelaunch(focus: "-"))
      for target in DeliveryProbe.targets {
        let relaunched = DeliveryProbe.triesARelaunch(target, openedByProbe: true)
        XCTAssertEqual(relaunched, ["Claude", "Codex"].contains(target.name), target.name)
        XCTAssertFalse(
          DeliveryProbe.triesARelaunch(target, openedByProbe: false),
          "an application the user had open is never quit: \(target.name)")
      }
    }

    /// A second delivery into the same page is judged by what it added.
    @MainActor
    func testASecondDeliveryIntoThePageIsJudgedByWhatItAdded() {
      let one = DeliveryProbe.PageReport(
        scenario: "field", token: "abc123", words: 1, prior: 0, pasteEvents: 1)
      let two = DeliveryProbe.PageReport(
        scenario: "field", token: "abc123", words: 2, prior: 0, pasteEvents: 2)
      let wrong = DeliveryProbe.PageReport(
        scenario: "field", token: "abc123", words: 1, prior: 1, pasteEvents: 2)
      XCTAssertEqual(
        DeliveryProbeRunner.pageDelta(before: nil, after: one, token: "abc123"), .landed)
      XCTAssertEqual(
        DeliveryProbeRunner.pageDelta(before: one, after: two, token: "abc123"), .landed)
      XCTAssertEqual(
        DeliveryProbeRunner.pageDelta(before: one, after: one, token: "abc123"), .absent)
      XCTAssertEqual(
        DeliveryProbeRunner.pageDelta(before: one, after: wrong, token: "abc123"), .priorClipboard)
      XCTAssertEqual(
        DeliveryProbeRunner.pageDelta(before: one, after: two, token: "ffffff"), .unreadable)
    }

    /// The applications the user named, each with a surface that is the
    /// probe's own or found empty; sign-in applications only when open.
    func testThePlanCoversTheNamedApplications() {
      let names = DeliveryProbe.targets.map(\.name)
      for name in [
        "Claude", "VS Code", "Feishu", "WeChat", "Safari", "Chrome", "Notes", "TextEdit",
        "Terminal",
        "Codex",
      ] {
        XCTAssertTrue(names.contains(name), name)
      }
      let wechat = DeliveryProbe.targets.first { $0.name == "WeChat" }
      XCTAssertEqual(wechat?.launchIfNeeded, false)
      XCTAssertEqual(wechat?.surface, .searchField)
      XCTAssertEqual(DeliveryProbe.targets.first { $0.name == "Claude" }?.surface, .composer)
      XCTAssertTrue(DeliveryProbe.targets.filter(\.chromium).map(\.name).contains("Claude"))
      XCTAssertEqual(DeliveryProbe.Variant.allCases, [.daily, .current])
    }

    func testTheWordsAreSyntheticAndDistinctPerTrial() {
      let a = DeliveryProbe.token()
      let b = DeliveryProbe.token()
      XCTAssertEqual(a.count, 6)
      XCTAssertNotEqual(a, b)
      XCTAssertTrue(DeliveryProbe.probeText(token: a).hasPrefix("mlprobe \(a) "))
      XCTAssertFalse(
        LandingEvidence.comparable(DeliveryProbe.priorText(token: a))
          .contains(LandingEvidence.comparable(DeliveryProbe.probeText(token: a))))
    }

    func testWhatTheFieldShowsIsReadByTheWords() {
      let words = DeliveryProbe.probeText(token: "abc123")
      let prior = DeliveryProbe.priorText(token: "abc123")
      XCTAssertEqual(
        DeliveryProbe.observed(before: "", after: " " + words, probeText: words, priorText: prior),
        .landed)
      XCTAssertEqual(
        DeliveryProbe.observed(before: "", after: prior, probeText: words, priorText: prior),
        .priorClipboard)
      XCTAssertEqual(
        DeliveryProbe.observed(before: "x", after: "x", probeText: words, priorText: prior), .absent
      )
      XCTAssertEqual(
        DeliveryProbe.observed(before: "", after: nil, probeText: words, priorText: prior),
        .unreadable)
    }

    /// The failure the user reports is the claim 「写进去了」 with nothing in
    /// the field; the earlier clipboard arriving instead is its own failure.
    func testVerdicts() {
      XCTAssertEqual(DeliveryProbe.verdict(claimedInserted: true, observed: .landed), .landed)
      XCTAssertEqual(DeliveryProbe.verdict(claimedInserted: true, observed: .absent), .falseSuccess)
      XCTAssertEqual(DeliveryProbe.verdict(claimedInserted: false, observed: .absent), .kept)
      XCTAssertEqual(
        DeliveryProbe.verdict(claimedInserted: false, observed: .landed), .landedButKept)
      XCTAssertEqual(
        DeliveryProbe.verdict(claimedInserted: true, observed: .priorClipboard), .wrongContent)
      XCTAssertEqual(
        DeliveryProbe.verdict(claimedInserted: false, observed: .unreadable), .unverified)
      XCTAssertEqual(DeliveryProbe.Verdict.falseSuccess.rawValue, "FALSE-SUCCESS")
    }

    func testClipboardAfterATrial() {
      let words = DeliveryProbe.probeText(token: "abc123")
      let prior = DeliveryProbe.priorText(token: "abc123")
      XCTAssertEqual(
        DeliveryProbe.clipboardAfter(" " + words, probeText: words, priorText: prior), .words)
      XCTAssertEqual(
        DeliveryProbe.clipboardAfter(prior, probeText: words, priorText: prior), .prior)
      XCTAssertEqual(DeliveryProbe.clipboardAfter(nil, probeText: words, priorText: prior), .empty)
      XCTAssertEqual(DeliveryProbe.clipboardAfter("x", probeText: words, priorText: prior), .other)
    }

    func testThePageReportsInItsTitle() {
      let report = DeliveryProbe.pageReport(
        fromTitle: "MLPROBE no-field t=abc123 words=0 prior=0 paste=1 - Google Chrome")
      XCTAssertEqual(
        report,
        DeliveryProbe.PageReport(
          scenario: "no-field", token: "abc123", words: 0, prior: 0, pasteEvents: 1))
      XCTAssertEqual(DeliveryProbe.observed(page: report), .absent)
      XCTAssertNil(DeliveryProbe.pageReport(fromTitle: "Google"))
      XCTAssertNil(
        DeliveryProbe.pageReport(fromTitle: "MLPROBE field t=abc words=x prior=0 paste=0"))
      let html = DeliveryProbe.pageHTML(scenario: .rich, token: "abc123<\'/>")
      XCTAssertTrue(html.contains("<title>MLPROBE rich t=abc123 words=0 prior=0 paste=0</title>"))
      XCTAssertFalse(html.contains("<'/>"))
      XCTAssertTrue(html.contains("target = 'r'"))
      XCTAssertTrue(html.contains(#"/[\s\u200B-\u200D\u2060\uFEFF\uFFFC]/g"#))
    }

    func testTheMatrixIsOneTabSeparatedLinePerTrial() {
      var row = DeliveryProbe.Row(
        app: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", appVersion: "1",
        surface: "composer", scenario: "rich", variant: "current", focus: "text",
        claim: "inserted", detail: "field", observed: "landed", verdict: "ok-landed",
        clipboardAfter: "prior", deliverMilliseconds: 420, waitMilliseconds: 61, note: "a\tb\nc")
      let tsv = DeliveryProbe.tsv([row])
      let lines = tsv.split(separator: "\n")
      XCTAssertEqual(lines.count, 2)
      XCTAssertEqual(lines[0].split(separator: "\t").count, DeliveryProbe.tsvHeader.count)
      XCTAssertEqual(
        lines[1].split(separator: "\t", omittingEmptySubsequences: false).count,
        DeliveryProbe.tsvHeader.count)
      XCTAssertTrue(lines[1].hasSuffix("420\t61\ta b c"))
      row.deliverMilliseconds = nil
      XCTAssertTrue(DeliveryProbe.tsv([row]).contains("\t-\t61\t"))
    }

    /// The probe closes a VS Code untitled editor only by its exact name in
    /// the window title, so an untitled editor of the user's own is never the
    /// one closed without saving.
    @MainActor
    func testTheEditorIsNamedByTheWindowTitle() {
      XCTAssertEqual(
        DeliveryProbeRunner.editorName("● Untitled-2 — notes — Visual Studio Code"), "Untitled-2")
      XCTAssertEqual(
        DeliveryProbeRunner.editorName("Untitled-2 - Visual Studio Code"), "Untitled-2")
      XCTAssertEqual(DeliveryProbeRunner.editorName("无标题-1 — Visual Studio Code"), "无标题-1")
      XCTAssertNil(DeliveryProbeRunner.editorName(nil))
      XCTAssertNotEqual(
        DeliveryProbeRunner.editorName("● Untitled-1 — notes — Visual Studio Code"),
        DeliveryProbeRunner.editorName("Untitled-2 — notes — Visual Studio Code"))
    }

    func testTheDelivererLogLineIsReadByItsFields() {
      let fields = DeliveryProbe.logFields(
        "delivery app=com.anthropic.claudefordesktop outcome=delivered evidence=field focus=text wait_ms=61"
      )
      XCTAssertEqual(fields["focus"], "text")
      XCTAssertEqual(fields["wait_ms"], "61")
      XCTAssertEqual(fields["outcome"], "delivered")
    }
  }
#endif
