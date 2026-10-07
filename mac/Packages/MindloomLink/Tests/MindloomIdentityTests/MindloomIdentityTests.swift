import Foundation
import MindloomIdentity
import XCTest

final class MindloomIdentityTests: XCTestCase {
  /// The repository root (this file is Packages/MindloomLink/Tests/MindloomIdentityTests/…).
  private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  func testEverythingDerivesFromTheBundleID() {
    XCTAssertEqual(MindloomIdentity.bundleID, "app.mindloom")
    XCTAssertEqual(MindloomIdentity.appGroup, "group.app.mindloom")
    XCTAssertEqual(MindloomIdentity.iCloudContainer, "iCloud.app.mindloom")
    XCTAssertEqual(MindloomIdentity.debugBundleID, "app.mindloom.debug")
    XCTAssertEqual(MindloomIdentity.bundleID(of: .keyboard), "app.mindloom.keyboard")
    XCTAssertEqual(MindloomIdentity.bundleID(of: .share), "app.mindloom.share")
    XCTAssertEqual(MindloomIdentity.bundleID(of: .live), "app.mindloom.live")
    XCTAssertEqual(MindloomIdentity.bundleID(of: .watch), "app.mindloom.watchkitapp")
    XCTAssertEqual(
      MindloomIdentity.bundleID(of: .inferenceWorker), "app.mindloom.inference-worker")
    XCTAssertEqual(MindloomIdentity.bundleID(of: .mcp), "app.mindloom.mcp")
    XCTAssertEqual(
      MindloomIdentity.bundleID(of: .share, base: MindloomIdentity.debugBundleID),
      "app.mindloom.debug.share")
    XCTAssertEqual(MindloomIdentity.keychainService("organizer-key"), "app.mindloom.organizer-key")
    XCTAssertEqual(MindloomIdentity.logSubsystem, "app.mindloom")
    XCTAssertEqual(MindloomIdentity.darwinNotification("voice.start"), "app.mindloom.voice.start")
    XCTAssertEqual(MindloomIdentity.nativeMessagingHost, "app.mindloom")
    XCTAssertEqual(MindloomIdentity.outboxRefreshTask, "app.mindloom.outbox-refresh")
    XCTAssertEqual(MindloomIdentity.libraryFolderName, "Mindloom")
    XCTAssertEqual(MindloomIdentity.urlScheme, "mindloom")
  }

  func testThePreviousIdentityIsBestASRs() {
    XCTAssertEqual(MindloomIdentity.Previous.bundleID, "com.bestasr.app")
    XCTAssertEqual(MindloomIdentity.Previous.libraryFolderName, "bestASR")
    XCTAssertEqual(
      MindloomIdentity.Previous.keychainService("organizer-key"), "com.bestasr.organizer-key")
  }

  func testCheckIdentitiesAreNeverTheProductOrBestASR() {
    XCTAssertTrue(MindloomIdentity.isCheckIdentity("com.bestasr.mindloom.check"))
    XCTAssertTrue(MindloomIdentity.isCheckIdentity("com.bestasr.mindloom.check.switch"))
    XCTAssertFalse(MindloomIdentity.isCheckIdentity("com.bestasr.mindloom.checkout"))
    XCTAssertFalse(MindloomIdentity.isCheckIdentity(MindloomIdentity.bundleID))
    XCTAssertFalse(MindloomIdentity.isCheckIdentity(MindloomIdentity.Previous.bundleID))
    XCTAssertFalse(MindloomIdentity.isCheckIdentity("com.bestasr.mindloom.preview"))
  }

  /// The build files name the bundle id once each, and it is this one.
  func testBuildFilesCarryTheSameBundleID() throws {
    let mac = try String(
      contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
    XCTAssertEqual(setting("MINDLOOM_BUNDLE_ID", in: mac), [MindloomIdentity.bundleID])
    let phone = try String(
      contentsOf: repository.appendingPathComponent("iOS/project.yml"), encoding: .utf8)
    XCTAssertEqual(setting("MINDLOOM_PHONE_BUNDLE_ID", in: phone), [MindloomIdentity.bundleID])
    let shell = try String(
      contentsOf: repository.appendingPathComponent("script/identity.sh"), encoding: .utf8)
    XCTAssertEqual(
      setting("MINDLOOM_BUNDLE_ID", in: shell, separator: "="), [MindloomIdentity.bundleID])
    XCTAssertEqual(
      setting("MINDLOOM_PREVIOUS_BUNDLE_ID", in: shell, separator: "="),
      [MindloomIdentity.Previous.bundleID])
    // The agent launchers ship outside the repository's scripts: each names the bundle id once.
    for launcher in [
      "integrations/claude-code-plugin/bin/mindloom-mcp.sh",
      "integrations/claude-desktop/server/mindloom-mcp.sh",
    ] {
      let text = try String(
        contentsOf: repository.appendingPathComponent(launcher), encoding: .utf8)
      XCTAssertTrue(
        text.contains("app_id=\"${MINDLOOM_APP_ID:-\(MindloomIdentity.bundleID)}\""), launcher)
      XCTAssertFalse(text.contains(MindloomIdentity.Previous.bundleID), launcher)
    }
    let chrome = try String(
      contentsOf: repository.appendingPathComponent("integrations/chrome-extension/background.js"),
      encoding: .utf8)
    XCTAssertTrue(chrome.contains("const HOST = \"\(MindloomIdentity.nativeMessagingHost)\";"))
  }

  /// `KEY: value` (YAML) or `KEY=value` (shell) lines for one key, values only.
  private func setting(_ key: String, in text: String, separator: String = ":") -> [String] {
    text.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(key + separator) else { return nil }
      return trimmed.dropFirst(key.count + separator.count).trimmingCharacters(in: .whitespaces)
    }
  }

  func testALibraryRootsIdentityIsItsCanonicalPathHashed() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("Mindloom", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let link = base.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let hash = LibraryRootIdentity.hash(of: root)
    XCTAssertEqual(hash.count, 32)
    XCTAssertEqual(LibraryRootIdentity.hash(of: link), hash)
    XCTAssertEqual(LibraryRootIdentity.hash(of: root.appendingPathComponent("x/..")), hash)
    // Moved to another folder: another identity.
    let moved = base.appendingPathComponent("bestASR", isDirectory: true)
    try FileManager.default.moveItem(at: root, to: moved)
    XCTAssertNotEqual(LibraryRootIdentity.hash(of: moved), hash)
  }
}
