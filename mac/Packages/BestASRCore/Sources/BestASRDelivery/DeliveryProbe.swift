#if MINDLOOM_DELIVERY_PROBE
  import Foundation

  /// The delivery probe: drives real applications through the production
  /// delivery path and records, for each, what the deliverer claimed and what
  /// the field then actually shows.
  ///
  /// It is compiled only into debug builds (`MINDLOOM_DELIVERY_PROBE`, set for
  /// the debug configuration in Package.swift; the App calls it under
  /// `#if DEBUG`), and runs only in the check app (bundle identifier
  /// `com.bestasr.mindloom.check`) launched with
  /// `-MindloomDeliveryProbe <absolute directory>`: the product and the
  /// preview never carry it, so no other program can borrow their
  /// permission to drive other applications through it (review 10-5c P4).
  /// It runs only when the check app already has the permission macOS 27
  /// calls 「设备控制和数据访问」 (it never asks for it). It never touches the
  /// user's documents: it writes only into surfaces it made itself or that it
  /// found empty — a new document, a new Terminal window, its own local page,
  /// an empty message box that it never sends, an empty search field — and
  /// leaves each as it found it, closing what it made without saving. Before
  /// every delivery and every key it sends to clean up, the application under
  /// test must be in front with the keyboard on the probe's own surface
  /// (review 10-5c P1). The rows that keep the tree off on purpose cannot see
  /// the keyboard; they check that nobody clicked or typed since and rely on
  /// the user not touching the keyboard or the mouse (`userActed`, review
  /// 10-5d R1). A message box is emptied by keys only when it is the
  /// element the probe put the keyboard in and holds exactly the probe's
  /// words (`cleanup`). The words are synthetic. The user's clipboard is put
  /// back after every trial, and the front application at the end; a copy
  /// the user makes during the run is kept (`clipboardIsProbes`, R2). The
  /// accessibility switches it turns are listed before they are turned and
  /// put back at the end, or by `restoreArgument` when it did not finish
  /// (`SwitchRecord`, R3).
  ///
  /// This file is the part that decides nothing about the screen: the plan,
  /// the vocabulary of the matrix, the classification and the files written.
  /// `DeliveryProbeRunner` does the driving.
  public enum DeliveryProbe {
    public static let launchArgument = "-MindloomDeliveryProbe"
    /// The only App identity the probe runs in: the check app.
    public static let checkBundleIdentifier = "com.bestasr.mindloom.check"

    /// Whether a process with this bundle identifier may run the probe.
    public static func mayRun(bundleIdentifier: String?) -> Bool {
      bundleIdentifier == checkBundleIdentifier
    }

    /// Puts back the accessibility switches a probe that did not finish left
    /// turned (`switchesFileName` in that probe's output directory; review
    /// 10-5d R3), and does nothing else.
    public static let restoreArgument = "-MindloomDeliveryProbeRestore"

    /// The output directory named after the launch argument; nil when the
    /// argument is absent or not followed by an absolute path, or when this
    /// is not the check app.
    public static func outputDirectory(
      in arguments: [String], bundleIdentifier: String?, argument: String = launchArgument
    ) -> URL? {
      guard mayRun(bundleIdentifier: bundleIdentifier),
        let index = arguments.firstIndex(of: argument),
        arguments.indices.contains(index + 1)
      else { return nil }
      let path = arguments[index + 1]
      guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where the probe writes in a target application.
    public enum Surface: String, Codable, Sendable {
      /// ⌘N: a new untitled document (TextEdit, VS Code), emptied and closed
      /// without saving.
      case newDocument = "new-document"
      /// ⌘N: a new Terminal window; the typed line is cleared (never run)
      /// and the window closed.
      case newWindow = "new-window"
      /// The probe's own local page, one tab per trial, closed after.
      case probePage = "probe-page"
      /// The message box of a chat application, used only when it is empty;
      /// never sent, emptied after.
      case composer
      /// The search field, used only when it is empty; emptied after.
      case searchField = "search-field"
    }

    public struct Target: Equatable, Sendable {
      public let name: String
      public let bundleIdentifiers: [String]
      public let surface: Surface
      /// Chromium inside (Chrome, Electron): tried cold first (no tree yet),
      /// and checked for a tree that is dropped after input with no assistive
      /// use.
      public let chromium: Bool
      /// Opened by the probe when it is not running, and quit at the end.
      /// Claude and Codex keep their sign-in and are opened too (a freshly
      /// opened process is the cold state the daily build fails in). WeChat
      /// and Feishu are probed only when the user already has them open.
      public let launchIfNeeded: Bool
      public let scenarios: [Scenario]
    }

    /// What the field looks like when the words are delivered.
    public enum Scenario: String, Codable, Sendable {
      /// A plain text field or document has the keyboard.
      case field
      /// A rich editor (contenteditable) has the keyboard.
      case rich
      /// Nothing editable has the keyboard (a button does).
      case noField = "no-field"
    }

    /// The order of an application's trials. A Chromium application is tried
    /// cold first, before the probe asks it for anything else: the state the
    /// daily build's first sentence after a relaunch meets (review 10-5c P3).
    public enum Phase: String, Codable, Sendable {
      /// Before any tree is asked for; where the application has the switch
      /// (Electron), with its tree turned off first.
      case cold
      /// Whether the focused element is named, and how soon after asking.
      case exposure
      /// The application's surfaces with its tree on.
      case warm
      /// The tree dropped after input with no assistive use, and a delivery
      /// of each build in that state.
      case treeDrop = "tree-drop"
    }

    public static func phases(for target: Target) -> [Phase] {
      target.chromium ? [.cold, .exposure, .warm, .treeDrop] : [.exposure, .warm]
    }

    /// A message-box application the probe opened itself is quit and opened
    /// again once before its first sentence of each build: a process nothing
    /// has asked for its tree, which is what the daily build meets after a
    /// relaunch (review 10-5d R10). Only there: an application the user had
    /// open is never quit, and VS Code reopens the user's own editors.
    public static func triesARelaunch(_ target: Target, openedByProbe: Bool) -> Bool {
      openedByProbe && target.chromium && target.surface == .composer
    }

    /// How long the probe waits between the key going down (when this build
    /// asks the application for its tree) and the words being ready: the
    /// production timing of a short dictation.
    public static let dictationSeconds: TimeInterval = 2

    /// Why the probe must not send anything now, or nil when it may: the
    /// application under test must be in front and the keyboard on the
    /// probe's own surface. Checked before every delivery and every key sent
    /// to clean up, so that nothing reaches the user's own window when they
    /// click elsewhere during the run (review 10-5c P1).
    public static func refusal(frontmost: Int32?, target: Int32, onOwnSurface: Bool) -> String? {
      guard frontmost == target else { return "another application is in front" }
      guard onOwnSurface else { return "the keyboard is not on the probe's own surface" }
      return nil
    }

    /// Whether the user clicked or typed since the probe put the keyboard on
    /// its surface, `secondsSincePlaced` ago, given how long ago the last
    /// click or key press was. The rows that cannot look at the keyboard
    /// through accessibility — the tree is off on purpose: the cold rows,
    /// the rows after the tree dropped, the presses in between — are sent
    /// only while this is false (review 10-5d R1). It is all they have: they
    /// rely on the user not touching the keyboard or the mouse.
    public static func userActed(
      secondsSinceLastInput: TimeInterval, secondsSincePlaced: TimeInterval
    ) -> Bool {
      secondsSinceLastInput < secondsSincePlaced
    }

    /// Whose the clipboard is: the probe's while its change count is the one
    /// the probe noted after its own last write, the user's once it changed
    /// otherwise — whatever it holds. Review 10-5d R2: a clipboard with no
    /// text (an image, a screenshot copied during the run) was taken for the
    /// probe's, and the user's copy was replaced.
    public static func clipboardIsProbes(changeCount: Int, probesChangeCount: Int?) -> Bool {
      changeCount == probesChangeCount
    }

    /// What the probe may do to take its words out of a message box after a
    /// trial (review 10-5d R1: the box was emptied with ⌘A and Delete when
    /// it was not empty, including a box found again after the tree was
    /// off, which may be another conversation with the user's draft).
    public enum Cleanup: Equatable, Sendable {
      /// Nothing of the probe's is there (the box may hold the user's own
      /// text; it is left as it is).
      case nothing
      /// The box holds the probe's words and nothing else, and it is the
      /// element the probe put the keyboard in: select all and delete.
      case selectAllAndDelete
      /// Take the probe's words out through accessibility, never a key:
      /// the box's value set to this (the rest as it was).
      case setValue(String)
      /// The probe's words cannot be taken out without touching the rest,
      /// or the box cannot be read: nothing is done, and the row says so.
      case stop
    }

    /// The text a trial may leave behind: its words and the stand-in for the
    /// user's clipboard.
    public static func pieces(tokens: [String]) -> [String] {
      tokens.flatMap { [probeText(token: $0), priorText(token: $0)] }
    }

    /// The cleanup for a box that shows `value`, after trials that left at
    /// most `pieces`. Keys are pressed only on `sameElement` (the element
    /// the probe put the keyboard in and checked, never one found again),
    /// and only when its value is exactly the probe's words.
    public static func cleanup(of value: String?, pieces: [String], sameElement: Bool) -> Cleanup {
      guard let value else { return .stop }
      let whole = LandingEvidence.comparable(value)
      if whole.isEmpty { return .nothing }
      let ordered = pieces.filter { !LandingEvidence.comparable($0).isEmpty }
        .sorted { $0.count > $1.count }
      var rest = whole
      for piece in ordered {
        rest = rest.replacingOccurrences(of: LandingEvidence.comparable(piece), with: "")
      }
      if rest == whole { return .nothing }
      if rest.isEmpty { return sameElement ? .selectAllAndDelete : .setValue("") }
      // The probe's words out of the value as it is, with the space a
      // delivery puts before them; what is left must be the rest exactly.
      var kept = value
      for piece in ordered {
        kept = kept.replacingOccurrences(of: " " + piece, with: "")
        kept = kept.replacingOccurrences(of: piece, with: "")
      }
      guard LandingEvidence.comparable(kept) == rest else { return .stop }
      return .setValue(kept)
    }

    /// Whether a cold row met what the daily build meets in the first
    /// sentence after a relaunch: an application that names no focused
    /// element at all (DELIVERY.md 原因 1, `evidence=pasteboard`). A row
    /// whose application named an element without text is a different state,
    /// and its daily build replica judges 「没写进去」 there; it cannot show the
    /// false success (review 10-5d R10).
    public static func matchesRelaunch(focus: String) -> Bool {
      focus == "none"
    }

    /// An accessibility switch the probe is about to turn, with the value it
    /// found: listed in `switchesFileName` before the switch is turned, and
    /// taken off the list once it is put back. What is still listed when the
    /// probe did not finish is put back by `restoreArgument` (review 10-5d
    /// R3: a probe that crashed or was ended left Claude, Codex and VS Code
    /// with their trees off, and the daily build back at its false success).
    public struct SwitchRecord: Codable, Equatable, Sendable {
      public var app: String
      public var bundleIdentifier: String
      public var processIdentifier: Int32
      public var attribute: String
      /// The value to put back.
      public var original: Bool

      public init(
        app: String, bundleIdentifier: String, processIdentifier: Int32, attribute: String,
        original: Bool
      ) {
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.attribute = attribute
        self.original = original
      }
    }

    public static let switchesFileName = "switches.json"

    /// A dialog seen after the probe asked to close something of its own.
    public struct DialogFacts: Equatable, Sendable {
      /// It was there before the probe's own ⌘W or close.
      public var existedBefore: Bool
      /// It is a sheet on the window the probe closed.
      public var onOwnWindow: Bool
      public var isSheet: Bool
      /// Its text names the probe's own document (VS Code's untitled editor).
      public var mentionsOwnDocument: Bool

      public init(
        existedBefore: Bool, onOwnWindow: Bool, isSheet: Bool, mentionsOwnDocument: Bool
      ) {
        self.existedBefore = existedBefore
        self.onOwnWindow = onOwnWindow
        self.isSheet = isSheet
        self.mentionsOwnDocument = mentionsOwnDocument
      }
    }

    /// Whether the probe may answer a dialog with its discarding choice: only
    /// one that its own close raised — new since, a sheet on the window it
    /// closed (naming its document where `mustMention`), or a new dialog
    /// window naming its document. A question that was already on the screen
    /// is the user's and is never answered (review 10-5c P2).
    public static func mayAnswer(_ dialog: DialogFacts, mustMention: Bool) -> Bool {
      guard !dialog.existedBefore else { return false }
      if dialog.isSheet {
        return dialog.onOwnWindow && (!mustMention || dialog.mentionsOwnDocument)
      }
      return dialog.mentionsOwnDocument
    }

    /// Which delivery decides the claim.
    public enum Variant: String, Codable, Sendable, CaseIterable {
      /// The 2026-09-22 build the user runs every day (d54fb45), replicated.
      case daily = "d54fb45"
      /// This build's production path (`DeliveryInsertionPort`).
      case current
    }

    public static let targets: [Target] = [
      Target(
        name: "TextEdit", bundleIdentifiers: ["com.apple.TextEdit"], surface: .newDocument,
        chromium: false, launchIfNeeded: true, scenarios: [.field]),
      Target(
        name: "Notes", bundleIdentifiers: ["com.apple.Notes"], surface: .searchField,
        chromium: false, launchIfNeeded: true, scenarios: [.field]),
      Target(
        name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"], surface: .newWindow,
        chromium: false, launchIfNeeded: true, scenarios: [.field]),
      Target(
        name: "Safari", bundleIdentifiers: ["com.apple.Safari"], surface: .probePage,
        chromium: false, launchIfNeeded: true, scenarios: [.field, .rich, .noField]),
      Target(
        name: "Chrome", bundleIdentifiers: ["com.google.Chrome"], surface: .probePage,
        chromium: true, launchIfNeeded: true, scenarios: [.field, .rich, .noField]),
      Target(
        name: "Claude", bundleIdentifiers: ["com.anthropic.claudefordesktop"], surface: .composer,
        chromium: true, launchIfNeeded: true, scenarios: [.rich, .noField]),
      Target(
        name: "Codex", bundleIdentifiers: ["com.openai.codex"], surface: .composer,
        chromium: true, launchIfNeeded: true, scenarios: [.rich, .noField]),
      Target(
        name: "VS Code", bundleIdentifiers: ["com.microsoft.VSCode"], surface: .newDocument,
        chromium: true, launchIfNeeded: true, scenarios: [.field]),
      Target(
        name: "Feishu",
        bundleIdentifiers: [
          "com.bytedance.lark.Feishu", "com.electron.lark", "com.bytedance.macos.feishu",
        ],
        surface: .searchField, chromium: true, launchIfNeeded: false, scenarios: [.field]),
      Target(
        name: "WeChat", bundleIdentifiers: ["com.tencent.xinWeChat"], surface: .searchField,
        chromium: false, launchIfNeeded: false, scenarios: [.field]),
    ]

    // MARK: Words

    /// A fresh token for one trial: six lowercase hex digits.
    public static func token() -> String {
      String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
    }

    /// The synthetic words one trial delivers.
    public static func probeText(token: String) -> String {
      "mlprobe \(token) 送达测试 delivery"
    }

    /// What the clipboard holds before a trial, standing in for the user's own
    /// clipboard: if it shows up in the field, the earlier clipboard was
    /// pasted instead of the words.
    public static func priorText(token: String) -> String {
      "mlprobe-prior \(token)"
    }

    // MARK: What was seen

    /// What the field shows after a trial, read independently of the
    /// deliverer.
    public enum Observed: String, Codable, Sendable {
      case landed
      case absent
      /// The stand-in for the user's earlier clipboard arrived, not the words.
      case priorClipboard = "prior-clipboard"
      /// The field could not be read back at all.
      case unreadable
    }

    /// Compares the field before and after by the words themselves.
    public static func observed(
      before: String?, after: String?, probeText: String, priorText: String
    ) -> Observed {
      guard let after else { return .unreadable }
      let old = LandingEvidence.comparable(before ?? "")
      let new = LandingEvidence.comparable(after)
      let words = LandingEvidence.comparable(probeText)
      let prior = LandingEvidence.comparable(priorText)
      if LandingEvidence.occurrences(of: words, in: new)
        > LandingEvidence.occurrences(of: words, in: old)
      {
        return .landed
      }
      if LandingEvidence.occurrences(of: prior, in: new)
        > LandingEvidence.occurrences(of: prior, in: old)
      {
        return .priorClipboard
      }
      return .absent
    }

    /// The probe page reports what its field holds in its title, so the
    /// window title (which accessibility always exposes) can be read even
    /// where the page's own tree is not:
    /// `MLPROBE <scenario> t=<token> words=<n> prior=<m> paste=<k>`.
    public struct PageReport: Equatable, Sendable {
      public let scenario: String
      public let token: String
      public let words: Int
      public let prior: Int
      public let pasteEvents: Int
    }

    public static func pageReport(fromTitle title: String) -> PageReport? {
      guard let start = title.range(of: "MLPROBE ") else { return nil }
      let fields = title[start.upperBound...].split(separator: " ")
      guard let scenario = fields.first else { return nil }
      var values: [String: String] = [:]
      for field in fields.dropFirst() {
        let parts = field.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        values[String(parts[0])] = String(parts[1])
      }
      guard let token = values["t"], let words = values["words"].flatMap(Int.init),
        let prior = values["prior"].flatMap(Int.init), let paste = values["paste"].flatMap(Int.init)
      else { return nil }
      return PageReport(
        scenario: String(scenario), token: token, words: words, prior: prior, pasteEvents: paste)
    }

    public static func observed(page: PageReport?) -> Observed {
      guard let page else { return .unreadable }
      if page.words > 0 { return .landed }
      if page.prior > 0 { return .priorClipboard }
      return .absent
    }

    // MARK: Verdicts

    public enum Verdict: String, Codable, Sendable {
      /// Claimed typed in, and the words are there.
      case landed = "ok-landed"
      /// Claimed copied, and the words are not there.
      case kept = "ok-kept"
      /// Claimed typed in, and the words are not there: the failure the user
      /// reports (收1-12).
      case falseSuccess = "FALSE-SUCCESS"
      /// The user's earlier clipboard arrived instead of the words.
      case wrongContent = "WRONG-CONTENT"
      /// The words arrived, but the claim was 「已复制」: honest, and a
      /// usability cost (the user sees both).
      case landedButKept = "landed-but-kept"
      /// The field could not be read back.
      case unverified
    }

    public static func verdict(claimedInserted: Bool, observed: Observed) -> Verdict {
      switch (claimedInserted, observed) {
      case (_, .unreadable): .unverified
      case (_, .priorClipboard): .wrongContent
      case (true, .landed): .landed
      case (true, .absent): .falseSuccess
      case (false, .landed): .landedButKept
      case (false, .absent): .kept
      }
    }

    /// What the clipboard holds right after a trial.
    public enum ClipboardAfter: String, Codable, Sendable {
      case words
      case prior
      case empty
      case other
    }

    public static func clipboardAfter(
      _ string: String?, probeText: String, priorText: String
    ) -> ClipboardAfter {
      guard let string, !string.isEmpty else { return .empty }
      let comparable = LandingEvidence.comparable(string)
      if comparable.contains(LandingEvidence.comparable(probeText)) { return .words }
      if comparable == LandingEvidence.comparable(priorText) { return .prior }
      return .other
    }

    /// Whether the text a delivery or an editor's copy left on the clipboard
    /// is the probe's own — its stand-in, its words, an editor's copy of
    /// them or of an empty line. A clipboard with no text is not (review
    /// 10-5d R2: an image the user copied has none). Who owns the clipboard
    /// is decided by its change count (`clipboardIsProbes`); this only
    /// checks, right after the probe's own write, that nobody wrote in
    /// between.
    public static func isProbeClipboard(_ string: String?) -> Bool {
      guard let string else { return false }
      let comparable = LandingEvidence.comparable(string)
      return comparable.isEmpty || comparable.contains("mlprobe")
    }

    // MARK: The matrix

    public struct Row: Codable, Equatable, Sendable {
      public var app: String
      public var bundleIdentifier: String
      public var appVersion: String
      public var surface: String
      public var scenario: String
      public var variant: String
      /// What the application showed at its keyboard focus before ⌘V:
      /// text / no-text / none, or - when not known.
      public var focus: String
      /// inserted / kept / - (not delivered)
      public var claim: String
      /// The evidence (inserted) or the reason (kept), as the deliverer
      /// named it.
      public var detail: String
      public var observed: String
      public var verdict: String
      public var clipboardAfter: String
      /// From the call to the claim.
      public var deliverMilliseconds: Int?
      /// The deliverer's own wait from ⌘V to its verdict, where it logged one.
      public var waitMilliseconds: Int?
      public var note: String

      public init(
        app: String, bundleIdentifier: String, appVersion: String = "-", surface: String = "-",
        scenario: String = "-", variant: String = "-", focus: String = "-", claim: String = "-",
        detail: String = "-", observed: String = "-", verdict: String = "-",
        clipboardAfter: String = "-", deliverMilliseconds: Int? = nil,
        waitMilliseconds: Int? = nil, note: String = ""
      ) {
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.surface = surface
        self.scenario = scenario
        self.variant = variant
        self.focus = focus
        self.claim = claim
        self.detail = detail
        self.observed = observed
        self.verdict = verdict
        self.clipboardAfter = clipboardAfter
        self.deliverMilliseconds = deliverMilliseconds
        self.waitMilliseconds = waitMilliseconds
        self.note = note
      }
    }

    public static let tsvHeader = [
      "app", "bundle", "version", "surface", "scenario", "variant", "focus", "claim", "detail",
      "observed", "verdict", "clipboard_after", "deliver_ms", "wait_ms", "note",
    ]

    /// One line per row, tab-separated; tabs and line breaks inside a value
    /// become spaces.
    public static func tsv(_ rows: [Row]) -> String {
      func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
      }
      var lines = [tsvHeader.joined(separator: "\t")]
      for row in rows {
        let fields = [
          row.app, row.bundleIdentifier, row.appVersion, row.surface, row.scenario, row.variant,
          row.focus, row.claim, row.detail, row.observed, row.verdict, row.clipboardAfter,
          row.deliverMilliseconds.map(String.init) ?? "-",
          row.waitMilliseconds.map(String.init) ?? "-", row.note,
        ]
        lines.append(fields.map(clean).joined(separator: "\t"))
      }
      return lines.joined(separator: "\n") + "\n"
    }

    /// The fields of the deliverer's own log line (`delivery app=… focus=…
    /// wait_ms=…`): no text is ever in it.
    public static func logFields(_ line: String) -> [String: String] {
      var fields: [String: String] = [:]
      for part in line.split(separator: " ") {
        let pair = part.split(separator: "=", maxSplits: 1)
        if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
      }
      return fields
    }

    // MARK: The probe page

    /// The probe's own page for one trial. The scenario picks which element
    /// has the keyboard: a textarea (field), a contenteditable box (rich), or
    /// a button (no-field). The page reports the words it holds, and how many
    /// paste events it saw, in its title. `token` is six hex digits.
    public static func pageHTML(scenario: Scenario, token: String) -> String {
      let safeToken = String(token.filter { $0.isHexDigit }.prefix(12))
      let element =
        switch scenario {
        case .field: "f"
        case .rich: "r"
        case .noField: "b"
        }
      return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>MLPROBE \(scenario.rawValue) t=\(safeToken) words=0 prior=0 paste=0</title>
        <style>body{font:16px -apple-system,sans-serif;margin:24px}textarea,#r{width:420px;height:80px;border:1px solid #888;padding:6px;display:block;margin:8px 0}</style>
        </head><body>
        <p>Mindloom delivery probe. This page belongs to the probe and is closed when the probe is done.</p>
        <textarea id="f"></textarea>
        <div id="r" contenteditable="true"></div>
        <button id="b" type="button">probe</button>
        <script>
        const scenario = '\(scenario.rawValue)', token = '\(safeToken)', target = '\(element)';
        const norm = s => (s || '').normalize('NFKC').replace(/[\\s\\u200B-\\u200D\\u2060\\uFEFF\\uFFFC]/g, '');
        const words = norm('mlprobe ' + token + ' 送达测试 delivery');
        const prior = norm('mlprobe-prior ' + token);
        const count = (hay, needle) => needle ? hay.split(needle).length - 1 : 0;
        let pastes = 0;
        function report() {
          const all = norm(document.getElementById('f').value) + norm(document.getElementById('r').innerText);
          document.title = 'MLPROBE ' + scenario + ' t=' + token + ' words=' + count(all, words)
            + ' prior=' + count(all, prior) + ' paste=' + pastes;
        }
        function place() { document.getElementById(target).focus(); }
        document.addEventListener('paste', () => { pastes += 1; setTimeout(report, 0); }, true);
        document.addEventListener('input', report, true);
        window.addEventListener('focus', place);
        setInterval(report, 100);
        place();
        report();
        </script>
        </body></html>
        """
    }
  }
#endif
