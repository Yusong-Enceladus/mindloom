#if MINDLOOM_DELIVERY_PROBE
  import AppKit
  import ApplicationServices
  import BestASRDictation
  import BestASRDomain
  import Carbon.HIToolbox
  import Foundation
  import OSLog
  import MindloomIdentity

  /// Drives the delivery probe (see `DeliveryProbe`): for each target
  /// application it opens its own surface, puts the keyboard there through
  /// accessibility, delivers synthetic words through the daily build's replica
  /// and through this build's production path, reads the field back, and
  /// writes one matrix row per trial into the output directory.
  ///
  /// Refuses to start outside the check app, and without the permission
  /// macOS 27 calls 「设备控制和数据访问」; it never asks for it: the request
  /// would put a system prompt on the user's screen.
  ///
  /// What protects the user's own windows (review 10-5c, 10-5d):
  /// - This build's delivery is pinned to the application under test, and
  ///   every key the probe sends goes to that process (P1).
  /// - Before every delivery and every key sent to clean up, that application
  ///   must be in front with the keyboard on the probe's own surface — the
  ///   same element it put the keyboard in (`CFEqual`), still empty before a
  ///   paste; otherwise the row says it was skipped and nothing is sent (P1,
  ///   10-5d R1).
  /// - Where the tree is off on purpose (the cold rows, the rows after the
  ///   tree dropped, the presses in between) the keyboard cannot be seen
  ///   through accessibility, and a look would turn the tree back on. Those
  ///   rows check that the application is in front and that nobody clicked
  ///   or typed since the probe put the keyboard there; beyond that they
  ///   rely on the user not touching the keyboard or the mouse (10-5d R1).
  /// - A message box is emptied with ⌘A and Delete only when it is the
  ///   element the probe put the keyboard in and holds exactly the probe's
  ///   words. Otherwise the probe's words are taken out through
  ///   accessibility (its value set, no key); when that cannot be done, the
  ///   box is left as it is and the row says so (10-5d R1).
  /// - Only a question raised by the probe's own close is answered, and only
  ///   on the window it closed (P2).
  /// - The user's clipboard is put back after every trial; a copy the user
  ///   makes during the run is kept, whatever it holds: the clipboard is the
  ///   probe's only while its change count is the one the probe noted after
  ///   its own write (P5, 10-5d R2).
  /// - The accessibility switches the probe turns are put back as they were
  ///   found, and listed in `switches.json` before they are turned, so that
  ///   a probe that did not finish can have them put back
  ///   (`restoreSwitches`, run by v12-delivery-probe.sh; P5, 10-5d R3).
  @MainActor
  public final class DeliveryProbeRunner {
    public enum ExitCode: Int32 {
      case finished = 0
      case cannotWrite = 1
      case needsAccessibility = 2
      /// Not the check app.
      case refused = 3
      /// Some switches could not be put back (`restoreSwitches`).
      case notRestored = 4
    }

    /// The application under test, which this build's delivery path is
    /// pinned to; nil between applications (nothing is then delivered).
    @MainActor
    final class TargetPin {
      var snapshot: DictationTargetSnapshot?
    }

    private let output: URL
    private let pages: URL
    private var rows: [DeliveryProbe.Row] = []
    private var log: [String] = []
    /// The daily build's delivery as a long-running process: one replica for
    /// the whole run (each process woken once).
    private let daily = DailyDeliveryReplica()
    private let pin: TargetPin
    private let port: DeliveryInsertionPort
    private var launchedByProbe: [NSRunningApplication] = []
    /// Said before every row of the application being probed (how its tree
    /// was turned on, when that was not the production way).
    private var notePrefix = ""
    private let started = Date()
    /// The user's own clipboard, put back after every trial (review 10-5c
    /// P5); replaced by what the user copies during the run.
    private var userClipboard: PasteboardSnapshot?
    /// The clipboard's change count after the probe's own last write, or
    /// after it took a copy of the user's: any other count means the user
    /// copied something since (review 10-5d R2).
    private var knownChangeCount: Int?
    /// The switches turned by the probe and not yet put back, as listed in
    /// `switches.json` (review 10-5d R3).
    private var switchRecords: [DeliveryProbe.SwitchRecord] = []

    private init(output: URL) {
      self.output = output
      pages = output.appendingPathComponent("pages", isDirectory: true)
      let pin = TargetPin()
      self.pin = pin
      port = DeliveryInsertionPort(
        reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
        targetProvider: { pin.snapshot })
    }

    public static func run(outputDirectory: URL) async -> ExitCode {
      await DeliveryProbeRunner(output: outputDirectory).run()
    }

    private func run() async -> ExitCode {
      // The App checks this before calling; the runner checks it again.
      guard DeliveryProbe.mayRun(bundleIdentifier: Bundle.main.bundleIdentifier) else {
        return .refused
      }
      do {
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
      } catch {
        return .cannotWrite
      }
      let trusted = AXIsProcessTrusted()
      let canPost = CGPreflightPostEventAccess()
      writeStatus(state: "started", trusted: trusted, canPost: canPost)
      guard trusted, canPost else {
        let path = Bundle.main.bundlePath
        let message = """
          The delivery probe needs the permission macOS 27 calls "Device Control and Data Access"
          (设备控制和数据访问; earlier versions of macOS called it Accessibility) for this app, and
          stopped without touching anything.
          App: \(path)
          Bundle identifier: \(Bundle.main.bundleIdentifier ?? "-")
          AXIsProcessTrusted: \(trusted)
          CGPreflightPostEventAccess: \(canPost)
          Turn this app on in System Settings > Privacy & Security > Device Control and Data Access
          (“系统设置”>“隐私与安全”>“设备控制和数据访问”), then run the probe again. The probe never
          asks for the permission itself.

          """
        try? message.write(
          to: output.appendingPathComponent("NEEDS-ACCESSIBILITY.txt"), atomically: true,
          encoding: .utf8)
        note("stopped: permission missing (trusted=\(trusted) post=\(canPost))")
        flush()
        writeStatus(state: "needs-accessibility", trusted: trusted, canPost: canPost)
        return .needsAccessibility
      }
      userClipboard = PasteboardSnapshot(pasteboard: .general)
      knownChangeCount = NSPasteboard.general.changeCount
      writeSwitches()
      let front = NSWorkspace.shared.frontmostApplication
      note("started; front application \(front?.bundleIdentifier ?? "-")")
      for target in DeliveryProbe.targets {
        await probe(target)
        flush()
      }
      putBackUserClipboard()
      note("clipboard put back")
      if let front, !front.isTerminated {
        _ = await bringToFront(front)
        note("front application put back")
      }
      for application in launchedByProbe where !application.isTerminated {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
          == application.processIdentifier
        {
          note(
            "left \(application.bundleIdentifier ?? "-") open (opened by the probe): it is in front"
          )
          continue
        }
        application.terminate()
        note("quit \(application.bundleIdentifier ?? "-") (opened by the probe)")
      }
      flush()
      writeStatus(state: "finished", trusted: trusted, canPost: canPost)
      return .finished
    }

    // MARK: One application

    private func probe(_ target: DeliveryProbe.Target) async {
      let installed = target.bundleIdentifiers.lazy.compactMap { identifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map {
          (identifier, $0)
        }
      }.first
      guard let (bundleIdentifier, appURL) = installed else {
        append(
          DeliveryProbe.Row(
            app: target.name, bundleIdentifier: target.bundleIdentifiers.first ?? "-",
            surface: target.surface.rawValue, note: "not installed"))
        return
      }
      let version =
        Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
      var base = DeliveryProbe.Row(
        app: target.name, bundleIdentifier: bundleIdentifier, appVersion: version,
        surface: target.surface.rawValue)
      var application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first
      var launchedNow = false
      if application == nil {
        guard target.launchIfNeeded else {
          base.note = "not running; probed only when the user already has it open"
          append(base)
          return
        }
        application = await launch(appURL)
        if let application {
          launchedByProbe.append(application)
          launchedNow = true
        }
      }
      guard var application else {
        base.note = "could not be opened"
        append(base)
        return
      }
      if DeliveryProbe.triesARelaunch(target, openedByProbe: launchedNow) {
        application = await relaunchTrials(base: base, application: application, appURL: appURL)
      }
      guard await bringToFront(application) else {
        base.note = "could not be brought to the front"
        append(base)
        return
      }
      note("\(target.name): in front")
      let processID = application.processIdentifier
      let app = ProbeAX.application(processID)
      // The switches as found, put back after this application (review 10-5c
      // P5). An application that does not have the manual switch reads nil.
      // They are listed before any is turned, so that a probe that does not
      // finish can have them put back (review 10-5d R3).
      let originalManual = ProbeAX.bool(app, ProbeAX.manualAccessibility)
      let originalEnhanced = ProbeAX.bool(app, ProbeAX.enhancedUserInterface)
      var enhancedByProbe = false
      let record = { (attribute: String, original: Bool) in
        DeliveryProbe.SwitchRecord(
          app: target.name, bundleIdentifier: bundleIdentifier, processIdentifier: processID,
          attribute: attribute, original: original)
      }
      listSwitches(
        [
          originalManual.map { record(ProbeAX.manualAccessibility, $0) },
          originalEnhanced.map { record(ProbeAX.enhancedUserInterface, $0) },
        ].compactMap { $0 })
      pin.snapshot = DictationTargetSnapshot(
        processIdentifier: processID, bundleIdentifier: bundleIdentifier, isSecure: false)
      defer {
        pin.snapshot = nil
        notePrefix = ""
        if let originalManual {
          ProbeAX.set(app, ProbeAX.manualAccessibility, originalManual)
        }
        if let originalEnhanced {
          ProbeAX.set(app, ProbeAX.enhancedUserInterface, originalEnhanced)
        } else if enhancedByProbe {
          ProbeAX.set(app, ProbeAX.enhancedUserInterface, false)
        }
        forgetSwitches(of: processID)
        note(
          "\(target.name): switches put back as found (manual "
            + "\(originalManual.map { $0 ? "on" : "off" } ?? "absent"), enhanced "
            + "\(originalEnhanced.map { $0 ? "on" : "off" } ?? "unreadable")"
            + "\(enhancedByProbe && originalEnhanced == nil ? ", switched off" : ""))")
      }
      // Electron has the manual switch, and so a way to turn its tree off.
      let switchable = originalManual != nil
      for phase in DeliveryProbe.phases(for: target) {
        switch phase {
        case .cold:
          await coldTrials(
            base: base, target: target, application: application, appURL: appURL,
            launchedNow: launchedNow, switchable: switchable)
        case .exposure:
          enhancedByProbe = await exposureCheck(
            base: base, application: application, dropFirst: switchable,
            originalEnhanced: originalEnhanced,
            beforeEnhancing: {
              if originalEnhanced == nil {
                self.listSwitches([record(ProbeAX.enhancedUserInterface, false)])
              }
            })
          if enhancedByProbe {
            notePrefix = "tree on through AXEnhancedUserInterface (probe only)"
          }
        case .warm:
          await warmTrials(
            base: base, target: target, bundleIdentifier: bundleIdentifier,
            application: application, appURL: appURL)
        case .treeDrop:
          await treeDropCheck(base: base, appURL: appURL, application: application, target: target)
        }
      }
    }

    private func warmTrials(
      base: DeliveryProbe.Row, target: DeliveryProbe.Target, bundleIdentifier: String,
      application: NSRunningApplication, appURL: URL
    ) async {
      switch target.surface {
      case .probePage:
        for scenario in target.scenarios {
          for variant in DeliveryProbe.Variant.allCases {
            await pageTrial(
              base: base, appURL: appURL, application: application, scenario: scenario,
              variant: variant)
          }
        }
      case .composer:
        await composerTrials(base: base, application: application, scenarios: target.scenarios)
      case .newDocument where bundleIdentifier == "com.microsoft.VSCode":
        for variant in DeliveryProbe.Variant.allCases {
          await editorTrial(base: base, application: application, variant: variant)
        }
      case .newDocument:
        for variant in DeliveryProbe.Variant.allCases {
          await documentTrial(base: base, application: application, variant: variant)
        }
      case .newWindow:
        await terminalTrials(base: base, application: application)
      case .searchField:
        await searchTrials(
          base: base, application: application,
          findByMenu: bundleIdentifier != "com.apple.Notes")
      }
    }

    // MARK: Cold

    /// The first sentence after a relaunch: the application has not been
    /// asked for its tree (Chrome, before the probe asks it anything) or has
    /// its tree turned off first (Electron's manual switch set off), and the
    /// daily build meets it as a process it has never woken. This build's
    /// path asks for the tree when the key goes down and delivers a
    /// dictation's length later (review 10-5c P3).
    private func coldTrials(
      base: DeliveryProbe.Row, target: DeliveryProbe.Target, application: NSRunningApplication,
      appURL: URL, launchedNow: Bool, switchable: Bool
    ) async {
      let state = launchedNow ? "opened by the probe" : "already running"
      switch target.surface {
      case .probePage:
        for variant in DeliveryProbe.Variant.allCases {
          await pageTrial(
            base: base, appURL: appURL, application: application, scenario: .field,
            variant: variant,
            cold: "\(state); no tree asked for yet; this application has no switch to turn it off")
        }
      case .composer where switchable:
        await coldComposerTrials(base: base, application: application, state: state)
      case .newDocument where switchable:
        for variant in DeliveryProbe.Variant.allCases {
          await editorTrial(base: base, application: application, variant: variant, cold: state)
        }
      case .composer, .newDocument:
        var row = base
        row.scenario = "cold"
        row.note = "this application has no switch to turn its tree off; no cold trial"
        append(row)
      case .newWindow, .searchField:
        var row = base
        row.scenario = "cold"
        row.note = "no cold trial for this surface"
        append(row)
      }
    }

    /// The message box, cold: found and given the keyboard with the tree on,
    /// then the tree turned off, then delivered into; read back with the tree
    /// on again, and cleaned up.
    ///
    /// With the tree off the keyboard cannot be seen through accessibility
    /// (a look would turn the tree back on): it was on the empty message box
    /// a moment before, the paste goes to this application only, and the
    /// application must be in front with no click or key press by the user
    /// since. Beyond that this row relies on the user not touching the
    /// keyboard or the mouse (review 10-5d R1).
    private func coldComposerTrials(
      base: DeliveryProbe.Row, application: NSRunningApplication, state: String
    ) async {
      let app = ProbeAX.application(application.processIdentifier)
      for variant in DeliveryProbe.Variant.allCases {
        var row = base
        row.scenario = "cold"
        row.variant = variant.rawValue
        ProbeAX.requestTree(app)
        guard let composer = await findComposer(app) else {
          row.note = "no message box visible to accessibility; nothing sent"
          append(row)
          return
        }
        guard ProbeAX.isEmptyField(composer) else {
          row.note =
            "the message box holds text (a draft or unreadable); left untouched, nothing sent"
          append(row)
          return
        }
        guard await bringToFront(application), ProbeAX.focus(composer, in: app) else {
          row.note = "could not put the keyboard in the message box; nothing sent"
          append(row)
          continue
        }
        let placed = Date()
        let drop = await dropTree(app)
        let token = DeliveryProbe.token()
        let outcome = await deliver(
          token: token, to: application, variant: variant, replica: DailyDeliveryReplica(),
          onOwnSurface: { self.untouched(since: placed) })
        var notes = ["cold (\(state)); after the tree was switched off: \(drop.seen)"]
        guard case .delivered(let trial) = outcome else {
          if case .skipped(let reason) = outcome {
            notes.append("skipped: \(reason); nothing sent")
          }
          row.note = notes.joined(separator: "; ")
          append(row)
          continue
        }
        fill(&row, with: trial)
        notes.append(Self.relaunchNote(focus: trial.focus))
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        ProbeAX.requestTree(app)
        // The element the keyboard was put in, if the tree that came back
        // still answers for it; otherwise the box found again, which is
        // cleaned only through accessibility (review 10-5d R1).
        let box = await sameOrFoundAgain(composer, app: app)
        let observed = DeliveryProbe.observed(
          before: "", after: box.flatMap { ProbeAX.value($0.element) },
          probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
        let left = await cleanComposer(box, tokens: [token], app: app, application: application)
        if let left {
          notes.append(left + "; the probe stops using it")
          row.note = notes.joined(separator: "; ")
          append(row)
          return
        }
        row.note = notes.joined(separator: "; ")
        append(row)
      }
    }

    /// The row's note on whether a cold row met the state after a relaunch
    /// (review 10-5d R10).
    static func relaunchNote(focus: String) -> String {
      DeliveryProbe.matchesRelaunch(focus: focus)
        ? "matches the state after a relaunch (no focused element named)"
        : "not the state after a relaunch (focus=\(focus)); the daily build's first sentence "
          + "after a relaunch is read from focus=none rows only"
    }

    /// A message-box application the probe opened itself, met as a process
    /// nothing has asked for its tree, once per build (review 10-5d R10):
    /// the daily build in the process the probe just opened, this build in
    /// the same application quit and opened again. The words go where the
    /// freshly opened application put the keyboard (its message box); the
    /// row is sent only while nobody clicked or typed since the application
    /// opened. Read back and cleaned up with the tree on afterwards, through
    /// accessibility only. Returns the application as it is running now.
    private func relaunchTrials(
      base: DeliveryProbe.Row, application first: NSRunningApplication, appURL: URL
    ) async -> NSRunningApplication {
      var application = first
      var opened = Date()
      for (index, variant) in DeliveryProbe.Variant.allCases.enumerated() {
        var row = base
        row.scenario = "relaunch"
        row.variant = variant.rawValue
        if index > 0 {
          guard untouched(since: opened), await relaunch(&application, appURL: appURL) else {
            row.note = "could not quit and open the application again; no relaunch row"
            append(row)
            return application
          }
          opened = Date()
        }
        // A freshly opened window settles its keyboard focus (in front: the
        // probe opened it with activation, and a relaunch brings it there).
        _ = await bringToFront(application)
        try? await Task.sleep(for: .seconds(3))
        let pid = application.processIdentifier
        let token = DeliveryProbe.token()
        pin.snapshot = DictationTargetSnapshot(
          processIdentifier: pid, bundleIdentifier: application.bundleIdentifier,
          isSecure: false)
        let outcome = await deliver(
          token: token, to: application, variant: variant, replica: DailyDeliveryReplica(),
          onOwnSurface: { self.untouched(since: opened) })
        pin.snapshot = nil
        var notes = [
          "a process opened by the probe, its tree never asked for before this sentence"
        ]
        guard case .delivered(let trial) = outcome else {
          if case .skipped(let reason) = outcome {
            notes.append("skipped: \(reason); nothing sent")
          }
          row.note = notes.joined(separator: "; ")
          append(row)
          return application
        }
        fill(&row, with: trial)
        notes.append(Self.relaunchNote(focus: trial.focus))
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let app = ProbeAX.application(pid)
        ProbeAX.requestTree(app)
        let box = await findComposer(app).map { (element: $0, same: false) }
        let observed = DeliveryProbe.observed(
          before: "", after: box.flatMap { ProbeAX.value($0.element) },
          probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
        if let left = await cleanComposer(box, tokens: [token], app: app, application: application)
        {
          notes.append(left)
          row.note = notes.joined(separator: "; ")
          append(row)
          return application
        }
        row.note = notes.joined(separator: "; ")
        append(row)
      }
      return application
    }

    /// Quits an application the probe opened and opens it again; false when
    /// it does not quit or does not come back.
    private func relaunch(_ application: inout NSRunningApplication, appURL: URL) async -> Bool {
      let old = application
      guard old.terminate(), await waitUntil(seconds: 10, { old.isTerminated }) else {
        return false
      }
      launchedByProbe.removeAll { $0.processIdentifier == old.processIdentifier }
      guard let fresh = await launch(appURL) else { return false }
      launchedByProbe.append(fresh)
      application = fresh
      note("\(fresh.bundleIdentifier ?? "-"): quit and opened again by the probe")
      return await bringToFront(fresh)
    }

    /// Turns an Electron application's tree off (the manual switch set off:
    /// the state of a process nobody has asked yet) and waits until it names
    /// no focused element. Says what it names then: a focused element
    /// without text is not the state after a relaunch (review 10-5d R10).
    private func dropTree(_ app: AXUIElement) async -> (dropped: Bool, seen: String) {
      ProbeAX.set(app, ProbeAX.manualAccessibility, false)
      var seen = "-"
      let dropped = await waitUntil(seconds: 3) {
        guard let element = ProbeAX.focusedElement(app) else {
          seen = "names no focused element"
          return true
        }
        let shows = ProbeAX.value(element) != nil
        seen =
          "names \(ProbeAX.role(element) ?? "an element")\(shows ? " with text" : " without text")"
        return false
      }
      return (dropped, seen)
    }

    // MARK: Exposure

    /// Whether the application names its focused element without being
    /// asked, and how soon after asking (for an application with the manual
    /// switch, after turning its tree off first). Returns whether the probe
    /// turned AXEnhancedUserInterface on for the rest of this application.
    private func exposureCheck(
      base: DeliveryProbe.Row, application: NSRunningApplication, dropFirst: Bool,
      originalEnhanced: Bool?, beforeEnhancing: () -> Void
    ) async -> Bool {
      let app = ProbeAX.application(application.processIdentifier)
      var row = base
      row.scenario = "exposure"
      var notes: [String] = []
      if dropFirst {
        let drop = await dropTree(app)
        notes.append("tree switched off first: \(drop.seen)")
      }
      let namedWithoutAsking = ProbeAX.focusedElement(app) != nil
      var namedAfterAsking = namedWithoutAsking
      if !namedWithoutAsking {
        ProbeAX.requestTree(app)
        let start = Date()
        namedAfterAsking = await waitUntil(seconds: 3) { ProbeAX.focusedElement(app) != nil }
        notes.append(
          "after AXManualAccessibility: \(namedAfterAsking ? "yes" : "no")"
            + (namedAfterAsking ? " in \(Int(Date().timeIntervalSince(start) * 1000)) ms" : ""))
      }
      notes.insert(
        "focused element named without asking: \(namedWithoutAsking ? "yes" : "no")",
        at: dropFirst ? 1 : 0)
      row.focus = namedWithoutAsking ? "named" : "not-named"
      // An application that ignores the manual switch (Chrome; possibly
      // WeChat) may honour the one screen readers set. Probe only: put back
      // as found after this application, and the rows below say the tree was
      // on through it.
      var enhanced = false
      if !namedAfterAsking {
        beforeEnhancing()
        ProbeAX.set(app, ProbeAX.enhancedUserInterface, true)
        let start = Date()
        enhanced = await waitUntil(seconds: 3) { ProbeAX.focusedElement(app) != nil }
        notes.append(
          "after AXEnhancedUserInterface: \(enhanced ? "yes" : "no")"
            + (enhanced ? " in \(Int(Date().timeIntervalSince(start) * 1000)) ms" : ""))
        if !enhanced {
          ProbeAX.set(app, ProbeAX.enhancedUserInterface, originalEnhanced ?? false)
        }
      }
      row.note = notes.joined(separator: "; ")
      append(row)
      return enhanced
    }

    // MARK: Surfaces

    /// The probe's own page in a new tab; read back through the window title.
    private func pageTrial(
      base: DeliveryProbe.Row, appURL: URL, application: NSRunningApplication,
      scenario: DeliveryProbe.Scenario, variant: DeliveryProbe.Variant, cold: String? = nil
    ) async {
      var row = base
      row.scenario = cold == nil ? scenario.rawValue : "cold"
      row.variant = variant.rawValue
      let token = DeliveryProbe.token()
      guard
        await openPage(scenario: scenario, token: token, appURL: appURL, application: application)
          != nil
      else {
        row.note = "the probe page did not open"
        append(row)
        return
      }
      let pid = application.processIdentifier
      let outcome = await deliver(
        token: token, to: application, variant: variant,
        replica: cold == nil ? nil : DailyDeliveryReplica(),
        onOwnSurface: { self.showsPage(token, in: pid) })
      var notes = cold.map { ["cold (\($0))"] } ?? []
      switch outcome {
      case .skipped(let reason):
        notes.append("skipped: \(reason); nothing sent")
      case .delivered(let trial):
        fill(&row, with: trial)
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let report = windowTitle(of: pid).flatMap(DeliveryProbe.pageReport(fromTitle:))
        let observed = report?.token == token ? DeliveryProbe.observed(page: report) : .unreadable
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
        if let report, report.token == token {
          notes.append("page saw \(report.pasteEvents) paste event(s)")
        }
      }
      row.note = notes.joined(separator: "; ")
      append(row)
      await closePage(token: token, application: application)
    }

    /// A chat application's message box, used only when it is empty, never
    /// sent; emptied after each trial. Before every paste the box must be the
    /// same element as found (`CFEqual`) and still empty (review 10-5d R1:
    /// it was checked once, before the first trial).
    private func composerTrials(
      base: DeliveryProbe.Row, application: NSRunningApplication,
      scenarios: [DeliveryProbe.Scenario]
    ) async {
      let app = ProbeAX.application(application.processIdentifier)
      ProbeAX.requestTree(app)
      guard let composer = await findComposer(app) else {
        var row = base
        row.note = "no message box visible to accessibility; nothing sent"
        append(row)
        return
      }
      guard ProbeAX.isEmptyField(composer) else {
        var row = base
        row.note =
          "the message box holds text (a draft or unreadable); left untouched, nothing sent"
        append(row)
        return
      }
      let before = ProbeAX.value(composer) ?? ""
      for scenario in scenarios {
        for variant in DeliveryProbe.Variant.allCases {
          var row = base
          row.scenario = scenario.rawValue
          row.variant = variant.rawValue
          guard await bringToFront(application) else {
            row.note = "could not be brought to the front"
            append(row)
            continue
          }
          guard ProbeAX.isEmptyField(composer) else {
            row.note =
              "the message box is no longer empty; left untouched, nothing sent; the probe stops using it"
            append(row)
            return
          }
          var keyboardOn: AXUIElement?
          if scenario == .noField {
            if let window = ProbeAX.focusedWindow(app),
              let button = ProbeAX.firstButton(in: window),
              ProbeAX.focus(button, in: app)
            {
              keyboardOn = button
            }
          } else if ProbeAX.focus(composer, in: app) {
            keyboardOn = composer
          }
          guard let keyboardOn else {
            row.note = "could not put the keyboard where the scenario needs it; nothing sent"
            append(row)
            continue
          }
          let token = DeliveryProbe.token()
          let outcome = await deliver(
            token: token, to: application, variant: variant,
            onOwnSurface: {
              ProbeAX.hasKeyboard(keyboardOn, in: app) && ProbeAX.isEmptyField(composer)
            })
          guard case .delivered(let trial) = outcome else {
            if case .skipped(let reason) = outcome { row.note = "skipped: \(reason); nothing sent" }
            append(row)
            continue
          }
          fill(&row, with: trial)
          try? await Task.sleep(for: .milliseconds(800))
          row.clipboardAfter = clipboardAfter(token: token).rawValue
          let observed = DeliveryProbe.observed(
            before: before, after: ProbeAX.value(composer),
            probeText: DeliveryProbe.probeText(token: token),
            priorText: DeliveryProbe.priorText(token: token))
          row.observed = observed.rawValue
          row.verdict =
            DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed)
            .rawValue
          if let left = await cleanComposer(
            (composer, true), tokens: [token], app: app, application: application)
          {
            row.note = left + "; the probe stops using it"
            append(row)
            return
          }
          append(row)
        }
      }
    }

    /// The last editable text area in the focused window, looked for while the
    /// tree is being built.
    private func findComposer(_ app: AXUIElement) async -> AXUIElement? {
      var composer: AXUIElement?
      _ = await waitUntil(seconds: 4) {
        composer = ProbeAX.focusedWindow(app).flatMap(ProbeAX.composer(in:))
        return composer != nil
      }
      return composer
    }

    /// The message box the probe put the keyboard in, if the application
    /// still answers for that element; otherwise the box found again
    /// (`same` false: cleaned through accessibility only, never by keys).
    private func sameOrFoundAgain(_ composer: AXUIElement, app: AXUIElement) async
      -> (element: AXUIElement, same: Bool)?
    {
      if ProbeAX.value(composer) != nil { return (composer, true) }
      return await findComposer(app).map { ($0, false) }
    }

    /// Takes the probe's own words out of a message box after its trials
    /// (`DeliveryProbe.cleanup`, review 10-5d R1): ⌘A and Delete only on the
    /// element the probe put the keyboard in and only when it holds exactly
    /// the probe's words, with the application in front and the keyboard on
    /// that element before each key; otherwise its value is set through
    /// accessibility with the probe's words taken out. Nil when the box holds
    /// none of the probe's words afterwards; otherwise what was left, for the
    /// row's note.
    private func cleanComposer(
      _ box: (element: AXUIElement, same: Bool)?, tokens: [String], app: AXUIElement,
      application: NSRunningApplication
    ) async -> String? {
      guard let box else {
        return "the message box was not found again; the probe's words may be in it (not sent)"
      }
      let composer = box.element
      let pieces = DeliveryProbe.pieces(tokens: tokens)
      switch DeliveryProbe.cleanup(
        of: ProbeAX.value(composer), pieces: pieces, sameElement: box.same)
      {
      case .nothing:
        return nil
      case .stop:
        return "the message box could not be read, or holds the probe's words mixed with other "
          + "text it cannot take them out of; left as it is (not sent)"
      case .setValue(let kept):
        ProbeAX.setValue(composer, kept)
        try? await Task.sleep(for: .milliseconds(300))
        if DeliveryProbe.cleanup(of: ProbeAX.value(composer), pieces: pieces, sameElement: false)
          == .nothing
        {
          return nil
        }
        return "the probe's words could not be taken out through accessibility; left in the "
          + "message box (not sent)"
      case .selectAllAndDelete:
        let exactlyTheProbes = {
          DeliveryProbe.cleanup(of: ProbeAX.value(composer), pieces: pieces, sameElement: true)
            == .selectAllAndDelete
        }
        guard ProbeAX.focus(composer, in: app),
          refusal(application, onOwnSurface: ProbeAX.hasKeyboard(composer, in: app)) == nil
        else { return "the keyboard could not be put back in the message box; not emptied" }
        _ = ProbeAX.pressMenuItem(app, command: "A")
        try? await Task.sleep(for: .milliseconds(150))
        // Still that element, still exactly the probe's words: what is
        // selected is the probe's words.
        guard
          refusal(
            application,
            onOwnSurface: ProbeAX.hasKeyboard(composer, in: app) && exactlyTheProbes()) == nil
        else { return "the message box changed before Delete; not emptied" }
        ProbeKeys.post(application.processIdentifier, CGKeyCode(kVK_Delete))
        try? await Task.sleep(for: .milliseconds(300))
        return ProbeAX.isEmptyField(composer) ? nil : "the message box could not be emptied"
      }
    }

    /// TextEdit: a new untitled document per trial, undone to empty and
    /// closed without saving.
    private func documentTrial(
      base: DeliveryProbe.Row, application: NSRunningApplication, variant: DeliveryProbe.Variant
    ) async {
      var row = base
      row.scenario = DeliveryProbe.Scenario.field.rawValue
      row.variant = variant.rawValue
      let app = ProbeAX.application(application.processIdentifier)
      guard let window = await newWindow(app: app, application: application),
        let area = ProbeAX.descendants(
          of: window, limit: 400, where: { ProbeAX.role($0) == "AXTextArea" }
        ).first
      else {
        row.note = "no new document appeared"
        append(row)
        return
      }
      let before = ProbeAX.value(area) ?? ""
      guard before.isEmpty, ProbeAX.focus(area, in: app) else {
        row.note = "the new document was not empty or could not take the keyboard; nothing sent"
        _ = await closeWindow(window, app: app)
        append(row)
        return
      }
      let onOwnDocument = { ProbeAX.hasKeyboard(area, in: app) }
      let token = DeliveryProbe.token()
      let outcome = await deliver(
        token: token, to: application, variant: variant, onOwnSurface: onOwnDocument)
      var notes: [String] = []
      if case .delivered(let trial) = outcome {
        fill(&row, with: trial)
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let observed = DeliveryProbe.observed(
          before: before, after: ProbeAX.value(area),
          probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
        for _ in 0..<8 where (ProbeAX.value(area) ?? "") != before {
          if let reason = refusal(application, onOwnSurface: onOwnDocument()) {
            notes.append("undo stopped: \(reason)")
            break
          }
          _ = ProbeAX.pressMenuItem(app, command: "Z")
          try? await Task.sleep(for: .milliseconds(150))
        }
      } else if case .skipped(let reason) = outcome {
        notes.append("skipped: \(reason); nothing sent")
      }
      if !(await closeWindow(window, app: app)) {
        notes.append("the new document was left open (unsaved)")
      }
      row.note = notes.joined(separator: "; ")
      append(row)
    }

    /// VS Code: a new untitled editor per trial, read back by copying it, and
    /// closed without saving. With the tree on, the keyboard must be in the
    /// editor's own text area (the element focused when the editor opened,
    /// `CFEqual`), not only the editor's name in the window title: the
    /// title stays the same while the keyboard is in the terminal panel, the
    /// search box or the chat input (review 10-5d R1). Cold: the tree is
    /// switched off once the editor is there, and the daily build meets the
    /// process for the first time; the title, the application in front and
    /// no click or key press since are all that can be checked then.
    private func editorTrial(
      base: DeliveryProbe.Row, application: NSRunningApplication, variant: DeliveryProbe.Variant,
      cold: String? = nil
    ) async {
      var row = base
      row.scenario = cold == nil ? DeliveryProbe.Scenario.field.rawValue : "cold"
      row.variant = variant.rawValue
      let app = ProbeAX.application(application.processIdentifier)
      guard await bringToFront(application), let editor = await newUntitledEditor(app: app) else {
        row.note = "no new untitled editor appeared"
        append(row)
        return
      }
      try? await Task.sleep(for: .milliseconds(500))
      ProbeAX.requestTree(app)
      let area = await editorArea(app)
      let placed = Date()
      let titled = { Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title)) == editor }
      let inArea = { area.map { ProbeAX.hasKeyboard($0, in: app) } ?? false }
      var notes: [String] = []
      guard area != nil else {
        row.note = "the editor's text area is not visible to accessibility; nothing sent"
        _ = await closeUntitledEditor(
          editor, app: app, application: application, onOwnEditor: titled)
        append(row)
        return
      }
      var onOwnEditor: () -> Bool = { titled() && inArea() }
      if let cold {
        let drop = await dropTree(app)
        notes.append("cold (\(cold)); after the tree was switched off: \(drop.seen)")
        onOwnEditor = { titled() && self.untouched(since: placed) }
      }
      let token = DeliveryProbe.token()
      let outcome = await deliver(
        token: token, to: application, variant: variant,
        replica: cold == nil ? nil : DailyDeliveryReplica(), onOwnSurface: onOwnEditor)
      switch outcome {
      case .skipped(let reason):
        notes.append("skipped: \(reason); nothing sent")
      case .delivered(let trial):
        fill(&row, with: trial)
        if cold != nil { notes.append(Self.relaunchNote(focus: trial.focus)) }
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let copied = await copyEditor(app: app, application: application, onOwnEditor: onOwnEditor)
        let observed = DeliveryProbe.observed(
          before: "", after: copied, probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
      }
      if !(await closeUntitledEditor(
        editor, app: app, application: application, onOwnEditor: onOwnEditor))
      {
        notes.append("the untitled editor was left open (unsaved)")
      }
      row.note = notes.joined(separator: "; ")
      append(row)
    }

    /// The text area that has the keyboard in VS Code's new editor, looked
    /// for while the tree is being built.
    private func editorArea(_ app: AXUIElement) async -> AXUIElement? {
      var area: AXUIElement?
      _ = await waitUntil(seconds: 3) {
        area = ProbeAX.focusedElement(app).flatMap { ProbeAX.role($0) == "AXTextArea" ? $0 : nil }
        return area != nil
      }
      return area
    }

    /// The probe's own editor read back by selecting and copying all of it;
    /// nil when it is not the active editor in front.
    private func copyEditor(
      app: AXUIElement, application: NSRunningApplication, onOwnEditor: () -> Bool
    ) async -> String? {
      guard refusal(application, onOwnSurface: onOwnEditor()) == nil else { return nil }
      let count = NSPasteboard.general.changeCount
      _ = ProbeAX.pressMenuItem(app, command: "A")
      try? await Task.sleep(for: .milliseconds(150))
      guard refusal(application, onOwnSurface: onOwnEditor()) == nil else { return nil }
      _ = ProbeAX.pressMenuItem(app, command: "C")
      guard await waitUntil(seconds: 1, { NSPasteboard.general.changeCount != count }) else {
        return nil
      }
      let copied = NSPasteboard.general.string(forType: .string) ?? ""
      // The probe asked for this copy: the clipboard is still the probe's.
      noteProbeClipboard()
      return copied
    }

    /// Terminal: one new window; the typed line is cleared with ⌃U (never
    /// run) after each trial, and the window closed at the end.
    private func terminalTrials(base: DeliveryProbe.Row, application: NSRunningApplication) async {
      let pid = application.processIdentifier
      let app = ProbeAX.application(pid)
      guard let window = await newWindow(app: app, application: application),
        let area = ProbeAX.descendants(
          of: window, limit: 400, where: { ProbeAX.role($0) == "AXTextArea" }
        ).first
      else {
        var row = base
        row.note = "no new window appeared"
        append(row)
        return
      }
      try? await Task.sleep(for: .milliseconds(800))
      let onOwnWindow = { ProbeAX.hasKeyboard(area, in: app) }
      for variant in DeliveryProbe.Variant.allCases {
        var row = base
        row.scenario = DeliveryProbe.Scenario.field.rawValue
        row.variant = variant.rawValue
        _ = await bringToFront(application)
        _ = ProbeAX.focus(area, in: app)
        let before = ProbeAX.value(area)
        let token = DeliveryProbe.token()
        let outcome = await deliver(
          token: token, to: application, variant: variant, onOwnSurface: onOwnWindow)
        guard case .delivered(let trial) = outcome else {
          if case .skipped(let reason) = outcome { row.note = "skipped: \(reason); nothing sent" }
          append(row)
          continue
        }
        fill(&row, with: trial)
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let observed = DeliveryProbe.observed(
          before: before, after: ProbeAX.value(area),
          probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed)
          .rawValue
        if let reason = refusal(application, onOwnSurface: onOwnWindow()) {
          row.note = "the line was not cleared: \(reason)"
        } else {
          ProbeKeys.post(pid, CGKeyCode(kVK_ANSI_U), flags: .maskControl)
          try? await Task.sleep(for: .milliseconds(200))
        }
        append(row)
      }
      if !(await closeWindow(window, app: app)) {
        note("Terminal: the probe's window was left open")
      }
    }

    /// A search field, used only when it is empty; emptied after each trial.
    private func searchTrials(
      base: DeliveryProbe.Row, application: NSRunningApplication, findByMenu: Bool
    ) async {
      let pid = application.processIdentifier
      let app = ProbeAX.application(pid)
      ProbeAX.requestTree(app)
      var field: AXUIElement?
      if findByMenu {
        // The box ⌘F puts the keyboard in, only if it says it is for
        // searching and is not what had the keyboard already (a chat's
        // message box never qualifies).
        let earlier = ProbeAX.focusedElement(app)
        if refusal(application, onOwnSurface: true) == nil,
          !ProbeAX.pressMenuItem(app, command: "F")
        {
          ProbeKeys.post(pid, CGKeyCode(kVK_ANSI_F), flags: .maskCommand)
        }
        _ = await waitUntil(seconds: 3) {
          field = ProbeAX.focusedElement(app).flatMap { element in
            if let earlier, CFEqual(earlier, element) { return nil }
            return ProbeAX.isLabelledSearchBox(element) ? element : nil
          }
          return field != nil
        }
      } else if let window = ProbeAX.focusedWindow(app) {
        field = ProbeAX.descendants(of: window, limit: 600, where: ProbeAX.isSearchField).first
      }
      guard let field else {
        var row = base
        row.note = "no search field visible to accessibility; nothing sent"
        append(row)
        return
      }
      guard ProbeAX.isEmptyField(field) else {
        var row = base
        row.note = "the search field holds text; left untouched, nothing sent"
        append(row)
        return
      }
      let before = ProbeAX.value(field) ?? ""
      let onOwnField = { ProbeAX.hasKeyboard(field, in: app) }
      for variant in DeliveryProbe.Variant.allCases {
        var row = base
        row.scenario = DeliveryProbe.Scenario.field.rawValue
        row.variant = variant.rawValue
        _ = await bringToFront(application)
        guard ProbeAX.focus(field, in: app) else {
          row.note = "could not put the keyboard in the search field; nothing sent"
          append(row)
          continue
        }
        let token = DeliveryProbe.token()
        let outcome = await deliver(
          token: token, to: application, variant: variant, onOwnSurface: onOwnField)
        guard case .delivered(let trial) = outcome else {
          if case .skipped(let reason) = outcome { row.note = "skipped: \(reason); nothing sent" }
          append(row)
          continue
        }
        fill(&row, with: trial)
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        let observed = DeliveryProbe.observed(
          before: before, after: ProbeAX.value(field),
          probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict =
          DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed)
          .rawValue
        ProbeAX.setValue(field, before)
        if refusal(application, onOwnSurface: onOwnField()) == nil {
          ProbeKeys.post(pid, CGKeyCode(kVK_Escape))
        }
        try? await Task.sleep(for: .milliseconds(200))
        if (ProbeAX.value(field) ?? before) != before {
          row.note = "the search field could not be emptied; the probe stops using it"
          append(row)
          return
        }
        append(row)
      }
    }

    // MARK: Chromium drops its tree

    /// The probe's own surface for the tree-drop check.
    private enum DropSurface {
      case page(token: String)
      /// The message box the keyboard was put in.
      case composer(AXUIElement)
      /// The editor's name, and its text area.
      case editor(String, AXUIElement)
    }

    /// Whether the application stops naming its focused element after input
    /// with no assistive use (Chromium's AutoDisableAccessibility: three or
    /// more inputs over more than thirty seconds), and, when it does, what
    /// each build's delivery does in that state: the daily build as a
    /// process that already woke this application once (it never asks
    /// again), this build as in production (it asks when the key goes down).
    /// Four right-arrow presses, eleven seconds apart, into the probe's own
    /// empty field, with no accessibility call in between. Between the
    /// presses only the front application and the user's own clicks and key
    /// presses are checked (a look through accessibility would count as
    /// assistive use): a click or key press by the user stops the check
    /// (review 10-5d R1).
    private func treeDropCheck(
      base: DeliveryProbe.Row, appURL: URL, application: NSRunningApplication,
      target: DeliveryProbe.Target
    ) async {
      var row = base
      row.scenario = "tree-drop"
      let pid = application.processIdentifier
      let app = ProbeAX.application(pid)
      let surface: DropSurface
      switch target.surface {
      case .probePage:
        let token = DeliveryProbe.token()
        guard
          await openPage(scenario: .field, token: token, appURL: appURL, application: application)
            != nil
        else {
          row.note = "the probe page did not open"
          append(row)
          return
        }
        surface = .page(token: token)
      case .composer:
        ProbeAX.requestTree(app)
        guard let composer = await findComposer(app), ProbeAX.isEmptyField(composer),
          await bringToFront(application), ProbeAX.focus(composer, in: app)
        else {
          row.note = "no empty message box; check skipped"
          append(row)
          return
        }
        surface = .composer(composer)
      case .newDocument:
        guard await bringToFront(application), let editor = await newUntitledEditor(app: app)
        else {
          row.note = "no new untitled editor; check skipped"
          append(row)
          return
        }
        ProbeAX.requestTree(app)
        guard let area = await editorArea(app) else {
          row.note = "the editor's text area is not visible to accessibility; check skipped"
          append(row)
          _ = await closeUntitledEditor(
            editor, app: app, application: application,
            onOwnEditor: {
              Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title)) == editor
            })
          return
        }
        surface = .editor(editor, area)
      case .newWindow, .searchField:
        row.note = "no surface for this check"
        append(row)
        return
      }
      ProbeAX.requestTree(app)
      let namedBefore = await waitUntil(seconds: 3) { ProbeAX.focusedElement(app) != nil }
      var pressed = 0
      var lastPress = Date()
      var stopped = "another application came to the front"
      for index in 0..<4 {
        if index > 0 { try? await Task.sleep(for: .seconds(11)) }
        // Only the front application and the user's own input are checked
        // between the presses: an accessibility call would count as
        // assistive use. A right arrow changes no text wherever it lands.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { break }
        guard untouched(since: lastPress) else {
          stopped = "the keyboard or the mouse was used"
          break
        }
        ProbeKeys.post(pid, CGKeyCode(kVK_RightArrow))
        lastPress = Date()
        pressed += 1
      }
      guard pressed == 4 else {
        row.note = "\(stopped); check stopped after \(pressed) key presses"
        append(row)
        await cleanUp(surface, tokens: [], since: lastPress, app: app, application: application)
        return
      }
      try? await Task.sleep(for: .seconds(1))
      let namedAfter = ProbeAX.focusedElement(app) != nil
      row.focus = namedAfter ? "named" : "dropped"
      row.note =
        "named before: \(namedBefore ? "yes" : "no"); after 4 key presses over 33 s with no "
        + "assistive use: \(namedAfter ? "yes" : "no")"
      append(row)
      var tokens: [String] = []
      if !namedAfter {
        tokens = await afterDropTrials(
          base: base, application: application, surface: surface, since: lastPress)
      }
      await cleanUp(surface, tokens: tokens, since: lastPress, app: app, application: application)
    }

    /// One delivery of each build into the surface whose tree just dropped,
    /// read back afterwards (a message box only once its tree is asked for
    /// again, after both). With the tree off, the message box and the editor
    /// are checked by the application in front, the editor's name in the
    /// window title, and no click or key press by the user since the last
    /// press: this row relies on the user not touching the keyboard or the
    /// mouse (review 10-5d R1). Returns the tokens delivered into a message
    /// box, for its cleanup.
    private func afterDropTrials(
      base: DeliveryProbe.Row, application: NSRunningApplication, surface: DropSurface,
      since lastPress: Date
    ) async -> [String] {
      let pid = application.processIdentifier
      let app = ProbeAX.application(pid)
      var pending: [(row: DeliveryProbe.Row, token: String, inserted: Bool)] = []
      for variant in DeliveryProbe.Variant.allCases {
        var row = base
        row.scenario = "after-drop"
        row.variant = variant.rawValue
        let token: String
        let onOwnSurface: () -> Bool
        var pageBefore: DeliveryProbe.PageReport?
        switch surface {
        case .page(let pageToken):
          token = pageToken
          onOwnSurface = { self.showsPage(pageToken, in: pid) }
          pageBefore = windowTitle(of: pid).flatMap(DeliveryProbe.pageReport(fromTitle:))
        case .composer:
          token = DeliveryProbe.token()
          // The tree is off: the keyboard was on the empty box before the
          // presses, the paste goes to this application only, and nobody
          // clicked or typed since.
          onOwnSurface = { self.untouched(since: lastPress) }
        case .editor(let editor, _):
          token = DeliveryProbe.token()
          onOwnSurface = {
            Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title)) == editor
              && self.untouched(since: lastPress)
          }
        }
        let outcome = await deliver(
          token: token, to: application, variant: variant,
          replica: DailyDeliveryReplica(alreadyWoken: [pid]), onOwnSurface: onOwnSurface)
        guard case .delivered(let trial) = outcome else {
          if case .skipped(let reason) = outcome { row.note = "skipped: \(reason); nothing sent" }
          append(row)
          continue
        }
        fill(&row, with: trial)
        try? await Task.sleep(for: .milliseconds(800))
        row.clipboardAfter = clipboardAfter(token: token).rawValue
        switch surface {
        case .page:
          let after = windowTitle(of: pid).flatMap(DeliveryProbe.pageReport(fromTitle:))
          let observed = Self.pageDelta(before: pageBefore, after: after, token: token)
          row.observed = observed.rawValue
          row.verdict =
            DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
          append(row)
        case .editor:
          let copied = await copyEditor(
            app: app, application: application, onOwnEditor: onOwnSurface)
          let observed = DeliveryProbe.observed(
            before: "", after: copied, probeText: DeliveryProbe.probeText(token: token),
            priorText: DeliveryProbe.priorText(token: token))
          row.observed = observed.rawValue
          row.verdict =
            DeliveryProbe.verdict(claimedInserted: trial.inserted, observed: observed).rawValue
          append(row)
        case .composer:
          pending.append((row, token, trial.inserted))
        }
      }
      guard case .composer(let composer) = surface, !pending.isEmpty else { return [] }
      ProbeAX.requestTree(app)
      let box = await sameOrFoundAgain(composer, app: app)
      let value = box.flatMap { ProbeAX.value($0.element) }
      for (pendingRow, token, inserted) in pending {
        var row = pendingRow
        let observed = DeliveryProbe.observed(
          before: "", after: value, probeText: DeliveryProbe.probeText(token: token),
          priorText: DeliveryProbe.priorText(token: token))
        row.observed = observed.rawValue
        row.verdict = DeliveryProbe.verdict(claimedInserted: inserted, observed: observed).rawValue
        row.note = "read back after both deliveries (the box's tree asked for again)"
        append(row)
      }
      return pending.map(\.token)
    }

    /// What a second delivery into the same page added: its title counts the
    /// page's words and the stand-in for the clipboard.
    static func pageDelta(
      before: DeliveryProbe.PageReport?, after: DeliveryProbe.PageReport?, token: String
    ) -> DeliveryProbe.Observed {
      guard let after, after.token == token else { return .unreadable }
      if after.words > (before?.words ?? 0) { return .landed }
      if after.prior > (before?.prior ?? 0) { return .priorClipboard }
      return .absent
    }

    /// After the tree-drop check: the page closed, the message box cleaned
    /// of the words delivered into it (`cleanComposer`: the element the
    /// keyboard was put in if the tree still answers for it, otherwise only
    /// through accessibility), the editor closed.
    private func cleanUp(
      _ surface: DropSurface, tokens: [String], since lastPress: Date, app: AXUIElement,
      application: NSRunningApplication
    ) async {
      switch surface {
      case .page(let token):
        await closePage(token: token, application: application)
      case .composer(let composer):
        guard !tokens.isEmpty else { return }
        ProbeAX.requestTree(app)
        let box = await sameOrFoundAgain(composer, app: app)
        if let left = await cleanComposer(
          box, tokens: tokens, app: app, application: application)
        {
          note("\(application.bundleIdentifier ?? "-"): \(left)")
        }
      case .editor(let editor, let area):
        ProbeAX.requestTree(app)
        _ = await closeUntitledEditor(
          editor, app: app, application: application,
          onOwnEditor: {
            ProbeAX.hasKeyboard(area, in: app) || self.untouched(since: lastPress)
          })
      }
    }

    // MARK: Delivering

    private struct Trial {
      let inserted: Bool
      let detail: String
      let focus: String
      let deliverMilliseconds: Int
      let waitMilliseconds: Int?
    }

    private enum Outcome {
      case delivered(Trial)
      /// Nothing was sent: the application under test was not in front, or
      /// the keyboard was not on the probe's own surface.
      case skipped(String)
    }

    private func fill(_ row: inout DeliveryProbe.Row, with trial: Trial) {
      row.claim = trial.inserted ? "inserted" : "kept"
      row.detail = trial.detail
      row.focus = trial.focus
      row.deliverMilliseconds = trial.deliverMilliseconds
      row.waitMilliseconds = trial.waitMilliseconds
    }

    /// Why nothing may be sent to `application` now (nil when it may).
    private func refusal(_ application: NSRunningApplication, onOwnSurface: Bool) -> String? {
      DeliveryProbe.refusal(
        frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        target: application.processIdentifier, onOwnSurface: onOwnSurface)
    }

    /// One delivery of the trial's words, with the stand-in for the user's
    /// clipboard on the clipboard first, only while the application is in
    /// front with the keyboard on the probe's own surface. This build's path
    /// is driven as a dictation is: the target captured when the key goes
    /// down (which asks for the tree), the words ready a dictation's length
    /// later. `replica` is the daily build's delivery to use (the run's
    /// long-running one by default).
    private func deliver(
      token: String, to application: NSRunningApplication, variant: DeliveryProbe.Variant,
      replica: DailyDeliveryReplica? = nil, onOwnSurface: () -> Bool
    ) async -> Outcome {
      if let reason = refusal(application, onOwnSurface: onOwnSurface()) {
        return .skipped(reason)
      }
      let text = DeliveryProbe.probeText(token: token)
      // The deliverers' ⌘V is the probe's own key press, and what they leave
      // on the clipboard is the probe's.
      var sent = false
      defer {
        if sent {
          ProbeKeys.lastPost = Date()
          noteProbeClipboard()
        }
      }
      switch variant {
      case .daily:
        placePriorText(token: token)
        sent = true
        let start = Date()
        let claim = await (replica ?? daily).deliver(text, to: application.processIdentifier)
        return .delivered(
          Trial(
            inserted: claim.inserted, detail: claim.detail, focus: claim.focus,
            deliverMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
            waitMilliseconds: claim.waitMilliseconds))
      case .current:
        _ = try? port.captureTargetNow()
        try? await Task.sleep(for: .seconds(DeliveryProbe.dictationSeconds))
        if let reason = refusal(application, onOwnSurface: onOwnSurface()) {
          return .skipped(reason)
        }
        placePriorText(token: token)
        sent = true
        let start = Date()
        let result: DictationInsertionResult?
        if let key = try? DictationIdempotencyKey("delivery-probe-\(token)") {
          result = try? await port.insert(
            DictationInsertionRequest(
              sessionID: SessionID(), target: nil, text: text, idempotencyKey: key))
        } else {
          result = nil
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let logged = deliveryLogFields(since: start)
        guard let result else {
          return .delivered(
            Trial(
              inserted: false, detail: "error", focus: "-", deliverMilliseconds: elapsed,
              waitMilliseconds: nil))
        }
        return .delivered(
          Trial(
            inserted: result.inserted,
            detail: result.inserted
              ? (result.evidence ?? "-") : (result.failureReason?.rawValue ?? "-"),
            focus: logged["focus"] ?? "-", deliverMilliseconds: elapsed,
            waitMilliseconds: logged["wait_ms"].flatMap(Int.init)))
      }
    }

    // MARK: The user's clipboard

    /// Whether the clipboard is still as the probe last left or noted it.
    private var clipboardIsProbes: Bool {
      DeliveryProbe.clipboardIsProbes(
        changeCount: NSPasteboard.general.changeCount, probesChangeCount: knownChangeCount)
    }

    /// A copy the user made since the probe last wrote the clipboard is
    /// theirs, whatever it holds (an image, a file, text): it becomes the
    /// clipboard put back from now on (review 10-5d R2).
    private func keepUsersCopy() {
      let pasteboard = NSPasteboard.general
      guard !clipboardIsProbes else { return }
      userClipboard = PasteboardSnapshot(pasteboard: pasteboard)
      knownChangeCount = pasteboard.changeCount
      note("a copy made during the run is kept as the clipboard to put back")
    }

    /// After a write the probe caused (a delivery, an editor's copy): the
    /// clipboard is the probe's — unless what is there now is not the
    /// probe's text, which means someone copied something in between.
    private func noteProbeClipboard() {
      let pasteboard = NSPasteboard.general
      if DeliveryProbe.isProbeClipboard(pasteboard.string(forType: .string)) {
        knownChangeCount = pasteboard.changeCount
      } else {
        keepUsersCopy()
      }
    }

    /// Puts the stand-in for the user's clipboard on the clipboard, after
    /// keeping a copy the user made since the probe's last write.
    private func placePriorText(token: String) {
      keepUsersCopy()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(DeliveryProbe.priorText(token: token), forType: .string)
      knownChangeCount = pasteboard.changeCount
    }

    /// After every trial: the user's clipboard back, unless the user copied
    /// something since the probe's last write: that stays, and is what is
    /// put back from now on (review 10-5c P5, 10-5d R2).
    private func putBackUserClipboard() {
      guard let userClipboard else { return }
      guard clipboardIsProbes else {
        // The user's copy stays as it is.
        keepUsersCopy()
        return
      }
      let pasteboard = NSPasteboard.general
      userClipboard.restore(to: pasteboard)
      knownChangeCount = pasteboard.changeCount
    }

    /// True when nobody clicked or pressed a key since `placed` (the moment
    /// the probe put the keyboard on its surface, or its last key press):
    /// what the rows with the tree off check instead of the keyboard
    /// (review 10-5d R1). The probe's own key presses (`ProbeKeys`, the
    /// deliverers' ⌘V) are not the user's; its clicks are accessibility
    /// actions, not input events.
    private func untouched(since placed: Date) -> Bool {
      let now = Date()
      let clickTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      let clicks =
        clickTypes.map {
          CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? .infinity
      let keys = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
      let clicked = DeliveryProbe.userActed(
        secondsSinceLastInput: clicks, secondsSincePlaced: now.timeIntervalSince(placed))
      let typed = DeliveryProbe.userActed(
        secondsSinceLastInput: keys,
        secondsSincePlaced: now.timeIntervalSince(max(placed, ProbeKeys.lastPost)))
      return !clicked && !typed
    }

    // MARK: Switches

    /// Lists switches about to be turned (with their values as found) in
    /// `switches.json`, before they are turned (review 10-5d R3).
    private func listSwitches(_ records: [DeliveryProbe.SwitchRecord]) {
      for record in records
      where !switchRecords.contains(where: {
        $0.processIdentifier == record.processIdentifier && $0.attribute == record.attribute
      }) {
        switchRecords.append(record)
      }
      writeSwitches()
    }

    /// The switches of one process were put back.
    private func forgetSwitches(of processID: Int32) {
      switchRecords.removeAll { $0.processIdentifier == processID }
      writeSwitches()
    }

    private func writeSwitches() {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(switchRecords) {
        try? data.write(
          to: output.appendingPathComponent(DeliveryProbe.switchesFileName), options: .atomic)
      }
    }

    /// Puts back the switches a probe that did not finish left turned, as
    /// listed in its output directory, for the processes that still run
    /// with the same bundle identifier (a process that ended took its
    /// switches with it). Touches nothing else. Writes `restore.txt`, and
    /// rewrites the list with what could not be put back.
    public static func restoreSwitches(outputDirectory: URL) -> ExitCode {
      guard DeliveryProbe.mayRun(bundleIdentifier: Bundle.main.bundleIdentifier) else {
        return .refused
      }
      let file = outputDirectory.appendingPathComponent(DeliveryProbe.switchesFileName)
      guard let data = try? Data(contentsOf: file),
        let records = try? JSONDecoder().decode([DeliveryProbe.SwitchRecord].self, from: data)
      else { return .cannotWrite }
      guard AXIsProcessTrusted() else { return .needsAccessibility }
      var lines: [String] = []
      var left: [DeliveryProbe.SwitchRecord] = []
      for record in records {
        let running = NSRunningApplication(processIdentifier: record.processIdentifier)
        guard let running, !running.isTerminated,
          running.bundleIdentifier == record.bundleIdentifier
        else {
          lines.append(
            "\(record.app) \(record.attribute): the process has ended; nothing to put back")
          continue
        }
        let app = ProbeAX.application(record.processIdentifier)
        let result = AXUIElementSetAttributeValue(
          app, record.attribute as CFString, record.original ? kCFBooleanTrue : kCFBooleanFalse)
        if result == .success {
          lines.append(
            "\(record.app) \(record.attribute): put back \(record.original ? "on" : "off")")
        } else {
          lines.append(
            "\(record.app) \(record.attribute): could not be put back (\(result.rawValue))")
          left.append(record)
        }
      }
      try? (lines.joined(separator: "\n") + "\n").write(
        to: outputDirectory.appendingPathComponent("restore.txt"), atomically: true,
        encoding: .utf8)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(left) { try? data.write(to: file, options: .atomic) }
      return left.isEmpty ? .finished : .notRestored
    }

    /// The fields of this process's own `delivery` log line for the trial.
    private func deliveryLogFields(since start: Date) -> [String: String] {
      guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [:] }
      let position = store.position(date: start.addingTimeInterval(-0.05))
      let predicate = NSPredicate(
        format: "subsystem == %@ AND category == %@", MindloomIdentity.logSubsystem, "delivery")
      guard let entries = try? store.getEntries(at: position, matching: predicate) else {
        return [:]
      }
      var last: [String: String] = [:]
      for case let entry as OSLogEntryLog in entries {
        last = DeliveryProbe.logFields(entry.composedMessage)
      }
      return last
    }

    private func clipboardAfter(token: String) -> DeliveryProbe.ClipboardAfter {
      DeliveryProbe.clipboardAfter(
        NSPasteboard.general.string(forType: .string),
        probeText: DeliveryProbe.probeText(token: token),
        priorText: DeliveryProbe.priorText(token: token))
    }

    // MARK: Applications and windows

    private func launch(_ url: URL) async -> NSRunningApplication? {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      guard
        let application = try? await NSWorkspace.shared.openApplication(
          at: url, configuration: configuration)
      else { return nil }
      let app = ProbeAX.application(application.processIdentifier)
      _ = await waitUntil(seconds: 8) { !ProbeAX.windows(app).isEmpty }
      try? await Task.sleep(for: .milliseconds(800))
      return application
    }

    private func bringToFront(_ application: NSRunningApplication) async -> Bool {
      let pid = application.processIdentifier
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
      _ = application.activate(options: [])
      AXUIElementSetAttributeValue(
        ProbeAX.application(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
      return await waitUntil(seconds: 3) {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      }
    }

    /// ⌘N, and the window it made (the one that was not there before).
    private func newWindow(app: AXUIElement, application: NSRunningApplication) async
      -> AXUIElement?
    {
      guard await bringToFront(application) else { return nil }
      let before = ProbeAX.windows(app)
      guard ProbeAX.pressMenuItem(app, command: "N") else { return nil }
      var made: AXUIElement?
      _ = await waitUntil(seconds: 4) {
        made = ProbeAX.windows(app).first { window in !before.contains { CFEqual($0, window) } }
        return made != nil
      }
      try? await Task.sleep(for: .milliseconds(300))
      return made
    }

    /// Closes a window the probe made, without saving, by its own close
    /// button. Only a sheet that appeared on that window after the probe
    /// pressed it is answered, with the discarding choice (review 10-5c P2).
    private func closeWindow(_ window: AXUIElement, app: AXUIElement) async -> Bool {
      guard let button = ProbeAX.element(window, kAXCloseButtonAttribute) else { return false }
      let sheetsBefore = ProbeAX.sheets(of: window)
      ProbeAX.press(button)
      if await waitUntil(seconds: 2, { !ProbeAX.windows(app).contains { CFEqual($0, window) } }) {
        return true
      }
      for sheet in ProbeAX.sheets(of: window) {
        let facts = DeliveryProbe.DialogFacts(
          existedBefore: sheetsBefore.contains { CFEqual($0, sheet) }, onOwnWindow: true,
          isSheet: true, mentionsOwnDocument: false)
        guard DeliveryProbe.mayAnswer(facts, mustMention: false) else { continue }
        if let discard = ProbeAX.descendants(
          of: sheet, limit: 80,
          where: { ProbeAX.isButton($0, titled: ProbeAX.discardNewDocumentTitles) }
        ).first {
          ProbeAX.press(discard)
        }
      }
      return await waitUntil(seconds: 2) { !ProbeAX.windows(app).contains { CFEqual($0, window) } }
    }

    /// ⌘N in VS Code, and the name of the untitled editor it made: a name
    /// that was not the active editor's before (the user may have an untitled
    /// editor of their own; it is never the one closed).
    private func newUntitledEditor(app: AXUIElement) async -> String? {
      let earlier = Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title))
      guard ProbeAX.pressMenuItem(app, command: "N") else { return nil }
      var made: String?
      _ = await waitUntil(seconds: 4) {
        let name = Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title))
        if let name, Self.isUntitled(name), name != earlier { made = name }
        return made != nil
      }
      return made
    }

    /// Closes the probe's own untitled editor without saving, only while it
    /// is the active editor in front (its exact name in the window title).
    /// The "save changes?" question is answered only when it is new since the
    /// probe's ⌘W, sits on the window that held the editor (or is a new
    /// dialog window), and names that editor; a question already on any
    /// window is the user's and stays (review 10-5c P2).
    private func closeUntitledEditor(
      _ editor: String, app: AXUIElement, application: NSRunningApplication,
      onOwnEditor: () -> Bool
    ) async -> Bool {
      let ownWindow = ProbeAX.focusedWindow(app)
      guard
        refusal(
          application,
          onOwnSurface: Self.editorName(ownWindow.flatMap(ProbeAX.title)) == editor
            && onOwnEditor()) == nil,
        let ownWindow
      else { return false }
      let windowsBefore = ProbeAX.windows(app)
      let sheetsBefore = windowsBefore.flatMap(ProbeAX.sheets(of:))
      _ = ProbeAX.pressMenuItem(app, command: "W")
      try? await Task.sleep(for: .milliseconds(500))
      for window in ProbeAX.windows(app) {
        var dialogs: [(AXUIElement, DeliveryProbe.DialogFacts)] = []
        if !windowsBefore.contains(where: { CFEqual($0, window) }) {
          dialogs.append(
            (
              window,
              DeliveryProbe.DialogFacts(
                existedBefore: false, onOwnWindow: false, isSheet: false,
                mentionsOwnDocument: ProbeAX.dialogText(window).contains(editor))
            ))
        }
        for sheet in ProbeAX.sheets(of: window) {
          dialogs.append(
            (
              sheet,
              DeliveryProbe.DialogFacts(
                existedBefore: sheetsBefore.contains { CFEqual($0, sheet) },
                onOwnWindow: CFEqual(window, ownWindow), isSheet: true,
                mentionsOwnDocument: ProbeAX.dialogText(sheet).contains(editor))
            ))
        }
        for (dialog, facts) in dialogs where DeliveryProbe.mayAnswer(facts, mustMention: true) {
          if let discard = ProbeAX.descendants(
            of: dialog, limit: 80, where: { ProbeAX.isButton($0, titled: ProbeAX.dontSaveTitles) }
          ).first {
            ProbeAX.press(discard)
            try? await Task.sleep(for: .milliseconds(300))
          }
        }
      }
      return Self.editorName(ProbeAX.focusedWindow(app).flatMap(ProbeAX.title)) != editor
    }

    private static func isUntitled(_ title: String?) -> Bool {
      guard let title else { return false }
      return title.contains("Untitled") || title.contains("无标题") || title.contains("未命名")
    }

    /// The active editor's name in a VS Code window title ("● Untitled-2 —
    /// folder — Visual Studio Code"): the first part, without the unsaved
    /// mark.
    static func editorName(_ title: String?) -> String? {
      guard let title else { return nil }
      var first = title.components(separatedBy: " — ").first ?? title
      first = first.components(separatedBy: " - ").first ?? first
      first = first.trimmingCharacters(in: .whitespaces)
      if first.hasPrefix("●") { first = String(first.dropFirst()) }
      let name = first.trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }

    private func openPage(
      scenario: DeliveryProbe.Scenario, token: String, appURL: URL,
      application: NSRunningApplication
    ) async -> URL? {
      let page = pages.appendingPathComponent("probe-\(scenario.rawValue)-\(token).html")
      do {
        try DeliveryProbe.pageHTML(scenario: scenario, token: token)
          .write(to: page, atomically: true, encoding: .utf8)
      } catch {
        return nil
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      guard
        (try? await NSWorkspace.shared.open(
          [page], withApplicationAt: appURL, configuration: configuration)) != nil
      else { return nil }
      let pid = application.processIdentifier
      let opened = await waitUntil(seconds: 8) { self.showsPage(token, in: pid) }
      guard opened else { return nil }
      _ = await bringToFront(application)
      try? await Task.sleep(for: .milliseconds(600))
      return page
    }

    /// ⌘W, only while the application is in front showing the probe's own
    /// page.
    private func closePage(token: String, application: NSRunningApplication) async {
      let pid = application.processIdentifier
      guard refusal(application, onOwnSurface: showsPage(token, in: pid)) == nil else {
        note("\(application.bundleIdentifier ?? "-"): the probe tab was not in front; left open")
        return
      }
      _ = ProbeAX.pressMenuItem(ProbeAX.application(pid), command: "W")
      _ = await waitUntil(seconds: 2) { !self.showsPage(token, in: pid) }
    }

    private func showsPage(_ token: String, in pid: Int32) -> Bool {
      DeliveryProbe.pageReport(fromTitle: windowTitle(of: pid) ?? "")?.token == token
    }

    private func windowTitle(of pid: Int32) -> String? {
      ProbeAX.focusedWindow(ProbeAX.application(pid)).flatMap(ProbeAX.title)
    }

    private func waitUntil(
      seconds: TimeInterval, _ condition: @MainActor () -> Bool
    ) async -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return condition()
    }

    // MARK: Output

    /// Every row ends a trial: the user's clipboard goes back here.
    private func append(_ row: DeliveryProbe.Row) {
      putBackUserClipboard()
      var row = row
      if !notePrefix.isEmpty {
        row.note = row.note.isEmpty ? notePrefix : notePrefix + "; " + row.note
      }
      rows.append(row)
      note(
        "\(row.app) \(row.scenario) \(row.variant): \(row.claim)/\(row.detail) observed=\(row.observed) verdict=\(row.verdict) \(row.note)"
      )
      flush()
    }

    private func note(_ line: String) {
      let seconds = Int(Date().timeIntervalSince(started))
      log.append("[+\(seconds)s] \(line)")
    }

    private func flush() {
      try? DeliveryProbe.tsv(rows).write(
        to: output.appendingPathComponent("matrix.tsv"), atomically: true, encoding: .utf8)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(rows) {
        try? data.write(to: output.appendingPathComponent("matrix.json"), options: .atomic)
      }
      try? (log.joined(separator: "\n") + "\n").write(
        to: output.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }

    private func writeStatus(state: String, trusted: Bool, canPost: Bool) {
      let status: [String: Any] = [
        "state": state,
        "started": ISO8601DateFormatter().string(from: started),
        "updated": ISO8601DateFormatter().string(from: Date()),
        "accessibility": trusted,
        "post_events": canPost,
        "bundle_identifier": Bundle.main.bundleIdentifier ?? "-",
        "app_path": Bundle.main.bundlePath,
        "build_revision": Bundle.main.infoDictionary?["BestASRBuildRevision"] as? String ?? "-",
        "rows": rows.count,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output.appendingPathComponent("status.json"), options: .atomic)
      }
    }
  }

  // MARK: Accessibility, for the probe

  /// Accessibility reads and actions the probe uses to find and drive its own
  /// surfaces. Generous timeouts: the probe may wait, the App may not.
  @MainActor
  enum ProbeAX {
    static func application(_ pid: Int32) -> AXUIElement {
      let element = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(element, 1.0)
      return element
    }

    /// Electron's switch for its accessibility tree (also what this build's
    /// reader sets to ask for it).
    static let manualAccessibility = "AXManualAccessibility"
    /// The switch screen readers set.
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    static func requestTree(_ app: AXUIElement) {
      set(app, manualAccessibility, true)
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
      attribute(element, name) as? Bool
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: Bool) {
      AXUIElementSetAttributeValue(
        element, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
      }
      return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
      guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID()
      else { return nil }
      return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
      attribute(element, name) as? String
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    static func subrole(_ element: AXUIElement) -> String? { string(element, kAXSubroleAttribute) }
    static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute) }
    static func value(_ element: AXUIElement) -> String? { string(element, kAXValueAttribute) }

    static func setValue(_ element: AXUIElement, _ value: String) {
      AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
      (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
      (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
      element(app, kAXFocusedWindowAttribute)
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
      element(app, kAXFocusedUIElementAttribute)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
      AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Whether the application names `element` as focused now.
    static func hasKeyboard(_ element: AXUIElement, in app: AXUIElement) -> Bool {
      focusedElement(app).map { CFEqual($0, element) } == true
    }

    /// The sheets on a window.
    static func sheets(of window: AXUIElement) -> [AXUIElement] {
      children(window).filter { role($0) == "AXSheet" }
    }

    /// The words a dialog shows (its texts, titles and descriptions), to tell
    /// whether it names the probe's own document.
    static func dialogText(_ dialog: AXUIElement) -> String {
      descendants(of: dialog, limit: 120, where: { _ in true }).flatMap { element in
        [value(element), title(element), string(element, kAXDescriptionAttribute)].compactMap { $0 }
      }.joined(separator: " ")
    }

    /// Puts the keyboard on `element` and checks that the application now
    /// names it as focused.
    static func focus(_ element: AXUIElement, in app: AXUIElement) -> Bool {
      AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      let deadline = Date().addingTimeInterval(1)
      repeat {
        if let focused = focusedElement(app), CFEqual(focused, element) { return true }
        Thread.sleep(forTimeInterval: 0.05)
      } while Date() < deadline
      return false
    }

    /// Breadth first, bounded.
    static func descendants(
      of root: AXUIElement, limit: Int, where matches: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
      var queue = [root]
      var found: [AXUIElement] = []
      var visited = 0
      while !queue.isEmpty, visited < limit {
        let element = queue.removeFirst()
        visited += 1
        if matches(element) { found.append(element) }
        queue.append(contentsOf: children(element))
      }
      return found
    }

    /// A chat application's message box: the last editable text area in the
    /// window (the box sits below the conversation).
    static func composer(in window: AXUIElement) -> AXUIElement? {
      descendants(of: window, limit: 5000) { element in
        role(element) == "AXTextArea"
          && (attribute(element, "AXEnabled") as? Bool ?? true)
      }.last
    }

    /// A button inside the window's content (not a window control): the
    /// keyboard is put on it to leave nothing editable focused. Never pressed.
    static func firstButton(in window: AXUIElement) -> AXUIElement? {
      let controls: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
      ]
      return descendants(of: window, limit: 3000) { element in
        role(element) == "AXButton" && !controls.contains(subrole(element) ?? "")
          && (attribute(element, "AXEnabled") as? Bool ?? false)
      }.first
    }

    /// A search field by its role: what Notes' toolbar shows.
    static func isSearchField(_ element: AXUIElement) -> Bool {
      subrole(element) == "AXSearchField"
    }

    /// A search box that ⌘F put the keyboard in, in an application whose
    /// search box is a plain text field: it must say it is for searching.
    static func isLabelledSearchBox(_ element: AXUIElement) -> Bool {
      if isSearchField(element) { return true }
      guard role(element) == "AXTextField" else { return false }
      let labels = [
        string(element, "AXPlaceholderValue"), string(element, kAXDescriptionAttribute),
        title(element),
      ].compactMap { $0 }
      return labels.contains { $0.contains("搜索") || $0.localizedCaseInsensitiveContains("search") }
    }

    /// Empty, or showing only its placeholder.
    static func isEmptyField(_ element: AXUIElement) -> Bool {
      guard let text = value(element) else { return false }
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
      return text == string(element, "AXPlaceholderValue")
    }

    /// The discarding answer of the sheet a new TextEdit document or a new
    /// Terminal window raises when the probe closes it.
    static let discardNewDocumentTitles = [
      "删除", "Delete", "不存储", "Don't Save", "Don’t Save", "终止", "Terminate",
    ]
    /// VS Code's answer for closing an unsaved untitled editor.
    static let dontSaveTitles = ["不保存", "Don't Save", "Don’t Save"]

    static func isButton(_ element: AXUIElement, titled titles: [String]) -> Bool {
      guard role(element) == "AXButton", let title = title(element) else { return false }
      return titles.contains { title.hasPrefix($0) }
    }

    /// Presses the menu item whose shortcut is ⌘ plus `command`, wherever it
    /// sits in the application's menus (the shortcut names it in every
    /// language).
    @discardableResult
    static func pressMenuItem(_ app: AXUIElement, command: Character) -> Bool {
      guard let bar = element(app, kAXMenuBarAttribute) else { return false }
      let wanted = String(command).uppercased()
      let items = descendants(of: bar, limit: 4000) { element in
        guard role(element) == "AXMenuItem",
          string(element, kAXMenuItemCmdCharAttribute)?.uppercased() == wanted,
          (attribute(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? -1) == 0
        else { return false }
        return attribute(element, "AXEnabled") as? Bool ?? false
      }
      guard let item = items.first else { return false }
      return press(item)
    }
  }

  /// Keys the probe posts to its own surfaces (never Return).
  @MainActor
  enum ProbeKeys {
    /// When the probe last pressed a key (its own or a deliverer's ⌘V): a
    /// key press before this is not the user's.
    static var lastPost = Date.distantPast

    static func post(_ pid: Int32, _ key: CGKeyCode, flags: CGEventFlags = []) {
      defer { lastPost = Date() }
      guard let source = CGEventSource(stateID: .hidSystemState),
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
      else { return }
      down.flags = flags
      up.flags = flags
      down.postToPid(pid)
      up.postToPid(pid)
    }
  }
#endif
