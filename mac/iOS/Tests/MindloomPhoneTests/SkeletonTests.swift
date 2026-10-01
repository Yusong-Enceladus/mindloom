import Foundation
import MindloomLink
import MindloomPhoneKit
import XCTest

/// Checks the built app on the simulator: identifiers, embedded extensions,
/// their extension points and the shared App Group container.
final class SkeletonTests: XCTestCase {
  private var app: Bundle { Bundle.main }

  private func plugin(_ name: String) throws -> Bundle {
    let url = try XCTUnwrap(app.builtInPlugInsURL).appendingPathComponent("\(name).appex")
    return try XCTUnwrap(Bundle(url: url), "\(name).appex is embedded")
  }

  private func extensionInfo(_ bundle: Bundle) throws -> [String: Any] {
    try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
  }

  func testAppIdentity() {
    XCTAssertEqual(app.bundleIdentifier, PhoneAppGroup.appBundleID)
    XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "织机")
    let modes = app.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    XCTAssertTrue(modes.contains("audio"), "the voice session keeps running for the keyboard")
    XCTAssertTrue(modes.contains("fetch"), "BGAppRefreshTask sends the outbox")
    XCTAssertNotNil(app.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
  }

  func testKeyboardExtension() throws {
    let keyboard = try plugin("MindloomKeyboard")
    XCTAssertEqual(keyboard.bundleIdentifier, PhoneAppGroup.keyboardBundleID)
    XCTAssertEqual(keyboard.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "织机键盘")
    let info = try extensionInfo(keyboard)
    XCTAssertEqual(info["NSExtensionPointIdentifier"] as? String, "com.apple.keyboard-service")
    let attributes = try XCTUnwrap(info["NSExtensionAttributes"] as? [String: Any])
    XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, true)
    XCTAssertEqual(attributes["PrimaryLanguage"] as? String, "zh-Hans")
  }

  func testShareExtension() throws {
    let share = try plugin("MindloomShare")
    XCTAssertEqual(share.bundleIdentifier, PhoneAppGroup.shareBundleID)
    XCTAssertEqual(share.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "收进织机")
    let info = try extensionInfo(share)
    XCTAssertEqual(info["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
    let attributes = try XCTUnwrap(info["NSExtensionAttributes"] as? [String: Any])
    let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? [String: Any])
    XCTAssertNotNil(
      rule["NSExtensionActivationSupportsMovieWithMaxCount"],
      "videos open 收进织机 so it can say 音视频请在 Mac 上导入")
  }

  /// 织机键盘's "打开织机开始语音" opens this URL.
  func testAppHandlesTheStartVoiceURL() throws {
    let types = try XCTUnwrap(
      app.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    XCTAssertTrue(schemes.contains(PhoneAppGroup.urlScheme))
    XCTAssertEqual(PhoneAppGroup.startVoiceURL.scheme, PhoneAppGroup.urlScheme)
  }

  /// The extensions link no networking code (the SSH stack is app-only).
  func testExtensionsCarryNoSSHCode() throws {
    for name in ["MindloomKeyboard", "MindloomShare"] {
      let bundle = try plugin(name)
      let executable = try XCTUnwrap(bundle.executableURL)
      let data = try Data(contentsOf: executable, options: .mappedIfSafe)
      XCTAssertNil(data.range(of: Data("NIOSSHHandler".utf8)), "\(name) must not contain SSH code")
    }
  }

  /// The simulator build is signed with the App Group entitlement, so the
  /// shared container exists and the outbox opens inside it.
  func testAppGroupOutboxOpens() throws {
    let container = try XCTUnwrap(PhoneAppGroup.containerURL(), "App Group entitlement present")
    let store = try OutboxStore.appGroup()
    XCTAssertEqual(
      store.root.standardizedFileURL,
      PhoneAppGroup.outboxDirectory(in: container).standardizedFileURL)
    let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }
}
