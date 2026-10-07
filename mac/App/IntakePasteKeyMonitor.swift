import AppKit
import BestASRIntake
import SwiftUI
import UniformTypeIdentifiers

/// Watches ⌘V in the main window. When no text is being edited (the first
/// responder is not a text view), the key takes the clipboard in as an item
/// instead of doing nothing; while a field is being edited, ⌘V pastes into
/// it as usual. Only this window's key events are looked at.
struct IntakePasteKeyMonitor: NSViewRepresentable {
  static let dropTypes: [UTType] = IntakePasteboardReader.acceptedTypeIdentifiers.compactMap {
    UTType($0)
  }

  let onPaste: @MainActor () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.onPaste = onPaste
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.onPaste = onPaste
  }

  static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
    view.stop()
  }

  final class MonitorView: NSView {
    var onPaste: (@MainActor () -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let consumed = MainActor.assumeIsolated { () -> Bool in
          guard let self, let window = self.window, event.window === window,
            !(window.firstResponder is NSText),
            IntakePasteShortcut.isPlainPaste(
              modifierFlags: event.modifierFlags,
              charactersIgnoringModifiers: event.charactersIgnoringModifiers, isARepeat: false)
          else { return false }
          // Holding ⌘V auto-repeats; only the first press takes anything in.
          // The rule is `IntakePasteShortcut.takesClipboard` (tested).
          if IntakePasteShortcut.takesClipboard(
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            isARepeat: event.isARepeat, firstResponderIsText: false)
          {
            self.onPaste?()
          }
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

/// Words selected in the main window (原文, a matter page) and copied with
/// ⌘C or 编辑 › 拷贝 are copied by the system, which knows nothing of
/// Mindloom's origin mark; ⌘V in the window would then take Mindloom's own
/// words back in as a new item labelled with the last other App. After such
/// a copy the mark is added to what was copied (review finish-ship). Copies
/// out of a field being edited (the search field) are left as they are.
@MainActor
enum MindloomCopyMarker {
  private static var observers: [NSObjectProtocol] = []
  private static var monitor: Any?
  private static var pending: Int?

  static func install() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) {
        note in
        nonisolated(unsafe) let item = note.userInfo?["MenuItem"]
        MainActor.assumeIsolated {
          guard (item as? NSMenuItem)?.action == #selector(NSText.copy(_:)) else { return }
          pending = copiesReadOnlyWords() ? NSPasteboard.general.changeCount : nil
        }
      })
    observers.append(
      center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) {
        note in
        nonisolated(unsafe) let item = note.userInfo?["MenuItem"]
        MainActor.assumeIsolated {
          guard (item as? NSMenuItem)?.action == #selector(NSText.copy(_:)) else { return }
          finish()
        }
      })
    // ⌘C that some view takes before the menu: the same check a turn later.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated {
        guard
          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          event.charactersIgnoringModifiers?.lowercased() == "c", copiesReadOnlyWords()
        else { return }
        let before = NSPasteboard.general.changeCount
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            pending = before
            finish()
          }
        }
      }
      return event
    }
  }

  /// The main window is key and its keyboard focus is not a field being
  /// edited (selected words are read-only text).
  static func copiesReadOnlyWords() -> Bool {
    guard let window = NSApp.keyWindow, window === MainWindow.existing,
      window.attachedSheet == nil
    else { return false }
    return isReadOnly(window.firstResponder)
  }

  static func isReadOnly(_ responder: NSResponder?) -> Bool {
    if let text = responder as? NSTextView { return !text.isEditable }
    if responder is NSText { return false }
    return true
  }

  private static func finish() {
    guard let before = pending else { return }
    pending = nil
    let board = NSPasteboard.general
    guard board.changeCount != before else { return }
    IntakePasteboardMarks.markOwn(board)
  }
}
