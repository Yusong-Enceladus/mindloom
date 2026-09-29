import AppKit
import SwiftUI

enum HistoryPlaybackKeyCommand: Equatable {
  case togglePlayback
  case seekBackward
  case seekForward
}

enum HistoryPlaybackKeyboardPolicy {
  static func command(
    keyCode: UInt16,
    modifierRawValue: UInt,
    isRepeat: Bool
  ) -> HistoryPlaybackKeyCommand? {
    guard !isRepeat else { return nil }
    let modifiers = NSEvent.ModifierFlags(rawValue: modifierRawValue)
      .intersection([.command, .control, .option, .shift])
    if keyCode == 49, modifiers.isEmpty {
      return .togglePlayback
    }
    guard modifiers == .command else { return nil }
    switch keyCode {
    case 123: return .seekBackward
    case 124: return .seekForward
    default: return nil
    }
  }
}

/// Handles playback before focused rows consume Space, while the owning view
/// disables the monitor whenever any Library text editor has focus.
struct HistoryPlaybackKeyboardHandler: NSViewRepresentable {
  let isEnabled: Bool
  let perform: @MainActor (HistoryPlaybackKeyCommand) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.hostView = view
    context.coordinator.installMonitor()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.hostView = nsView
    context.coordinator.isEnabled = isEnabled
    context.coordinator.perform = perform
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  @MainActor
  final class Coordinator {
    weak var hostView: NSView?
    var isEnabled = false
    var perform: (@MainActor (HistoryPlaybackKeyCommand) -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        let keyCode = event.keyCode
        let modifierRawValue = event.modifierFlags.rawValue
        let isRepeat = event.isARepeat
        let eventWindowNumber = event.window?.windowNumber
        let consumed = MainActor.assumeIsolated {
          self?.handle(
            keyCode: keyCode,
            modifierRawValue: modifierRawValue,
            isRepeat: isRepeat,
            eventWindowNumber: eventWindowNumber
          ) ?? false
        }
        return consumed ? nil : event
      }
    }

    func removeMonitor() {
      guard let monitor else { return }
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    private func handle(
      keyCode: UInt16,
      modifierRawValue: UInt,
      isRepeat: Bool,
      eventWindowNumber: Int?
    ) -> Bool {
      guard isEnabled, let window = hostView?.window,
        window.isKeyWindow, eventWindowNumber == window.windowNumber,
        let command = HistoryPlaybackKeyboardPolicy.command(
          keyCode: keyCode,
          modifierRawValue: modifierRawValue,
          isRepeat: isRepeat
        )
      else { return false }
      perform?(command)
      return true
    }
  }
}

/// What the keyboard can do on the library list.
///
/// A list of five thousand records is searched, not browsed, and a search you
/// cannot drive from the keyboard is a search you have to reach for the mouse
/// in the middle of. ⌘F is where every macOS app puts "find"; the arrow keys
/// walk what was found; Esc puts it back.
enum HistoryListKeyCommand: Equatable {
  case focusSearch
  case moveUp
  case moveDown
  case clearSearch
}

enum HistoryListKeyboardPolicy {
  static func command(
    keyCode: UInt16,
    modifierRawValue: UInt,
    hasQuery: Bool
  ) -> HistoryListKeyCommand? {
    let modifiers = NSEvent.ModifierFlags(rawValue: modifierRawValue)
      .intersection([.command, .control, .option, .shift])
    if modifiers == .command, keyCode == 3 { return .focusSearch }
    guard modifiers.isEmpty else { return nil }
    switch keyCode {
    case 126: return .moveUp
    case 125: return .moveDown
    // Esc only means "undo the search" while there is one; otherwise it
    // belongs to whatever else is on screen.
    case 53: return hasQuery ? .clearSearch : nil
    default: return nil
    }
  }
}

struct HistoryListKeyboardHandler: NSViewRepresentable {
  let isEnabled: Bool
  let hasQuery: Bool
  let perform: @MainActor (HistoryListKeyCommand) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.hostView = view
    context.coordinator.installMonitor()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.hostView = nsView
    context.coordinator.isEnabled = isEnabled
    context.coordinator.hasQuery = hasQuery
    context.coordinator.perform = perform
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  @MainActor
  final class Coordinator {
    weak var hostView: NSView?
    var isEnabled = false
    var hasQuery = false
    var perform: (@MainActor (HistoryListKeyCommand) -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        let keyCode = event.keyCode
        let modifierRawValue = event.modifierFlags.rawValue
        let eventWindowNumber = event.window?.windowNumber
        let consumed = MainActor.assumeIsolated {
          self?.handle(
            keyCode: keyCode,
            modifierRawValue: modifierRawValue,
            eventWindowNumber: eventWindowNumber
          ) ?? false
        }
        return consumed ? nil : event
      }
    }

    func removeMonitor() {
      guard let monitor else { return }
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    private func handle(
      keyCode: UInt16,
      modifierRawValue: UInt,
      eventWindowNumber: Int?
    ) -> Bool {
      guard isEnabled, let window = hostView?.window,
        window.isKeyWindow, eventWindowNumber == window.windowNumber,
        let command = HistoryListKeyboardPolicy.command(
          keyCode: keyCode,
          modifierRawValue: modifierRawValue,
          hasQuery: hasQuery
        )
      else { return false }
      perform?(command)
      return true
    }
  }
}
