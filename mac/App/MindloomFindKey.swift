import AppKit
import BestASRMemoryUI
import SwiftUI

/// ⌘F in the main window: Mindloom's search field takes focus, whatever has
/// the keyboard (a text field included). A local monitor sees the key before
/// the menu bar, so the system's 编辑 › 查找 › 查找… (kept for its 拼写和语法
/// and 替换 neighbours) never takes ⌘F from the search field. Only this
/// window's key events are looked at.
struct MindloomFindKeyMonitor: NSViewRepresentable {
  func makeNSView(context: Context) -> MonitorView { MonitorView() }
  func updateNSView(_ view: MonitorView, context: Context) {}
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let consumed = MainActor.assumeIsolated { () -> Bool in
          guard let self, let window = self.window, event.window === window,
            MindloomFindShortcut.mayFocusSearch(in: window),
            MindloomFindShortcut.isFind(
              modifierFlags: event.modifierFlags,
              charactersIgnoringModifiers: event.charactersIgnoringModifiers)
          else { return false }
          MindloomFind.focusSearch()
          return true
        }
        return consumed ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

@MainActor
enum MindloomFind {
  /// Brings the main window forward and focuses its search field; nothing
  /// while a sheet is open on it (the field is behind the sheet, review
  /// finish-ship), whether ⌘F or 编辑 › 查找 › 查找… asked.
  static func focusSearch() {
    guard MindloomFindShortcut.mayFocusSearch(in: MainWindow.existing) else { return }
    if let window = MainWindow.existing, !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
    }
    NotificationCenter.default.post(name: .mindloomFocusSearch, object: nil)
  }
}
