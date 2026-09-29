import AppKit
import Foundation

@MainActor
private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
  private let readyFileURL: URL
  private var window: NSWindow?
  private var directTarget: NSTextView?

  init(readyFileURL: URL) {
    self.readyFileURL = readyFileURL
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "bestASR AX insertion fixture"
    window.center()
    let content = NSView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = content

    let direct = makeTextView(
      identifier: "bestasr.ax.direct",
      value: "alpha target omega",
      editable: true,
      frame: NSRect(x: 20, y: 490, width: 680, height: 90)
    )
    let fallback = makeTextView(
      identifier: "bestasr.ax.fallback",
      value: "alpha target omega",
      editable: true,
      frame: NSRect(x: 20, y: 380, width: 680, height: 90)
    )
    let readOnly = makeTextView(
      identifier: "bestasr.ax.readonly",
      value: "read only fixture",
      editable: false,
      frame: NSRect(x: 20, y: 270, width: 680, height: 90)
    )
    let alternate = makeTextView(
      identifier: "bestasr.ax.alternate",
      value: "alternate fixture",
      editable: true,
      frame: NSRect(x: 20, y: 160, width: 680, height: 90)
    )
    let secure = NSSecureTextField(
      frame: NSRect(x: 20, y: 95, width: 680, height: 32)
    )
    secure.stringValue = "synthetic-secret"
    secure.setAccessibilityIdentifier("bestasr.ax.secure")

    for view in [
      direct.scrollView, fallback.scrollView, readOnly.scrollView,
      alternate.scrollView,
    ] {
      content.addSubview(view)
    }
    content.addSubview(secure)

    self.window = window
    directTarget = direct.textView
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, let window = self.window,
        let directTarget = self.directTarget
      else { return }
      window.makeFirstResponder(directTarget)
      directTarget.setSelectedRange(NSRange(location: 6, length: 6))
      do {
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
          .write(to: self.readyFileURL, options: .atomic)
      } catch {
        NSApplication.shared.terminate(nil)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }

  private func makeTextView(
    identifier: String,
    value: String,
    editable: Bool,
    frame: NSRect
  ) -> (scrollView: NSScrollView, textView: NSTextView) {
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView(frame: scrollView.contentView.bounds)
    textView.autoresizingMask = [.width, .height]
    textView.isEditable = editable
    textView.isSelectable = true
    textView.string = value
    textView.setAccessibilityIdentifier(identifier)
    scrollView.documentView = textView
    return (scrollView, textView)
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    mainMenu.addItem(applicationItem)
    let applicationMenu = NSMenu()
    applicationItem.submenu = applicationMenu
    applicationMenu.addItem(
      withTitle: "Quit",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    let paste = editMenu.addItem(
      withTitle: "Paste",
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    paste.keyEquivalentModifierMask = [.command]
    NSApplication.shared.mainMenu = mainMenu
  }
}

private func argumentValue(_ flag: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: flag),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return CommandLine.arguments[index + 1]
}

guard let readyPath = argumentValue("--ready-file") else {
  fputs("error: --ready-file is required\n", stderr)
  exit(64)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
private let fixtureDelegate = FixtureApplicationDelegate(
  readyFileURL: URL(fileURLWithPath: readyPath)
)
application.delegate = fixtureDelegate
application.run()
