import AppKit
import ApplicationServices
import XCTest

@testable import BestASRDelivery

/// Delivery against a real application: the AXInsertionFixture app, which
/// has an editable field, a read-only one and a password field. These run
/// only where the test process may post keystrokes and read accessibility;
/// elsewhere they skip rather than pretend.
@MainActor
final class TextDelivererFixtureTests: XCTestCase {
  private var fixture: Process?
  private var readyFile: URL?

  override func setUp() async throws {
    try XCTSkipUnless(
      CGPreflightPostEventAccess() && AXIsProcessTrusted(),
      "needs Accessibility for the test runner")
    let binary = Self.fixtureBinary()
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no fixture binary")
    let ready = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestASR-fixture-\(UUID().uuidString).pid")
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--ready-file", ready.path]
    try process.run()
    fixture = process
    readyFile = ready
    let deadline = Date().addingTimeInterval(8)
    while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try XCTSkipUnless(FileManager.default.fileExists(atPath: ready.path), "fixture did not start")
    try await Task.sleep(for: .milliseconds(300))
  }

  override func tearDown() async throws {
    fixture?.terminate()
    if let readyFile { try? FileManager.default.removeItem(at: readyFile) }
  }

  private var target: DeliveryTarget {
    DeliveryTarget(
      processIdentifier: fixture!.processIdentifier, bundleIdentifier: "bestASR.fixture")
  }

  func testTextLandsInTheEditableFieldAndTheClipboardComesBack() async throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("the user's own clipboard", forType: .string)
    try focus("bestasr.ax.direct")
    let outcome = await TextDeliverer().deliver("delivered", to: target, observing: TargetReader().focusedText(in: target.processIdentifier))
    guard case .delivered(let evidence, let wait) = outcome else {
      return XCTFail("expected delivery, got \(outcome)")
    }
    XCTAssertLessThan(wait, 400)
    XCTAssertEqual(evidence, .field)
    XCTAssertEqual(value(of: "bestasr.ax.direct")?.contains("delivered"), true)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "the user's own clipboard")
  }

  func testAReadOnlyFieldTakesNothingAndTheWordsStayOnTheClipboard() async throws {
    try focus("bestasr.ax.readonly")
    let outcome = await TextDeliverer().deliver("unwanted", to: target, observing: TargetReader().focusedText(in: target.processIdentifier))
    XCTAssertEqual(outcome, .kept(.nowhere))
    XCTAssertEqual(value(of: "bestasr.ax.readonly")?.contains("unwanted"), false)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unwanted")
  }

  func testAPasswordFieldIsNeverSentAnything() async throws {
    try focus("bestasr.ax.secure")
    try await Task.sleep(for: .milliseconds(100))
    let outcome = await TextDeliverer().deliver("secret", to: target, observing: TargetReader().focusedText(in: target.processIdentifier))
    XCTAssertEqual(outcome, .kept(.secureInput))
  }

  func testTheSelectionIsReadFromTheFrontApplication() throws {
    try focus("bestasr.ax.direct")
    let element = try element("bestasr.ax.direct")
    var range = CFRange(location: 0, length: 5)
    let value = AXValueCreate(.cfRange, &range)!
    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    XCTAssertEqual(TargetReader().selectedText(), "alpha")
  }

  // MARK: Fixture access

  private static func fixtureBinary() -> URL {
    Bundle(for: TextDelivererFixtureTests.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("AXInsertionFixture")
  }

  private func element(_ identifier: String) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(fixture!.processIdentifier)
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
    for window in (windows as? [AXUIElement]) ?? [] {
      if let found = Self.descendant(of: window, identifier: identifier) { return found }
    }
    throw XCTSkip("fixture element \(identifier) not exposed")
  }

  private static func descendant(of element: AXUIElement, identifier: String) -> AXUIElement? {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
      value as? String == identifier
    {
      return element
    }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    for child in (children as? [AXUIElement]) ?? [] {
      if let found = descendant(of: child, identifier: identifier) { return found }
    }
    return nil
  }

  private func focus(_ identifier: String) throws {
    NSRunningApplication(processIdentifier: fixture!.processIdentifier)?
      .activate(options: [])
    let element = try element(identifier)
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
  }

  private func value(of identifier: String) -> String? {
    guard let element = try? element(identifier) else { return nil }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    return value as? String
  }
}
