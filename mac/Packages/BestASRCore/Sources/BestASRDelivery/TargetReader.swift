import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MindloomIdentity

/// One read of the world: which application is in front, whether a password
/// field has the keyboard, what text is highlighted, and what sits around
/// the caret. Nothing here decides anything. The only thing remembered
/// between dictations is which applications have named a focused element
/// (`AccessibilityWakeBook`), to bound how long a read waits for one.
///
/// Every accessibility call carries a short timeout. The default is six
/// seconds, and an application that is busy — or waiting on us — must not
/// be allowed to hold this app's main thread for that long.
@MainActor
public final class TargetReader {
  private let accessibility: any TargetAccessibility

  public convenience init() {
    self.init(accessibility: LiveTargetAccessibility())
  }

  /// `accessibility` stands in for the applications' accessibility in tests.
  init(accessibility: any TargetAccessibility) {
    self.accessibility = accessibility
  }

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
  ///
  /// Does not wait for a tree being built: see
  /// `focusedTextWaitingForTree(in:)` for the read a delivery makes.
  public func focusedText(in processID: Int32) -> FocusedText? {
    guard let element = focusedElement(of: processID) else { return nil }
    return read(element).text
  }

  /// The read made when the words are ready. Where the application names
  /// no focused element it is asked to build its accessibility tree, every
  /// time it is found without one, and given up to
  /// `AccessibilityWakeBook.wakeWindowSeconds` to name the element — unless
  /// it showed nothing after such a wait within the last ten minutes. The
  /// wait is a suspended task; the main thread stays free.
  public func focusedTextWaitingForTree(in processID: Int32) async -> FocusedText? {
    if let element = accessibility.focusedElement(ofProcess: processID) {
      wakeBook.noteExposed(processID)
      return read(element).text
    }
    accessibility.requestTree(ofProcess: processID)
    let wait = wakeBook.waitSeconds(for: processID, now: Date())
    let deadline = Date().addingTimeInterval(wait)
    repeat {
      if let element = accessibility.focusedElement(ofProcess: processID) {
        wakeBook.noteExposed(processID)
        return read(element).text
      }
      if Date() >= deadline { break }
      try? await Task.sleep(for: .milliseconds(25))
    } while true
    if wait > 0 { wakeBook.noteMissingAfterWait(processID, now: Date()) }
    return nil
  }

  /// Asks the application in front to build its accessibility tree now, off
  /// the main thread, so that the read made when the words are ready finds
  /// the field. Called when the dictation key goes down: by the time the
  /// words are ready the tree is there, and the read then does not wait for
  /// it again. Only a request; nothing is read or kept, and the main thread
  /// is never held.
  public func prepareAccessibility(of processID: Int32) {
    guard processID != ProcessInfo.processInfo.processIdentifier else { return }
    wakeBook.noteRequested(processID, now: Date())
    let accessibility = self.accessibility
    Self.wakeQueue.async {
      if accessibility.focusedElement(ofProcess: processID) == nil {
        accessibility.requestTree(ofProcess: processID)
      }
    }
  }

  /// Whether `words` were seen to arrive in the field `before` was read
  /// from, polled for up to `window` because an application updates its
  /// accessibility tree a frame or two after it updates its field.
  ///
  /// The field asked is the same element as before ⌘V, never whichever has
  /// the keyboard by then. When that element no longer exists (the
  /// application rebuilt its field) nothing can show that the words arrived
  /// in it, and they are reported as not seen: another element that happens
  /// to show the same words is not the field they were aimed at (review
  /// 10-5c S2). Text that was never exposed cannot show the words either.
  public func wordsLanded(
    _ words: String, since before: FocusedText, in processID: Int32,
    within window: TimeInterval
  ) async -> Bool {
    guard before.exposesText else { return false }
    let deadline = Date().addingTimeInterval(window)
    repeat {
      if let after = readAfterPaste(before, in: processID),
        LandingEvidence.landed(words, before: before, after: after)
      {
        return true
      }
      if Date() >= deadline { break }
      try? await Task.sleep(for: .milliseconds(30))
    } while true
    return false
  }

  /// The text the field `before` was read from shows now; nil when the
  /// field is gone, was never named, or shows no text. Used to see what the
  /// user changed in a dictation after it was typed in (ALIGNMENT 收1-8).
  public func currentValue(of before: FocusedText) -> String? {
    guard let handle = before.element else { return nil }
    let now = read(handle.element)
    return now.gone ? nil : now.text?.value
  }

  /// The field `before` was read from, read again; nil when it is gone or
  /// was never named.
  private func readAfterPaste(_ before: FocusedText, in processID: Int32) -> FocusedText? {
    guard let handle = before.element else { return nil }
    let same = read(handle.element)
    return same.gone ? nil : same.text
  }

  static let maximumSelectedTextUTF8Bytes = 16_384
  nonisolated static let accessibilityTimeoutSeconds: Float = 0.25
  static let copySelectionWindowSeconds: TimeInterval = 0.15
  static let copyVirtualKey: CGKeyCode = 8
  private nonisolated static let wakeQueue = DispatchQueue(
    label: MindloomIdentity.queueLabel("delivery.accessibility-wake"), qos: .userInitiated)

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
      let down = CGEvent(
        keyboardEventSource: source, virtualKey: Self.copyVirtualKey, keyDown: true),
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

  private var wakeBook = AccessibilityWakeBook()

  /// The focused element without waiting. Where there is none the
  /// application is asked to build its tree and asked once more at once:
  /// every time, not once per process, because Chromium drops a tree it
  /// built when input continues with no assistive use (DELIVERY.md 原因 2).
  private func focusedElement(of processID: Int32) -> AXUIElement? {
    if let focused = accessibility.focusedElement(ofProcess: processID) {
      wakeBook.noteExposed(processID)
      return focused
    }
    accessibility.requestTree(ofProcess: processID)
    guard let focused = accessibility.focusedElement(ofProcess: processID) else { return nil }
    wakeBook.noteExposed(processID)
    return focused
  }

  /// One read of an element: its text and selection, and whether the
  /// element no longer exists.
  private func read(_ element: AXUIElement) -> (text: FocusedText?, gone: Bool) {
    let found = accessibility.read(element)
    if found.gone { return (nil, true) }
    return (
      FocusedText(
        value: found.value,
        selectionLocation: found.selection?.location,
        selectionLength: found.selection?.length,
        element: FocusedElementHandle(element: element)),
      false
    )
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }
}

/// The accessibility calls the reader makes to find and read the field that
/// has the keyboard, behind one seam so that a test can stand in for an
/// application (review 10-5c S3: "the tree is requested on every miss" was
/// not pinned by any test). Safe to call from any thread.
protocol TargetAccessibility: Sendable {
  /// The element the application names as focused, without waiting; nil
  /// when it names none.
  func focusedElement(ofProcess processID: Int32) -> AXUIElement?
  /// Asks the application to build its accessibility tree now.
  func requestTree(ofProcess processID: Int32)
  /// One read of an element's text and selection.
  func read(_ element: AXUIElement) -> AccessibilityRead
}

/// What one read of an element found.
struct AccessibilityRead: Equatable, Sendable {
  var value: String?
  var selection: Selection?
  /// The element no longer exists.
  var gone: Bool

  struct Selection: Equatable, Sendable {
    var location: Int
    var length: Int
  }

  static let missing = AccessibilityRead(value: nil, selection: nil, gone: true)
}

/// The system's accessibility, with the reader's short timeouts.
struct LiveTargetAccessibility: TargetAccessibility {
  func focusedElement(ofProcess processID: Int32) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(application, TargetReader.accessibilityTimeoutSeconds)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let element = value as! AXUIElement
    AXUIElementSetMessagingTimeout(element, TargetReader.accessibilityTimeoutSeconds)
    return element
  }

  /// Chromium and Electron build their accessibility tree only once someone
  /// asks for it; this attribute is how an assistive client asks. An
  /// application that does not know it answers that it is unsupported, and
  /// nothing changes.
  func requestTree(ofProcess processID: Int32) {
    let application = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(application, TargetReader.accessibilityTimeoutSeconds)
    AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  func read(_ element: AXUIElement) -> AccessibilityRead {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    if status == .invalidUIElement { return .missing }
    return AccessibilityRead(
      value: status == .success ? value as? String : nil, selection: selectedRange(of: element),
      gone: false)
  }

  private func selectedRange(of element: AXUIElement) -> AccessibilityRead.Selection? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return AccessibilityRead.Selection(location: range.location, length: range.length)
  }
}

/// An accessibility element carried inside a `FocusedText`. Elements are
/// immutable references; reading them from another task is safe.
struct FocusedElementHandle: @unchecked Sendable {
  let element: AXUIElement
}

/// Which applications have shown a focused element through accessibility,
/// so that waiting for a tree being built is spent only where one can appear.
///
/// The 2026-09-22 reader woke each process once and never again (a set of
/// process numbers). A Chromium application that dropped its tree later —
/// Chromium's AutoDisableAccessibility turns it off after three or more
/// inputs over thirty seconds with no assistive use — then named no focused
/// element for the rest of the process's life, and every paste into it was
/// judged on the pasteboard read alone (DELIVERY.md 原因 2). Now the tree is
/// requested on every miss; this book only decides how long to wait for it.
struct AccessibilityWakeBook {
  /// How long a process is given to name its focused element after its
  /// tree is requested. Chromium builds the tree asynchronously.
  static let wakeWindowSeconds: TimeInterval = 0.5
  /// How long "showed nothing after a full wait" is believed. After that a
  /// full wait is given again: an application may build its tree later, and
  /// a process number can be reused.
  static let missingMemorySeconds: TimeInterval = 600
  /// How long a request made when the dictation key went down counts: a
  /// dictation is shorter than this. Within it, the application has already
  /// had (part of) its wake window, so the read when the words are ready
  /// waits only for what is left of it.
  static let requestMemorySeconds: TimeInterval = 120

  enum Exposure: Equatable {
    case exposed
    case missing(since: Date)
  }

  private(set) var exposure: [Int32: Exposure] = [:]
  private(set) var requested: [Int32: Date] = [:]

  func waitSeconds(for processID: Int32, now: Date) -> TimeInterval {
    if case .missing(let since)? = exposure[processID],
      now.timeIntervalSince(since) < Self.missingMemorySeconds
    {
      return 0
    }
    if let at = requested[processID] {
      let age = now.timeIntervalSince(at)
      if age >= 0, age < Self.requestMemorySeconds {
        return max(0, Self.wakeWindowSeconds - age)
      }
    }
    return Self.wakeWindowSeconds
  }

  /// The tree was requested when the dictation key went down.
  mutating func noteRequested(_ processID: Int32, now: Date) {
    requested[processID] = now
  }

  mutating func noteExposed(_ processID: Int32) {
    exposure[processID] = .exposed
  }

  mutating func noteMissingAfterWait(_ processID: Int32, now: Date) {
    exposure[processID] = .missing(since: now)
  }
}
