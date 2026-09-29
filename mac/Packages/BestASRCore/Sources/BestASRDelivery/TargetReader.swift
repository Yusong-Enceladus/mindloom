import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// One read of the world: which application is in front, whether a password
/// field has the keyboard, what text is highlighted, and what sits around
/// the caret. Nothing here decides anything and nothing here is remembered
/// between dictations.
///
/// Every accessibility call carries a short timeout. The default is six
/// seconds, and an application that is busy — or waiting on us — must not
/// be allowed to hold this app's main thread for that long.
@MainActor
public final class TargetReader {
  public init() {}

  /// The application in front. Nil when there is none — the desktop, a
  /// screen saver — or when it is this process and `ownApplicationAllowed`
  /// is false.
  public func frontmostApplication(ownApplicationAllowed: Bool) -> DeliveryTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    if application.processIdentifier == ProcessInfo.processInfo.processIdentifier,
      !ownApplicationAllowed
    {
      return nil
    }
    return DeliveryTarget(
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier)
  }

  /// True while a password field, or anything else that enables secure
  /// keyboard entry, has the keyboard.
  public func secureInputActive() -> Bool {
    IsSecureEventInputEnabled()
  }

  /// The text highlighted in the front application: what accessibility
  /// reports as selected, or — where the application reports nothing, as
  /// WeChat does — what ⌘C yields, with the user's clipboard put back.
  public func selectedText() -> String? {
    guard !IsSecureEventInputEnabled(),
      let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }
    let processID = frontmost.processIdentifier
    if let element = focusedElement(of: processID) {
      let role = stringAttribute(element, kAXRoleAttribute) ?? ""
      let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
      guard
        ![role, subrole].contains(where: {
          $0.range(of: "secure", options: .caseInsensitive) != nil
        })
      else { return nil }
      if let selected = stringAttribute(element, kAXSelectedTextAttribute) {
        return Self.usable(selected)
      }
    }
    return Self.usable(selectedTextByCopying(from: processID))
  }

  /// What the application says has the keyboard, and the text it shows
  /// there. Nil when the application names no focused element at all
  /// (WeChat); a `FocusedText` with neither value nor selection when it
  /// names one that shows no text (a page body, a button, a group).
  public func focusedText(in processID: Int32) -> FocusedText? {
    guard let element = focusedElement(of: processID) else { return nil }
    let selection = selectedRange(of: element)
    return FocusedText(
      value: stringAttribute(element, kAXValueAttribute),
      selectionLocation: selection?.location,
      selectionLength: selection?.length)
  }

  /// Whether the focused text has changed since `before`, polled for up to
  /// `window` because an application updates its accessibility tree a frame
  /// or two after it updates its field. Text that was never exposed cannot
  /// be seen to change, and is reported unchanged.
  public func textChanged(
    since before: FocusedText, in processID: Int32, within window: TimeInterval
  ) async -> Bool {
    guard before.exposesText else { return false }
    let deadline = Date().addingTimeInterval(window)
    repeat {
      if let now = focusedText(in: processID), now.exposesText, now != before { return true }
      try? await Task.sleep(for: .milliseconds(30))
    } while Date() < deadline
    return false
  }

  static let maximumSelectedTextUTF8Bytes = 16_384
  static let accessibilityTimeoutSeconds: Float = 0.25
  static let accessibilityWakeSeconds: TimeInterval = 0.15
  static let copySelectionWindowSeconds: TimeInterval = 0.15
  static let copyVirtualKey: CGKeyCode = 8

  private static func usable(_ text: String?) -> String? {
    guard let text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= maximumSelectedTextUTF8Bytes
    else { return nil }
    return text
  }

  private func selectedTextByCopying(from processID: Int32) -> String? {
    guard CGPreflightPostEventAccess(),
      let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: Self.copyVirtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: Self.copyVirtualKey, keyDown: false)
    else { return nil }
    down.flags = .maskCommand
    up.flags = .maskCommand
    let pasteboard = NSPasteboard.general
    let prior = PasteboardSnapshot(pasteboard: pasteboard)
    let before = pasteboard.changeCount
    down.postToPid(processID)
    up.postToPid(processID)
    var copied: String?
    let deadline = Date().addingTimeInterval(Self.copySelectionWindowSeconds)
    repeat {
      Thread.sleep(forTimeInterval: 0.015)
      if pasteboard.changeCount != before {
        copied = pasteboard.string(forType: .string)
        break
      }
    } while Date() < deadline
    prior.restore(to: pasteboard)
    return copied
  }

  // MARK: Accessibility

  private var wokenProcesses: Set<pid_t> = []

  private func focusedElement(of processID: Int32) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(application, Self.accessibilityTimeoutSeconds)
    if let focused = focusedElement(in: application) { return focused }
    // Chromium and Electron build their accessibility tree only once someone
    // asks for it; this attribute is how an assistive client asks.
    guard !wokenProcesses.contains(processID) else { return nil }
    wokenProcesses.insert(processID)
    AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(Self.accessibilityWakeSeconds)
    repeat {
      Thread.sleep(forTimeInterval: 0.02)
      if let focused = focusedElement(in: application) { return focused }
    } while Date() < deadline
    return nil
  }

  private func focusedElement(in application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let value
    else { return nil }
    let element = value as! AXUIElement
    AXUIElementSetMessagingTimeout(element, Self.accessibilityTimeoutSeconds)
    return element
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  private func selectedRange(of element: AXUIElement) -> (location: Int, length: Int)? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return (range.location, range.length)
  }
}
