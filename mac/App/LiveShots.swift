#if MINDLOOM_PREVIEW
  import AppKit
  import BestASRAgentAccess
  import BestASRDelivery
  import BestASRAudioJournal
  import BestASRDictation
  import BestASRDomain
  import BestASRInference
  import BestASRIntake
  import BestASRMacUI
  import BestASRMemory
  import BestASRMemoryUI
  import BestASRPersistence
  import Combine
  import BestASRRemoteOrganizer
  import MindloomSpaces
  import Security
  import Darwin
  import SwiftUI
  import MindloomIdentity

  // Mindloom Preview only (MINDLOOM_PREVIEW; never in the user's App): the
  // live verification run. With `-MindloomLiveShots <dir>` the real App, on
  // its real data root and in its real windows, steps through the pages and
  // states of MAC-SPEC one by one. For each it writes
  // `<dir>/current.txt` = "<n>\t<state>\t<window number>" and waits for
  // `<dir>/ack-<n>` (written by /Volumes/<build-volume>/mac-build/v11-liveshots.sh
  // once it captured that window), at most 45 s; then `current.txt` = "done".
  // `-MindloomLiveRoutes a,b,c` keeps only states named a, b, c or starting
  // with "a-" …; `<dir>/timings.txt` records the time to first content and
  // `<dir>/log.txt` what happened. Nothing here opens the microphone: the fn
  // HUD is driven with a synthetic level.

  /// Preview-only launch options.
  @MainActor
  enum PreviewLaunch {
    static func value(_ name: String) -> String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }

    /// `-MindloomAppearance light|dark`: the App's own appearance, whatever
    /// the system's (verification runs shoot both).
    static func applyAppearance() {
      switch value("-MindloomAppearance")?.lowercased() {
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
      case "light": NSApp.appearance = NSAppearance(named: .aqua)
      default: break
      }
    }

    /// `-MindloomNoArm YES` (and every live run): fn is never armed, so a
    /// verification run cannot listen to fn or ask for Input Monitoring.
    static var noArm: Bool {
      UserDefaults.standard.bool(forKey: "MindloomNoArm") || LiveShots.shared != nil
    }

    /// When this process started (for the time to first content).
    static var processStart: Date? {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
      let start = info.kp_proc.p_starttime
      return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }
  }

  @MainActor
  final class LiveShots: ObservableObject {
    static let shared: LiveShots? = {
      guard let path = PreviewLaunch.value("-MindloomLiveShots"), path.hasPrefix("/") else {
        return nil
      }
      let routes = PreviewLaunch.value("-MindloomLiveRoutes")?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      return LiveShots(directory: URL(fileURLWithPath: path, isDirectory: true), routes: routes)
    }()

    let directory: URL
    let routes: [String]?
    /// Welcome's step, set by the run (`WelcomeScene` follows it).
    @Published var welcomeStep: WelcomeStep?
    /// The Home row whose track shows its tooltip.
    @Published var forcedHover: String?
    private var counter = 0
    private(set) var running = false

    init(directory: URL, routes: [String]?) {
      self.directory = directory
      self.routes = routes
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Every menu that opens, as AppKit shows it: titles, whether the icon
      // is there and shown, and the destructive tint.
      menuObserver = NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
      ) { [weak self] note in
        nonisolated(unsafe) let object = note.object
        // After the App's own styling observer has run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          MainActor.assumeIsolated {
            guard let menu = object as? NSMenu else { return }
            self?.log("tracking: " + LiveShots.describe(menu))
          }
        }
      }
    }

    private var menuObserver: NSObjectProtocol?

    static func describe(_ menu: NSMenu) -> String {
      menu.items.map { item in
        if item.isSeparatorItem { return "─" }
        var marks: [String] = []
        if item.image != nil { marks.append("icon") }
        if #available(macOS 27.0, *), item.preferredImageVisibility == .visible {
          marks.append("shown")
        }
        if let title = item.attributedTitle, title.length > 0,
          title.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil
        {
          marks.append("tinted")
        }
        if item.submenu != nil { marks.append("›") }
        return item.title + (marks.isEmpty ? "" : "[" + marks.joined(separator: ",") + "]")
      }.joined(separator: " | ")
    }

    /// `-MindloomLiveForgetKeys YES` (and the end of a share run): deletes
    /// the Keychain items this data root made (its account is the root's
    /// identity hash; space keys are `<hash>|<space>`). Only a root marked
    /// synthetic. Logs counts only.
    static func forgetRootKeys(_ shots: LiveShots, root given: URL? = nil) {
      guard let root = given ?? (try? DictationAppModel.applicationDataRoot()),
        FileManager.default.fileExists(atPath: root.appendingPathComponent("SYNTHETIC_DATA_ROOT").path)
      else {
        shots.log("forget keys: not a synthetic root")
        return
      }
      let account = OrganizerDataRootIdentity.hash(of: root)
      var deleted = 0
      // Mindloom's services, and the ones builds before 10-6 used.
      let names = [
        "space-key", "space-device-key", "phone-seal-key", "member-access", "organizer-key",
      ]
      for service in names.flatMap({
        [MindloomIdentity.keychainService($0), MindloomIdentity.Previous.keychainService($0)]
      }) {
        let query: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword, kSecAttrService: service,
          kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[String: Any]]
        else { continue }
        for item in items {
          guard let name = item[kSecAttrAccount as String] as? String,
            name == account || name.hasPrefix(account + "|")
          else { continue }
          let one: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
          ]
          if SecItemDelete(one as CFDictionary) == errSecSuccess { deleted += 1 }
        }
      }
      shots.log("forget keys: \(deleted) items of root \(account)")
      shots.append("timings.txt", "forgot_keys\t\(deleted)\n")
    }

    /// A click as the pointer makes it, at `point` in `window` (bottom-left
    /// origin), through the event queue. SwiftUI's controls in a sheet have
    /// no accessibility elements in-process until an assistive app asks, so
    /// the share flow clicks where the sheet lays its controls out.
    static func click(_ window: NSWindow?, at point: NSPoint) {
      guard let window else { return }
      let now = ProcessInfo.processInfo.systemUptime
      for (type, time) in [(NSEvent.EventType.leftMouseDown, now), (.leftMouseUp, now + 0.05)] {
        if let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: time,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0)
        {
          NSApp.postEvent(event, atStart: false)
        }
      }
      shared?.log("click \(window.windowNumber) at \(point) in \(window.frame.size)")
    }

    /// How many characters the window's selection owner hands out through
    /// its services hook (a private pasteboard; the length only, never the
    /// words).
    static func selectionLength(_ window: NSWindow) -> String {
      guard let requestor = window.firstResponder as? NSServicesMenuRequestor else {
        return "no requestor"
      }
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      board.clearContents()
      let ok = requestor.writeSelection?(to: board, types: [.string]) ?? false
      var more = ""
      if let responder = window.firstResponder {
        let copy = #selector(NSText.copy(_:))
        let item = NSMenuItem(title: "copy", action: copy, keyEquivalent: "")
        let valid =
          (responder as? NSMenuItemValidation)?.validateMenuItem(item)
          ?? (responder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
        let target = NSApp.target(forAction: copy, to: nil, from: item)
        let ax = (responder as? NSAccessibilityProtocol)?.accessibilitySelectedText()?.count
        let range = (responder as? NSTextInputClient)?.selectedRange()
        more =
          " respondsCopy=\(responder.responds(to: copy)) valid=\(String(describing: valid))"
          + " target=\(target.map { String(describing: type(of: $0)) } ?? "nil")"
          + " axSelected=\(ax ?? -1) inputClientRange=\(range.map { NSStringFromRange($0) } ?? "nil")"
      }
      return "writeSelection=\(ok) length=\(board.string(forType: .string)?.count ?? -1)" + more
    }

    /// A double-click as the pointer makes it, at `point` (the window
    /// content's top-left coordinates), through the event queue.
    static func doubleClick(_ window: NSWindow, atTopLeft point: CGPoint) {
      let height = window.contentView?.bounds.height ?? window.frame.height
      let location = NSPoint(x: point.x, y: height - point.y)
      let now = ProcessInfo.processInfo.systemUptime
      for (index, count) in [1, 2].enumerated() {
        for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.03)] {
          if let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: now + Double(index) * 0.1 + offset,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
            pressure: type == .leftMouseDown ? 1 : 0)
          {
            NSApp.postEvent(event, atStart: false)
          }
        }
      }
      shared?.log("double-click \(window.windowNumber) at \(location)")
    }

    /// Presses the first button (or combined row) whose accessibility label
    /// or title is `label` (or contains it) in `window`: the same action a
    /// click runs. False when there is none.
    static func press(_ label: String, in window: NSWindow?, contains: Bool = false) -> Bool {
      guard let root = window?.contentView else { return false }
      var queue: [Any] = [root]
      var seen = 0
      var labels: [String] = []
      while !queue.isEmpty, seen < 5000 {
        let element = queue.removeFirst()
        seen += 1
        guard let node = element as? NSAccessibilityProtocol else { continue }
        let names = [node.accessibilityLabel(), node.accessibilityTitle()].compactMap { $0 }
        let matches = names.contains { contains ? $0.contains(label) : $0 == label }
        if matches, node.isAccessibilityEnabled(), node.accessibilityPerformPress() { return true }
        if !names.isEmpty, labels.count < 40 { labels.append(names.joined(separator: "/")) }
        queue.append(contentsOf: node.accessibilityChildren() ?? [])
        if let view = element as? NSView { queue.append(contentsOf: view.subviews) }
      }
      shared?.log(
        "press \(label): not found in \(window?.identifier?.rawValue ?? "-") after \(seen) nodes; labels: "
          + labels.joined(separator: " | "))
      return false
    }

    /// The 编辑 menu as the menu bar has it (titles, key equivalents, submenus).
    static func editMenu() -> String {
      guard
        let edit = NSApp.mainMenu?.items.first(where: {
          ["编辑", "Edit"].contains($0.submenu?.title ?? $0.title)
        })?.submenu
      else { return "no 编辑 menu: " + (NSApp.mainMenu?.items.map(\.title).joined(separator: ",") ?? "-") }
      return edit.items.map { item in
        if item.isSeparatorItem { return "─" }
        let key = item.keyEquivalent.isEmpty ? "" : " ⌘" + item.keyEquivalent
        let sub = item.submenu.map { " {" + $0.items.map { $0.isSeparatorItem ? "─" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent) }.joined(separator: ", ") + "}" } ?? ""
        return item.title + key + sub
      }.joined(separator: "\n  ")
    }

    /// Welcome's step as the run sets it (nothing without a run).
    static var welcomeSteps: AnyPublisher<WelcomeStep?, Never> {
      shared?.$welcomeStep.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    func wants(_ name: String) -> Bool {
      guard let routes, !routes.isEmpty else { return true }
      return routes.contains { name == $0 || name.hasPrefix($0 + "-") }
    }

    func log(_ line: String) {
      let url = directory.appendingPathComponent("log.txt")
      let text = "\(Date().timeIntervalSince1970)\t\(line)\n"
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
      } else {
        try? Data(text.utf8).write(to: url)
      }
    }

    func append(_ name: String, _ text: String) {
      let url = directory.appendingPathComponent(name)
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
      } else {
        write(name, text)
      }
    }

    func write(_ name: String, _ text: String) {
      try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Claims the run once (the main window's task may start twice).
    func begin() -> Bool {
      guard !running else { return false }
      running = true
      return true
    }

    /// Shows one state: lets it settle, tells the driver which window to
    /// capture, and waits for its ack.
    func shoot(_ name: String, window: NSWindow?, settle: Double = 0.8) async {
      guard wants(name) else { return }
      try? await Task.sleep(for: .seconds(settle))
      counter += 1
      let number = window?.windowNumber ?? 0
      write("current.txt", "\(counter)\t\(name)\t\(number)\n")
      log("shoot \(counter) \(name) window \(number)")
      let ack = directory.appendingPathComponent("ack-\(counter)")
      let deadline = Date().addingTimeInterval(45)
      while !FileManager.default.fileExists(atPath: ack.path), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if !FileManager.default.fileExists(atPath: ack.path) { log("no ack for \(name)") }
    }

    func finish() {
      write("current.txt", "done\n")
      log("done")
    }

    // MARK: - Windows

    static var mainWindow: NSWindow? {
      NSApp.windows.first {
        $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
      } ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title == "Mindloom" }
    }

    static var settingsWindow: NSWindow? {
      NSApp.windows.first {
        $0.isVisible && ($0.identifier?.rawValue.contains("Settings") == true)
      }
    }

    /// Settings above the main window (not above other Apps): a check run
    /// starts in the background, where opening Settings may leave it behind
    /// the main window, and the capture would show the main window.
    static func raiseSettings() {
      guard let settings = settingsWindow, let main = mainWindow else { return }
      settings.order(.above, relativeTo: main.windowNumber)
    }

    static var welcomeWindow: NSWindow? {
      NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("welcome") == true }
    }

    /// Scrolls the page's scroll view (the widest one in `window`) to its
    /// end, as the pointer's wheel would; lazy rows are drawn on the way.
    static func scrollToEnd(_ window: NSWindow?) async {
      guard let root = window?.contentView else { return }
      func scrollViews(_ view: NSView) -> [NSScrollView] {
        let own: [NSScrollView] = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
      }
      guard let page = scrollViews(root).max(by: { $0.frame.width < $1.frame.width }) else {
        return
      }
      for _ in 0..<40 {
        guard let document = page.documentView else { return }
        let clip = page.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        let y = document.isFlipped ? bottom : 0
        if abs(clip.bounds.origin.y - y) < 1 { break }
        clip.scroll(to: NSPoint(x: 0, y: y))
        page.reflectScrolledClipView(clip)
        try? await Task.sleep(for: .milliseconds(120))
      }
    }

    static func windowList() -> String {
      NSApp.windows.map {
        "\($0.windowNumber) \($0.identifier?.rawValue ?? "-") '\($0.title)' visible=\($0.isVisible) \(NSStringFromRect($0.frame))"
      }.joined(separator: "\n")
    }

    // MARK: - Menus (a context menu opened by a synthetic right-click)

    /// A context menu, as a right-click at `point` (the window content's
    /// top-left coordinates) opens it. Its tracking loop holds the main
    /// thread, so a separate thread tells the driver, waits for the ack and
    /// closes the menu with Escape (`postEvent` may be called from any
    /// thread).
    func shootMenu(
      _ name: String, window: NSWindow, at point: CGPoint, posted: Bool = false, button: Bool = false
    ) async {
      guard wants(name) else { return }
      counter += 1
      let n = counter
      let number = window.windowNumber
      let folder = directory
      let height = window.contentView?.bounds.height ?? window.frame.height
      let location = NSPoint(x: point.x, y: height - point.y)
      let now = ProcessInfo.processInfo.systemUptime
      guard
        let down = NSEvent.mouseEvent(
          with: button ? .leftMouseDown : .rightMouseDown, location: location, modifierFlags: [],
          timestamp: now,
          windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      else { return }
      log("menu \(n) \(name) at \(location)")
      nonisolated(unsafe) let app = NSApplication.shared
      Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.9)
        try? Data("\(n)\t\(name)\t\(number)\n".utf8).write(
          to: folder.appendingPathComponent("current.txt"), options: .atomic)
        let ack = folder.appendingPathComponent("ack-\(n)")
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: ack.path), Date() < deadline {
          Thread.sleep(forTimeInterval: 0.1)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          guard
            let key = NSEvent.keyEvent(
              with: type, location: .zero, modifierFlags: [], timestamp: now,
              windowNumber: number, context: nil, characters: "\u{1b}",
              charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
          else { continue }
          app.postEvent(key, atStart: false)
        }
      }
      // The view under the point gives its context menu (SwiftUI's
      // `.contextMenu`), shown as a right-click shows it.
      var view = posted || button ? nil : (window.contentView?.superview ?? window.contentView)?.hitTest(location)
      var menu: NSMenu?
      while let current = view, menu == nil {
        menu = current.menu(for: down)
        if menu == nil { view = current.superview }
      }
      if let menu, let view {
        log("menu \(n) items: " + menu.items.map(\.title).joined(separator: " | "))
        NSMenu.popUpContextMenu(menu, with: down, for: view)
      } else if let up = NSEvent.mouseEvent(
        with: button ? .leftMouseUp : .rightMouseUp, location: location, modifierFlags: [],
        timestamp: now + 0.05,
        windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
      {
        // Through the event queue, as the pointer's own click arrives.
        log("posting a right-click at \(location)")
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
      }
      let ack = directory.appendingPathComponent("ack-\(n)")
      let deadline = Date().addingTimeInterval(50)
      while !FileManager.default.fileExists(atPath: ack.path), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  /// The forced Home hover (`mindloomForcedHover`) while a run asks for it.
  struct LiveShotsProbe: ViewModifier {
    @ObservedObject var shots: LiveShots

    func body(content: Content) -> some View {
      content.environment(\.mindloomForcedHover, shots.forcedHover)
    }
  }

  extension View {
    @ViewBuilder
    func liveShotsProbe() -> some View {
      if let shots = LiveShots.shared {
        modifier(LiveShotsProbe(shots: shots))
      } else {
        self
      }
    }
  }

  // MARK: - The run

  extension ContentView {
    /// The live verification run (`LiveShots`), from the main window's task.
    func runLiveShots() async {
      guard let shots = LiveShots.shared, shots.begin() else { return }
      if UserDefaults.standard.bool(forKey: "MindloomLiveForgetKeys") {
        // The spaces loop makes this root's device key at launch: once it
        // has run, everything of the root goes.
        try? await Task.sleep(for: .seconds(5))
        LiveShots.forgetRootKeys(shots)
        // `-MindloomLiveForgetRoot <path>[,<path>…]`: other synthetic roots'
        // items too (never opened here; a root's path names its Keychain
        // account; each must still hold the synthetic marker).
        if let other = PreviewLaunch.value("-MindloomLiveForgetRoot") {
          for path in other.split(separator: ",") where path.hasPrefix("/") {
            LiveShots.forgetRootKeys(
              shots, root: URL(fileURLWithPath: String(path), isDirectory: true))
          }
        }
        shots.finish()
        return
      }
      let appeared = Date()
      // First content: Home's matters derived from the real root.
      let deadline = Date().addingTimeInterval(60)
      while memoryScreen.base.digest?.matters.isEmpty ?? true, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      let content = Date()
      let start = PreviewLaunch.processStart
      let matters = memoryScreen.base.digest?.matters.count ?? 0
      shots.write(
        "timings.txt",
        """
        process_start_to_window_s\t\(start.map { appeared.timeIntervalSince($0) } ?? -1)
        process_start_to_first_content_s\t\(start.map { content.timeIntervalSince($0) } ?? -1)
        window_to_first_content_s\t\(content.timeIntervalSince(appeared))
        matters\t\(matters)
        people\t\(memoryScreen.base.people.count)
        unfiled\t\(memoryScreen.base.unfiled.count)
        link\t\(model.remoteOrganizerEnabled ? "on" : "off") \(String(describing: model.remoteOrganizerLinkStatus))

        """)
      if PreviewLaunch.value("-MindloomLiveLink") == "on" {
        await liveLink(shots)
        if UserDefaults.standard.bool(forKey: "MindloomLiveUnpinAll") { await liveUnpinAll(shots) }
        if UserDefaults.standard.bool(forKey: "MindloomLiveShare"), let main = LiveShots.mainWindow {
          main.setContentSize(NSSize(width: 1188, height: 848))
          main.center()
          await liveShareFlow(shots, main)
          shots.finish()
          return
        }
      }
      shots.log("windows:\n" + LiveShots.windowList())
      shots.log("编辑 menu:\n  " + LiveShots.editMenu())
      guard let main = LiveShots.mainWindow else {
        shots.log("no main window")
        shots.finish()
        return
      }
      main.setContentSize(NSSize(width: 1188, height: 848))
      main.center()
      await liveHome(shots, main)
      await liveMatters(shots, main)
      await liveSearchAndPeople(shots, main)
      await liveOwnField(shots, main)
      await livePeopleV12(shots, main)
      await liveHistoryV12(shots, main)
      await liveReviewFixes(shots, main)
      // Pins, groups and the rename toast write to the library; with the
      // link on a pin would also reach the DGX Spark, so a link run makes
      // no corrections at all (and those steps run only when shot).
      let linkOn = PreviewLaunch.value("-MindloomLiveLink") == "on"
      if !linkOn, ["group", "home-sidebar"].contains(where: shots.wants) {
        await liveGroups(shots, main)
      }
      await liveOverlays(shots, main, corrections: !linkOn)
      if !linkOn { await liveFindKey(shots, main) }
      await liveSettings(shots)
      await liveWelcome(shots)
      await liveHUD(shots)
      await liveMeeting(shots, main)
      // The recognition models are found in the background after launch
      // (a first launch on a root compiles them); wait for that, at most
      // 3 minutes, so the run says whether dictation would be ready.
      let modelsStart = Date()
      _ = await until(180) { model.models.modelDiscoveryComplete }
      shots.append(
        "timings.txt",
        "models_wait_s\t\(Int(Date().timeIntervalSince(modelsStart)))\n")
      shots.append(
        "timings.txt",
        "link_end\t\(model.remoteOrganizerEnabled ? "on" : "off") \(String(describing: model.remoteOrganizerLinkStatus))\n"
          + "models_ready\t\(model.models.modelRuntimeReady) discovery_complete=\(model.models.modelDiscoveryComplete)"
          + " import_offer=\(CaptureState.shared.modelImportOffer.map { String(describing: $0) } ?? "none")\n"
      )
      memoryNavigation = MemoryNavigation()
      // The clone is thrown away; the Keychain items the App made for it at
      // launch (space device and seal keys) go with it.
      LiveShots.forgetRootKeys(shots)
      shots.finish()
    }

    private var liveDigest: MemoryDigest? { memoryScreen.base.digest }

    /// Waits until `done` holds (at most `seconds`); false on timeout.
    private func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while !done() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return true
    }

    /// `-MindloomLiveLink on -MindloomLiveShare YES`: 共享 end to end with
    /// the DGX Spark preview instance, through the real sheets: a new space
    /// (its invite), a matter's share sheet, 查看会共享什么 with one kind
    /// unticked, 共享, the space page and 成员, then 停止共享 and leaving
    /// with what was shared taken back, so nothing of the run stays in the
    /// space. Buttons in the sheets are pressed through their accessibility
    /// elements (the same actions a click runs). Logs ids, counts and status
    /// lines only.
    private func liveShareFlow(_ shots: LiveShots, _ main: NSWindow) async {
      func status(_ step: String) {
        let scope: String
        switch spaces.screen.scope {
        case .space(let id): scope = "space \(id.prefix(8))"
        default: scope = "\(spaces.screen.scope)"
        }
        shots.log(
          "share-flow \(step): spaces=\(spaces.screen.spaces.count) linkReady=\(spaces.screen.linkReady) busy=\(spaces.screen.busy) scope=\(scope) sheet=\(spaces.sheet?.id.prefix(14) ?? "-") status=\(spaces.screen.status ?? "-")"
        )
      }
      guard model.remoteOrganizerLinkStatus == .connected else {
        shots.log("share-flow: link not connected")
        return
      }
      _ = await until(30) { spaces.screen.linkReady }
      status("start")
      // 1. 新建共享空间 (the sheet, then its 新建 action).
      spacesActions.present(.newSpace)
      await shots.shoot("space-new", window: main, settle: 1.0)
      var draft = SpaceDraft()
      draft.name = "Mindloom 测试空间"
      spacesActions.createSpace(draft)
      let made = await until(60) {
        if case .space = spaces.screen.scope, spaces.sheet != nil { return true }
        return false
      }
      status("created \(made)")
      guard case .space(let spaceID) = spaces.screen.scope else { return }
      await shots.shoot("space-invite", window: main, settle: 1.5)
      spacesActions.present(nil)
      try? await Task.sleep(for: .milliseconds(600))
      // 2. A matter with a map: its share sheet.
      guard
        let matter = liveDigest?.matters.max(by: {
          ($0.parts.count, $0.steps.count) < ($1.parts.count, $1.steps.count)
        })
      else { return }
      shots.log("share-flow matter \(matter.eventID) parts \(matter.parts.count)")
      spacesActions.setScope(.mine)
      memoryNavigation = MemoryNavigation(path: [.matter(matter.eventID)])
      try? await Task.sleep(for: .milliseconds(800))
      spacesActions.present(.share(eventID: matter.eventID))
      _ = await until(30) { spaces.screen.shareDraft?.eventID == matter.eventID }
      status("share sheet")
      await shots.shoot("share", window: main, settle: 1.5)
      // 3. 查看会共享什么, then untick one kind that has something.
      let sheet = { main.attachedSheet ?? NSApp.windows.first { $0.isVisible && $0.sheetParent === main } }
      shots.log("share-flow windows:\n" + LiveShots.windowList() + "\nattached=\(main.attachedSheet?.windowNumber ?? -1)")
      // 查看会共享什么: the plain button at the left of the action row.
      LiveShots.click(sheet(), at: NSPoint(x: 84, y: 34))
      await shots.shoot("share-look", window: main, settle: 1.0)
      let review = spaces.screen.shareDraft?.review
      shots.log(
        "share-flow review candidates=\(review?.candidates.count ?? -1) ticked=\(review?.ticked.count ?? -1)")
      // Untick 相关的聊天和会议记录 (the second row's box).
      if let window = sheet() {
        LiveShots.click(window, at: NSPoint(x: 42, y: window.frame.height - 135))
      }
      await shots.shoot("share-look-untick", window: main, settle: 0.8)
      // 4. 共享.
      if let window = sheet() {
        LiveShots.click(window, at: NSPoint(x: window.frame.width - 52, y: 34))
      }
      let shared = await until(90) {
        spaces.sheet == nil && spaces.screen.space(spaceID)?.packages.values.contains {
          $0.active && $0.matterID == matter.eventID
        } == true
      }
      status("shared \(shared)")
      await shots.shoot("share-done", window: main, settle: 1.2)
      // 5. The space page and 成员.
      spacesActions.setScope(.space(spaceID))
      _ = await until(20) { spaces.screen.scope == .space(spaceID) }
      await shots.shoot("space-page", window: main, settle: 2.0)
      spacesActions.present(.members(spaceID: spaceID))
      await shots.shoot("space-members", window: main, settle: 1.2)
      spacesActions.present(nil)
      try? await Task.sleep(for: .milliseconds(600))
      // 6. 停止共享 from the matter's share sheet (已共享到…).
      spacesActions.setScope(.mine)
      memoryNavigation = MemoryNavigation(path: [.matter(matter.eventID)])
      try? await Task.sleep(for: .milliseconds(800))
      spacesActions.present(.share(eventID: matter.eventID))
      _ = await until(30) { spaces.screen.shareDraft?.eventID == matter.eventID }
      await shots.shoot("share-shared", window: main, settle: 1.5)
      // 停止共享: the destructive button at the left of the action row.
      LiveShots.click(sheet(), at: NSPoint(x: 70, y: 34))
      let unshared = await until(60) {
        !spaces.screen.busy && spaces.screen.space(spaceID)?.packages.values.contains {
          $0.active && $0.matterID == matter.eventID
        } != true
      }
      status("unshared \(unshared)")
      await shots.shoot("share-unshared", window: main, settle: 0.8)
      // 7. Take back every item still in the space (撤回), then leave. The
      // owner of a space cannot leave it (the DGX Spark refuses
      // `owner_cannot_leave`); its rows go when the run's space is cleared
      // on the preview instance.
      let items = Array(spaces.screen.space(spaceID)?.items.keys ?? [:].keys)
      for item in items {
        spacesActions.itemAction(spaceID, item, .withdraw, nil)
        _ = await until(30) { !spaces.screen.busy }
      }
      func active() -> Int {
        spaces.screen.space(spaceID)?.items.values.filter(\.isActive).count ?? -1
      }
      _ = await until(30) { active() == 0 }
      shots.log("share-flow withdrew \(items.count); still active in space: \(active())")
      spacesActions.leave(spaceID, true)
      let left = await until(60) { spaces.screen.space(spaceID) == nil && !spaces.screen.busy }
      status("left \(left)")
      memoryNavigation = MemoryNavigation()
      await shots.shoot("space-left", window: main, settle: 1.0)
      // This clone's own Keychain items (device, space and seal keys) go
      // with the run; the clone root is thrown away.
      LiveShots.forgetRootKeys(shots)
      shots.append("timings.txt", "share_flow\tcreated=\(made) shared=\(shared) unshared=\(unshared) left=\(left) space=\(spaceID)\n")
    }

    /// `-MindloomLiveUnpinAll YES` (with the link on): takes back every pin
    /// of this root, on the Mac and on the DGX Spark (an earlier run's pins
    /// reached the preview instance).
    private func liveUnpinAll(_ shots: LiveShots) async {
      await memoryScreen.reloadUser()
      let pins = memoryScreen.user.pins.map(\.eventID)
      for id in pins { await model.memoryCommit(.pin(eventID: id, pinned: false)) }
      try? await Task.sleep(for: .seconds(5))
      shots.append("timings.txt", "unpinned\t\(pins.joined(separator: ","))\n")
    }

    /// `-MindloomLiveLink on`: turns the DGX Spark link on (the clone root's
    /// own key; host and paths from the launch arguments) and waits for the
    /// first pull, recording how long it took and the cursor before and after.
    private func liveLink(_ shots: LiveShots) async {
      let before = model.events.remoteProjection?.cursor ?? 0
      let started = Date()
      model.setRemoteOrganizerEnabled(true)
      var connectedAt: Date?
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline {
        if connectedAt == nil, model.remoteOrganizerLinkStatus == .connected { connectedAt = Date() }
        if let cursor = model.events.remoteProjection?.cursor, cursor > before,
          model.remoteOrganizerLinkStatus == .connected
        {
          break
        }
        try? await Task.sleep(for: .milliseconds(200))
      }
      let pulled = Date().timeIntervalSince(started)
      // Let the read model catch up with the pulled state.
      try? await Task.sleep(for: .seconds(2))
      let projection = model.events.remoteProjection
      let digest = memoryScreen.base.digest
      let lines = [
        "link_status\t\(String(describing: model.remoteOrganizerLinkStatus))",
        "link_connect_s\t\(connectedAt.map { $0.timeIntervalSince(started) } ?? -1)",
        "link_first_pull_s\t\(pulled)",
        "cursor_before\t\(before)",
        "cursor_after\t\(projection?.cursor ?? -1)",
        "events_with_map\t\(projection?.events.filter { $0.map != nil }.count ?? -1)",
        "matters_after\t\(digest?.matters.count ?? -1)",
        "matters_with_parts\t\(digest?.matters.filter { !$0.parts.isEmpty }.count ?? -1)",
        "last_pull\t\(model.remoteOrganizerLastPull.map { "\($0)" } ?? "-")",
      ]
      shots.append("timings.txt", lines.joined(separator: "\n") + "\n")
    }

    private func liveHome(_ shots: LiveShots, _ main: NSWindow) async {
      memoryNavigation = MemoryNavigation()
      await shots.shoot("home", window: main, settle: 1.2)
      if let first = memoryScreen.base.home.first?.eventID {
        shots.forcedHover = first
        await shots.shoot("home-hover", window: main)
        shots.forcedHover = nil
      }
      await shots.shootMenu("home-menu", window: main, at: CGPoint(x: 560, y: 240), posted: true)
      memoryNavigation.earlierOpen = true
      await shots.shoot("home-earlier", window: main)
      memoryNavigation.earlierOpen = false
      memoryNavigation.homeLens = .deadlines
      await shots.shoot("home-deadline", window: main)
      memoryNavigation.homeLens = .people
      await shots.shoot("home-people", window: main)
      memoryNavigation.homeLens = .time
    }

    private func liveMatters(_ shots: LiveShots, _ main: NSWindow) async {
      guard let digest = liveDigest else { return }
      // The matter with the most parts and steps (an offline mirror without
      // maps has no parts: then the one with the most steps).
      let rich = digest.matters.max {
        ($0.parts.count, $0.steps.count, -$0.rank) < ($1.parts.count, $1.steps.count, -$1.rank)
      }
      guard let rich else { return }
      shots.log("matter \(rich.eventID) parts \(rich.parts.count) steps \(rich.steps.count)")
      memoryNavigation = MemoryNavigation(path: [.matter(rich.eventID)])
      await shots.shoot("matter", window: main, settle: 1.2)
      // The toolbar's 「⋯」 (a click on the button, as the pointer's own).
      await shots.shootMenu("matter-menu", window: main, at: CGPoint(x: 951, y: 26), button: true)
      let step =
        rich.steps.first { $0.evidence?.alsoIn.isEmpty == false }
        ?? rich.steps.first { $0.evidence != nil } ?? rich.steps.first
      if let step {
        memoryNavigation.popover = .step(step.id)
        await shots.shoot("matter-popover", window: main, settle: 1.0)
        memoryNavigation.popover = nil
      }
      if let part = rich.parts.first(where: { $0.closed }) ?? rich.parts.first {
        memoryNavigation.popover = .segment(part.id)
        await shots.shoot("matter-fold", window: main, settle: 1.0)
        memoryNavigation.popover = nil
      }
      memoryNavigation.matterTab = .text
      await shots.shoot("matter-text", window: main, settle: 1.0)
      // On the first item's words (its own menu), not the gap between items.
      // Posted as the pointer's own right-click: the catcher over the
      // selectable words takes it only for a real right-click.
      await shots.shootMenu("matter-text-menu", window: main, at: CGPoint(x: 600, y: 242), posted: true)
      // The words focused by a double-click, then the right-click: no
      // selection, so no 「复制所选」. Then six characters selected (through
      // accessibility; posted clicks select nothing while this App is not
      // the active one) and the right-click again: the menu starts with
      // 「复制所选」 (review finish-ship). Nothing is copied: the menu is
      // closed with Escape.
      if shots.wants("matter-text-select") {
        LiveShots.doubleClick(main, atTopLeft: CGPoint(x: 600, y: 242))
        try? await Task.sleep(for: .milliseconds(600))
        let responder = main.firstResponder
        let frame = (responder as? NSView).map { NSStringFromRect($0.convert($0.bounds, to: nil)) }
        shots.log(
          "selection responder: \(responder.map { String(describing: type(of: $0)) } ?? "nil") \(frame ?? "")"
            + " services=\(responder is NSServicesMenuRequestor) " + LiveShots.selectionLength(main))
        await shots.shootMenu(
          "matter-text-select-menu", window: main, at: CGPoint(x: 600, y: 242), posted: true)
        // Posted clicks may land where the real pointer is (and this App is
        // not the active one): select the first characters of the focused
        // words through accessibility, as an assistive App would.
        (main.firstResponder as? NSView)?.setAccessibilitySelectedTextRange(
          NSRange(location: 0, length: 6))
        try? await Task.sleep(for: .milliseconds(400))
        shots.log("after selecting 6: " + LiveShots.selectionLength(main))
        await shots.shootMenu(
          "matter-text-select-all-menu", window: main, at: CGPoint(x: 600, y: 242), posted: true)
        // Where a posted double-click lands: the focused words and what
        // they hand out (lengths only), on three items.
        if shots.routes?.contains("x-select-probe") == true {
          for y in [242.0, 360.0, 450.0] {
            LiveShots.doubleClick(main, atTopLeft: CGPoint(x: 520, y: y))
            try? await Task.sleep(for: .milliseconds(700))
            let view = main.firstResponder as? NSView
            shots.log(
              "probe y=\(y): \(view.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "nil") "
                + LiveShots.selectionLength(main))
            await shots.shoot("x-select-probe-\(Int(y))", window: main, settle: 0.3)
          }
        }
      }
      if let item = rich.itemIDs.first {
        memoryNavigation.sheet = .move(.item(eventID: rich.eventID, itemID: item, segID: nil))
        await shots.shoot("move-text", window: main, settle: 1.0)
        memoryNavigation.sheet = nil
      }
      if let step = rich.steps.first(where: { $0.evidence != nil }) {
        memoryNavigation.matterTab = .progress
        memoryNavigation.sheet = .move(.step(eventID: rich.eventID, stepID: step.id))
        await shots.shoot("move-item", window: main, settle: 1.0)
        memoryNavigation.sheet = nil
      }
      memoryNavigation.matterTab = .progress
      if let small = digest.matters.first(where: { $0.parts.isEmpty }) {
        memoryNavigation = MemoryNavigation(path: [.matter(small.eventID)])
        await shots.shoot("matter-small", window: main, settle: 1.0)
      }
      if let over = digest.matters.first(where: { $0.overdue != nil && $0.eventID != rich.eventID }) {
        memoryNavigation = MemoryNavigation(path: [.matter(over.eventID)])
        await shots.shoot("matter-over", window: main, settle: 1.0)
      }
      memoryNavigation = MemoryNavigation(path: [.matter(rich.eventID)])
      memoryNavigation.renaming = rich.eventID
      await shots.shoot("rename", window: main, settle: 0.8)
      memoryNavigation.renaming = nil
    }

    private func liveSearchAndPeople(_ shots: LiveShots, _ main: NSWindow) async {
      memoryNavigation = MemoryNavigation(root: .search)
      await shots.shoot("search-empty", window: main)
      let title = liveDigest?.matters.first?.title ?? "实验"
      let query = String(title.filter { !$0.isWhitespace }.prefix(2))
      memoryNavigation.search = query
      await shots.shoot("search", window: main, settle: 1.2)
      if let person = memoryScreen.base.featuredPeople.first ?? memoryScreen.base.people.first {
        memoryNavigation.search = String(person.name.suffix(2))
        await shots.shoot("search-person", window: main, settle: 1.2)
        memoryNavigation = MemoryNavigation(path: [.person(person.personID)])
        await shots.shoot("people", window: main, settle: 1.0)
      }
      memoryNavigation = MemoryNavigation(root: .search, search: "火星基地")
      await shots.shoot("search-none", window: main)
      // v12 find: 历史 with conditions read out of the query, a homophone
      // typo, the list scrolled to load the next page, and 加进词典.
      memoryNavigation = MemoryNavigation(root: .search, search: "上周 微信")
      await shots.shoot("x-history-chips", window: main, settle: 1.2)
      memoryNavigation = MemoryNavigation(root: .search, search: "穹鼎 实习")
      await shots.shoot("x-history-typo", window: main, settle: 1.2)
      memoryNavigation = MemoryNavigation(root: .search)
      if shots.wants("x-history-page2") {
        try? await Task.sleep(for: .seconds(1.2))
        for _ in 0..<12 where historySearch.state.hasMore {
          historySearch.loadMore()
          try? await Task.sleep(for: .milliseconds(400))
        }
        let loaded = historySearch.state.rows.count
        shots.log("history rows \(loaded) of \(historySearch.state.total ?? -1)")
        await shots.shoot("x-history-page2", window: main, settle: 0.6)
      }
      if let row = historySearch.state.rows.first {
        memoryNavigation.sheet = .addToDictionary(itemID: row.itemID)
        await shots.shoot("x-history-dictionary", window: main, settle: 1.0)
        memoryNavigation.sheet = nil
        if shots.wants("x-history-dictionary") {
          // What 加进词典 saves (on the clone), as Settings › 口述 then lists it.
          let note = await model.addHeardWordToDictionary(heard: "穹鼎", written: "穹顶")
          let again = await model.addHeardWordToDictionary(heard: "琼顶", written: "穹顶")
          let words = (try? await model.repository?.allDictionaryEntries()) ?? []
          shots.log(
            "dictionary add: \(note ?? "ok") / \(again ?? "ok"); entries "
              + words.map { "\($0.canonicalForm)<\($0.spokenForms.joined(separator: ","))>" }
              .joined(separator: " "))
        }
      }
      memoryNavigation = MemoryNavigation()
    }

    /// 收1-11: a dictation that ends in Mindloom's own search field is
    /// written into it directly, through the insertion port's own-field
    /// route (no microphone, no clipboard): the field takes the words as
    /// typing would, without the final 「。」, and the search runs on them.
    private func liveOwnField(_ shots: LiveShots, _ main: NSWindow) async {
      guard shots.wants("x-dictation-own-field") else { return }
      memoryNavigation = MemoryNavigation()
      try? await Task.sleep(for: .milliseconds(500))
      NotificationCenter.default.post(name: .mindloomFocusSearch, object: nil)
      try? await Task.sleep(for: .milliseconds(500))
      let title = liveDigest?.matters.first?.title ?? "实验"
      let said = String(title.filter { !$0.isWhitespace }.prefix(2)) + "。"
      guard let field = AppKitOwnTextInput.input(in: main),
        let words = DeliveryInsertionPort.ownFieldText(said, into: field)
      else {
        shots.log("own field: no focused field in the main window")
        return
      }
      field.insert(words)
      let query = memoryNavigation.search
      shots.log("own field: single-line=\(field.isSingleLine) field=\(field.text) query=\(query)")
      await shots.shoot("x-dictation-own-field", window: main, settle: 1.2)
      main.makeFirstResponder(nil)
      memoryNavigation = MemoryNavigation()
    }

    /// v12 integration, on the clone only: 历史 with a person, a time and a
    /// source read out of the query next to a content word; and ▶ on a
    /// record that has audio — a synthetic recording made on the clone
    /// through the App's own capture coordinator and journal
    /// (`LiveSyntheticRecording`: nearly silent synthetic samples, no
    /// microphone, no model), then played from the sentence the query
    /// matched, as the row's ▶ does. Logs counts and synthetic words only.
    private func liveHistoryV12(_ shots: LiveShots, _ main: NSWindow) async {
      if shots.wants("x-history-full") {
        let query = "许嘉禾 上个月 微信 论文"
        memoryNavigation = MemoryNavigation(root: .search, search: query)
        _ = await until(8) {
          historySearch.state.query == query && !historySearch.state.loading
            && historySearch.state.total != nil
        }
        shots.log(
          "history full: chips=" + historySearch.state.chips.map(\.label).joined(separator: " | ")
            + " total=\(historySearch.state.total ?? -1) rows=\(historySearch.state.rows.count)")
        await shots.shoot("x-history-full", window: main, settle: 1.2)
      }
      guard shots.wants("x-history-playing") else { return }
      guard let session = await LiveSyntheticRecording.make(model: model, shots: shots) else {
        memoryNavigation = MemoryNavigation()
        return
      }
      model.refreshHistory()
      let itemID = session.rawValue.uuidString.uppercased()
      let query = "印刷文件"
      // The index follows the library a second after it changes.
      var row: MemoryHistoryRow?
      for attempt in 0..<4 where row == nil {
        memoryNavigation = MemoryNavigation(root: .search, search: attempt.isMultiple(of: 2) ? query : query + " ")
        _ = await until(6) { historySearch.state.rows.contains { $0.itemID == itemID } }
        row = historySearch.state.rows.first { $0.itemID == itemID }
      }
      guard let row else {
        shots.log("synthetic recording: not in 历史 for \(query)")
        memoryNavigation = MemoryNavigation()
        return
      }
      shots.log(
        "synthetic row: playable=\(row.playable) from=\(row.playFrom.map(String.init) ?? "start")"
          + " line=\(row.line)")
      memoryActions.history.play(row.itemID, row.playFrom)
      let playing = await until(10) { model.playback.playbackIsPlaying }
      try? await Task.sleep(for: .milliseconds(700))
      shots.log(
        "synthetic playback: playing=\(playing) position=\(String(format: "%.1f", model.playback.playbackPosition)) s")
      await shots.shoot("x-history-playing", window: main, settle: 0.3)
      if model.playback.playbackIsPlaying { model.toggleHistoryPlayback() }
      try? await Task.sleep(for: .milliseconds(300))
      shots.log("synthetic playback paused: playing=\(model.playback.playbackIsPlaying)")
      memoryNavigation = MemoryNavigation()
    }

    /// v12 phase B review fixes, on the clone only (synthetic data): 历史's
    /// 「还有 N 件」 and the page it opens (#15); a row's menu entries and its
    /// 删除… confirmation, a record exported through the history exporter
    /// into the run folder and the synthetic recording's source audio
    /// exported as WAV (#6; the save panel is the system's and is not
    /// driven); a pasted synthetic record deleted and gone from the list;
    /// the menu bar's rows in demo mode (#7). Logs counts and synthetic words.
    private func liveReviewFixes(_ shots: LiveShots, _ main: NSWindow) async {
      if shots.wants("x-history-matters") {
        var found: String?
        for query in ["实验", "论文", "数据", "报告", "会议", "结果", "交", "周"] {
          memoryNavigation = MemoryNavigation(root: .search, search: query)
          _ = await until(6) {
            historySearch.state.query == query && !historySearch.state.loading
              && historySearch.state.total != nil
          }
          if historySearch.state.matters.count > HistoryPage.mattersShown {
            found = query
            break
          }
        }
        if let query = found {
          shots.log("history matters: 「\(query)」 \(historySearch.state.matters.count) matters")
          await shots.shoot("x-history-matters", window: main, settle: 1.0)
          memoryNavigation = MemoryNavigation(
            root: .search, path: [.matterResults(query)], search: query)
          await shots.shoot("x-history-matters-all", window: main, settle: 1.2)
        } else {
          shots.log("history matters: no query found more than five matters")
        }
      }
      if shots.wants("x-history-row") {
        let query = "印刷文件"
        memoryNavigation = MemoryNavigation(root: .search, search: query)
        _ = await until(6) { historySearch.state.query == query && !historySearch.state.loading }
        if let recording = historySearch.state.rows.first(where: \.playable) {
          shots.log(
            "row menu (recording): " + Self.describe(HistoryRowMenu.entries(for: recording)))
          await liveExportRecord(recording.itemID, shots: shots)
        } else {
          shots.log("row menu: no synthetic recording in 历史")
        }
        memoryNavigation = MemoryNavigation(root: .search)
        _ = await until(6) {
          historySearch.state.query.isEmpty && !historySearch.state.rows.isEmpty
        }
        if let pasted = historySearch.state.rows.first(where: { !$0.playable }) {
          shots.log(
            "row menu (no recording): " + Self.describe(HistoryRowMenu.entries(for: pasted)))
          memoryActions.history.delete(pasted.itemID)
          _ = await until(4) { pendingHistoryDeletion != nil }
          await shots.shoot("x-history-row-delete", window: main, settle: 0.8)
          // Deleted on the clone, as 删除记录和保留原音 does it.
          if let item = pendingHistoryDeletion {
            pendingHistoryDeletion = nil
            let before = historySearch.state.total ?? -1
            model.deleteHistoryItem(item) { [historySearch] in
              historySearch.forgetRow(item.sessionID.rawValue.uuidString.uppercased())
            }
            let gone = await until(6) {
              !historySearch.state.rows.contains { $0.itemID == pasted.itemID }
            }
            let stored = try? await model.repository?.load(sessionID: item.sessionID)
            shots.log(
              "row delete: left the list=\(gone) total \(before)→"
                + "\(historySearch.state.total ?? -1)"
                + " record in library=\(stored != nil)")
            await shots.shoot("x-history-row-deleted", window: main, settle: 0.6)
          }
        }
        memoryNavigation = MemoryNavigation()
      }
      shots.log(
        "menu bar rows (demo=\(MindloomLaunch.isDemo)): "
          + MenuBarExtraRow.rows(
            link: MemoryScreenModel.link(model), recording: nil, meeting: model.meetingMenu,
            demo: MindloomLaunch.isDemo
          ).compactMap { row -> String? in
            switch row {
            case .action(_, let title, _, _), .header(let title, _, _, _),
              .submenu(_, let title, _, _):
              title
            case .separator: "─"
            }
          }.joined(separator: " | "))
    }

    /// 导出文字与字幕 › SRT and 导出原音… for one record, without the save
    /// panel: the record opened as the row opens it, then the same exporter
    /// and journal calls, into the run folder.
    private func liveExportRecord(_ itemID: String, shots: LiveShots) async {
      guard let session = model.sessionID(itemID),
        let item = await model.openRecord(session, forPlaying: true), let journal = model.journal
      else {
        shots.log("export: the record did not open")
        return
      }
      let context = LocalHistoryExportContext(
        history: item, transcripts: model.history.selectedHistoryTranscripts,
        documents: model.history.selectedHistoryDocuments,
        speakers: model.people.selectedSessionSpeakers,
        occurrences: model.selectedSessionOccurrences)
      let text = shots.directory.appendingPathComponent("export-\(UUID().uuidString.prefix(6)).srt")
      do {
        try await model.historyExporter.exportText(format: .srt, context: context, to: text)
        let srt = (try? String(contentsOf: text, encoding: .utf8)) ?? ""
        shots.log(
          "export srt: \(srt.utf8.count) bytes, "
            + "\(srt.components(separatedBy: " --> ").count - 1) cues")
      } catch {
        shots.log("export srt failed: \(error)")
      }
      if let track = UUID(uuidString: model.playback.selectedHistoryPlaybackTrackID) {
        let wav = shots.directory.appendingPathComponent(
          "export-\(UUID().uuidString.prefix(6)).wav")
        do {
          _ = try await journal.exportSourceTrackAsWave(
            sessionID: session, trackID: TrackID(track), to: wav, monotonicRange: nil)
          let size = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          shots.log("export wav: \(size) bytes")
        } catch {
          shots.log("export wav failed: \(error)")
        }
      } else {
        shots.log("export wav: no track selected")
      }
    }

    static func describe(_ entries: [HistoryRowMenu.Entry]) -> String {
      entries.map { entry in
        switch entry {
        case .copy: "拷贝"
        case .share: "共享…"
        case .addToDictionary: "添加到词典…"
        case .exportText(let kinds):
          HistoryRowMenu.exportTextTitle(kinds) + " › "
            + kinds.map(\.title).joined(separator: " ")
        case .exportAudio: "导出录音…"
        case .openMatter: "打开所在的事"
        case .delete: "删除…"
        case .divider: "─"
        }
      }.joined(separator: " | ")
    }

    /// v12 people and Home (理3-1, 理1-4), on the clone only: 按人 with the
    /// unnamed voices (a seeded clone), an unnamed person's page, naming it
    /// (the same correction the title field sends; committed after the undo
    /// window and read back), 合并到… with its toast and 撤销, and two
    /// synthetic texts taken in to show 「刚收进来」 with its count. Logs
    /// counts and synthetic names only.
    private func livePeopleV12(_ shots: LiveShots, _ main: NSWindow) async {
      guard ["x-people", "x-home-waiting"].contains(where: shots.wants) else { return }
      func people() -> [MemoryPersonEntry] { memoryScreen.base.people }
      let unnamed = people().filter { !$0.isNamed && $0.hasVoice }
        .sorted { ($0.unnamedNumber ?? .max) < ($1.unnamedNumber ?? .max) }
      shots.log(
        "people \(people().count) voices \(people().filter(\.hasVoice).count) unnamed "
          + unnamed.map { "\($0.name)=\($0.voiceRecords)" }.joined(separator: ","))
      memoryNavigation = MemoryNavigation(homeLens: .people)
      await shots.shoot("x-people-home", window: main, settle: 1.2)
      if shots.wants("x-people-home-end") {
        await LiveShots.scrollToEnd(main)
        await shots.shoot("x-people-home-end", window: main, settle: 0.8)
      }
      if let first = unnamed.first {
        memoryNavigation = MemoryNavigation(path: [.person(first.personID)], homeLens: .people)
        await shots.shoot("x-people-unnamed", window: main, settle: 1.0)
        memoryNavigation.renaming = first.personID
        await shots.shoot("x-people-naming", window: main, settle: 0.8)
        memoryNavigation.renaming = nil
        memoryActions.correct(.namePerson(personID: first.personID, from: "", to: "虚构丙"))
        await shots.shoot("x-people-named", window: main, settle: 0.6)
        // After the undo window: written to the clone, read back.
        try? await Task.sleep(for: .seconds(9))
        await model.refreshPeopleNow()
        _ = await until(5) { memoryScreen.base.person(first.personID)?.name == "虚构丙" }
        shots.log(
          "named: page=\(memoryScreen.base.person(first.personID)?.name ?? "-") library="
            + (model.localPersonSummary(first.personID)?.person.displayName ?? "-"))
        await shots.shoot("x-people-named-saved", window: main, settle: 0.6)
        if let second = unnamed.dropFirst().first {
          memoryNavigation = MemoryNavigation(path: [.person(second.personID)], homeLens: .people)
          memoryNavigation.sheet = .mergePerson(second.personID)
          await shots.shoot("x-people-merge-sheet", window: main, settle: 1.0)
          memoryNavigation.sheet = nil
          memoryActions.correct(.mergePerson(personID: second.personID, into: first.personID))
          memoryNavigation = MemoryNavigation(path: [.person(first.personID)], homeLens: .people)
          await shots.shoot("x-people-merged", window: main, settle: 0.6)
          memoryScreen.undo()
          memoryNavigation = MemoryNavigation(homeLens: .people)
          try? await Task.sleep(for: .seconds(1))
          await LiveShots.scrollToEnd(main)
          await shots.shoot("x-people-merge-undone", window: main, settle: 0.8)
          shots.log(
            "merge undone: \(second.name) back=\(memoryScreen.base.person(second.personID) != nil)")
        }
      }
      guard shots.wants("x-home-waiting") else { return }
      model.receive(
        [
          .text("合成测试：周五前把海报初稿发给虚构甲", extractor: "pasteboard-text-v1"),
          .text("合成测试：下周二上午约虚构乙对一下预算", extractor: "pasteboard-text-v1"),
        ], source: ItemSourceApplication(bundleID: nil, name: "微信"), origin: .unknown)
      _ = await until(10) { memoryScreen.base.isLoaded && model.memorySourceItems.count > 0 }
      try? await Task.sleep(for: .seconds(3))
      memoryNavigation = MemoryNavigation()
      let state = memoryScreen.state(app: model, capture: nil)
      var patched = state
      patchHomeState(&patched)
      shots.log(
        "waiting \(patched.homeExtras.waitingTotal) shown \(patched.waitingCaptures.count)"
          + " link \(patched.link.status)")
      await shots.shoot("x-home-waiting", window: main, settle: 1.2)
    }

    /// Makes pins and a group on the clone root the way a user would (the
    /// sidebar then shows 置顶 and 分组), and shoots their pages.
    private func liveGroups(_ shots: LiveShots, _ main: NSWindow) async {
      guard let digest = liveDigest, digest.matters.count >= 4 else { return }
      memoryNavigation = MemoryNavigation()
      memoryNavigation.sheet = .newGroup(moving: nil)
      await shots.shoot("group-new", window: main, settle: 1.0)
      memoryNavigation.sheet = nil
      let matters = Array(digest.matters.prefix(6))
      for matter in matters.prefix(2) where !memoryScreen.user.isPinned(matter.eventID) {
        memoryScreen.submit(.pin(eventID: matter.eventID, pinned: true))
      }
      let existing = memoryScreen.base.groups.first { $0.name == "论文" }
      var groupID = existing?.id
      if groupID == nil, let group = await model.memoryCreateGroup(name: "论文", moving: matters[2].eventID) {
        groupID = group.id
        for matter in matters[3...4] {
          try? await model.repository?.moveToUserGroup(
            eventID: matter.eventID, groupID: group.id, at: Date())
        }
      }
      var emptyID: UUID?
      if let empty = await model.memoryCreateGroup(name: "课题组杂事", moving: nil) { emptyID = empty.id }
      await memoryScreen.reloadUser()
      try? await Task.sleep(for: .milliseconds(400))
      memoryScreen.dismissToast()
      if let groupID {
        memoryNavigation = MemoryNavigation(root: .group(groupID.uuidString.lowercased()))
        await shots.shoot("group", window: main, settle: 1.2)
      }
      if let emptyID {
        let route = emptyID.uuidString.lowercased()
        memoryNavigation = MemoryNavigation(root: .group(route))
        await shots.shoot("group-empty", window: main, settle: 1.0)
        memoryNavigation.sheet = .addToGroup(route)
        await shots.shoot("group-add", window: main, settle: 1.0)
        memoryNavigation.sheet = nil
      }
      memoryNavigation = MemoryNavigation()
      await shots.shoot("home-sidebar", window: main, settle: 1.0)
      await liveGroupMade(shots, main)
    }

    /// 新建分组 through the page's own action (as the sheet's 新建 calls it):
    /// the new group's page must open on its empty page, never on
    /// 「这个分组已经删掉了」, not even for a frame (finish-mac).
    private func liveGroupMade(_ shots: LiveShots, _ main: NSWindow) async {
      guard shots.wants("group-made") else { return }
      memoryNavigation = MemoryNavigation()
      try? await Task.sleep(for: .milliseconds(300))
      memoryActions.createGroup("新建的分组", nil)
      var samples = 0
      var gone = 0
      var opened: String?
      let deadline = Date().addingTimeInterval(2)
      while Date() < deadline {
        if case .group(let id) = memoryNavigation.root {
          opened = id
          samples += 1
          let state = memoryScreen.state(app: model, capture: nil)
          if state.group(id) == nil { gone += 1 }
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
      shots.log("group-made opened=\(opened ?? "-") samples=\(samples) gone=\(gone)")
      shots.append("timings.txt", "group_made_gone_samples\t\(gone)/\(samples)\n")
      await shots.shoot("group-made", window: main, settle: 0.1)
      memoryNavigation = MemoryNavigation()
    }

    /// ⌘F posted as a key press: the search field takes the keyboard (the
    /// system's 查找… is back in 编辑 but must not take the key).
    private func liveFindKey(_ shots: LiveShots, _ main: NSWindow) async {
      guard shots.wants("x-find-key"), let first = liveDigest?.matters.first else { return }
      memoryNavigation = MemoryNavigation(path: [.matter(first.eventID)])
      try? await Task.sleep(for: .milliseconds(600))
      main.makeFirstResponder(nil)
      let now = ProcessInfo.processInfo.systemUptime
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let key = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: .command, timestamp: now,
          windowNumber: main.windowNumber, context: nil, characters: "f",
          charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)
        {
          NSApp.postEvent(key, atStart: false)
        }
      }
      try? await Task.sleep(for: .milliseconds(600))
      let responder = main.firstResponder
      shots.log("x-find-key first responder: \(responder.map { String(describing: type(of: $0)) } ?? "-") text=\(responder is NSTextView)")
      await shots.shoot("x-find-key", window: main, settle: 0.2)
      main.makeFirstResponder(nil)
      memoryNavigation = MemoryNavigation()
    }

    private func liveOverlays(_ shots: LiveShots, _ main: NSWindow, corrections: Bool) async {
      guard let digest = liveDigest, let first = digest.matters.first else { return }
      memoryNavigation = MemoryNavigation(path: [.matter(first.eventID)])
      try? await Task.sleep(for: .milliseconds(500))
      spacesActions.present(.share(eventID: first.eventID))
      await shots.shoot("share", window: main, settle: 1.2)
      spacesActions.present(nil)
      try? await Task.sleep(for: .milliseconds(400))
      memoryNavigation = MemoryNavigation()
      // A correction's toast (held 8 s, with 撤销), then undone.
      if corrections, shots.wants("x-toast-undo"), let target = digest.matters.dropFirst(5).first {
        memoryScreen.submit(.rename(eventID: target.eventID, from: target.title, to: target.title + "（改）"))
        await shots.shoot("x-toast-undo", window: main, settle: 0.8)
        memoryScreen.undo()
      }
      highlightAndToast(first)
      await shots.shoot("organized", window: main, settle: 0.6)
      memoryScreen.dismissToast()
      memoryScreen.highlightedEventID = nil
      dropTargeted = true
      await shots.shoot("drop", window: main, settle: 0.8)
      dropTargeted = false
    }

    private func highlightAndToast(_ matter: MatterDigest) {
      memoryScreen.highlightedEventID = matter.eventID
      memoryScreen.show(
        MemoryToast(
          "已归入“\(matter.title)”", icon: .none,
          action: .view(eventID: matter.eventID, stepID: nil)))
    }

    private func liveSettings(_ shots: LiveShots) async {
      let panes: [(SettingsPane, String)] = [
        (.general, "settings-general"), (.dictation, "settings-dictation"),
        (.entries, "settings-entries"),
        (.devices, "settings-devices"),
        (.apps, "settings-apps"), (.about, "settings-about"),
      ]
      guard panes.contains(where: { shots.wants($0.1) }) else { return }
      for (pane, name) in panes {
        SettingsRouter.shared.open(pane)
        try? await Task.sleep(for: .milliseconds(500))
        LiveShots.raiseSettings()
        await shots.shoot(name, window: LiveShots.settingsWindow, settle: 0.8)
      }
      // `-MindloomLiveTimeZone <zone>`: 通用 › 时区 changed as the picker
      // does (saved in the library, applied at once), then shot again.
      if let zone = PreviewLaunch.value("-MindloomLiveTimeZone"), shots.wants("settings-general") {
        model.setProductTimeZone(zone)
        SettingsRouter.shared.open(.general)
        try? await Task.sleep(for: .milliseconds(500))
        let now = model.productTimeZone.identifier
        shots.log("product time zone now \(now) (process \(TimeZone.current.identifier))")
        LiveShots.raiseSettings()
        await shots.shoot("settings-general-changed", window: LiveShots.settingsWindow, settle: 0.8)
      }
      // v12 F6: one App's own page (its changes with 撤销, every call), on
      // whatever App the library's records name first.
      if shots.wants("settings-app-page") {
        await model.agentAccess.refresh()
        let key =
          model.agentAccess.changes.first?.clientKey ?? model.agentAccess.grants.first?.clientKey
          ?? model.agentAccess.audit.first { $0.clientName != "unknown" }?.clientKey
        if let key {
          model.agentAccess.openApp = key
          SettingsRouter.shared.open(.apps)
          try? await Task.sleep(for: .milliseconds(900))
          LiveShots.raiseSettings()
          await shots.shoot("settings-app-page", window: LiveShots.settingsWindow, settle: 0.8)
          // 撤销 as the page's button does it: the newest change of a kind
          // the run names (`-MindloomLiveUndo rename_matter,mark_step,…`).
          if shots.wants("settings-app-page-undone"),
            let kinds = PreviewLaunch.value("-MindloomLiveUndo")?.split(separator: ",")
          {
            for kind in kinds {
              guard
                let change = model.agentAccess.changes.first(where: {
                  $0.clientKey == key && $0.kind.rawValue == kind && $0.state == .applied
                })
              else { continue }
              model.undoAgentChange(change.changeID)
              shots.log("undo \(kind) \(change.changeID.uuidString.lowercased())")
              try? await Task.sleep(for: .milliseconds(1_500))
            }
            await model.agentAccess.refresh()
            let undone = model.agentAccess.changes.filter { $0.state == .undone }.count
            shots.log("changes undone: \(undone)")
            try? await Task.sleep(for: .milliseconds(600))
            LiveShots.raiseSettings()
            await shots.shoot(
              "settings-app-page-undone", window: LiveShots.settingsWindow, settle: 0.8)
          }
          model.agentAccess.openApp = nil
        } else {
          shots.log("settings-app-page: no App in this library's records")
        }
      }
      LiveShots.settingsWindow?.close()
      await liveAgentCards(shots)
    }

    /// v12 F2, F3: the consent card on the real panel, for a synthetic
    /// request (nothing connects): a first call that named no matter, and a
    /// program that calls itself Claude Code but is another one. Each card is
    /// put away unanswered.
    private func liveAgentCards(_ shots: LiveShots) async {
      let cards = ["agent-consent-search", "agent-consent-matter", "agent-consent-lookalike"]
      guard cards.contains(where: shots.wants), let panel = model.agentRequestPanel else { return }
      guard let inputs = await AppAgentMemory(app: model).agentSnapshot() else {
        shots.log("agent cards: no snapshot")
        return
      }
      let matters = inputs.projection.home().prefix(6).map {
        AgentMatterOption(id: $0.eventID, title: $0.title)
      }
      let options = AgentConsentOptions(
        spaces: inputs.spaces, ropes: [], matters: Array(matters))
      let signed = AgentClientIdentity(
        name: "claude-code", path: NSHomeDirectory() + "/.local/share/claude/versions/2.1.3/claude",
        signer: "team:ANTHRTEAM1:com.anthropic.claude-code", signerName: "Anthropic PBC")
      let impostor = AgentClientIdentity(name: "claude-code", path: "/tmp/x/claude")
      let requests: [(String, AgentConsentRequest)] = [
        (
          "agent-consent-search",
          AgentConsentRequest(client: signed, options: options, requestedAt: Date())
        ),
        // The first call named a matter: only that one is ticked, read only.
        (
          "agent-consent-matter",
          AgentConsentRequest(
            client: signed, options: options, requestedAt: Date(), requestedMatter: matters.first)
        ),
        (
          "agent-consent-lookalike",
          AgentConsentRequest(
            client: impostor, options: options, requestedAt: Date(),
            requestedMatter: matters.first,
            lookalike: AgentLookalike(name: "Claude Code", path: signed.shownPath),
            wantsToChange: true)
        ),
      ]
      for (name, request) in requests where shots.wants(name) {
        model.agentAccess.enqueue(request) { _ in }
        try? await Task.sleep(for: .milliseconds(700))
        await shots.shoot(name, window: panel.window, settle: 0.6)
        model.agentAccess.answer(request.id, with: nil)
      }
      panel.close()
    }

    private func liveWelcome(_ shots: LiveShots) async {
      guard ["first-run", "first-run-2", "first-run-3"].contains(where: shots.wants) else { return }
      openWindow(id: "welcome")
      try? await Task.sleep(for: .milliseconds(800))
      for (step, name) in [
        (WelcomeStep.title, "first-run"), (.permissions, "first-run-2"), (.devices, "first-run-3"),
      ] {
        shots.welcomeStep = step
        await shots.shoot(name, window: LiveShots.welcomeWindow, settle: step == .title ? 2.4 : 1.0)
      }
      shots.welcomeStep = nil
      LiveShots.welcomeWindow?.close()
    }

    /// The fn HUD driven by a synthetic level, no microphone (v12 B1): press,
    /// listen with the caption, gather, typed in; a short tap left listening;
    /// 翻译 「英」, then ⇧ to 「日 · 未下载」; 指令; then how a take ends when
    /// it was only copied, nothing was heard, or it failed.
    private func liveHUD(_ shots: LiveShots) async {
      guard ["dictation", "x-dictation", "fn-tap"].contains(where: shots.wants) else { return }
      model.installFnHUD()
      let panel = model.recordingPanel
      panel.showsCaptions = true
      panel.badge = nil
      let feed = Task { @MainActor in
        var t = 0.0
        while !Task.isCancelled {
          let level = -30 + 12 * sin(t * 2.1) + 6 * sin(t * 5.3)
          panel.updateInputLevel(dBFS: level)
          t += 1.0 / 30
          try? await Task.sleep(for: .milliseconds(33))
        }
      }
      defer { feed.cancel() }
      var session = SessionID(UUID())
      panel.render(DictationSessionSnapshot(sessionID: session, revision: 1, phase: .recording))
      await shots.shoot("x-dictation-press", window: panel.panel, settle: 0.12)
      let words = "下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果"
      for (index, end) in [10, 22, words.count].enumerated() {
        panel.render(
          DictationSessionSnapshot(sessionID: session, revision: UInt64(2 + index), phase: .recording),
          liveText: String(words.prefix(end)))
        try? await Task.sleep(for: .milliseconds(500))
      }
      await shots.shoot("dictation-plain", window: panel.panel, settle: 0.4)
      panel.render(
        DictationSessionSnapshot(sessionID: session, revision: 6, phase: .recognizing), liveText: words)
      await shots.shoot("x-dictation-gather", window: panel.panel, settle: 0.25)
      let key = try? DictationIdempotencyKey("live-shots")
      if let key {
        panel.render(
          DictationSessionSnapshot(
            sessionID: session, revision: 7, phase: .completed,
            insertion: DictationInsertionResult(idempotencyKey: key, method: .clipboardPaste, inserted: true)),
          liveText: words)
        await shots.shoot("dictation-saved", window: panel.panel, settle: 0.3)
      }
      try? await Task.sleep(for: .seconds(2))

      // A short tap: the take keeps listening hands-free (nothing said yet).
      session = SessionID(UUID())
      panel.render(DictationSessionSnapshot(sessionID: session, revision: 1, phase: .recording))
      await shots.shoot("fn-tap", window: panel.panel, settle: 1.2)
      // Fn+⇧: 翻译 into English; ⇧ again: Japanese, not installed.
      panel.badge = .translation(into: "英语", ready: true)
      panel.render(
        DictationSessionSnapshot(sessionID: session, revision: 2, phase: .recording),
        liveText: String(words.prefix(22)))
      await shots.shoot("x-dictation-translate", window: panel.panel, settle: 0.4)
      panel.badge = .translation(into: "日语", ready: false)
      panel.render(
        DictationSessionSnapshot(sessionID: session, revision: 3, phase: .recording),
        liveText: String(words.prefix(22)))
      await shots.shoot("x-dictation-translate-missing", window: panel.panel, settle: 0.3)
      panel.badge = .command
      panel.render(
        DictationSessionSnapshot(sessionID: session, revision: 4, phase: .recording),
        liveText: "把这段改短一点")
      await shots.shoot("x-dictation-command", window: panel.panel, settle: 0.3)
      panel.badge = nil
      panel.dismiss()

      // How a take ends when it was not typed in.
      func take(_ end: DictationSessionSnapshot, facts: FnHUDTakeFacts, text: String) {
        panel.dismiss()
        panel.render(
          DictationSessionSnapshot(sessionID: end.sessionID, revision: 1, phase: .recording),
          liveText: text)
        panel.render(
          DictationSessionSnapshot(sessionID: end.sessionID, revision: 2, phase: .recognizing),
          liveText: text)
        panel.render(end, liveText: text, facts: facts)
      }
      if let key {
        session = SessionID(UUID())
        take(
          DictationSessionSnapshot(
            sessionID: session, revision: 3, phase: .completed,
            insertion: DictationInsertionResult(
              idempotencyKey: key, method: .retainedForCopy, inserted: false,
              failureReason: .unconfirmed)),
          facts: FnHUDTakeFacts(copied: true), text: words)
        await shots.shoot("x-dictation-copied", window: panel.panel, settle: 0.5)
      }
      if let silent = try? DictationFailure(
        stage: .recognition, category: .corruptInput, code: "asr-no-speech-detected",
        retryable: true, recoveryPhase: .recognizing)
      {
        session = SessionID(UUID())
        take(
          DictationSessionSnapshot(
            sessionID: session, revision: 3, phase: .failedRecoverable, failure: silent),
          facts: FnHUDTakeFacts(), text: "")
        await shots.shoot("x-dictation-nothing-heard", window: panel.panel, settle: 0.5)
      }
      if let failed = try? DictationFailure(
        stage: .recognition, category: .transientRuntime, code: "asr-engine-failed",
        retryable: true, recoveryPhase: .recognizing)
      {
        session = SessionID(UUID())
        take(
          DictationSessionSnapshot(
            sessionID: session, revision: 3, phase: .failedRecoverable, failure: failed),
          facts: FnHUDTakeFacts(), text: "")
        await shots.shoot("x-dictation-failed", window: panel.panel, settle: 0.5)
      }
      // Review v12-B #7: demo mode says when a take is not kept.
      if let key {
        session = SessionID(UUID())
        take(
          DictationSessionSnapshot(
            sessionID: session, revision: 3, phase: .completed,
            insertion: DictationInsertionResult(
              idempotencyKey: key, method: .clipboardPaste, inserted: true)),
          facts: FnHUDTakeFacts(leavesLibrary: true), text: words)
        await shots.shoot("x-dictation-demo-typed", window: panel.panel, settle: 0.5)
        session = SessionID(UUID())
        take(
          DictationSessionSnapshot(
            sessionID: session, revision: 3, phase: .completed,
            insertion: DictationInsertionResult(
              idempotencyKey: key, method: .retainedForCopy, inserted: false,
              failureReason: .unconfirmed)),
          facts: FnHUDTakeFacts(copied: true, leavesLibrary: true), text: words)
        await shots.shoot("x-dictation-demo-copied", window: panel.panel, settle: 0.5)
      }
      panel.dismiss()
      panel.showsCaptions = model.dictationCaptionsEnabled
    }

    /// v12 1C (ALIGNMENT 收2-2 – 收2-6), with no microphone and no
    /// recording: the meeting's caption strip in every stage (its real
    /// panel and controller, synthetic text), ✕ clicked as the pointer
    /// would; the 文件 menu; 收进会议记录… on synthetic transcripts
    /// (`-MindloomLiveTranscripts <folder>`, the panel's own path), and 导入…
    /// on a synthetic recording (`-MindloomLiveMedia <file>`), which this
    /// clone (no models) refuses and says why.
    private func liveMeeting(_ shots: LiveShots, _ main: NSWindow) async {
      guard ["x-meeting", "x-transcript", "x-import"].contains(where: shots.wants) else { return }
      let meeting = MeetingState.shared
      let captions = meeting.captions
      let wasEnabled = meeting.captionsEnabled
      meeting.captionsEnabled = true
      let live = """
        说话人 A  下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果
        我  好，那 cover 第一段我再删两句
        正在识别  柚子那边的报价
        """
      captions.update(.listening, text: "")
      await shots.shoot("x-meeting-captions-empty", window: captions.panel, settle: 0.5)
      captions.update(.listening, text: live)
      shots.log(
        "captions frame \(NSStringFromRect(captions.panel.frame)) screen "
          + NSStringFromRect(captions.panel.screen?.visibleFrame ?? .zero)
          + " key=\(captions.panel.canBecomeKey) mouse=\(!captions.panel.ignoresMouseEvents)")
      await shots.shoot("x-meeting-captions", window: captions.panel, settle: 0.5)
      captions.update(
        .listening,
        text: "下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果，然后 cover 第一段再删两句，柚子那边的报价也要在周四之前确认")
      await shots.shoot("x-meeting-captions-running", window: captions.panel, settle: 0.5)
      captions.update(.paused, text: live)
      await shots.shoot("x-meeting-captions-paused", window: captions.panel, settle: 0.5)
      captions.update(.saving, text: live)
      await shots.shoot("x-meeting-captions-saving", window: captions.panel, settle: 0.5)
      captions.update(
        .saved, text: "下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果。好，那 cover 第一段我再删两句。柚子那边的报价周四之前确认。")
      await shots.shoot("x-meeting-captions-saved", window: captions.panel, settle: 0.5)
      captions.update(.waitingForModels)
      await shots.shoot("x-meeting-captions-models", window: captions.panel, settle: 0.5)
      captions.update(.failed)
      await shots.shoot("x-meeting-captions-failed", window: captions.panel, settle: 0.5)
      // ✕, clicked where the pointer would (the panel never becomes key).
      captions.update(.listening, text: live)
      try? await Task.sleep(for: .milliseconds(400))
      let size = MeetingCaptionPanelController.panelSize
      LiveShots.click(captions.panel, at: NSPoint(x: size.width - 12 - 11, y: size.height / 2))
      try? await Task.sleep(for: .milliseconds(600))
      shots.log(
        "captions after ✕: shown=\(captions.isShown) enabled=\(meeting.captionsEnabled)")
      meeting.captionsEnabled = wasEnabled
      captions.hide()

      // 文件 menu, as AppKit has it.
      if let file = NSApp.mainMenu?.items.first(where: {
        ["文件", "File"].contains($0.submenu?.title)
      })?
      .submenu {
        shots.log(
          "文件 menu: " + LiveShots.describe(file) + " keys: "
            + file.items.map {
              "\($0.title)=\($0.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\($0.keyEquivalent)"
            }
            .joined(separator: " | "))
        if shots.wants("x-file-menu"), let copy = file.copy() as? NSMenu, let view = main.contentView {
          // The same items, opened over the window for a still image (a
          // copy: the menu bar's own menu stays where it is) and put away
          // without choosing anything. Opened from a run-loop timer, not
          // from this task, so the run keeps going while the menu tracks; a
          // second timer closes it after 8 s whatever happens.
          nonisolated(unsafe) let menu = copy
          let point = NSPoint(x: 220, y: view.isFlipped ? 60 : view.bounds.height - 60)
          nonisolated(unsafe) let host = view
          let opener = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
              _ = menu.popUp(positioning: nil, at: point, in: host)
            }
          }
          let closer = Timer(timeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated { menu.cancelTracking() }
          }
          RunLoop.main.add(opener, forMode: .default)
          RunLoop.main.add(closer, forMode: .common)
          try? await Task.sleep(for: .milliseconds(700))
          await shots.shoot("x-file-menu", window: main, settle: 0.2)
          menu.cancelTracking()
          closer.invalidate()
          try? await Task.sleep(for: .milliseconds(300))
        }
      } else {
        shots.log(
          "文件 menu: not found in "
            + (NSApp.mainMenu?.items.map(\.title).joined(separator: ",") ?? "-"))
      }

      let started = Date()
      if shots.wants("x-transcript"), let folder = PreviewLaunch.value("-MindloomLiveTranscripts") {
        let files =
          ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: nil))
          ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        model.takeInMeetingTranscripts(files)
        _ = await until(20) {
          model.memorySourceItems.filter { $0.createdAt >= started && $0.inputMode == .userItem }
            .count
            >= files.count
        }
        try? await Task.sleep(for: .seconds(1))
        let fresh = model.memorySourceItems.filter {
          $0.createdAt >= started && $0.inputMode == .userItem
        }
        let records =
          (try? await model.repository?.memoryItemRecords(ids: fresh.map(\.sessionID))) ?? []
        for record in records {
          let words = MemoryItemSource.words(record)
          let waiting = MemoryWaitingCapture(record: record)
          let turns = MemoryTranscriptText.parse(record.text ?? "")
          shots.log(
            "transcript item kind=\(record.itemKind?.rawValue ?? "-") source=\(words.line) symbol=\(words.symbol)"
              + " waiting=\(waiting.kind) format=\(turns?.format.rawValue ?? "none") turns=\(turns?.turns.count ?? 0)"
          )
        }
        for item in fresh {
          shots.log("transcript row kind=" + ContentView.waitingCapture(item).kind)
        }
        shots.log("transcript note: \(model.intake.confirmation ?? "-")")
        memoryNavigation = MemoryNavigation()
        await shots.shoot("x-transcript-home", window: main, settle: 1.5)
        memoryNavigation = MemoryNavigation(root: .search, search: "柚子")
        await shots.shoot("x-transcript-search", window: main, settle: 1.5)
        memoryNavigation = MemoryNavigation()
      }
      if shots.wants("x-import"), let media = PreviewLaunch.value("-MindloomLiveMedia") {
        model.receive([.file(URL(fileURLWithPath: media))], source: nil, origin: .unknown)
        _ = await until(10) { model.intake.confirmation != nil }
        shots.log(
          "import: said=\(model.intake.confirmation ?? "-") importing=\(model.capture.importInProgress)"
            + " kind=" + MemoryMediaKind.of(filename: media, mediaType: nil).word)
        await shots.shoot("x-import-result", window: main, settle: 0.4)
      }
    }
  }

  /// v12 integration live walk: a recording made on the clone through the
  /// App's own capture coordinator and audio journal, from a capture port
  /// of synthetic samples (a 12 s tone at about -54 dBFS: no microphone),
  /// with three synthetic sentences committed as a recognition, polish and
  /// delivery would commit them (no model runs; delivery is 「kept for
  /// copy」, nothing is typed anywhere). Never sent to the organizer.
  @MainActor
  enum LiveSyntheticRecording {
    static let sentences = ["合成录音：开放日的海报今天定稿。", "周五前把印刷文件发给虚构甲。", "下周一再看一次样张。"]

    static func make(model: DictationAppModel, shots: LiveShots) async -> SessionID? {
      guard let repository = model.repository, let journal = model.journal else {
        shots.log("synthetic recording: the library is not open")
        return nil
      }
      let session = SessionID(UUID())
      let actor = DictationSessionActor()
      let coordinator = DictationCaptureCoordinator(
        sessionActor: actor, capture: LiveSyntheticCapture(seconds: 12), journal: journal,
        repository: repository, grantsRemoteEligibility: false)
      do {
        _ = try await coordinator.start(sessionID: session, target: nil)
        let finalization = try await coordinator.end()
        let ranges = finalization.audio
        guard let first = ranges.map(\.monotonicStartNanoseconds).min(),
          let last = ranges.map(\.monotonicEndNanoseconds).max(), last > first
        else {
          shots.log("synthetic recording: no audio ranges")
          return nil
        }
        let span = (last - first) / UInt64(sentences.count)
        let segments = sentences.enumerated().map { index, text in
          DictationTranscriptSegment(
            id: UUID(), monotonicStartNanoseconds: first + UInt64(index) * span,
            monotonicEndNanoseconds: index == sentences.count - 1
              ? last : first + UInt64(index + 1) * span,
            text: text, confidence: 1)
        }
        let transcript = DictationTranscriptResult(
          revisionID: TranscriptRevisionID(), segmentIDs: segments.map(\.id),
          text: sentences.joined(), modelArtifactID: "mindloom-liveshots-synthetic-v1",
          provenance: DictationTranscriptProvenance(
            parentRevisionID: nil, kind: .final, languageHints: ["zh"], audioRanges: ranges,
            segments: segments))
        let input = finalization.snapshot.revision
        let hash = try SHA256Digest(String(repeating: "0", count: 64))
        let polishing = try await actor.handle(.recognitionSucceeded(transcript))
        try await repository.commitRecognition(
          DictationRecognitionCommit(
            snapshot: polishing, transcript: transcript, inputRevision: input, configHash: hash,
            createdAt: Date()))
        let polish = DictationPolishResult(
          sourceRevisionID: transcript.revisionID, text: transcript.text,
          disposition: .rawTranscriptFallback, modelArtifactID: nil)
        let inserting = try await actor.handle(.polishFellBack(polish))
        try await repository.commitPolish(
          DictationPolishCommit(
            derivationID: UUID(), snapshot: inserting, polish: polish, sourceRevision: input,
            configHash: hash, createdAt: Date()))
        let key = try DictationIdempotencyKey("liveshots-" + session.rawValue.uuidString.lowercased())
        _ = try await repository.reserveInsertion(sessionID: session, key: key)
        let result = DictationInsertionResult(
          idempotencyKey: key, method: .retainedForCopy, inserted: false)
        let completed = try await actor.handle(.insertionCompleted(result))
        try await repository.commitInsertion(
          DictationInsertionCommit(snapshot: completed, result: result))
        shots.log(
          "synthetic recording \(session.rawValue.uuidString.lowercased()): ranges=\(ranges.count)"
            + " seconds=\(Double(last - first) / 1e9)")
        return session
      } catch {
        shots.log("synthetic recording failed: \(error)")
        return nil
      }
    }
  }

  /// Synthetic samples in half-second chunks, all at start (no microphone).
  private actor LiveSyntheticCapture: MicrophoneCapturePort {
    let seconds: Int
    private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
    private var stream: AsyncStream<CapturedPCMChunk>?
    static let rate: UInt32 = 16_000

    init(seconds: Int) { self.seconds = seconds }

    func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
      let pair = AsyncStream.makeStream(of: CapturedPCMChunk.self, bufferingPolicy: .unbounded)
      stream = pair.stream
      continuation = pair.continuation
      return MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "mindloom-liveshots-synthetic",
        sampleRateHertz: Self.rate, channelCount: 1, encoding: .float32LittleEndian,
        interleaved: true)
    }

    func start() async throws {
      let frames = Int(Self.rate) / 2
      let base: UInt64 = 1_000_000_000
      for chunk in 0..<(seconds * 2) {
        var samples = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
          let time = Double(chunk * frames + index) / Double(Self.rate)
          samples[index] = Float(0.002 * sin(2 * .pi * 330 * time))
        }
        continuation?.yield(
          CapturedPCMChunk(
            sequence: UInt64(chunk), monotonicStartNanoseconds: base + UInt64(chunk) * 500_000_000,
            frameCount: UInt64(frames), sampleRateHertz: Self.rate, channelCount: 1,
            encoding: .float32LittleEndian, interleaved: true,
            bytes: samples.withUnsafeBytes { Data($0) }))
      }
    }

    func chunks() async -> AsyncStream<CapturedPCMChunk> { stream ?? AsyncStream { $0.finish() } }
    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws { continuation?.finish() }
    func cancel() async { continuation?.finish() }
    func terminalFailure() async -> DictationFailure? { nil }
  }
#endif
