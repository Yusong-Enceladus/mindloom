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
