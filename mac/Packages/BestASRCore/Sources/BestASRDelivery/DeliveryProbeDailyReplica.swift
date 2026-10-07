#if MINDLOOM_DELIVERY_PROBE
  import AppKit
  import ApplicationServices
  import Carbon.HIToolbox
  import Foundation

  /// The delivery of the build the user runs every day (d54fb45, 2026-09-22),
  /// replicated for the delivery probe only, so that its claims can be checked
  /// against what the field shows on the same machine and the same
  /// applications. Production never uses this.
  ///
  /// What it replicates, line for line with that build:
  /// - the focused element is read once; a process is woken
  ///   (`AXManualAccessibility`) at most once in this object's life, with a
  ///   0.15 s wait;
  /// - a paste counts as landed when the pasteboard was read and, where a
  ///   focused element was named, whatever has the keyboard afterwards shows
  ///   different text; where none was named, the read alone counts
  ///   (evidence `pasteboard`);
  /// - on a landing the earlier clipboard is put back at once, whoever owns
  ///   the clipboard by then; otherwise the words are left on it.
  @MainActor
  final class DailyDeliveryReplica {
    struct Claim: Equatable {
      let inserted: Bool
      /// Evidence when inserted, reason otherwise, in that build's words.
      let detail: String
      let focus: String
      let waitMilliseconds: Int?
    }

    private var woken: Set<Int32>

    /// `alreadyWoken`: processes this daily process has already woken once
    /// (a long-running daily process after the first sentence into them). A
    /// fresh replica is the daily process meeting an application for the
    /// first time — the first sentence after a relaunch.
    init(alreadyWoken: Set<Int32> = []) {
      woken = alreadyWoken
    }

    func deliver(_ text: String, to processID: Int32) async -> Claim {
      guard CGPreflightPostEventAccess() else {
        return Claim(inserted: false, detail: "permissionDenied", focus: "-", waitMilliseconds: nil)
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
        return Claim(
          inserted: false, detail: "applicationChanged", focus: "-", waitMilliseconds: nil)
      }
      guard !IsSecureEventInputEnabled() else {
        return Claim(inserted: false, detail: "secureInput", focus: "-", waitMilliseconds: nil)
      }
      let before = focusedText(of: processID)
      let focus = TextDeliverer.focusName(before)
      let spaced = BoundarySpacing.apply(text, before: before?.caret)
      guard let source = CGEventSource(stateID: .hidSystemState),
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
      else {
        return Claim(
          inserted: false, detail: "permissionDenied", focus: focus, waitMilliseconds: nil)
      }
      down.flags = .maskCommand
      up.flags = .maskCommand
      let pasteboard = NSPasteboard.general
      let prior = PasteboardSnapshot(pasteboard: pasteboard)
      let promise = PromisedPasteboardText(spaced)
      guard promise.write(to: pasteboard) else {
        prior.restore(to: pasteboard)
        return Claim(
          inserted: false, detail: "permissionDenied", focus: focus, waitMilliseconds: nil)
      }
      let posted = Date()
      down.postToPid(processID)
      up.postToPid(processID)
      let taken = await promise.awaitRequest(after: posted, timeout: 0.4)
      var fieldChanged: Bool?
      if taken, let before {
        fieldChanged = await textChanged(since: before, in: processID, within: 0.3)
      }
      let waited = Int(Date().timeIntervalSince(posted) * 1000)
      if taken, fieldChanged ?? true {
        prior.restore(to: pasteboard)
        return Claim(
          inserted: true, detail: fieldChanged == nil ? "pasteboard" : "field", focus: focus,
          waitMilliseconds: waited)
      }
      pasteboard.clearContents()
      _ = pasteboard.setString(spaced, forType: .string)
      return Claim(
        inserted: false, detail: taken ? "nowhere(read-unchanged)" : "nowhere(unread)",
        focus: focus,
        waitMilliseconds: waited)
    }

    // MARK: That build's reader

    private func focusedText(of processID: Int32) -> FocusedText? {
      guard let element = focusedElement(of: processID) else { return nil }
      var value: CFTypeRef?
      let text =
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        ? value as? String : nil
      var rangeValue: CFTypeRef?
      var range = CFRange()
      let hasRange =
        AXUIElementCopyAttributeValue(
          element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
        && rangeValue.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
        && AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
      return FocusedText(
        value: text, selectionLocation: hasRange ? range.location : nil,
        selectionLength: hasRange ? range.length : nil)
    }

    private func focusedElement(of processID: Int32) -> AXUIElement? {
      let application = AXUIElementCreateApplication(processID)
      AXUIElementSetMessagingTimeout(application, 0.25)
      if let focused = focusedElement(in: application) { return focused }
      guard !woken.contains(processID) else { return nil }
      woken.insert(processID)
      AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
      let deadline = Date().addingTimeInterval(0.15)
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
        let value, CFGetTypeID(value) == AXUIElementGetTypeID()
      else { return nil }
      let element = value as! AXUIElement
      AXUIElementSetMessagingTimeout(element, 0.25)
      return element
    }

    private func textChanged(
      since before: FocusedText, in processID: Int32, within window: TimeInterval
    ) async -> Bool {
      guard before.exposesText else { return false }
      let deadline = Date().addingTimeInterval(window)
      repeat {
        if let now = focusedText(of: processID), now.exposesText, now != before { return true }
        try? await Task.sleep(for: .milliseconds(30))
      } while Date() < deadline
      return false
    }
  }
#endif
